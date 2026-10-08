# RV Agent Identity Phase 2 — Result

**PHASE 2 BLOCKED.** This branch contains incomplete, uncommitted security foundations
and temporary refusal boundaries. It is not a releasable Phase 2 implementation.
No implementation PRs were opened or landed. Working agent/control/C-client paths
and the complete security acceptance gates remain unsatisfied. Do not merge or deploy
this draft as Phase 2, or start Phase 3 from it.

## 1. Baseline

Starting branch `phase-1Identity`; HEAD `a85151b68ec15809679c40afc0ec26ef322468b3`.
No tracked modifications; unrelated untracked `Vendor/` preserved. The spec is tracked
and unchanged. Dedicated branch `phase-2Identity` was created after verification.
HEAD remains the hardened baseline; draft changes are in the working tree.

Last eight commits before edits:

```text
a85151b6 Harden AgentInstanceRegistry concurrent teardown
92a21b5b Add RV Agent Identity Specification v1
e1efb8c6 PR3: instance registry, lifecycle, journal + runtime binding
33d7bac0 PR2: trusted agent definition store + canonical revisions (RVPolicy)
e6c077ed PR1: immutable agent principal models (RVDomain)
9c546c99 Merge pull request #359 from christopherkarani/arch/29f18c88/T4
ee427488 Review fixes: typed hook API, test fidelity, M-2/M-4/M-5/M-7, L4/L6/L8-L13, F-1
469881ab Merge fixes: qualify Token, tuple env, typed wire, legacy tolerance
```

Preflight: 22 checks, zero failed, two existing test-dependency warnings.
Phase 1 focused baseline: domain 24, definition store 16, registry/lifecycle/concurrency
27, all passed. Initial sandbox/cache restrictions caused failures; writable temporary
caches plus actual process access produced the passing baseline. N1 was not labeled
in repository docs; the expected concurrent teardown hardening is present and its
five concurrency tests pass. No Phase 2 peer/control implementation was present at
baseline. The separate implementation-plan document was not found by title among
tracked files; the pasted requirements and tracked spec governed this draft.

## 2. PR4 — Peer authentication

Implemented audit-token-based Unix peer evidence and message-derived XPC code
identity using public APIs. Live dynamic code is checked; signing metadata is rebound
to the live CDHash. Same UID, path, basename or ad-hoc signing alone confer no role.

Configured roles are separate from Agent Instances and owner authority. Production
requirements include exact identifier/team plus live Apple-anchor validation;
development pins require protected installed artifacts and exact hashes. Both require
runtime hardening and reject injection/debug entitlements. The fixed root-protected
manifest path is `/Library/Application Support/RV/peer-trust.json`; absent configuration
grants no component roles. Extended ACL allow entries, writable ancestors and symlinks
are rejected; the opened manifest descriptor is validated too.

Named Mach XPC carries only discovery Hello. The client verifies the endpoint-bearing
reply and uses a separately authenticated anonymous, non-rediscoverable endpoint for
action traffic. Interrupted connections are canceled. Workspace clients authenticate
the host before transmitting the owner token.

Real current-machine Unix, same-process XPC, Task propagation, ACL and endpoint
lifetime proofs passed. Successful installed-role authentication, full cross-process
product exchange, wrong-EUID, substituted executable, PID-reuse and forwarding proofs
remain absent. No production trust installer has been implemented or provisioned.
See [platform proof](../phase-2-peer-platform-proof.md).

## 3. PR5 — Authenticated dispatch

Added a non-wire context with immutable peer, role and connection identity. XPC captures
it synchronously before Task dispatch. No decoder or payload field can construct an
authenticated role or principal.

The exhaustive matrix separates diagnostic, agent, control-read and owner-mutation
methods. Diagnostics remain unprivileged. CLI identity alone is not control-reader or
owner authority. Workspace owner tokens are insufficient for operator permissions.

