// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AlphaVault} from "../src/AlphaVault.sol";
import {AlphaToken} from "../src/AlphaToken.sol";
import {AlphaGateway} from "../src/AlphaGateway.sol";
import {IStaking} from "../src/interfaces/IStaking.sol";
import {MockStakingP} from "./mocks/MockStakingP.sol";
import {MockRouter} from "./mocks/MockRouter.sol";
import {MockExit} from "./mocks/MockExit.sol";

/// Bridge-fee behaviour on the HUB (964) leg.
///
/// BridgeFee.t.sol covers the spoke (Base) gateway. The hub gateway carries the same markup but
/// had no coverage of its own, so the outbound leg on 964 -- the one that actually holds the
/// user's TAO while it works -- was the untested half of a two-sided fee.
///
/// The property that matters most is the LAST one: the markup is charged on the CCIP FEE and
/// never on the bridged amount. A fee that quietly skimmed principal would break the 1:1 claim
/// the whole product rests on, and would not show up in a balance assertion on the fee recipient.
contract BridgeFeeHubTest is Test {
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

    function _bridge(uint256 tao, uint256 value) internal {
        vm.prank(user);
        gw.bridgeOut{value: value}(BASE_SEL, address(wtao), dest, tao, 0, 0);
    }

    function test_defaultsToZeroSoADeployChargesNothing() public view {
        assertEq(gw.bridgeFeeBps(), 0, "fee must be opt-in, never on by default");
    }

    function test_onlyVaultAdminMaySetIt() public {
        vm.prank(stranger);
        vm.expectRevert();
        gw.setBridgeFeeBps(500);

        gw.setBridgeFeeBps(500); // vault DEFAULT_ADMIN
        assertEq(gw.bridgeFeeBps(), 500);
    }

    function test_rejectsAFeeAboveTheCap() public {
        uint16 max = gw.MAX_BRIDGE_FEE_BPS();
        vm.expectRevert();
        gw.setBridgeFeeBps(max + 1);
    }

    function test_quoteMatchesRouterWhenFeeIsZero() public view {
        assertEq(gw.quoteBridgeOut(BASE_SEL, address(wtao), dest, 1 ether), FEE);
    }

    function test_quoteIncludesTheMarkupSoCallersAreNotSurprised() public {
        gw.setBridgeFeeBps(1_000); // 10%
        assertEq(
            gw.quoteBridgeOut(BASE_SEL, address(wtao), dest, 1 ether),
            FEE + FEE / 10,
            "quote must be what the caller actually has to send"
        );
    }

    function test_markupGoesToEmissionsRecipientAndRouterGetsOnlyItsFee() public {
        gw.setBridgeFeeBps(1_000); // 10%
        uint256 before = emissions.balance;
        uint256 routerBefore = address(router).balance;

        _bridge(1 ether, 1 ether + FEE + FEE / 10);

        assertEq(emissions.balance - before, FEE / 10, "markup to the emissions recipient");
        assertEq(address(router).balance - routerBefore, FEE, "router gets its bare fee, no more");
    }

    function test_zeroFeeSendsNothingToTheRecipient() public {
        uint256 before = emissions.balance;
        _bridge(1 ether, 1 ether + FEE);
        assertEq(emissions.balance, before, "no markup means no transfer at all");
    }

    function test_underpayingTheMarkupReverts() public {
        gw.setBridgeFeeBps(1_000);
        vm.prank(user);
        vm.expectRevert();
        // exactly the bare CCIP fee: enough before the markup existed, short now
        gw.bridgeOut{value: 1 ether + FEE}(BASE_SEL, address(wtao), dest, 1 ether, 0, 0);
    }

    function test_overpaymentIsRefundedNetOfTheMarkup() public {
        gw.setBridgeFeeBps(1_000);
        uint256 gross = FEE + FEE / 10;
        uint256 before = user.balance;
        _bridge(1 ether, 1 ether + gross + 0.5 ether);
        assertEq(before - user.balance, 1 ether + gross, "caller keeps everything above tao+gross");
    }

    /// THE load-bearing one. The markup must ride on the CCIP fee, never on the principal:
    /// a 10% fee means ~$0.25 on a $2.50 hop, NOT 10% of the user's TAO. If this ever fails,
    /// the wrapped token stops being a 1:1 claim and every downstream price assumption breaks.
    function test_bridgedAmountIsUntouchedByTheFee() public {
        uint256 taoIn = 1 ether;

        // The mock router pulls transferred tokens to itself, so its balance delta IS the amount
        // that actually crossed. Measured twice rather than snapshotted, which keeps this free of
        // forge-std's snapshot API differences.
        uint256 b0 = wtao.balanceOf(address(router));
        gw.setBridgeFeeBps(0);
        _bridge(taoIn, taoIn + FEE);
        uint256 bridgedWithoutFee = wtao.balanceOf(address(router)) - b0;

        uint256 b1 = wtao.balanceOf(address(router));
        gw.setBridgeFeeBps(1_000); // 10%
        _bridge(taoIn, taoIn + FEE + FEE / 10);
        uint256 bridgedWithFee = wtao.balanceOf(address(router)) - b1;

        assertGt(bridgedWithoutFee, 0, "sanity: something bridged");
        assertEq(bridgedWithFee, bridgedWithoutFee, "the fee must not shrink what gets bridged");
    }

    /// Default is the vault's emissions recipient, resolved LIVE -- a cached mirror here would
    /// keep paying the old address after the vault moved its own.
    function test_defaultsToTheVaultsEmissionsRecipient() public {
        assertEq(gw.feeRecipient(), address(0), "unset means 'use the vault'");
        gw.setBridgeFeeBps(1_000);

        uint256 before = emissions.balance;
        _bridge(1 ether, 1 ether + FEE + FEE / 10);
        assertEq(emissions.balance - before, FEE / 10);
    }

    function test_recipientOverrideDivertsTheMarkup() public {
        address other = makeAddr("other");
        gw.setBridgeFeeBps(1_000);
        gw.setFeeRecipient(other);

        uint256 beforeOther = other.balance;
        uint256 beforeEmissions = emissions.balance;
        _bridge(1 ether, 1 ether + FEE + FEE / 10);

        assertEq(other.balance - beforeOther, FEE / 10, "override wins");
        assertEq(emissions.balance, beforeEmissions, "emissions no longer take fee income");
    }

    /// Zero restores the vault default rather than burning the markup.
    function test_zeroRecipientFallsBackToTheVault() public {
        address other = makeAddr("other");
        gw.setBridgeFeeBps(1_000);
        gw.setFeeRecipient(other);
        gw.setFeeRecipient(address(0));

        uint256 before = emissions.balance;
        _bridge(1 ether, 1 ether + FEE + FEE / 10);
        assertEq(emissions.balance - before, FEE / 10, "back to the vault's recipient");
    }

    function test_recipientIsVaultAdminOnly() public {
        vm.prank(stranger);
        vm.expectRevert();
        gw.setFeeRecipient(stranger);
    }
}
