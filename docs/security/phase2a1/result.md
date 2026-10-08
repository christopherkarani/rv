# Phase 2A.1 — Production Identity Launch Integration

## Baseline

Starting branch: `phase-2Identity`. HEAD: `2df5484972fa2ad1afe9394941e023e7ad01bef0`. No reset, commit, branch replacement or Phase 2B work. Existing Phase 2A candidate and unrelated untracked `Vendor/` preserved. Exact starting porcelain and prior focused bridge results are in [baseline.json](baseline.json). Prior focused baseline: 22 passing tests (14 service, 5 host, 3 domain).

Recoverable pre-edit snapshot: `/private/tmp/rv-phase2a-before-launch-20260930T193132Z.tar.gz`. Previous committed draft recovery bundle: `/private/tmp/rv-phase2-draft-2df54849.bundle`. Snapshot excludes unrelated Vendor and includes dirty candidate. Uncommitted starting files are enumerated verbatim in baseline.json.

## Launch topology

[launch-topology.md](launch-topology.md) traces exact callers and authority boundaries before/after. Previously HostServer.launch called supervisor.launch without agentDefinition, giving nil. New CLI agent/custom -> host client explicit wire operations -> host dispatch -> immutable selection -> supervisor.launchAgent -> existing announce/bind-before-resume/establish/activate machinery. Legacy uses supervisor.launchLegacy explicitly.

**Reachability remains BLOCKED:** existing WorkspaceOperationAuthorization refuses both identity operations before selection for every peer. Protected component trust would not fix this operator-authority dependency. Enabling scoped launch permits would require out-of-scope authorization work.

## AgentDefinition selection

RVPolicy owns pure selection. WorkspaceHostProcess loads existing Phase 1 AgentDefinitionStore alongside resource policy using kernel account home (not caller HOME) before opening workspace. The host retains an immutable definition/revision set. Unsafe/invalid store refuses startup; missing store is empty. Named launch requests contain an exact definition ID and argv, no executable override, HookHost/tag or profile override. Exact canonical original-project membership is required. The executable comes from exactly one existing operator executableLinks entry whose name equals that definition ID; this reuses the existing resource configuration, not a second identity store.

Unknown IDs, wrong projects, malformed/ambiguous executable links fail closed. Definitions with content/signing requirements or credentials are refused because those integrations are deferred. Only explicitly unsigned weak requirements are accepted. The revision includes the profile and executable link, retained with the selected definition by value through launch.

Custom launch requires an absolute executable and lowercase SHA-256 expected intent, uses existing AdHocAgentSnapshot, no named profile, credential bindings, integration metadata or authority ceiling. This digest is never claimed as observed content evidence. Basename matching does not select a named definition. Legacy custom execution remains explicitly unidentified.

## Identity-aware vs legacy launch

`rv workspace agent <definition-id> -- <arguments>` calls launchAgentRuntime. `rv workspace custom --expected-content-digest-sha256 <digest> -- /absolute/executable <arguments>` calls launchCustomRuntime. Both require identityAgentLaunchV1 capability; no fallback/downgrade to legacy. supervisor.launchAgent requires ResolvedAgentLaunch. Existing internal Phase 1 fixture API remains available, but production dispatch uses explicit adapters.

Existing run/OpenCode/TUI semantics remain legacy: no AgentInstance is minted by HookHost, tag or basename. Authorization refusals inherited from the existing Phase 2 draft remain in place. Identity launches additionally suppress ambient legacy AgentBin grants and PTY home credential staging; legacy behavior is preserved.

## Real AgentInstance creation

ProductionIdentityLaunchTests uses the real operator store and required selection, real WorkspaceSessionSupervisor.open/launchAgent, and a contained child. It never manually constructs/announces/activates an instance. It verifies active instance owner, immutable revision, workspace/runtime IDs, launchObserved assurance and absent observed digest/workload-image evidence. The real fd4/fd5 child admission request resolves that exact active instance through RuntimeChannelBinding into RuntimeAdmissionSubject.agent. A deliberate normalization failure prevents action execution in this fixture; it is a binding oracle, not the requested service operation.

## Cross-process successful operation

**NOT PROVEN / BLOCKED.** No valid live agent evaluation succeeded through installed `rvd`. Therefore no authenticated role/PID/principal-ID tuple for the required rvd + workspace-host + runtime topology exists to report. Protected `/Library/Application Support/RV/peer-trust.json` is absent; no administrator installation or writable fallback was used. Independently, the scoped operator gate refuses launch before trusted selection. No named operator configuration was installed by this pass. [product-oracle.json](verification/product-oracle.json) records the readiness result and explicitly distinguishes the real-child fixture from installed authenticated XPC success.

## Revocation oracle

Real launched-child cancellation makes the host facade reject its former reference. Existing focused service registry tests prove live revalidation/revocation logic with synthetic registered host callbacks. **Successful service evaluation before revoke followed by service-side rejection of that same real installed reference remains NOT PROVEN.** No capability-only denial is presented as proof of service revocation.

## Host-generation oracle

The real launched-child fixture creates a fresh authority facade generation and rejects the old reference. Existing registry tests verify old-generation/replay rejection with modeled transports. **Actual host termination/restart after successful installed service evaluation remains NOT PROVEN.** No persisted history restores active authority.

## Forgery tests

Existing focused host/service tests independently change all five structurally valid reference fields: AgentInstanceID, RuntimeSessionID, WorkspaceSessionID, WorkspaceHostID, WorkspaceHostGeneration. Each mismatch fails semantic lookup, not merely decoding. These are logic fixtures; same-user forged references across an installed authenticated transport remain NOT PROVEN. Selection tests prove unknown/basename/HookHost do not select another definition; ad-hoc carries none authority and nil integration/profile. A real legacy .claude child has no instance and no issued principal reference.

