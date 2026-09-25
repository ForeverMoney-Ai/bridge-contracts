// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@chainlink/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {LockReleaseTokenPool} from "@chainlink/contracts-ccip/contracts/pools/LockReleaseTokenPool.sol";
import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/contracts/libraries/RateLimiter.sol";
import {Cfg} from "./Config.sol";

/// @notice 964 side of an additional subnet token when the VAULT is operator-listed by the multisig
///         (so `createToken` ran as a Safe tx, not from this key). Deploys ONLY the LockReleaseTokenPool
///         for an EXISTING AlphaToken, wires the lane to the Base counterpart while we still own the
///         pool, sets the rate-limit admin, then hands ownership to the multisig (2-step). CCIP
///         registration (registerAdminViaGetCCIPAdmin / acceptAdminRole / setPool) is the multisig's,
///         because it is vault.ccipAdmin — see the Safe batch "SN80 B".
/// Env: PRIVATE_KEY, TOKEN (964 AlphaToken), ADMIN (multisig), GUARDIAN (opt), EXPECT_POOL,
///      REMOTE_POOL / REMOTE_TOKEN (Base BurnMintTokenPool / token)
contract DeploySubPoolOnly is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address admin = vm.envAddress("ADMIN");
        require(admin != address(0) && admin != deployer, "ADMIN must be the multisig");
        require(
            vm.computeCreateAddress(deployer, vm.getNonce(deployer)) == vm.envAddress("EXPECT_POOL"),
            "ADDRESS GUARD: (deployer, nonce) would not produce EXPECT_POOL"
        );
        IERC20 token = IERC20(vm.envAddress("TOKEN"));
        require(address(token).code.length > 0, "TOKEN has no code - run the createToken Safe batch first");

        vm.startBroadcast(pk);
        LockReleaseTokenPool pool =
            new LockReleaseTokenPool(token, Cfg.DECIMALS, new address[](0), Cfg.SUB_RMN_PROXY, false, Cfg.SUB_ROUTER);
        require(address(pool) == vm.envAddress("EXPECT_POOL"), "deployed pool != EXPECT_POOL");
        pool.setRateLimitAdmin(vm.envOr("GUARDIAN", admin));
        _lane(pool);
        pool.transferOwnership(admin);
        vm.stopBroadcast();

        console2.log("LockReleasePool:", address(pool));
        console2.log("NEXT: Safe batch SN80 B (register + setPool + acceptOwnership)");
    }

    function _lane(LockReleaseTokenPool pool) internal {
        bytes[] memory rp = new bytes[](1);
        rp[0] = abi.encode(vm.envAddress("REMOTE_POOL"));
        TokenPool.ChainUpdate[] memory adds = new TokenPool.ChainUpdate[](1);
        adds[0] = TokenPool.ChainUpdate({
            remoteChainSelector: Cfg.BASE_SELECTOR,
            remotePoolAddresses: rp,
            remoteTokenAddress: abi.encode(vm.envAddress("REMOTE_TOKEN")),
            outboundRateLimiterConfig: RateLimiter.Config({isEnabled: true, capacity: Cfg.RL_CAPACITY, rate: Cfg.RL_RATE}),
            inboundRateLimiterConfig: RateLimiter.Config({isEnabled: true, capacity: Cfg.RL_CAPACITY, rate: Cfg.RL_RATE})
        });
        pool.applyChainUpdates(new uint64[](0), adds);
        require(pool.isSupportedChain(Cfg.BASE_SELECTOR), "lane not registered");
    }
}
