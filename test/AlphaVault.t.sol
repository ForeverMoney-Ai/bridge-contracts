// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AlphaVault} from "../src/AlphaVault.sol";
import {AlphaToken} from "../src/AlphaToken.sol";
import {IStaking} from "../src/interfaces/IStaking.sol";
import {MockStakingP} from "./mocks/MockStakingP.sol";

contract AlphaVaultTest is Test {
    MockStakingP staking;
    AlphaVault vault;
    AlphaToken wtao; // netuid 0, VAL

    bytes32 constant VAL = bytes32(uint256(0x5A11));
    bytes32 constant VAL2 = bytes32(uint256(0xB0B2));
    address recipient = makeAddr("recipient");
    address alice = makeAddr("alice");
    address owner = address(this);

    uint256 constant RAO = 1e9;

    event Halted(address indexed by, uint256 until);
    event Unhalted(address indexed by);
    event CcipAdminChanged(address indexed to);

    function setUp() public {
        staking = new MockStakingP();
        // coldkey is immutable — compute it from the deterministic deploy address up front
        bytes32 ck = staking.ck(vm.computeCreateAddress(address(this), vm.getNonce(address(this))));
        vault = new AlphaVault(IStaking(address(staking)), ck, recipient, owner);
        wtao = new AlphaToken(address(vault), "TAO", "TAO");
        // owner (this test contract) is DEFAULT_ADMIN; grant itself OPERATOR + GUARDIAN too.
        // OPERATOR must come BEFORE the first listing — createToken/addToken are fast-lane now.
        vault.grantRole(vault.OPERATOR_ROLE(), owner);
        vault.grantRole(vault.GUARDIAN_ROLE(), owner);
        vault.addToken(address(wtao), VAL, 0);
        vm.deal(alice, 100 ether);
    }

    receive() external payable {}

    function _vaultCk() internal view returns (bytes32) {
        return staking.ck(address(vault));
    }

    function _assertBacked(AlphaToken t) internal view {
        assertGe(vault.backing(address(t)), t.totalSupply(), "under-backed");
    }

    /// second token: netuid 8 on VAL2
    function _mkSubnet() internal returns (AlphaToken t) {
        t = new AlphaToken(address(vault), "Subnet 8", "SN8");
        vault.addToken(address(t), VAL2, 8);
    }

    // ---------------------------------------------------------- registry

    // one-call listing: the vault deploys AND lists the token atomically
    function test_createToken_deploysAndLists() public {
        address t = vault.createToken("Subnet 42", "SN42", VAL2, 42);
        assertTrue(vault.isListed(t));
        assertEq(AlphaToken(t).VAULT(), address(vault)); // bound to this vault by construction
        assertEq(AlphaToken(t).symbol(), "SN42");
        (bytes32 v, uint256 n) = vault.positionOf(t);
        assertEq(v, VAL2);
        assertEq(n, 42);
        // fully functional immediately
        vault.depositLiquid{value: 1 ether}(t, 0);
        assertEq(AlphaToken(t).totalSupply(), 1 ether);

        // same guards as addToken: netuid already taken + role gating
        vm.expectRevert(abi.encodeWithSelector(AlphaVault.NetuidTaken.selector, uint256(42), t));
        vault.createToken("dup", "dup", VAL2, 42);
        vm.prank(alice);
        vm.expectRevert();
        vault.createToken("x", "x", VAL2, 43);
    }

    function test_addToken_guards() public {
        AlphaToken t = new AlphaToken(address(vault), "x", "x");
        // duplicate listing
        vm.expectRevert(AlphaVault.AlreadyListed.selector);
        vault.addToken(address(wtao), VAL2, 1);
        // netuid 0 already taken by wtao
        vm.expectRevert(abi.encodeWithSelector(AlphaVault.NetuidTaken.selector, uint256(0), address(wtao)));
        vault.addToken(address(t), VAL, 0);
        // token bound to a different vault
        AlphaToken foreign = new AlphaToken(address(0xDEAD), "y", "y");
        vm.expectRevert(AlphaVault.WrongVault.selector);
        vault.addToken(address(foreign), VAL2, 1);
        // only OPERATOR lists
        vm.prank(alice);
        vm.expectRevert();
        vault.addToken(address(t), VAL2, 1);
        // valid listing works
        vault.addToken(address(t), VAL2, 1);
        assertTrue(vault.isListed(address(t)));
    }

    function test_ccipAdmin_defaultsToAdminAndIsRootOnly() public {
        // must never start at zero — getCCIPAdmin() returning zero would brick CCIP registration
        assertEq(vault.ccipAdmin(), owner, "ccipAdmin should default to the deploy admin");
        assertEq(wtao.getCCIPAdmin(), owner, "token should mirror the vault's ccipAdmin");

        vm.expectRevert(AlphaVault.ZeroAddress.selector);
        vault.setCcipAdmin(address(0));

        // OPERATOR is not enough — repointing this is the slow tier's call
        vault.grantRole(vault.OPERATOR_ROLE(), alice);
        vm.prank(alice);
        vm.expectRevert();
        vault.setCcipAdmin(alice);

        vm.expectEmit(true, false, false, true);
        emit CcipAdminChanged(alice);
        vault.setCcipAdmin(alice);
        assertEq(wtao.getCCIPAdmin(), alice, "token did not follow the repoint");
    }

    function test_unlistedToken_allRoutesRevert() public {
        AlphaToken t = new AlphaToken(address(vault), "x", "x"); // NOT listed
        vm.expectRevert(AlphaVault.UnknownToken.selector);
        vault.depositLiquid{value: 1 ether}(address(t), 0);
        vm.expectRevert(AlphaVault.UnknownToken.selector);
        vault.depositStaked(address(t), 1e9);
        vm.expectRevert(AlphaVault.UnknownToken.selector);
        vault.withdrawLiquid(address(t), 1 ether, 0);
        vm.expectRevert(AlphaVault.UnknownToken.selector);
        vault.withdrawStaked(address(t), 1 ether, bytes32(uint256(1)));
        vm.expectRevert(AlphaVault.UnknownToken.selector);
        vault.skim(address(t), 0);
    }

    function test_onlyVaultCanMintBurn() public {
        vm.expectRevert(AlphaToken.OnlyVault.selector);
        wtao.mint(alice, 1 ether);
        vm.expectRevert(AlphaToken.OnlyVault.selector);
        wtao.burn(alice, 1 ether);
    }

    // ---------------------------------------------------------- multi-token isolation

    function test_multiToken_positionsIsolated() public {
        AlphaToken w8 = _mkSubnet();
        vault.depositLiquid{value: 1 ether}(address(wtao), 0);
        vault.depositLiquid{value: 2 ether}(address(w8), 0);

        assertEq(vault.stakedValueRao(address(wtao)), 1e9);
        assertEq(vault.stakedValueRao(address(w8)), 2e9);
        assertEq(wtao.totalSupply(), 1 ether);
        assertEq(w8.totalSupply(), 2 ether);

        // fully exiting one token does not touch the other's position
        vault.withdrawLiquid(address(wtao), 1 ether, 0);
        assertEq(vault.stakedValueRao(address(wtao)), 0);
        assertEq(vault.stakedValueRao(address(w8)), 2e9);
        assertEq(w8.totalSupply(), 2 ether);
        _assertBacked(w8);
    }

    /// The vault holds no native between transactions, so anything resting in it is untracked
    /// by construction and fully sweepable. Backing is the staked position and is untouched.
    function test_sweepExcess_takesForcedBalance_notBacking() public {
        vault.depositLiquid{value: 1 ether}(address(wtao), 0);
        assertEq(address(vault).balance, 0, "deposit must leave no resting native");
        vm.deal(address(vault), 0.5 ether); // forced balance (selfdestruct-style)

        uint256 before = recipient.balance;
        uint256 swept = vault.sweepExcess();
        assertEq(swept, 0.5 ether);
        assertEq(recipient.balance - before, 0.5 ether);
        assertEq(vault.stakedValueRao(address(wtao)), 1e9, "sweep must not touch the position");
        _assertBacked(wtao);

        vm.expectRevert(AlphaVault.ZeroAmount.selector);
        vault.sweepExcess(); // nothing untracked left
    }

    // ---------------------------------------------------------- liquid deposit

    function test_depositLiquid_mintsMeasured_root() public {
        uint256 minted = vault.depositLiquid{value: 1 ether}(address(wtao), 1e9);
        assertEq(minted, 1 ether);
        assertEq(vault.stakedValueRao(address(wtao)), 1e9);
        _assertBacked(wtao);
    }

    function test_depositLiquid_feeBorneByDepositor() public {
        staking.setFee(10); // 0.1%
        uint256 minted = vault.depositLiquid{value: 1 ether}(address(wtao), 0.998e9);
        assertEq(minted, 0.999 ether);
        _assertBacked(wtao);
    }

    function test_depositLiquid_slippageRevert() public {
        staking.setFee(100); // 1%
        vm.expectRevert(AlphaVault.Slippage.selector);
        vault.depositLiquid{value: 1 ether}(address(wtao), 1e9); // demands full, gets 0.99e9
    }

    function test_depositLiquid_subnetPrice() public {
        AlphaToken w8 = _mkSubnet();
        staking.setPrice(2e9);
        uint256 minted = vault.depositLiquid{value: 1 ether}(address(w8), 0.5e9);
        assertEq(minted, 0.5 ether); // 1 TAO buys 0.5 alpha
    }

    function test_depositLiquid_belowMin_reverts() public {
        vm.expectRevert("AmountTooLow");
        vault.depositLiquid{value: 0.001 ether}(address(wtao), 0); // below 0.002 min stake
    }

    function test_depositLiquid_guards() public {
        vm.expectRevert(AlphaVault.ZeroAmount.selector);
        vault.depositLiquid{value: 0}(address(wtao), 0);
        vm.expectRevert(AlphaVault.NotWholeRao.selector);
        vault.depositLiquid{value: 1 ether + 1}(address(wtao), 0);
    }

    // a plain native send is a user mistake — it bounces instead of becoming a silent donation
    function test_rawSendReverts() public {
        (bool ok, ) = address(vault).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(wtao.totalSupply(), 0);
        assertEq(address(vault).balance, 0);
    }

    // ...but the unstake window accepts a precompile credit delivered as an EVM value transfer, so
    // redemptions do not depend on HOW 0x805 credits (direct substrate mutation vs a CALL).
    function test_unstakeWindow_acceptsCreditViaEvmCall() public {
        vault.depositLiquid{value: 1 ether}(address(wtao), 0);
        staking.setCreditViaCall(true); // mock now credits by calling the vault, hitting receive()

        uint256 before = owner.balance;
        uint256 got = vault.withdrawLiquid(address(wtao), 1 ether, 1e18); // must still work
        assertEq(got, 1 ether);
        assertEq(owner.balance - before, 1 ether);
        assertEq(wtao.totalSupply(), 0);

        // the window is shut again afterwards — plain sends still bounce
        (bool ok, ) = address(vault).call{value: 1 ether}("");
        assertFalse(ok);
    }

    // ---------------------------------------------------------- staked deposit

    function test_depositStaked_zeroSlippage_evenWithAmmFee() public {
        staking.setFee(100);
        staking.seed(VAL, alice, 0, 5e9);
        vm.startPrank(alice);
        staking.approve(address(vault), 0, 5e9);
        uint256 minted = vault.depositStaked(address(wtao), 5e9);
        vm.stopPrank();
        assertEq(minted, 5 ether); // exact 1:1 despite fee
        assertEq(vault.stakedValueRao(address(wtao)), 5e9);
        _assertBacked(wtao);
    }

    function test_depositStaked_requiresAllowance() public {
        staking.seed(VAL, alice, 0, 5e9);
        vm.prank(alice);
        vm.expectRevert("allowance");
        vault.depositStaked(address(wtao), 5e9);
    }

    // ---------------------------------------------------------- liquid withdraw

    function test_withdrawLiquid_paysMeasured() public {
        vault.depositLiquid{value: 1 ether}(address(wtao), 0);
        uint256 before = owner.balance;
        uint256 got = vault.withdrawLiquid(address(wtao), 0.4 ether, 0.4e18);
        assertEq(got, 0.4 ether);
        assertEq(owner.balance - before, 0.4 ether);
        assertEq(wtao.totalSupply(), 0.6 ether);
        _assertBacked(wtao);
    }

    function test_withdrawLiquid_feeBorneByWithdrawer() public {
        vault.depositLiquid{value: 1 ether}(address(wtao), 0);
        staking.setFee(10);
        uint256 got = vault.withdrawLiquid(address(wtao), 1 ether, 0.998e18);
        assertEq(got, 0.999 ether);
        _assertBacked(wtao);
    }

    // withdrawing more than the caller holds reverts with the vault's explicit error (with amounts)
    function test_withdraw_insufficientBalance_explicitRevert() public {
        vault.depositLiquid{value: 1 ether}(address(wtao), 0); // owner holds 1 wTAO
        vm.expectRevert(
            abi.encodeWithSelector(AlphaVault.InsufficientBalance.selector, 1 ether, 2 ether)
        );
        vault.withdrawLiquid(address(wtao), 2 ether, 0);
        vm.expectRevert(
            abi.encodeWithSelector(AlphaVault.InsufficientBalance.selector, 1 ether, 2 ether)
        );
        vault.withdrawStaked(address(wtao), 2 ether, bytes32(uint256(0xC01D)));
        // a caller with NO balance gets the same clear error
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AlphaVault.InsufficientBalance.selector, 0, 1 ether));
        vault.withdrawLiquid(address(wtao), 1 ether, 0);
    }

    function test_withdrawLiquid_slippageRevert() public {
        vault.depositLiquid{value: 1 ether}(address(wtao), 0);
        staking.setFee(100);
        vm.expectRevert(AlphaVault.Slippage.selector);
        vault.withdrawLiquid(address(wtao), 1 ether, 1e18); // demands full, gets 0.99
    }

    // ---------------------------------------------------------- staked withdraw

    function test_withdrawStaked_toAnyColdkey_zeroSlippage() public {
        vault.depositLiquid{value: 1 ether}(address(wtao), 0);
        bytes32 nativeColdkey = bytes32(uint256(0xC01D));
        vault.withdrawStaked(address(wtao), 1 ether, nativeColdkey);
        assertEq(wtao.totalSupply(), 0);
        assertEq(staking.getStake(VAL, nativeColdkey, 0), 1e9); // delivered, still staked
    }

    function test_roundTrip_stakedRoutes_exact() public {
        staking.setFee(50); // hostile fee active throughout
        staking.seed(VAL, alice, 0, 3e9);
        vm.startPrank(alice);
        staking.approve(address(vault), 0, 3e9);
        vault.depositStaked(address(wtao), 3e9);
        vault.withdrawStaked(address(wtao), 3 ether, staking.ck(alice));
        vm.stopPrank();
        assertEq(staking.getStake(VAL, staking.ck(alice), 0), 3e9); // alpha-in == alpha-out exactly
    }

    // ---------------------------------------------------------- emissions

    function test_skim_nativeToRecipient() public {
        vault.depositLiquid{value: 1 ether}(address(wtao), 0);
        staking.accrue(VAL, _vaultCk(), 0, 0.1e9); // +0.1 alpha emissions
        uint256 before = recipient.balance;
        uint256 got = vault.skim(address(wtao), 0.09e18);
        assertApproxEqAbs(got, 0.1 ether, 1e15);
        assertEq(recipient.balance - before, got);
        assertEq(wtao.totalSupply(), 1 ether); // peg untouched
        _assertBacked(wtao);
    }

    function test_skimStaked_zeroSlippage_operatorOnly() public {
        vault.depositLiquid{value: 1 ether}(address(wtao), 0);
        staking.accrue(VAL, _vaultCk(), 0, 0.1e9);
        bytes32 dest = bytes32(uint256(0xFEE));
        uint256 got = vault.skimStaked(address(wtao), dest);
        assertApproxEqAbs(got, 0.1e9, 1e6);
        assertEq(staking.getStake(VAL, dest, 0), got);

        vm.prank(alice);
        vm.expectRevert();
        vault.skimStaked(address(wtao), dest);
    }

    // skimStaked is gated by the full halt, same as skim — emissions cannot leave during a freeze
    function test_skimStaked_revertsWhileHalted() public {
        vault.depositLiquid{value: 1 ether}(address(wtao), 0);
        staking.accrue(VAL, _vaultCk(), 0, 0.1e9);
        vault.guardianPause(1 days); // owner holds GUARDIAN in this suite's setUp
        vm.expectRevert(AlphaVault.IsHalted.selector);
        vault.skimStaked(address(wtao), bytes32(uint256(0xFEE)));
        vault.unpause(); // OPERATOR
        vault.skimStaked(address(wtao), bytes32(uint256(0xFEE))); // works once lifted
    }

    function test_skim_noSurplus_reverts() public {
        vault.depositLiquid{value: 1 ether}(address(wtao), 0);
        vm.expectRevert(AlphaVault.NothingToSkim.selector);
        vault.skim(address(wtao), 0);
    }

    // the #8 fix: liquid TAO on a high-price subnet is NOT phantom-harvestable
    function test_skim_ignoresLiquid_noPhantomSurplusOnSubnet() public {
        AlphaToken w8 = _mkSubnet();
        staking.setPrice(2e9); // 1 alpha = 2 TAO
        vault.depositLiquid{value: 2 ether}(address(w8), 0); // stakes 2 TAO -> 1 alpha, mints 1e18
        assertEq(vault.stakedValueRao(address(w8)), 1e9);
        // supply == staked, so there is no surplus to harvest at any alpha price
        assertEq(vault.harvestableAlphaRao(address(w8)), 0);
        vm.expectRevert(AlphaVault.NothingToSkim.selector);
        vault.skim(address(w8), 0);
    }

    // per-token emissions: each token's surplus is measured on its OWN position
    function test_skim_perTokenSurplus() public {
        AlphaToken w8 = _mkSubnet();
        vault.depositLiquid{value: 1 ether}(address(wtao), 0);
        vault.depositLiquid{value: 1 ether}(address(w8), 0);
        staking.accrue(VAL, _vaultCk(), 0, 0.1e9); // only wtao's position earns

        assertGt(vault.harvestableAlphaRao(address(wtao)), 0);
        assertEq(vault.harvestableAlphaRao(address(w8)), 0);
        vm.expectRevert(AlphaVault.NothingToSkim.selector);
        vault.skim(address(w8), 0);
        vault.skim(address(wtao), 0.09e18); // works for the earning token
    }

    // ---------------------------------------------------------- admin

    function test_migrateValidator_movesFullStake_readableUnderNew() public {
        vault.depositLiquid{value: 1 ether}(address(wtao), 0);
        assertEq(staking.getStake(VAL, _vaultCk(), 0), 1e9); // under old hotkey
        vault.migrateValidator(address(wtao), VAL2);
        (bytes32 v, ) = vault.positionOf(address(wtao));
        assertEq(v, VAL2);
        assertEq(staking.getStake(VAL, _vaultCk(), 0), 0); // nothing stranded on old
        assertEq(staking.getStake(VAL2, _vaultCk(), 0), 1e9); // fully under new
        assertEq(vault.stakedValueRao(address(wtao)), 1e9); // reads correctly post-migration
        // the netuid registry is unaffected by a validator change — it is keyed on netuid alone
        assertEq(vault.tokenForNetuid(0), address(wtao));
        _assertBacked(wtao);
    }

    // ONE token per subnet: a second listing for the same netuid is rejected even with a DIFFERENT
    // validator (the old guard was on (validator, netuid), which let two tokens share a subnet).
    function test_oneTokenPerNetuid_differentValidatorStillRejected() public {
        AlphaToken w8 = _mkSubnet(); // VAL2, netuid 8
        AlphaToken dup = new AlphaToken(address(vault), "Subnet 8 dup", "SN8b");
        vm.expectRevert(abi.encodeWithSelector(AlphaVault.NetuidTaken.selector, uint256(8), address(w8)));
        vault.addToken(address(dup), VAL, 8); // same subnet, different validator
        assertEq(vault.tokenForNetuid(8), address(w8)); // registry unchanged

        // ...and the same subnet stays claimed after that token migrates validator
        vault.migrateValidator(address(w8), VAL);
        vm.expectRevert(abi.encodeWithSelector(AlphaVault.NetuidTaken.selector, uint256(8), address(w8)));
        vault.addToken(address(dup), VAL2, 8);
    }

    // two tokens on DIFFERENT netuids may share a validator — stake is keyed by netuid too
    function test_differentNetuidsMayShareValidator() public {
        AlphaToken a = new AlphaToken(address(vault), "Subnet 1", "SN1");
        AlphaToken b = new AlphaToken(address(vault), "Subnet 2", "SN2");
        vault.addToken(address(a), VAL2, 1);
        vault.addToken(address(b), VAL2, 2); // same validator, different subnet: allowed
        vault.depositLiquid{value: 1 ether}(address(a), 0);
        vault.depositLiquid{value: 2 ether}(address(b), 0);
        assertEq(vault.stakedValueRao(address(a)), 1e9); // positions stay separate
        assertEq(vault.stakedValueRao(address(b)), 2e9);
    }

    /// A redemption the position cannot cover reverts rather than paying out of anything else.
    /// There is no buffer, so this is the only possible behaviour — pin it.
    function test_withdrawLiquid_revertsWhenPositionShort() public {
        vault.depositLiquid{value: 1 ether}(address(wtao), 0);
        staking.shrink(VAL, _vaultCk(), 0, 0.4e9); // position drops below supply
        vm.expectRevert(AlphaVault.Insolvent.selector);
        vault.withdrawLiquid(address(wtao), 1 ether, 0);
        assertEq(wtao.totalSupply(), 1e18, "burn must roll back");
    }

    // an account with no roles reverts on every gated function
    function test_roleGating_noRoleReverts() public {
        vm.startPrank(alice);
        vm.expectRevert();
        vault.setEmissionsRecipient(alice); // DEFAULT_ADMIN
        vm.expectRevert();
        vault.addToken(address(1), VAL2, 1); // DEFAULT_ADMIN
        vm.expectRevert();
        vault.migrateValidator(address(wtao), VAL2); // OPERATOR
        vm.expectRevert();
        vault.setSkimMargin(address(wtao), 1); // OPERATOR
        vm.expectRevert();
        vault.skimStaked(address(wtao), bytes32(uint256(1))); // OPERATOR
        vm.expectRevert();
        vault.sweepExcess(); // OPERATOR
        vm.expectRevert();
        vault.guardianPause(1 hours); // GUARDIAN
        vm.expectRevert();
        vault.unpause(); // OPERATOR
        vm.expectRevert();
        vault.adminHold(1); // OPERATOR
        vm.stopPrank();
    }

    // DEFAULT_ADMIN and OPERATOR are distinct capability sets: neither can do the other's actions.
    function test_roleSeparation_adminVsOperator() public {
        address opOnly = makeAddr("opOnly");
        vault.grantRole(vault.OPERATOR_ROLE(), opOnly);

        // operator can migrate the validator, but cannot reroute emissions
        vm.prank(opOnly);
        vault.migrateValidator(address(wtao), VAL2);
        vm.prank(opOnly);
        vm.expectRevert();
        vault.setEmissionsRecipient(opOnly);

        // the DEFAULT_ADMIN (owner) can reroute emissions; once it drops OPERATOR it cannot operate.
        vault.setEmissionsRecipient(owner);
        vault.renounceRole(vault.OPERATOR_ROLE(), owner);
        vm.expectRevert();
        vault.migrateValidator(address(wtao), VAL);
    }

    // grantRole cannot mint a second DEFAULT_ADMIN — rotation is 2-step via beginDefaultAdminTransfer
    function test_defaultAdminCannotBeGrantedDirectly() public {
        bytes32 adminRole = vault.DEFAULT_ADMIN_ROLE();
        address adminOnly = makeAddr("adminOnly");
        vm.expectRevert();
        vault.grantRole(adminRole, adminOnly);
    }

    // the CCT admin-discovery hook lives on each token and tracks the vault's DEFAULT_ADMIN
    function test_getCCIPAdmin_onToken_tracksVaultOwner() public view {
        assertEq(wtao.getCCIPAdmin(), vault.owner());
        assertEq(wtao.getCCIPAdmin(), owner);
    }

    function test_constructorRejectsZeroColdkey() public {
        vm.expectRevert(AlphaVault.ZeroValidator.selector); // zero coldkey shares the guard
        new AlphaVault(IStaking(address(staking)), bytes32(0), recipient, owner);
    }

    // ---------------------------------------------------------- emergency full-halt (global)

    function test_guardianPause_haltsAllRoutes_allTokens() public {
        AlphaToken w8 = _mkSubnet();
        vault.depositLiquid{value: 1 ether}(address(wtao), 0); // supply to withdraw later
        staking.seed(VAL, alice, 0, 5e9);
        vm.prank(alice);
        staking.approve(address(vault), 0, 5e9);

        vault.guardianPause(1 days);
        assertTrue(vault.isPaused());

        vm.expectRevert(AlphaVault.IsHalted.selector);
        vault.depositLiquid{value: 1 ether}(address(wtao), 0);
        vm.prank(alice);
        vm.expectRevert(AlphaVault.IsHalted.selector);
        vault.depositStaked(address(wtao), 1e9);
        vm.expectRevert(AlphaVault.IsHalted.selector);
        vault.withdrawLiquid(address(wtao), 0.1 ether, 0);
        vm.expectRevert(AlphaVault.IsHalted.selector);
        vault.withdrawStaked(address(wtao), 0.1 ether, bytes32(uint256(1)));
        vm.expectRevert(AlphaVault.IsHalted.selector);
        vault.skim(address(wtao), 0);
        // the halt is GLOBAL: the other token is frozen too
        vm.expectRevert(AlphaVault.IsHalted.selector);
        vault.depositLiquid{value: 1 ether}(address(w8), 0);
    }

    function test_pauseAutoExpires() public {
        vault.guardianPause(1 days);
        assertTrue(vault.isPaused());
        vm.warp(block.timestamp + 1 days + 1);
        assertFalse(vault.isPaused());
        vault.depositLiquid{value: 1 ether}(address(wtao), 0); // works again, no unpause tx needed
        assertEq(wtao.totalSupply(), 1 ether);
    }

    function test_guardianCannotExceedMaxPause() public {
        vm.expectRevert(AlphaVault.PauseCapExceeded.selector);
        vault.guardianPause(3 days); // > MAX_PAUSE (2 days)
    }

    function test_cooldownBlocksImmediateRepause() public {
        vault.guardianPause(1 days);
        vm.warp(block.timestamp + 1 days + 1); // pause expired, but still in cooldown
        vm.expectRevert(AlphaVault.PauseCooldown.selector);
        vault.guardianPause(1 hours);
        vm.warp(block.timestamp + 12 hours); // cooldown elapsed
        vault.guardianPause(1 hours); // now allowed
        assertTrue(vault.isPaused());
    }

    function test_operatorUnpauseEarly() public {
        vault.guardianPause(1 days);
        vault.unpause(); // owner has OPERATOR
        assertFalse(vault.isPaused());
        vault.depositLiquid{value: 1 ether}(address(wtao), 0);
    }

    function test_operatorAdminHoldExceedsCap() public {
        vault.adminHold(block.timestamp + 10 days); // beyond MAX_PAUSE, OPERATOR override
        assertTrue(vault.isPaused());
    }

    function test_guardianCannotUnpause() public {
        address guardianOnly = makeAddr("guardianOnly");
        vault.grantRole(vault.GUARDIAN_ROLE(), guardianOnly);
        vm.prank(guardianOnly);
        vault.guardianPause(1 days); // can pause
        vm.prank(guardianOnly);
        vm.expectRevert();
        vault.unpause(); // cannot unpause (needs OPERATOR)
    }

    // guardianPause is extend-only: a guardian cannot shorten (≈ cancel) an OPERATOR adminHold
    function test_guardianCannotShortenAdminHold() public {
        address guardianOnly = makeAddr("guardianOnly");
        vault.grantRole(vault.GUARDIAN_ROLE(), guardianOnly);

        uint256 heldUntil = block.timestamp + 10 days;
        vault.adminHold(heldUntil); // OPERATOR (owner) freezes for 10 days

        vm.prank(guardianOnly);
        vault.guardianPause(1); // tries to rewrite the hold down to ~1s
        assertEq(vault.pausedUntil(), heldUntil); // unchanged: not shortened
        vm.warp(block.timestamp + 2 days);
        assertTrue(vault.isPaused()); // the operator's freeze still stands
    }

    // an early OPERATOR unpause re-anchors the guardian cooldown to the actual end, not the schedule
    function test_unpauseReanchorsGuardianCooldown() public {
        address guardianOnly = makeAddr("guardianOnly");
        vault.grantRole(vault.GUARDIAN_ROLE(), guardianOnly);

        vm.prank(guardianOnly);
        vault.guardianPause(2 days); // false alarm, max window
        vault.unpause(); // OPERATOR lifts almost immediately

        // cooldown is COOLDOWN from the lift (~12h), NOT 2 days + 12h from the scheduled expiry
        vm.warp(block.timestamp + 12 hours + 1);
        vm.prank(guardianOnly);
        vault.guardianPause(1 hours); // allowed again
        assertTrue(vault.isPaused());
    }

    // shortening a halt via adminHold re-anchors the guardian cooldown to the new (earlier) end
    function test_adminHoldShortenReanchorsGuardianCooldown() public {
        address guardianOnly = makeAddr("guardianOnly");
        vault.grantRole(vault.GUARDIAN_ROLE(), guardianOnly);

        vm.prank(guardianOnly);
        vault.guardianPause(2 days); // pausedUntil = T+2d, cooldown -> T+2d+12h
        vault.adminHold(block.timestamp + 6 hours); // OPERATOR shortens the halt to T+6h

        vm.warp(block.timestamp + 6 hours + 12 hours + 1); // past the new end + cooldown
        assertFalse(vault.isPaused()); // halt ended at T+6h, not T+2d
        vm.prank(guardianOnly);
        vault.guardianPause(1 hours); // cooldown re-anchored, so re-pause is allowed
        assertTrue(vault.isPaused());
    }

    // adminHold(0) lifts the halt and emits Unhalted (not Halted), so the event stream stays truthful
    function test_adminHoldZeroLiftsAndEmitsUnhalted() public {
        vault.adminHold(block.timestamp + 1 days);
        assertTrue(vault.isPaused());

        vm.expectEmit(true, false, false, false, address(vault));
        emit Unhalted(owner);
        vault.adminHold(0); // OPERATOR lifts via adminHold(0)
        assertFalse(vault.isPaused());
    }

    // ---------------------------------------------------------- invariant fuzz

    /// backing must never fall below supply across arbitrary deposit/withdraw sequences.
    function testFuzz_backingGeSupply(uint96 d1, uint96 d2, uint96 w1) public {
        // BOUND, do not assume. vm.assume THROWS AWAY the run, and a uint96 lands inside
        // [0.01, 50] ether only about one time in 1.6e9 -- so at high run counts the fuzzer fails
        // on rejection-rate long before the invariant is ever meaningfully exercised. Mapping the
        // input into range instead means every run tests something.
        uint256 a = bound(uint256(d1), 0.01 ether, 50 ether) / RAO * RAO; // whole-RAO
        uint256 b = bound(uint256(d2), 0.01 ether, 50 ether) / RAO * RAO;
        vm.deal(owner, 200 ether);

        vault.depositLiquid{value: a}(address(wtao), 0);
        vault.depositLiquid{value: b}(address(wtao), 0);
        _assertBacked(wtao);

        uint256 sup = wtao.totalSupply();
        uint256 wd = (uint256(w1) % (sup + 1)) / RAO * RAO; // whole-RAO, <= supply
        if (wd >= RAO) {
            vault.withdrawLiquid(address(wtao), wd, 0);
            _assertBacked(wtao);
        }
    }

    /// skim SELLS the surplus and takes minTaoOut from its caller. Permissionless, a stranger
    /// could pass 0 and dump protocol revenue into a sandwich. The destination being hard-wired
    /// does not help: it bounds who gets paid, not what the sale fetches.
    function test_skimIsOperatorOnly() public {
        vault.depositLiquid{value: 10 ether}(address(wtao), 0);
        staking.accrue(VAL, _vaultCk(), 0, 5 * RAO); // surplus over supply

        address stranger_ = makeAddr("stranger_");
        vm.prank(stranger_);
        vm.expectRevert();
        vault.skim(address(wtao), 0);

        assertGt(vault.skim(address(wtao), 0), 0, "operator still can");
    }

    /// The runtime addresses subnets as uint16, so a larger netuid cannot name a real subnet and
    /// would list a token whose position can never exist.
    function test_listingRejectsAnOutOfRangeNetuid() public {
        AlphaToken t = new AlphaToken(address(vault), "X", "X");
        uint256 tooBig = uint256(type(uint16).max) + 1;
        vm.expectRevert(abi.encodeWithSelector(AlphaVault.NetuidTooLarge.selector, tooBig));
        vault.addToken(address(t), bytes32(uint256(0xAA)), tooBig);
    }
}
