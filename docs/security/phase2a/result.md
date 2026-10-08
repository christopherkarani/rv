# Phase 2A — Authenticated Host/Principal Bridge

## Baseline

Requested Phase 1 baseline: `phase-1Identity`, `a85151b68ec15809679c40afc0ec26ef322468b3`.
Actual starting/current branch: `phase-2Identity`; HEAD `2df5484972fa2ad1afe9394941e023e7ad01bef0`,
`WIP: checkpoint blocked Phase 2 authentication draft`. Contrary to the supplied description,
the previous draft was already committed. Starting dirty state: only untracked `Vendor/`.
This pass leaves a reviewable, uncommitted candidate on that checkpoint. No merge, Phase 3,
approval resolver work, or trust installation occurred. Phase 1 registry/supervisor lifecycle
implementations are unchanged relative to the checkpoint.

Recoverability: existing checkpoint retains draft sources, tests and platform artifacts;
`/private/tmp/rv-phase2-draft-2df54849.bundle` contains the full branch history and passed
`git bundle verify`. `starting-status.txt` records porcelain status after creating this report directory; the first pre-edit status check reported only Vendor/.

## Existing draft reuse

**SAFE TO REUSE as implementation primitives, not certification:** protected trust loader,
ACL/ancestor checks, hardened-runtime/injection-entitlement restrictions, dynamic live-hash
verification, per-message `SecCodeCreateWithXPCMessage`, anonymous action endpoint discovery,
and captured immutable peer evidence. The new bridge uses these existing draft primitives.
Their installed-role success remains unproven.

**NEEDS REDESIGN:** treating owner token/PID/socket identity as host authentication; absence
of cross-process principal validity; generic `AuthenticatedRequestContext.agent` construction;
principal-free evaluation and grant mutation sequencing. Existing draft approval-ledger/owner
flows also fail broad tests and remain unapproved, unchanged research code in this checkout.

**DEFER:** owner/human resolver, LocalAuthentication, pending approval completion, rule-save
authority, C client successful mutation, HookHost/tag credential migration, terminal rewrite,
EgressProxy identity, measured launch and Secrets. Nothing here closes those gates.

## Runtime topology

See [topology.md](topology.md) for exact process ownership and source symbols.
The dedicated host owns supervisor, registry, channel binding, capability and Unix control
socket. `rvd` owns policy service and XPC listeners. CLI discovers/launches a host; rvd now
learns hosts only through authenticated live registration. Journals/endpoint records persist
correlation and history, never registrations or active principal state.

## Host authentication design

The anonymous action connection requires successful Hello. Every host registration/evaluation
message is synchronously authenticated before crossing the Task boundary using the message's
live Security code object and installed `.workspaceHost` role. Reverse validity replies must
match the exact original authenticated peer/connection. The host authenticates service Hello,
registration/evaluation replies and every incoming validity request as `.service` before use.
Same UID, labels, paths, owner tokens or payload IDs never assign component roles.

Observed platform: macOS 27.0, arm64, Apple Swift 6.4. These are local source/build observations;
no installed trusted-role journey or macOS 15 runtime certification is claimed.

## Host registration

Registration is bound to one action connection, one workspace, one host and one freshly minted
UUID generation. Live duplicate workspace/host registrations refuse; first accepted registration
wins. Retired generations/connections cannot replay within the daemon incarnation. State lives
only in memory. Socket/XPC errors synchronously close a liveness latch before queued actor
removal; in-flight RPCs recheck that latch and the registration epoch after await. A daemon restart
starts empty. Automatic reconnect of an old incarnation after disconnect is intentionally absent;
a fresh host start is required by this candidate's conservative availability semantics.

Workspace ownership is derived from the trusted host facade constructed after the supervisor
owns the workspace lock. rvd does not independently reconstruct flock ownership from disk.
This relies on authentication of the protected host implementation and remains subject to
installed process/impersonation proof.

## AgentPrincipalReference

Five mandatory names: AgentInstanceID, RuntimeSessionID, WorkspaceSessionID, WorkspaceHostID,
WorkspaceHostGeneration. Codable encodes UUIDs explicitly without changing existing identity
types. Missing generation fails decoding. Fabrication grants nothing. The facade issues a
reference only for an active instance in its own registry. Generation is never restored as live
state from journals or endpoint records.

## Principal validity RPC

`rv.host-validity` carries a reference. Host `WorkspacePrincipalAuthority.resolve` checks all
five identities and the registry's active snapshot. A successful response is only
`AgentPrincipalValidity(reference, active)`; inactive/unknown/mismatched requests produce no
positive response. No RuntimeCapability, raw admission capability or Secrets crosses the bridge.
Reverse RPC timeout is five seconds; client exchange timeout is ten seconds. Failure refuses
the operation. Validation responses are point-in-time descriptions, not leases.

## End-to-end legitimate path

Candidate code: authenticated runtime admission subject → active host-issued reference →
persistent host XPC relay → rvd peer/registration/live validity → private-construction
ServiceValidatedAgentContext → ServiceRuntime.evaluateAgent → canonical semantic/hard-policy
engine → second live validity → host's final local lookup → normal runtime admission.
Only instance-bound shell evaluation uses this path. Generic external `.evaluate`/`.hookEvaluate`
authority and owner mutations remain closed.

**NOT PROVEN:** production workspace control launches currently omit trusted `agentDefinition`;
they mint no AgentInstance and therefore cannot reach this branch. Existing legacy launches
retain their existing local admission path. No installed authorized operation succeeded in this
pass. This is a release blocker, not a successful cross-process product claim.

