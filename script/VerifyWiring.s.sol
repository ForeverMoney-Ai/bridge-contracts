// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {TokenPool} from "@chainlink/contracts-ccip/contracts/pools/TokenPool.sol";
import {AlphaVault} from "../src/AlphaVault.sol";
import {AlphaGateway} from "../src/AlphaGateway.sol";
import {ITokenAdminRegistry} from "./Config.sol";

/// @notice Read-back check of a token's FULL wiring on ONE chain. Listing a token spans three
///         registries in two contracts plus our own two layers, and a half-wired token fails only
///         at bridge time — this turns "did we miss a step?" into a green/red assertion.
///
///         Run on EACH chain after listing a token or adding a lane. Broadcasts nothing.
///
/// @dev    Checks, in the order they can fail:
///           1. vault.isListed(token)                      — our custody layer knows the token (964)
///           2. registry.getPool(token) == pool            — CCIP can find a pool to lock/burn from
///           3. registry administrator == expected         — and it is NOT still the deployer EOA.
///                                                           NOTE: the registry SNAPSHOTS this at
///                                                           registration; rotating the vault admin
///                                                           does not move it (see AlphaToken).
///           4. pool.isSupportedChain / getRemoteToken / isRemotePool  — the lane is paired
///           5. gateway.allowedLane(remoteSelector)        — our app layer allows the lane (964)
///
/// Env:
///   TOKEN, POOL, REGISTRY, REMOTE_SELECTOR, REMOTE_POOL, REMOTE_TOKEN
///   EXPECTED_ADMIN   who should hold the CCIP registry admin (the multisig, post-handoff)
///   VAULT, GATEWAY   964 only — omit on Base
///   DEPLOYER         optional: assert the registry admin is NOT this address
///
/// Run: forge script script/VerifyWiring.s.sol --rpc-url $RPC
contract VerifyWiring is Script {
    uint256 internal _fail;

    function run() external {
        address token = vm.envAddress("TOKEN");
        address pool = vm.envAddress("POOL");
        address registry = vm.envAddress("REGISTRY");
        uint64 remoteSelector = uint64(vm.envUint("REMOTE_SELECTOR"));
        address remotePool = vm.envAddress("REMOTE_POOL");
        address remoteToken = vm.envAddress("REMOTE_TOKEN");
        address vault = vm.envOr("VAULT", address(0));
        address gateway = vm.envOr("GATEWAY", address(0));

        console2.log("=== wiring check for token", token);

        // 1. our custody layer (964 only)
        if (vault != address(0)) {
            _check(AlphaVault(payable(vault)).isListed(token), "vault.isListed(token)");
        }

        // 2. CCIP token -> pool
        address gotPool = ITokenAdminRegistry(registry).getPool(token);
        _check(gotPool == pool, "registry.getPool(token) == POOL");
        if (gotPool != pool) console2.log("   got:", gotPool);

        // 3. registry admin is where it should be, and not a hot key
        address admin = ITokenAdminRegistry(registry).getTokenConfig(token).administrator;
        console2.log("   registry administrator:", admin);
        address expected = vm.envOr("EXPECTED_ADMIN", address(0));
        if (expected != address(0)) _check(admin == expected, "registry administrator == EXPECTED_ADMIN");
        address deployer = vm.envOr("DEPLOYER", address(0));
        if (deployer != address(0)) _check(admin != deployer, "registry administrator is NOT the deployer");

        // 4. the lane is paired on this side
        _check(TokenPool(pool).isSupportedChain(remoteSelector), "pool.isSupportedChain(remote)");
        _check(
            keccak256(TokenPool(pool).getRemoteToken(remoteSelector)) == keccak256(abi.encode(remoteToken)),
            "pool.getRemoteToken == REMOTE_TOKEN"
        );
        _check(
            TokenPool(pool).isRemotePool(remoteSelector, abi.encode(remotePool)), "pool.isRemotePool(REMOTE_POOL)"
        );

        // 5. our app layer allows the lane (964 only)
        if (gateway != address(0)) {
            _check(AlphaGateway(payable(gateway)).allowedLane(remoteSelector), "gateway.allowedLane(remote)");
        }

        require(_fail == 0, "WIRING INCOMPLETE - see FAIL lines above");
        console2.log("=== all checks passed");
    }

    /// @dev Logs every check (so one run shows ALL problems, not just the first) and tallies
    ///      failures for the final require.
    function _check(bool ok, string memory what) internal {
        console2.log(ok ? "  ok   " : "  FAIL ", what);
        if (!ok) ++_fail;
    }
}
