// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {BurnMintERC20} from "@chainlink/contracts/src/v0.8/shared/token/ERC20/BurnMintERC20.sol";
import {SpokeGateway} from "../src/SpokeGateway.sol";
import {ExitPayload} from "../src/ExitPayload.sol";
import {MockRouter} from "./mocks/MockRouter.sol";

contract SpokeGatewayTest is Test {
    address feeAdmin = address(0xFEEADA);
    address feeRecipient = address(0xFEE2EC);
    BurnMintERC20 wtao;
    BurnMintERC20 wsn8;
    MockRouter router;
    SpokeGateway gw;

    address user = address(0xB0B);
    uint64 constant SUB_SEL = 2135107236357186872;
    address subtensorGateway = address(0x5175);
    uint256 constant FEE = 0.001 ether;

    function setUp() public {
        wtao = new BurnMintERC20("TAO", "TAO", 18, 0, 0);
        wsn8 = new BurnMintERC20("Subnet 8", "SN8", 18, 0, 0);
        // grant this test mint rights so we can fund the user
        wtao.grantMintAndBurnRoles(address(this));
        wsn8.grantMintAndBurnRoles(address(this));
        wtao.mint(user, 100 ether);
        wsn8.mint(user, 100 ether);

        router = new MockRouter(FEE);
        gw = new SpokeGateway(address(router), SUB_SEL, subtensorGateway, feeAdmin, feeRecipient);
        vm.deal(user, 10 ether);
    }

    function test_BridgeToFinney_pullsSendsRefunds() public {
        uint256 amount = 25 ether;
        bytes32 ss58 = bytes32(uint256(0xABCD));
        uint256 sent = FEE + 0.2 ether;
        uint256 preEth = user.balance;

        vm.startPrank(user);
        wtao.approve(address(gw), amount);
        bytes32 id = gw.bridgeToFinney{value: sent}(address(wtao), amount, _exit(ss58, user, true));
        vm.stopPrank();

        assertTrue(id != bytes32(0));
        // router (mock pool) pulled the wTAO to burn
        assertEq(wtao.balanceOf(address(router)), amount);
        assertEq(wtao.balanceOf(user), 75 ether);
        assertEq(wtao.balanceOf(address(gw)), 0);
        // refunded excess: spent exactly FEE
        assertEq(user.balance, preEth - FEE);
    }

    // ONE gateway serves every wrapped asset
    function test_BridgeToFinney_multiToken() public {
        vm.startPrank(user);
        wtao.approve(address(gw), 1 ether);
        gw.bridgeToFinney{value: FEE}(address(wtao), 1 ether, _exit(bytes32(uint256(1)), user, true));
        wsn8.approve(address(gw), 2 ether);
        gw.bridgeToFinney{value: FEE}(address(wsn8), 2 ether, _exit(bytes32(uint256(1)), user, false));
        vm.stopPrank();
        assertEq(wtao.balanceOf(address(router)), 1 ether);
        assertEq(wsn8.balanceOf(address(router)), 2 ether);
    }

    function test_BridgeToFinney_revertsIfUnderfunded() public {
        vm.startPrank(user);
        wtao.approve(address(gw), 10 ether);
        vm.expectRevert(SpokeGateway.InsufficientFee.selector);
        gw.bridgeToFinney{value: 0}(address(wtao), 10 ether, _exit(bytes32(uint256(1)), user, true));
        vm.stopPrank();
    }

    function test_BridgeToFinney_revertsZero() public {
        vm.prank(user);
        vm.expectRevert(SpokeGateway.ZeroAmount.selector);
        gw.bridgeToFinney{value: FEE}(address(wtao), 0, _exit(bytes32(uint256(1)), user, true));
    }

    function test_BridgeToFinney_rejectsZeroFallback() public {
        vm.startPrank(user);
        wtao.approve(address(gw), 1 ether);
        vm.expectRevert(SpokeGateway.ZeroFallback.selector);
        gw.bridgeToFinney{value: FEE}(address(wtao), 1 ether, _exit(bytes32(uint256(1)), address(0), true));
        vm.stopPrank();
    }

    function test_constructorRejectsBadArgs() public {
        vm.expectRevert(SpokeGateway.ZeroAddress.selector);
        new SpokeGateway(address(0), SUB_SEL, subtensorGateway, feeAdmin, feeRecipient);
        vm.expectRevert(SpokeGateway.ZeroAddress.selector);
        new SpokeGateway(address(router), SUB_SEL, address(0), feeAdmin, feeRecipient);
        // a chain selector is a uint64 — a zero one is not a zero *address*
        vm.expectRevert(SpokeGateway.ZeroSelector.selector);
        new SpokeGateway(address(router), 0, subtensorGateway, feeAdmin, feeRecipient);
    }

    function test_Quote() public view {
        assertEq(gw.quoteBridgeToFinney(address(wtao), 1 ether, _exit(bytes32(uint256(1)), user, true)), FEE);
    }

    // the 5-arg default path encodes DEFAULT_EXIT_GAS_LIMIT into the message
    function test_BridgeToFinney_defaultGasLimit() public {
        vm.startPrank(user);
        wtao.approve(address(gw), 1 ether);
        gw.bridgeToFinney{value: FEE}(address(wtao), 1 ether, _exit(bytes32(uint256(0xABCD)), user, true));
        vm.stopPrank();
        assertEq(router.lastExtraArgs(), _expectedArgs(gw.DEFAULT_EXIT_GAS_LIMIT()));
    }

    // a caller-supplied gas limit overrides the default and rides in the CCIP message
    function test_BridgeToFinney_customGasLimit() public {
        vm.startPrank(user);
        wtao.approve(address(gw), 1 ether);
        gw.bridgeToFinney{value: FEE}(address(wtao), 1 ether, _exit(bytes32(uint256(0xABCD)), user, true), 850_000);
        vm.stopPrank();
        assertEq(router.lastExtraArgs(), _expectedArgs(850_000));
    }

    // passing 0 falls back to the default (equivalent to the 5-arg form)
    function test_BridgeToFinney_zeroGasLimitUsesDefault() public {
        vm.startPrank(user);
        wtao.approve(address(gw), 1 ether);
        gw.bridgeToFinney{value: FEE}(address(wtao), 1 ether, _exit(bytes32(uint256(0xABCD)), user, true), 0);
        vm.stopPrank();
        assertEq(router.lastExtraArgs(), _expectedArgs(gw.DEFAULT_EXIT_GAS_LIMIT()));
    }

    function _exit(bytes32 ss58, address fb, bool wantLiquid)
        internal
        pure
        returns (ExitPayload.Params memory)
    {
        return ExitPayload.Params({ss58: ss58, evmFallback: fb, wantLiquid: wantLiquid, minTaoOut: 0});
    }

    function _expectedArgs(uint256 gasLimit) internal pure returns (bytes memory) {
        return Client._argsToBytes(
            Client.GenericExtraArgsV2({gasLimit: gasLimit, allowOutOfOrderExecution: true})
        );
    }
}
