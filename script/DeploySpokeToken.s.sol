// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {BurnMintERC20} from "@chainlink/contracts/src/v0.8/shared/token/ERC20/BurnMintERC20.sol";
import {IBurnMintERC20} from "@chainlink/contracts/src/v0.8/shared/token/ERC20/IBurnMintERC20.sol";
import {BurnMintTokenPool} from "@chainlink/contracts-ccip/contracts/pools/BurnMintTokenPool.sol";
import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/contracts/libraries/RateLimiter.sol";
import {Cfg, TokenNaming, IRegistryModuleOwnerCustom, ITokenAdminRegistry} from "./Config.sol";

/// @notice Add ONE more wrapped subnet token to an EXISTING spoke chain (Base). Unlike DeploySpoke
///         it does NOT deploy a SpokeGateway — the gateway is shared per chain and already exists.
///         Deploys token at the deployer's nonce N and pool at N+1 (CREATE = keccak(deployer, nonce)),
///         so the SAME fresh key at the SAME nonce yields the SAME token address on every chain.
/// Env: PRIVATE_KEY, NETUID, ADMIN (multisig), GUARDIAN (opt), EXPECT_TOKEN (same-address guard),
///      REMOTE_POOL / REMOTE_TOKEN (964 counterpart for the lane; skipped if unset)
contract DeploySpokeToken is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address admin = vm.envAddress("ADMIN");
        require(admin != address(0) && admin != deployer, "ADMIN must be the multisig");

        // Same-address guard: abort BEFORE any broadcast unless (deployer, nonce) reproduces EXPECT_TOKEN.
        require(
            vm.computeCreateAddress(deployer, vm.getNonce(deployer)) == vm.envAddress("EXPECT_TOKEN"),
            "ADDRESS GUARD: (deployer, nonce) would not produce EXPECT_TOKEN"
        );

        vm.startBroadcast(pk);
        BurnMintERC20 tok = new BurnMintERC20(
            TokenNaming.name(vm.envUint("NETUID")), TokenNaming.symbol(vm.envUint("NETUID")), Cfg.DECIMALS, 0, 0
        );
        require(address(tok) == vm.envAddress("EXPECT_TOKEN"), "deployed token != EXPECT_TOKEN");
        BurnMintTokenPool pool = new BurnMintTokenPool(
            IBurnMintERC20(address(tok)), Cfg.DECIMALS, new address[](0), Cfg.BASE_RMN_PROXY, Cfg.BASE_ROUTER
        );
        tok.grantMintAndBurnRoles(address(pool));

        IRegistryModuleOwnerCustom(Cfg.BASE_REGISTRY_MODULE).registerAdminViaGetCCIPAdmin(address(tok));
        ITokenAdminRegistry(Cfg.BASE_TOKEN_ADMIN_REGISTRY).acceptAdminRole(address(tok));
        ITokenAdminRegistry(Cfg.BASE_TOKEN_ADMIN_REGISTRY).setPool(address(tok), address(pool));
        pool.setRateLimitAdmin(vm.envOr("GUARDIAN", admin));

        _lane(pool);
        _handoff(tok, pool, admin, deployer);
        vm.stopBroadcast();

        require(!tok.hasRole(tok.DEFAULT_ADMIN_ROLE(), deployer), "deployer still token admin");
        require(!tok.hasRole(tok.MINTER_ROLE(), deployer), "deployer can still mint");
        console2.log("token:", address(tok));
        console2.log("pool: ", address(pool));
        console2.log("NEXT: multisig acceptAdminRole(token) + pool.acceptOwnership()");
    }

    /// @dev Lane to 964 while we still own the pool (after handoff only the multisig could).
    function _lane(BurnMintTokenPool pool) internal {
        address remotePool = vm.envOr("REMOTE_POOL", address(0));
        if (remotePool == address(0)) return;
        bytes[] memory rp = new bytes[](1);
        rp[0] = abi.encode(remotePool);
        TokenPool.ChainUpdate[] memory adds = new TokenPool.ChainUpdate[](1);
        adds[0] = TokenPool.ChainUpdate({
            remoteChainSelector: Cfg.SUB_SELECTOR,
            remotePoolAddresses: rp,
            remoteTokenAddress: abi.encode(vm.envAddress("REMOTE_TOKEN")),
            outboundRateLimiterConfig: RateLimiter.Config({isEnabled: true, capacity: Cfg.RL_CAPACITY, rate: Cfg.RL_RATE}),
            inboundRateLimiterConfig: RateLimiter.Config({isEnabled: true, capacity: Cfg.RL_CAPACITY, rate: Cfg.RL_RATE})
        });
        pool.applyChainUpdates(new uint64[](0), adds);
    }

    /// @dev Hand EVERY privilege to the multisig — DEFAULT_ADMIN can mint unbacked supply.
    function _handoff(BurnMintERC20 tok, BurnMintTokenPool pool, address admin, address deployer) internal {
        tok.setCCIPAdmin(admin);
        ITokenAdminRegistry(Cfg.BASE_TOKEN_ADMIN_REGISTRY).transferAdminRole(address(tok), admin);
        tok.grantRole(tok.DEFAULT_ADMIN_ROLE(), admin);
        tok.renounceRole(tok.DEFAULT_ADMIN_ROLE(), deployer);
        pool.transferOwnership(admin);
    }
}
