// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal interface the vault needs from a AlphaToken token.
interface IAlphaToken {
    function VAULT() external view returns (address);
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}
