// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Subtensor-EVM staking precompile V2, at 0x0000000000000000000000000000000000000805.
/// @dev  IMPORTANT: amounts are RAO (9-decimal, 1 TAO = 1e9), NOT 18-decimal wei. V2 takes the
///       amount as an explicit argument and does NOT read msg.value (send msg.value = 0). The TAO
///       is debited from / credited to the caller's mapped substrate coldkey; on Subtensor EVM the
///       caller's native EVM balance reflects that credit synchronously within the same tx
///       (verified on mainnet). `getStake` returns alpha (RAO); on root (netuid 0) alpha ≈ TAO 1:1.
interface IStaking {
    function addStake(bytes32 hotkey, uint256 amount, uint256 netuid) external payable;
    function removeStake(bytes32 hotkey, uint256 amount, uint256 netuid) external payable;
    function moveStake(
        bytes32 originHotkey,
        bytes32 destinationHotkey,
        uint256 originNetuid,
        uint256 destinationNetuid,
        uint256 amount
    ) external payable;

    function transferStake(
        bytes32 destinationColdkey,
        bytes32 hotkey,
        uint256 originNetuid,
        uint256 destinationNetuid,
        uint256 amount
    ) external payable;

    function transferStakeFrom(
        address sourceAddress,
        address destinationAddress,
        bytes32 hotkey,
        uint256 originNetuid,
        uint256 destinationNetuid,
        uint256 amount
    ) external;

    function approve(address spenderAddress, uint256 netuid, uint256 absoluteAmount) external;

    function allowance(address sourceAddress, address spenderAddress, uint256 netuid)
        external
        view
        returns (uint256);

    /// @notice Redeem accrued beta-basket ("Root Reborn") entitlement for the caller's mapped
    ///         coldkey. The runtime sells the basket share to TAO and stakes it on root, so the
    ///         proceeds land as stake under the SAME coldkey — the destination is not a parameter
    ///         and cannot be redirected.
    /// @dev `subnets` is ignored by the runtime; it is retained only so pre-basket clients' encoded
    ///      calldata still decodes. Pass an empty array. Returns nothing: the amount paid is only
    ///      observable as the change in `getStake`.
    function claimRoot(uint16[] calldata subnets) external;

    /// @notice As `claimRoot`, restricted to one validator's basket.
    function claimRootWithHotkey(bytes32 hotkey) external;

    function getStake(bytes32 hotkey, bytes32 coldkey, uint256 netuid) external view returns (uint256);
    function getNominatorMinRequiredStake() external view returns (uint256);
}
