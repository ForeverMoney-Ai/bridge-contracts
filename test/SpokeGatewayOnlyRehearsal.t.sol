// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeploySpokeGatewayOnly} from "../script/DeploySpokeGatewayOnly.s.sol";
import {SpokeGateway} from "../src/SpokeGateway.sol";
import {Cfg} from "../script/Config.sol";
import {MockRouter} from "./mocks/MockRouter.sol";

/// Runs the gateway-only spoke deploy end to end with env set from the test.
/// @dev ONE test function on purpose: `vm.setEnv` writes the process environment, which forge's
///      test functions share while running concurrently — split across tests they race and the
///      deploy script reads another case's values.
contract SpokeGatewayOnlyRehearsal is Test {
    uint256 constant PK = 0xA11CE;

    function _env(address hub, address feeAdmin, address feeRecipient, address router, address expect) internal {
        vm.setEnv("PRIVATE_KEY", vm.toString(PK));
        vm.setEnv("SUBTENSOR_GATEWAY", vm.toString(hub));
        vm.setEnv("FEE_ADMIN", vm.toString(feeAdmin));
        vm.setEnv("FEE_RECIPIENT", vm.toString(feeRecipient));
        vm.setEnv("ROUTER", vm.toString(router));
        vm.setEnv("EXPECT_GATEWAY", vm.toString(expect));
    }

    function test_rehearsal() public {
        address hub = makeAddr("hub964");
        address safe = makeAddr("govSafe");
        address router = makeAddr("router");
        vm.etch(router, address(new MockRouter(0)).code); // isChainSupported -> true

        // 1. the happy path wires every immutable from the environment
        address expect = vm.computeCreateAddress(vm.addr(PK), vm.getNonce(vm.addr(PK)));
        _env(hub, safe, safe, router, expect);
        SpokeGateway gw = new DeploySpokeGatewayOnly().run();
        assertEq(address(gw), expect, "address guard");
        assertEq(gw.ROUTER(), router);
        assertEq(gw.BITTENSOR_SELECTOR(), Cfg.SUB_SELECTOR);
        assertEq(gw.SUBTENSOR_GATEWAY(), hub);
        assertEq(gw.FEE_ADMIN(), safe);
        assertEq(gw.feeRecipient(), safe);
        assertEq(gw.bridgeFeeBps(), 0);
        assertEq(gw.maxIntegratorFeeBps(), 100);

        // 2. the deployer may not keep the fee authority
        _env(hub, vm.addr(PK), safe, router, address(0));
        DeploySpokeGatewayOnly d = new DeploySpokeGatewayOnly();
        vm.expectRevert(bytes("FEE_ADMIN must be the Safe"));
        d.run();

        // 3. on a known chain the router comes from the chain id, never from a default
        _env(hub, safe, safe, address(0), address(0));
        vm.chainId(8453);
        vm.etch(Cfg.BASE_ROUTER, address(new MockRouter(0)).code);
        d = new DeploySpokeGatewayOnly();
        assertEq(d.run().ROUTER(), Cfg.BASE_ROUTER, "Base router by chain id");
        _env(hub, safe, safe, address(0), address(0));
        vm.chainId(4663);
        vm.etch(Cfg.RH_ROUTER, address(new MockRouter(0)).code);
        d = new DeploySpokeGatewayOnly();
        assertEq(d.run().ROUTER(), Cfg.RH_ROUTER, "Robinhood router by chain id");

        // 4. on a chain the script does not know, the router must be explicit — never guessed
        _env(hub, safe, safe, address(0), address(0));
        vm.chainId(999);
        d = new DeploySpokeGatewayOnly();
        vm.expectRevert(bytes("ROUTER: unknown chain, set it explicitly"));
        d.run();
    }
}
