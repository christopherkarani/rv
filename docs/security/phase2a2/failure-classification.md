# Phase 2A.2 failure classification

Phase 2A.2 stopped before source implementation. This report independently compares every issue in the requested broad run against the final Phase 2A.1 logs, and rechecks the preserved source hashes. No tests or source edits were performed during classification.

## Gate status

| Gate | Current result | Classification |
|---|---|---|
| Preflight | Exit 0 | GREEN |
| RVDomainTests | 478 tests, 39 suites, 8 issues | INHERITED FAILURE — all 8 exact final Phase 2A.1 matches |
| RVPolicyTests | 325 tests, 34 suites, 4 issues | INHERITED FAILURE — all 4 exact matches |
| RVIsolationTests | 454 tests, 29 suites, 54 issues | INHERITED FAILURE — all 54 exact matches |
| RVIPCTests | 95 tests, 7 suites passed | GREEN |
| RVServiceTests | Signal 5 after 41 printed issue records; suite incomplete | INHERITED FAILURE — all 41 exact matches; same zero-row array trap |

No unmatched current failure signature or new broad failure cause was identified. Failed gates remain failed; unchanged source and inherited failures do not prove product acceptance.

## Machine-readable comparison

```json
{
  "RVDomainTests": {
    "current_issue_records": 8,
    "exact_phase2a1_final_matches": 8,
    "unmatched_current_signatures": 0,
    "prior_phase2a1_issue_records": 8
  },
  "RVPolicyTests": {
    "current_issue_records": 4,
    "exact_phase2a1_final_matches": 4,
    "unmatched_current_signatures": 0,
    "prior_phase2a1_issue_records": 4
  },
  "RVIsolationTests": {
    "current_issue_records": 54,
    "exact_phase2a1_final_matches": 54,
    "unmatched_current_signatures": 0,
    "prior_phase2a1_issue_records": 54
  },
  "RVServiceTests": {
    "current_issue_records": 41,
    "exact_phase2a1_final_matches": 41,
    "unmatched_current_signatures": 0,
    "prior_phase2a1_issue_records": 90
  }
}
```

## Method and source preservation

Each issue is matched using test name, parameter argument, source filename, source line, column, and failure message. Only temporary fixture directory names, hexadecimal memory addresses, and UUIDs are normalized. Equal total counts are not treated as inheritance evidence.

`baseline.json` records starting branch `phase-2Identity`, HEAD `2df5484972fa2ad1afe9394941e023e7ad01bef0`, and 31 SHA-256 source/test/script/Package hashes. All 31 were independently recomputed from the working tree and match the baseline. `source-preservation.json` likewise records no changes. The recoverable archive is `/private/tmp/rv-phase2a2-before-authorization-20260930.tar.gz`.

## Service crash and reporting limits

Current service output contains 41 issues versus 90 printed before the final Phase 2A.1 crash. Every currently printed issue has an exact Phase 2A.1 match. This is a subset of the failed concurrent suite; the 49 unprinted prior issue records are not classified as newly passing. Scheduling and the early array trap limit issue reporting.

Final Phase 2A.1 separately documented nine signatures newly visible relative to its earlier runs and established their inherited cause through unchanged one-shot/fake-XPC/pending-resolution fixtures and byte-identical generic authorization paths. This pass introduces no source changes; its smaller printed stream does not change that evidence or establish those tests now pass.

`hookEvaluateSpendDeny_recordsHookHost` again expects `rows.count == 1`, observes zero, then accesses `rows[0]`. Current log line 445 records that expectation and line 448 records `Fatal error: Index out of range`. The generic service path still refuses unauthenticated agent/mutation operations before the old fixtures can produce their expected replies, pending rows, or grants.

Crash signatures:

```json
[
  {
    "line": 432,
    "signature": "unexpected signal code 5"
  },
  {
    "line": 448,
    "signature": "Swift/ContiguousArrayBuffer.swift:695: Fatal error: Index out of range"
  }
]
```

## Every current failure and exact prior match

### RVDomainTests

Current log: `verification/RVDomainTests-unsandboxed.log`.

