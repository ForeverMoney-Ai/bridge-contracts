// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AlphaVault} from "../src/AlphaVault.sol";
import {AlphaToken} from "../src/AlphaToken.sol";
import {IStaking} from "../src/interfaces/IStaking.sol";
import {MockStakingP} from "./mocks/MockStakingP.sol";

/// Covers the two v4 vault additions: root claiming, and migration behind a notice period.
contract VaultClaimMigrateTest is Test {
    MockStakingP staking;
    AlphaVault vault;
    AlphaVault target; // migration destination
    AlphaToken wtao;

    bytes32 constant VAL = bytes32(uint256(0x5A11));
    address recipient = makeAddr("recipient");
    address alice = makeAddr("alice");
    address owner = address(this);
    uint256 constant RAO = 1e9;

    event RootClaimed(address indexed token, uint256 alphaGained);
    event MigrationInitiated(address indexed target, bytes32 targetColdkey, uint256 readyAt);
    event MigrationCancelled(address indexed target);
    event MigrationExecuted(address indexed token, address indexed target, uint256 alphaRao);

    function setUp() public {
        staking = new MockStakingP();
        bytes32 ck = staking.ck(vm.computeCreateAddress(address(this), vm.getNonce(address(this))));
        vault = new AlphaVault(IStaking(address(staking)), ck, recipient, owner);
        wtao = new AlphaToken(address(vault), "TAO", "TAO");
        vault.grantRole(vault.OPERATOR_ROLE(), owner);
        vault.grantRole(vault.GUARDIAN_ROLE(), owner);
        vault.addToken(address(wtao), VAL, 0);

        bytes32 tck = staking.ck(vm.computeCreateAddress(address(this), vm.getNonce(address(this))));
        target = new AlphaVault(IStaking(address(staking)), tck, recipient, owner);

        vm.deal(alice, 100 ether);
    }

    receive() external payable {}

    function _ck() internal view returns (bytes32) {
        return staking.ck(address(vault));
    }

    function _deposit(uint256 tao) internal {
        vm.prank(alice);
        vault.depositLiquid{value: tao}(address(wtao), 0);
    }

    // ------------------------------------------------------------------ claiming

    function test_claimRootMovesBasketIntoStakeAndReportsIt() public {
        _deposit(10 ether);
        uint256 before = vault.backing(address(wtao));

        staking.setClaimable(VAL, _ck(), 0, 3 * RAO); // 3 TAO of basket entitlement

        vm.expectEmit(true, false, false, true);
        emit RootClaimed(address(wtao), 3 * RAO);
        uint256 gained = vault.claimRoot(address(wtao));

        assertEq(gained, 3 * RAO, "must report what the claim actually paid");
        // backing() reports wei-scaled alpha (RAO x 1e9); stakedValueRao is the RAO figure.
        assertEq(vault.backing(address(wtao)) - before, 3 * RAO * RAO, "proceeds land as backing");
    }

    /// The whole point of claiming: it is what makes skim() callable. Before a claim the surplus
    /// over supply is zero and skim reverts; after, the claimed amount is harvestable.
    function test_claimUnblocksSkim() public {
        _deposit(10 ether);
        assertEq(vault.harvestableAlphaRao(address(wtao)), 0);
        vm.expectRevert(AlphaVault.NothingToSkim.selector);
        vault.skim(address(wtao), 0);

        staking.setClaimable(VAL, _ck(), 0, 2 * RAO);
        vault.claimRoot(address(wtao));

        uint256 h = vault.harvestableAlphaRao(address(wtao));
        assertGt(h, 0, "claimed alpha must become harvestable");
        vault.skim(address(wtao), 0);
    }

    function test_claimRootForUsesTheTokensValidator() public {
        _deposit(5 ether);
        staking.setClaimable(VAL, _ck(), 0, RAO);
        assertEq(vault.claimRootFor(address(wtao)), RAO);
    }

    /// NOT permissionless. The claim liquidates the basket at market with no slippage bound at
    /// all, so a stranger could pick a manipulated moment and burn emissions value for free.
    /// Hard-wiring the destination bounds who gets paid, not what the sale fetches.
    function test_claimIsOperatorOnly() public {
        _deposit(5 ether);
        staking.setClaimable(VAL, _ck(), 0, RAO);

        vm.prank(alice);
        vm.expectRevert();
        vault.claimRoot(address(wtao));

        vm.prank(alice);
        vm.expectRevert();
        vault.claimRootFor(address(wtao));

        assertEq(vault.claimRoot(address(wtao)), RAO, "operator still can");
    }

    function test_claimWithNothingOwedIsZeroNotRevert() public {
        _deposit(5 ether);
        assertEq(vault.claimRoot(address(wtao)), 0);
    }

    function test_claimRejectsUnlistedToken() public {
        AlphaToken other = new AlphaToken(address(vault), "X", "X");
        vm.expectRevert();
        vault.claimRoot(address(other));
    }

    // ------------------------------------------------------------------ migration

    function test_initiateStartsClockAndFreezesDeposits() public {
        _deposit(10 ether);

        vm.expectEmit(true, false, false, true);
        emit MigrationInitiated(address(target), staking.ck(address(target)),
                                block.timestamp + vault.MIGRATION_DELAY());
        vault.initiateMigration(address(target), staking.ck(address(target)));

        // deposits shut immediately: a notice period is meaningless if people can keep buying in
        vm.prank(alice);
        vm.expectRevert(AlphaVault.MigrationInProgress.selector);
        vault.depositLiquid{value: 1 ether}(address(wtao), 0);
    }

    /// Withdrawals must stay open, or the notice period is a lock-in rather than an exit window.
    function test_withdrawalsStayOpenDuringNotice() public {
        _deposit(10 ether);
        vault.initiateMigration(address(target), staking.ck(address(target)));

        uint256 bal = wtao.balanceOf(alice);
        vm.prank(alice);
        vault.withdrawLiquid(address(wtao), bal, 0);
        assertEq(wtao.balanceOf(alice), 0, "holder must be able to leave");
    }

    function test_rejectsTargetWhoseColdkeyDoesNotMatch() public {
        vm.expectRevert(AlphaVault.ColdkeyMismatch.selector);
        vault.initiateMigration(address(target), bytes32(uint256(0xDEAD)));
    }

    function test_cannotInitiateTwice() public {
        // Resolve the coldkey BEFORE arming expectRevert: staking.ck() is an external call and
        // would otherwise consume the cheatcode instead of initiateMigration.
        bytes32 tck = staking.ck(address(target));
        vault.initiateMigration(address(target), tck);
        vm.expectRevert(AlphaVault.MigrationPending.selector);
        vault.initiateMigration(address(target), tck);
    }

    function test_cancelReopensDeposits() public {
        _deposit(1 ether);
        vault.initiateMigration(address(target), staking.ck(address(target)));
        vm.expectEmit(true, false, false, false);
        emit MigrationCancelled(address(target));
        vault.cancelMigration();

        vm.prank(alice);
        vault.depositLiquid{value: 1 ether}(address(wtao), 0); // must not revert
    }

    function test_executeBeforeDelayReverts() public {
        _deposit(10 ether);
        vault.initiateMigration(address(target), staking.ck(address(target)));
        vm.warp(block.timestamp + 6 days);
        vm.expectRevert(AlphaVault.MigrationNotReady.selector);
        vault.executeMigration(address(wtao));
    }

    /// Migration executes with supply STILL OUTSTANDING. The notice window is the protection,
    /// not a supply check: holders who did not use their seven days keep tokens this vault can no
    /// longer honour. Asserted so the consequence is stated by the suite, not discovered later.
    function test_executeProceedsWithSupplyOutstanding() public {
        _deposit(10 ether);
        vault.initiateMigration(address(target), staking.ck(address(target)));
        vm.warp(block.timestamp + 8 days);

        uint256 supplyBefore = wtao.totalSupply();
        assertGt(supplyBefore, 0, "precondition: holders still hold");

        uint256 moved = vault.executeMigration(address(wtao));
        assertGt(moved, 0, "backing moves regardless of outstanding supply");
        assertEq(wtao.totalSupply(), supplyBefore, "their tokens still exist");
        assertEq(vault.backing(address(wtao)), 0, "and are backed by nothing here");
    }

    /// The reason execute and finish are separate: a vault listing several tokens must move each
    /// one before anything is finalised. Execute stays callable across tokens; nothing closes
    /// until finishMigration says so.
    function test_executeIsPerTokenAndDoesNotEndTheMigration() public {
        AlphaToken sn8 = new AlphaToken(address(vault), "Subnet 8", "SN8");
        vault.addToken(address(sn8), bytes32(uint256(0xB0B2)), 8);

        _deposit(10 ether);
        vault.initiateMigration(address(target), staking.ck(address(target)));
        vm.warp(block.timestamp + 8 days);

        vault.executeMigration(address(wtao));
        assertGt(vault.migrationReadyAt(), 0, "migration stays open after one token");
        assertEq(vault.migrationTarget(), address(target), "target is still set");

        staking.accrue(bytes32(uint256(0xB0B2)), _ck(), 8, 5 * RAO);
        assertEq(vault.executeMigration(address(sn8)), 5 * RAO, "second token still movable");
    }

    function test_finishRetiresTheVaultAndHaltsIt() public {
        _deposit(10 ether);
        vault.initiateMigration(address(target), staking.ck(address(target)));
        vm.warp(block.timestamp + 8 days);
        vault.executeMigration(address(wtao));

        assertFalse(vault.isPaused(), "not halted until finish");
        vault.finishMigration();

        assertTrue(vault.migrationFinished(), "retired");
        assertTrue(vault.isPaused(), "finishing halts every value route");
        assertEq(vault.migrationReadyAt(), 0, "pending state cleared");
        assertEq(vault.migrationTarget(), address(0));
    }

    /// Retirement must be one-way. If a finished vault could re-announce, cancelMigration would
    /// clear the flag path and reopen deposits into a vault whose backing has already left.
    function test_finishedVaultCanNeverReopenDeposits() public {
        _deposit(10 ether);
        vault.initiateMigration(address(target), staking.ck(address(target)));
        vm.warp(block.timestamp + 8 days);
        vault.executeMigration(address(wtao));
        vault.finishMigration();

        bytes32 tck = staking.ck(address(target));
        vm.expectRevert(AlphaVault.MigrationAlreadyFinished.selector);
        vault.initiateMigration(address(target), tck);

        // even with the halt lifted, deposits stay shut forever
        vault.unpause();
        assertFalse(vault.isPaused());
        vm.prank(alice);
        vm.expectRevert(AlphaVault.MigrationInProgress.selector);
        vault.depositLiquid{value: 1 ether}(address(wtao), 0);
    }

    /// The halt must stay liftable: a listed token may still hold real backing its holders need
    /// to exit, and an unliftable halt would be a second stranding on top of the first.
    function test_theFinishHaltCanBeLifted() public {
        _deposit(10 ether);
        vault.initiateMigration(address(target), staking.ck(address(target)));
        vm.warp(block.timestamp + 8 days);
        vault.executeMigration(address(wtao));
        vault.finishMigration();

        assertTrue(vault.isPaused());
        vault.unpause();
        assertFalse(vault.isPaused(), "OPERATOR can reopen the exit");
    }

    /// Cancellation is a way back only while nothing has left. After the first executeMigration
    /// the vault has less backing than its tokens claim, so reopening deposits would put a new
    /// depositor's stake underneath holders whose backing already moved -- they could withdraw
    /// against the newcomer's money.
    function test_cancelIsRefusedOnceAnythingHasMoved() public {
        _deposit(10 ether);
        vault.initiateMigration(address(target), staking.ck(address(target)));
        vm.warp(block.timestamp + 8 days);
        vault.executeMigration(address(wtao));

        vm.expectRevert(AlphaVault.MigrationIrreversible.selector);
        vault.cancelMigration();

        // and therefore deposits can never reopen by that route
        vm.prank(alice);
        vm.expectRevert(AlphaVault.MigrationInProgress.selector);
        vault.depositLiquid{value: 1 ether}(address(wtao), 0);
    }

    /// Cancelling BEFORE anything moves must still work -- that is the whole point of the notice
    /// period being an announcement rather than a commitment.
    function test_cancelStillWorksBeforeAnyMove() public {
        _deposit(10 ether);
        vault.initiateMigration(address(target), staking.ck(address(target)));
        vm.warp(block.timestamp + 8 days);

        vault.cancelMigration();
        vm.prank(alice);
        vault.depositLiquid{value: 1 ether}(address(wtao), 0); // must not revert
    }

    /// Claim proceeds always land on ROOT. Measuring them against a subnet token's ledger would
    /// report 0 while real root stake appeared that no token's backing represents.
    function test_claimRejectsSubnetTokens() public {
        AlphaToken sn8 = new AlphaToken(address(vault), "Subnet 8", "SN8");
        vault.addToken(address(sn8), bytes32(uint256(0xB0B2)), 8);

        vm.expectRevert(abi.encodeWithSelector(AlphaVault.NotRootToken.selector, uint256(8)));
        vault.claimRoot(address(sn8));

        vm.expectRevert(abi.encodeWithSelector(AlphaVault.NotRootToken.selector, uint256(8)));
        vault.claimRootFor(address(sn8));
    }

    function test_finishRequiresAnAnnouncedMigration() public {
        vm.expectRevert(AlphaVault.MigrationNotInitiated.selector);
        vault.finishMigration();
    }

    /// finishMigration is at least as destructive as executeMigration -- it retires the vault and
    /// halts every route -- so it carries the same two gates. Without them, initiate -> finish in
    /// one block bricks a live vault with no notice served and nothing moved.
    function test_finishRequiresTheNoticePeriod() public {
        _deposit(10 ether);
        vault.initiateMigration(address(target), staking.ck(address(target)));

        vm.expectRevert(AlphaVault.MigrationNotReady.selector);
        vault.finishMigration();
    }

    /// A migration where nothing was executed is an abandoned one, and cancelMigration is the
    /// route for that -- it reopens deposits instead of sealing the vault shut.
    function test_finishRefusesWhenNothingWasMigrated() public {
        _deposit(10 ether);
        vault.initiateMigration(address(target), staking.ck(address(target)));
        vm.warp(block.timestamp + 8 days);

        vm.expectRevert(AlphaVault.NothingMigrated.selector);
        vault.finishMigration();
    }

    function test_finishIsAdminOnly() public {
        _deposit(10 ether);
        vault.initiateMigration(address(target), staking.ck(address(target)));
        vm.warp(block.timestamp + 8 days);
        vault.executeMigration(address(wtao));

        vm.prank(alice);
        vm.expectRevert();
        vault.finishMigration();
    }

    function test_executeMovesStakeOnceEveryoneHasExited() public {
        _deposit(10 ether);
        vault.initiateMigration(address(target), staking.ck(address(target)));

        uint256 bal = wtao.balanceOf(alice);
        bytes32 aliceCk = staking.ck(alice); // hoisted: it is an external call and would eat the prank
        vm.prank(alice);
        vault.withdrawStaked(address(wtao), bal, aliceCk);
        assertEq(wtao.totalSupply(), 0);

        // re-seed a position so there is something to move (holder exited with their own)
        staking.accrue(VAL, _ck(), 0, 4 * RAO);
        vm.warp(block.timestamp + 8 days);

        uint256 moved = vault.executeMigration(address(wtao));
        assertEq(moved, 4 * RAO);
        assertEq(staking.getStake(VAL, staking.ck(address(target)), 0), 4 * RAO,
                 "stake must land on the target's coldkey");
        assertEq(vault.backing(address(wtao)), 0, "old vault is emptied");
    }

    /// The notice window is the ONLY protection, so it must actually hold: before the delay
    /// elapses, migration is refused however much supply has left.
    function test_noticeWindowIsEnforcedEvenWithSupplyGone() public {
        _deposit(10 ether);
        vault.initiateMigration(address(target), staking.ck(address(target)));

        uint256 bal = wtao.balanceOf(alice);
        bytes32 aliceCk = staking.ck(alice);
        vm.prank(alice);
        vault.withdrawStaked(address(wtao), bal, aliceCk);

        vm.warp(block.timestamp + 6 days); // one day short
        vm.expectRevert(AlphaVault.MigrationNotReady.selector);
        vault.executeMigration(address(wtao));
    }

    function test_executeWithoutInitiateReverts() public {
        _deposit(1 ether);
        vm.expectRevert(AlphaVault.MigrationNotInitiated.selector);
        vault.executeMigration(address(wtao));
    }

    function test_migrationIsAdminOnly() public {
        bytes32 tck = staking.ck(address(target));
        vm.startPrank(alice);
        vm.expectRevert();
        vault.initiateMigration(address(target), tck);
        vm.expectRevert();
        vault.cancelMigration();
        vm.expectRevert();
        vault.executeMigration(address(wtao));
        vm.stopPrank();
    }
}
