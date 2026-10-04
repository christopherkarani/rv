# Phase 2A.1 broad failure classification

The first section covers `verification/first-pass/`; the final comparison appended below reports the completed rerun. No tests were run for this classification. Starting HEAD: `2df5484972fa2ad1afe9394941e023e7ad01bef0`.

## Method

An exact inherited signature matches test name, parameter argument, source filename, source line, column, and failure message. Only temporary fixture-directory names, hexadecimal process-memory addresses, and UUIDs are normalized. Each issue is compared independently; equal counts are not used as proof. Prior Phase 2A unsandboxed matches are preferred, with committed Phase 2 logs also checked because early service crashes truncate reporting.

```json
{
  "RVDomainTests": {
    "issue_records": 8,
    "exact_matches": 8,
    "newly_observed_signature_unchanged_authority_path": 0
  },
  "RVPolicyTests": {
    "issue_records": 4,
    "exact_matches": 4,
    "newly_observed_signature_unchanged_authority_path": 0
  },
  "RVIsolationTests": {
    "issue_records": 54,
    "exact_matches": 54,
    "newly_observed_signature_unchanged_authority_path": 0
  },
  "RVServiceTests": {
    "issue_records": 82,
    "exact_matches": 41,
    "newly_observed_signature_unchanged_authority_path": 41
  }
}
```

All 54 isolation issues, all 8 domain issues and all 4 policy issues have exact historical matches. Service prints 82 issues before its known crash: 41 exact historical matches and 41 newly observed signatures. Those 41 are inherited from unchanged generic service authority paths and unchanged fixtures; the table explicitly distinguishes source proof from historical issue matches.

## Gate interpretation

Domain, policy, isolation, and service: **INHERITED FAILURE — EXISTING PHASE 2 DRAFT**. IPC: **GREEN**, 95 tests. Preflight: **NEW FAILURE** in the first run, three introduced issues; their fixes and subsequent preflight result belong in the final report.

## Source-based service evidence

Both service sources are byte-identical to the pre-pass archive `/private/tmp/rv-phase2a-before-launch-20260930T193132Z.tar.gz`. SHA-256:

```json
{
  "Sources/RVService/AuthenticatedRequestContext.swift": "b8d7ab2d238a78a1b03969a9327d7581b4f410d83078b862e9ce06ef819b75c1",
  "Sources/RVService/ServiceRuntime.swift": "c676a83a41f7308c2aebee1bcb4db286abf98091e174bcebe7d82d346671de4f"
}
```

`ServiceRuntime.dispatch` defaults to `.unauthenticated`, calls `ServiceMethodAuthorization.permits`, and returns `.authorizationDenied` before evaluation/mutation dispatch. The unchanged method matrix refuses generic `.evaluate`/`.hookEvaluate`, owner mutations, and unauthenticated control reads. The newly visible failing fixtures invoke this path without principal context and expect evaluation replies, pending rows, grants, analytics, or mutation responses. Those expectations are unreachable in both source snapshots. Scheduling determines which issues print before the array trap; absence of an earlier issue record does not establish a new implementation failure.

`DenialLedgerRecordTests.swift:174` expects one row, receives zero, then accesses `rows[0]` at line 175. Prior Phase 2A service log lines 330–333 record the expectation and fatal `Index out of range`. First-pass service log lines 596–599 repeat them. Both exit with signal 5. The entire service suite remains uncompleted.

## Phase 2 versus pre-Phase 2

`git diff a85151b6 2df54849` shows Phase 2 introduced unconditional false for `PendingApproval.authorizes`, authorizing-consume rejection in `PendingApprovalLedger`, service authorization gates, and protected workspace component-role authentication. These concretely explain approval failures and unauthenticated old fixtures. The classification is inherited from the Phase 2 draft; no pre-Phase 2 full-green gate is claimed. Unsafe service fixture array indexing predates the draft, while the observed zero-row/refusal/crash combination is already recorded in Phase 2.

## Every issue and historical match

### RVDomainTests

New log: `verification/first-pass/RVDomainTests-unsandboxed.log`.

| # | Test / parameter | Source | Signature | New log line | Historical match / evidence |
|---|---|---|---|---:|---|
| 1 | replayedIdenticalActionCannotBeConsumedTwice() | PendingApprovalLedgerTests.swift:209:6 | Caught error: .invalidRequest | 852 | docs/security/phase2a/verification/RVDomainTests-unsandboxed.log:756 |
| 2 | consumedStateRoundTripsThroughCodable() | PendingApprovalLedgerTests.swift:526:6 | Caught error: .invalidRequest | 854 | docs/security/phase2a/verification/RVDomainTests-unsandboxed.log:743 |
| 3 | consumeDeliversResolutionExactlyOnce() | PendingApprovalLedgerTests.swift:53:6 | Caught error: .invalidRequest | 862 | docs/security/phase2a/verification/RVDomainTests-unsandboxed.log:755 |
| 4 | consumeFoldsEachDecisionIntoConsumedState(decision:) with 1 argument decision → .allowOnce | PendingApprovalLedgerTests.swift:474:6 | Caught error: .invalidRequest | 868 | docs/security/phase2a/verification/RVDomainTests-unsandboxed.log:785 |
| 5 | consumeFoldsEachDecisionIntoConsumedState(decision:) with 1 argument decision → .createRule | PendingApprovalLedgerTests.swift:474:6 | Caught error: .invalidRequest | 875 | docs/security/phase2a/verification/RVDomainTests-unsandboxed.log:786 |
| 6 | keepWaitingAllowsResolveAfterDeadline() | PendingApprovalLedgerTests.swift:362:9 | Expectation failed: resolved.authorizes(Self.fingerprint, identity: Self.identity) | 1248 | docs/security/phase2a/verification/RVDomainTests-unsandboxed.log:1248 |
| 7 | exactDeadlineIsStillAwaitingHuman() | PendingApprovalLedgerTests.swift:382:9 | Expectation failed: resolved.authorizes(Self.fingerprint, identity: Self.identity) | 1296 | docs/security/phase2a/verification/RVDomainTests-unsandboxed.log:1296 |
| 8 | resolvedWithoutParentConsumedAtStaysResolved() | PendingApprovalLedgerTests.swift:617:9 | Expectation failed: decoded.authorizes(Self.fingerprint, identity: Self.identity) | 1344 | docs/security/phase2a/verification/RVDomainTests-unsandboxed.log:1344 |

### RVPolicyTests

New log: `verification/first-pass/RVPolicyTests-unsandboxed.log`.

| # | Test / parameter | Source | Signature | New log line | Historical match / evidence |
|---|---|---|---|---:|---|
| 1 | processRestartReloadsPendingAndResolvedRecords() | PendingApprovalStoreTests.swift:8:6 | Caught error: .invalidRequest | 383 | docs/security/phase2a/verification/RVPolicyTests-unsandboxed.log:377 |
| 2 | keepWaitingSurvivesRestartPastDeadline() | PendingApprovalStoreTests.swift:231:9 | Expectation failed: resolved.authorizes(Self.fingerprint, identity: Self.identity) | 384 | docs/security/phase2a/verification/RVPolicyTests-unsandboxed.log:385 |
| 3 | concurrentConsumeWinsOnce() | PendingApprovalStoreTests.swift:102:9 | Expectation failed: results.filter(\.isSuccess).count == 1 | 751 | docs/security/phase2a/verification/RVPolicyTests-unsandboxed.log:775 |
| 4 | concurrentConsumeWinsOnce() | PendingApprovalStoreTests.swift:103:9 | Expectation failed: results.filter { $0 == .alreadyConsumed }.count == 1 | 754 | docs/security/phase2a/verification/RVPolicyTests-unsandboxed.log:778 |

### RVIsolationTests

New log: `verification/first-pass/RVIsolationTests-unsandboxed.log`.

