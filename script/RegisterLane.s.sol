// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/contracts/libraries/RateLimiter.sol";
import {Cfg} from "./Config.sol";

/// @notice Pair a LOCAL token pool with its counterpart on ONE remote chain (`applyChainUpdates`).
///         Generic over token AND chain — run it once per pool per remote chain, on BOTH sides.
///         Supersedes the old RegisterSubtensor/RegisterBase scripts, which hardcoded Base as the
///         only possible remote and so could not wire a second lane.
///
/// @dev    Caller must be the pool's OWNER. Run BEFORE handing pool ownership to the multisig; after
///         handoff this must be executed by the owner (multisig/timelock) instead.
///         This is the protocol-level half of a lane. The app-level half is
///         `AlphaGateway.setLane(remoteSelector, true)` on 964 (vault DEFAULT_ADMIN).
///
/// Env:
///   PRIVATE_KEY      pool owner key
///   LOCAL_POOL       pool on THIS chain
///   REMOTE_POOL      counterpart pool on the remote chain
///   REMOTE_TOKEN     counterpart token on the remote chain
///   REMOTE_SELECTOR  remote CCIP chain selector (e.g. Cfg.BASE_SELECTOR from 964, or
///                    Cfg.SUB_SELECTOR from Base — required, so a new chain needs no code change)
///   RL_CAPACITY / RL_RATE   optional rate-limit overrides (default: Cfg values)
///
/// Run: forge script script/RegisterLane.s.sol --rpc-url $RPC --broadcast
contract RegisterLane is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address localPool = vm.envAddress("LOCAL_POOL");
        address remotePool = vm.envAddress("REMOTE_POOL");
        address remoteToken = vm.envAddress("REMOTE_TOKEN");
        uint64 remoteSelector = uint64(vm.envUint("REMOTE_SELECTOR"));
        uint128 capacity = uint128(vm.envOr("RL_CAPACITY", uint256(Cfg.RL_CAPACITY)));
        uint128 rate = uint128(vm.envOr("RL_RATE", uint256(Cfg.RL_RATE)));

        bytes[] memory remotePools = new bytes[](1);
        remotePools[0] = abi.encode(remotePool);

        TokenPool.ChainUpdate[] memory adds = new TokenPool.ChainUpdate[](1);
        adds[0] = TokenPool.ChainUpdate({
            remoteChainSelector: remoteSelector,
            remotePoolAddresses: remotePools,
            remoteTokenAddress: abi.encode(remoteToken),
            outboundRateLimiterConfig: RateLimiter.Config({isEnabled: true, capacity: capacity, rate: rate}),
            inboundRateLimiterConfig: RateLimiter.Config({isEnabled: true, capacity: capacity, rate: rate})
        });

        vm.startBroadcast(pk);
        TokenPool(localPool).applyChainUpdates(new uint64[](0), adds);
        vm.stopBroadcast();

        // Read back immediately — applyChainUpdates silently accepts a config that does not match
        // the far side, and the mismatch only surfaces as failed deliveries later.
        require(TokenPool(localPool).isSupportedChain(remoteSelector), "lane not registered");
        require(
            keccak256(TokenPool(localPool).getRemoteToken(remoteSelector)) == keccak256(abi.encode(remoteToken)),
            "remote token mismatch"
        );
        require(TokenPool(localPool).isRemotePool(remoteSelector, abi.encode(remotePool)), "remote pool missing");

        console2.log("lane registered on pool: ", localPool);
        console2.log("  remote selector:       ", remoteSelector);
        console2.log("  remote pool:           ", remotePool);
        console2.log("  remote token:          ", remoteToken);
        console2.log("NEXT: run the mirror on the remote chain, then AlphaGateway.setLane on 964.");
    }
}
