// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal interface the gateway needs from the multi-token AlphaVault.
interface IAlphaVault {
    /// Stake native TAO into `token`'s position, mint the measured alpha received to the caller.
    function depositLiquid(address token, uint256 minAlphaRao) external payable returns (uint256 minted);

    /// Pull the CALLER's existing staked alpha into `token`'s position and mint the measured amount.
    /// Zero slippage. Caller must have approved the vault on 0x805 for the token's netuid.
    function depositStaked(address token, uint256 alphaRao) external returns (uint256 minted);

    /// Burn `wad` of `token`, transfer the corresponding staked alpha to `destColdkey` (zero slippage).
    function withdrawStaked(address token, uint256 wad, bytes32 destColdkey) external;

    /// Burn `wad` of `token`, unstake to native TAO, send to caller (bounded by minTaoOut).
    function withdrawLiquid(address token, uint256 wad, uint256 minTaoOut) external returns (uint256 taoOut);

    /// True while the vault is halted (global, all tokens): deposits, withdrawals, skims and root
    /// claims revert. `executeMigration`, `migrateValidator` and `sweepExcess` are NOT gated by it.
    function isPaused() external view returns (bool);

    /// The token's (validator, netuid) position — reverts for unlisted tokens.
    function positionOf(address token) external view returns (bytes32 validator, uint256 netuid);

    function isListed(address token) external view returns (bool);

    /// The vault's EVM-mapped substrate coldkey. Read when announcing a migration, so a target
    /// that reports a different coldkey than the one supplied is rejected before any backing moves.
    function vaultColdkey() external view returns (bytes32);

    /// Where emissions — and now the bridge fee markup — are routed. Read live rather than
    /// mirrored, so there is one place to change it and no second copy to drift.
    function emissionsRecipient() external view returns (address);
    function STAKING() external view returns (address);

    /// Role check the gateway delegates its own admin authority to (vault DEFAULT_ADMIN_ROLE),
    /// so the gateway holds no key of its own. Checked at call time: any delay depends on the
    /// role holder.
    function hasRole(bytes32 role, address account) external view returns (bool);

    /// The address AlphaToken.getCCIPAdmin() resolves to — the account CCIP requires as msg.sender
    /// for `registerAdminViaGetCCIPAdmin`, normally the OPERATOR multisig. Set by DEFAULT_ADMIN.
    function ccipAdmin() external view returns (address);
}
