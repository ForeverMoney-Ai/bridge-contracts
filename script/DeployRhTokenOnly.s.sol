// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {BurnMintERC20} from "@chainlink/contracts/src/v0.8/shared/token/ERC20/BurnMintERC20.sol";
import {Cfg, TokenNaming, IRegistryModuleOwnerCustom, ITokenAdminRegistry} from "./Config.sol";

/// @notice Reserve the SAME token address on a second spoke chain WITHOUT wiring it: deploy only the
///         BurnMintERC20 at the deployer's nonce N (must equal the nonce used on the first chain) and
///         hand DEFAULT_ADMIN + CCIP admin to the multisig. No pool, no registry, no lane, no minter.
/// Env: PRIVATE_KEY, NETUID, ADMIN, EXPECT_TOKEN
contract DeployRhTokenOnly is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        uint256 netuid = vm.envUint("NETUID");
        address admin = vm.envAddress("ADMIN");
        require(admin != address(0) && admin != deployer, "ADMIN must be the multisig");
        address expect = vm.envAddress("EXPECT_TOKEN");
        require(vm.computeCreateAddress(deployer, vm.getNonce(deployer)) == expect, "ADDRESS GUARD");

        vm.startBroadcast(pk);
        BurnMintERC20 tok = new BurnMintERC20(TokenNaming.name(netuid), TokenNaming.symbol(netuid), Cfg.DECIMALS, 0, 0);
        require(address(tok) == expect, "deployed token != EXPECT_TOKEN");
        tok.setCCIPAdmin(admin);
        tok.grantRole(tok.DEFAULT_ADMIN_ROLE(), admin);
        tok.renounceRole(tok.DEFAULT_ADMIN_ROLE(), deployer);
        vm.stopBroadcast();
        require(!tok.hasRole(tok.DEFAULT_ADMIN_ROLE(), deployer), "deployer still admin");
        console2.log("token (unwired):", address(tok));
    }
}
