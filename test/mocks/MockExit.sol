// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Stand-in for the 0x800 balance-transfer precompile. Records the last exit.
///         Etch this at address(0x800) in tests.
contract MockExit {
    event Exited(bytes32 ss58, uint256 value);
    bytes32 public lastSS58;
    uint256 public lastValue;

    function transfer(bytes32 ss58) external payable {
        lastSS58 = ss58;
        lastValue = msg.value;
        emit Exited(ss58, msg.value);
    }
}

/// @notice Always-reverting variant to test the claimable fallback path.
contract MockExitReverting {
    function transfer(bytes32) external payable {
        revert("exit down");
    }
}