## Revocation path

In-process tests prove active lookup succeeds and the same reference fails after Phase 1
registry revoke. Service logic tests prove each use revalidates and an inactive response refuses.
No installed operation→revoke→retry journey has run. There is no claim of an atomic distributed
lease through a later host execution; post-response race semantics still require product oracles.

## Host restart path

Fresh registry/facade generation rejects old references despite journal history. Service logic
rejects old generations, connection replay, and an old response after disconnect/replacement.
No real process restart following a successful installed operation has run.

## Impersonation tests

Logic rejects wrong role, wrong peer/connection, forged/mismatched five-field responses, unknown
host, inactive instance, and RPC errors. Synthetic peer evidence is explicitly marked logic-only.
The inherited separate-process Unix peer tests do not certify this new XPC bridge. Required
same-user fake host with copied identifiers/token, wrong-role component and forged generation
against an installed legitimate role configuration remains unexecuted.

## Cross-process product proof

**BLOCKED.** No protected manifest exists. The explicit privilege probe `sudo -n true`, run
outside the sandbox, returned `sudo: a password is required`. No unsafe user-writable trust
fallback was introduced. See [provisioning.md](provisioning.md) and the administrator-run
`Scripts/phase2a-development-trust.sh`: exact installed hardened binaries/CDHashes, protected
paths, no wildcard, refusal of existing configuration, receipt-checked cleanup.
Script syntax/help/JSON formatting were tested; installation and cleanup were not executed.

A genuine rvd + workspace-host + authorized runtime journey and separate hostile forwarding
process are still required. CLOEXEC_DEFAULT/containment and per-message code checks are source
evidence; they do not substitute for deliberate descriptor/send-right forwarding attacks.

## Files changed

See [files-changed.txt](files-changed.txt) for exact candidate source/test/script/document paths.
Verification logs are under `verification/`. Pre-existing `Vendor/` is untouched.

## Tests

Focused command (with isolated writable compiler caches):

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/rv-phase2a-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/rv-phase2a-clang-cache \
Scripts/swift-6.4 test --disable-sandbox \
  --filter 'AgentPrincipalReference|WorkspacePrincipalAuthority|LiveWorkspaceHost'
```

22 tests passed: service registry/operation 14, host authority 5, reference 3.
These are in-process logic/registry tests. `bridge.log` contains all target summaries.
`bash -n Scripts/phase2a-development-trust.sh` and `git diff --check` passed.

## Broad regression gates

Exact commands, exit codes and complete target summaries are in
[verification/summary-unsandboxed.json](verification/summary-unsandboxed.json).
The required preflight and five module suites were run; sandboxed attempts are retained separately.
A bounded unsandboxed rerun distinguishes socket/volume restrictions from code failures.
No relevant full-module failures are waived or called green. Broad gate result is **NOT GREEN**.

| Gate | Executed result |
|---|---|
| Scripts/preflight.sh | PASS — 0 failures, 2 warnings |
| RVDomainTests | FAIL — 478 tests, 8 issues |
| RVPolicyTests | FAIL — 317 tests, 4 issues |
| RVIsolationTests | FAIL — 449 tests, 54 issues, 328.903 seconds |
| RVIPCTests | PASS — 95 tests |
| RVServiceTests | FAIL — signal 5, index-out-of-range crash; no complete count |

Domain/policy approval failures match the prior checkpoint's saved module results (8 and
4 issues respectively); their approval sources are unchanged by this pass. Service output
records `DenialLedgerRecordTests.swift:174`, zero expected rows, then an index-out-of-range
crash; the prior checkpoint also recorded this expectation/signal failure. Isolation remains
non-green, including the draft's refusal-boundary incompatibilities with legitimate-control
fixtures; not all 54 issues have been independently classified. The successful inherited
separate-process Unix authentication tests are visible in the unsandboxed isolation log;
they still do not prove successful new XPC component-role registration. No cause is assumed
for every broad failure simply because narrower tests pass.

## Fresh-review findings

Fresh reviewer received only spec, diff, topology and tests. Independently reproduced:

1. **Production launch gap — OPEN:** launch call omits agentDefinition; the supervisor default
   is nil; new bridge guard cannot be reached by installed control launches.
2. **Discarded service context — FIXED:** evaluation now accepts the trusted service-local
   context and records its exact reference in ServiceLogEvent. A test asserts attribution.
3. **Owner grant mutation before final validation — FIXED:** red regression showed agent
   evaluation allowed a grant-backed denied command and permanently changed the row to
   consumed. Candidate now calls canonical semantic/hard-policy evaluation without owner
   grant lookup/consumption. Green regression asserts deny plus the grant remains granted.
   It does not use peek-grant results as repeatable execution permits. Saved red log:
   `verification/grant-race-red.log`; final green evidence: `verification/bridge.log`.

Reviewer approved the narrow grant fix after reviewing it. Missing installed/cross-process
and forwarding evidence are explicit acceptance gaps, not reported as reproduced exploits.

## Remaining Phase 2 blockers

- Trusted production Agent Definition selection/launch integration and genuine instance-bound
  operation success.
- Administrator provisioning execution and authenticated installed process evidence.
- Separate-process impersonation, deliberate channel forwarding, revoke/restart and race oracles.
- All required full modules green; inherited blocked-draft approval behavior remains unresolved.
- Distributed validation/execution race semantics proven with actual transports.
- All explicitly deferred Phase 2 work listed above.

## Final status

PHASE 2A BLOCKED
