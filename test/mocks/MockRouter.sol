// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IERC20} from
    "@chainlink/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";

/// @notice Minimal CCIP router stub for unit tests. Charges a flat fee, pulls transferred tokens
///         from the caller (simulating the pool lock/burn), and returns a deterministic messageId.
contract MockRouter {
    uint256 public fee;
    uint256 public nonce;
    bytes public lastExtraArgs; // capture for asserting the encoded gas limit

    constructor(uint256 fee_) {
        fee = fee_;
    }

    function getFee(uint64, Client.EVM2AnyMessage memory) external view returns (uint256) {
        return fee;
    }

    function isChainSupported(uint64) external pure returns (bool) {
        return true;
    }

    function ccipSend(uint64, Client.EVM2AnyMessage calldata message)
        external
        payable
        returns (bytes32)
    {
        require(msg.value >= fee, "fee");
        lastExtraArgs = message.extraArgs;
        // Simulate the token pool pulling the tokens the caller approved.
        for (uint256 i = 0; i < message.tokenAmounts.length; i++) {
            IERC20(message.tokenAmounts[i].token).transferFrom(
                msg.sender, address(this), message.tokenAmounts[i].amount
            );
        }
        return keccak256(abi.encode(++nonce));
    }
}