| # | Test / parameter | Source | Normalized signature | Current log line | Exact final Phase 2A.1 match |
|---|---|---|---|---:|---|
| 1 | replayedIdenticalActionCannotBeConsumedTwice() | PendingApprovalLedgerTests.swift:209:6 | Caught error: .invalidRequest | 774 | docs/security/phase2a1/verification/RVDomainTests-unsandboxed.log:611 |
| 2 | consumedStateRoundTripsThroughCodable() | PendingApprovalLedgerTests.swift:526:6 | Caught error: .invalidRequest | 778 | docs/security/phase2a1/verification/RVDomainTests-unsandboxed.log:634 |
| 3 | consumeFoldsEachDecisionIntoConsumedState(decision:) with 1 argument decision → .allowOnce | PendingApprovalLedgerTests.swift:474:6 | Caught error: .invalidRequest | 798 | docs/security/phase2a1/verification/RVDomainTests-unsandboxed.log:620 |
| 4 | consumeFoldsEachDecisionIntoConsumedState(decision:) with 1 argument decision → .createRule | PendingApprovalLedgerTests.swift:474:6 | Caught error: .invalidRequest | 800 | docs/security/phase2a1/verification/RVDomainTests-unsandboxed.log:625 |
| 5 | consumeDeliversResolutionExactlyOnce() | PendingApprovalLedgerTests.swift:53:6 | Caught error: .invalidRequest | 802 | docs/security/phase2a1/verification/RVDomainTests-unsandboxed.log:616 |
| 6 | exactDeadlineIsStillAwaitingHuman() | PendingApprovalLedgerTests.swift:382:9 | Expectation failed: resolved.authorizes(Self.fingerprint, identity: Self.identity) | 1250 | docs/security/phase2a1/verification/RVDomainTests-unsandboxed.log:1344 |
| 7 | resolvedWithoutParentConsumedAtStaysResolved() | PendingApprovalLedgerTests.swift:617:9 | Expectation failed: decoded.authorizes(Self.fingerprint, identity: Self.identity) | 1298 | docs/security/phase2a1/verification/RVDomainTests-unsandboxed.log:1296 |
| 8 | keepWaitingAllowsResolveAfterDeadline() | PendingApprovalLedgerTests.swift:362:9 | Expectation failed: resolved.authorizes(Self.fingerprint, identity: Self.identity) | 1346 | docs/security/phase2a1/verification/RVDomainTests-unsandboxed.log:1248 |

### RVPolicyTests

Current log: `verification/RVPolicyTests-unsandboxed.log`.

| # | Test / parameter | Source | Normalized signature | Current log line | Exact final Phase 2A.1 match |
|---|---|---|---|---:|---|
| 1 | processRestartReloadsPendingAndResolvedRecords() | PendingApprovalStoreTests.swift:8:6 | Caught error: .invalidRequest | 378 | docs/security/phase2a1/verification/RVPolicyTests-unsandboxed.log:403 |
| 2 | keepWaitingSurvivesRestartPastDeadline() | PendingApprovalStoreTests.swift:231:9 | Expectation failed: resolved.authorizes(Self.fingerprint, identity: Self.identity) | 381 | docs/security/phase2a1/verification/RVPolicyTests-unsandboxed.log:405 |
| 3 | concurrentConsumeWinsOnce() | PendingApprovalStoreTests.swift:102:9 | Expectation failed: results.filter(\.isSuccess).count == 1 | 756 | docs/security/phase2a1/verification/RVPolicyTests-unsandboxed.log:759 |
| 4 | concurrentConsumeWinsOnce() | PendingApprovalStoreTests.swift:103:9 | Expectation failed: results.filter { $0 == .alreadyConsumed }.count == 1 | 760 | docs/security/phase2a1/verification/RVPolicyTests-unsandboxed.log:763 |

### RVIsolationTests

Current log: `verification/RVIsolationTests-unsandboxed.log`.

