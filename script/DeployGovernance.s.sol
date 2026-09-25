// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @notice Deploys the `ADMIN` Timelock that every other script takes as an env address.
///
///         The bridge's access model (docs/access-control.md) is two speeds over ONE signer set:
///         the multisig holds OPERATOR directly (instant), and holds root only through this
///         Timelock (delayed). That only holds if the Timelock's proposer IS the multisig and its
///         admin is nobody — which is what this script wires.
///
///         Deploy this BEFORE DeployAlpha/DeploySpoke, once per chain, and pass the resulting
///         address as ADMIN. The same multisig address on both chains does NOT give the same
///         Timelock address unless the deployer's nonce matches, so record both.
///
/// Env:
///   PRIVATE_KEY   deployer key (keeps nothing — see the self-administration note below)
///   MULTISIG      the Safe. Becomes proposer + canceller.
///   DELAY         seconds. Defaults to 2 days, matching AlphaVault.INITIAL_ADMIN_DELAY — a
///                 shorter timelock than the vault's own root rotation would be theatre.
///   OPEN_EXECUTOR "true" lets ANYONE execute an already-matured proposal (address(0) executor).
///                 Default false: only the multisig executes.
///
///                 Open execution is the usual choice — by the time a call is executable it has
///                 sat publicly for DELAY and been cancellable throughout, so execution is not a
///                 trust boundary, and it means a proposal cannot be stranded if the multisig is
///                 unavailable. Closed execution is the more conservative reading: it keeps a
///                 second, human gate in front of every root action.
///
/// Run: forge script script/DeployGovernance.s.sol --rpc-url $RPC --broadcast
///      (on 964, add --evm-version london --slow)
contract DeployGovernance is Script {
    uint256 constant DEFAULT_DELAY = 2 days;

    function run() external {
        deploy(
            vm.envUint("PRIVATE_KEY"),
            vm.envAddress("MULTISIG"),
            vm.envOr("DELAY", DEFAULT_DELAY),
            vm.envOr("OPEN_EXECUTOR", false)
        );
    }

    /// @dev The wiring itself, on explicit parameters. `run()` is only the env-reading shell —
    ///      keeping these separate is what lets the tests drive this deterministically, since
    ///      vm.setEnv mutates the real process environment and races across parallel tests.
    function deploy(uint256 pk, address multisig, uint256 delay, bool openExecutor)
        public
        returns (TimelockController timelock)
    {
        address deployer = vm.addr(pk);

        require(multisig != address(0), "governance: MULTISIG unset");
        require(multisig.code.length > 0, "governance: MULTISIG has no code - deploy the Safe first");
        require(delay > 0, "governance: zero delay is not a timelock");

        address[] memory proposers = new address[](1);
        proposers[0] = multisig;

        address[] memory executors = new address[](1);
        executors[0] = openExecutor ? address(0) : multisig;

        vm.startBroadcast(pk);

        // admin_ = address(0): the Timelock self-administers from birth. Passing the deployer here
        // would create an optional-admin window in which a hot key could grant itself PROPOSER,
        // i.e. root without the delay — the exact thing this contract exists to prevent. The
        // tradeoff is that role changes later must themselves go through the Timelock.
        timelock = new TimelockController(delay, proposers, executors, address(0));

        vm.stopBroadcast();

        // The multisig proposes and (unless OPEN_EXECUTOR) executes; nothing is left on the deployer.
        require(timelock.hasRole(timelock.PROPOSER_ROLE(), multisig), "governance: multisig not proposer");
        require(timelock.hasRole(timelock.CANCELLER_ROLE(), multisig), "governance: multisig not canceller");
        require(!timelock.hasRole(timelock.PROPOSER_ROLE(), deployer), "governance: deployer kept PROPOSER");
        require(!timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), deployer), "governance: deployer kept ADMIN");
        require(timelock.getMinDelay() == delay, "governance: delay mismatch");

        console2.log("== Timelock (pass this as ADMIN) ==");
        console2.log("Timelock:      ", address(timelock));
        console2.log("proposer:      ", multisig);
        console2.log("executor:      ", openExecutor ? address(0) : multisig);
        console2.log("minDelay (s):  ", delay);
    }
}
