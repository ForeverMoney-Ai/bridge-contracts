// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AlphaVault} from "../src/AlphaVault.sol";
import {AlphaToken} from "../src/AlphaToken.sol";
import {AlphaGateway} from "../src/AlphaGateway.sol";
import {IntegratorFee} from "../src/IntegratorFee.sol";
import {StakeSource} from "../src/StakeSource.sol";
import {IStaking} from "../src/interfaces/IStaking.sol";
import {MockStakingP} from "./mocks/MockStakingP.sol";
import {MockRouter} from "./mocks/MockRouter.sol";
import {MockExit} from "./mocks/MockExit.sol";

/// Wrapping alpha that is delegated to the USER's OWN validators, not the token's.
///
/// `transferStakeFrom` takes ONE hotkey, so a pull lands on the hotkey it came from. Substrate
/// solves this in a single `transfer_stake_and_hotkey`, batched via `Utility.batch` — neither is
/// exposed to the EVM (verified against the live 0x805), so the gateway pulls each position under
/// its own hotkey and re-delegates with `moveStake` before depositing.
contract MultiValidatorDepositTest is Test {
    MockStakingP staking;
    AlphaVault vault;
    AlphaToken wtao;
    MockRouter router;
    AlphaGateway gw;

    bytes32 constant CANON = bytes32(uint256(0x5A11)); // the token's canonical validator
    bytes32 constant V1 = bytes32(uint256(0xA1));      // validators the user picked themselves
    bytes32 constant V2 = bytes32(uint256(0xA2));
    bytes32 constant V3 = bytes32(uint256(0xA3));
    uint64 constant BASE_SEL = 111;
    uint256 constant FEE = 0.001 ether;
    uint256 constant NETUID = 0;

    address emissions = makeAddr("emissions");
    address rescuer = makeAddr("rescuer");
    address dest = makeAddr("dest");
    address user = makeAddr("user");
    address integrator = makeAddr("integrator");
    address owner = address(this);
    address constant EXIT = 0x0000000000000000000000000000000000000800;

    function setUp() public {
        staking = new MockStakingP();
        bytes32 vck = staking.ck(vm.computeCreateAddress(address(this), vm.getNonce(address(this))));
        vault = new AlphaVault(IStaking(address(staking)), vck, emissions, owner);
        wtao = new AlphaToken(address(vault), "TAO", "TAO");
        vault.grantRole(vault.OPERATOR_ROLE(), owner);
        vault.addToken(address(wtao), CANON, NETUID);
        router = new MockRouter(FEE);
        gw = new AlphaGateway(address(router), address(vault), BASE_SEL, rescuer,
            staking.ck(vm.computeCreateAddress(address(this), vm.getNonce(address(this)))));
        vm.etch(EXIT, type(MockExit).runtimeCode);
        vm.deal(user, 100 ether);
    }

    receive() external payable {}

    /// Give `user` a real position on `hotkey` and let the gateway pull from it.
    function _seed(bytes32 hotkey, uint256 alphaRao) internal {
        staking.seed(hotkey, user, NETUID, alphaRao);
        vm.prank(user);
        staking.approve(address(gw), NETUID, type(uint256).max);
    }

    function _src(bytes32 v, uint256 a) internal pure returns (StakeSource[] memory s) {
        s = new StakeSource[](1);
        s[0] = StakeSource({validator: v, alphaRao: a});
    }

    function _userStake(bytes32 hotkey) internal view returns (uint256) {
        return staking.getStake(hotkey, staking.ck(user), NETUID);
    }

    function _gwStake(bytes32 hotkey) internal view returns (uint256) {
        return staking.getStake(hotkey, staking.ck(address(gw)), NETUID);
    }

    // ---------------------------------------------------------------- the core fix

    function test_singleForeignValidator_isRedelegatedAndWrapped() public {
        _seed(V1, 1_000);
        uint256 backing0 = vault.backing(address(wtao));

        vm.prank(user);
        gw.bridgeOutFromValidators{value: FEE}(BASE_SEL, address(wtao), dest, 0, _src(V1, 1_000), 0);

        assertEq(_userStake(V1), 0, "user position drained");
        assertEq(_gwStake(V1), 0, "nothing stranded on the foreign hotkey");
        assertEq(vault.backing(address(wtao)) - backing0, 1_000 * 1e9, "backing grew by the full amount");
    }

    function test_threeValidators_consolidateIntoOneDeposit() public {
        _seed(V1, 1_000);
        _seed(V2, 2_500);
        _seed(V3, 400);
        uint256 backing0 = vault.backing(address(wtao));

        StakeSource[] memory s = new StakeSource[](3);
        s[0] = StakeSource({validator: V1, alphaRao: 1_000});
        s[1] = StakeSource({validator: V2, alphaRao: 2_500});
        s[2] = StakeSource({validator: V3, alphaRao: 400});

        vm.prank(user);
        gw.bridgeOutFromValidators{value: FEE}(BASE_SEL, address(wtao), dest, 0, s, 0);

        assertEq(vault.backing(address(wtao)) - backing0, 3_900 * 1e9, "all three consolidated");
        assertEq(_gwStake(V1) + _gwStake(V2) + _gwStake(V3), 0, "no intermediate positions left");
        assertEq(_userStake(V1), 0);
        assertEq(_userStake(V2), 0);
        assertEq(_userStake(V3), 0);
    }

    function test_partialPull_leavesTheRestWithTheUsersValidator() public {
        _seed(V1, 1_000);
        vm.prank(user);
        gw.bridgeOutFromValidators{value: FEE}(BASE_SEL, address(wtao), dest, 0, _src(V1, 600), 0);
        assertEq(_userStake(V1), 400, "caller keeps the remainder on their own validator");
    }

    function test_canonicalValidatorNeedsNoMove() public {
        _seed(CANON, 1_000);
        uint256 backing0 = vault.backing(address(wtao));
        vm.prank(user);
        gw.bridgeOutFromValidators{value: FEE}(BASE_SEL, address(wtao), dest, 0, _src(CANON, 1_000), 0);
        assertEq(vault.backing(address(wtao)) - backing0, 1_000 * 1e9);
    }

    function test_mixedCanonicalAndForeign() public {
        _seed(CANON, 700);
        _seed(V1, 300);
        uint256 backing0 = vault.backing(address(wtao));
        StakeSource[] memory s = new StakeSource[](2);
        s[0] = StakeSource({validator: CANON, alphaRao: 700});
        s[1] = StakeSource({validator: V1, alphaRao: 300});
        vm.prank(user);
        gw.bridgeOutFromValidators{value: FEE}(BASE_SEL, address(wtao), dest, 0, s, 0);
        assertEq(vault.backing(address(wtao)) - backing0, 1_000 * 1e9);
    }

    function test_stakedPlusLiquidInOneCall() public {
        _seed(V1, 1_000);
        uint256 backing0 = vault.backing(address(wtao));
        uint256 taoWei = 1e18; // 1 TAO = 1e9 RAO, comfortably over the runtime minimum
        vm.prank(user);
        gw.bridgeOutFromValidators{value: FEE + taoWei}(BASE_SEL, address(wtao), dest, taoWei, _src(V1, 1_000), 0);
        assertEq(vault.backing(address(wtao)) - backing0, (1e9 + 1_000) * 1e9, "liquid and staked legs both landed");
        assertEq(_userStake(V1), 0, "staked source drained");
    }

    // ---------------------------------------------------------------- validation

    function test_emptySourcesReverts() public {
        vm.prank(user);
        vm.expectRevert(AlphaGateway.NoStakeSources.selector);
        gw.bridgeOutFromValidators{value: FEE}(BASE_SEL, address(wtao), dest, 0, new StakeSource[](0), 0);
    }

    function test_tooManySourcesReverts() public {
        uint256 n = gw.MAX_STAKE_SOURCES() + 1;
        StakeSource[] memory s = new StakeSource[](n);
        for (uint256 i; i < n; ++i) s[i] = StakeSource({validator: bytes32(uint256(0xB0 + i)), alphaRao: 1});
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(AlphaGateway.TooManyStakeSources.selector, n, gw.MAX_STAKE_SOURCES()));
        gw.bridgeOutFromValidators{value: FEE}(BASE_SEL, address(wtao), dest, 0, s, 0);
    }

    function test_maxSourcesIsAllowed() public {
        uint256 n = gw.MAX_STAKE_SOURCES();
        StakeSource[] memory s = new StakeSource[](n);
        for (uint256 i; i < n; ++i) {
            bytes32 v = bytes32(uint256(0xB0 + i));
            staking.seed(v, user, NETUID, 100);
            s[i] = StakeSource({validator: v, alphaRao: 100});
        }
        vm.prank(user);
        staking.approve(address(gw), NETUID, type(uint256).max);
        uint256 backing0 = vault.backing(address(wtao));
        vm.prank(user);
        gw.bridgeOutFromValidators{value: FEE}(BASE_SEL, address(wtao), dest, 0, s, 0);
        assertEq(vault.backing(address(wtao)) - backing0, 100 * n * 1e9, "the cap itself works");
    }

    function test_duplicateValidatorReverts() public {
        _seed(V1, 1_000);
        StakeSource[] memory s = new StakeSource[](2);
        s[0] = StakeSource({validator: V1, alphaRao: 100});
        s[1] = StakeSource({validator: V1, alphaRao: 100});
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(AlphaGateway.DuplicateStakeSource.selector, V1));
        gw.bridgeOutFromValidators{value: FEE}(BASE_SEL, address(wtao), dest, 0, s, 0);
    }

    function test_zeroValidatorAndZeroAmountRevert() public {
        _seed(V1, 1_000);
        vm.prank(user);
        vm.expectRevert(AlphaGateway.ZeroValidator.selector);
        gw.bridgeOutFromValidators{value: FEE}(BASE_SEL, address(wtao), dest, 0, _src(bytes32(0), 100), 0);

        vm.prank(user);
        vm.expectRevert(AlphaGateway.ZeroAmount.selector);
        gw.bridgeOutFromValidators{value: FEE}(BASE_SEL, address(wtao), dest, 0, _src(V1, 0), 0);
    }

    function test_constructorRejectsZeroColdkey() public {
        vm.expectRevert(AlphaGateway.ZeroColdkey.selector);
        new AlphaGateway(address(router), address(vault), BASE_SEL, rescuer, bytes32(0));
    }

    function test_minStakeRequiredIsExposedForPlanning() public view {
        assertEq(gw.minStakeRequired(), staking.getNominatorMinRequiredStake());
    }

    // ---------------------------------------------------------------- integrator fee

    function test_integratorCutIsProRataAcrossEverySource() public {
        _seed(V1, 10_000);
        _seed(V2, 10_000);
        gw.setMaxIntegratorFeeBps(100);

        // 3_000 + 1_000 = 4_000 total; 1% = 40 cut, split 30/10 in the caller's own proportions.
        StakeSource[] memory s = new StakeSource[](2);
        s[0] = StakeSource({validator: V1, alphaRao: 3_000});
        s[1] = StakeSource({validator: V2, alphaRao: 1_000});

        vm.prank(user);
        gw.bridgeOutFromValidatorsWithFee{value: FEE}(
            BASE_SEL, address(wtao), dest, 0, s, 0, IntegratorFee(integrator, 100)
        );

        assertEq(wtao.balanceOf(integrator), 40 * 1e9, "fee is 1% of the TOTAL, paid on top");
        assertEq(_userStake(V1), 10_000 - 3_000 - 30, "V1 bore 3/4 of the cut");
        assertEq(_userStake(V2), 10_000 - 1_000 - 10, "V2 bore 1/4 of the cut");
    }

    function test_apportionedCutSumsExactly_dustToFirstSource() public {
        _seed(V1, 10_000);
        _seed(V2, 10_000);
        _seed(V3, 10_000);
        gw.setMaxIntegratorFeeBps(100);

        // 1_000 each => 3_000 total, 1% = 30, which splits 10/10/10 with no dust; use an
        // indivisible split instead: 1_000 / 1_000 / 1_001 => total 3_001, cut 30.
        StakeSource[] memory s = new StakeSource[](3);
        s[0] = StakeSource({validator: V1, alphaRao: 1_000});
        s[1] = StakeSource({validator: V2, alphaRao: 1_000});
        s[2] = StakeSource({validator: V3, alphaRao: 1_001});

        vm.prank(user);
        gw.bridgeOutFromValidatorsWithFee{value: FEE}(
            BASE_SEL, address(wtao), dest, 0, s, 0, IntegratorFee(integrator, 100)
        );

        // Whatever the rounding, the integrator gets exactly the cut and the sources gave exactly
        // total + cut between them.
        uint256 taken = (10_000 - _userStake(V1)) + (10_000 - _userStake(V2)) + (10_000 - _userStake(V3));
        assertEq(wtao.balanceOf(integrator), 30 * 1e9, "integrator paid the exact cut");
        assertEq(taken, 3_001 + 30, "sources gave exactly the total plus the cut, no more");
    }

    function test_feeNeverRaidsBeyondTheListedAmountsPlusItsOwnShare() public {
        // The failure this replaces: the cut used to come entirely out of sources[0], so a caller
        // who listed their WHOLE first position had the bridge revert, and a caller with spare
        // alpha there had it taken without asking.
        _seed(V1, 5_000);
        _seed(V2, 5_000);
        gw.setMaxIntegratorFeeBps(100);
        StakeSource[] memory s = new StakeSource[](2);
        s[0] = StakeSource({validator: V1, alphaRao: 4_000});
        s[1] = StakeSource({validator: V2, alphaRao: 4_000});
        vm.prank(user);
        gw.bridgeOutFromValidatorsWithFee{value: FEE}(
            BASE_SEL, address(wtao), dest, 0, s, 0, IntegratorFee(integrator, 100)
        );
        // 8_000 total, 1% = 80, split 40/40 — each position keeps 1_000 - 40.
        assertEq(_userStake(V1), 960);
        assertEq(_userStake(V2), 960);
        assertEq(wtao.balanceOf(integrator), 80 * 1e9);
    }

    function test_zeroBpsPullsExactlyWhatWasListed() public {
        _seed(V1, 5_000);
        _seed(V2, 5_000);
        StakeSource[] memory s = new StakeSource[](2);
        s[0] = StakeSource({validator: V1, alphaRao: 4_000});
        s[1] = StakeSource({validator: V2, alphaRao: 4_000});
        vm.prank(user);
        gw.bridgeOutFromValidators{value: FEE}(BASE_SEL, address(wtao), dest, 0, s, 0);
        assertEq(_userStake(V1), 1_000, "no fee, nothing extra taken");
        assertEq(_userStake(V2), 1_000);
    }

    function test_scalarPathWithFeeUnchanged_amountPlusCut() public {
        // Regression on the SHIPPED v5 semantics: one canonical source, caller supplies amount+cut.
        _seed(CANON, 10_000);
        gw.setMaxIntegratorFeeBps(100);
        vm.prank(user);
        gw.bridgeOutWithFee{value: FEE}(
            BASE_SEL, address(wtao), dest, 0, 5_000, 0, IntegratorFee(integrator, 100)
        );
        assertEq(wtao.balanceOf(integrator), 50 * 1e9, "1% of 5_000, on top");
        assertEq(_userStake(CANON), 10_000 - 5_000 - 50, "amount + cut taken, as before");
    }

    // ---------------------------------------------------------------- regression

    function test_legacyScalarPathStillUsesTheCanonicalValidator() public {
        _seed(CANON, 1_000);
        uint256 backing0 = vault.backing(address(wtao));
        vm.prank(user);
        gw.bridgeOut{value: FEE}(BASE_SEL, address(wtao), dest, 0, 1_000, 0);
        assertEq(vault.backing(address(wtao)) - backing0, 1_000 * 1e9, "old signature unchanged");
    }

    function test_legacySelectorsUnchanged() public pure {
        assertEq(
            bytes4(keccak256("bridgeOut(uint64,address,address,uint256,uint256,uint256)")),
            bytes4(0x46101418),
            "bridgeOut selector must not move: Zodiac Roles scopes pin it"
        );
    }


}
