// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TokenNaming} from "../script/Config.sol";

/// @notice Token names are derived from the netuid, never from the subnet's own Finney token name.
///         Those are owner-chosen, change over time and are stylistically inconsistent — while an
///         ERC20's name/symbol are immutable once deployed. Deriving removes the chance of a
///         deployment permanently baking in a name that later drifts or reads oddly.
contract TokenNamingTest is Test {
    function test_rootIsNamedForTheNetworkNotTheTicker() public pure {
        assertEq(TokenNaming.name(0), "Bittensor");
        assertEq(TokenNaming.symbol(0), "TAO");
    }

    function test_subnetsAreNumbered() public pure {
        assertEq(TokenNaming.name(93), "Subnet 93");
        assertEq(TokenNaming.symbol(93), "SN93");
        assertEq(TokenNaming.name(8), "Subnet 8");
        assertEq(TokenNaming.symbol(8), "SN8");
    }

    function test_multiDigitAndLargeNetuids() public pure {
        assertEq(TokenNaming.symbol(1), "SN1");
        assertEq(TokenNaming.symbol(12), "SN12");
        assertEq(TokenNaming.symbol(345), "SN345");
        assertEq(TokenNaming.symbol(1024), "SN1024");
    }

    /// @dev No "w" prefix anywhere — the whole point of the rename.
    function testFuzz_neverWrapped(uint16 netuid) public pure {
        bytes memory sym = bytes(TokenNaming.symbol(netuid));
        assertTrue(sym.length > 0);
        assertTrue(sym[0] != "w", "symbol must not be w-prefixed");
    }

    /// @dev Distinct netuids must never collide, or two tokens would be indistinguishable in a UI.
    function testFuzz_symbolsAreUnique(uint16 a, uint16 b) public pure {
        vm.assume(a != b);
        assertTrue(
            keccak256(bytes(TokenNaming.symbol(a))) != keccak256(bytes(TokenNaming.symbol(b))),
            "two netuids produced the same symbol"
        );
    }
}
