# Runtime release gate — initial acceptance matrix

Inspected 2026-09-21, main `854e69103333a65e86deacac853f915adc450868`, macOS 27 arm64 / Swift 6.4. Written **before production or test changes**. This snapshot is retained; final results belong in `runtime-acceptance.md`.

Verdicts: PASS requires executable evidence for the stated scope; PARTIAL and FAIL both mean **NOT SATISFIED** for release. No tests have yet been run in this audit, so existing tests alone are not PASS evidence. NOT APPLICABLE means an optional feature is absent, never that a required guarantee is waived.

Source keys: CLI = `Sources/RVCLI/RV.swift` + `Sources/rv-c/rv.c`; D = `Sources/RVDomain/Isolation.swift`; A = `Sources/RVIsolation/IsolationApply.swift`; S = `Sources/RVIsolation/SeatbeltProfile.swift`; L = `Sources/RVIsolation/LandlockRuleset.swift`, `LandlockApply.swift`, `landlock_apply.c`, `Sources/rv-isolation-exec/main.c`; E = `Sources/RVIsolation/ExecutableAction.swift`, `LocalExecutor.swift`, `AgentTurn.swift`; H = `Sources/RVIsolation/HostLaunch.swift`; ID = `Sources/RVDomain/AgentRequest.swift`, `SessionID.swift`; LOG = `Sources/RVHistory` and `Sources/RVService` (hook evaluation, not isolation execution).

The checked-out CLI does **not** register `rv <agent>`. H is an API called by tests, not a CLI path. CLI has no RVIsolation dependency. User has been asked whether a different checkout contains the launcher; audit proceeds on the supplied checkout.

## Initial matrix

