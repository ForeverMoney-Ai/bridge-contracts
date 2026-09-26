# Bridge contracts

Solidity for a bridge that wraps a staked Bittensor position into a transferable token on other
chains, without unstaking it. The stake keeps earning on Bittensor while a 1:1 token moves over
[Chainlink CCIP](https://docs.chain.link/ccip); it is redeemable for the underlying position at any
time, either as liquid TAO or as the staked position itself.

This repository is a snapshot of the contracts as deployed to mainnet, published for audit.
The initial snapshot was squashed to a single commit; subsequent changes are tracked here. The development history,
off-chain services, deploy records and frontend live in the private monorepo.

## Layout

| Path | What |
|---|---|
| `src/` | Current contract source in the audit scope |
| `legacy/v5/` | Older hub source, **still active for inbound transfers** and also in the audit scope |
| `test/` | Foundry tests (239, all passing) |
| `test-onchain/` | tests that run against mainnet forks / live chains |
| `script/` | Foundry deployment and wiring scripts |
| `lib/` | third-party dependencies, vendored at pinned tags (see below) |

### `src/`

| Contract | Chain | Role |
|---|---|---|
| `AlphaVault.sol` | Bittensor EVM (964) | Custodies the staked positions and mints/burns the wrapped tokens. Holds the accounting, the guardian pause and the emissions skim. |
| `AlphaToken.sol` | Bittensor EVM (964) | The wrapped token on the home chain, one per subnet (netuid 0 = TAO). |
| `AlphaGateway.sol` | Bittensor EVM (964) | The CCIP hub. Sends wrapped tokens out to spoke chains and handles arrivals, including exits that unstake or sell on the subnet. |
| `SpokeGateway.sol` | Base (8453), Robinhood (4663) | The CCIP spoke. Bridges the wrapped token back to 964 with an exit payload. |
| `ExitPayload.sol` | — | Encoding of what an arrival should do (deliver liquid, deliver staked, or push the token). |
| `StakeSource.sol` | — | Selecting and draining the validator positions a wrap is taken from. |
| `IntegratorFee.sol` | — | Optional per-call fee an integrator may charge, capped on-chain. |
| `interfaces/` | — | Bittensor precompile interfaces (staking, balance transfer) and our own token/vault interfaces. |

Bittensor-specific note: `AlphaVault` and `AlphaGateway` talk to Subtensor **precompiles**
(`0x805` staking, `0x800` balance transfer) rather than ordinary contracts, so parts of their
behaviour can only be exercised on-chain — that is what `test-onchain/` is for.

## Deployed, and how to verify it

The current contracts compile to the deployed executable runtime code after masking the compiler's
constructor-set immutable slots. The vault, four home-chain tokens and both spokes also match the
compiler metadata. The current v6 hub differs only in a 32-byte metadata hash after masking immutables.

The still-active v5 hub is preserved separately in [`legacy/v5/`](legacy/v5/README.md). Its executable
runtime also matches that preserved source after masking immutables; its 32-byte metadata hash differs.
These checks establish executable-code identity, not a security audit or validation of every
constructor value and current storage setting.

| Contract | Chain | Address |
|---|---|---|
| AlphaVault | 964 | `0x11837459896D96F821a8D88eC93a3C8D152033D4` |
| AlphaGateway v6 (current hub) | 964 | `0xd5Fa238aa4177f6c1341491969d9cBeec94EEd69` |
| AlphaGateway v5 (still serves inbound) | 964 | `0xcd0C6d98D0A126B1c113d15b4c28F38321437787` |
| AlphaToken — TAO | 964 | `0xC5b6C1632d34901239396F5E1BDe54B342900256` |
| AlphaToken — SN80 | 964 | `0xfD628dE75EF96f0A5C59659159C6cA81E0DC2222` |
| AlphaToken — SN10 | 964 | `0xcd0836D1ecE4AEDf5B39f2792e0790BBE79449b3` |
| AlphaToken — SN78 | 964 | `0xF2a747b004fACa8EAB646948117499E25CB8641d` |
| SpokeGateway v5 | Base | `0x1da2415229b614C787e145D1D7346eb496319C52` |
| SpokeGateway v5 | Robinhood | `0xf27fdA637131E25B2A1b4865ED9597d881980c7E` |

Both Base and Robinhood spokes send transfers back to the v5 hub on Bittensor at
`0xcd0C6d98D0A126B1c113d15b4c28F38321437787`; their `SUBTENSOR_GATEWAY` pointers are immutable.
The SDK uses the current v6 hub for outbound transfers from Bittensor. The v5 hub has different
executable code from v6, so review its preserved source as part of the live bridge flow.
Older v4 contracts remain outside this repository's scope.

The spoke-side tokens on Base and Robinhood are Chainlink's `BurnMintERC20` with Chainlink's
`BurnMintTokenPool` / `LockReleaseTokenPool`, used unmodified from `lib/`; they are not our code.

To reproduce the comparison:

```bash
forge build
# then, per contract, compare `out/<C>.sol/<C>.json` .deployedBytecode.object with
# `cast code <address> --rpc-url <chain>`, ignoring the byte ranges listed in
# .deployedBytecode.immutableReferences
# For the current hub, also account for the 32-byte metadata hash difference.

# Build the preserved v5 source separately and verify its live runtime + spoke routing:
python3 scripts/verify-v5.py
```

## Build

Requires [Foundry](https://book.getfoundry.sh/). Dependencies are already vendored in `lib/`, so a
clone builds offline once the pinned compiler is installed:

```bash
forge build
forge test
```

`scripts/install-deps.sh` is what produced `lib/`, pinned to exact upstream tags:

| Dependency | Tag |
|---|---|
| `forge-std` | `v1.9.4` |
| `openzeppelin-contracts` | `v5.0.2` |
| `chainlink-ccip` | `contracts-ccip-v1.6.0` |
| `chainlink-evm` | `contracts-v1.4.0` |

Compiler settings that produced the deployed bytecode are in `foundry.toml`: solc `0.8.26`,
`evm_version = "paris"`, optimizer on, 200 runs.
