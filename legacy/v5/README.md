# v5 hub — still active for inbound transfers

Both current spokes (Base and Robinhood) send transfers back to this Bittensor hub:
`0xcd0C6d98D0A126B1c113d15b4c28F38321437787` (chain ID 964).
“Legacy” describes its version; this contract remains part of the live bridge and audit scope.
The current v6 hub is in the top-level `src/` directory and handles SDK outbound transfers.

## Source provenance

These six Solidity files are copied unchanged from the private `tao-bridge` repository,
commit `5ac33fcd2878de1251662c33c52ab6f9392abc25` (final v5 deployment review).
They include `AlphaGateway.sol` and every local import it needs. Third-party imports use the
same pinned dependencies in the top-level `lib/` directory. This preserves the actual older
implementation rather than trying to reproduce it by editing the current hub.

## Verification

From the repository root, with Python 3 and Foundry installed:

```bash
python3 scripts/verify-v5.py
# Optionally refresh the recorded evidence:
python3 scripts/verify-v5.py --output legacy/v5/verification.json
```

The script compiles this source in a temporary directory with the original `src/` and `lib/`
paths and the repository's compiler settings (Solidity 0.8.26, Paris, optimizer 200 runs).
It performs read-only RPC calls, checks chain IDs, pins each chain's reads to a block, compares
runtime bytecode, and checks that both spokes still point to this hub. Set `SUBTENSOR_RPC`,
`BASE_RPC`, or `ROBINHOOD_RPC` to override the public endpoints.

The deployed runtime is **16,118 bytes**. Executable code matches after masking only the
compiler-declared immutable slots. A **32-byte IPFS metadata hash differs**; the script requires
the rest of the metadata to match. This is not a full byte-for-byte match including metadata
and constructor values. Immutable values are not individually validated, except the spokes'
hub pointers, which are checked separately.

[`verification.json`](verification.json) records the checked blocks, source hashes, runtime hash
and comparison result. The legacy source is compiled separately so the main build and current
contract artifacts remain unambiguous. The top-level test suite covers the current contracts;
it is not a dedicated v5 test suite or a security audit.
