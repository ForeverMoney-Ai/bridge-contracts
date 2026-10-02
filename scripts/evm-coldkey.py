#!/usr/bin/env python3
"""Print the substrate coldkey an EVM address maps to: blake2b_256("evm:" + address).

Used by the deploy scripts through `vm.ffi` so VAULT_COLDKEY / GATEWAY_COLDKEY are checked against
the address they are supposed to belong to, instead of being trusted as given. Solidity cannot do
this itself: blake2b-256 is not an EVM primitive (0x09 is only the compression function).

    python3 scripts/evm-coldkey.py 0x11837459896D96F821a8D88eC93a3C8D152033D4

Run forge with `--ffi` for the scripts that call this.
"""
import hashlib
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: evm-coldkey.py <0x-address>")

raw = sys.argv[1].strip()
if raw.startswith(("0x", "0X")):
    raw = raw[2:]
address = bytes.fromhex(raw)
if len(address) != 20:
    raise SystemExit(f"expected a 20-byte address, got {len(address)} bytes")

print("0x" + hashlib.blake2b(b"evm:" + address, digest_size=32).hexdigest())
