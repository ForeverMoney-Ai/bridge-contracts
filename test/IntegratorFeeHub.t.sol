// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {AlphaVault} from "../src/AlphaVault.sol";
import {AlphaToken} from "../src/AlphaToken.sol";
import {AlphaGateway} from "../src/AlphaGateway.sol";
import {IntegratorFee} from "../src/IntegratorFee.sol";
import {IStaking} from "../src/interfaces/IStaking.sol";
import {MockStakingP} from "./mocks/MockStakingP.sol";
import {MockRouter} from "./mocks/MockRouter.sol";
import {MockExit} from "./mocks/MockExit.sol";

/// Per-call integrator fee on the HUB (964) leg: a cut of the minted/bridged token paid to whoever
/// prepared the tx, capped by the vault admin, with the old signatures untouched.
contract IntegratorFeeHubTest is Test {
    MockStakingP staking;
    AlphaVault vault;
    AlphaToken wtao;
    MockRouter router;
    AlphaGateway gw;

    bytes32 constant VAL = bytes32(uint256(0x5A11));
    uint64 constant BASE_SEL = 111;
    uint256 constant FEE = 0.001 ether;
    address emissions = makeAddr("emissions");
    address rescuer = makeAddr("rescuer");
    address dest = makeAddr("dest");
    address user = makeAddr("user");
    address integrator = makeAddr("integrator");
    address stranger = makeAddr("stranger");
    address owner = address(this);
    address constant EXIT = 0x0000000000000000000000000000000000000800;

    function setUp() public {
        staking = new MockStakingP();
        bytes32 ck = staking.ck(vm.computeCreateAddress(address(this), vm.getNonce(address(this))));
        vault = new AlphaVault(IStaking(address(staking)), ck, emissions, owner);
        wtao = new AlphaToken(address(vault), "TAO", "TAO");
        vault.grantRole(vault.OPERATOR_ROLE(), owner);
        vault.addToken(address(wtao), VAL, 0);
        router = new MockRouter(FEE);
        gw = new AlphaGateway(address(router), address(vault), BASE_SEL, rescuer,
            staking.ck(vm.computeCreateAddress(address(this), vm.getNonce(address(this)))));
        vm.etch(EXIT, type(MockExit).runtimeCode);
        vm.deal(user, 100 ether);
        vm.deal(owner, 100 ether);
    }

    receive() external payable {}

    function _fee(uint16 bps) internal view returns (IntegratorFee memory) {
        return IntegratorFee(integrator, bps);
    }

    // ------------------------------------------------------------------ cap and authority

    function test_defaultCapAndCeiling() public view {
        assertEq(gw.maxIntegratorFeeBps(), gw.DEFAULT_MAX_INTEGRATOR_FEE_BPS());
        assertEq(gw.DEFAULT_MAX_INTEGRATOR_FEE_BPS(), 100);
        assertEq(gw.MAX_INTEGRATOR_FEE_BPS(), 1_000);
    }

    function test_onlyVaultAdminSetsTheCap() public {
        vm.prank(stranger);
        vm.expectRevert(AlphaGateway.NotVaultAdmin.selector);
        gw.setMaxIntegratorFeeBps(500);
        gw.setMaxIntegratorFeeBps(500); // owner == vault DEFAULT_ADMIN
        assertEq(gw.maxIntegratorFeeBps(), 500);
        vm.expectRevert(abi.encodeWithSelector(AlphaGateway.IntegratorFeeTooHigh.selector, 1_001, 1_000));
        gw.setMaxIntegratorFeeBps(1_001);
        gw.setMaxIntegratorFeeBps(1_000); // the ceiling itself is allowed
    }

    function test_feeAboveCapRevertsBeforeAnyTaoIsStaked() public {
        uint256 before = user.balance;
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(AlphaGateway.IntegratorFeeTooHigh.selector, 101, 100));
        gw.bridgeOutWithFee{value: 1 ether + FEE}(BASE_SEL, address(wtao), dest, 1 ether, 0, 0, _fee(101));
        assertEq(vault.stakedValueRao(address(wtao)), 0, "nothing staked");
        assertEq(user.balance, before);
    }

    function test_feeWithZeroRecipientReverts() public {
        vm.prank(user);
        vm.expectRevert(AlphaGateway.ZeroIntegrator.selector);
        gw.bridgeOutWithFee{value: 1 ether + FEE}(BASE_SEL, address(wtao), dest, 1 ether, 0, 0, IntegratorFee(address(0), 50));
    }

    function test_selfAsIntegratorIsRejected() public {
        vm.prank(user);
        vm.expectRevert(AlphaGateway.ZeroIntegrator.selector);
        gw.bridgeOutWithFee{value: 1.01 ether + FEE}(BASE_SEL, address(wtao), dest, 1 ether, 0, 0, IntegratorFee(address(gw), 10));
    }

    function test_zeroBpsIgnoresRecipient() public {
        vm.prank(user);
        gw.bridgeOutWithFee{value: 1 ether + FEE}(BASE_SEL, address(wtao), dest, 1 ether, 0, 0, IntegratorFee(address(0), 0));
        assertEq(wtao.balanceOf(address(router)), 1 ether);
        assertEq(wtao.balanceOf(integrator), 0);
    }

    // ------------------------------------------------------------------ fee math

    /// Liquid leg: the caller carries the top-up in msg.value; it is staked and minted as the WRAPPED
    /// TOKEN for the integrator — the same currency the staked leg pays — while the requested amount
    /// crosses in full.
    function test_bridgeOut_liquid_feeOnTop() public {
        gw.setMaxIntegratorFeeBps(500);
        uint256 topUp = gw.integratorTaoTopUp(1 ether, 250);
        assertEq(topUp, 0.025e18);
        uint256 before = user.balance;
        vm.prank(user);
        gw.bridgeOutWithFee{value: 1 ether + topUp + FEE}(BASE_SEL, address(wtao), dest, 1 ether, 0, 1e18, _fee(250));
        assertEq(wtao.balanceOf(integrator), 0.025e18, "2.5% minted as the wrapped token");
        assertEq(integrator.balance, 0, "never native");
        assertEq(wtao.balanceOf(address(router)), 1 ether, "the full amount crossed");
        assertEq(wtao.totalSupply(), 1.025e18, "everything minted is backed");
        assertEq(vault.stakedValueRao(address(wtao)), 1.025e9);
        assertEq(before - user.balance, 1 ether + topUp + FEE, "caller paid amount + top-up + fee");
        assertEq(address(gw).balance, 0, "gateway keeps nothing");
    }

    function test_bridgeOut_liquid_missingTopUpReverts() public {
        vm.prank(user);
        vm.expectRevert(AlphaGateway.InsufficientValue.selector);
        gw.bridgeOutWithFee{value: 1 ether + FEE}(BASE_SEL, address(wtao), dest, 1 ether, 0, 0, _fee(100));
    }

    function test_topUpRoundsUpToWholeRao() public view {
        assertEq(gw.integratorTaoTopUp(1e9 + 1, 100), 1e9, "any positive remainder rounds up to one RAO");
        assertEq(gw.integratorTaoTopUp(1 ether, 0), 0);
    }

    /// Staked leg: the extra alpha is minted as the wrapped token — same currency as the liquid leg.
    function test_bridgeOut_staked_feeOnTop() public {
        staking.seed(VAL, user, 0, 4.04e9); // 4 alpha to bridge + 1% on top
        vm.startPrank(user);
        staking.approve(address(gw), 0, 4.04e9);
        gw.bridgeOutWithFee{value: FEE}(BASE_SEL, address(wtao), dest, 0, 4e9, 4e18, _fee(100));
        vm.stopPrank();
        assertEq(gw.integratorCut(4e9, 100), 0.04e9, "1% of the staked alpha");
        assertEq(wtao.balanceOf(integrator), 0.04e18, "paid in the wrapped token");
        assertEq(integrator.balance, 0, "never native");
        assertEq(wtao.balanceOf(address(router)), 4e18, "requested alpha crossed in full");
        assertEq(staking.getStake(VAL, staking.ck(user), 0), 0, "4.04 alpha left the user");
    }

    function test_bridgeTokenOut_feeOnTop() public {
        uint256 amt = vault.depositLiquid{value: 2.02 ether}(address(wtao), 0);
        wtao.transfer(user, amt);
        vm.startPrank(user);
        wtao.approve(address(gw), amt);
        gw.bridgeTokenOutWithFee{value: FEE}(BASE_SEL, address(wtao), dest, 2 ether, _fee(100));
        vm.stopPrank();
        assertEq(wtao.balanceOf(integrator), 0.02e18);
        assertEq(wtao.balanceOf(address(router)), 2 ether, "full amount crossed");
        assertEq(wtao.balanceOf(user), 0, "amount + cut pulled");
    }

    function test_tinyAmountRoundsCutToZero() public {
        uint256 amt = vault.depositLiquid{value: 1 ether}(address(wtao), 0);
        wtao.transfer(user, amt);
        vm.startPrank(user);
        wtao.approve(address(gw), amt);
        vm.recordLogs();
        gw.bridgeTokenOutWithFee{value: FEE}(BASE_SEL, address(wtao), dest, 3, _fee(100)); // 3 wei * 1% = 0 on top
        vm.stopPrank();
        assertEq(wtao.balanceOf(integrator), 0);
        assertEq(wtao.balanceOf(address(router)), 3);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != keccak256("IntegratorFeeCollected(address,address,uint256)"), "no fee event");
        }
    }

    // minTokenOut bounds what CROSSES; the fee on top never eats into it
    function test_minTokenOutBoundsTheCrossingAmount_reverts() public {
        vm.prank(user);
        vm.expectRevert(AlphaGateway.Slippage.selector);
        gw.bridgeOutWithFee{value: 1.01 ether + FEE}(BASE_SEL, address(wtao), dest, 1 ether, 0, 1e18 + 1, _fee(100));
    }

    function test_minTokenOutBoundsTheCrossingAmount_passes() public {
        vm.prank(user);
        gw.bridgeOutWithFee{value: 1.01 ether + FEE}(BASE_SEL, address(wtao), dest, 1 ether, 0, 1e18, _fee(100));
        assertEq(wtao.balanceOf(address(router)), 1e18);
        assertEq(wtao.balanceOf(integrator), 0.01e18);
    }

    // ------------------------------------------------------------------ quotes

    /// The quote tells a frontend exactly what to send: fee, native top-up, alpha top-up, crossing.
    function test_quoteParity() public {
        (uint256 f, uint256 nativeTopUp, uint256 alphaTopUp, uint256 crossing) =
            gw.quoteBridgeOutWithFee(BASE_SEL, address(wtao), dest, 1 ether, 1 ether, 2e9, _fee(100));
        assertEq(f, FEE);
        assertEq(nativeTopUp, 0.01e18, "native top-up for the liquid leg");
        assertEq(alphaTopUp, 0.02e9, "alpha top-up for the staked leg");
        assertEq(crossing, 1 ether, "the full amount crosses");
        assertEq(gw.quoteBridgeOut(BASE_SEL, address(wtao), dest, 1 ether), FEE, "old quote = gross fee");
        vm.expectRevert(abi.encodeWithSelector(AlphaGateway.IntegratorFeeTooHigh.selector, 101, 100));
        gw.quoteBridgeOutWithFee(BASE_SEL, address(wtao), dest, 1 ether, 1 ether, 0, _fee(101));
        vm.expectRevert(AlphaGateway.ZeroIntegrator.selector);
        gw.quoteBridgeOutWithFee(BASE_SEL, address(wtao), dest, 1 ether, 1 ether, 0, IntegratorFee(address(0), 1));

        vm.prank(user);
        gw.bridgeOutWithFee{value: 1 ether + nativeTopUp + FEE}(BASE_SEL, address(wtao), dest, 1 ether, 0, 0, _fee(100));
        assertEq(wtao.balanceOf(integrator), nativeTopUp, "quote matches execution (1:1 on root)");
        assertEq(wtao.balanceOf(address(router)), crossing);
    }

    // ------------------------------------------------------------------ interplay + compat

    function test_markupAndIntegratorFeeTogether() public {
        gw.setBridgeFeeBps(1_000); // 10% on the CCIP fee, native, to emissions
        uint256 before = user.balance;
        vm.prank(user);
        gw.bridgeOutWithFee{value: 1.01 ether + FEE * 2}(BASE_SEL, address(wtao), dest, 1 ether, 0, 0, _fee(100));
        assertEq(emissions.balance, FEE / 10, "native markup to the vault's recipient");
        assertEq(wtao.balanceOf(integrator), 0.01e18, "token cut to the integrator, from the top-up");
        assertEq(before - user.balance, 1.01 ether + FEE + FEE / 10, "excess refunded");
    }

    /// The legacy signature and the fee variant with an empty fee must be indistinguishable:
    /// same events (data included, bar the messageId nonce), same balances, same refund.
    function test_legacyBridgeOutIsIdenticalToEmptyFee() public {
        uint256 u0 = user.balance;
        vm.prank(user);
        vm.recordLogs();
        gw.bridgeOut{value: 1 ether + FEE + 0.3 ether}(BASE_SEL, address(wtao), dest, 1 ether, 0, 0);
        Vm.Log[] memory a = vm.getRecordedLogs();
        uint256 spentA = u0 - user.balance;
        uint256 routerA = wtao.balanceOf(address(router));

        u0 = user.balance;
        vm.prank(user);
        vm.recordLogs();
        gw.bridgeOutWithFee{value: 1 ether + FEE + 0.3 ether}(BASE_SEL, address(wtao), dest, 1 ether, 0, 0, IntegratorFee(address(0), 0));
        Vm.Log[] memory b = vm.getRecordedLogs();
        assertEq(u0 - user.balance, spentA, "same native spend (refund identical)");
        assertEq(wtao.balanceOf(address(router)) - routerA, routerA, "same amount crossed");
        assertEq(a.length, b.length, "same number of events");
        for (uint256 i; i < a.length; ++i) {
            assertEq(a[i].topics.length, b[i].topics.length);
            for (uint256 t; t < a[i].topics.length; ++t) assertEq(a[i].topics[t], b[i].topics[t]);
            if (a[i].topics[0] != keccak256("BridgedOut(uint64,address,address,address,uint256,bytes32)")) {
                assertEq(a[i].data, b[i].data, "same event data");
            }
        }
        assertEq(wtao.balanceOf(integrator), 0);
    }

    function test_legacyBridgeTokenOutIsIdenticalToEmptyFee() public {
        uint256 amt = vault.depositLiquid{value: 2 ether}(address(wtao), 0);
        wtao.transfer(user, amt);
        vm.startPrank(user);
        wtao.approve(address(gw), amt);
        uint256 u0 = user.balance;
        gw.bridgeTokenOut{value: FEE + 0.1 ether}(BASE_SEL, address(wtao), dest, amt / 2);
        uint256 spentA = u0 - user.balance;
        u0 = user.balance;
        gw.bridgeTokenOutWithFee{value: FEE + 0.1 ether}(BASE_SEL, address(wtao), dest, amt / 2, IntegratorFee(address(0), 0));
        vm.stopPrank();
        assertEq(u0 - user.balance, spentA);
        assertEq(wtao.balanceOf(address(router)), amt);
        assertEq(wtao.balanceOf(integrator), 0);
    }

    function test_capZeroDisablesIntegratorFees() public {
        gw.setMaxIntegratorFeeBps(0);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(AlphaGateway.IntegratorFeeTooHigh.selector, 1, 0));
        gw.bridgeOutWithFee{value: 1 ether + FEE}(BASE_SEL, address(wtao), dest, 1 ether, 0, 0, _fee(1));
        vm.prank(user);
        gw.bridgeOutWithFee{value: 1 ether + FEE}(BASE_SEL, address(wtao), dest, 1 ether, 0, 0, IntegratorFee(integrator, 0));
        assertEq(wtao.balanceOf(address(router)), 1 ether, "empty fee still works");
    }

    function test_combinedLiquidAndStakedFeeOnTop() public {
        staking.seed(VAL, user, 0, 2.02e9);
        vm.startPrank(user);
        staking.approve(address(gw), 0, 2.02e9);
        gw.bridgeOutWithFee{value: 1.01 ether + FEE}(BASE_SEL, address(wtao), dest, 1 ether, 2e9, 3e18, _fee(100));
        vm.stopPrank();
        assertEq(wtao.totalSupply(), 3.03e18, "3 bridged + 1% of each leg for the integrator");
        assertEq(wtao.balanceOf(integrator), 0.03e18, "1% of both legs, one currency");
        assertEq(integrator.balance, 0, "never native");
        assertEq(wtao.balanceOf(address(router)), 3e18, "the 3 wSN requested crossed");
    }
}
