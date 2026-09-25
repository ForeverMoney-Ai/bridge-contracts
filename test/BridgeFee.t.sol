// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {SpokeGateway} from "../src/SpokeGateway.sol";
import {MockRouter} from "./mocks/MockRouter.sol";
import {ExitPayload} from "../src/ExitPayload.sol";

interface IERC20Mint {
    function mint(address to, uint256 amt) external;
    function approve(address s, uint256 a) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
}

contract FeeToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
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

/// A recipient that is ALSO the fee admin and repoints itself while being paid. Exists to prove
/// the emitted event names the address that actually received the money, not whatever the pointer
/// was moved to mid-call.
contract SelfRepointingRecipient {
    address public gw;
    address public next;

    function arm(address gw_, address next_) external {
        gw = gw_;
        next = next_;
    }

    receive() external payable {
        (bool ok, ) = gw.call(abi.encodeWithSignature("setFeeRecipient(address)", next));
        require(ok, "repoint failed");
    }
}

/// A recipient that rejects ETH, to prove the markup transfer failing is a revert and not a
/// silently swallowed loss.
contract RejectsEth {
    receive() external payable {
        revert("no");
    }
}

contract BridgeFeeTest is Test {
    event BridgeFeeCollected(address indexed to, uint256 amount);

    MockRouter router;
    SpokeGateway gw;
    FeeToken token;

    address feeAdmin = makeAddr("feeAdmin");
    address feeRecipient = makeAddr("feeRecipient");
    address subGateway = makeAddr("subGateway");
    address alice = makeAddr("alice");
    uint64 constant SUB_SEL = 2135107236357186872;

    function setUp() public {
        router = new MockRouter(0.01 ether);
        gw = new SpokeGateway(address(router), SUB_SEL, subGateway, feeAdmin, feeRecipient);
        token = new FeeToken();
        token.mint(alice, 1_000 ether);
        vm.prank(alice);
        token.approve(address(gw), type(uint256).max);
        vm.deal(alice, 100 ether);
    }

    function _exit() internal pure returns (ExitPayload.Params memory) {
        return ExitPayload.Params({
            ss58: bytes32(uint256(0xABC)),
            evmFallback: address(0xF00D),
            wantLiquid: false,
            minTaoOut: 0
        });
    }

    // ------------------------------------------------------------------ defaults

    function test_defaultsToZeroSoShippingChangesNothing() public view {
        assertEq(gw.bridgeFeeBps(), 0);
    }

    function test_quoteMatchesRouterWhenFeeIsZero() public view {
        uint256 q = gw.quoteBridgeToFinney(address(token), 1 ether, _exit());
        assertEq(q, router.fee(), "with no markup the quote is the bare CCIP fee");
    }

    // ------------------------------------------------------------------ authority

    function test_onlyFeeAdminMaySetIt() public {
        vm.prank(alice);
        vm.expectRevert(SpokeGateway.NotFeeAdmin.selector);
        gw.setBridgeFeeBps(100);

        vm.prank(feeAdmin);
        gw.setBridgeFeeBps(100);
        assertEq(gw.bridgeFeeBps(), 100);
    }

    /// The authority and destination are immutable by design: the concession for a settable fee is
    /// the number, not control of the contract.
    function test_adminAndRecipientAreImmutable() public view {
        assertEq(gw.FEE_ADMIN(), feeAdmin);
        assertEq(gw.feeRecipient(), feeRecipient);
    }

    function test_capIsEnforced() public {
        uint16 max = gw.MAX_BRIDGE_FEE_BPS();
        vm.startPrank(feeAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(SpokeGateway.BridgeFeeTooHigh.selector, max + 1, max)
        );
        gw.setBridgeFeeBps(max + 1);
        gw.setBridgeFeeBps(max); // the boundary itself is allowed
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ charging

    function test_quoteIncludesTheMarkup() public {
        vm.prank(feeAdmin);
        gw.setBridgeFeeBps(2_000); // 20%
        uint256 base = router.fee();
        assertEq(gw.quoteBridgeToFinney(address(token), 1 ether, _exit()), base + (base * 2_000) / 10_000);
    }

    function test_markupGoesToTheRecipientAndRouterGetsOnlyItsFee() public {
        vm.prank(feeAdmin);
        gw.setBridgeFeeBps(5_000); // 50%
        uint256 base = router.fee();
        uint256 gross = gw.quoteBridgeToFinney(address(token), 1 ether, _exit());
        assertEq(gross, base + base / 2);

        vm.prank(alice);
        gw.bridgeToFinney{value: gross}(address(token), 1 ether, _exit());

        assertEq(feeRecipient.balance, gross - base, "recipient receives exactly the markup");
        assertEq(address(router).balance, base, "router receives exactly its own fee");
        assertEq(address(gw).balance, 0, "gateway keeps nothing");
    }

    function test_underpayingTheGrossReverts() public {
        vm.prank(feeAdmin);
        gw.setBridgeFeeBps(3_000);
        uint256 base = router.fee();

        // enough for the bare CCIP fee, short of the quoted total
        vm.prank(alice);
        vm.expectRevert(SpokeGateway.InsufficientFee.selector);
        gw.bridgeToFinney{value: base}(address(token), 1 ether, _exit());
    }

    function test_overpayingIsRefundedNetOfTheMarkup() public {
        vm.prank(feeAdmin);
        gw.setBridgeFeeBps(1_000);
        uint256 gross = gw.quoteBridgeToFinney(address(token), 1 ether, _exit());
        uint256 before = alice.balance;

        vm.prank(alice);
        gw.bridgeToFinney{value: gross + 3 ether}(address(token), 1 ether, _exit());

        assertEq(before - alice.balance, gross, "caller is out exactly the quoted total");
    }

    /// The markup is settled before the refund, so a caller who reverts on receive cannot leave
    /// the fee stranded in the gateway. Here the RECIPIENT reverts, which must fail the whole tx
    /// rather than quietly skip payment.
    function test_recipientThatRejectsEthRevertsTheBridge() public {
        RejectsEth bad = new RejectsEth();
        SpokeGateway g2 =
            new SpokeGateway(address(router), SUB_SEL, subGateway, feeAdmin, address(bad));
        token.mint(alice, 10 ether);
        vm.prank(alice);
        token.approve(address(g2), type(uint256).max);
        vm.prank(feeAdmin);
        g2.setBridgeFeeBps(1_000);

        uint256 gross = g2.quoteBridgeToFinney(address(token), 1 ether, _exit());
        vm.prank(alice);
        vm.expectRevert(SpokeGateway.FeeTransferFailed.selector);
        g2.bridgeToFinney{value: gross}(address(token), 1 ether, _exit());
    }

    function test_zeroFeeSendsNothingToTheRecipient() public {
        uint256 gross = gw.quoteBridgeToFinney(address(token), 1 ether, _exit());
        vm.prank(alice);
        gw.bridgeToFinney{value: gross}(address(token), 1 ether, _exit());
        assertEq(feeRecipient.balance, 0, "disabled means disabled");
    }

    /// The bridged amount is never touched — a markup on the fee must not become a cut of the
    /// principal, or the 1:1 invariant the whole product rests on would break.
    function test_bridgedAmountIsUntouchedByTheFee() public {
        vm.prank(feeAdmin);
        gw.setBridgeFeeBps(5_000);
        uint256 gross = gw.quoteBridgeToFinney(address(token), 7 ether, _exit());

        vm.prank(alice);
        gw.bridgeToFinney{value: gross}(address(token), 7 ether, _exit());
        assertEq(token.balanceOf(address(router)), 7 ether, "full principal reaches the router");
    }

    function test_feeRecipientIsSettableByAdminOnly() public {
        address other = makeAddr("other");
        vm.prank(alice);
        vm.expectRevert(SpokeGateway.NotFeeAdmin.selector);
        gw.setFeeRecipient(other);

        vm.prank(feeAdmin);
        gw.setFeeRecipient(other);
        assertEq(gw.feeRecipient(), other);
    }

    /// Zero would burn the markup on every bridge: this gateway has no vault to fall back to.
    function test_feeRecipientRejectsZero() public {
        vm.prank(feeAdmin);
        vm.expectRevert(SpokeGateway.ZeroAddress.selector);
        gw.setFeeRecipient(address(0));
    }

    function test_markupFollowsTheNewRecipient() public {
        address other = makeAddr("other");
        uint256 fee = router.fee();
        vm.startPrank(feeAdmin);
        gw.setBridgeFeeBps(1_000);
        gw.setFeeRecipient(other);
        vm.stopPrank();

        uint256 before = other.balance;
        uint256 oldBefore = feeRecipient.balance;
        vm.prank(alice);
        gw.bridgeToFinney{value: fee + fee / 10}(address(token), 1 ether, _exit());

        assertEq(other.balance - before, fee / 10, "markup follows the pointer");
        assertEq(feeRecipient.balance, oldBefore, "and stops going to the old one");
    }

    /// The transfer is always correct -- it uses the pre-call value. What this pins is the RECORD:
    /// a second storage read after the external call would log an address that was never paid, and
    /// fee reconciliation is done from these events with nothing on chain to contradict them.
    function test_collectedEventNamesWhoWasActuallyPaid() public {
        SelfRepointingRecipient r = new SelfRepointingRecipient();
        address other = makeAddr("other");

        // the recipient is also the admin, so it can repoint itself from inside receive()
        SpokeGateway g2 = new SpokeGateway(address(router), SUB_SEL, subGateway, address(r), address(r));
        r.arm(address(g2), other); // arm AFTER g2 exists, or it repoints the wrong gateway
        vm.prank(alice);
        token.approve(address(g2), type(uint256).max);
        vm.prank(address(r));
        g2.setBridgeFeeBps(1_000);

        uint256 fee = router.fee();
        uint256 markup = fee / 10;

        vm.recordLogs();
        vm.prank(alice);
        g2.bridgeToFinney{value: fee + markup}(address(token), 1 ether, _exit());

        // recordLogs rather than expectEmit: BridgedToFinney fires first, and expectEmit only ever
        // looks at the next event.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("BridgeFeeCollected(address,uint256)");
        address logged;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) logged = address(uint160(uint256(logs[i].topics[1])));
        }
        assertEq(logged, address(r), "event must name who was paid, not the new pointer");

        assertEq(g2.feeRecipient(), other, "the pointer really did move mid-call");
        assertEq(address(r).balance, markup, "and the money went to the OLD one");
    }
}
