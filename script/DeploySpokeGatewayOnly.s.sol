// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {SpokeGateway} from "../src/SpokeGateway.sol";
import {Cfg} from "./Config.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";

/// @notice Deploy ONLY a SpokeGateway on a spoke chain, pointed at an existing 964 AlphaGateway.
///         Tokens, pools, registries and lanes are untouched: the pools have no sender allow-list and
///         the hub gateway validates the source chain, not the sender, so a new spoke works next to
///         the old one from the moment it exists.
/// Env: PRIVATE_KEY, SUBTENSOR_GATEWAY (the 964 AlphaGateway), FEE_ADMIN, FEE_RECIPIENT (both must
///      be a Safe, not the deployer), optional ROUTER (else chosen by chain id: Base 8453, Robinhood
///      4663; any other chain must set it), optional EXPECT_GATEWAY (nonce guard).
contract DeploySpokeGatewayOnly is Script {
    function run() external returns (SpokeGateway gw) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address hub = vm.envAddress("SUBTENSOR_GATEWAY");
        address feeAdmin = vm.envAddress("FEE_ADMIN");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        require(hub != address(0), "SUBTENSOR_GATEWAY");
        require(feeAdmin != address(0) && feeAdmin != deployer, "FEE_ADMIN must be the Safe");
        require(feeRecipient != address(0) && feeRecipient != deployer, "FEE_RECIPIENT must be the Safe");
        address router = vm.envOr("ROUTER", address(0));
        if (router == address(0)) {
            // the router is per chain and the gateway is immutable: never guess it
            if (block.chainid == 8453) router = Cfg.BASE_ROUTER;
            else if (block.chainid == 4663) router = Cfg.RH_ROUTER;
            else revert("ROUTER: unknown chain, set it explicitly");
        }
        require(IRouterClient(router).isChainSupported(Cfg.SUB_SELECTOR), "router cannot reach 964");
        address expect = vm.envOr("EXPECT_GATEWAY", address(0));
        if (expect != address(0)) {
            require(vm.computeCreateAddress(deployer, vm.getNonce(deployer)) == expect, "ADDRESS GUARD");
        }

        vm.startBroadcast(pk);
        gw = new SpokeGateway(router, Cfg.SUB_SELECTOR, hub, feeAdmin, feeRecipient);
        vm.stopBroadcast();

        require(gw.ROUTER() == router, "router");
        require(gw.BITTENSOR_SELECTOR() == Cfg.SUB_SELECTOR, "selector");
        require(gw.SUBTENSOR_GATEWAY() == hub, "hub");
        require(gw.FEE_ADMIN() == feeAdmin, "feeAdmin");
        require(gw.feeRecipient() == feeRecipient, "feeRecipient");
        require(gw.bridgeFeeBps() == 0, "markup");
        require(gw.maxIntegratorFeeBps() == gw.DEFAULT_MAX_INTEGRATOR_FEE_BPS(), "integrator cap");
        if (expect != address(0)) require(address(gw) == expect, "deployed != EXPECT_GATEWAY");
        console2.log("SpokeGateway:", address(gw));
        console2.log("  router:", router);
        console2.log("  hub 964 gateway:", hub);
        console2.log("  FEE_ADMIN / feeRecipient:", feeAdmin, feeRecipient);
    }
}
