// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Subtensor EVM balance-transfer precompile (0x0000...0800)
/// @notice Moves native TAO from the caller's EVM balance to a substrate SS58 account.
/// @dev The recipient is the raw 32-byte substrate public key. Amount is sent as msg.value
///      (18-dec wei); the runtime credits it to the SS58 account in RAO (9 dec), truncating
///      any sub-RAO (sub-gwei) remainder. Callers must send whole-RAO amounts (value % 1e9 == 0).
interface IBalanceTransfer {
    function transfer(bytes32 ss58PublicKey) external payable;
}
