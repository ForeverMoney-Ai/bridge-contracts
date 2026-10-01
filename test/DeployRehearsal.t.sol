// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from
    "@chainlink/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {LockReleaseTokenPool} from "@chainlink/contracts-ccip/contracts/pools/LockReleaseTokenPool.sol";

import {AlphaVault} from "../src/AlphaVault.sol";
import {AlphaGateway} from "../src/AlphaGateway.sol";
import {AlphaToken} from "../src/AlphaToken.sol";
import {IStaking} from "../src/interfaces/IStaking.sol";
import {Cfg} from "../script/Config.sol";
import {MockStakingP} from "./mocks/MockStakingP.sol";
import {MockRouter} from "./mocks/MockRouter.sol";
import {MockRegistryModuleOwnerCustom, MockTokenAdminRegistry} from "./mocks/MockCCIPRegistry.sol";

/// @notice DEPLOYMENT REHEARSAL — runs the real 964 deploy sequence end to end against mocked
///         infrastructure, and asserts the end state a real deploy must reach.
///
///         This exists because the parts of a deployment most likely to be wrong are not the
///         contracts (those have 98 tests) but the ORDER and the HANDOFF: CCIP registration must
///         happen while the deployer is still the CCIP admin, the coldkey must match the predicted
///         address, and every privilege must end up pending on governance rather than left on a
///         hot key. Those are exactly the mistakes that cost real money to discover on mainnet.
///
///         What this CANNOT prove (needs a real Subtensor node — see docs/DEPLOYMENT.md):
///           - transferStakeFrom / moveStake semantics on the real 0x805
///           - whether removeStake credits via account mutation or an EVM call
///           - real CCIP fees, lane liveness, and maxNumberOfTokensPerMsg
contract DeployRehearsalTest is Test {
    MockStakingP staking;
    MockTokenAdminRegistry registry;
    MockRouter router;

    address deployer = makeAddr("deployer");
    address timelock = makeAddr("timelock");     // DEFAULT_ADMIN target
    address multisig = makeAddr("multisig");     // OPERATOR target
    address guardian = makeAddr("guardian");
    address emissions = makeAddr("emissions");

    bytes32 constant VALIDATOR = bytes32(uint256(0x5A11));
    uint256 constant NETUID = 0;

    AlphaVault vault;
    AlphaGateway gateway;
    AlphaToken token;
    LockReleaseTokenPool pool;

    function setUp() public {
        // Etch the mocked infrastructure at the EXACT addresses Config.sol names, so the rehearsal
        // exercises the real constants rather than a parallel set.
        staking = new MockStakingP();
        vm.etch(0x0000000000000000000000000000000000000805, address(staking).code);
        // vm.etch copies CODE, not STORAGE — the etched precompile starts with priceRao = 0, which
        // divides by zero on the first addStake. Immutables survive (they live in code); mutable
        // state does not, so it has to be re-initialised through the setters.
        MockStakingP(payable(0x0000000000000000000000000000000000000805)).setPrice(1e9);

        MockTokenAdminRegistry reg = new MockTokenAdminRegistry();
        vm.etch(Cfg.SUB_TOKEN_ADMIN_REGISTRY, address(reg).code);
        registry = MockTokenAdminRegistry(Cfg.SUB_TOKEN_ADMIN_REGISTRY);

        MockRegistryModuleOwnerCustom mod =
            new MockRegistryModuleOwnerCustom(Cfg.SUB_TOKEN_ADMIN_REGISTRY);
        vm.etch(Cfg.SUB_REGISTRY_MODULE, address(mod).code);
        // the module stores REGISTRY as an immutable, which lives in code — etching preserves it

        router = new MockRouter(0.001 ether);
        vm.etch(Cfg.SUB_ROUTER, address(router).code);

        vm.deal(deployer, 100 ether);
    }

    /// @dev The full run(), in the script's order, as the deployer.
    function _deploy() internal {
        vm.startPrank(deployer);

        // 1. predict the vault address so the coldkey can be derived off-chain, exactly as the
        //    script does. A stray tx that bumps the nonce must break this, not slip through.
        address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer));
        bytes32 coldkey = MockStakingP(payable(0x0000000000000000000000000000000000000805)).ck(predicted);

        vault = new AlphaVault(
            IStaking(0x0000000000000000000000000000000000000805), coldkey, emissions, deployer);
        require(address(vault) == predicted, "vault addr != predicted");

        // 2. shared gateway
        gateway = new AlphaGateway(Cfg.SUB_ROUTER, address(vault), Cfg.BASE_SELECTOR, timelock,
            bytes32(uint256(uint160(vm.computeCreateAddress(address(this), vm.getNonce(address(this)))))));

        // 3. token + pool, then CCIP registration. Listing is OPERATOR-gated, so the deployer
        //    grants itself OPERATOR for the duration of the deploy (revoked in step 4). The
        //    registration works because ccipAdmin still points at the deployer at this stage.
        vault.grantRole(vault.OPERATOR_ROLE(), deployer);
        token = AlphaToken(vault.createToken("TAO", "TAO", VALIDATOR, NETUID));
        pool = new LockReleaseTokenPool(
            IERC20(address(token)), Cfg.DECIMALS, new address[](0),
            Cfg.SUB_RMN_PROXY, false, Cfg.SUB_ROUTER);

        MockRegistryModuleOwnerCustom(Cfg.SUB_REGISTRY_MODULE).registerAdminViaGetCCIPAdmin(address(token));
        registry.acceptAdminRole(address(token));
        registry.setPool(address(token), address(pool));

        // 4. handoff. Registry admin + pool ownership go to the OPERATOR multisig, not the
        //    timelock — the same destination an operator-listed token reaches by itself, so
        //    custody of a token does not depend on when it was listed.
        pool.setRateLimitAdmin(guardian);
        registry.transferAdminRole(address(token), multisig);
        pool.transferOwnership(multisig);

        vault.grantRole(vault.OPERATOR_ROLE(), multisig);
        vault.grantRole(vault.GUARDIAN_ROLE(), guardian);
        // Listing is a fast-lane action, so the CCIP admin slot future tokens resolve to must be
        // the operator multisig — not the timelock, or registration would stall on the delay again.
        vault.setCcipAdmin(multisig);
        // the deployer's temporary OPERATOR goes back before root does
        vault.revokeRole(vault.OPERATOR_ROLE(), deployer);
        vault.beginDefaultAdminTransfer(timelock);

        vm.stopPrank();
    }

    // ------------------------------------------------------------------ the rehearsal

    function test_fullDeploySequence() public {
        _deploy();

        // token is live and bound to this vault
        assertTrue(vault.isListed(address(token)), "token not listed");
        assertEq(token.VAULT(), address(vault), "token bound to wrong vault");
        assertEq(vault.tokenForNetuid(NETUID), address(token), "netuid registry wrong");

        // CCIP can find a pool to lock from — without this the token cannot bridge at all
        assertEq(registry.getPool(address(token)), address(pool), "pool not attached");

        // gateway wiring
        assertEq(address(gateway.VAULT()), address(vault));
        assertTrue(gateway.allowedLane(Cfg.BASE_SELECTOR), "Base lane not seeded");

        console2.log("vault   ", address(vault));
        console2.log("gateway ", address(gateway));
        console2.log("token   ", address(token));
        console2.log("pool    ", address(pool));
    }

    /// @dev The single most expensive mistake available: finishing a deploy with privileges still
    ///      on the hot deployer key.
    function test_handoffLeavesNothingOnTheDeployer() public {
        _deploy();

        assertFalse(vault.hasRole(vault.OPERATOR_ROLE(), deployer), "deployer still OPERATOR");
        assertFalse(vault.hasRole(vault.GUARDIAN_ROLE(), deployer), "deployer still GUARDIAN");
        assertTrue(vault.hasRole(vault.OPERATOR_ROLE(), multisig));
        assertTrue(vault.hasRole(vault.GUARDIAN_ROLE(), guardian));

        // every transfer is 2-step: PENDING on governance, not yet effective
        (address pendingAdmin,) = vault.pendingDefaultAdmin();
        assertEq(pendingAdmin, timelock, "vault admin transfer not pending");
        assertEq(registry.getTokenConfig(address(token)).pendingAdministrator, multisig,
                 "registry admin transfer not pending to the operator");
        assertEq(pool.owner(), deployer, "pool owner should still be deployer until accept");

        // and the deployer is STILL DEFAULT_ADMIN until the timelock accepts — so the key cannot
        // be retired yet. This is the step most likely to be skipped.
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), deployer));
    }

    /// @dev Governance accepting completes the handoff and locks the deployer out.
    function test_governanceAcceptsCompleteTheHandoff() public {
        _deploy();

        vm.prank(multisig);
        registry.acceptAdminRole(address(token));
        assertEq(registry.getTokenConfig(address(token)).administrator, multisig);

        vm.prank(multisig);
        pool.acceptOwnership();
        assertEq(pool.owner(), multisig);

        // The invariant behind the script's ADMIN-without-OPERATOR guard: once a handoff has run,
        // the broadcasting key must retain NO token custody. Leaving registry admin on it would
        // leave `setPool` — the repoint-the-pool vector — on a hot key, which is the exact failure
        // a half-configured run (ADMIN named, OPERATOR left defaulting) used to produce silently.
        assertTrue(registry.getTokenConfig(address(token)).administrator != deployer,
                   "deployer kept registry admin");
        assertTrue(pool.owner() != deployer, "deployer kept pool ownership");

        vm.warp(block.timestamp + vault.INITIAL_ADMIN_DELAY() + 1);
        vm.prank(timelock);
        vault.acceptDefaultAdminTransfer();
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), timelock));
        assertFalse(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), deployer), "deployer kept root");
    }

    /// @dev The deployer is locked out of listing after the handoff — it holds neither OPERATOR nor
    ///      the ccipAdmin slot, so it can neither list a token nor claim its CCIP admin slot.
    function test_listingImpossibleFromTheDeployerAfterHandoff() public {
        _deploy();
        vm.warp(block.timestamp + vault.INITIAL_ADMIN_DELAY() + 1);
        vm.prank(timelock);
        vault.acceptDefaultAdminTransfer();

        // deployer can no longer list a token...
        vm.prank(deployer);
        vm.expectRevert();
        vault.createToken("Subnet 8", "SN8", bytes32(uint256(0xB0B2)), 8);

        // ...and even with a token in hand could not claim its CCIP admin slot
        vm.prank(multisig);
        address t2 = vault.createToken("Subnet 8", "SN8", bytes32(uint256(0xB0B2)), 8);
        vm.prank(deployer);
        vm.expectRevert();
        MockRegistryModuleOwnerCustom(Cfg.SUB_REGISTRY_MODULE).registerAdminViaGetCCIPAdmin(t2);
    }

    /// @dev THE POINT OF THE FAST LANE: after the handoff, the operator multisig completes an
    ///      entire token listing — vault listing, CCIP registration, admin accept, pool attach —
    ///      on its own, with no timelock queue anywhere in the path. If this ever starts requiring
    ///      the timelock again, listing has silently become a governance action.
    function test_operatorListsAndRegistersWithoutTheTimelock() public {
        _deploy();
        vm.warp(block.timestamp + vault.INITIAL_ADMIN_DELAY() + 1);
        vm.prank(timelock);
        vault.acceptDefaultAdminTransfer();

        vm.startPrank(multisig);

        address t2 = vault.createToken("Subnet 8", "SN8", bytes32(uint256(0xB0B2)), 8);
        assertTrue(vault.isListed(t2), "operator could not list");
        assertEq(AlphaToken(t2).getCCIPAdmin(), multisig, "ccipAdmin should resolve to the operator");

        LockReleaseTokenPool p2 = new LockReleaseTokenPool(
            IERC20(t2), Cfg.DECIMALS, new address[](0), Cfg.SUB_RMN_PROXY, false, Cfg.SUB_ROUTER);

        MockRegistryModuleOwnerCustom(Cfg.SUB_REGISTRY_MODULE).registerAdminViaGetCCIPAdmin(t2);
        registry.acceptAdminRole(t2);
        registry.setPool(t2, address(p2));

        vm.stopPrank();

        assertEq(registry.getPool(t2), address(p2), "pool not attached by the operator");
        assertEq(registry.getTokenConfig(t2).administrator, multisig, "operator is not registry admin");
    }

    /// @dev THE invariant behind making custody uniform: who holds `setPool` over a token must not
    ///      depend on WHEN it was listed. The deploy-time token and an operator-listed one must
    ///      land on the same administrator, or answering "who can repoint this pool?" during an
    ///      incident means checking each token's history.
    function test_registryAdminIsTheSameWhoeverListedTheToken() public {
        _deploy();

        // finish the deploy-time token's 2-step handoff
        vm.startPrank(multisig);
        registry.acceptAdminRole(address(token));

        address t2 = vault.createToken("Subnet 8", "SN8", bytes32(uint256(0xB0B2)), 8);
        MockRegistryModuleOwnerCustom(Cfg.SUB_REGISTRY_MODULE).registerAdminViaGetCCIPAdmin(t2);
        registry.acceptAdminRole(t2);
        vm.stopPrank();

        assertEq(
            registry.getTokenConfig(address(token)).administrator,
            registry.getTokenConfig(t2).administrator,
            "custody differs between the deploy-time token and a later one"
        );
        assertEq(registry.getTokenConfig(address(token)).administrator, multisig);
    }

    /// @dev `ccipAdmin` is the one part of the fast lane the slow tier still owns — the operator
    ///      must not be able to repoint who may claim CCIP admin over future tokens.
    function test_ccipAdminRepointableOnlyByRoot() public {
        _deploy();
        vm.warp(block.timestamp + vault.INITIAL_ADMIN_DELAY() + 1);
        vm.prank(timelock);
        vault.acceptDefaultAdminTransfer();

        vm.prank(multisig);
        vm.expectRevert();
        vault.setCcipAdmin(multisig);

        vm.prank(timelock);
        vault.setCcipAdmin(guardian);
        assertEq(vault.ccipAdmin(), guardian);
    }

    /// @dev A nonce bump between predicting the address and deploying must break the run, because
    ///      the coldkey was derived from the prediction. Silently shipping a vault whose coldkey
    ///      points elsewhere would make every deposit unmeasurable.
    function test_coldkeyPredictionCatchesNonceDrift() public {
        vm.startPrank(deployer);
        address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer));
        bytes32 coldkey = MockStakingP(payable(0x0000000000000000000000000000000000000805)).ck(predicted);

        new AlphaToken(address(0xBEEF), "stray", "stray");   // the stray tx

        AlphaVault v = new AlphaVault(
            IStaking(0x0000000000000000000000000000000000000805), coldkey, emissions, deployer);
        assertTrue(address(v) != predicted, "prediction should no longer hold");
        vm.stopPrank();
    }

    /// @dev End-to-end: a real deposit against the deployed stack mints measured backing.
    function test_deployedStackAcceptsADeposit() public {
        _deploy();
        vm.deal(address(this), 10 ether);
        uint256 minted = vault.depositLiquid{value: 1 ether}(address(token), 0);
        assertEq(minted, 1 ether, "root should mint 1:1");
        assertEq(vault.stakedValueRao(address(token)), 1e9, "backing not staked");
        uint256 stakedAlpha = vault.backing(address(token));
        assertGe(stakedAlpha, token.totalSupply(), "under-backed");
    }
}
