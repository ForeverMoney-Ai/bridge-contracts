// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Verified CCIP v1.6.0 infrastructure addresses + bridge parameters.
///         Sources: Chainlink CCIP config API (docs.chain.link/api/ccip/v1/chains), July 2026.
library Cfg {
    // --- Subtensor EVM (chain 964) ---
    address constant SUB_ROUTER = 0xD941fBEcD2b971d0F54b4C34286C95faB52B60B8;
    address constant SUB_TOKEN_ADMIN_REGISTRY = 0xe72d25aDd538E8ef9CeF85622eA8912a6CB98Be6;
    address constant SUB_REGISTRY_MODULE = 0xcDca5D374e46A6DDDab50bD2D9acB8c796eC35C3;
    address constant SUB_RMN_PROXY = 0x02A4D69cFfeC00Fbf7F3B60c93e3529Dfc58894d;
    uint64 constant SUB_SELECTOR = 2135107236357186872;

    // --- Base (chain 8453) ---
    address constant BASE_ROUTER = 0x881e3A65B4d4a04dD529061dd0071cf975F58bCD;
    address constant BASE_TOKEN_ADMIN_REGISTRY = 0x6f6C373d09C07425BaAE72317863d7F6bb731e37;
    address constant BASE_REGISTRY_MODULE = 0xAFEd606Bd2CAb6983fC6F10167c98aaC2173D77f;
    address constant BASE_RMN_PROXY = 0xC842c69d54F83170C42C4d556B4F6B2ca53Dd3E8;
    uint64 constant BASE_SELECTOR = 15971525489660198786;

    // --- Robinhood Chain (chain 4663) ---
    // Source: Chainlink CCIP config API (docs.chain.link/api/ccip/v1/chains, mainnet, Aug 2026).
    // The 964<->4663 lane is already live both directions (validated via the CCIP lanes API), so a
    // new token on it is self-serve — no Chainlink lane request needed.
    address constant RH_ROUTER = 0x06fC836cf9839B1cd891C440A0a45242DA6Ae1c9;
    address constant RH_TOKEN_ADMIN_REGISTRY = 0x1912C3cFafE8A76A32a92861d815aC2837F237Ca;
    address constant RH_REGISTRY_MODULE = 0x3237c0D7B58BEc8Dc17F00103B784Bd6678f789E;
    address constant RH_RMN_PROXY = 0xe8464c353210Cc398A45dB2454FBc5BCd25fFf20;
    uint64 constant RH_SELECTOR = 6180753054346818345;

    // --- Bridge token params ---
    uint8 constant DECIMALS = 18;

    // --- Launch rate limits (token-bucket, per remote chain per direction) ---
    // Conservative start: 5,000 tokens capacity, ~2,000/hour refill. Tune post-launch.
    uint128 constant RL_CAPACITY = 5_000 ether;
    uint128 constant RL_RATE = 0.6 ether; // ~2160 / hour
}

/// @notice Canonical token naming, derived from the netuid alone.
///
///         Deliberately NOT the subnet's own token name from Finney: those are chosen by subnet
///         owners, can change at any time, and are inconsistent in style. Deriving from the netuid
///         gives a stable, predictable symbol that cannot drift out from under a deployed token
///         (ERC20 name/symbol are immutable once constructed).
///
///           netuid 0  -> "Bittensor" / "TAO"
///           netuid 93 -> "Subnet 93" / "SN93"
///
///         Root is NAMED for the network, not the ticker: "Bittensor"/"TAO" mirrors how every
///         other chain's native asset reads (Ethereum/ETH), and a token whose name and symbol are
///         both "TAO" looks like a placeholder in wallets and listings.
library TokenNaming {
    function name(uint256 netuid) internal pure returns (string memory) {
        return netuid == 0 ? "Bittensor" : string.concat("Subnet ", _u(netuid));
    }

    function symbol(uint256 netuid) internal pure returns (string memory) {
        return netuid == 0 ? "TAO" : string.concat("SN", _u(netuid));
    }

    function _u(uint256 v) private pure returns (string memory) {
        if (v == 0) return "0";
        uint256 n = v;
        uint256 len;
        while (n != 0) { len++; n /= 10; }
        bytes memory b = new bytes(len);
        while (v != 0) { b[--len] = bytes1(uint8(48 + v % 10)); v /= 10; }
        return string(b);
    }
}

/// @notice Minimal interfaces for CCIP registry interactions.
interface IRegistryModuleOwnerCustom {
    function registerAdminViaGetCCIPAdmin(address token) external;
    function registerAdminViaOwner(address token) external;
}

interface ITokenAdminRegistry {
    /// @dev Mirrors TokenAdminRegistry.TokenConfig. `administrator` is SNAPSHOT at registration and
    ///      only moved by transferAdminRole + acceptAdminRole — it does NOT follow getCCIPAdmin().
    struct TokenConfig {
        address administrator;
        address pendingAdministrator;
        address tokenPool;
    }

    function acceptAdminRole(address localToken) external;
    function setPool(address localToken, address pool) external;
    function getPool(address token) external view returns (address);
    function getTokenConfig(address token) external view returns (TokenConfig memory);
    function transferAdminRole(address localToken, address newAdmin) external;
}