| # | Test / parameter | Source | Signature | New log line | Historical match / evidence |
|---|---|---|---|---:|---|
| 1 | forgedAndCrossProjectProfileIDsFailClosedAtServer() | RuntimeResourceAdversarialTests.swift:130:2 | Caught error: .unauthorizedClient | 418 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:400 |
| 2 | ensureTerminalRuntimeAdjudicatesExplicitProfile() | RuntimeResourceAdversarialTests.swift:307:5 | Expectation failed: WorkspaceControlSocket.writeFrame(fd: raw, body: ensureBody) | 419 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:382 |
| 3 | ensureTerminalRuntimeAcceptsKnownExplicitProfile() | RuntimeResourceAdversarialTests.swift:320:2 | Caught error: .unauthorizedClient | 427 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:394 |
| 4 | ensureTerminalRuntimeAdjudicatesExplicitProfile() | RuntimeResourceAdversarialTests.swift:269:2 | Caught error: .disconnected | 428 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:390 |
| 5 | defaultProfileNeverAutoAttachesNilLaunchKeepsBaseFence() | RuntimeResourceAdversarialTests.swift:167:2 | Caught error: .unauthorizedClient | 430 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:393 |
| 6 | profileStagingFailureKeepsLaunchFailurePath() | RuntimeResourceAdversarialTests.swift:223:2 | Caught error: .unauthorizedClient | 624 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:397 |
| 7 | clientsAttachDetachAndCancelWithoutSharingAuthority() | WorkspaceHostTests.swift:107:6 | Caught error: .unauthorizedClient | 651 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:702 |
| 8 | workspaceRunRestoresOnExitCloseDisconnectAndStdinEOF() | LocalTerminalRestoreTests.swift:52:6 | Caught error: .unauthorizedClient | 708 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:682 |
| 9 | malformedFramesAndForeignTokensDoNotMutate() | WorkspaceHostTests.swift:175:6 | Caught error: .unauthorizedClient | 734 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:736 |
| 10 | disconnectAndProtocolErrorRestoreRawMode() | LocalTerminalRestoreTests.swift:142:6 | Caught error: .unauthorizedClient | 737 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:741 |
| 11 | clientResubscribeAfterUnsubscribeReceivesReplay() | RuntimeTerminalTests.swift:291:6 | Caught error: .unauthorizedClient | 742 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:717 |
| 12 | hostSurvivesTheCreatingClientAndAKilledClient() | WorkspaceHostTests.swift:238:6 | Caught error: .unauthorizedClient | 777 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:770 |
| 13 | hostDeathDuringAPtyRuntimeIsOrphanedNotReattachable() | WorkspaceHostTests.swift:320:6 | Caught error: .unauthorizedClient | 793 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:780 |
| 14 | hookAndBareLaunchesShareTheCageEnvironment() | RuntimeTerminalTests.swift:466:6 | Caught error: .unauthorizedClient | 803 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:783 |
| 15 | containedSessionSurvivesSetsIDAndDoubleForkUntilCancel() | RuntimeTerminalTests.swift:506:6 | Caught error: .unauthorizedClient | 815 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:794 |
| 16 | controlCInterruptsTheForegroundGroupWithoutKillingTheHost() | RuntimeTerminalTests.swift:542:6 | Caught error: .unauthorizedClient | 833 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:812 |
| 17 | childObservesResizeAndSignal() | RuntimeTerminalTests.swift:581:6 | Caught error: .unauthorizedClient | 850 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:829 |
| 18 | onlyInputLeaseOwnerCanResizeTerminal() | RuntimeTerminalTests.swift:610:6 | Caught error: .unauthorizedClient | 866 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:843 |
| 19 | twoViewersDetachReattachAndKeepInputExclusive() | RuntimeTerminalTests.swift:645:6 | Caught error: .unauthorizedClient | 883 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:860 |
| 20 | concurrentEnsureTerminalRuntimeRequestsShareOneRuntime() | RuntimeTerminalTests.swift:698:6 | Caught error: .unauthorizedClient | 899 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:873 |
| 21 | inputReachesOnlyTheAddressedRuntime() | RuntimeTerminalTests.swift:728:6 | Caught error: .unauthorizedClient | 921 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:879 |
| 22 | runtimeExitClosesTheTerminalAndLeavesTheWorkspace() | RuntimeTerminalTests.swift:770:6 | Caught error: .unauthorizedClient | 932 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:894 |
| 23 | launchFaultsDoNotReportARunningRuntime() | RuntimeTerminalTests.swift:827:9 | Expectation failed: writeFrame(raw, stolen) | 939 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:907 |
| 24 | launchFaultsDoNotReportARunningRuntime() | RuntimeTerminalTests.swift:808:6 | Caught error: .disconnected | 944 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:913 |
| 25 | closingTheWorkspaceKillsEveryPTYRuntime() | RuntimeTerminalTests.swift:932:6 | Caught error: .unauthorizedClient | 954 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:925 |
| 26 | aSlowSocketDoesNotStopTheOtherSubscriberOrClose() | RuntimeTerminalTests.swift:979:6 | Caught error: .unauthorizedClient | 963 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:942 |
| 27 | repeatedAttachCyclesDoNotLeakPTYs() | RuntimeTerminalTests.swift:1017:6 | Caught error: .unauthorizedClient | 972 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:948 |
| 28 | provingClientRestoresTheLocalTerminal() | RuntimeTerminalTests.swift:1074:9 | Expectation failed: waitUntil(seconds: 40) { FileManager.default.fileExists(atPath: ready.path) } | 1021 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1013 |
| 29 | provingClientRestoresTheLocalTerminal() | RuntimeTerminalTests.swift:1075:9 | Expectation failed: waitUntilRaw(pty.slave) | 1023 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1015 |
| 30 | provingClientRestoresTheLocalTerminal() | RuntimeTerminalTests.swift:1048:6 | Caught error: Error Domain=NSCocoaErrorDomain Code=260 "The file “client-sleep.pid” couldn’t be opened because there is no such file." UserInfo={NSFilePath=/tmp/<fixture>/ws/client-sleep.pid, NSURL=file:///tmp/<fixture>/ws/client-sleep.pid, NSUnderlyingError=<address> {Error Domain=NSPOSIXErrorDomain Code=2 "No such file or directory"}} | 1029 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1021 |
| 31 | workspaceStartLeavesALiveHostAfterTheClientExits() | WorkspaceHostTests.swift:412:9 | Expectation failed: start.terminationStatus == 0 | 1035 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1027 |
| 32 | workspaceStartLeavesALiveHostAfterTheClientExits() | WorkspaceHostTests.swift:398:6 | Caught error: .unauthorizedClient | 1038 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1030 |
| 33 | hostDeathDropsTheTerminalAndRecoveryKillsTheGroup() | RuntimeTerminalTests.swift:1157:9 | Expectation failed: waitUntil(seconds: 40) { | 1056 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1035 |
| 34 | hostDeathDropsTheTerminalAndRecoveryKillsTheGroup() | RuntimeTerminalTests.swift:1161:9 | Expectation failed: waitUntilRaw(pty.slave) | 1070 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1050 |
| 35 | hostDeathDropsTheTerminalAndRecoveryKillsTheGroup() | RuntimeTerminalTests.swift:1162:26 | Expectation failed: pidFile(leaderURL) | 1073 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1053 |
| 36 | rvSpawnedHostDiesOnSIGTERM() | WorkspaceHostTests.swift:437:9 | Expectation failed: start.terminationStatus == 0 | 1083 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1075 |
| 37 | rvSpawnedHostDiesOnSIGTERM() | WorkspaceHostTests.swift:452:9 | Expectation failed: restart.terminationStatus == 0 | 1089 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1081 |
| 38 | rvSpawnedHostDiesOnSIGTERM() | WorkspaceHostTests.swift:423:6 | Caught error: .unauthorizedClient | 1092 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1084 |
| 39 | simultaneousCreatorsProduceOneOwner() | WorkspaceHostTests.swift:459:6 | Caught error: .unauthorizedClient | 1097 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1089 |
| 40 | oneClientSerializesOverlappedCalls() | WorkspaceHostTests.swift:535:6 | Caught error: .unauthorizedClient | 1102 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1094 |
| 41 | streamingClientMultiplexesOverlappedCalls() | WorkspaceHostTests.swift:557:6 | Caught error: .unauthorizedClient | 1105 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1097 |
| 42 | legacyHostStaysUsableAndGatesProfilesPerCall() | WorkspaceHostTests.swift:633:6 | Caught error: .unauthorizedClient | 1112 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1104 |
| 43 | explicitProfilesKeepSyntheticCredentialsAndSupportDisjoint() | WorkspaceHostTests.swift:653:6 | Caught error: .unauthorizedClient | 1115 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1107 |
| 44 | hookAndProfileStayOrthogonalAtLaunch() | WorkspaceHostTests.swift:735:6 | Caught error: .unauthorizedClient | 1118 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1110 |
| 45 | unknownOperationReceivesAnInvalidRequestEcho() | WorkspaceHostTests.swift:813:25 | Issue recorded | 1123 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1115 |
| 46 | legacyEnsureReusesARunningTerminalAndLaunchesWhenEmpty() | WorkspaceHostTests.swift:833:6 | Caught error: .unauthorizedClient | 1127 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1119 |
| 47 | ensureTerminalRuntimeIsExecutableAgnosticByContract() | WorkspaceHostTests.swift:861:6 | Caught error: .unauthorizedClient | 1130 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1122 |
| 48 | ensureTerminalRuntimeNeverRelabelsTheExistingPrincipal() | WorkspaceHostTests.swift:886:6 | Caught error: .unauthorizedClient | 1133 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1125 |
| 49 | malformedHookTagIsRefusedClientSideBeforeSpawn() | WorkspaceHostTests.swift:920:6 | Caught error: .unauthorizedClient | 1136 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1128 |
| 50 | stagingOnlyTagStagesFilteredCredentialsWithoutHookRecord() | WorkspaceHostTests.swift:936:6 | Caught error: .unauthorizedClient | 1139 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1131 |
| 51 | malformedHookTagIsRefusedBeforeSpawn() | WorkspaceHostTests.swift:1026:9 | Expectation failed: WorkspaceControlSocket.writeFrame(fd: raw, body: launchBody) | 1142 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1134 |
| 52 | malformedHookTagIsRefusedBeforeSpawn() | WorkspaceHostTests.swift:999:6 | Caught error: .disconnected | 1150 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1142 |
| 53 | controlLaunchBounds_fitDeveloperCommands() | WorkspaceHostTests.swift:1038:6 | Caught error: .unauthorizedClient | 1153 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1145 |
| 54 | hostBinaryRunsTheProductionAdmission() | WorkspaceHostTests.swift:1079:6 | Caught error: .unauthorizedClient | 1156 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1148 |

### RVServiceTests

New log: `verification/first-pass/RVServiceTests-unsandboxed.log`.

| # | Test / parameter | Source | Signature | New log line | Historical match / evidence |
|---|---|---|---|---:|---|
| 1 | PendingResolveGrant_missingCoordinatorFailsClosedWithoutGrant() | PendingResolveGrantTests.swift:188:9 | Expectation failed: resolve.result == .error(.pendingCoordinatorUnavailable) | 320 | No historical issue match; unchanged fixture + byte-identical pre-pass service authority path |
| 2 | stdinOverlay_replacesJSONStdinOnImplicitHello() | HookEvaluateTests.swift:157:25 | Issue recorded | 326 | No historical issue match; unchanged fixture + byte-identical pre-pass service authority path |
| 3 | explainPeeksGrantWithoutSpending() | ExplainDispatchTests.swift:95:25 | Issue recorded | 330 | No historical issue match; unchanged fixture + byte-identical pre-pass service authority path |
| 4 | classifyPeeksGrantWithoutSpending() | ExplainDispatchTests.swift:183:25 | Issue recorded | 332 | No historical issue match; unchanged fixture + byte-identical pre-pass service authority path |
| 5 | PendingResolveGrant_denyResolvesWithoutGrant() | PendingResolveGrantTests.swift:60:25 | Issue recorded | 335 | No historical issue match; unchanged fixture + byte-identical pre-pass service authority path |
| 6 | PendingResolveGrant_allowOncePlantsGrantAndNextApplyAllowsOnce() | PendingResolveGrantTests.swift:22:25 | Issue recorded | 338 | No historical issue match; unchanged fixture + byte-identical pre-pass service authority path |
| 7 | PendingResolveGrant_secondAllowOnceIsAlreadyTerminalWithoutSecondGrant() | PendingResolveGrantTests.swift:101:9 | Expectation failed: grants == 1 | 340 | No historical issue match; unchanged fixture + byte-identical pre-pass service authority path |
| 8 | PendingResolveGrant_secondAllowOnceIsAlreadyTerminalWithoutSecondGrant() | PendingResolveGrantTests.swift:106:9 | Expectation failed: again.result == .error(.pendingAlreadyTerminal) | 344 | No historical issue match; unchanged fixture + byte-identical pre-pass service authority path |
| 9 | PendingResolveGrant_alreadyAllowResolvesWithoutSecondGrant() | PendingResolveGrantTests.swift:202:25 | Issue recorded | 351 | No historical issue match; unchanged fixture + byte-identical pre-pass service authority path |
| 10 | hookEvaluate_doesNotLogCommandText() | HookEvaluateTests.swift:357:9 | Expectation failed: blob.contains("hookEvaluate") | 373 | No historical issue match; unchanged fixture + byte-identical pre-pass service authority path |
| 11 | dispatchEvaluate_disabledCatalogPackStillDeniesResetHard() | ServiceRuntimeEvaluateTests.swift:117:25 | Issue recorded | 376 | No historical issue match; unchanged fixture + byte-identical pre-pass service authority path |
| 12 | emptyStdinOverlay_overridesJSONStdin() | HookEvaluateTests.swift:181:25 | Issue recorded | 378 | No historical issue match; unchanged fixture + byte-identical pre-pass service authority path |
| 13 | PendingResolveGrant_nonSpendFirstAllowOnceDoesNotPlant(_:) with 1 argument host → .grok | PendingResolveGrantTests.swift:322:9 | Expectation failed: resolved.result == .error(.pendingAllowOnceNotUnlockable) | 380 | No historical issue match; unchanged fixture + byte-identical pre-pass service authority path |
| 14 | stdinOverlay_winsOverJSONAllowStdin() | HookEvaluateTests.swift:206:25 | Issue recorded | 386 | No historical issue match; unchanged fixture + byte-identical pre-pass service authority path |
| 15 | dispatchEvaluate_emptyEnabledPacksDoesNotRefillDayOne() | ServiceRuntimeEvaluateTests.swift:100:25 | Issue recorded | 388 | No historical issue match; unchanged fixture + byte-identical pre-pass service authority path |
| 16 | PendingResolveGrant_hardBindDoesNotPlantOrResolve() | PendingResolveGrantTests.swift:135:9 | Expectation failed: resolved.result == .error(.pendingAllowOnceNotUnlockable) | 390 | No historical issue match; unchanged fixture + byte-identical pre-pass service authority path |
| 17 | PendingResolveGrant_nonSpendFirstAllowOnceDoesNotPlant(_:) with 1 argument host → .codex | PendingResolveGrantTests.swift:322:9 | Expectation failed: resolved.result == .error(.pendingAllowOnceNotUnlockable) | 396 | No historical issue match; unchanged fixture + byte-identical pre-pass service authority path |
| 18 | PendingResolveGrant_nonSpendFirstAllowOnceDoesNotPlant(_:) with 1 argument host → .cursor | PendingResolveGrantTests.swift:322:9 | Expectation failed: resolved.result == .error(.pendingAllowOnceNotUnlockable) | 402 | No historical issue match; unchanged fixture + byte-identical pre-pass service authority path |
| 19 | dispatchEvaluate_grantHonorsOnceForCwd() | ServiceRuntimeEvaluateTests.swift:154:25 | Issue recorded | 409 | No historical issue match; unchanged fixture + byte-identical pre-pass service authority path |
| 20 | missingStdinOverlay_keepsJSONStdin() | HookEvaluateTests.swift:253:25 | Issue recorded | 412 | No historical issue match; unchanged fixture + byte-identical pre-pass service authority path |
| 21 | implicitHello_claudeResetHardReturnsAskWire() | HookEvaluateTests.swift:52:25 | Issue recorded | 417 | No historical issue match; unchanged fixture + byte-identical pre-pass service authority path |
| 22 | implicitHello_grokResetHardReturnsCanonicalDenyWire() | HookEvaluateTests.swift:30:25 | Issue recorded | 420 | No historical issue match; unchanged fixture + byte-identical pre-pass service authority path |
| 23 | grokStashDrop_emptyStdout() | HookEvaluateTests.swift:272:25 | Issue recorded | 422 | No historical issue match; unchanged fixture + byte-identical pre-pass service authority path |
| 24 | oldEvaluate_stillWorksAfterHookEvaluate() | HookEvaluateTests.swift:334:25 | Issue recorded | 424 | No historical issue match; unchanged fixture + byte-identical pre-pass service authority path |
| 25 | fileToolAlwaysAllowFailsClosedWithoutMatchingView() | PendingDispatchTests.swift:520:25 | Issue recorded | 426 | docs/security/phase2/verification/RVServiceTests.log:398 |
| 26 | watchAcksUnchangedThenReturnsItemsAfterResolve() | PendingDispatchTests.swift:841:25 | Issue recorded | 429 | docs/security/phase2/verification/RVServiceTests.log:350 |
| 27 | watchAcksUnchangedThenReturnsItemsAfterResolve() | PendingDispatchTests.swift:111:6 | Caught error: DispatchExpectation() | 431 | docs/security/phase2/verification/RVServiceTests.log:370 |
| 28 | hookEvaluate_resolvesPacksFromConfig_notDayOne() | HookEvaluateTests.swift:91:25 | Issue recorded | 432 | No historical issue match; unchanged fixture + byte-identical pre-pass service authority path |
| 29 | alwaysAllowSaveAuthorizesFutureEvaluateWithoutExtraClick() | PendingDispatchTests.swift:368:25 | Issue recorded | 434 | docs/security/phase2/verification/RVServiceTests.log:338 |
| 30 | allowOnceOnPiLeavesOpenCodeAwaiting() | PendingDispatchTests.swift:841:25 | Issue recorded | 437 | docs/security/phase2/verification/RVServiceTests.log:413 |
| 31 | allowOnceOnPiLeavesOpenCodeAwaiting() | PendingDispatchTests.swift:45:6 | Caught error: DispatchExpectation() | 439 | docs/security/phase2/verification/RVServiceTests.log:415 |
| 32 | resolveMapsLedgerErrors() | PendingDispatchTests.swift:220:9 | Expectation failed: missing.result == .error(.pendingNotFound) | 441 | docs/security/phase2/verification/RVServiceTests.log:358 |
| 33 | resolveMapsLedgerErrors() | PendingDispatchTests.swift:237:9 | Expectation failed: identity.result == .error(.pendingIdentityMismatch) | 449 | docs/security/phase2/verification/RVServiceTests.log:364 |
| 34 | resolveMapsLedgerErrors() | PendingDispatchTests.swift:251:9 | Expectation failed: fingerprint.result == .error(.pendingFingerprintMismatch) | 456 | docs/security/phase2/verification/RVServiceTests.log:373 |
| 35 | resolveMapsLedgerErrors() | PendingDispatchTests.swift:259:9 | Expectation failed: second.result == .error(.pendingAlreadyTerminal) | 462 | docs/security/phase2/verification/RVServiceTests.log:379 |
| 36 | missingFolderUsesPlaceholder() | PendingDispatchTests.swift:841:25 | Issue recorded | 468 | docs/security/phase2/verification/RVServiceTests.log:352 |
| 37 | missingFolderUsesPlaceholder() | PendingDispatchTests.swift:183:6 | Caught error: DispatchExpectation() | 470 | docs/security/phase2/verification/RVServiceTests.log:372 |
| 38 | extraAllowOnceStillWorksWithoutATypedRule() | PendingDispatchTests.swift:629:25 | Issue recorded | 471 | docs/security/phase2/verification/RVServiceTests.log:344 |
| 39 | hookEvaluateAskOnPiPersistsWaitWithoutCommandOnList() | PendingDispatchTests.swift:740:25 | Issue recorded | 473 | docs/security/phase2/verification/RVServiceTests.log:407 |
| 40 | sessionSuffixOnlyWhenAskLineCollides() | PendingDispatchTests.swift:841:25 | Issue recorded | 475 | docs/security/phase2/verification/RVServiceTests.log:403 |
| 41 | sessionSuffixOnlyWhenAskLineCollides() | PendingDispatchTests.swift:152:6 | Caught error: DispatchExpectation() | 477 | docs/security/phase2/verification/RVServiceTests.log:409 |
| 42 | listOmitsCommandAndOrdersOldestFirst() | PendingDispatchTests.swift:841:25 | Issue recorded | 478 | docs/security/phase2/verification/RVServiceTests.log:437 |
| 43 | listOmitsCommandAndOrdersOldestFirst() | PendingDispatchTests.swift:12:6 | Caught error: DispatchExpectation() | 483 | docs/security/phase2/verification/RVServiceTests.log:439 |
| 44 | automaticStoreListsCreatedWaits() | PendingDispatchTests.swift:841:25 | Issue recorded | 484 | docs/security/phase2/verification/RVServiceTests.log:356 |
| 45 | automaticStoreListsCreatedWaits() | PendingDispatchTests.swift:777:6 | Caught error: DispatchExpectation() | 486 | docs/security/phase2/verification/RVServiceTests.log:389 |
| 46 | alwaysBlockSaveDeniesThisWait() | PendingDispatchTests.swift:584:25 | Issue recorded | 487 | docs/security/phase2/verification/RVServiceTests.log:340 |
| 47 | previewWithoutSaveLeavesWaitAwaitingHuman() | PendingDispatchTests.swift:340:25 | Issue recorded | 489 | docs/security/phase2/verification/RVServiceTests.log:405 |
| 48 | failedPlantConsumesWaitAndReportsNotUnlockable() | PendingDispatchTests.swift:659:9 | Expectation failed: resolved.result == .error(.pendingAllowOnceNotUnlockable) | 491 | docs/security/phase2/verification/RVServiceTests.log:440 |
| 49 | failedPlantConsumesWaitAndReportsNotUnlockable() | PendingDispatchTests.swift:660:9 | Expectation failed: await approvals.resolveCalls.map(\.decision) == [.allowOnce] | 497 | docs/security/phase2/verification/RVServiceTests.log:446 |
| 50 | failedPlantConsumesWaitAndReportsNotUnlockable() | PendingDispatchTests.swift:841:25 | Issue recorded | 499 | docs/security/phase2/verification/RVServiceTests.log:448 |
| 51 | allowOncePeekUsesCompileSetAfterPackEnable() | PendingDispatchTests.swift:701:25 | Issue recorded | 501 | docs/security/phase2/verification/RVServiceTests.log:416 |
| 52 | failedPlantConsumesWaitAndReportsNotUnlockable() | PendingDispatchTests.swift:638:6 | Caught error: DispatchExpectation() | 503 | docs/security/phase2/verification/RVServiceTests.log:450 |
| 53 | hookEvaluateAskWithoutSessionDoesNotPersist() | PendingDispatchTests.swift:766:25 | Issue recorded | 504 | docs/security/phase2/verification/RVServiceTests.log:346 |
| 54 | alwaysAllowHardStopPreviewForbidsSaveAndWritesNothing() | PendingDispatchTests.swift:301:25 | Issue recorded | 506 | docs/security/phase2/verification/RVServiceTests.log:411 |
| 55 | setPackEnabledRefreshesAnalyticsPackSnapshot() | ServiceRuntimeAnalyticsTests.swift:67:25 | Issue recorded | 508 | docs/security/phase2/verification/RVServiceTests.log:336 |
| 56 | alwaysAllowSaveAuthorizesNormalizedWrapperRetry() | PendingDispatchTests.swift:430:25 | Issue recorded | 510 | docs/security/phase2/verification/RVServiceTests.log:400 |
| 57 | missingCoordinatorFailsClosedWithoutSpendingAGrant() | PendingDispatchTests.swift:99:9 | Expectation failed: resolve.result == .error(.pendingCoordinatorUnavailable) | 512 | docs/security/phase2/verification/RVServiceTests.log:418 |
| 58 | missingCoordinatorFailsClosedWithoutSpendingAGrant() | PendingDispatchTests.swift:101:9 | Expectation failed: listed.result == .error(.pendingCoordinatorUnavailable) | 518 | docs/security/phase2/verification/RVServiceTests.log:424 |
| 59 | missingCoordinatorFailsClosedWithoutSpendingAGrant() | PendingDispatchTests.swift:105:9 | Expectation failed: watch.result == .error(.pendingCoordinatorUnavailable) | 524 | No historical issue match; unchanged fixture + byte-identical pre-pass service authority path |
| 60 | directConfigEditIsPickedUpByWarmRuntimeEvaluate() | EnabledCompileTests.swift:120:25 | Issue recorded | 531 | No historical issue match; unchanged fixture + byte-identical pre-pass service authority path |
| 61 | hookEvaluateRecordsDecisionAnalyticsWithoutCommandText() | ServiceRuntimeAnalyticsTests.swift:123:25 | Issue recorded | 535 | docs/security/phase2/verification/RVServiceTests.log:342 |
| 62 | evaluateSnapshotsEnabledPackIDsBeforeAsyncWork() | ServiceRuntimeAnalyticsTests.swift:27:25 | Issue recorded | 540 | docs/security/phase2/verification/RVServiceTests.log:348 |
| 63 | setPackEnabledGrowsAndShrinksCompiledPackIDs() | EnabledCompileTests.swift:167:25 | Issue recorded | 542 | No historical issue match; unchanged fixture + byte-identical pre-pass service authority path |
| 64 | ruleSaveDraftMismatchWritesNothing() | PendingDispatchTests.swift:559:9 | Expectation failed: save.result == .error(.ruleDraftMismatch) | 544 | docs/security/phase2/verification/RVServiceTests.log:390 |
| 65 | ruleSaveDraftMismatchWritesNothing() | PendingDispatchTests.swift:841:25 | Issue recorded | 550 | docs/security/phase2/verification/RVServiceTests.log:396 |
| 66 | ruleSaveDraftMismatchWritesNothing() | PendingDispatchTests.swift:540:6 | Caught error: DispatchExpectation() | 552 | docs/security/phase2/verification/RVServiceTests.log:402 |
| 67 | serviceRuntime_missingHomeCannotEnablePack() | LinuxResidualCoverageTests.swift:343:25 | Issue recorded | 554 | No historical issue match; unchanged fixture + byte-identical pre-pass service authority path |
| 68 | pendingDispatchDoesNotLogCommandText() | PendingDispatchTests.swift:841:25 | Issue recorded | 558 | docs/security/phase2/verification/RVServiceTests.log:354 |
| 69 | pendingDispatchDoesNotLogCommandText() | PendingDispatchTests.swift:262:6 | Caught error: DispatchExpectation() | 560 | docs/security/phase2/verification/RVServiceTests.log:371 |
| 70 | serviceRuntime_dispatchResiduals() | LinuxResidualCoverageTests.swift:219:25 | Issue recorded | 563 | No historical issue match; unchanged fixture + byte-identical pre-pass service authority path |
| 71 | PendingHostAsk_grokCreatesNoRows() | PendingHostAskTests.swift:152:25 | Issue recorded | 568 | No historical issue match; unchanged fixture + byte-identical pre-pass service authority path |
| 72 | PendingHostAsk_spendAllowEmptiesMatchingAwaiting() | PendingHostAskTests.swift:54:9 | Expectation failed: try await env.store.list(now: now).count == 1 | 570 | No historical issue match; unchanged fixture + byte-identical pre-pass service authority path |
| 73 | PendingHostAsk_spendAllowEmptiesMatchingAwaiting() | PendingHostAskTests.swift:60:25 | Issue recorded | 572 | No historical issue match; unchanged fixture + byte-identical pre-pass service authority path |
| 74 | PendingHostAsk_secondAskSameIdentityKeepsOneAwaiting() | PendingHostAskTests.swift:131:9 | Expectation failed: listed.count == 1 | 574 | No historical issue match; unchanged fixture + byte-identical pre-pass service authority path |
| 75 | PendingHostAsk_secondAskSameIdentityKeepsOneAwaiting() | PendingHostAskTests.swift:132:9 | Expectation failed: listed.first?.state == .awaitingHuman | 577 | No historical issue match; unchanged fixture + byte-identical pre-pass service authority path |
| 76 | PendingHostAsk_askWithSessionWritesAwaitingRowThatSurvivesNewStore() | PendingHostAskTests.swift:164:25 | Issue recorded | 581 | No historical issue match; unchanged fixture + byte-identical pre-pass service authority path |
| 77 | PendingHostAsk_askWithSessionWritesAwaitingRowThatSurvivesNewStore() | PendingHostAskTests.swift:12:6 | Caught error: PendingHostAskExpectation() | 583 | No historical issue match; unchanged fixture + byte-identical pre-pass service authority path |
| 78 | PendingHostAsk_missingSessionEncodesAskWithEmptyList() | PendingHostAskTests.swift:164:25 | Issue recorded | 585 | No historical issue match; unchanged fixture + byte-identical pre-pass service authority path |
| 79 | PendingHostAsk_missingSessionEncodesAskWithEmptyList() | PendingHostAskTests.swift:94:6 | Caught error: PendingHostAskExpectation() | 587 | No historical issue match; unchanged fixture + byte-identical pre-pass service authority path |
| 80 | PendingHostAsk_spendDenyStillCancelsMatchingAwaiting() | PendingHostAskTests.swift:75:9 | Expectation failed: try await env.store.list(now: now).count == 1 | 589 | No historical issue match; unchanged fixture + byte-identical pre-pass service authority path |
| 81 | PendingHostAsk_spendDenyStillCancelsMatchingAwaiting() | PendingHostAskTests.swift:82:25 | Issue recorded | 591 | No historical issue match; unchanged fixture + byte-identical pre-pass service authority path |
| 82 | hookEvaluateSpendDeny_recordsHookHost() | DenialLedgerRecordTests.swift:174:9 | Expectation failed: rows.count == 1 | 596 | docs/security/phase2a/verification/RVServiceTests-unsandboxed.log:330 |

## Verified unchanged failing fixtures

Each Git blob hash below matches both current source and `HEAD:<path>`.

```json
{
  "Tests/RVDomainTests/PendingApprovalLedgerTests.swift": "2b7dafc85cb55ed5a0609f1f28c6d2d2396c1a03",
  "Tests/RVPolicyTests/PendingApprovalStoreTests.swift": "45eb0f91fbf385cef17beff14f766b20c01b21f1",
  "Tests/RVIsolationTests/RuntimeResourceAdversarialTests.swift": "06c1862ca66fd8dce221854006ffa3dc86637327",
  "Tests/RVIsolationTests/WorkspaceHostTests.swift": "2b1465451945c97db039aad096c17a8a2b5232f9",
  "Tests/RVIsolationTests/LocalTerminalRestoreTests.swift": "3de4245e4b4205eb6823d1e955b013549f0eeedf",
  "Tests/RVIsolationTests/RuntimeTerminalTests.swift": "0ab69aa917fff39b4a008321badf5ba02e9068b2",
  "Tests/RVServiceTests/PendingResolveGrantTests.swift": "b468cdc021d1cc6693fbe124b075bfe177d39e51",
  "Tests/RVServiceTests/HookEvaluateTests.swift": "9dccfaeaa8e5da6e433576b7662e8b3771bb4d8f",
  "Tests/RVServiceTests/ExplainDispatchTests.swift": "310b716ae9c762ebd8b7ab9ec6e1d180b8b00789",
  "Tests/RVServiceTests/ServiceRuntimeEvaluateTests.swift": "3cbf797288de7ad93d91a32595b3d77c22102ff7",
  "Tests/RVServiceTests/PendingDispatchTests.swift": "baa5b5a4f3464256a6121ab00b903a20dd5e4548",
  "Tests/RVServiceTests/ServiceRuntimeAnalyticsTests.swift": "546c23b0d3c2a975822383c81a945429fdb5de81",
  "Tests/RVServiceTests/EnabledCompileTests.swift": "642a9fe39705fc29318d5f7383e9a2ec2ca4e217",
  "Tests/RVServiceTests/LinuxResidualCoverageTests.swift": "c292727f7fd23a05202d7dfcb185c5650035f9b3",
  "Tests/RVServiceTests/PendingHostAskTests.swift": "6250edda66e9eeee9a457719239c82106f8fd6bb",
  "Tests/RVServiceTests/DenialLedgerRecordTests.swift": "25c94894c9f6f80c3f17cf5159b5ea18ab8c7c76"
}
```

## Limits

No pre-Phase 2 whole-gate rerun was performed. Source-based service inheritance is distinguished from exact log matches. Later ambient-authority fixes and reruns are outside this first-run comparison. This report does not waive broad gate failures or certify overall release/security acceptance.

## Final broad-run comparison

This section supersedes first-pass gate counts while retaining their evidence above. Final logs are `verification/*-unsandboxed.log`. All final issues were compared individually against first-pass and pre-pass logs.

| Gate | Final result | Classification |
|---|---|---|
| Preflight | Exit 0, 0 failures, 2 warnings | GREEN after fixing three first-pass introduced checks |
| Domain | 478 tests, 39 suites, 8 issues | INHERITED FAILURE; 8 exact pre-pass matches |
| Policy | 325 tests, 34 suites, 4 issues | INHERITED FAILURE; 4 exact pre-pass matches |
| Isolation | 454 tests, 29 suites, 54 issues | INHERITED FAILURE; all 54 exact pre-pass matches |
| IPC | 95 tests, 7 suites, passed | GREEN |
| Service | 90 issue records before signal 5; suite not completed | INHERITED FAILURE; exact-log and unchanged-source evidence distinguished below |

```json
{
  "RVDomainTests": {
    "issues": 8,
    "exact_prepass_log_matches": 8,
    "exact_firstpass_log_matches": 8,
    "no_earlier_issue_record": 0
  },
  "RVPolicyTests": {
    "issues": 4,
    "exact_prepass_log_matches": 4,
    "exact_firstpass_log_matches": 4,
    "no_earlier_issue_record": 0
  },
  "RVIsolationTests": {
    "issues": 54,
    "exact_prepass_log_matches": 54,
    "exact_firstpass_log_matches": 54,
    "no_earlier_issue_record": 0
  },
  "RVServiceTests": {
    "issues": 90,
    "exact_prepass_log_matches": 41,
    "exact_firstpass_log_matches": 81,
    "no_earlier_issue_record": 9
  }
}
```

Final service emits 90 issues: 81 exactly match first-pass issues and 41 exactly match pre-pass issue records (overlapping sets). Nine signatures were absent from both earlier issue streams. They occur in unchanged `OneShotEvaluateTests`, `FakeXPCUnixSocketTests`, and `PendingResolveGrantTests`. Each follows the byte-identical pre-pass unauthenticated generic evaluation/mutation path. This establishes inherited cause without claiming those nine were previously logged.

The nine newly printed signatures are four one-shot evaluation reply assertions, two fake-XPC evaluation response assertions, and three concurrent pending-resolution/grant assertions. One-shot and fake-XPC fixtures call `handleIncoming` without authenticated context and cannot receive evaluate results; pending-resolution fixtures call generic `dispatch` and cannot mutate/grant. The unchanged authority gate refuses both before their expected work. No new broad failure cause is evidenced by the final run. The global service gate remains failed and incomplete.

The same final crash is at service-log lines 973–976 (`rows.count == 1`, actual zero, then array trap); signal 5 is recorded at line 951. The two new isolated ambient-credential tests pass within `IdentityAmbientCredentialTests` (suite passed at isolation-log line 692); the final isolation increase from 452 to 454 is not an increase in failures.

Revalidated byte-identical pre-pass service source SHA-256:

```json
{
  "Sources/RVService/AuthenticatedRequestContext.swift": "b8d7ab2d238a78a1b03969a9327d7581b4f410d83078b862e9ce06ef819b75c1",
  "Sources/RVService/ServiceRuntime.swift": "c676a83a41f7308c2aebee1bcb4db286abf98091e174bcebe7d82d346671de4f"
}
```

### Every final issue

#### RVDomainTests

| # | Test / parameter | Source | Signature | Final log line | Exact pre-pass match | Exact first-pass match / source evidence |
|---|---|---|---|---:|---|---|
| 1 | replayedIdenticalActionCannotBeConsumedTwice() | PendingApprovalLedgerTests.swift:209:6 | Caught error: .invalidRequest | 611 | docs/security/phase2a/verification/RVDomainTests-unsandboxed.log:756 | docs/security/phase2a1/verification/first-pass/RVDomainTests-unsandboxed.log:852 |
| 2 | consumeDeliversResolutionExactlyOnce() | PendingApprovalLedgerTests.swift:53:6 | Caught error: .invalidRequest | 616 | docs/security/phase2a/verification/RVDomainTests-unsandboxed.log:755 | docs/security/phase2a1/verification/first-pass/RVDomainTests-unsandboxed.log:862 |
| 3 | consumeFoldsEachDecisionIntoConsumedState(decision:) with 1 argument decision → .allowOnce | PendingApprovalLedgerTests.swift:474:6 | Caught error: .invalidRequest | 620 | docs/security/phase2a/verification/RVDomainTests-unsandboxed.log:785 | docs/security/phase2a1/verification/first-pass/RVDomainTests-unsandboxed.log:868 |
| 4 | consumeFoldsEachDecisionIntoConsumedState(decision:) with 1 argument decision → .createRule | PendingApprovalLedgerTests.swift:474:6 | Caught error: .invalidRequest | 625 | docs/security/phase2a/verification/RVDomainTests-unsandboxed.log:786 | docs/security/phase2a1/verification/first-pass/RVDomainTests-unsandboxed.log:875 |
| 5 | consumedStateRoundTripsThroughCodable() | PendingApprovalLedgerTests.swift:526:6 | Caught error: .invalidRequest | 634 | docs/security/phase2a/verification/RVDomainTests-unsandboxed.log:743 | docs/security/phase2a1/verification/first-pass/RVDomainTests-unsandboxed.log:854 |
| 6 | keepWaitingAllowsResolveAfterDeadline() | PendingApprovalLedgerTests.swift:362:9 | Expectation failed: resolved.authorizes(Self.fingerprint, identity: Self.identity) | 1248 | docs/security/phase2a/verification/RVDomainTests-unsandboxed.log:1248 | docs/security/phase2a1/verification/first-pass/RVDomainTests-unsandboxed.log:1248 |
| 7 | resolvedWithoutParentConsumedAtStaysResolved() | PendingApprovalLedgerTests.swift:617:9 | Expectation failed: decoded.authorizes(Self.fingerprint, identity: Self.identity) | 1296 | docs/security/phase2a/verification/RVDomainTests-unsandboxed.log:1344 | docs/security/phase2a1/verification/first-pass/RVDomainTests-unsandboxed.log:1344 |
| 8 | exactDeadlineIsStillAwaitingHuman() | PendingApprovalLedgerTests.swift:382:9 | Expectation failed: resolved.authorizes(Self.fingerprint, identity: Self.identity) | 1344 | docs/security/phase2a/verification/RVDomainTests-unsandboxed.log:1296 | docs/security/phase2a1/verification/first-pass/RVDomainTests-unsandboxed.log:1296 |

#### RVPolicyTests

| # | Test / parameter | Source | Signature | Final log line | Exact pre-pass match | Exact first-pass match / source evidence |
|---|---|---|---|---:|---|---|
| 1 | processRestartReloadsPendingAndResolvedRecords() | PendingApprovalStoreTests.swift:8:6 | Caught error: .invalidRequest | 403 | docs/security/phase2a/verification/RVPolicyTests-unsandboxed.log:377 | docs/security/phase2a1/verification/first-pass/RVPolicyTests-unsandboxed.log:383 |
| 2 | keepWaitingSurvivesRestartPastDeadline() | PendingApprovalStoreTests.swift:231:9 | Expectation failed: resolved.authorizes(Self.fingerprint, identity: Self.identity) | 405 | docs/security/phase2a/verification/RVPolicyTests-unsandboxed.log:385 | docs/security/phase2a1/verification/first-pass/RVPolicyTests-unsandboxed.log:384 |
| 3 | concurrentConsumeWinsOnce() | PendingApprovalStoreTests.swift:102:9 | Expectation failed: results.filter(\.isSuccess).count == 1 | 759 | docs/security/phase2a/verification/RVPolicyTests-unsandboxed.log:775 | docs/security/phase2a1/verification/first-pass/RVPolicyTests-unsandboxed.log:751 |
| 4 | concurrentConsumeWinsOnce() | PendingApprovalStoreTests.swift:103:9 | Expectation failed: results.filter { $0 == .alreadyConsumed }.count == 1 | 763 | docs/security/phase2a/verification/RVPolicyTests-unsandboxed.log:778 | docs/security/phase2a1/verification/first-pass/RVPolicyTests-unsandboxed.log:754 |

#### RVIsolationTests

| # | Test / parameter | Source | Signature | Final log line | Exact pre-pass match | Exact first-pass match / source evidence |
|---|---|---|---|---:|---|---|
| 1 | ensureTerminalRuntimeAdjudicatesExplicitProfile() | RuntimeResourceAdversarialTests.swift:307:5 | Expectation failed: WorkspaceControlSocket.writeFrame(fd: raw, body: ensureBody) | 411 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:382 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:419 |
| 2 | profileStagingFailureKeepsLaunchFailurePath() | RuntimeResourceAdversarialTests.swift:223:2 | Caught error: .unauthorizedClient | 419 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:397 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:624 |
| 3 | ensureTerminalRuntimeAcceptsKnownExplicitProfile() | RuntimeResourceAdversarialTests.swift:320:2 | Caught error: .unauthorizedClient | 421 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:394 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:427 |
| 4 | forgedAndCrossProjectProfileIDsFailClosedAtServer() | RuntimeResourceAdversarialTests.swift:130:2 | Caught error: .unauthorizedClient | 425 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:400 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:418 |
| 5 | defaultProfileNeverAutoAttachesNilLaunchKeepsBaseFence() | RuntimeResourceAdversarialTests.swift:167:2 | Caught error: .unauthorizedClient | 427 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:393 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:430 |
| 6 | ensureTerminalRuntimeAdjudicatesExplicitProfile() | RuntimeResourceAdversarialTests.swift:269:2 | Caught error: .disconnected | 428 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:390 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:428 |
| 7 | workspaceRunRestoresOnExitCloseDisconnectAndStdinEOF() | LocalTerminalRestoreTests.swift:52:6 | Caught error: .unauthorizedClient | 711 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:682 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:708 |
| 8 | clientsAttachDetachAndCancelWithoutSharingAuthority() | WorkspaceHostTests.swift:107:6 | Caught error: .unauthorizedClient | 718 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:702 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:651 |
| 9 | clientResubscribeAfterUnsubscribeReceivesReplay() | RuntimeTerminalTests.swift:291:6 | Caught error: .unauthorizedClient | 725 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:717 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:742 |
| 10 | disconnectAndProtocolErrorRestoreRawMode() | LocalTerminalRestoreTests.swift:142:6 | Caught error: .unauthorizedClient | 748 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:741 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:737 |
| 11 | malformedFramesAndForeignTokensDoNotMutate() | WorkspaceHostTests.swift:175:6 | Caught error: .unauthorizedClient | 751 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:736 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:734 |
| 12 | hostSurvivesTheCreatingClientAndAKilledClient() | WorkspaceHostTests.swift:238:6 | Caught error: .unauthorizedClient | 782 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:770 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:777 |
| 13 | hookAndBareLaunchesShareTheCageEnvironment() | RuntimeTerminalTests.swift:466:6 | Caught error: .unauthorizedClient | 792 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:783 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:803 |
| 14 | hostDeathDuringAPtyRuntimeIsOrphanedNotReattachable() | WorkspaceHostTests.swift:320:6 | Caught error: .unauthorizedClient | 801 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:780 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:793 |
| 15 | containedSessionSurvivesSetsIDAndDoubleForkUntilCancel() | RuntimeTerminalTests.swift:506:6 | Caught error: .unauthorizedClient | 810 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:794 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:815 |
| 16 | controlCInterruptsTheForegroundGroupWithoutKillingTheHost() | RuntimeTerminalTests.swift:542:6 | Caught error: .unauthorizedClient | 827 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:812 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:833 |
| 17 | childObservesResizeAndSignal() | RuntimeTerminalTests.swift:581:6 | Caught error: .unauthorizedClient | 845 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:829 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:850 |
| 18 | onlyInputLeaseOwnerCanResizeTerminal() | RuntimeTerminalTests.swift:610:6 | Caught error: .unauthorizedClient | 859 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:843 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:866 |
| 19 | twoViewersDetachReattachAndKeepInputExclusive() | RuntimeTerminalTests.swift:645:6 | Caught error: .unauthorizedClient | 880 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:860 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:883 |
| 20 | concurrentEnsureTerminalRuntimeRequestsShareOneRuntime() | RuntimeTerminalTests.swift:698:6 | Caught error: .unauthorizedClient | 890 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:873 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:899 |
| 21 | inputReachesOnlyTheAddressedRuntime() | RuntimeTerminalTests.swift:728:6 | Caught error: .unauthorizedClient | 899 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:879 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:921 |
| 22 | runtimeExitClosesTheTerminalAndLeavesTheWorkspace() | RuntimeTerminalTests.swift:770:6 | Caught error: .unauthorizedClient | 913 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:894 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:932 |
| 23 | launchFaultsDoNotReportARunningRuntime() | RuntimeTerminalTests.swift:827:9 | Expectation failed: writeFrame(raw, stolen) | 927 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:907 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:939 |
| 24 | launchFaultsDoNotReportARunningRuntime() | RuntimeTerminalTests.swift:808:6 | Caught error: .disconnected | 931 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:913 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:944 |
| 25 | closingTheWorkspaceKillsEveryPTYRuntime() | RuntimeTerminalTests.swift:932:6 | Caught error: .unauthorizedClient | 955 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:925 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:954 |
| 26 | aSlowSocketDoesNotStopTheOtherSubscriberOrClose() | RuntimeTerminalTests.swift:979:6 | Caught error: .unauthorizedClient | 964 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:942 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:963 |
| 27 | repeatedAttachCyclesDoNotLeakPTYs() | RuntimeTerminalTests.swift:1017:6 | Caught error: .unauthorizedClient | 969 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:948 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:972 |
| 28 | provingClientRestoresTheLocalTerminal() | RuntimeTerminalTests.swift:1074:9 | Expectation failed: waitUntil(seconds: 40) { FileManager.default.fileExists(atPath: ready.path) } | 1027 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1013 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:1021 |
| 29 | provingClientRestoresTheLocalTerminal() | RuntimeTerminalTests.swift:1075:9 | Expectation failed: waitUntilRaw(pty.slave) | 1029 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1015 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:1023 |
| 30 | provingClientRestoresTheLocalTerminal() | RuntimeTerminalTests.swift:1048:6 | Caught error: Error Domain=NSCocoaErrorDomain Code=260 "The file “client-sleep.pid” couldn’t be opened because there is no such file." UserInfo={NSFilePath=/tmp/<fixture>/ws/client-sleep.pid, NSURL=file:///tmp/<fixture>/ws/client-sleep.pid, NSUnderlyingError=<address> {Error Domain=NSPOSIXErrorDomain Code=2 "No such file or directory"}} | 1035 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1021 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:1029 |
| 31 | workspaceStartLeavesALiveHostAfterTheClientExits() | WorkspaceHostTests.swift:412:9 | Expectation failed: start.terminationStatus == 0 | 1041 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1027 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:1035 |
| 32 | workspaceStartLeavesALiveHostAfterTheClientExits() | WorkspaceHostTests.swift:398:6 | Caught error: .unauthorizedClient | 1044 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1030 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:1038 |
| 33 | hostDeathDropsTheTerminalAndRecoveryKillsTheGroup() | RuntimeTerminalTests.swift:1157:9 | Expectation failed: waitUntil(seconds: 40) { | 1056 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1035 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:1056 |
| 34 | hostDeathDropsTheTerminalAndRecoveryKillsTheGroup() | RuntimeTerminalTests.swift:1161:9 | Expectation failed: waitUntilRaw(pty.slave) | 1070 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1050 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:1070 |
| 35 | hostDeathDropsTheTerminalAndRecoveryKillsTheGroup() | RuntimeTerminalTests.swift:1162:26 | Expectation failed: pidFile(leaderURL) | 1073 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1053 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:1073 |
| 36 | rvSpawnedHostDiesOnSIGTERM() | WorkspaceHostTests.swift:437:9 | Expectation failed: start.terminationStatus == 0 | 1089 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1075 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:1083 |
| 37 | rvSpawnedHostDiesOnSIGTERM() | WorkspaceHostTests.swift:452:9 | Expectation failed: restart.terminationStatus == 0 | 1095 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1081 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:1089 |
| 38 | rvSpawnedHostDiesOnSIGTERM() | WorkspaceHostTests.swift:423:6 | Caught error: .unauthorizedClient | 1098 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1084 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:1092 |
| 39 | simultaneousCreatorsProduceOneOwner() | WorkspaceHostTests.swift:459:6 | Caught error: .unauthorizedClient | 1103 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1089 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:1097 |
| 40 | oneClientSerializesOverlappedCalls() | WorkspaceHostTests.swift:535:6 | Caught error: .unauthorizedClient | 1108 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1094 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:1102 |
| 41 | streamingClientMultiplexesOverlappedCalls() | WorkspaceHostTests.swift:557:6 | Caught error: .unauthorizedClient | 1111 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1097 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:1105 |
| 42 | legacyHostStaysUsableAndGatesProfilesPerCall() | WorkspaceHostTests.swift:633:6 | Caught error: .unauthorizedClient | 1118 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1104 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:1112 |
| 43 | explicitProfilesKeepSyntheticCredentialsAndSupportDisjoint() | WorkspaceHostTests.swift:653:6 | Caught error: .unauthorizedClient | 1121 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1107 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:1115 |
| 44 | hookAndProfileStayOrthogonalAtLaunch() | WorkspaceHostTests.swift:735:6 | Caught error: .unauthorizedClient | 1124 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1110 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:1118 |
| 45 | unknownOperationReceivesAnInvalidRequestEcho() | WorkspaceHostTests.swift:813:25 | Issue recorded | 1129 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1115 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:1123 |
| 46 | legacyEnsureReusesARunningTerminalAndLaunchesWhenEmpty() | WorkspaceHostTests.swift:833:6 | Caught error: .unauthorizedClient | 1133 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1119 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:1127 |
| 47 | ensureTerminalRuntimeIsExecutableAgnosticByContract() | WorkspaceHostTests.swift:861:6 | Caught error: .unauthorizedClient | 1136 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1122 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:1130 |
| 48 | ensureTerminalRuntimeNeverRelabelsTheExistingPrincipal() | WorkspaceHostTests.swift:886:6 | Caught error: .unauthorizedClient | 1139 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1125 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:1133 |
| 49 | malformedHookTagIsRefusedClientSideBeforeSpawn() | WorkspaceHostTests.swift:920:6 | Caught error: .unauthorizedClient | 1142 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1128 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:1136 |
| 50 | stagingOnlyTagStagesFilteredCredentialsWithoutHookRecord() | WorkspaceHostTests.swift:936:6 | Caught error: .unauthorizedClient | 1145 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1131 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:1139 |
| 51 | malformedHookTagIsRefusedBeforeSpawn() | WorkspaceHostTests.swift:1026:9 | Expectation failed: WorkspaceControlSocket.writeFrame(fd: raw, body: launchBody) | 1148 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1134 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:1142 |
| 52 | malformedHookTagIsRefusedBeforeSpawn() | WorkspaceHostTests.swift:999:6 | Caught error: .disconnected | 1156 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1142 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:1150 |
| 53 | controlLaunchBounds_fitDeveloperCommands() | WorkspaceHostTests.swift:1038:6 | Caught error: .unauthorizedClient | 1159 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1145 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:1153 |
| 54 | hostBinaryRunsTheProductionAdmission() | WorkspaceHostTests.swift:1079:6 | Caught error: .unauthorizedClient | 1162 | docs/security/phase2a/verification/RVIsolationTests-unsandboxed.log:1148 | docs/security/phase2a1/verification/first-pass/RVIsolationTests-unsandboxed.log:1156 |

#### RVServiceTests

| # | Test / parameter | Source | Signature | Final log line | Exact pre-pass match | Exact first-pass match / source evidence |
|---|---|---|---|---:|---|---|
| 1 | hookEvaluateAskOnPiPersistsWaitWithoutCommandOnList() | PendingDispatchTests.swift:740:25 | Issue recorded | 350 | docs/security/phase2/verification/RVServiceTests.log:407 | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:473 |
| 2 | fileToolAlwaysAllowFailsClosedWithoutMatchingView() | PendingDispatchTests.swift:520:25 | Issue recorded | 352 | docs/security/phase2/verification/RVServiceTests.log:398 | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:426 |
| 3 | alwaysBlockSaveDeniesThisWait() | PendingDispatchTests.swift:584:25 | Issue recorded | 354 | docs/security/phase2/verification/RVServiceTests.log:340 | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:487 |
| 4 | missingFolderUsesPlaceholder() | PendingDispatchTests.swift:841:25 | Issue recorded | 356 | docs/security/phase2/verification/RVServiceTests.log:352 | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:468 |
| 5 | pendingDispatchDoesNotLogCommandText() | PendingDispatchTests.swift:841:25 | Issue recorded | 358 | docs/security/phase2/verification/RVServiceTests.log:354 | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:558 |
| 6 | allowOncePeekUsesCompileSetAfterPackEnable() | PendingDispatchTests.swift:701:25 | Issue recorded | 360 | docs/security/phase2/verification/RVServiceTests.log:416 | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:501 |
| 7 | watchAcksUnchangedThenReturnsItemsAfterResolve() | PendingDispatchTests.swift:841:25 | Issue recorded | 362 | docs/security/phase2/verification/RVServiceTests.log:350 | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:429 |
| 8 | automaticStoreListsCreatedWaits() | PendingDispatchTests.swift:841:25 | Issue recorded | 364 | docs/security/phase2/verification/RVServiceTests.log:356 | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:484 |
| 9 | ruleSaveDraftMismatchWritesNothing() | PendingDispatchTests.swift:559:9 | Expectation failed: save.result == .error(.ruleDraftMismatch) | 366 | docs/security/phase2/verification/RVServiceTests.log:390 | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:544 |
| 10 | failedPlantConsumesWaitAndReportsNotUnlockable() | PendingDispatchTests.swift:659:9 | Expectation failed: resolved.result == .error(.pendingAllowOnceNotUnlockable) | 372 | docs/security/phase2/verification/RVServiceTests.log:440 | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:491 |
| 11 | failedPlantConsumesWaitAndReportsNotUnlockable() | PendingDispatchTests.swift:660:9 | Expectation failed: await approvals.resolveCalls.map(\.decision) == [.allowOnce] | 378 | docs/security/phase2/verification/RVServiceTests.log:446 | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:497 |
| 12 | ruleSaveDraftMismatchWritesNothing() | PendingDispatchTests.swift:841:25 | Issue recorded | 380 | docs/security/phase2/verification/RVServiceTests.log:396 | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:550 |
| 13 | failedPlantConsumesWaitAndReportsNotUnlockable() | PendingDispatchTests.swift:841:25 | Issue recorded | 382 | docs/security/phase2/verification/RVServiceTests.log:448 | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:499 |
| 14 | watchAcksUnchangedThenReturnsItemsAfterResolve() | PendingDispatchTests.swift:111:6 | Caught error: DispatchExpectation() | 385 | docs/security/phase2/verification/RVServiceTests.log:370 | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:431 |
| 15 | pendingDispatchDoesNotLogCommandText() | PendingDispatchTests.swift:262:6 | Caught error: DispatchExpectation() | 386 | docs/security/phase2/verification/RVServiceTests.log:371 | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:560 |
| 16 | missingFolderUsesPlaceholder() | PendingDispatchTests.swift:183:6 | Caught error: DispatchExpectation() | 387 | docs/security/phase2/verification/RVServiceTests.log:372 | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:470 |
| 17 | failedPlantConsumesWaitAndReportsNotUnlockable() | PendingDispatchTests.swift:638:6 | Caught error: DispatchExpectation() | 389 | docs/security/phase2/verification/RVServiceTests.log:450 | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:503 |
| 18 | ruleSaveDraftMismatchWritesNothing() | PendingDispatchTests.swift:540:6 | Caught error: DispatchExpectation() | 390 | docs/security/phase2/verification/RVServiceTests.log:402 | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:552 |
| 19 | automaticStoreListsCreatedWaits() | PendingDispatchTests.swift:777:6 | Caught error: DispatchExpectation() | 391 | docs/security/phase2/verification/RVServiceTests.log:389 | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:486 |
| 20 | alwaysAllowHardStopPreviewForbidsSaveAndWritesNothing() | PendingDispatchTests.swift:301:25 | Issue recorded | 394 | docs/security/phase2/verification/RVServiceTests.log:411 | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:506 |
| 21 | hookEvaluateAskWithoutSessionDoesNotPersist() | PendingDispatchTests.swift:766:25 | Issue recorded | 396 | docs/security/phase2/verification/RVServiceTests.log:346 | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:504 |
| 22 | alwaysAllowSaveAuthorizesNormalizedWrapperRetry() | PendingDispatchTests.swift:430:25 | Issue recorded | 398 | docs/security/phase2/verification/RVServiceTests.log:400 | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:510 |
| 23 | sessionSuffixOnlyWhenAskLineCollides() | PendingDispatchTests.swift:841:25 | Issue recorded | 400 | docs/security/phase2/verification/RVServiceTests.log:403 | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:475 |
| 24 | sessionSuffixOnlyWhenAskLineCollides() | PendingDispatchTests.swift:152:6 | Caught error: DispatchExpectation() | 402 | docs/security/phase2/verification/RVServiceTests.log:409 | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:477 |
| 25 | listOmitsCommandAndOrdersOldestFirst() | PendingDispatchTests.swift:841:25 | Issue recorded | 403 | docs/security/phase2/verification/RVServiceTests.log:437 | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:478 |
| 26 | listOmitsCommandAndOrdersOldestFirst() | PendingDispatchTests.swift:12:6 | Caught error: DispatchExpectation() | 405 | docs/security/phase2/verification/RVServiceTests.log:439 | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:483 |
| 27 | previewWithoutSaveLeavesWaitAwaitingHuman() | PendingDispatchTests.swift:340:25 | Issue recorded | 406 | docs/security/phase2/verification/RVServiceTests.log:405 | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:489 |
| 28 | allowOnceOnPiLeavesOpenCodeAwaiting() | PendingDispatchTests.swift:841:25 | Issue recorded | 408 | docs/security/phase2/verification/RVServiceTests.log:413 | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:437 |
| 29 | allowOnceOnPiLeavesOpenCodeAwaiting() | PendingDispatchTests.swift:45:6 | Caught error: DispatchExpectation() | 410 | docs/security/phase2/verification/RVServiceTests.log:415 | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:439 |
| 30 | missingCoordinatorFailsClosedWithoutSpendingAGrant() | PendingDispatchTests.swift:99:9 | Expectation failed: resolve.result == .error(.pendingCoordinatorUnavailable) | 411 | docs/security/phase2/verification/RVServiceTests.log:418 | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:512 |
| 31 | missingCoordinatorFailsClosedWithoutSpendingAGrant() | PendingDispatchTests.swift:101:9 | Expectation failed: listed.result == .error(.pendingCoordinatorUnavailable) | 417 | docs/security/phase2/verification/RVServiceTests.log:424 | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:518 |
| 32 | missingCoordinatorFailsClosedWithoutSpendingAGrant() | PendingDispatchTests.swift:105:9 | Expectation failed: watch.result == .error(.pendingCoordinatorUnavailable) | 423 | No exact pre-pass issue record | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:524 |
| 33 | resolveMapsLedgerErrors() | PendingDispatchTests.swift:220:9 | Expectation failed: missing.result == .error(.pendingNotFound) | 429 | docs/security/phase2/verification/RVServiceTests.log:358 | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:441 |
| 34 | resolveMapsLedgerErrors() | PendingDispatchTests.swift:237:9 | Expectation failed: identity.result == .error(.pendingIdentityMismatch) | 435 | docs/security/phase2/verification/RVServiceTests.log:364 | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:449 |
| 35 | resolveMapsLedgerErrors() | PendingDispatchTests.swift:251:9 | Expectation failed: fingerprint.result == .error(.pendingFingerprintMismatch) | 441 | docs/security/phase2/verification/RVServiceTests.log:373 | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:456 |
| 36 | resolveMapsLedgerErrors() | PendingDispatchTests.swift:259:9 | Expectation failed: second.result == .error(.pendingAlreadyTerminal) | 447 | docs/security/phase2/verification/RVServiceTests.log:379 | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:462 |
| 37 | extraAllowOnceStillWorksWithoutATypedRule() | PendingDispatchTests.swift:629:25 | Issue recorded | 453 | docs/security/phase2/verification/RVServiceTests.log:344 | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:471 |
| 38 | directConfigEditIsPickedUpByWarmRuntimeEvaluate() | EnabledCompileTests.swift:120:25 | Issue recorded | 455 | No exact pre-pass issue record | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:531 |
| 39 | alwaysAllowSaveAuthorizesFutureEvaluateWithoutExtraClick() | PendingDispatchTests.swift:368:25 | Issue recorded | 457 | docs/security/phase2/verification/RVServiceTests.log:338 | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:434 |
| 40 | classifyPeeksGrantWithoutSpending() | ExplainDispatchTests.swift:183:25 | Issue recorded | 459 | No exact pre-pass issue record | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:332 |
| 41 | PendingHostAsk_missingSessionEncodesAskWithEmptyList() | PendingHostAskTests.swift:164:25 | Issue recorded | 461 | No exact pre-pass issue record | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:585 |
| 42 | PendingHostAsk_secondAskSameIdentityKeepsOneAwaiting() | PendingHostAskTests.swift:131:9 | Expectation failed: listed.count == 1 | 463 | No exact pre-pass issue record | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:574 |
| 43 | PendingHostAsk_secondAskSameIdentityKeepsOneAwaiting() | PendingHostAskTests.swift:132:9 | Expectation failed: listed.first?.state == .awaitingHuman | 466 | No exact pre-pass issue record | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:577 |
| 44 | PendingHostAsk_missingSessionEncodesAskWithEmptyList() | PendingHostAskTests.swift:94:6 | Caught error: PendingHostAskExpectation() | 470 | No exact pre-pass issue record | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:587 |
| 45 | PendingHostAsk_askWithSessionWritesAwaitingRowThatSurvivesNewStore() | PendingHostAskTests.swift:164:25 | Issue recorded | 471 | No exact pre-pass issue record | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:581 |
| 46 | PendingHostAsk_askWithSessionWritesAwaitingRowThatSurvivesNewStore() | PendingHostAskTests.swift:12:6 | Caught error: PendingHostAskExpectation() | 473 | No exact pre-pass issue record | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:583 |
| 47 | PendingHostAsk_grokCreatesNoRows() | PendingHostAskTests.swift:152:25 | Issue recorded | 474 | No exact pre-pass issue record | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:568 |
| 48 | emptyStdinOverlay_overridesJSONStdin() | HookEvaluateTests.swift:181:25 | Issue recorded | 476 | No exact pre-pass issue record | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:378 |
| 49 | setPackEnabledGrowsAndShrinksCompiledPackIDs() | EnabledCompileTests.swift:167:25 | Issue recorded | 478 | No exact pre-pass issue record | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:542 |
| 50 | PendingHostAsk_spendDenyStillCancelsMatchingAwaiting() | PendingHostAskTests.swift:75:9 | Expectation failed: try await env.store.list(now: now).count == 1 | 480 | No exact pre-pass issue record | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:589 |
| 51 | PendingHostAsk_spendDenyStillCancelsMatchingAwaiting() | PendingHostAskTests.swift:82:25 | Issue recorded | 482 | No exact pre-pass issue record | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:591 |
| 52 | implicitHello_claudeResetHardReturnsAskWire() | HookEvaluateTests.swift:52:25 | Issue recorded | 484 | No exact pre-pass issue record | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:417 |
| 53 | hookEvaluate_doesNotLogCommandText() | HookEvaluateTests.swift:357:9 | Expectation failed: blob.contains("hookEvaluate") | 486 | No exact pre-pass issue record | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:373 |
| 54 | stdinOverlay_replacesJSONStdinOnImplicitHello() | HookEvaluateTests.swift:157:25 | Issue recorded | 489 | No exact pre-pass issue record | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:326 |
| 55 | explainPeeksGrantWithoutSpending() | ExplainDispatchTests.swift:95:25 | Issue recorded | 491 | No exact pre-pass issue record | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:330 |
| 56 | stdinOverlay_winsOverJSONAllowStdin() | HookEvaluateTests.swift:206:25 | Issue recorded | 493 | No exact pre-pass issue record | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:386 |
| 57 | hookEvaluate_resolvesPacksFromConfig_notDayOne() | HookEvaluateTests.swift:91:25 | Issue recorded | 495 | No exact pre-pass issue record | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:432 |
| 58 | PendingHostAsk_spendAllowEmptiesMatchingAwaiting() | PendingHostAskTests.swift:54:9 | Expectation failed: try await env.store.list(now: now).count == 1 | 497 | No exact pre-pass issue record | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:570 |
| 59 | PendingHostAsk_spendAllowEmptiesMatchingAwaiting() | PendingHostAskTests.swift:60:25 | Issue recorded | 499 | No exact pre-pass issue record | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:572 |
| 60 | evaluateSnapshotsEnabledPackIDsBeforeAsyncWork() | ServiceRuntimeAnalyticsTests.swift:27:25 | Issue recorded | 501 | docs/security/phase2/verification/RVServiceTests.log:348 | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:540 |
| 61 | hookEvaluateRecordsDecisionAnalyticsWithoutCommandText() | ServiceRuntimeAnalyticsTests.swift:123:25 | Issue recorded | 503 | docs/security/phase2/verification/RVServiceTests.log:342 | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:535 |
| 62 | implicitHello_grokResetHardReturnsCanonicalDenyWire() | HookEvaluateTests.swift:30:25 | Issue recorded | 505 | No exact pre-pass issue record | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:420 |
| 63 | grokStashDrop_emptyStdout() | HookEvaluateTests.swift:272:25 | Issue recorded | 507 | No exact pre-pass issue record | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:422 |
| 64 | setPackEnabledRefreshesAnalyticsPackSnapshot() | ServiceRuntimeAnalyticsTests.swift:67:25 | Issue recorded | 509 | docs/security/phase2/verification/RVServiceTests.log:336 | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:508 |
| 65 | oldEvaluate_stillWorksAfterHookEvaluate() | HookEvaluateTests.swift:334:25 | Issue recorded | 522 | No exact pre-pass issue record | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:424 |
| 66 | missingStdinOverlay_keepsJSONStdin() | HookEvaluateTests.swift:253:25 | Issue recorded | 524 | No exact pre-pass issue record | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:412 |
| 67 | majorSemverEvaluateAfterSuccessfulHello_doesNotEvaluate() | OneShotEvaluateTests.swift:155:25 | Issue recorded | 526 | No exact pre-pass issue record | No exact first-pass issue record; unchanged fixture + byte-identical pre-pass service authority path |
| 68 | dispatchEvaluate_grantHonorsOnceForCwd() | ServiceRuntimeEvaluateTests.swift:154:25 | Issue recorded | 528 | No exact pre-pass issue record | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:409 |
| 69 | dispatchEvaluate_emptyEnabledPacksDoesNotRefillDayOne() | ServiceRuntimeEvaluateTests.swift:100:25 | Issue recorded | 530 | No exact pre-pass issue record | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:388 |
| 70 | dispatchEvaluate_disabledCatalogPackStillDeniesResetHard() | ServiceRuntimeEvaluateTests.swift:117:25 | Issue recorded | 532 | No exact pre-pass issue record | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:376 |
| 71 | implicitHelloOnEvaluate_oneShotDeniesResetHard() | OneShotEvaluateTests.swift:19:25 | Issue recorded | 534 | No exact pre-pass issue record | No exact first-pass issue record; unchanged fixture + byte-identical pre-pass service authority path |
| 72 | oldHelloThenEvaluateWithoutClientSemver_stillWorks() | OneShotEvaluateTests.swift:249:25 | Issue recorded | 542 | No exact pre-pass issue record | No exact first-pass issue record; unchanged fixture + byte-identical pre-pass service authority path |
| 73 | matchingClientSemverAfterSuccessfulHello_stillEvaluates() | OneShotEvaluateTests.swift:220:25 | Issue recorded | 546 | No exact pre-pass issue record | No exact first-pass issue record; unchanged fixture + byte-identical pre-pass service authority path |
| 74 | PendingResolveGrant_secondAllowOnceIsAlreadyTerminalWithoutSecondGrant() | PendingResolveGrantTests.swift:101:9 | Expectation failed: grants == 1 | 549 | No exact pre-pass issue record | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:340 |
| 75 | PendingResolveGrant_secondAllowOnceIsAlreadyTerminalWithoutSecondGrant() | PendingResolveGrantTests.swift:106:9 | Expectation failed: again.result == .error(.pendingAlreadyTerminal) | 552 | No exact pre-pass issue record | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:344 |
| 76 | PendingResolveGrant_nonSpendFirstAllowOnceDoesNotPlant(_:) with 1 argument host → .codex | PendingResolveGrantTests.swift:322:9 | Expectation failed: resolved.result == .error(.pendingAllowOnceNotUnlockable) | 558 | No exact pre-pass issue record | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:396 |
| 77 | PendingResolveGrant_nonSpendFirstAllowOnceDoesNotPlant(_:) with 1 argument host → .grok | PendingResolveGrantTests.swift:322:9 | Expectation failed: resolved.result == .error(.pendingAllowOnceNotUnlockable) | 564 | No exact pre-pass issue record | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:380 |
| 78 | PendingResolveGrant_nonSpendFirstAllowOnceDoesNotPlant(_:) with 1 argument host → .cursor | PendingResolveGrantTests.swift:322:9 | Expectation failed: resolved.result == .error(.pendingAllowOnceNotUnlockable) | 577 | No exact pre-pass issue record | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:402 |
| 79 | PendingResolveGrant_missingCoordinatorFailsClosedWithoutGrant() | PendingResolveGrantTests.swift:188:9 | Expectation failed: resolve.result == .error(.pendingCoordinatorUnavailable) | 583 | No exact pre-pass issue record | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:320 |
| 80 | PendingResolveGrant_alreadyAllowResolvesWithoutSecondGrant() | PendingResolveGrantTests.swift:202:25 | Issue recorded | 592 | No exact pre-pass issue record | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:351 |
| 81 | PendingResolveGrant_allowOncePlantsGrantAndNextApplyAllowsOnce() | PendingResolveGrantTests.swift:22:25 | Issue recorded | 600 | No exact pre-pass issue record | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:338 |
| 82 | serviceRuntime_missingHomeCannotEnablePack() | LinuxResidualCoverageTests.swift:343:25 | Issue recorded | 602 | No exact pre-pass issue record | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:554 |
| 83 | PendingResolveGrant_hardBindDoesNotPlantOrResolve() | PendingResolveGrantTests.swift:135:9 | Expectation failed: resolved.result == .error(.pendingAllowOnceNotUnlockable) | 605 | No exact pre-pass issue record | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:390 |
| 84 | PendingResolveGrant_denyResolvesWithoutGrant() | PendingResolveGrantTests.swift:60:25 | Issue recorded | 616 | No exact pre-pass issue record | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:335 |
| 85 | oneShotEvaluateWithoutPriorHello_deniesResetHard() | FakeXPCUnixSocketTests.swift:24:9 | Expectation failed: result["error"] == nil | 851 | No exact pre-pass issue record | No exact first-pass issue record; unchanged fixture + byte-identical pre-pass service authority path |
| 86 | oneShotEvaluateWithoutPriorHello_deniesResetHard() | FakeXPCUnixSocketTests.swift:25:28 | Expectation failed: result["evaluate"] as? [String: Any] | 859 | No exact pre-pass issue record | No exact first-pass issue record; unchanged fixture + byte-identical pre-pass service authority path |
| 87 | PendingResolveGrant_concurrentAllowOncePlantsAtMostOneGrant() | PendingResolveGrantTests.swift:88:9 | Expectation failed: planted.count == 1 | 917 | No exact pre-pass issue record | No exact first-pass issue record; unchanged fixture + byte-identical pre-pass service authority path |
| 88 | PendingResolveGrant_concurrentAllowOncePlantsAtMostOneGrant() | PendingResolveGrantTests.swift:89:9 | Expectation failed: rejected.count == 1 | 920 | No exact pre-pass issue record | No exact first-pass issue record; unchanged fixture + byte-identical pre-pass service authority path |
| 89 | PendingResolveGrant_concurrentAllowOncePlantsAtMostOneGrant() | PendingResolveGrantTests.swift:90:9 | Expectation failed: try await env.grantedCount() == 1 | 923 | No exact pre-pass issue record | No exact first-pass issue record; unchanged fixture + byte-identical pre-pass service authority path |
| 90 | hookEvaluateSpendDeny_recordsHookHost() | DenialLedgerRecordTests.swift:174:9 | Expectation failed: rows.count == 1 | 973 | docs/security/phase2a/verification/RVServiceTests-unsandboxed.log:330 | docs/security/phase2a1/verification/first-pass/RVServiceTests-unsandboxed.log:596 |

### Revalidated final failing-fixture Git blob hashes

All current fixture blobs below match HEAD.

```json
{
  "Tests/RVDomainTests/PendingApprovalLedgerTests.swift": "2b7dafc85cb55ed5a0609f1f28c6d2d2396c1a03",
  "Tests/RVPolicyTests/PendingApprovalStoreTests.swift": "45eb0f91fbf385cef17beff14f766b20c01b21f1",
  "Tests/RVIsolationTests/RuntimeResourceAdversarialTests.swift": "06c1862ca66fd8dce221854006ffa3dc86637327",
  "Tests/RVIsolationTests/LocalTerminalRestoreTests.swift": "3de4245e4b4205eb6823d1e955b013549f0eeedf",
  "Tests/RVIsolationTests/WorkspaceHostTests.swift": "2b1465451945c97db039aad096c17a8a2b5232f9",
  "Tests/RVIsolationTests/RuntimeTerminalTests.swift": "0ab69aa917fff39b4a008321badf5ba02e9068b2",
  "Tests/RVServiceTests/PendingDispatchTests.swift": "baa5b5a4f3464256a6121ab00b903a20dd5e4548",
  "Tests/RVServiceTests/EnabledCompileTests.swift": "642a9fe39705fc29318d5f7383e9a2ec2ca4e217",
  "Tests/RVServiceTests/ExplainDispatchTests.swift": "310b716ae9c762ebd8b7ab9ec6e1d180b8b00789",
  "Tests/RVServiceTests/PendingHostAskTests.swift": "6250edda66e9eeee9a457719239c82106f8fd6bb",
  "Tests/RVServiceTests/HookEvaluateTests.swift": "9dccfaeaa8e5da6e433576b7662e8b3771bb4d8f",
  "Tests/RVServiceTests/ServiceRuntimeAnalyticsTests.swift": "546c23b0d3c2a975822383c81a945429fdb5de81",
  "Tests/RVServiceTests/OneShotEvaluateTests.swift": "1dc9ab95def39d469ecff2bed26cf8e255f20e08",
  "Tests/RVServiceTests/ServiceRuntimeEvaluateTests.swift": "3cbf797288de7ad93d91a32595b3d77c22102ff7",
  "Tests/RVServiceTests/PendingResolveGrantTests.swift": "b468cdc021d1cc6693fbe124b075bfe177d39e51",
  "Tests/RVServiceTests/LinuxResidualCoverageTests.swift": "c292727f7fd23a05202d7dfcb185c5650035f9b3",
  "Tests/RVServiceTests/FakeXPCUnixSocketTests.swift": "2a1fd668775f95be3fddac5253c0553be19d2f48",
  "Tests/RVServiceTests/DenialLedgerRecordTests.swift": "25c94894c9f6f80c3f17cf5159b5ea18ab8c7c76"
}
```
