# Phase 2A.2 — Scoped Operator Launch Authorization

## Baseline

Branch `phase-2Identity`; HEAD `2df5484972fa2ad1afe9394941e023e7ad01bef0`. The Phase 2A and 2A.1 dirty candidate is preserved without reset, discard, commit, squash or history rewrite. Unrelated untracked Vendor is untouched. [baseline.json](baseline.json) records exact starting porcelain and source/test/script SHA-256 values.

Pre-modification recoverable snapshot: `/private/tmp/rv-phase2a2-before-authorization-20260930.tar.gz`; existing Phase 2A.1 snapshot remains `/private/tmp/rv-phase2a1-final-candidate-20260930.tar.gz`. The snapshot excludes Vendor and includes the dirty candidate. No implementation source or test changes have been made in this pass.

Starting focused status: 35 passing Phase 2A.1 tests. Starting broad status: preflight 0 failures/2 warnings; Domain478/8 inherited issues; Policy325/4 inherited issues; Isolation454/54 inherited issues; IPC95 passing; Service incomplete with inherited signal5 empty-array crash. Starting results are from phase2a1/verification, not new authorization proof.

## Refusal root cause

Exact current named CLI chain:

1. `WorkspaceAgent.run`, Sources/RVCLI/Commands/WorkspaceCommand.swift:117 -> `WorkspaceCommandRun.runAgent`:317 validates the definition ID -> `runInteractiveSelection`:384.
2. `WorkspaceHosts.ensure`, Sources/RVIsolation/WorkspaceHostProcess.swift:201 requires `WorkspaceClient.connect`:208 and successful `client.describe()`:215 before returning the endpoint.
3. `WorkspaceClient.connect`, Sources/RVIsolation/WorkspaceHostClient.swift:177 authenticates the live host through the fixed protected trust manifest before disclosing the owner token. With the currently absent manifest, it returns unauthorizedClient before Hello.
4. If protected component authentication succeeds, `WorkspaceHostServer.adopt`, Sources/RVIsolation/WorkspaceHostServer.swift:317 captures the Unix connector's UID/PID/audit-token/live-code evidence and requires a recognized component role; `hello`:420 checks the endpoint token and correlates the endpoint. `WorkspaceControlConnection`:41 stores connection UUID, peer evidence and closed/hello state.
5. Even then, `WorkspaceHosts.ensure` cannot obtain `describeWorkspace` from a `.cli`: `WorkspaceOperationAuthorization.permits`, Sources/RVIsolation/WorkspaceOperationAuthorization.swift:10 permits describe/list only to service or workspaceHost. It treats the host as unusable and can time out before emitting launch.
6. If a usable client reaches launch, `WorkspaceClient.launchAgentRuntime`, Sources/RVIsolation/WorkspaceHostClient.swift:335 sends `.launchAgentRuntime` with UUID request ID, definition ID, argv and terminal intent, requiring negotiated identityAgentLaunchV1. Custom launch uses `.launchCustomRuntime`, absolute executable and expected digest intent.
7. `WorkspaceHostServer.respond`:379 decodes/bounds the frame and requires request ID/Hello; `operation`:448 calls `WorkspaceOperationAuthorization.permits`:455 before dispatch. Identity launch operations at WorkspaceOperationAuthorization.swift:12–15 return false for every peer. The reply is unauthorizedClient. `launchIdentity`:723 is not reached; neither definition lookup nor supervisor launch occurs.

The request can reach host dispatch only after the earlier authentication/readiness checks. The current environment does not pass those earlier checks. The launch-dispatch refusal is a separate exhaustive source branch; this report does not claim an observed installed authenticated launch refusal tuple.

## Authorization model

**No new authorization value was issued or implemented.** The available evidence proves a component and correlates its endpoint; it does not establish who authorized this launch.

- Component authentication: kernel transport peer + live code + protected code-role configuration.
- Endpoint correlation: token, socket inode, host/workspace identifiers.
- Operator/control authority: independently delegated permission for the exact requested launch; currently missing.
- Agent Principal: host-minted runtime instance after authorized launch; cannot authorize its own creation.
- Human approval authority: separate authenticated decision, not reused in this pass.

`ProtectedPeerTrustConfiguration.Entry`, WorkspacePeerAuthenticator.swift:51–57, has component role/signing requirements and development pins only. Roles are cli/service/workspaceHost; no workspace/launch delegations are represented. A request ID or immutable definition identifies intent, not permission to invoke it.

