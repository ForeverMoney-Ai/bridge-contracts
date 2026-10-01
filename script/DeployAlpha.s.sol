// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from
    "@chainlink/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {LockReleaseTokenPool} from "@chainlink/contracts-ccip/contracts/pools/LockReleaseTokenPool.sol";
import {AlphaVault} from "../src/AlphaVault.sol";
import {AlphaToken} from "../src/AlphaToken.sol";
import {IStaking} from "../src/interfaces/IStaking.sol";
import {AlphaGateway} from "../src/AlphaGateway.sol";
import {Cfg, TokenNaming, IRegistryModuleOwnerCustom, ITokenAdminRegistry} from "./Config.sol";

/// @notice Subtensor-EVM (964) side of the MULTI-TOKEN AlphaVault bridge.
///
///         Deployed ONCE per chain:  AlphaVault (singleton, all logic) + AlphaGateway (shared UX).
///         Deployed PER listed asset: AlphaToken (thin ERC20) + LockReleaseTokenPool, then
///         `vault.addToken` + CCIP token-admin registration.
///
///         run()      — full stack: vault + gateway + the FIRST token (env below).
///         addToken() — list another token on an EXISTING vault (env: VAULT + the token vars).
///                      Requires the broadcasting key to still hold DEFAULT_ADMIN on the vault
///                      (i.e. pre-handoff, or run through governance afterwards).
///
/// Env (run):
///   PRIVATE_KEY          deployer key
///   HANDOFF              "true" for a production handoff: ADMIN/OPERATOR/GUARDIAN then REQUIRED
///   ADMIN                DEFAULT_ADMIN_ROLE (Timelock->5/9 multisig) — defaults to deployer
///   OPERATOR             OPERATOR_ROLE — defaults to deployer
///   GUARDIAN             GUARDIAN_ROLE — defaults to deployer
///   RESCUER              gateway rescuer — defaults to ADMIN
///   EMISSIONS_RECIPIENT  address that receives skimmed emissions (global, all tokens)
///   VAULT_COLDKEY        blake2b_256("evm:"+predicted vault address), computed off-chain
///   GATEWAY_COLDKEY      blake2b_256("evm:"+predicted gateway address), computed off-chain
///   NETUID               first token's subnet id (0 = root)
///   VALIDATOR_HOTKEY     first token's bytes32 validator hotkey
///   TOKEN_NAME/TOKEN_SYMBOL  OPTIONAL override. By default derived from NETUID:
///                            0 -> "Bittensor"/"TAO", 93 -> "Subnet 93"/"SN93". Never the subnet's own
///                            Finney token name — those change and are inconsistent.
/// Env (addToken): PRIVATE_KEY, VAULT, NETUID, VALIDATOR_HOTKEY, TOKEN_NAME, TOKEN_SYMBOL,
///   and optionally ADMIN (handoff target for the new pool/registry admin).
///
/// Run: forge script script/DeployAlpha.s.sol --rpc-url $SUBTENSOR_RPC --evm-version london --broadcast --slow
///      forge script script/DeployAlpha.s.sol --sig "addToken()" ... (subsequent tokens)
contract DeployAlpha is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        // Resolve role destinations once. In HANDOFF mode they are REQUIRED (envAddress reverts if
        // unset) so a missing/typoed var can't silently leave the hot deployer key holding a role.
        bool handoff = vm.envOr("HANDOFF", false);
        address admin = handoff ? vm.envAddress("ADMIN") : vm.envOr("ADMIN", deployer);
        address operator = handoff ? vm.envAddress("OPERATOR") : vm.envOr("OPERATOR", deployer);
        address guardian = handoff ? vm.envAddress("GUARDIAN") : vm.envOr("GUARDIAN", deployer);
        address rescuer = vm.envOr("RESCUER", admin);

        // Token custody (registry admin + pool ownership) follows OPERATOR, not ADMIN. So a run
        // that names an ADMIN but lets OPERATOR default to the deployer would hand over root and
        // silently keep registry admin — i.e. `setPool` — on the broadcasting hot key. Naming
        // ADMIN is the signal that this is a real handoff, so require OPERATOR with it. (Under
        // HANDOFF both are already mandatory; this covers the half-configured run in between.)
        require(
            admin == deployer || operator != deployer,
            "ADMIN set without OPERATOR - token custody would stay on the deployer"
        );

        // VAULT_COLDKEY = blake2b_256("evm:" + predicted vault address) — the vault is the FIRST
        // contract deployed here, so predict via `cast compute-address <deployer> --nonce <n>`.
        address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer));
        // Derive it and compare, rather than accepting whatever the env says. The address assert
        // below only proves we deployed where we expected, not that the coldkey belongs to it.
        require(
            _coldkeyFor(predicted) == vm.envBytes32("VAULT_COLDKEY"),
            "VAULT_COLDKEY is not blake2b_256(\"evm:\" + predicted vault address)"
        );

        vm.startBroadcast(pk);

        // 1. AlphaVault singleton. The deployer is DEFAULT_ADMIN so it can list tokens and each
        //    token's getCCIPAdmin() (== vault.owner()) resolves to it for CCIP self-registration.
        AlphaVault vault = new AlphaVault(
            IStaking(0x0000000000000000000000000000000000000805),
            vm.envBytes32("VAULT_COLDKEY"),
            vm.envAddress("EMISSIONS_RECIPIENT"),
            deployer // admin_ (DEFAULT_ADMIN)
        );
        require(address(vault) == predicted, "vault addr != predicted; VAULT_COLDKEY is for wrong addr");

        // 2. AlphaGateway (shared UX layer — one per chain).
        // GATEWAY_COLDKEY = blake2b_256("evm:" + predicted gateway address). The gateway reads its
        // OWN transient positions when consolidating alpha pulled from several validators, so a
        // wrong coldkey makes those deposits revert (it would read a stranger's position as zero)
        // rather than misroute anything — but assert it up front all the same.
        AlphaGateway gw;
        {
            // Scoped so `predicted` does not survive into the rest of run() — this script compiles
            // without via-ir and is already close to the stack limit.
            address predictedGateway = vm.computeCreateAddress(deployer, vm.getNonce(deployer));
            require(
                _coldkeyFor(predictedGateway) == vm.envBytes32("GATEWAY_COLDKEY"),
                "GATEWAY_COLDKEY is not blake2b_256(\"evm:\" + predicted gateway address)"
            );
            gw = new AlphaGateway(
                Cfg.SUB_ROUTER, address(vault), Cfg.BASE_SELECTOR, rescuer, vm.envBytes32("GATEWAY_COLDKEY")
            );
            require(address(gw) == predictedGateway, "gateway addr != predicted; GATEWAY_COLDKEY is for wrong addr");
        }

        // Listing is OPERATOR-gated, so the deployer needs OPERATOR for the duration of this run.
        // _handoffVault revokes it again — and asserts it is gone when HANDOFF=true.
        vault.grantRole(vault.OPERATOR_ROLE(), deployer);

        // 3. First token + pool + listing + CCIP registration.
        (AlphaToken token, LockReleaseTokenPool pool) = _deployToken(vault, guardian, operator, deployer);

        // 4. Hand vault roles and admin to governance.
        _handoffVault(vault, deployer, admin, operator, guardian, handoff);

        vm.stopBroadcast();

        console2.log("== AlphaVault bridge (964, multi-token) ==");
        console2.log("AlphaVault (singleton): ", address(vault));
        console2.log("AlphaGateway (shared):  ", address(gw));
        console2.log("AlphaToken token:     ", address(token));
        console2.log("LockReleasePool:        ", address(pool));
    }

    /// @notice List an additional token on an existing vault.
    ///
    /// @dev POST-HANDOFF THIS RUNS FROM THE OPERATOR MULTISIG, WITH NO TIMELOCK IN THE PATH. Both
    ///      steps sit on the fast tier: `createToken` needs vault OPERATOR, and
    ///      `registerAdminViaGetCCIPAdmin` requires msg.sender == token.getCCIPAdmin(), which
    ///      resolves to `vault.ccipAdmin()` — pointed at that same multisig by the handoff. So the
    ///      broadcaster must hold OPERATOR *and* be ccipAdmin; the guards below fail fast on either
    ///      rather than reverting deep inside createToken or the registry module.
    ///
    ///      HANDOFF=true mirrors run(): ADMIN/OPERATOR/GUARDIAN become REQUIRED (no silent deployer
    ///      default, which would otherwise leave registry admin + pool ownership on the
    ///      broadcasting key) and the registry transfer is asserted pending to the OPERATOR
    ///      afterwards.
    function addToken() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        AlphaVault vault = AlphaVault(payable(vm.envAddress("VAULT")));

        bool handoff = vm.envOr("HANDOFF", false);
        address admin = handoff ? vm.envAddress("ADMIN") : vm.envOr("ADMIN", deployer);
        address guardian = handoff ? vm.envAddress("GUARDIAN") : vm.envOr("GUARDIAN", deployer);
        address operator = handoff ? vm.envAddress("OPERATOR") : vm.envOr("OPERATOR", deployer);
        require(admin != address(0) && guardian != address(0), "addToken: zero addr");
        require(operator != address(0), "addToken: zero OPERATOR");

        // Token custody (registry admin + pool ownership) follows OPERATOR, not ADMIN. So a run
        // that names an ADMIN but lets OPERATOR default to the deployer would hand over root and
        // silently keep registry admin — i.e. `setPool` — on the broadcasting hot key. Naming
        // ADMIN is the signal that this is a real handoff, so require OPERATOR with it. (Under
        // HANDOFF both are already mandatory; this covers the half-configured run in between.)
        require(
            admin == deployer || operator != deployer,
            "addToken: ADMIN set without OPERATOR - token custody would stay on the deployer"
        );

        // Listing is fast-lane: the broadcaster needs OPERATOR (to list) AND must BE ccipAdmin (to
        // self-register with CCIP). Post-handoff both live on the operator multisig, so this runs
        // as Safe transactions rather than a hot key — but no timelock queue is involved.
        require(
            vault.hasRole(vault.OPERATOR_ROLE(), deployer),
            "addToken: broadcaster lacks vault OPERATOR - listing is operator-gated"
        );
        require(
            vault.ccipAdmin() == deployer,
            "addToken: broadcaster is not vault.ccipAdmin - CCIP registration would revert"
        );

        vm.startBroadcast(pk);
        (AlphaToken token, LockReleaseTokenPool pool) = _deployToken(vault, guardian, operator, deployer);
        vm.stopBroadcast();

        if (handoff) {
            // transferAdminRole is 2-step: assert it is PENDING for the OPERATOR. (Pool ownership is
            // also pending, but Chainlink's ownership base exposes no pendingOwner getter, so it
            // cannot be asserted here; VerifyWiring checks `pool.owner()` after the accept.)
            address pending =
                ITokenAdminRegistry(Cfg.SUB_TOKEN_ADMIN_REGISTRY).getTokenConfig(address(token)).pendingAdministrator;
            require(pending == operator, "addToken: registry admin transfer not pending to OPERATOR");
        }

        console2.log("== additional token listed ==");
        console2.log("AlphaToken token: ", address(token));
        console2.log("LockReleasePool:    ", address(pool));
        console2.log("NEXT: RegisterLane on BOTH chains, gateway.setLane, then the multisig must");
        console2.log("      acceptAdminRole(token) + pool.acceptOwnership(). Verify with VerifyWiring.");
    }

    /// @dev Per-token deploy: thin ERC20 + LockRelease pool, vault listing, CCIP token-admin
    ///      self-registration (via the token's getCCIPAdmin == vault.ccipAdmin == broadcaster),
    ///      pool attach, and the per-token piece of the handoff: registry admin + pool ownership
    ///      go to `custodian` — the OPERATOR multisig, the same place operator-listed tokens land.
    function _deployToken(AlphaVault vault, address guardian, address custodian, address deployer)
        internal
        returns (AlphaToken token, LockReleaseTokenPool pool)
    {
        // One call deploys AND lists the token (vault constructs it, so the binding can't be wrong).
        // Names are DERIVED from the netuid, not taken from env — see TokenNaming. Overridable
        // only if you really mean to, which should be rare.
        uint256 netuid = vm.envUint("NETUID");
        token = AlphaToken(
            vault.createToken(
                vm.envOr("TOKEN_NAME", TokenNaming.name(netuid)),
                vm.envOr("TOKEN_SYMBOL", TokenNaming.symbol(netuid)),
                vm.envBytes32("VALIDATOR_HOTKEY"),
                netuid
            )
        );
        pool = new LockReleaseTokenPool(
            IERC20(address(token)), Cfg.DECIMALS, new address[](0), Cfg.SUB_RMN_PROXY, false, Cfg.SUB_ROUTER
        );

        IRegistryModuleOwnerCustom(Cfg.SUB_REGISTRY_MODULE).registerAdminViaGetCCIPAdmin(address(token));
        ITokenAdminRegistry(Cfg.SUB_TOKEN_ADMIN_REGISTRY).acceptAdminRole(address(token));
        ITokenAdminRegistry(Cfg.SUB_TOKEN_ADMIN_REGISTRY).setPool(address(token), address(pool));

        // Guardian gets rateLimitAdmin (fast lane throttle) regardless of the admin handoff — a
        // distinct GUARDIAN on a non-handoff run must not silently skip this wiring.
        pool.setRateLimitAdmin(guardian);

        if (custodian != deployer) {
            // Registry admin + pool ownership go to the OPERATOR, for EVERY token including this
            // first one. Uniformity is the point: a token registered by the operator (via
            // ccipAdmin) already lands there, so sending only the deploy-time token to the
            // timelock would mean "who can setPool on token X" depended on when X was listed —
            // exactly the question you do not want to have to research during an incident.
            //
            // The cost is explicit: setPool is the repoint-the-pool vector and it is now undelayed
            // for all tokens. Root still bounds it — DEFAULT_ADMIN owns setCcipAdmin, so it
            // decides who may register future tokens at all, and can walk any token's registry
            // admin back with transferAdminRole + acceptAdminRole.
            ITokenAdminRegistry(Cfg.SUB_TOKEN_ADMIN_REGISTRY).transferAdminRole(address(token), custodian);
            pool.transferOwnership(custodian);
        }
    }

    /// @dev Moves every vault privilege off the deployer. OPERATOR/GUARDIAN are one-step grants
    ///      straight to their targets; vault DEFAULT_ADMIN goes through the 2-step + delayed
    ///      acceptDefaultAdminTransfer(). Retire the deployer key only AFTER the accept lands.
    function _handoffVault(
        AlphaVault vault,
        address deployer,
        address admin,
        address operator,
        address guardian,
        bool handoff
    ) internal {
        require(admin != address(0) && operator != address(0) && guardian != address(0), "handoff: zero addr");

        vault.grantRole(vault.OPERATOR_ROLE(), operator);
        vault.grantRole(vault.GUARDIAN_ROLE(), guardian);

        // Point getCCIPAdmin() at the operator so FUTURE listings complete on the fast lane. Must
        // happen after this run's own CCIP registration, which needed ccipAdmin == deployer.
        vault.setCcipAdmin(operator);

        if (admin != deployer) {
            // The deployer's temporary OPERATOR (needed to list) goes back before root does —
            // while the deployer is still DEFAULT_ADMIN and can still revoke it.
            if (operator != deployer) vault.revokeRole(vault.OPERATOR_ROLE(), deployer);
            vault.beginDefaultAdminTransfer(admin);
        }

        if (handoff) {
            require(!vault.hasRole(vault.OPERATOR_ROLE(), deployer), "handoff: deployer still OPERATOR");
            require(!vault.hasRole(vault.GUARDIAN_ROLE(), deployer), "handoff: deployer still GUARDIAN");
            require(vault.ccipAdmin() == operator, "handoff: ccipAdmin not on the operator");
            (address pending,) = vault.pendingDefaultAdmin();
            require(pending == admin, "handoff: admin transfer not pending");
        }

        console2.log("admin (DEFAULT_ADMIN, pending accept):", admin);
        console2.log("operator (OPERATOR_ROLE):             ", operator);
        console2.log("guardian (GUARDIAN_ROLE):             ", guardian);
    }

    /// @dev blake2b_256("evm:" + addr), the substrate coldkey an EVM address maps to. Not an EVM
    ///      primitive, so this shells out via `vm.ffi` — run these scripts with `--ffi`.
    function _coldkeyFor(address addr) internal returns (bytes32) {
        string[] memory cmd = new string[](3);
        cmd[0] = "python3";
        cmd[1] = "scripts/evm-coldkey.py";
        cmd[2] = vm.toString(addr);
        bytes memory out = vm.ffi(cmd);
        require(out.length == 32, "evm-coldkey helper did not return 32 bytes");
        return bytes32(out);
    }
}