## Files changed

Incremental source/test changes relative to the preserved Phase 2A starting candidate (not just HEAD):

- `Sources/RVCLI/Commands/WorkspaceCommand.swift`
- `Sources/RVCLI/Help/HelpCatalog.swift`
- `Sources/RVIsolation/IsolationApply.swift`
- `Sources/RVIsolation/SessionSupervisor.swift`
- `Sources/RVIsolation/WorkspaceControlProtocol.swift`
- `Sources/RVIsolation/WorkspaceHostClient.swift`
- `Sources/RVIsolation/WorkspaceHostProcess.swift`
- `Sources/RVIsolation/WorkspaceHostServer.swift`
- `Sources/RVIsolation/WorkspaceOperationAuthorization.swift`
- `Sources/RVIsolation/WorkspaceSessionSupervisor.swift`
- `Sources/RVPolicy/AgentLaunchSelection.swift`
- `Tests/RVIsolationTests/IdentityAmbientCredentialTests.swift`
- `Tests/RVIsolationTests/ProductionIdentityLaunchTests.swift`
- `Tests/RVPolicyTests/AgentLaunchSelectionTests.swift`

[incremental-files.json](incremental-files.json) records before/after SHA-256. The separate original Phase 2A bridge files remain dirty and preserved; baseline.json distinguishes them. Added documentation is contained in docs/security/phase2a1; verification logs are retained there. No Vendor edits.

## Tests

Commands use pinned Scripts/swift-6.4, CLANG_MODULE_CACHE_PATH and SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/rv-phase2a-clang-cache, plus --disable-sandbox. Real-volume/IPC checks ran outside the filesystem sandbox after automatic approval. Exact argument arrays, exit codes, timeouts and summaries: [verification/summary-unsandboxed.json](verification/summary-unsandboxed.json). Runs are serialized; each command has a 420-second process-group timeout.

Final focused verification: **35 passing tests**: 8 selection, 3 real launch, 22 existing bridge, and 2 isolated ambient credential probes. Explicit commands: `Scripts/swift-6.4 test --disable-sandbox --skip-build --filter ProductionIdentityLaunchTests` (run separately: 3 pass, 6.368 seconds, verification/production-launch-explicit.log), combined selector `AgentLaunchSelectionTests|ProductionIdentityLaunchTests|AgentPrincipalReference|WorkspacePrincipalAuthority|LiveWorkspaceHost`, and separate `IdentityAmbientCredentialTests`. The installed product oracle is BLOCKED before a runtime can be admitted, not counted as a passing test. Initial sandbox real-volume failures were reproduced outside sandbox and disappeared. A test path assertion was corrected to canonicalize /tmp vs /private/tmp; this was a new fixture assertion error, not a production defect.

The isolated ambient credential reproduction was RED for a generated unwanted grant, while its real child credential read already remained DENIED. The suppression addresses the generated grant/staging boundary; no exposed real credential is claimed. Final probes run in private copied test-helper processes, so HOME and AgentBin of concurrent parent suites are not mutated. Receipt verification prevents a zero-test subprocess from counting as success.

## Broad gate status

| Gate | Final result | Classification |
|---|---|---|
| `Scripts/preflight.sh` | 0 failures, 2 existing warnings | GREEN |
| `RVDomainTests` | 478 tests, 8 issues | INHERITED FAILURE — existing Phase 2 draft |
| `RVPolicyTests` | 325 tests, 4 issues | INHERITED FAILURE — existing Phase 2 draft |
| `RVIsolationTests` | 454 tests, 54 issues; 344.118 seconds | INHERITED FAILURE — existing Phase 2 draft |
| `RVIPCTests` | 95 tests pass | GREEN |
| `RVServiceTests` | signal 5; DenialLedgerRecordTests:174 expects one row, receives zero, then indexes empty array; incomplete suite | INHERITED FAILURE — existing Phase 2 draft |
| Focused selection / launch / bridge / credential probes | 35 tests pass | GREEN (partial oracle scope) |
| Installed three-process product operation | no authenticated success tuple exists | BLOCKED |

No remaining NEW FAILURE identified by final signature/source comparison. New test counts add 8 policy and 5 isolation tests relative to the original Phase 2A baseline. First run of preflight introduced three check failures; those edits were corrected before final verification. Initial newly introduced preflight force-unwrap/dependency declarations were fixed; final preflight has 0 failures and 2 existing warnings. [failure-classification.md](failure-classification.md) compares every failing signature and distinguishes historical log matches from source-based inherited paths. No approval tests were removed or weakened.

## Fresh-review findings

Fresh reviewer received Phase 1 spec/current diff/call chain/selection/oracle status without implementation rationale. Independently reproduced: operator launch gate rejects new operations; left closed because scoped authorization is out of scope. Reproduced generated ambient credential grant, not readable-secret exposure; identity preparation/spawn now suppress ambient integration, including request copies. Reviewer approved suppression by inspection. Reviewer retracted tentative stronger-assurance issue after verifying enum has only unattested/launchObserved. No out-of-scope approvals, LocalAuthentication, C success, policy mutation, credential migration or measured launch was implemented.

## Remaining Phase 2A blockers

- Scoped authenticated operator launch authorization is required to reach the new dispatch path; this pass cannot solve it within scope.
- Protected installed component-trust provisioning has no runtime proof; existing explicit administrator script was not installed. Earlier sudo -n probe required a password.
- Legitimate installed three-process evaluation, real service revocation, actual host restart, and same-user forgery oracles are unproven.
- Deliberate message-forwarding attack proof remains missing.
- Broad inherited approval/authority fixtures and service crash remain non-green; focused tests do not certify Phase 2A or a release.

## Final verdict

PHASE 2A.1 BLOCKED
