#!/usr/bin/env python3
"""Compile the preserved v5 source and compare it with pinned live runtime code."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HUB = '0xcd0C6d98D0A126B1c113d15b4c28F38321437787'
SPOKES = {
    'base': (8453, '0x1da2415229b614C787e145D1D7346eb496319C52', 'https://mainnet.base.org'),
    'robinhood': (4663, '0xf27fdA637131E25B2A1b4865ED9597d881980c7E', 'https://rpc.mainnet.chain.robinhood.com'),
}


def run(*args):
    return subprocess.check_output(args, text=True, timeout=180).strip()


def rpc(url, method, *params):
    return json.loads(run('cast', 'rpc', '--rpc-url', url, method, *params))


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def split_metadata(code):
    require(len(code) >= 2, 'Runtime code is empty or truncated')
    size = int.from_bytes(code[-2:], 'big') + 2
    require(size <= len(code), 'Invalid Solidity metadata length')
    return code[:-size], code[-size:]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, help='Save JSON evidence')
    args = parser.parse_args()
    url = os.environ.get('SUBTENSOR_RPC', 'https://lite.chain.opentensor.ai')
    require(int(rpc(url, 'eth_chainId'), 16) == 964, 'Expected Subtensor chain 964')
    block = rpc(url, 'eth_blockNumber')
    live = bytes.fromhex(rpc(url, 'eth_getCode', HUB, block)[2:])
    # Preserve the original src/ and lib/ import paths without changing the main build.
    with tempfile.TemporaryDirectory(prefix='bridge-v5-') as directory:
        stage = Path(directory)
        shutil.copytree(ROOT / 'legacy/v5/src', stage / 'src')
        shutil.copyfile(ROOT / 'foundry.toml', stage / 'foundry.toml')
        (stage / 'lib').symlink_to(ROOT / 'lib', target_is_directory=True)
        run('forge', 'build', '--root', str(stage), '--quiet')
        artifact = json.loads((stage / 'out/AlphaGateway.sol/AlphaGateway.json').read_text())
    expected = bytearray.fromhex(artifact['deployedBytecode']['object'].removeprefix('0x'))
    actual = bytearray(live)
    require(len(expected) == len(actual), 'Runtime length mismatch')
    ranges = [slot for slots in artifact['deployedBytecode']['immutableReferences'].values() for slot in slots]
    for slot in ranges:
        start, length = slot['start'], slot['length']
        require(0 <= start < start + length <= len(actual), 'Invalid immutable range')
        expected[start:start + length] = bytes(length)
        actual[start:start + length] = bytes(length)
    expected_code, expected_metadata = split_metadata(expected)
    actual_code, actual_metadata = split_metadata(actual)
    require(expected_code == actual_code, 'Executable bytecode mismatch')
    # Permit only the IPFS digest to differ, not arbitrary trailing metadata.
    prefix = bytes.fromhex('a2646970667358221220')
    require(expected_metadata[:len(prefix)] == actual_metadata[:len(prefix)] == prefix, f'Unexpected metadata format: expected {expected_metadata.hex()}, actual {actual_metadata.hex()}')
    require(expected_metadata[len(prefix) + 32:] == actual_metadata[len(prefix) + 32:], 'Non-IPFS metadata differs')
    report = {
        'sourceCommit': '5ac33fcd2878de1251662c33c52ab6f9392abc25',
        'sourceSha256': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                         for p in sorted((ROOT / 'legacy/v5/src').rglob('*.sol'))},
        'chainId': 964, 'block': int(block, 16), 'address': HUB,
        'runtimeBytes': len(live), 'runtimeSha256': hashlib.sha256(live).hexdigest(),
        'immutableRangesMasked': len(ranges),
        'executableMatchAfterMaskingImmutables': True,
        'matchIncludingMetadataAfterMaskingImmutables': expected == actual,
        'metadataDifferingBytes': sum(a != b for a, b in zip(expected_metadata, actual_metadata)),
        'spokes': {},
    }
    for name, (chain_id, address, default_url) in SPOKES.items():
        spoke_url = os.environ.get(name.upper() + '_RPC', default_url)
        require(int(rpc(spoke_url, 'eth_chainId'), 16) == chain_id, 'Unexpected spoke chain')
        spoke_block = rpc(spoke_url, 'eth_blockNumber')
        hub = run('cast', 'call', address, 'SUBTENSOR_GATEWAY()(address)',
                  '--rpc-url', spoke_url, '--block', str(int(spoke_block, 16)))
        require(hub.lower() == HUB.lower(), name + ' no longer points to the v5 hub')
        report['spokes'][name] = {'chainId': chain_id, 'block': int(spoke_block, 16),
                                  'address': address, 'hub': hub}
    result = json.dumps(report, indent=2) + '\n'
    if args.output:
        args.output.write_text(result)
    print(result, end='')


if __name__ == '__main__':
    main()
