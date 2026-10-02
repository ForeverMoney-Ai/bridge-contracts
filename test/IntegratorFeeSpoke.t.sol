// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {SpokeGateway} from "../src/SpokeGateway.sol";
import {IntegratorFee} from "../src/IntegratorFee.sol";
import {MockRouter} from "./mocks/MockRouter.sol";
import {ExitPayload} from "../src/ExitPayload.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

/// Minimal ERC20 with a switch to make the next `transfer` fail.
contract SpokeToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    bool public failNextTransfer;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function setFailNextTransfer(bool f) external {
        failNextTransfer = f;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address t, uint256 a) external returns (bool) {
        if (failNextTransfer) {
            failNextTransfer = false;
            return false;
        }
        balanceOf[msg.sender] -= a;
        balanceOf[t] += a;
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        require(allowance[f][msg.sender] >= a, "allow");
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }
}

/// Per-call integrator fee on a SPOKE gateway: a cut of the bridged token paid on the source chain,
/// capped by FEE_ADMIN, old signatures untouched.
contract IntegratorFeeSpokeTest is Test {
    MockRouter router;
    SpokeGateway gw;
    SpokeToken token;

    address feeAdmin = makeAddr("feeAdmin");
    address feeRecipient = makeAddr("feeRecipient");
    address subGateway = makeAddr("subGateway");
    address alice = makeAddr("alice");
    address integrator = makeAddr("integrator");
    uint64 constant SUB_SEL = 2135107236357186872;
    uint256 constant FEE = 0.01 ether;

    function setUp() public {
        router = new MockRouter(FEE);
        gw = new SpokeGateway(address(router), SUB_SEL, subGateway, feeAdmin, feeRecipient);
        token = new SpokeToken();
        token.mint(alice, 1_000 ether);
        vm.prank(alice);
        token.approve(address(gw), type(uint256).max);
        vm.deal(alice, 100 ether);
    }

    function _exit() internal pure returns (ExitPayload.Params memory) {
        return ExitPayload.Params({ss58: bytes32(uint256(0xABC)), evmFallback: address(0xF00D), wantLiquid: false, minTaoOut: 0});
    }

    function _fee(uint16 bps) internal view returns (IntegratorFee memory) {
        return IntegratorFee(integrator, bps);
    }

    // ------------------------------------------------------------------ cap and authority

    function test_defaultCapAndCeiling() public view {
        assertEq(gw.maxIntegratorFeeBps(), 100);
        assertEq(gw.MAX_INTEGRATOR_FEE_BPS(), 1_000);
    }

    function test_onlyFeeAdminSetsTheCap() public {
        vm.prank(alice);
        vm.expectRevert(SpokeGateway.NotFeeAdmin.selector);
        gw.setMaxIntegratorFeeBps(500);
        vm.prank(feeAdmin);
        vm.expectRevert(abi.encodeWithSelector(SpokeGateway.IntegratorFeeTooHigh.selector, 1_001, 1_000));
        gw.setMaxIntegratorFeeBps(1_001);
        vm.prank(feeAdmin);
        gw.setMaxIntegratorFeeBps(1_000);
        assertEq(gw.maxIntegratorFeeBps(), 1_000);
    }

    function test_feeAboveCapReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SpokeGateway.IntegratorFeeTooHigh.selector, 101, 100));
        gw.bridgeToFinneyWithFee{value: FEE}(address(token), 10 ether, _exit(), 0, _fee(101));
        assertEq(token.balanceOf(alice), 1_000 ether, "nothing pulled");
    }

    function test_zeroRecipientWithBpsReverts() public {
        vm.prank(alice);
        vm.expectRevert(SpokeGateway.ZeroIntegrator.selector);
        gw.bridgeToFinneyWithFee{value: FEE}(address(token), 10 ether, _exit(), 0, IntegratorFee(address(0), 10));
    }

    // ------------------------------------------------------------------ fee math

    function test_cutIsPaidOnTopOnThisChainAndFullAmountCrosses() public {
        vm.prank(alice);
        vm.recordLogs();
        gw.bridgeToFinneyWithFee{value: FEE}(address(token), 25 ether, _exit(), 0, _fee(50));
        assertEq(token.balanceOf(integrator), 0.125e18, "0.5% to the integrator, on top");
        assertEq(token.balanceOf(address(router)), 25 ether, "the full amount crossed");
        assertEq(token.balanceOf(address(gw)), 0);
        assertEq(token.balanceOf(alice), 1_000 ether - 25.125e18, "amount + cut pulled");
        // BridgedToFinney carries the net amount
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == keccak256("BridgedToFinney(address,address,bytes32,uint256,bytes32)")) {
                (uint256 amount,) = abi.decode(logs[i].data, (uint256, bytes32));
                assertEq(amount, 25 ether);
                seen = true;
            }
        }
        assertTrue(seen);
    }

    /// The cut rounds DOWN, so a small enough amount pays the integrator nothing. Since the exit
    /// floors landed, an amount that small can no longer reach the bridge, so assert the rounding at
    /// the smallest amount that CAN: 1 bps of the staked floor still rounds to a non-zero cut, and
    /// the rounding itself is covered by the pure quote below.
    function test_tinyAmountRoundsCutToZero() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("StakedExitBelowMin(uint256,uint256)", 3, MIN_STAKED));
        gw.bridgeToFinneyWithFee{value: FEE}(address(token), 3, _exit(), 0, _fee(100));

        // at the floor the cut is real, not rounded away
        vm.prank(alice);
        gw.bridgeToFinneyWithFee{value: FEE}(address(token), MIN_STAKED, _exit(), 0, _fee(1));
        assertEq(token.balanceOf(integrator), MIN_STAKED / 10_000, "1 bps of the floor");
        assertEq(token.balanceOf(address(router)), MIN_STAKED, "the full amount still crosses");
    }

    function test_transferFailureRevertsTheBridge() public {
        token.setFailNextTransfer(true);
        vm.prank(alice);
        vm.expectRevert(SpokeGateway.IntegratorFeeTransferFailed.selector);
        gw.bridgeToFinneyWithFee{value: FEE}(address(token), 10 ether, _exit(), 0, _fee(100));
    }

    // ------------------------------------------------------------------ quotes and compat

    function test_quoteParity() public {
        (uint256 f, uint256 cut, uint256 net) = gw.quoteBridgeToFinneyWithFee(address(token), 10 ether, _exit(), 0, _fee(100));
        assertEq(f, FEE);
        assertEq(cut, 0.1e18, "on top");
        assertEq(net, 10 ether, "full amount crosses");
        assertEq(gw.quoteBridgeToFinney(address(token), 10 ether, _exit()), FEE);
        assertEq(gw.quoteBridgeToFinney(address(token), 10 ether, _exit(), 0), FEE);
        vm.expectRevert(abi.encodeWithSelector(SpokeGateway.IntegratorFeeTooHigh.selector, 101, 100));
        gw.quoteBridgeToFinneyWithFee(address(token), 10 ether, _exit(), 0, _fee(101));
    }

    function test_gasLimitStillHonouredWithAFee() public {
        vm.prank(alice);
        gw.bridgeToFinneyWithFee{value: FEE}(address(token), 10 ether, _exit(), 777_777, _fee(10));
        bytes memory want = Client._argsToBytes(Client.GenericExtraArgsV2({gasLimit: 777_777, allowOutOfOrderExecution: true}));
        assertEq(router.lastExtraArgs(), want);
    }

    function test_markupAndIntegratorFeeTogether() public {
        vm.prank(feeAdmin);
        gw.setBridgeFeeBps(1_000);
        uint256 before = alice.balance;
        vm.prank(alice);
        gw.bridgeToFinneyWithFee{value: FEE * 2}(address(token), 10 ether, _exit(), 0, _fee(100));
        assertEq(feeRecipient.balance, FEE / 10, "native markup");
        assertEq(token.balanceOf(integrator), 0.1e18, "token cut on top");
        assertEq(token.balanceOf(address(router)), 10 ether);
        assertEq(before - alice.balance, FEE + FEE / 10, "excess refunded");
    }

    function test_legacySignaturesAreIdenticalToEmptyFee() public {
        uint256[3] memory spent;
        Vm.Log[][3] memory logs;
        uint256 u0 = alice.balance;
        vm.prank(alice);
        vm.recordLogs();
        gw.bridgeToFinney{value: FEE + 0.02 ether}(address(token), 10 ether, _exit());
        logs[0] = vm.getRecordedLogs();
        spent[0] = u0 - alice.balance;
        u0 = alice.balance;
        vm.prank(alice);
        vm.recordLogs();
        gw.bridgeToFinney{value: FEE + 0.02 ether}(address(token), 10 ether, _exit(), 0);
        logs[1] = vm.getRecordedLogs();
        spent[1] = u0 - alice.balance;
        u0 = alice.balance;
        vm.prank(alice);
        vm.recordLogs();
        gw.bridgeToFinneyWithFee{value: FEE + 0.02 ether}(address(token), 10 ether, _exit(), 0, IntegratorFee(address(0), 0));
        logs[2] = vm.getRecordedLogs();
        spent[2] = u0 - alice.balance;
        assertEq(spent[0], FEE, "refund identical");
        assertEq(spent[1], FEE);
        assertEq(spent[2], FEE);
        assertEq(logs[0].length, logs[2].length, "same events");
        for (uint256 i; i < logs[0].length; ++i) {
            assertEq(logs[0][i].topics[0], logs[2][i].topics[0]);
            assertEq(logs[1][i].topics[0], logs[2][i].topics[0]);
        }
        assertEq(token.balanceOf(address(router)), 30 ether);
        assertEq(token.balanceOf(integrator), 0);
        assertEq(router.lastExtraArgs(), Client._argsToBytes(Client.GenericExtraArgsV2({gasLimit: 300_000, allowOutOfOrderExecution: true})));
    }

    function test_capZeroDisablesIntegratorFees() public {
        vm.prank(feeAdmin);
        gw.setMaxIntegratorFeeBps(0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SpokeGateway.IntegratorFeeTooHigh.selector, 1, 0));
        gw.bridgeToFinneyWithFee{value: FEE}(address(token), 10 ether, _exit(), 0, _fee(1));
    }

    function test_selfAsIntegratorIsRejected() public {
        vm.prank(alice);
        vm.expectRevert(SpokeGateway.ZeroIntegrator.selector);
        gw.bridgeToFinneyWithFee{value: FEE}(address(token), 10 ether, _exit(), 0, IntegratorFee(address(gw), 10));
    }

    // ---------------------------------------------- liquid-exit minimum (HACK-22 / HACK-25)

    function _liquidExit() internal pure returns (ExitPayload.Params memory) {
        return ExitPayload.Params({ss58: bytes32(uint256(0xABC)), evmFallback: address(0xF00D), wantLiquid: true, minTaoOut: 0});
    }

    uint256 constant MIN_LIQUID = 2_000_000 * 1e9; // 0.002 TAO, the runtime's removeStake floor

    function test_liquidExitBelowMinReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("LiquidExitBelowMin(uint256,uint256)", MIN_LIQUID - 1, MIN_LIQUID));
        gw.bridgeToFinney{value: FEE}(address(token), MIN_LIQUID - 1, _liquidExit());
    }

    function test_liquidExitAtTheMinimumPasses() public {
        vm.prank(alice);
        gw.bridgeToFinney{value: FEE}(address(token), MIN_LIQUID, _liquidExit());
        assertEq(token.balanceOf(address(router)), MIN_LIQUID, "the exact floor still bridges");
    }

    /// The floor is about what the hub can unstake, so it must not touch the staked route.
    function test_stakedExitBelowTheLiquidMinimumStillPasses() public {
        vm.prank(alice);
        gw.bridgeToFinney{value: FEE}(address(token), MIN_LIQUID - 1, _exit());
        assertEq(token.balanceOf(address(router)), MIN_LIQUID - 1, "staked exits keep their own lower floor");
    }

    /// A quote that succeeds for a bridge that would revert is worse than no quote.
    uint256 constant MIN_STAKED = 1_000_000 * 1e9; // 0.001 TAO, the transferStake floor

    function test_stakedExitBelowItsOwnFloorReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("StakedExitBelowMin(uint256,uint256)", MIN_STAKED - 1, MIN_STAKED));
        gw.bridgeToFinney{value: FEE}(address(token), MIN_STAKED - 1, _exit());
    }

    function test_stakedExitAtItsFloorPasses() public {
        vm.prank(alice);
        gw.bridgeToFinney{value: FEE}(address(token), MIN_STAKED, _exit());
        assertEq(token.balanceOf(address(router)), MIN_STAKED);
    }

    function test_quoteRejectsTheSameTinyStakedExit() public {
        vm.expectRevert(abi.encodeWithSignature("StakedExitBelowMin(uint256,uint256)", MIN_STAKED - 1, MIN_STAKED));
        gw.quoteBridgeToFinney(address(token), MIN_STAKED - 1, _exit());
    }

    function test_quoteRejectsTheSameTinyLiquidExit() public {
        vm.expectRevert(abi.encodeWithSignature("LiquidExitBelowMin(uint256,uint256)", MIN_LIQUID - 1, MIN_LIQUID));
        gw.quoteBridgeToFinney(address(token), MIN_LIQUID - 1, _liquidExit());
    }

    function test_liquidMinimumAppliesWithAFeeToo() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("LiquidExitBelowMin(uint256,uint256)", MIN_LIQUID - 1, MIN_LIQUID));
        gw.bridgeToFinneyWithFee{value: FEE}(address(token), MIN_LIQUID - 1, _liquidExit(), 0, _fee(50));
    }

    function test_selectorsArePinned() public pure {
        assertEq(bytes4(keccak256("bridgeToFinney(address,uint256,(bytes32,address,bool,uint256))")), bytes4(0xe966bbea));
        assertEq(bytes4(keccak256("quoteBridgeToFinney(address,uint256,(bytes32,address,bool,uint256))")), bytes4(0xd022c000));
    }
}
