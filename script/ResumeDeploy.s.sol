// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DeployAlpha} from "./DeployAlpha.s.sol";
import {AlphaVault} from "../src/AlphaVault.sol";
import {AlphaGateway} from "../src/AlphaGateway.sol";
import {AlphaToken} from "../src/AlphaToken.sol";
import {LockReleaseTokenPool} from "@chainlink/contracts-ccip/contracts/pools/LockReleaseTokenPool.sol";
import {Cfg} from "./Config.sol";
import {console2} from "forge-std/Script.sol";

/// @notice Finish a `DeployAlpha.run()` that died AFTER the vault deployed but before anything else.
///
///         The 964 RPC rate-limits hard enough to drop transactions mid-run. When that happens the
///         vault is already on-chain and its address is baked into VAULT_COLDKEY, so re-running
///         `run()` is the one thing you must not do — it would deploy a SECOND vault at the next
///         nonce, and the coldkey would then belong to an address the new vault does not control.
///         Every deposit into it would be unrecoverable.
///
///         This resumes instead: it takes the live vault via `VAULT` and performs exactly the steps
///         `run()` does after `new AlphaVault(...)`, by calling the same internal helpers rather
///         than reimplementing them. Whatever DeployRehearsal proves about the deploy sequence
///         therefore holds here too.
///
/// @dev    Guards, because resuming into the wrong state is worse than not resuming:
///           - VAULT must have code
///           - its `vaultColdkey()` must equal VAULT_COLDKEY (proves this is the vault the coldkey
///             was computed for, not a stray redeploy)
///           - the broadcaster must still be its DEFAULT_ADMIN (proves the handoff has not run)
///           - no token may be listed on NETUID yet (proves _deployToken has not run)
///
/// Env: same as DeployAlpha.run(), plus VAULT.
contract ResumeDeploy is DeployAlpha {
    function resume() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        AlphaVault vault = AlphaVault(payable(vm.envAddress("VAULT")));

        bool handoff = vm.envOr("HANDOFF", false);
        address admin = handoff ? vm.envAddress("ADMIN") : vm.envOr("ADMIN", deployer);
        address operator = handoff ? vm.envAddress("OPERATOR") : vm.envOr("OPERATOR", deployer);
        address guardian = handoff ? vm.envAddress("GUARDIAN") : vm.envOr("GUARDIAN", deployer);
        address rescuer = vm.envOr("RESCUER", admin);
        uint256 netuid = vm.envUint("NETUID");

        require(address(vault).code.length > 0, "resume: VAULT has no code");
        require(
            vault.vaultColdkey() == vm.envBytes32("VAULT_COLDKEY"),
            "resume: VAULT_COLDKEY does not match this vault - wrong vault or wrong coldkey"
        );
        require(
            vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), deployer),
            "resume: broadcaster is not vault DEFAULT_ADMIN - handoff already ran?"
        );
        require(
            vault.tokenForNetuid(netuid) == address(0),
            "resume: netuid already listed - _deployToken already ran"
        );
        require(
            admin == deployer || operator != deployer,
            "resume: ADMIN set without OPERATOR - token custody would stay on the deployer"
        );

        vm.startBroadcast(pk);

        AlphaGateway gw;
        {
            address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer));
            gw = new AlphaGateway(
                Cfg.SUB_ROUTER, address(vault), Cfg.BASE_SELECTOR, rescuer, vm.envBytes32("GATEWAY_COLDKEY")
            );
            require(address(gw) == predicted, "gateway addr != predicted; GATEWAY_COLDKEY is for wrong addr");
        }
        vault.grantRole(vault.OPERATOR_ROLE(), deployer);
        (AlphaToken token, LockReleaseTokenPool pool) = _deployToken(vault, guardian, operator, deployer);
        _handoffVault(vault, deployer, admin, operator, guardian, handoff);

        vm.stopBroadcast();

        console2.log("== resumed: AlphaVault bridge (964, multi-token) ==");
        console2.log("AlphaVault (existing):  ", address(vault));
        console2.log("AlphaGateway (shared):  ", address(gw));
        console2.log("AlphaToken token:       ", address(token));
        console2.log("LockReleasePool:        ", address(pool));
    }
}