| # | Test / parameter | Source | Normalized signature | Current log line | Exact final Phase 2A.1 match |
|---|---|---|---|---:|---|
| 1 | ensureTerminalRuntimeAdjudicatesExplicitProfile() | RuntimeResourceAdversarialTests.swift:307:5 | Expectation failed: WorkspaceControlSocket.writeFrame(fd: raw, body: ensureBody) | 380 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:411 |
| 2 | ensureTerminalRuntimeAdjudicatesExplicitProfile() | RuntimeResourceAdversarialTests.swift:269:2 | Caught error: .disconnected | 388 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:428 |
| 3 | forgedAndCrossProjectProfileIDsFailClosedAtServer() | RuntimeResourceAdversarialTests.swift:130:2 | Caught error: .unauthorizedClient | 391 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:425 |
| 4 | ensureTerminalRuntimeAcceptsKnownExplicitProfile() | RuntimeResourceAdversarialTests.swift:320:2 | Caught error: .unauthorizedClient | 394 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:421 |
| 5 | profileStagingFailureKeepsLaunchFailurePath() | RuntimeResourceAdversarialTests.swift:223:2 | Caught error: .unauthorizedClient | 396 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:419 |
| 6 | defaultProfileNeverAutoAttachesNilLaunchKeepsBaseFence() | RuntimeResourceAdversarialTests.swift:167:2 | Caught error: .unauthorizedClient | 406 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:427 |
| 7 | workspaceRunRestoresOnExitCloseDisconnectAndStdinEOF() | LocalTerminalRestoreTests.swift:52:6 | Caught error: .unauthorizedClient | 662 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:711 |
| 8 | clientsAttachDetachAndCancelWithoutSharingAuthority() | WorkspaceHostTests.swift:107:6 | Caught error: .unauthorizedClient | 705 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:718 |
| 9 | clientResubscribeAfterUnsubscribeReceivesReplay() | RuntimeTerminalTests.swift:291:6 | Caught error: .unauthorizedClient | 710 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:725 |
| 10 | malformedFramesAndForeignTokensDoNotMutate() | WorkspaceHostTests.swift:175:6 | Caught error: .unauthorizedClient | 736 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:751 |
| 11 | disconnectAndProtocolErrorRestoreRawMode() | LocalTerminalRestoreTests.swift:142:6 | Caught error: .unauthorizedClient | 739 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:748 |
| 12 | hostSurvivesTheCreatingClientAndAKilledClient() | WorkspaceHostTests.swift:238:6 | Caught error: .unauthorizedClient | 763 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:782 |
| 13 | hookAndBareLaunchesShareTheCageEnvironment() | RuntimeTerminalTests.swift:466:6 | Caught error: .unauthorizedClient | 790 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:792 |
| 14 | hostDeathDuringAPtyRuntimeIsOrphanedNotReattachable() | WorkspaceHostTests.swift:320:6 | Caught error: .unauthorizedClient | 793 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:801 |
| 15 | containedSessionSurvivesSetsIDAndDoubleForkUntilCancel() | RuntimeTerminalTests.swift:506:6 | Caught error: .unauthorizedClient | 805 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:810 |
| 16 | controlCInterruptsTheForegroundGroupWithoutKillingTheHost() | RuntimeTerminalTests.swift:542:6 | Caught error: .unauthorizedClient | 814 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:827 |
| 17 | childObservesResizeAndSignal() | RuntimeTerminalTests.swift:581:6 | Caught error: .unauthorizedClient | 831 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:845 |
| 18 | onlyInputLeaseOwnerCanResizeTerminal() | RuntimeTerminalTests.swift:610:6 | Caught error: .unauthorizedClient | 849 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:859 |
| 19 | twoViewersDetachReattachAndKeepInputExclusive() | RuntimeTerminalTests.swift:645:6 | Caught error: .unauthorizedClient | 866 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:880 |
| 20 | concurrentEnsureTerminalRuntimeRequestsShareOneRuntime() | RuntimeTerminalTests.swift:698:6 | Caught error: .unauthorizedClient | 879 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:890 |
| 21 | inputReachesOnlyTheAddressedRuntime() | RuntimeTerminalTests.swift:728:6 | Caught error: .unauthorizedClient | 888 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:899 |
| 22 | runtimeExitClosesTheTerminalAndLeavesTheWorkspace() | RuntimeTerminalTests.swift:770:6 | Caught error: .unauthorizedClient | 904 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:913 |
| 23 | launchFaultsDoNotReportARunningRuntime() | RuntimeTerminalTests.swift:827:9 | Expectation failed: writeFrame(raw, stolen) | 912 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:927 |
| 24 | launchFaultsDoNotReportARunningRuntime() | RuntimeTerminalTests.swift:808:6 | Caught error: .disconnected | 916 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:931 |
| 25 | closingTheWorkspaceKillsEveryPTYRuntime() | RuntimeTerminalTests.swift:932:6 | Caught error: .unauthorizedClient | 945 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:955 |
| 26 | aSlowSocketDoesNotStopTheOtherSubscriberOrClose() | RuntimeTerminalTests.swift:979:6 | Caught error: .unauthorizedClient | 957 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:964 |
| 27 | repeatedAttachCyclesDoNotLeakPTYs() | RuntimeTerminalTests.swift:1017:6 | Caught error: .unauthorizedClient | 966 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:969 |
| 28 | provingClientRestoresTheLocalTerminal() | RuntimeTerminalTests.swift:1074:9 | Expectation failed: waitUntil(seconds: 40) { FileManager.default.fileExists(atPath: ready.path) } | 1027 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:1027 |
| 29 | workspaceStartLeavesALiveHostAfterTheClientExits() | WorkspaceHostTests.swift:412:9 | Expectation failed: start.terminationStatus == 0 | 1032 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:1041 |
| 30 | workspaceStartLeavesALiveHostAfterTheClientExits() | WorkspaceHostTests.swift:398:6 | Caught error: .unauthorizedClient | 1035 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:1044 |
| 31 | provingClientRestoresTheLocalTerminal() | RuntimeTerminalTests.swift:1075:9 | Expectation failed: waitUntilRaw(pty.slave) | 1038 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:1029 |
| 32 | provingClientRestoresTheLocalTerminal() | RuntimeTerminalTests.swift:1048:6 | Caught error: Error Domain=NSCocoaErrorDomain Code=260 "The file “client-sleep.pid” couldn’t be opened because there is no such file." UserInfo={NSFilePath=/tmp/<fixture>/ws/client-sleep.pid, NSURL=file:///tmp/<fixture>/ws/client-sleep.pid, NSUnderlyingError=<address> {Error Domain=NSPOSIXErrorDomain Code=2 "No such file or directory"}} | 1044 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:1035 |
| 33 | hostDeathDropsTheTerminalAndRecoveryKillsTheGroup() | RuntimeTerminalTests.swift:1157:9 | Expectation failed: waitUntil(seconds: 40) { | 1054 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:1056 |
| 34 | hostDeathDropsTheTerminalAndRecoveryKillsTheGroup() | RuntimeTerminalTests.swift:1161:9 | Expectation failed: waitUntilRaw(pty.slave) | 1068 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:1070 |
| 35 | hostDeathDropsTheTerminalAndRecoveryKillsTheGroup() | RuntimeTerminalTests.swift:1162:26 | Expectation failed: pidFile(leaderURL) | 1071 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:1073 |
| 36 | rvSpawnedHostDiesOnSIGTERM() | WorkspaceHostTests.swift:437:9 | Expectation failed: start.terminationStatus == 0 | 1089 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:1089 |
| 37 | rvSpawnedHostDiesOnSIGTERM() | WorkspaceHostTests.swift:452:9 | Expectation failed: restart.terminationStatus == 0 | 1095 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:1095 |
| 38 | rvSpawnedHostDiesOnSIGTERM() | WorkspaceHostTests.swift:423:6 | Caught error: .unauthorizedClient | 1098 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:1098 |
| 39 | simultaneousCreatorsProduceOneOwner() | WorkspaceHostTests.swift:459:6 | Caught error: .unauthorizedClient | 1103 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:1103 |
| 40 | oneClientSerializesOverlappedCalls() | WorkspaceHostTests.swift:535:6 | Caught error: .unauthorizedClient | 1108 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:1108 |
| 41 | streamingClientMultiplexesOverlappedCalls() | WorkspaceHostTests.swift:557:6 | Caught error: .unauthorizedClient | 1111 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:1111 |
| 42 | legacyHostStaysUsableAndGatesProfilesPerCall() | WorkspaceHostTests.swift:633:6 | Caught error: .unauthorizedClient | 1118 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:1118 |
| 43 | explicitProfilesKeepSyntheticCredentialsAndSupportDisjoint() | WorkspaceHostTests.swift:653:6 | Caught error: .unauthorizedClient | 1121 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:1121 |
| 44 | hookAndProfileStayOrthogonalAtLaunch() | WorkspaceHostTests.swift:735:6 | Caught error: .unauthorizedClient | 1124 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:1124 |
| 45 | unknownOperationReceivesAnInvalidRequestEcho() | WorkspaceHostTests.swift:813:25 | Issue recorded | 1129 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:1129 |
| 46 | legacyEnsureReusesARunningTerminalAndLaunchesWhenEmpty() | WorkspaceHostTests.swift:833:6 | Caught error: .unauthorizedClient | 1133 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:1133 |
| 47 | ensureTerminalRuntimeIsExecutableAgnosticByContract() | WorkspaceHostTests.swift:861:6 | Caught error: .unauthorizedClient | 1136 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:1136 |
| 48 | ensureTerminalRuntimeNeverRelabelsTheExistingPrincipal() | WorkspaceHostTests.swift:886:6 | Caught error: .unauthorizedClient | 1139 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:1139 |
| 49 | malformedHookTagIsRefusedClientSideBeforeSpawn() | WorkspaceHostTests.swift:920:6 | Caught error: .unauthorizedClient | 1142 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:1142 |
| 50 | stagingOnlyTagStagesFilteredCredentialsWithoutHookRecord() | WorkspaceHostTests.swift:936:6 | Caught error: .unauthorizedClient | 1145 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:1145 |
| 51 | malformedHookTagIsRefusedBeforeSpawn() | WorkspaceHostTests.swift:1026:9 | Expectation failed: WorkspaceControlSocket.writeFrame(fd: raw, body: launchBody) | 1148 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:1148 |
| 52 | malformedHookTagIsRefusedBeforeSpawn() | WorkspaceHostTests.swift:999:6 | Caught error: .disconnected | 1156 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:1156 |
| 53 | controlLaunchBounds_fitDeveloperCommands() | WorkspaceHostTests.swift:1038:6 | Caught error: .unauthorizedClient | 1159 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:1159 |
| 54 | hostBinaryRunsTheProductionAdmission() | WorkspaceHostTests.swift:1079:6 | Caught error: .unauthorizedClient | 1162 | docs/security/phase2a1/verification/RVIsolationTests-unsandboxed.log:1162 |

### RVServiceTests

Current log: `verification/RVServiceTests-unsandboxed.log`.

| # | Test / parameter | Source | Normalized signature | Current log line | Exact final Phase 2A.1 match |
|---|---|---|---|---:|---|
| 1 | directConfigEditIsPickedUpByWarmRuntimeEvaluate() | EnabledCompileTests.swift:120:25 | Issue recorded | 350 | docs/security/phase2a1/verification/RVServiceTests-unsandboxed.log:455 |
| 2 | setPackEnabledGrowsAndShrinksCompiledPackIDs() | EnabledCompileTests.swift:167:25 | Issue recorded | 355 | docs/security/phase2a1/verification/RVServiceTests-unsandboxed.log:478 |
| 3 | implicitHelloOnEvaluate_oneShotDeniesResetHard() | OneShotEvaluateTests.swift:19:25 | Issue recorded | 357 | docs/security/phase2a1/verification/RVServiceTests-unsandboxed.log:534 |
| 4 | majorSemverEvaluateAfterSuccessfulHello_doesNotEvaluate() | OneShotEvaluateTests.swift:155:25 | Issue recorded | 359 | docs/security/phase2a1/verification/RVServiceTests-unsandboxed.log:526 |
| 5 | dispatchEvaluate_grantHonorsOnceForCwd() | ServiceRuntimeEvaluateTests.swift:154:25 | Issue recorded | 361 | docs/security/phase2a1/verification/RVServiceTests-unsandboxed.log:528 |
| 6 | matchingClientSemverAfterSuccessfulHello_stillEvaluates() | OneShotEvaluateTests.swift:220:25 | Issue recorded | 363 | docs/security/phase2a1/verification/RVServiceTests-unsandboxed.log:546 |
| 7 | oldHelloThenEvaluateWithoutClientSemver_stillWorks() | OneShotEvaluateTests.swift:249:25 | Issue recorded | 365 | docs/security/phase2a1/verification/RVServiceTests-unsandboxed.log:542 |
| 8 | dispatchEvaluate_disabledCatalogPackStillDeniesResetHard() | ServiceRuntimeEvaluateTests.swift:117:25 | Issue recorded | 367 | docs/security/phase2a1/verification/RVServiceTests-unsandboxed.log:532 |
| 9 | dispatchEvaluate_emptyEnabledPacksDoesNotRefillDayOne() | ServiceRuntimeEvaluateTests.swift:100:25 | Issue recorded | 371 | docs/security/phase2a1/verification/RVServiceTests-unsandboxed.log:530 |
| 10 | PendingHostAsk_spendDenyStillCancelsMatchingAwaiting() | PendingHostAskTests.swift:75:9 | Expectation failed: try await env.store.list(now: now).count == 1 | 377 | docs/security/phase2a1/verification/RVServiceTests-unsandboxed.log:480 |
| 11 | PendingHostAsk_spendDenyStillCancelsMatchingAwaiting() | PendingHostAskTests.swift:82:25 | Issue recorded | 379 | docs/security/phase2a1/verification/RVServiceTests-unsandboxed.log:482 |
| 12 | PendingHostAsk_missingSessionEncodesAskWithEmptyList() | PendingHostAskTests.swift:164:25 | Issue recorded | 381 | docs/security/phase2a1/verification/RVServiceTests-unsandboxed.log:461 |
| 13 | PendingHostAsk_missingSessionEncodesAskWithEmptyList() | PendingHostAskTests.swift:94:6 | Caught error: PendingHostAskExpectation() | 383 | docs/security/phase2a1/verification/RVServiceTests-unsandboxed.log:470 |
| 14 | implicitHello_grokResetHardReturnsCanonicalDenyWire() | HookEvaluateTests.swift:30:25 | Issue recorded | 384 | docs/security/phase2a1/verification/RVServiceTests-unsandboxed.log:505 |
| 15 | watchAcksUnchangedThenReturnsItemsAfterResolve() | PendingDispatchTests.swift:841:25 | Issue recorded | 386 | docs/security/phase2a1/verification/RVServiceTests-unsandboxed.log:362 |
| 16 | watchAcksUnchangedThenReturnsItemsAfterResolve() | PendingDispatchTests.swift:111:6 | Caught error: DispatchExpectation() | 388 | docs/security/phase2a1/verification/RVServiceTests-unsandboxed.log:385 |
| 17 | stdinOverlay_winsOverJSONAllowStdin() | HookEvaluateTests.swift:206:25 | Issue recorded | 389 | docs/security/phase2a1/verification/RVServiceTests-unsandboxed.log:493 |
| 18 | PendingHostAsk_askWithSessionWritesAwaitingRowThatSurvivesNewStore() | PendingHostAskTests.swift:164:25 | Issue recorded | 391 | docs/security/phase2a1/verification/RVServiceTests-unsandboxed.log:471 |
| 19 | stdinOverlay_replacesJSONStdinOnImplicitHello() | HookEvaluateTests.swift:157:25 | Issue recorded | 393 | docs/security/phase2a1/verification/RVServiceTests-unsandboxed.log:489 |
| 20 | PendingHostAsk_askWithSessionWritesAwaitingRowThatSurvivesNewStore() | PendingHostAskTests.swift:12:6 | Caught error: PendingHostAskExpectation() | 395 | docs/security/phase2a1/verification/RVServiceTests-unsandboxed.log:473 |
| 21 | PendingHostAsk_secondAskSameIdentityKeepsOneAwaiting() | PendingHostAskTests.swift:131:9 | Expectation failed: listed.count == 1 | 398 | docs/security/phase2a1/verification/RVServiceTests-unsandboxed.log:463 |
| 22 | PendingHostAsk_secondAskSameIdentityKeepsOneAwaiting() | PendingHostAskTests.swift:132:9 | Expectation failed: listed.first?.state == .awaitingHuman | 401 | docs/security/phase2a1/verification/RVServiceTests-unsandboxed.log:466 |
| 23 | setPackEnabledRefreshesAnalyticsPackSnapshot() | ServiceRuntimeAnalyticsTests.swift:67:25 | Issue recorded | 405 | docs/security/phase2a1/verification/RVServiceTests-unsandboxed.log:509 |
| 24 | hookEvaluateRecordsDecisionAnalyticsWithoutCommandText() | ServiceRuntimeAnalyticsTests.swift:123:25 | Issue recorded | 407 | docs/security/phase2a1/verification/RVServiceTests-unsandboxed.log:503 |
| 25 | pendingDispatchDoesNotLogCommandText() | PendingDispatchTests.swift:841:25 | Issue recorded | 409 | docs/security/phase2a1/verification/RVServiceTests-unsandboxed.log:358 |
| 26 | pendingDispatchDoesNotLogCommandText() | PendingDispatchTests.swift:262:6 | Caught error: DispatchExpectation() | 411 | docs/security/phase2a1/verification/RVServiceTests-unsandboxed.log:386 |
| 27 | implicitHello_claudeResetHardReturnsAskWire() | HookEvaluateTests.swift:52:25 | Issue recorded | 412 | docs/security/phase2a1/verification/RVServiceTests-unsandboxed.log:484 |
| 28 | PendingHostAsk_spendAllowEmptiesMatchingAwaiting() | PendingHostAskTests.swift:54:9 | Expectation failed: try await env.store.list(now: now).count == 1 | 414 | docs/security/phase2a1/verification/RVServiceTests-unsandboxed.log:497 |
| 29 | PendingHostAsk_spendAllowEmptiesMatchingAwaiting() | PendingHostAskTests.swift:60:25 | Issue recorded | 416 | docs/security/phase2a1/verification/RVServiceTests-unsandboxed.log:499 |
| 30 | oldEvaluate_stillWorksAfterHookEvaluate() | HookEvaluateTests.swift:334:25 | Issue recorded | 419 | docs/security/phase2a1/verification/RVServiceTests-unsandboxed.log:522 |
| 31 | missingFolderUsesPlaceholder() | PendingDispatchTests.swift:841:25 | Issue recorded | 421 | docs/security/phase2a1/verification/RVServiceTests-unsandboxed.log:356 |
| 32 | missingFolderUsesPlaceholder() | PendingDispatchTests.swift:183:6 | Caught error: DispatchExpectation() | 423 | docs/security/phase2a1/verification/RVServiceTests-unsandboxed.log:387 |
| 33 | evaluateSnapshotsEnabledPackIDsBeforeAsyncWork() | ServiceRuntimeAnalyticsTests.swift:27:25 | Issue recorded | 424 | docs/security/phase2a1/verification/RVServiceTests-unsandboxed.log:501 |
| 34 | allowOnceOnPiLeavesOpenCodeAwaiting() | PendingDispatchTests.swift:841:25 | Issue recorded | 426 | docs/security/phase2a1/verification/RVServiceTests-unsandboxed.log:408 |
| 35 | allowOnceOnPiLeavesOpenCodeAwaiting() | PendingDispatchTests.swift:45:6 | Caught error: DispatchExpectation() | 429 | docs/security/phase2a1/verification/RVServiceTests-unsandboxed.log:410 |
| 36 | automaticStoreListsCreatedWaits() | PendingDispatchTests.swift:841:25 | Issue recorded | 435 | docs/security/phase2a1/verification/RVServiceTests-unsandboxed.log:364 |
| 37 | automaticStoreListsCreatedWaits() | PendingDispatchTests.swift:777:6 | Caught error: DispatchExpectation() | 437 | docs/security/phase2a1/verification/RVServiceTests-unsandboxed.log:391 |
| 38 | fileToolAlwaysAllowFailsClosedWithoutMatchingView() | PendingDispatchTests.swift:520:25 | Issue recorded | 438 | docs/security/phase2a1/verification/RVServiceTests-unsandboxed.log:352 |
| 39 | missingStdinOverlay_keepsJSONStdin() | HookEvaluateTests.swift:253:25 | Issue recorded | 441 | docs/security/phase2a1/verification/RVServiceTests-unsandboxed.log:524 |
| 40 | grokStashDrop_emptyStdout() | HookEvaluateTests.swift:272:25 | Issue recorded | 443 | docs/security/phase2a1/verification/RVServiceTests-unsandboxed.log:507 |
| 41 | hookEvaluateSpendDeny_recordsHookHost() | DenialLedgerRecordTests.swift:174:9 | Expectation failed: rows.count == 1 | 445 | docs/security/phase2a1/verification/RVServiceTests-unsandboxed.log:973 |

## Independently verified SHA-256 hashes

```json
{
  "Scripts/phase2a-development-trust.sh": "32596dd756880ac11f07e2e1c475355b7883942f94c60ad4598da1f185f53972",
  "Sources/RVCLI/Commands/WorkspaceCommand.swift": "903886a2ab5d0380ee724ee191193ef59a18d73d7ef83cc4f81590914b72b4bf",
  "Sources/RVCLI/Help/HelpCatalog.swift": "f20440e39fc0b47e7b28f62dd9a7a516723a4e40f716bef726297ae66eb45050",
  "Sources/RVDomain/AgentPrincipalReference.swift": "14f9d9420b5c435863601738e90191f8571f0a99914394040020ed2be9618ed1",
  "Sources/RVIsolation/IsolationApply.swift": "d2520d798a2ee4a8075c9afffd569872f43bdedf62e7d35053e953c82f10cbb6",
  "Sources/RVIsolation/SessionSupervisor.swift": "98837ea9298c60b0213ac1576141f5de389527016c490585ed5b6a2c44674d02",
  "Sources/RVIsolation/WorkspaceControlProtocol.swift": "b920b48008a1c83ad1500e401bb7965397dae0a770a7a0e68ae169bf831ad0d1",
  "Sources/RVIsolation/WorkspaceHostClient.swift": "89ca64e24510bc71abed987d7ea10a162c60cdc75e97a8bed09fb4230227bea5",
  "Sources/RVIsolation/WorkspaceHostProcess.swift": "9fc17c17445a81a9bdb91c688d1f903158436b4e78a4676613845e7ec4f835d2",
  "Sources/RVIsolation/WorkspaceHostServer.swift": "d32e449ff6aba29b20abd20d840a96061ff48625954c3cab02fa4bfdff9fae36",
  "Sources/RVIsolation/WorkspaceOperationAuthorization.swift": "05891c62fb749c982f98cf3eb0c4af82c84ba719f3bd03334eaabb867d8205e4",
  "Sources/RVIsolation/WorkspacePrincipalAuthority.swift": "4895d475f3fe596f8b4f893f99b15081c0e2696f83975545d5dec23494ffb395",
  "Sources/RVIsolation/WorkspaceSessionSupervisor.swift": "686cd13ad65c5d0615d93c2c7de917afe040627664db988caa1ef9f3ec90bbeb",
  "Sources/RVPolicy/AgentLaunchSelection.swift": "71c7775d38d92e98c844162e331cb605fa15646099b4dbbecfdb81c9cbb7a42a",
  "Sources/RVService/AuthenticatedRequestContext.swift": "b8d7ab2d238a78a1b03969a9327d7581b4f410d83078b862e9ce06ef819b75c1",
  "Sources/RVService/GatedEvaluate.swift": "984f8103382d2a1de5d59b580c0f6cea506dde9e6dd0525804ac532290083b6e",
  "Sources/RVService/LiveWorkspaceHostRegistry.swift": "a40ffb36d278492a562e181c71420de3b2348e7ac5a121ea90d8754275eac4ed",
  "Sources/RVService/ServiceLog.swift": "d45ad179c1cbda956afc2213ace202ff89cfcb9b8c8af8fe9f711076c06952b3",
  "Sources/RVService/ServiceRuntime.swift": "c676a83a41f7308c2aebee1bcb4db286abf98091e174bcebe7d82d346671de4f",
  "Sources/RVService/WorkspaceHostBridgeClient.swift": "a44e387bcb897eb1ca6fd7cdaea22c76ed6f092e308cde2000df73e3dade7220",
  "Sources/RVService/XPCListener.swift": "e027b8856b4a226f010644ce4e5c77cb60e848ed8ce25ac57aeadb41f18df8d0",
  "Sources/RVService/XPCWorkspaceHostBridge.swift": "6cce3d2a7b731af24493ac1a55c1f4fec65654b5a02be25bc38a3d97c83d4de0",
  "Sources/rv-workspace-host/HostAdmission.swift": "92d317f668fe38c46243bb73cd796857612de9587d87d1a62c51786436f6afc8",
  "Sources/rv-workspace-host/main.swift": "23d042d1a0a88cdeaf256af76c886017991dd3b735bbe4bd40fcf7dc06f2eb78",
  "Tests/RVDomainTests/AgentPrincipalReferenceTests.swift": "40a9c1b71822c82a4245b0788c3885245dfcb4fc789300f699aedbe72ff84f41",
  "Tests/RVIsolationTests/IdentityAmbientCredentialTests.swift": "bc84d19c7ad1675ca074a8becdf455be168f0f967529f2d080d3183ccb705e86",
  "Tests/RVIsolationTests/ProductionIdentityLaunchTests.swift": "e5212fe7571ac27201ee4ec3eaf01051560743ae5f677d6365e2fb53733f854e",
  "Tests/RVIsolationTests/WorkspacePrincipalAuthorityTests.swift": "bc3800cec3ce66101d0f85e49206b8ba42bbfa5547adb1f3284eb3e8d11871db",
  "Tests/RVPolicyTests/AgentLaunchSelectionTests.swift": "3edd34c2557601ad0c3e51a3c84af7c5c150ce40633bff171e007f55fa27f0ed",
  "Tests/RVServiceTests/LiveWorkspaceHostRegistryTests.swift": "dbe2bec7f8b9d571933cd5f178905c72c0d15498e376bd9aedd6640d0cd18053",
  "Package.swift": "d89565db4d475ddb802a0e311638754e79e95a41dd8a9c7b411c45a8741ad67e"
}
```

## Historical attribution

As established in `../phase2a1/failure-classification.md`, these failures are inherited from the existing Phase 2 draft. Concrete Phase 1→Phase 2 source diffs introduced legacy approval refusal, generic service authority gates, and protected workspace-role admission. This report does not relabel them pre-existing before Phase 2, waive their failures, or claim a completed service suite.