**Incomplete:** agent evaluation and owner/workspace mutation are currently refused.
There is no authenticated authoritative-host registration channel, live principal
reference flow, host-generation revalidation RPC or operation-scoped workspace permit.
Correct-role successful behavior is therefore not established. Refusal is a temporary
boundary, not completion of P2.2.

## 4. PR6 — Approvals and human authorization

Added immutable optional `ApprovalSubject` carrying instance/runtime/workspace/host
generation, fingerprint, policy context and continuation. Legacy rows retain nil subject;
name-only authorization always fails and name-only executable consumption is refused.
No ID/HookHost/SessionID-based principal migration occurs.

Added separate internal actor, service-derived operation and opaque consume-once owner
receipt. The broker re-reads exact rows, calls a live validator, checks disconnects and
both wall/continuous deadlines around suspension, and removes receipts before competing
consumers can reuse them. The LocalAuthentication wrapper owns its LAContext and disables
Touch ID reuse. Client success booleans are not accepted.

An isolated user GUI LaunchAgent compiled for macOS 15 on macOS 27 successfully called
`deviceOwnerAuthentication`. An initial 30-second attempt timed out; a subsequent attempt
returned success. The test job was removed. This proves the basic API in the LaunchAgent
context, **not an integrated deployed RV approval mutation**.

**Incomplete:** the broker has no production resolver/disconnect integration; no
authoritative-host live validator, atomic principal-bound resolution/grant transaction,
or subject-bound grant-consumption revalidation exists. Pending resolution and rule
save are unavailable. The 14 broker tests prove the isolated seam, not an end-to-end
human resolution. See [owner-authentication status](../phase-2-owner-authentication-status.md).

## 5. PR7 — Fallback/bypass closure

Swift hook failures now produce host-compatible denial; no local authority retry occurs.
Generic local evaluation is explicitly diagnostic and uses an isolated empty grant
store. Host-ASK grant planting refuses without owner authorization. C hooks deny before
service contact until a conforming authenticated C channel exists; operator front-door
execution remains, but guarded mutations refuse.

Guarded direct grant mint/redeem/clear, pack toggle, policy apply/save, draft/save,
explicit policy export file writes, safety mutation, permanent allowlist CRUD,
operator abandon, setup/install/uninstall and host adapter writes. Read-only views
and rendering remain. Automated recovery has no new human prompt.

A real built C front door and Swift sibling were invoked in a Seatbelt agent-equivalent
filesystem/network fence: known-code redemption refused with owner-authorization error
(exit 64); Claude hook output explicitly denied (host-native exit 0). The initial mint
invocation hit a CLI parse error and is **not** counted as authority proof. No grant or
policy JSON/TOML was created in the fixture.

**Incomplete:** authenticated replacement mutation routes and successful C operation
are absent. Loopback EgressProxy, workspace-host bootstrap, raw same-user file/store
mutation and direct allow-once row inspection remain unresolved entry points. These
are blockers, not non-blocking notes.

## 6. Entry-point inventory

The complete table is [entry-points.md](entry-points.md). It records classification,
transport, baseline authentication, caller fields, required role/principal source and
draft failure mode for 30 local entry-point classes. EgressProxy, bootstrap, direct
files and direct row reads are explicitly marked open; there is no claim that all
local authority side doors are closed.

## 7. Files changed

Exact files grouped by intended unit are listed in [files-changed.md](files-changed.md).
Shared evidence is in this directory and `verification/`. `Vendor/` was neither modified
by this work nor included in implementation/evidence lists. Spec and Phase 1 identity,
definition-store and registry source files remain unchanged.

## 8. Security invariants proven

