// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title ExitPayload — the wire format of a return-leg CCIP message (spoke chain -> 964).
/// @notice Single source of truth for what rides in `EVM2AnyMessage.data`, shared by the sender
///         (`SpokeGateway`) and the receiver (`AlphaGateway`) so the two can never drift.
library ExitPayload {
    struct Params {
        /// @dev 32-byte substrate public key of the destination coldkey on Bittensor.
        bytes32 ss58;
        /// @dev 964 EVM address credited if delivery cannot complete. Zero is normalised to the
        ///      gateway's rescuer on decode, so no booking can ever land on address(0).
        address evmFallback;
        /// @dev true  -> unwrap to native TAO and exit via the 0x800 precompile.
        ///      false -> deliver the STAKED position to `ss58` (no AMM leg; `transferStake` can
        ///               credit 1 RAO less when it opens a new position).
        bool wantLiquid;
        /// @dev Slippage bound for the liquid unwrap, in native wei. Ignored when `wantLiquid` is
        ///      false (the staked route has no AMM leg). Without this a subnet unwrap would execute at
        ///      any AMM price; if the bound is missed the delivery is booked claimable instead.
        uint256 minTaoOut;
    }

    function encode(Params memory p) internal pure returns (bytes memory) {
        return abi.encode(p.ss58, p.evmFallback, p.wantLiquid, p.minTaoOut);
    }

    /// @dev Reverts on a malformed payload — callers that must not revert wrap this in a try/catch.
    ///      `fallbackIfZero` is substituted when the payload carries no EVM fallback.
    function decode(bytes calldata data, address fallbackIfZero) internal pure returns (Params memory p) {
        (p.ss58, p.evmFallback, p.wantLiquid, p.minTaoOut) =
            abi.decode(data, (bytes32, address, bool, uint256));
        if (p.evmFallback == address(0)) p.evmFallback = fallbackIfZero;
    }
}
