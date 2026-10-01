// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Stand-ins for Chainlink's TokenAdminRegistry + RegistryModuleOwnerCustom, faithful to
///         the parts the deploy scripts depend on:
///           - registerAdminViaGetCCIPAdmin requires msg.sender == token.getCCIPAdmin()
///           - acceptAdminRole requires msg.sender == pendingAdministrator
///           - setPool requires msg.sender == administrator AND pool.isSupportedToken(token)
///         Those three constraints are exactly what dictates the deploy ORDER, so a rehearsal
///         that mocks them loosely would prove nothing.

interface IGetCCIPAdmin {
    function getCCIPAdmin() external view returns (address);
}

interface IPoolSupports {
    function isSupportedToken(address token) external view returns (bool);
}

contract MockTokenAdminRegistry {
    struct TokenConfig {
        address administrator;
        address pendingAdministrator;
        address tokenPool;
    }

    mapping(address => TokenConfig) internal _cfg;

    error OnlyPendingAdministrator();
    error OnlyAdministrator();
    error InvalidTokenPoolToken(address token);
    error AlreadyRegistered(address token);

    function proposeAdministrator(address token, address admin) external {
        TokenConfig storage c = _cfg[token];
        if (c.administrator != address(0)) revert AlreadyRegistered(token);
        c.pendingAdministrator = admin;
    }

    function acceptAdminRole(address token) external {
        TokenConfig storage c = _cfg[token];
        if (c.pendingAdministrator != msg.sender) revert OnlyPendingAdministrator();
        c.administrator = msg.sender;
        c.pendingAdministrator = address(0);
    }

    function setPool(address token, address pool) external {
        TokenConfig storage c = _cfg[token];
        if (c.administrator != msg.sender) revert OnlyAdministrator();
        if (pool != address(0) && !IPoolSupports(pool).isSupportedToken(token)) {
            revert InvalidTokenPoolToken(token);
        }
        c.tokenPool = pool;
    }

    function transferAdminRole(address token, address newAdmin) external {
        TokenConfig storage c = _cfg[token];
        if (c.administrator != msg.sender) revert OnlyAdministrator();
        c.pendingAdministrator = newAdmin;
    }

    function getPool(address token) external view returns (address) {
        return _cfg[token].tokenPool;
    }

    function getTokenConfig(address token) external view returns (TokenConfig memory) {
        return _cfg[token];
    }
}

contract MockRegistryModuleOwnerCustom {
    address public immutable REGISTRY;

    error CanOnlySelfRegister(address admin, address token);

    constructor(address registry) {
        REGISTRY = registry;
    }

    /// @dev Mirrors the real module: the caller MUST be the address getCCIPAdmin() returns. This
    ///      is what forces every CCIP registration to happen before the governance handoff.
    function registerAdminViaGetCCIPAdmin(address token) external {
        address admin = IGetCCIPAdmin(token).getCCIPAdmin();
        if (admin != msg.sender) revert CanOnlySelfRegister(admin, token);
        MockTokenAdminRegistry(REGISTRY).proposeAdministrator(token, admin);
    }
}