The closest existing broker, `ControlAuthorizationBroker`, Sources/RVService/ControlAuthorization.swift:44–109, is approval-row-specific. Its authenticate operation requires PendingApproval/ApprovalSubject, a decision and live principal; its default `LocalOwnerAuthenticator` uses LAContext. No production caller was found. Reusing or adapting that approval resolver would cross the task's explicit scope boundary.

The locked spec anchors Owner in the invoking OS user (rv-agent-identity-spec-v1.md:73–79), trusts operator configuration/control components (:508), and separates human approval authority (:532–534). It does not mandate fresh LocalAuthentication for launches and does not supply an independent launch-control issuer. This inspection does not establish that all possible launch designs require human approval; it establishes that the current implementation has no acceptable issuer for the stricter requested boundary.

A host-created non-wire receipt derived only from recognized CLI + decoded workspace/definition/request would manufacture authority. Any rogue same-user process could invoke the genuine mode755 CLI with arguments; protecting its bytes does not independently authorize that invocation. Nonce/expiry/consume-once bookkeeping would constrain a receipt only after a legitimate issuer exists. No weaker fallback or second identity configuration was added.

## Scope/lifetime

Not implemented because the authority issuer is missing. A legitimate issuer must independently authorize before a non-wire value can bind authenticated connection/peer, workspace and host incarnation, launch operation, immutable selected definition/custom executable+expected digest intent, exact request identity/argv/IO, finite lifetime and consume-once state. Disconnect/restart/expiry/consumption must invalidate it. None of these binding fields alone can create authorization.

There is no persisted authorization, isOperator flag, payload-created principal, role-to-owner upgrade or reusable launch grant added by this pass. Other workspace mutations and terminal operations remain refused. Unix connector authentication explicitly does not authenticate writers of forwarded descriptors (WorkspacePeerAuthenticator.swift:204); a future permit must address that boundary before making a forwarding-resistance claim.

## Legitimate product launch

**BLOCKED.** The existing CLI/control route is retained without bypass. Authorizing only launchAgent/launchCustom would not repair the earlier ensure/describe barrier or establish an independent issuer. No trusted definition selection semantics were changed.

## AgentInstance result

No Phase 2A.2 authorized product runtime was created; there are no new product instance/runtime/workspace IDs to report. Existing Phase 2A.1 tests already prove real supervisor-launched instance binding at launchObserved assurance, and legacy remains non-principal. Those prior tests are not presented as Phase 2A.2 authorized product success.

## Cross-process service success

**BLOCKED, not PASS or skipped-as-PASS.** No authenticated rvd + workspace-host + runtime success tuple exists; therefore authenticated roles, PIDs, WorkspaceHostID, generation, AgentInstanceID, RuntimeSessionID and WorkspaceSessionID are unavailable for the requested oracle.

Live readiness checks: `/Library/Application Support/RV/peer-trust.json` is absent; `sudo -n true` returned exit1, `sudo: a password is required`. Existing explicit Scripts/phase2a-development-trust.sh requires administrator execution and refuses existing installation; no protected files were modified. No user-writable fallback or fake authentication was used. Component provisioning would still not supply operator launch scope. [verification/readiness.json](verification/readiness.json) records the current prerequisites separately from test results.

## Negative authorization tests

This pass reran the six existing real peer-boundary tests via `Scripts/swift-6.4 test --disable-sandbox --skip-build --filter WorkspacePeerAuthenticatorTests`; all six pass. They cover user-owned/ACL trust rejection, non-socket rejection, real connected-socket evidence with no role, live code/default no-role, a separate same-UID executable and dead-peer rejection. They are not scope/launch positive oracles.

| Requested oracle | Evidence/status |
|---|---|
| Same UID rogue process | Existing separate-process peer test passes; installed identity-launch attack is BLOCKED/unproven. |
| Copied owner token alone | Source: role authentication precedes Hello, and launch dispatch still refuses; real copied-token launch attack NOT PROVEN. No token output. |
| Trusted CLI without independent scope | Source: launch refuses every component; no scope issuer. Successful trusted control route NOT PROVEN. |
| Wrong workspace/definition, operation substitution | No authorization exists to substitute; no new scoped authorization tests can establish the requested guarantee. NOT PROVEN. |
| Replay, connection loss, host-generation expiry, consume once | No new permit/issuer exists; these requested lifetime oracles remain NOT PROVEN. |
| Authorized named/custom launch, real service use | BLOCKED. No mock or synthetic context was substituted. |
| Legacy remains legacy | Preserved unchanged Phase 2A.1 source and prior real-child test; not upgraded. |

