// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {BurnMintERC20} from "@chainlink/contracts/src/v0.8/shared/token/ERC20/BurnMintERC20.sol";
import {IBurnMintERC20} from "@chainlink/contracts/src/v0.8/shared/token/ERC20/IBurnMintERC20.sol";
import {BurnMintTokenPool} from "@chainlink/contracts-ccip/contracts/pools/BurnMintTokenPool.sol";
import {SpokeGateway} from "../src/SpokeGateway.sol";
import {Cfg, TokenNaming, IRegistryModuleOwnerCustom, ITokenAdminRegistry} from "./Config.sol";

/// @notice Deploys a SPOKE chain's side of the bridge: the wrapped token (BurnMintERC20), its
///         BurnMintTokenPool, and the shared SpokeGateway; grants mint/burn to the pool,
///         self-registers the CCIP token admin, attaches the pool, and hands off.
///         Chain-agnostic — the CCIP infra addresses default to Base but are env-overridable, so a
///         second spoke chain needs no code change.
///         Does NOT cross-link to the hub (run RegisterLane on BOTH chains afterwards).
///
/// Env:
///   PRIVATE_KEY       deployer key
///   HANDOFF           "true" for a production handoff: ADMIN is then REQUIRED and the deployer is
///                     asserted admin-free at the end (token DEFAULT_ADMIN renounced, pool ownership
///                     pending the multisig's acceptOwnership)
///   ADMIN             CCIP + token DEFAULT_ADMIN + pool owner recipient (multisig) — defaults to deployer
///   GUARDIAN          pool rateLimitAdmin (fast lane throttle) — defaults to ADMIN
///   SUBTENSOR_GATEWAY the 964 AlphaGateway address (receiver for the return leg) — required
///   NETUID                    which subnet this token represents — drives the derived name
///   TOKEN_NAME/TOKEN_SYMBOL   OPTIONAL override; default is derived from NETUID (see TokenNaming)
///   ROUTER / RMN_PROXY / TOKEN_ADMIN_REGISTRY / REGISTRY_MODULE
///                     this chain's CCIP infra — default to the Base values in Cfg
///
/// Run: forge script script/DeploySpoke.s.sol --rpc-url $SPOKE_RPC --broadcast
contract DeploySpoke is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        bool handoff = vm.envOr("HANDOFF", false);
        address admin = handoff ? vm.envAddress("ADMIN") : vm.envOr("ADMIN", deployer);
        address guardian = vm.envOr("GUARDIAN", admin);
        address subtensorGateway = vm.envAddress("SUBTENSOR_GATEWAY");

        // This chain's CCIP infrastructure. Defaults are Base; override to deploy another spoke.
        address router = vm.envOr("ROUTER", Cfg.BASE_ROUTER);
        address rmnProxy = vm.envOr("RMN_PROXY", Cfg.BASE_RMN_PROXY);
        address registry = vm.envOr("TOKEN_ADMIN_REGISTRY", Cfg.BASE_TOKEN_ADMIN_REGISTRY);
        address regModule = vm.envOr("REGISTRY_MODULE", Cfg.BASE_REGISTRY_MODULE);

        // Same-address guard: if EXPECT_TOKEN is set, this REVERTS before broadcasting a single tx
        // unless (deployer, nonce) is exactly the pair that produced EXPECT_TOKEN. See _guardPredicted.
        _guardPredicted(deployer);

        vm.startBroadcast(pk);

        // 1. the token — BurnMintERC20, 18 decimals, uncapped, no premint. Deployer gets DEFAULT_ADMIN_ROLE
        //    and becomes CCIP admin.
        BurnMintERC20 wtao = new BurnMintERC20(
            vm.envOr("TOKEN_NAME", TokenNaming.name(vm.envOr("NETUID", uint256(0)))),
            vm.envOr("TOKEN_SYMBOL", TokenNaming.symbol(vm.envOr("NETUID", uint256(0)))),
            Cfg.DECIMALS,
            0,
            0
        );

        // 2. BurnMintTokenPool.
        BurnMintTokenPool pool = new BurnMintTokenPool(
            IBurnMintERC20(address(wtao)),
            Cfg.DECIMALS,
            new address[](0),
            rmnProxy,
            router
        );

        // Belt-and-suspenders: the ACTUAL deployed addresses must equal the guarded expectation.
        _assertDeployed(address(wtao), address(pool));

        // 3. Grant mint/burn rights to the pool — the ONLY minter of the token.
        wtao.grantMintAndBurnRoles(address(pool));

        // 4. SpokeGateway (SHARED UX layer — one per chain; every wrapped asset rides through it,
        //    the token is a per-call parameter).
        // FEE_ADMIN is immutable in the gateway; the recipient is its starting value and can be
        // repointed later by that admin. Default both to the governance multisig. Read inline
        // rather than into locals: this function's stack is already at the limit.
        SpokeGateway gw = new SpokeGateway(
            router,
            Cfg.SUB_SELECTOR,
            subtensorGateway,
            vm.envOr("FEE_ADMIN", admin),
            vm.envOr("FEE_RECIPIENT", admin)
        );

        // 5. Self-register token admin via getCCIPAdmin, accept, attach pool.
        IRegistryModuleOwnerCustom(regModule).registerAdminViaGetCCIPAdmin(address(wtao));
        ITokenAdminRegistry(registry).acceptAdminRole(address(wtao));
        ITokenAdminRegistry(registry).setPool(address(wtao), address(pool));

        // 6. Guardian gets the pool's rateLimitAdmin (fast lane throttle), like the 964 side.
        pool.setRateLimitAdmin(guardian);

        // 7. Hand off EVERY privilege to the multisig in-script — the Base token's DEFAULT_ADMIN can
        //    grant mint/burn roles, i.e. mint unbacked supply that the 964 LockRelease pool would
        //    redeem for real backing. It must never linger on the hot deployer key.
        if (admin != deployer) {
            wtao.setCCIPAdmin(admin);
            ITokenAdminRegistry(registry).transferAdminRole(address(wtao), admin);
            // Token DEFAULT_ADMIN: grant to the multisig, renounce from the deployer (one-step
            // AccessControl on BurnMintERC20 — the grant lands atomically in this same tx batch).
            wtao.grantRole(wtao.DEFAULT_ADMIN_ROLE(), admin);
            wtao.renounceRole(wtao.DEFAULT_ADMIN_ROLE(), deployer);
            // Pool ownership -> multisig (2-step: multisig must acceptOwnership()).
            pool.transferOwnership(admin);
        }

        if (handoff) {
            require(!wtao.hasRole(wtao.DEFAULT_ADMIN_ROLE(), deployer), "handoff: deployer still token admin");
            require(wtao.hasRole(wtao.DEFAULT_ADMIN_ROLE(), admin), "handoff: multisig missing token admin");
            require(!wtao.hasRole(wtao.MINTER_ROLE(), deployer), "handoff: deployer can still mint");
        }

        vm.stopBroadcast();

        console2.log("== spoke chain ==");
        console2.log("token:         ", address(wtao));
        console2.log("BurnMintPool:  ", address(pool));
        console2.log("SpokeGateway:   ", address(gw));
        console2.log("Next: RegisterLane on BOTH chains, then VerifyWiring. See docs/DEPLOYMENT.md");
    }

    /// @dev Same-address guard, pre-broadcast. A CREATE address is keccak(deployer, nonce) — wholly
    ///      independent of bytecode/constructor args — so reproducing an existing token address on a
    ///      new chain requires the SAME deployer at the SAME nonce. If EXPECT_TOKEN is set, predict
    ///      where the token (nonce n) and pool (nonce n+1) WILL land and revert unless they match, so
    ///      a wrong key or a bumped nonce aborts before a single tx is broadcast rather than shipping
    ///      the token to an address that will never line up with the other chains.
    ///      Kept in its own frame so run()'s (already tight) stack is untouched.
    function _guardPredicted(address deployer) internal view {
        address expectToken = vm.envOr("EXPECT_TOKEN", address(0));
        if (expectToken == address(0)) return;
        uint64 n = vm.getNonce(deployer);
        address pred = vm.computeCreateAddress(deployer, n);
        require(
            pred == expectToken,
            string.concat(
                "ADDRESS GUARD: token would deploy at ", vm.toString(pred),
                " but EXPECT_TOKEN=", vm.toString(expectToken),
                " (deployer ", vm.toString(deployer), " is at nonce ", vm.toString(uint256(n)),
                " -- wrong key, or nonce != the one that produced EXPECT_TOKEN)"
            )
        );
        address expectPool = vm.envOr("EXPECT_POOL", address(0));
        if (expectPool != address(0)) {
            require(
                vm.computeCreateAddress(deployer, n + 1) == expectPool,
                "ADDRESS GUARD: pool (deployer nonce+1) would not match EXPECT_POOL"
            );
        }
    }

    /// @dev Post-deploy confirmation that the actual addresses equal the guarded expectation.
    function _assertDeployed(address token, address pool) internal view {
        address expectToken = vm.envOr("EXPECT_TOKEN", address(0));
        if (expectToken == address(0)) return;
        require(token == expectToken, "ADDRESS GUARD: deployed token != EXPECT_TOKEN");
        address expectPool = vm.envOr("EXPECT_POOL", address(0));
        if (expectPool != address(0)) {
            require(pool == expectPool, "ADDRESS GUARD: deployed pool != EXPECT_POOL");
        }
    }
}