- [x] Real Unix peer PID/EUID/audit-token/code evidence obtained without payload claims.
- [x] Real same-process XPC request/reply code evidence captured before asynchronous use.
- [x] Captured context survives Task dispatch unchanged.
- [x] Unconfigured component roles fail closed; forged role/PID fields do not assign roles.
- [x] Extended ACLs are checked alongside ownership/mode.
- [x] Anonymous endpoint lifetime cannot rediscover a replacement named listener.
- [x] Isolated receipt tests reject replay, stale rows/drafts, revocation and disconnect.
- [x] Monotonic lifetime bounds survive wall-clock rollback.
- [x] Legacy name-only rows cannot authorize executable consumption.
- [x] Swift/C failure paths do not retry local hook authority.
- [x] Tested direct CLI/TTY mutation paths refuse without owner authorization.
- [ ] Successful trusted-role production/development installation and authentication.
- [ ] Live authoritative-host principal registration/validity/generation invalidation.
- [ ] Correct-role successful agent dispatch and scoped workspace control.
- [ ] Integrated service-owned human authentication + atomic resolution + bound grant spend.
- [ ] Every local authority route authenticated; forwarding containment established.
- [ ] Full applicable gates green and final Phase 2 ground-truth audit satisfied.

Checks above are limited to the specified tests. Denying every operation does not prove
that a valid authenticated operation is correctly implemented.

## 9. Platform proof results

| Primitive | Minimum availability / observed result | Failure behavior / proof limit |
|---|---|---|
| SecCodeCreateWithXPCMessage | Public API available before macOS15; real request/reply on macOS27 passed | Fabricated message rejected; distinct-process installed-role product proof missing |
| SecCodeCopyGuestWithAttributes audit-token lookup | Public Security API; real Unix peers passed | Missing/dead token lookup fails; no PID fallback |
| SecCodeCheckValidity | Public API; real hash binding and wrong requirement checks passed | Required identity cannot downgrade to EUID |
| getpeereid / LOCAL_PEERPID | Public Darwin APIs; current-machine socket/PID comparisons passed | Missing/malformed/inconsistent evidence rejected |
| LOCAL_PEERTOKEN | Public Darwin SDK; current-machine full audit-token retrieval passed | Exact length/PID/EUID/process-version required; macOS15 runtime not tested |
| xpc_connection_create_from_endpoint | Public API macOS10.7; real endpoint lifecycle test passed | Non-rediscoverable endpoint replaced named action transport |
| xpc_connection_set_peer_code_signing_requirement | Public API macOS12; investigated, not introduced | No runtime enforcement proof claimed for this API |
| Extended ACL APIs | Public Darwin APIs; actual chmod ACL fixture passed | Allow entries/errors rejected; deny-only ACL accepted |
| Hardened runtime / injection entitlements | Public signing metadata; independent unchanged-hash DYLD injection reproduced and runtime mitigation observed | Role requires acceptable profile; installed-role proof still missing |
| LocalAuthentication | Available at target15; isolated GUI LaunchAgent success on macOS27 | First timeout reported; integrated RV resolver proof missing |

Deployment floor stays macOS15. No private SPI, measured launch or Secrets was added.
Headers/target-15 compilation do not substitute for running on macOS15.

## 10. Tests

All Swift commands used the pinned 6.4 wrapper. Actual process tests required sandbox
escalation; caches were redirected with `CLANG_MODULE_CACHE_PATH=/tmp/rv-phase2-clang`
and `SWIFTPM_MODULECACHE_OVERRIDE=/tmp/rv-phase2-swift`. Gates ran serially.

| Exact command | Observed result |
|---|---|
| `Scripts/preflight.sh` | PASS: 22 checks; zero failed; two existing dependency warnings |
| `Scripts/swift-6.4 test --filter RVDomainTests` | FAIL: 475 tests completed, 8 issues in legacy approval expectations |
| `Scripts/swift-6.4 test --filter RVPolicyTests` | FAIL: 317 tests completed, 4 issues in legacy approval store expectations |
| `Scripts/swift-6.4 test --filter RVIsolationTests` | INCOMPLETE/FAIL: terminated at 300s; 31 issues observed; no completed suite count |
| `Scripts/swift-6.4 test --filter RVIPCTests` | PASS: 95 tests |
| `Scripts/swift-6.4 test --filter RVServiceTests` | ABORTED: signal5 / test index-out-of-range trap after 42 observed issues; no completed count |
| `Scripts/swift-6.4 test --filter RVHooksTests` | PASS: 414 tests |
| `Scripts/swift-6.4 test --filter RVCLITests` | ABORTED: signal5 / test index-out-of-range trap after 151 observed issues; no completed count |
| `Sources/rv-c/tests/run.sh` | PASS: route/JSON/argv checks plus 9 host no-replay denials and oversized-input denial |

