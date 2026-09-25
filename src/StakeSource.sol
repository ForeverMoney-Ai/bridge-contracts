// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice One staked position to pull from when wrapping alpha.
/// @dev    Subtensor keys stake by (coldkey, hotkey, netuid), and the 0x805 `transferStakeFrom`
///         takes a SINGLE hotkey — so a pull can only land on the hotkey it came from. A user
///         whose alpha sits with their own chosen validators therefore needs one entry per
///         validator, and the gateway re-delegates each to the token's canonical validator with
///         `moveStake` (same-netuid, exact, no AMM round trip) before depositing.
///
///         `alphaRao` is explicit rather than a "take everything" sentinel: the EVM cannot read
///         the caller's positions (there is no coldkey lookup on the precompile, and the coldkey
///         is blake2b("evm:"+address) which is impractical on-chain), so the caller states the
///         amounts and the runtime enforces its own minimums.
struct StakeSource {
    bytes32 validator; // hotkey the caller's alpha currently sits on
    uint256 alphaRao;  // how much of that position to take, in RAO
}
