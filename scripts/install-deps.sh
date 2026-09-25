#!/usr/bin/env bash
# Vendors exact CCIP v1.6.0 + OpenZeppelin sources into contracts/lib via sparse checkout,
# so we don't pull the multi-GB Chainlink monorepos. Deterministic (pinned tags).
set -euo pipefail
cd "$(dirname "$0")/.."   # -> contracts/
mkdir -p lib

clone_sparse() {
  local url="$1" ref="$2" dir="$3"; shift 3
  echo ">> $dir @ $ref"
  rm -rf "lib/$dir"
  git clone --quiet --depth 1 --branch "$ref" --filter=blob:none --sparse "$url" "lib/$dir"
  ( cd "lib/$dir" && git sparse-checkout set "$@" >/dev/null && rm -rf .git )
}

# Foundry std
[ -d lib/forge-std/src ] || clone_sparse https://github.com/foundry-rs/forge-std v1.9.4 forge-std src test
# OpenZeppelin v5.0.2 (for our own WTAO)
clone_sparse https://github.com/OpenZeppelin/openzeppelin-contracts v5.0.2 openzeppelin-contracts contracts
# Chainlink CCIP CCT v1.6.0 (pools, Client, CCIPReceiver, RateLimiter)
clone_sparse https://github.com/smartcontractkit/chainlink-ccip contracts-ccip-v1.6.0 chainlink-ccip chains/evm/contracts
# Chainlink shared v1.4.0 (BurnMintERC20 + vendored OZ that CCIP imports)
clone_sparse https://github.com/smartcontractkit/chainlink-evm contracts-v1.4.0 chainlink-evm contracts/src/v0.8

echo "Done. lib/:"; ls lib
