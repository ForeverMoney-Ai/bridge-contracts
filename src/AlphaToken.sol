// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IAlphaVault} from "./interfaces/IAlphaVault.sol";

/// @title AlphaToken — thin per-asset ERC20 for the multi-token AlphaVault (TAO / SN_X).
/// @notice Pure mint/burn token: ALL logic (deposits, withdrawals, backing, emissions, halt, roles)
///         lives in the vault. One of these is deployed per wrapped asset because the CCIP token
///         pools require a distinct ERC20 per asset — this contract is deliberately as small as
///         that constraint allows.
/// @dev  Immutable, no owner of its own. Only the vault can mint/burn, and the binding is fixed at
///       construction — the vault refuses to list a token whose VAULT() is not itself.
contract AlphaToken is ERC20 {
    address public immutable VAULT;

    event Initialized(address indexed vault, string name, string symbol);

    error OnlyVault();
    error ZeroVault();

    modifier onlyVault() {
        if (msg.sender != VAULT) revert OnlyVault();
        _;
    }

    constructor(address vault_, string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        if (vault_ == address(0)) revert ZeroVault();
        VAULT = vault_;
        emit Initialized(vault_, name_, symbol_);
    }

    function mint(address to, uint256 amount) external onlyVault {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyVault {
        _burn(from, amount);
    }

    /// @notice Chainlink CCT admin-discovery hook, read by `RegistryModuleOwnerCustom` during
    ///         `registerAdminViaGetCCIPAdmin`. Returns the vault's `ccipAdmin` — normally the
    ///         OPERATOR multisig, NOT the Timelock — so that listing a token is a one-step ops
    ///         action: the same key that calls `createToken` can complete the CCIP registration.
    ///         The registration caller must BE that address (the module enforces
    ///         `admin == msg.sender`). `ccipAdmin` itself is repointable only by the vault's
    ///         DEFAULT_ADMIN, so the slow tier still decides who holds this power.
    /// @dev    IMPORTANT: this is read ONCE, at registration. TokenAdminRegistry then STORES the
    ///         administrator (`config.administrator`) and never re-reads this function. Repointing
    ///         the vault's `ccipAdmin` therefore does NOT move the registry administrator — the old
    ///         one keeps `setPool` power until governance separately calls
    ///         `transferAdminRole(token, newAdmin)` and the new admin calls `acceptAdminRole(token)`.
    ///         Any rotation MUST be paired with that registry handoff for every listed token.
    function getCCIPAdmin() external view returns (address) {
        return IAlphaVault(VAULT).ccipAdmin();
    }
}