| ID | Criterion | Initial | Implementation / missing evidence |
|---|---|---|---|
| 1.1 | Every agent command uses executor | FAIL | CLI → hooks; H not integrated; descendants bypass E |
| 1.2 | No alternate unsupervised RV path | FAIL | A supports explicit unsandboxed observed/mediated |
| 1.3 | Shell/script/interpreter descendants restricted | PARTIAL | S/L inherit only write fence; existing containment tests unrun |
| 1.4 | No silent unrestricted fallback | PARTIAL | E/H reject uncontained; backend failure tests unrun |
| 1.5 | Initialization fails closed | PARTIAL | A/L guard failures; Seatbelt establishment inferred from wrapper exit |
| 1.6 | Initiating agent recorded | FAIL | A/E/H have no runtime identity |
| 1.7 | Effective policy/capabilities recorded | FAIL | Plan in result only, no policy identity or audit sink |
| 1.8 | Children cannot escape supervision | FAIL | Waits direct child only |
| 2.1 | Minimum baseline authority | FAIL | S allow-default; L write-class only |
| 2.2 | Filesystem default deny | FAIL | All reads allowed |
| 2.3 | Network default deny | FAIL | D only unrestricted network |
| 2.4 | Process interaction default deny | FAIL | No process capability/control |
| 2.5 | Sensitive host resources inaccessible | FAIL | Ambient reads/network/IPC |
| 2.6 | Unknown capabilities cannot broaden | PARTIAL | Closed enums but no complete capability language |
| 2.7 | Missing policy cannot allow everything | FAIL | D independent of policy; observed/mediated unsandboxed |
| 2.8 | Compilation/init errors stop execution | PARTIAL | Existing failure tests unrun; no Seatbelt startup protocol |
| 3.1 | Allowed read works | PARTIAL | Reads unrestricted; no grant-specific model |
| 3.2 | Allowed write works | PARTIAL | Existing containment tests unrun |
| 3.3 | Read-only cannot mutate | PARTIAL | Outside workspace write fence only |
| 3.4 | Outside read denied | FAIL | S/L explicitly unrestricted |
| 3.5 | Outside write denied | PARTIAL | Existing tests; descriptors/hardlinks/races not proven |
| 3.6 | Parent traversal denied | PARTIAL | Kernel path rules; no dedicated proof |
| 3.7 | Relative escape denied | PARTIAL | Kernel path rules; no dedicated proof |
| 3.8 | Symlink escape denied | PARTIAL | Existing HOLE-SYMLINK does not assert effect |
| 3.9 | Hardlinks cannot bypass | FAIL | Inode alias behavior unproven |
| 3.10 | Rename/move cannot escape | PARTIAL | Existing FS-RENAME-OUT unrun |
| 3.11 | Deliberate temporary permissions | FAIL | No session temp capability |
| 3.12 | Home not implicitly granted | FAIL | Ambient reads |
| 3.13 | SSH denied unless granted | FAIL | Ambient reads |
| 3.14 | Credential/env/browser/keychain/cloud/git secrets denied | FAIL | Ambient reads/IPC/environment |
| 4.1 | No outbound without grant | FAIL | No network deny implementation |
| 4.2 | Children inherit network deny | FAIL | No network deny implementation |
| 4.3 | Localhost not exempt | FAIL | All network permitted |
| 4.4 | Unix sockets explicit | FAIL | No socket capability |
| 4.5 | DNS does not broaden | FAIL | No DNS/network capability |
| 4.6 | Host/domain rules resist raw IP bypass | NOT APPLICABLE | No host/domain rules; cannot claim support |
| 4.7 | Unknown network config fails closed | FAIL | No configuration parser for network capabilities |
| 5.1 | Cannot signal arbitrary host process | FAIL | No signal restriction |
| 5.2 | Cannot inspect unrelated processes | FAIL | No process isolation beyond OS baseline |
| 5.3 | Cannot attach debugger | PARTIAL | Platform baseline/Landlock; no probe |
| 5.4 | Cannot invoke privileged operations | FAIL | No explicit platform restriction set |
| 5.5 | Cannot elevate privilege | PARTIAL | L no_new_privs; macOS no explicit guarantee |
| 5.6 | Cannot manipulate RV | FAIL | No protected-control-plane model |
| 5.7 | Cannot kill/alter supervisor | FAIL | No signal supervision boundary |
| 5.8 | Cannot modify RV binary/config/policy | FAIL | Workspace may contain control plane; no separate grants |
| 5.9 | Namespace boundaries validated where used | NOT APPLICABLE | No namespaces used; missing host boundary remains blocker |
| 5.10 | Dangerous syscalls restricted when seccomp used | NOT APPLICABLE | No seccomp used |
| 6.1 | Typed policy/capabilities compile to isolation | PARTIAL | D typed isolation intent, unrelated to semantic policy |
| 6.2 | No loose security string interpretation | PARTIAL | Typed enums; E simple argv parser, C argv protocol |
| 6.3 | Invalid capability combinations rejected | PARTIAL | D restricted constructors; tests unrun |
| 6.4 | Unsupported capabilities explicit | PARTIAL | Typed errors for current slice only |
| 6.5 | Deterministic policy compilation | PARTIAL | D pure; S/L resolve live filesystem |
| 6.6 | Equivalent policies equivalent restrictions | PARTIAL | No policy-to-capability compiler |
| 6.7 | Broadening explicit and observable | FAIL | No audit; environment/descriptors implicit |
| 6.8 | Effective sandbox inspectable/explainable | PARTIAL | S source/L mask exposed, no runtime attestation |
| 6.9 | Independent compilation tests | PARTIAL | IsolationPlan/IsolationApply/LandlockApply exist, unrun |
| 7.1 | Stable runtime identity per agent | FAIL | No runtime identity |
| 7.2 | Every action attributable | FAIL | ID optional self-reported session |
| 7.3 | Identity not self-declared string | FAIL | No authenticated issuer |
| 7.4 | Child identity retained | FAIL | No process-tree identity |
| 7.5 | Policy uses authenticated identity | FAIL | No identity-bound policy |
| 7.6 | Cannot impersonate another agent | FAIL | No authenticated identity |
| 7.7 | Logs preserve identity across tree | FAIL | No execution audit stream |
| 8.1 | Deliberate authority/session association | PARTIAL | E carries action + plan; no session lease |
| 8.2 | Authority expires deliberately | FAIL | No expiry/revocation |
| 8.3 | Children lose authority after session | FAIL | No group/cgroup lifecycle |
| 8.4 | Temporary grants revocable | FAIL | No temporary capability model |
| 8.5 | No cross-agent capability leak | PARTIAL | Value plans local, ambient env/FDs shared |
| 8.6 | Session reuse excludes stale grants | FAIL | No session-capability binding |
| 8.7 | Concurrent differing agents isolated | PARTIAL | No concurrency enforcement tests |
| 9.1 | Policy parser failure | FAIL | Policy not bound to launch |
| 9.2 | Isolation generation failure | PARTIAL | Existing guards/tests unrun |
| 9.3 | Sandbox startup failure | PARTIAL | L exit protocol; S cannot distinguish startup exit |
| 9.4 | Process startup failure | PARTIAL | Process.run errors mapped; helper exec errors incomplete on S |
| 9.5 | Logging failure | FAIL | No mandatory execution logging |
| 9.6 | Child tracking failure | FAIL | No tracking |
| 9.7 | Malformed agent config | FAIL | No CLI agent configuration path |
| 9.8 | Partial runtime initialization | PARTIAL | Prepared vs established types; wrapper status issue |
| 9.9 | Cancellation | FAIL | Blocking waitUntilExit, no cancellation cleanup |
| 9.10 | Process crash | PARTIAL | Exit status only; no subtree cleanup |
| 9.11 | Supervisor termination | FAIL | No death/lease mechanism |
| 10.1 | Dedicated adversarial suite and all requested techniques | PARTIAL | Existing write tests; many attacks untested |
| 11.1 | Seatbelt applies before untrusted work | PARTIAL | sandbox-exec wraps inner; environment/FD/startup unresolved |
| 11.2 | Deterministic Seatbelt generation | PARTIAL | Deterministic for resolved path, live realpath input |
| 11.3 | Kernel path denial | PARTIAL | Existing kernel tests unrun |
| 11.4 | Descendant inheritance | PARTIAL | Existing shell tests unrun |
| 11.5 | Apply failure prevents command | PARTIAL | Need real invalid-profile marker test |
| 11.6 | Profile injection impossible | PARTIAL | Escapes slash/quote; adversarial paths untested |
| 11.7 | User paths encoded safely | PARTIAL | NUL/newline rejected; control characters/races unproven |
| 11.8 | Malformed input cannot broaden | PARTIAL | Root rejected; embedded NUL argv not rejected |
| 11.9 | Actual macOS enforcement tests | PARTIAL | Tests exist; audit has not executed them |
| 12.1 | Landlock before untrusted work | FAIL | Inherited loader environment can run before main |
| 12.2 | Detect unsupported Landlock/kernel | PARTIAL | ABI >=3 required, tests unrun |
| 12.3 | Unsupported kernel never unrestricted | PARTIAL | Trampoline returns 125, untested here |
| 12.4 | No silent namespace fallback | NOT APPLICABLE | No namespace implementation |
| 12.5 | Required seccomp failure closed | NOT APPLICABLE | No seccomp implementation |
| 12.6 | Children retain constraints | PARTIAL | Existing Linux tests unrun |
| 12.7 | proc/sys/devices/mounts/sockets/host visibility | FAIL | Ambient access not restricted |
| 12.8 | Privilege escalation tested | FAIL | No probes |
| 12.9 | CI/container and real host behavior | PARTIAL | CI configured; no fresh evidence |
| 13.1 | Which agent | FAIL | No runtime audit |
| 13.2 | Attempted action | PARTIAL | Hook logs only, no process exec stream |
| 13.3 | Effective capabilities | FAIL | No runtime audit |
| 13.4 | Authorizing policy | FAIL | No bound policy identity |
| 13.5 | Applied sandbox | PARTIAL | Result mode/family only |
| 13.6 | Denied operations | FAIL | No kernel-denial ingestion |
| 13.7 | Allowed operations | FAIL | No exec audit |
| 13.8 | Spawned PID | FAIL | PID discarded |
| 13.9 | Child process tree | FAIL | Not tracked |
| 13.10 | Event time | FAIL | No execution events |
| 13.11 | Decision rationale | PARTIAL | Authorization value only |
| 13.12 | Structured events without secrets; ingestion ready | FAIL | No execution event model |
| 14.1 | Unit type/compile tests | PARTIAL | Existing suites unrun |
| 14.2 | Real integration tests | PARTIAL | Existing suites unrun |
| 14.3 | Adversarial bypass suite | PARTIAL | Existing write conformance only |
| 14.4 | Permanent regression per discovered bug | FAIL | New findings not yet covered |
| 14.5 | Observable effects, not snapshots alone | PARTIAL | Existing filesystem effects; network hole is snapshot-only |
| 15.1 | Functional Swift/immutable domain | PARTIAL | Domain structs/enums; preflight unrun |
| 15.2 | Explicit states/strong types/exhaustive enums | PARTIAL | Prepared/established model; establishment not attested |
| 15.3 | Composition/DI/effects outside policy | PARTIAL | Function backends; synchronous process boundary |
| 15.4 | Pure deterministic policy compilation | PARTIAL | D pure, backend path resolution effectful |
| 15.5 | Typed errors | PARTIAL | Existing errors; some conflated startup status |
| 15.6 | Concurrency/Sendable/no unnecessary shared state | PARTIAL | LocalExecutor actor blocks; process lifetime unowned |
| 15.7 | Fail-closed security semantics | PARTIAL | Contained no fallback, insufficient authority restriction |
| 16.A | Repo rw, SSH unreadable, outside unwritable | FAIL | SSH reads allowed |
| 16.B | No network including children | FAIL | Network unrestricted |
| 16.C | Wrappers/children cannot escape all restrictions | PARTIAL | Write fence only |
| 16.D | Failed isolation never executes | PARTIAL | Need startup/loader/FD probes |
| 16.E | Concurrent agents cannot acquire authority | FAIL | No identity/capability boundary, ambient reads |
| 16.F | Identity + structured execution evidence | FAIL | Absent |
| 16.G | Explain X/Y/Z/P/S | FAIL | No identity or policy binding |
| 16.H | Important negative guarantees automated | PARTIAL | Write fence tests only |

## Hardening work plan

- [x] Inspect entrypoint, domain, executor, isolation, tests, handoffs and CI before code changes.
- [x] Record criterion-level initial matrix with no inferred passes.
- [ ] Reproduce boundary defects using disposable fixtures only; never real credentials or unrelated host processes.
- [ ] Harden executable/environment/workspace/backend startup boundaries where a small, reviewable fix can be verified.
- [ ] Add adversarial effect tests, including real sockets, process descendants, credential fixtures, concurrency, and known-gap witnesses.
- [ ] Run macOS enforcement, Linux kernel probes where available, repository checks, and independent review.
- [ ] Publish final matrix, actual architecture, trust boundary, attack inventory, release blockers and exact evidence; append phase-10 handoff notes.

Scope decision: do not invent an authenticated runtime, policy broker, revocable leases or a CLI integration absent from this checkout during a bounded hardening pass. Their absence is a release blocker, not permission to certify the first-slice fence as secure agent isolation. Any implemented capabilities must remain honestly described.