Final repository-standard command, after remediations:

```sh
Scripts/gate.sh --quiet --filter 'AuthenticatedDispatch|unixPeer|unixDifferent|peerTrust|dynamicCodeInvalid|fabricatedXPC|anonymousXPC|ControlAuthorization|LocalControlBoundary|EndpointLifetime|AgentIdentity|AgentDefinition|AgentInstance|AgentDelegation'
```

PASS: 102 tests (domain24, policy16, isolation33=27 identity+6 peer, service21,
CLI8) plus preflight. New focused security tests total35; frozen Phase1 total67.
Initial peer fixture failed Darwin socket path length and was shortened; repeat passed.
Broad suite failures are material product/regression failures of this incomplete draft;
they are not waived as green or hidden by modifying/skipping tests. No missing platform
case is counted as proof. An existing SwiftTerm build-graph warning was also emitted.
Full logs/commands are in [verification](verification/summary.json).

## 11. Fresh-review findings

A reviewer received no implementation rationale and independently examined all four
units, including untracked source/tests. Independently confirmed findings and remediations:

1. Action bytes preceded server authentication: Hello-first discovery, then verified endpoint.
2. Retained named connection could rediscover after interruption: anonymous action endpoint and cancellation.
3. POSIX root/mode checks ignored extended ACL writes: actual ACL fixture and path/FD validation.
4. Ad-hoc protected hash permitted injected process code: actual unchanged-hash injection reproduction;
   hardened-runtime/no-exception role gate.
5. Omitted draft/safety/export/allowlist writers: independently inspected direct writes and added guards.

Final review found no remaining actionable HIGH in the reviewed remediation. It expressly
kept full Phase2 completion blocked. This is approval of the narrow remediation, not
approval to ship disabled/unfinished Phase2 functionality or the unresolved entry points.

## 12. Phase 1 regression status

PASS for the frozen identity invariants: immutable instance and revision semantics,
exactly-once teardown, validity transitions, no journal resurrection, one-runtime/one-instance,
capability binding, weak-only assurance and delegation narrowing. All67 focused tests
passed before edits and after final remediations. Broad module regression gates are
not green; focused Phase1 passes do not certify this whole draft.

## 13. Deviations

The requested full implementation was not achieved. Four implementation PRs did not land;
this remains an uncommitted draft. Unsupported authority operations are unavailable
rather than weakened. This is more restrictive than usable Phase2 behavior and cannot
be treated as a completed feature. Protected trust installation and the authoritative
host/service bridge have not been built/proven. The implementation-plan document itself
was unavailable by title. Final post-landing ground-truth audit cannot occur before
those units land; this report is an interim read-only audit of repository/tests/product probes.

## 14. Remaining risks

Principal-reference/live-host/generation validation, atomic bound grants, production
owner/disconnect integration, scoped workspace permits, full successful XPC/C trust
journeys, Unix FD forwarding, unauthenticated proxy/bootstrap/direct files/row reads,
macOS15 runtime proof and failing full gates remain material blockers. The branch
currently prevents legitimate agent/control workflows; no release/merge claim is made.

## 15. Phase 3 prerequisites

Phase3 cannot rely on a completed Phase2. First implement/prove the missing host bridge,
working scoped owner/agent paths and principal-bound grant transaction, provision protected
component trust, close remaining entry points, complete adversarial product proofs and
make the applicable gates pass. HookHost/tag/reattachment rewiring was not started;
measured launch, Secrets and deferred Phase1 notes were not implemented.

## 16. Final status

**PHASE 2 BLOCKED**
