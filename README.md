# Audit Submission Notes

This repository includes:

- the audit PDF uploaded to GitHub
- proof-of-concept Foundry tests that reproduce the reported findings
- a dedicated audit-only test file for reproducing the reported behaviors

## Main Review Artifacts

- Audit PDF: review the uploaded PDF in this repository
- PoC test file: `test/AuditFindings.t.sol`

## Audit PoC Tests

The reproduced audit tests are:

- `test_Audit_H01_MigrationPermitRemainsUsableAfterSuccessfulMigration`
- `test_Audit_H02_RepeatedMigrationCyclesHitMaxUserStakesBeforeUint8Wrap`
- `test_Audit_M01_ZombiePermitReactivatesAfterMigratorRoleIsRegranted`
- `test_Audit_M02_UnboundedStakingDurationBricksPeriod`
- `test_Audit_M03_PauseDoesNotBlockWithdrawals`
- `test_Audit_M04_ManagerCanDrainPreFundedRewardPool`
- `test_Audit_L01_StakedEventIsEmittedBeforeTransferEvent`
- `test_Audit_L02_ZeroClaimWithdrawalSucceedsSilently`
- `test_Audit_L03_ExtremeUnlockDurationMakesWithdrawalsPracticallyZero`
- `test_Audit_I01_SecondMigrationCallEmitsMisleadingEvent`
- `test_Audit_I02_StakeWithPermitFallsBackToExistingAllowance`
- `test_Audit_I03_SolvencyMustBeReconstructedOffChain`
- `test_Audit_I04_MigrationLeavesPeriodCapUsedStale`

## Recommended Verification Commands

Run all audit reproduction tests:

```shell
forge test --match-path test/AuditFindings.t.sol -vv
```

Run the full staking suite:

```shell
forge test --match-path test/Staking.t.sol -vv
```

Run one finding at a time:

```shell
forge test --match-test test_Audit_H01_MigrationPermitRemainsUsableAfterSuccessfulMigration -vv
forge test --match-test test_Audit_H02_RepeatedMigrationCyclesHitMaxUserStakesBeforeUint8Wrap -vv
forge test --match-test test_Audit_M01_ZombiePermitReactivatesAfterMigratorRoleIsRegranted -vv
forge test --match-test test_Audit_M02_UnboundedStakingDurationBricksPeriod -vv
forge test --match-test test_Audit_M03_PauseDoesNotBlockWithdrawals -vv
forge test --match-test test_Audit_M04_ManagerCanDrainPreFundedRewardPool -vv
forge test --match-test test_Audit_L01_StakedEventIsEmittedBeforeTransferEvent -vv
forge test --match-test test_Audit_L02_ZeroClaimWithdrawalSucceedsSilently -vv
forge test --match-test test_Audit_L03_ExtremeUnlockDurationMakesWithdrawalsPracticallyZero -vv
forge test --match-test test_Audit_I01_SecondMigrationCallEmitsMisleadingEvent -vv
forge test --match-test test_Audit_I02_StakeWithPermitFallsBackToExistingAllowance -vv
forge test --match-test test_Audit_I03_SolvencyMustBeReconstructedOffChain -vv
forge test --match-test test_Audit_I04_MigrationLeavesPeriodCapUsedStale -vv
```

## Notes

- The audit report severity summary is `2 High`, `4 Medium`, `3 Low`, and `4 Informational`.
- The test coverage is designed as PoC-style reproduction coverage for the behaviors described in the report.
- `H-02` is reproduced as closely as possible against the current public flow; in this implementation the public max-stake guard is reached before the reported `uint8` wraparound path becomes reachable.
