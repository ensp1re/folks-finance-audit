// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.23;

import {ERC20Permit, ERC20} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Staking} from "../src/Staking.sol";
import {IStakingV1} from "../src/interfaces/IStakingV1.sol";

contract AuditToken is ERC20Permit {
    constructor() ERC20Permit("AuditToken") ERC20("AuditToken", "ATKN") {}
}

contract StakingAuditTest is Test {
    Staking public staking;

    address public admin = address(2);
    address public manager = address(3);
    address public migrator = address(4);
    address public pauser = address(5);
    address public alice = address(6);
    address public bob = address(7);
    address public charlie = address(8);

    AuditToken public token;

    function setUp() public {
        token = new AuditToken();
        staking = new Staking(admin, manager, pauser, address(token));

        vm.prank(admin);
        staking.grantRole(keccak256("MIGRATOR"), migrator);
    }

    // H-01 (High)
    // Bug location: `Staking.sol::migratePositionsFrom()`
    // What happens: migration consent is never cleared after a successful migration.
    // Why it matters: a previously approved migrator can drain any future stakes from the same user
    // without asking for fresh permission again.
    function test_Audit_H01_MigrationPermitRemainsUsableAfterSuccessfulMigration() public {
        deal(address(token), address(staking), 1000 ether);
        deal(address(token), alice, 100 ether);

        // Create one normal staking period and have Alice opt into migration once.
        uint8 periodIndex = addStakingPeriodByManager(100 ether, 30 days, 1 days, 5000, true);
        approveAndStake(alice, periodIndex, 10 ether, 30 days, 1 days, 5000, address(0));

        vm.prank(alice);
        staking.setMigrationPermit(migrator, true);

        // The first migration succeeds and empties Alice's active positions.
        vm.prank(migrator);
        staking.migratePositionsFrom(alice);

        // H-01: the permit is still live even after the migration completed.
        assertEq(staking.migrationPermits(migrator, alice), true);

        // Alice stakes again, assuming the previous migration authorization was one-time.
        approveAndStake(alice, periodIndex, 6 ether, 30 days, 1 days, 5000, address(0));

        // The same migrator can immediately drain the new position without renewed consent.
        uint256 migratorBalanceBefore = token.balanceOf(migrator);
        vm.prank(migrator);
        IStakingV1.UserStake[] memory migratedStakes = staking.migratePositionsFrom(alice);

        assertEq(migratedStakes.length, 1);
        assertEq(migratedStakes[0].amount, 6 ether);
        assertEq(staking.getUserStakes(alice).length, 0);
        assertGt(token.balanceOf(migrator), migratorBalanceBefore);
    }

    // H-02 (High)
    // Bug location: `Staking.sol::migratePositionsFrom()`, `Staking.sol::_stake()`, `Staking.sol::withdraw()`
    // What happens: repeated migration cycles preserve historical stakes and can keep growing the
    // user's storage footprint. The audit warns this can eventually collide with the `uint8` stake index model.
    // Current repo nuance: this public flow hits `MAX_STAKES_PER_USER` before the reported wraparound path.
    function test_Audit_H02_RepeatedMigrationCyclesHitMaxUserStakesBeforeUint8Wrap() public {
        deal(address(token), address(staking), 1000 ether);
        deal(address(token), alice, 1 ether);

        // Use one short period for stakes we can fully withdraw and one long period for stakes that stay active.
        uint8 shortPeriodIndex = addStakingPeriodByManager(1 ether, 1 days, 1 days, 0, true);
        uint8 longPeriodIndex = addStakingPeriodByManager(1 ether, 30 days, 1 days, 0, true);

        // Create 60 soon-to-be-historical stakes and 40 still-active stakes.
        for (uint256 i = 0; i < 60; i++) {
            approveAndStake(alice, shortPeriodIndex, 1 gwei, 1 days, 1 days, 0, address(0));
        }
        for (uint256 i = 0; i < 40; i++) {
            approveAndStake(alice, longPeriodIndex, 1 gwei, 30 days, 1 days, 0, address(0));
        }

        // Fully claim the short-period stakes so migration will re-push them as historical entries.
        vm.warp(block.timestamp + 2 days + 1);
        vm.startPrank(alice);
        for (uint8 i = 0; i < 60; i++) {
            staking.withdraw(i);
        }
        staking.setMigrationPermit(migrator, true);
        vm.stopPrank();

        // Migration removes the active stakes but preserves the already-withdrawn ones in storage.
        vm.prank(migrator);
        staking.migratePositionsFrom(alice);
        assertEq(staking.getUserStakes(alice).length, 60);

        // Refill the remaining public stake slots to show that repeated cycles grow historical baggage.
        uint256 remainingSlots = staking.MAX_STAKES_PER_USER() - staking.getUserStakes(alice).length;
        for (uint256 i = 0; i < remainingSlots; i++) {
            approveAndStake(alice, shortPeriodIndex, 1 gwei, 1 days, 1 days, 0, address(0));
        }
        assertEq(staking.getUserStakes(alice).length, staking.MAX_STAKES_PER_USER());

        // In the current implementation the public max-stake guard triggers before any uint8 index wrap is reachable.
        vm.prank(alice);
        token.approve(address(staking), 1 gwei);
        vm.expectRevert(
            abi.encodeWithSelector(IStakingV1.MaxUserStakesReached.selector, staking.MAX_STAKES_PER_USER())
        );
        stake(alice, shortPeriodIndex, 1 gwei, 1 days, 1 days, 0, address(0));
    }

    // M-01 (Medium)
    // Bug location: `Staking.sol::setMigrationPermit()`
    // What happens: users cannot revoke a stored permit once the migrator loses `MIGRATOR_ROLE`,
    // because both grant and revoke paths enforce the same role check.
    // Why it matters: if the same address later regains the role, the stale permit silently becomes active again.
    function test_Audit_M01_ZombiePermitReactivatesAfterMigratorRoleIsRegranted() public {
        deal(address(token), address(staking), 1000 ether);
        deal(address(token), alice, 100 ether);

        uint8 periodIndex = addStakingPeriodByManager(100 ether, 10 days, 1 days, 5000, true);

        // Alice opts into migration while the migrator has the role.
        vm.prank(alice);
        staking.setMigrationPermit(migrator, true);

        // Admin removes the migrator role after the permit is already stored.
        vm.prank(admin);
        staking.revokeRole(keccak256("MIGRATOR"), migrator);

        // M-01: Alice cannot clean up her own permit because revoke uses the same role gate as grant.
        vm.expectRevert(abi.encodeWithSelector(IStakingV1.MigratorNotFound.selector, migrator));
        vm.prank(alice);
        staking.setMigrationPermit(migrator, false);

        // If the role is later restored to the same address, the stale permit silently becomes live again.
        approveAndStake(alice, periodIndex, 10 ether, 10 days, 1 days, 5000, address(0));

        vm.prank(admin);
        staking.grantRole(keccak256("MIGRATOR"), migrator);

        vm.prank(migrator);
        IStakingV1.UserStake[] memory migratedStakes = staking.migratePositionsFrom(alice);

        assertEq(migratedStakes.length, 1);
        assertEq(staking.migrationPermits(migrator, alice), true);
        assertEq(staking.getUserStakes(alice).length, 0);
    }

    // M-02 (Medium)
    // Bug location: `Staking.sol::addStakingPeriod()`, `Staking.sol::updateStakingPeriod()`, `Staking.sol::_stake()`
    // What happens: an extremely large `stakingDurationSeconds` is accepted at configuration time,
    // but later overflows when the contract computes `unlockTime`.
    // Why it matters: the period becomes unusable and every attempt to stake into it reverts.
    function test_Audit_M02_UnboundedStakingDurationBricksPeriod() public {
        deal(address(token), alice, 10 ether);

        // Configure a period whose staking duration is so large that unlockTime overflows uint64 math.
        uint8 periodIndex = addStakingPeriodByManager(100 ether, type(uint64).max, 1 days, 0, true);

        vm.prank(alice);
        token.approve(address(staking), 1 ether);

        // M-02: staking this period panics during unlock time computation, so the period is unusable.
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        stake(alice, periodIndex, 1 ether, type(uint64).max, 1 days, 0, address(0));
    }

    // M-03 (Medium)
    // Bug location: `Staking.sol::pause()`, `Staking.sol::withdraw()`
    // What happens: pausing the contract blocks new deposits, but does not block withdrawals.
    // Why it matters: if an exploit depends on the withdraw path, the current pause mechanism is not
    // a full emergency freeze.
    function test_Audit_M03_PauseDoesNotBlockWithdrawals() public {
        deal(address(token), address(staking), 1000 ether);
        deal(address(token), alice, 100 ether);

        uint8 periodIndex = addStakingPeriodByManager(100 ether, 1 days, 1 days, 5000, true);
        uint8 stakeIndex = approveAndStake(alice, periodIndex, 10 ether, 1 days, 1 days, 5000, address(0));

        // Move past the full unlock window so Alice has something claimable.
        vm.warp(block.timestamp + 2 days + 1);

        // Pause only blocks new inflows in this implementation.
        vm.prank(pauser);
        staking.pause();

        // M-03: withdrawal still succeeds while paused.
        uint256 balanceBefore = token.balanceOf(alice);
        vm.prank(alice);
        staking.withdraw(stakeIndex);
        assertGt(token.balanceOf(alice), balanceBefore);
    }

    // M-04 (Medium)
    // Bug location: `Staking.sol::recoverERC20()`
    // What happens: reward tokens funded before any stakes exist are not tracked in active totals,
    // so the manager can recover the whole prefunded reserve.
    // Why it matters: draining that pool can make otherwise valid future stakes revert for lack of rewards.
    function test_Audit_M04_ManagerCanDrainPreFundedRewardPool() public {
        // Prefund the contract before any stakes exist, so the reward pool is not yet tracked in active totals.
        uint8 periodIndex = addStakingPeriodByManager(100 ether, 365 days, 1 days, 1000, true);

        uint256 prefundedRewards = 1000 ether;
        deal(address(token), address(staking), prefundedRewards);
        deal(address(token), alice, 100 ether);

        // M-04: manager can recover the whole prefunded balance because requiredBalance is still zero.
        vm.prank(manager);
        staking.recoverERC20(address(token), prefundedRewards);
        assertEq(token.balanceOf(address(staking)), 0);

        vm.prank(alice);
        token.approve(address(staking), 10 ether);

        // After the drain, an otherwise valid stake fails because there is no reward liquidity left to reserve.
        vm.expectRevert(
            abi.encodeWithSelector(IStakingV1.NotEnoughContractBalance.selector, token, 0, 1 ether)
        );
        stake(alice, periodIndex, 10 ether, 365 days, 1 days, 1000, address(0));
    }

    // L-01 (Low)
    // Bug location: `Staking.sol::_stake()`
    // What happens: the contract emits `Staked` before the ERC20 transfer is confirmed.
    // Why it matters: optimistic off-chain systems can briefly observe a stake event for a transaction
    // that could still fail later in the same call.
    function test_Audit_L01_StakedEventIsEmittedBeforeTransferEvent() public {
        deal(address(token), address(staking), 1000 ether);
        deal(address(token), alice, 100 ether);

        uint8 periodIndex = addStakingPeriodByManager(100 ether, 20, 5, 5000, true);

        vm.prank(alice);
        token.approve(address(staking), 10 ether);

        // Record raw logs so we can inspect the ordering between the staking event and ERC20 transfer.
        vm.recordLogs();
        stake(alice, periodIndex, 10 ether, 20, 5, 5000, bob);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 stakedTopic = keccak256("Staked(address,uint8,address,uint8,uint256)");
        bytes32 transferTopic = keccak256("Transfer(address,address,uint256)");

        // L-01: the staking event is emitted before the token transfer event is confirmed.
        assertGe(entries.length, 2);
        assertEq(entries[0].emitter, address(staking));
        assertEq(entries[0].topics[0], stakedTopic);
        assertEq(entries[1].emitter, address(token));
        assertEq(entries[1].topics[0], transferTopic);
    }

    // L-02 (Low)
    // Bug location: `Staking.sol::_withdraw()`, `Staking.sol::_getAccrued()`
    // What happens: rounding can make both claimable principal and reward equal zero right after unlock,
    // but `withdraw()` still succeeds and emits `Withdrawn(0, 0)`.
    // Why it matters: users spend gas and get no funds, with no explicit error telling them nothing accrued yet.
    function test_Audit_L02_ZeroClaimWithdrawalSucceedsSilently() public {
        deal(address(token), address(staking), 1000 ether);
        deal(address(token), alice, 100 ether);

        // Use an extreme unlock duration so almost no time has elapsed relative to the full release curve.
        uint8 periodIndex = addStakingPeriodByManager(100 ether, 1 days, type(uint64).max, 5000, true);
        uint8 stakeIndex = approveAndStake(alice, periodIndex, 10 ether, 1 days, type(uint64).max, 5000, address(0));

        // Move to the first second after unlock, where integer division still rounds accrued values down to zero.
        vm.warp(block.timestamp + 1 days + 1);

        uint256 aliceBalanceBefore = token.balanceOf(alice);
        uint256 stakingBalanceBefore = token.balanceOf(address(staking));

        // L-02: the call succeeds, emits Withdrawn, and transfers nothing.
        vm.expectEmit(true, true, true, true);
        emit IStakingV1.Withdrawn(alice, stakeIndex, 0, 0);
        vm.prank(alice);
        staking.withdraw(stakeIndex);

        assertEq(token.balanceOf(alice), aliceBalanceBefore);
        assertEq(token.balanceOf(address(staking)), stakingBalanceBefore);
    }

    // L-03 (Low)
    // Bug location: `Staking.sol::addStakingPeriod()`, `Staking.sol::updateStakingPeriod()`
    // What happens: an extreme `unlockDurationSeconds` can be configured with no upper bound.
    // Why it matters: funds are technically unlockable, but realistic elapsed time still rounds accrued
    // amounts down to zero for an impractically long time.
    function test_Audit_L03_ExtremeUnlockDurationMakesWithdrawalsPracticallyZero() public {
        deal(address(token), address(staking), 1000 ether);
        deal(address(token), alice, 100 ether);

        // Tiny stake plus max unlock duration makes realistic elapsed time accrue nothing meaningful.
        uint8 periodIndex = addStakingPeriodByManager(100 ether, 1 days, type(uint64).max, 0, true);
        uint8 stakeIndex = approveAndStake(alice, periodIndex, 1 gwei, 1 days, type(uint64).max, 0, address(0));

        // Even after a year past unlock, the rounded accrued amount is still zero.
        vm.warp(block.timestamp + 1 days + 365 days);

        uint256 aliceBalanceBefore = token.balanceOf(alice);
        vm.prank(alice);
        staking.withdraw(stakeIndex);

        assertEq(token.balanceOf(alice), aliceBalanceBefore);
    }

    // I-01 (Informational)
    // Bug location: `Staking.sol::migratePositionsFrom()`
    // What happens: calling migration a second time after everything is already moved still emits `MigrateFrom`.
    // Why it matters: analytics and monitoring built from events can overcount successful migrations.
    function test_Audit_I01_SecondMigrationCallEmitsMisleadingEvent() public {
        deal(address(token), address(staking), 1000 ether);
        deal(address(token), alice, 100 ether);

        uint8 periodIndex = addStakingPeriodByManager(100 ether, 20, 10, 5000, true);
        approveAndStake(alice, periodIndex, 10 ether, 20, 10, 5000, address(0));

        // First migrate the only active position out of the contract.
        vm.prank(alice);
        staking.setMigrationPermit(migrator, true);

        vm.prank(migrator);
        staking.migratePositionsFrom(alice);

        // I-01: a second call still emits MigrateFrom even though nothing is moved.
        vm.expectEmit(true, true, true, true);
        emit IStakingV1.MigrateFrom(migrator, alice);
        vm.prank(migrator);
        IStakingV1.UserStake[] memory migratedStakes = staking.migratePositionsFrom(alice);

        assertEq(migratedStakes.length, 0);
    }

    // I-02 (Informational)
    // Bug location: `Staking.sol::stakeWithPermit()`
    // What happens: the internal permit call is wrapped in a silent `try/catch`, so invalid permit data
    // is ignored if the user already gave allowance separately.
    // Why it matters: this is mostly a UX/documentation issue, because staking can succeed even though
    // the permit path itself failed.
    function test_Audit_I02_StakeWithPermitFallsBackToExistingAllowance() public {
        deal(address(token), address(staking), 1000 ether);
        deal(address(token), charlie, 100 ether);

        uint8 periodIndex = addStakingPeriodByManager(100 ether, 20, 10, 5000, true);

        // Give the staking contract a normal allowance first.
        vm.prank(charlie);
        token.approve(address(staking), 10 ether);

        // Then call stakeWithPermit with obviously bad permit data and an expired deadline.
        stakeWithPermit(
            charlie, periodIndex, 10 ether, 20, 10, 5000, address(0), block.timestamp - 1, 0, bytes32(0), bytes32(0)
        );

        // I-02: the call still succeeds because the internal permit failure is swallowed and allowance already exists.
        assertEq(staking.getUserStakes(charlie).length, 1);
        assertEq(token.balanceOf(charlie), 90 ether);
    }

    // I-03 (Informational)
    // Bug location: contract-wide invariant in `Staking.sol`
    // What happens: solvency is derivable from `activeTotalStaked`, `activeTotalRewards`, and token balance,
    // but there is no dedicated on-chain view that exposes the result directly.
    // Why it matters: dashboards and monitoring bots have to rebuild the invariant themselves off-chain.
    function test_Audit_I03_SolvencyMustBeReconstructedOffChain() public {
        deal(address(token), address(staking), 1000 ether);
        deal(address(token), alice, 100 ether);

        uint8 periodIndex = addStakingPeriodByManager(100 ether, 10 days, 2 days, 5000, true);
        approveAndStake(alice, periodIndex, 10 ether, 10 days, 2 days, 5000, address(0));

        // I-03: there is no dedicated solvency view, so we reconstruct the invariant from public state.
        uint256 reward = calculateReward(10 ether, 10 days, 5000);
        assertDerivedSolvencyState(10 ether + reward, 1000 ether - reward);

        // Re-check the same derived invariant after a partial withdrawal to show the bookkeeping remains externally derivable.
        vm.warp(block.timestamp + 11 days);
        vm.prank(alice);
        staking.withdraw(0);

        uint256 accruedAmount = uint256(10 ether * 1 days) / 2 days;
        uint256 accruedReward = uint256(reward * 1 days) / 2 days;
        assertDerivedSolvencyState((10 ether - accruedAmount) + (reward - accruedReward), 1000 ether - reward);
    }

    // I-04 (Informational)
    // Bug location: `Staking.sol::migratePositionsFrom()`
    // What happens: migrating stakes out reduces active balances, but does not decrement the period's `capUsed`.
    // Why it matters: if the same period remains active or gets reused later, new deposits can be blocked by
    // stale cap accounting even though the old stake is gone.
    function test_Audit_I04_MigrationLeavesPeriodCapUsedStale() public {
        deal(address(token), address(staking), 1000 ether);
        deal(address(token), alice, 100 ether);
        deal(address(token), bob, 100 ether);

        // Fill the period cap with Alice, then migrate her position away.
        uint8 periodIndex = addStakingPeriodByManager(10 ether, 20, 10, 5000, true);
        approveAndStake(alice, periodIndex, 10 ether, 20, 10, 5000, address(0));

        vm.prank(alice);
        staking.setMigrationPermit(migrator, true);

        vm.prank(migrator);
        staking.migratePositionsFrom(alice);

        // I-04: active balances are gone, but the period's capUsed is left unchanged.
        Staking.StakingPeriod memory period = staking.getStakingPeriod(periodIndex);
        assertEq(period.capUsed, 10 ether);
        assertEq(staking.activeTotalStaked(), 0);

        vm.prank(bob);
        token.approve(address(staking), 1 ether);

        // Bob is still blocked by the stale cap counter even though Alice's stake was migrated out.
        vm.expectRevert(abi.encodeWithSelector(IStakingV1.StakingCapReached.selector, 10 ether));
        stake(bob, periodIndex, 1 ether, 20, 10, 5000, address(0));
    }

    // Helpers

    function assertDerivedSolvencyState(uint256 requiredBalance, uint256 expectedSurplus) internal view {
        // This helper reconstructs the solvency invariant the audit notes is only observable off-chain.
        uint256 actualBalance = token.balanceOf(address(staking));
        assertEq(staking.activeTotalStaked() + staking.activeTotalRewards(), requiredBalance);
        assertEq(actualBalance - requiredBalance, expectedSurplus);
    }

    function addStakingPeriodByManager(
        uint256 cap,
        uint64 stakingDurationSeconds,
        uint64 unlockDurationSeconds,
        uint32 aprBps,
        bool isActive
    ) internal returns (uint8 periodIndex) {
        vm.prank(manager);
        periodIndex = staking.addStakingPeriod(cap, stakingDurationSeconds, unlockDurationSeconds, aprBps, isActive);
    }

    function approveAndStake(
        address user,
        uint8 periodIndex,
        uint256 amount,
        uint64 maxStakingDurationSeconds,
        uint64 maxUnlockDurationSeconds,
        uint32 minAprBps,
        address referrer
    ) internal returns (uint8 stakeIndex) {
        vm.startPrank(user);
        token.approve(address(staking), amount);
        stakeIndex = staking.stake(
            periodIndex,
            amount,
            IStakingV1.StakeParams({
                maxStakingDurationSeconds: maxStakingDurationSeconds,
                maxUnlockDurationSeconds: maxUnlockDurationSeconds,
                minAprBps: minAprBps,
                referrer: referrer
            })
        );
        vm.stopPrank();
    }

    function stake(
        address user,
        uint8 periodIndex,
        uint256 amount,
        uint64 maxStakingDurationSeconds,
        uint64 maxUnlockDurationSeconds,
        uint32 minAprBps,
        address referrer
    ) internal returns (uint8 stakeIndex) {
        vm.prank(user);
        stakeIndex = staking.stake(
            periodIndex,
            amount,
            IStakingV1.StakeParams({
                maxStakingDurationSeconds: maxStakingDurationSeconds,
                maxUnlockDurationSeconds: maxUnlockDurationSeconds,
                minAprBps: minAprBps,
                referrer: referrer
            })
        );
    }

    function stakeWithPermit(
        address user,
        uint8 periodIndex,
        uint256 amount,
        uint64 maxStakingDurationSeconds,
        uint64 maxUnlockDurationSeconds,
        uint32 minAprBps,
        address referrer,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal returns (uint8 stakeIndex) {
        vm.prank(user);
        stakeIndex = staking.stakeWithPermit(
            periodIndex,
            amount,
            IStakingV1.StakeParams({
                maxStakingDurationSeconds: maxStakingDurationSeconds,
                maxUnlockDurationSeconds: maxUnlockDurationSeconds,
                minAprBps: minAprBps,
                referrer: referrer
            }),
            deadline,
            v,
            r,
            s
        );
    }

    function calculateReward(uint256 stakingAmount, uint256 stakingTime, uint256 stakingApyBps)
        internal
        pure
        returns (uint256)
    {
        return (stakingAmount * stakingTime * stakingApyBps) / (365 days * 10000);
    }
}