## Revocation oracle

NOT PROVEN for the required authorized product flow. There was no successful real service operation before revocation; existing pure/real-child Phase 2A.1 coverage is not counted as this oracle.

## Host restart oracle

NOT PROVEN for the required authorized product flow. No successful installed host/service operation was followed by real host restart and old-reference retry.

## Files changed

Only documentation/evidence under `docs/security/phase2a2/`; the exact list is in [changed-files.txt](changed-files.txt), including baseline, plan, request, report, independent review, preservation proof, per-failure classification, final state and verification artifacts. No implementation/test/provisioning scripts changed in this pass. The cumulative existing Phase 2A/2A.1 dirty files are enumerated in baseline.json; they are not relabeled as new changes. All 31 recorded source/test/script/Package hashes match baseline; [source-preservation.json](source-preservation.json) records zero implementation changes.

## Tests

Platform: macOS27.0, arm64; pinned Swift6.4 wrapper. Newly rerun peer boundary: 6 tests pass, 0.011seconds, exit0, already-built binary with --skip-build. Cache environment CLANG_MODULE_CACHE_PATH and SWIFTPM_MODULECACHE_OVERRIDE both `/private/tmp/rv-phase2a-clang-cache`. Real IPC tests run outside filesystem sandbox after automatic approval; no trust checks bypassed.

The requested preflight/five suites ran serially with 420-second per-command process-group limits; none timed out. [verification/summary-unsandboxed.json](verification/summary-unsandboxed.json) records exact argv, exit codes and complete test summaries when available. The script uses `Scripts/preflight.sh` and `Scripts/swift-6.4 test --disable-sandbox --filter <TargetTests>` for all five named targets. Service crashed before a complete count could be reported. The installed product readiness oracle is independently BLOCKED; no passing three-process test is claimed.

## Broad gates

| Gate | Current rerun | Classification |
|---|---|---|
| Preflight | 0 failures, 2 existing warnings | GREEN |
| RVDomainTests | 478 tests; 8 issues | INHERITED |
| RVPolicyTests | 325 tests; 4 issues | INHERITED |
| RVIsolationTests | 454 tests; 54 issues; 340.673seconds | INHERITED |
| RVIPCTests | 95 tests pass | GREEN |
| RVServiceTests | 41 printed issue records, then signal5 at empty denial-ledger rows; incomplete | INHERITED |
| Peer boundary, run separately | 6 tests pass | GREEN, limited boundary scope |
| Mandatory installed product success | Prerequisites unavailable; no authenticated success tuple | BLOCKED, not PASS |

[failure-classification.md](failure-classification.md) matches every current issue to the preceding Phase2A.1 log by test/argument/source-line/column/normalized message. All current8/4/54/41 signatures match. The service's41 printed issues are a subset of its previous90; absent signatures after an early crash are not RESOLVED. No INTRODUCED or RESOLVED source failure is claimed; no source was changed. All31 recorded source/test/script/Package SHA256 values were independently rechecked and match.

## Fresh-review findings

A new code-reviewer independently inspected the locked spec, final unchanged source candidate, live trust readiness and negative peer results. Confirmed source branches: launchAgent/launchCustom refuse before dispatch; actual CLI requires a describe operation that rejects cli earlier; no launch issuer is present. Fixed protected manifest absence was independently checked by the reviewer. Existing approval broker is out of scope. Connector-versus-forwarded-writer distinction remains unproven. These are acceptance blockers, not newly introduced source defects. No code changes were made to work around them. Separate architect inspection reached the same issuer conclusion. Exact reviewed symbols and limitations are in review.md.

## Remaining Phase 2A blockers

- Independent narrow operator/control launch delegation and trustworthy issuer are missing.
- Actual CLI bootstrap/readiness/terminal requirements must be accounted for without broad role-based authority.
- Protected component trust cannot currently be exercised in the execution environment; non-interactive administrator authorization is unavailable.
- Real three-process normal service evaluation, revocation and host restart are unproven.
- Deliberate descriptor/message forwarding proof remains absent.
- Existing broad approval/control fixture failures and service crash remain release blockers.

No Phase2B, general human resolver, LocalAuthentication implementation, policy mutation, credential migration or measured launch was added.

## Final status

PHASE 2A.2 BLOCKED
