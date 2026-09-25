// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {DeployGovernance} from "../script/DeployGovernance.s.sol";

/// @notice The Timelock is the only thing standing between a compromised multisig and instant root
///         over the vault, so the failure mode worth testing is not "does it deploy" but "did the
///         deployer keep anything, and does the delay actually bind".
///
/// @dev    Drives `deploy(...)` on explicit params rather than `run()`: vm.setEnv writes the real
///         process environment, which is not reverted between tests and races under parallel
///         execution, so env-driven tests here were non-deterministic.
contract DeployGovernanceTest is Test {
    DeployGovernance script;

    uint256 constant PK = 0xA11CE;
    uint256 constant DELAY = 2 days;

    address deployer = vm.addr(PK);
    address multisig = makeAddr("multisig");
    address stranger = makeAddr("stranger");

    function setUp() public {
        script = new DeployGovernance();
        // MULTISIG is required to have code — the guard exists to catch "Safe not deployed yet"
        vm.etch(multisig, hex"600160005260206000f3");
        vm.deal(deployer, 10 ether);
    }

    function test_deployerKeepsNothing() public {
        TimelockController tl = script.deploy(PK, multisig, DELAY, false);

        assertTrue(tl.hasRole(tl.PROPOSER_ROLE(), multisig), "multisig not proposer");
        assertTrue(tl.hasRole(tl.CANCELLER_ROLE(), multisig), "multisig not canceller");

        // the whole point: no residual authority on the hot key, and no optional-admin window
        assertFalse(tl.hasRole(tl.PROPOSER_ROLE(), deployer), "deployer kept PROPOSER");
        assertFalse(tl.hasRole(tl.CANCELLER_ROLE(), deployer), "deployer kept CANCELLER");
        assertFalse(tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), deployer), "deployer kept ADMIN");
        assertTrue(tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), address(tl)), "timelock should self-administer");
    }

    function test_delayBinds() public {
        TimelockController tl = script.deploy(PK, multisig, DELAY, false);
        assertEq(tl.getMinDelay(), DELAY, "should match AlphaVault.INITIAL_ADMIN_DELAY");

        bytes memory call = abi.encodeWithSignature("setEmissionsRecipient(address)", stranger);
        bytes32 salt = bytes32(0);

        vm.prank(multisig);
        tl.schedule(address(0xBEEF), 0, call, bytes32(0), salt, DELAY);

        // not executable until the delay has actually elapsed
        vm.prank(multisig);
        vm.expectRevert();
        tl.execute(address(0xBEEF), 0, call, bytes32(0), salt);

        vm.warp(block.timestamp + DELAY + 1);
        assertTrue(tl.isOperationReady(tl.hashOperation(address(0xBEEF), 0, call, bytes32(0), salt)));
    }

    function test_strangerCannotPropose() public {
        TimelockController tl = script.deploy(PK, multisig, DELAY, false);
        vm.prank(stranger);
        vm.expectRevert();
        tl.schedule(address(0xBEEF), 0, "", bytes32(0), bytes32(0), DELAY);
    }

    function test_executorIsClosedByDefault() public {
        TimelockController tl = script.deploy(PK, multisig, DELAY, false);
        assertFalse(tl.hasRole(tl.EXECUTOR_ROLE(), address(0)), "open execution should be opt-in");
        assertTrue(tl.hasRole(tl.EXECUTOR_ROLE(), multisig), "multisig should execute");
    }

    function test_openExecutorIsOptIn() public {
        TimelockController tl = script.deploy(PK, multisig, DELAY, true);
        // address(0) as executor is how OZ spells "anyone"
        assertTrue(tl.hasRole(tl.EXECUTOR_ROLE(), address(0)), "open execution not enabled");
    }

    function test_rejectsMultisigWithoutCode() public {
        vm.expectRevert(bytes("governance: MULTISIG has no code - deploy the Safe first"));
        script.deploy(PK, makeAddr("notDeployedYet"), DELAY, false);
    }

    function test_rejectsZeroDelay() public {
        vm.expectRevert(bytes("governance: zero delay is not a timelock"));
        script.deploy(PK, multisig, 0, false);
    }
}
