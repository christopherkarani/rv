# RV runtime release-gating acceptance audit

Last updated: 2026-09-21. Base: `main` at `854e69103333a65e86deacac853f915adc450868`; results apply to the subsequent working-tree hardening changes, not that commit alone. Host: macOS 27 arm64, Swift 6.4. **Overall verdict: NOT SATISFIED — RELEASE BLOCKED.**

`rv opencode` launches through `launchContainedHost`. On macOS the contained plan is now workspace-scoped: `(deny default)`, not `(allow default)`. A native client under that profile was denied TCP/UDP to loopback, TCP to `::1`, TCP to `1.1.1.1:443`, a Unix socket, and DNS, including through `/bin/sh`. Synthetic files outside the workspace could not be read or written. `kill` of a test-owned process returned `Operation not permitted` and the process stayed alive. A workspace that already contains a hard link is refused before launch. Linux contained launch returns `containedGuaranteesUnsupported` and does not execute, because the helper still cannot enforce the same read, network, and signal limits. There is still no runtime-issued identity, no mandatory audit event, and no proof that a child loses authority when the supervisor exits. **Overall verdict remains NOT SATISFIED.**

The rows below this paragraph that still say `(allow default)` or "network unrestricted" describe the tree before this pass. The superseded IDs are listed in the hardening section. Do not quote those older sentences as the current profile.

The immutable [initial matrix](runtime-acceptance-initial.md) was written before production/test edits. The user's follow-up explicitly authorized registering the missing launcher in this checkout; that supersedes the initial scope note and the historical phase-10 instruction excluding CLI registration. No other branch contains the implementation for this audit.

## Evidence and interpretation

**PASS** means the exact stated scope has executed evidence. **PARTIAL** and **FAIL** mean **NOT SATISFIED** for the release criterion. FAIL includes demonstrated unsafe behavior and an absent mandatory boundary. PARTIAL includes a useful implemented subset or an unproven platform. NOT APPLICABLE only marks an optional mechanism that is absent; it does not waive the required guarantee.

`knownGap` tests deliberately succeed when they reproduce current limitations. Their success means the gap is observable, not fixed. RED logs are retained to show the defects/test-harness corrections that preceded hardening. Tests use synthetic credentials and owned process/socket/file fixtures.

| Evidence | Observed result | Scope |
|---|---|---|
| `.build/security-audit/focused-final.log` | 142 tests passed: RVIsolationTests 102, IsolationPlanTests 13, OpenCodeCommandTests + InstallScriptTests 27 | Final focused Swift verification; includes all eight installed launcher variants and corrected xargs fixture. |
| `.build/security-audit/boundary-green.log` | Earlier 72 tests / 6 suites passed | Launch input/environment/path validation, existing apply/host/action tests and executor lifecycle regressions on macOS. |
| `.build/security-audit/installer-green.log` | 20 tests passed | Installer packages/requires Linux helper and preserves prior install on missing helper. Not actual Linux kernel enforcement. |
| [Retained CLI proof](evidence/cli-proof.jsonl); `.build/security-audit/cli-proof-final.jsonl` | 9 PASS, 10 GAP, 5 NOT-TESTED, 0 FAIL; harness exit 2 | Staged C `rv` → Swift `rv-cli` through absolute and PATH entrypoints: write fence, sockets, fake reads, signals, startup, environment/FD fixture and child authority after supervisor SIGKILL. |
| [Retained Linux results](evidence/linux-results.json), [environment](evidence/linux-environment.json); `.build/security-audit/linux/reviewed/results.json` | 6 PASS, 3 GAP, 0 FAIL; harness exit 2 | Real unsupported-kernel rejection plus explicitly stubbed Landlock C setup tests, including a positive launch control. No positive Landlock enforcement claim. |
| `.build/security-audit/adversarial-macos.log` | Original RED: xargs input fixture did not run; other effects recorded | Retained diagnostic evidence; corrected xargs passes in `focused-final.log`. |
| [Retained Linux Swift proof](evidence/linux-swift.txt); `.build/security-audit/linux-swift.log` | Actual Swift Domain/Isolation/helper build and startup probes passed | Isolated dependency-free package in Docker: hostile loader variable removed before helper constructor, absent inner marker on unsupported kernel, helper located from kernel executable path with absolute/forged relative argv0. No positive Landlock enforcement. |
| `.build/security-audit/swift-gate.log` | 652 tests executed; 3 failures | Broader RVIsolation/RVDomain/RVCLI run, excluding `CHookPipeTests.cHookProof`; see failures below. This is not a green release gate. |
| `.build/security-audit/existing-failures.log`, `baseline-existing-failures.log` | Same 3 failures reproduced both in working tree and pristine `git archive HEAD` | Confirms pre-existing host service/app-presence assumptions and empty-stdin policy draft fixture failures. |
| `.build/security-audit/preflight-product.log` | 0 failures, 2 warnings | Separate product snapshot excludes historical ignored handoffs; does not change the failing full-checkout gate. |
| `.build/security-audit/c-path-green.log`, `c-linux.log` | Exit 0 on Darwin and Linux | C frontend tests include PATH launch, forged argv0 and malicious HOME fallback rejection. |
| `.build/security-audit/gate.log` | Repository gate failed in preflight | Pre-existing name-hygiene term in ignored `docs/rv-agent/handoffs/phase-05-landlock-apply.md`; tests were not reached by this gate invocation. |

The broader Swift failures are `SystemctlApplyingTests.launchAgentProbe_missingLaunchctlIsNotLoaded` (installed host service), `ResidualLinuxCoverageTests.companionPresence_linuxFilesystemProbe` (installed host app), and `OperatorCommandRunTests.policyDraft_runEdges` (empty stdin). These remain explicit verification limitations. Final verification additions are listed in the completion notes below. Compact evidence is retained under `docs/security/evidence`; full transient logs remain under `.build/security-audit`. [Source hashes](evidence/source-sha256.json) and [verification summary](evidence/verification.txt) tie retained results to the audited working tree. The exact isolated Linux Swift harness is retained as [linux-swift-probe.txt](evidence/linux-swift-probe.txt). The supplied checkout already had a modified `Package.resolved` and untracked `Scripts/__pycache__/`; those are recorded in `.build/security-audit/initial-git-status.txt` and are not hardening changes.

## Implementation and test keys

Each matrix row names the concrete boundary/implementation and the tested effect or missing proof. These keys resolve to source files and named tests, avoiding a false link between hook-policy logs and runtime enforcement.

| Key | Exact implementation / boundary |
|---|---|
| CLI | [RV.configuration](../../Sources/RVCLI/RV.swift), [OpenCode.run / OpenCodeRun.run](../../Sources/RVCLI/Commands/OpenCodeCommand.swift), C frontend dispatch in [rv.c](../../Sources/rv-c/rv.c). Operator input → contained host launch; no runtime identity or policy lookup. |
| D | [Isolation.swift](../../Sources/RVDomain/Isolation.swift): `compileIsolationPlan`, `IsolationPlan`, `IsolationGuarantees`, `NetworkContainment`. Typed intent → write-only isolation plan. |
| A | [IsolationApply.swift](../../Sources/RVIsolation/IsolationApply.swift): `IsolatedCommand.make`, `prepareSeatbelt`, `spawn`, `EstablishedIsolation`. Validated plan/argv → child process. |
| S | [SeatbeltProfile.swift](../../Sources/RVIsolation/SeatbeltProfile.swift): `compileFirstSliceProfile`, `escapeSeatbeltSubpath`, `existingResolvedWorkspacePath`. Path → Seatbelt allow-default/write-deny source. |
| L | [LandlockRuleset.swift](../../Sources/RVIsolation/LandlockRuleset.swift), [LandlockApply.swift](../../Sources/RVIsolation/LandlockApply.swift), [landlock_apply.c](../../Sources/RVIsolation/landlock_apply.c), [helper main.c](../../Sources/rv-isolation-exec/main.c): write-class rules, helper resolution, close_range/openat2/no_new_privs/apply/exec. |
| E | [LocalExecutor.run / perform](../../Sources/RVIsolation/LocalExecutor.swift), [compileExecutable](../../Sources/RVIsolation/ExecutableAction.swift), [AgentTurn](../../Sources/RVIsolation/AgentTurn.swift). Authorization → dispatch; separate from CLI host descendants. |
| H | [launchContainedHost](../../Sources/RVIsolation/HostLaunch.swift). Only `.opencode` plus contained plan may reach A with inherited stdio. |
| ID | [AgentRequest.swift](../../Sources/RVDomain/AgentRequest.swift), [SessionID.swift](../../Sources/RVDomain/SessionID.swift). Optional host-supplied session string; not runtime-issued identity. |
| LOG | [RVHistory](../../Sources/RVHistory), [RVService](../../Sources/RVService). Hook evaluation history exists; CLI/H/A/E have no required runtime audit sink, PID/tree events or policy identity. |
| LB | [LaunchBoundaryRegressionTests.swift](../../Tests/RVIsolationTests/LaunchBoundaryRegressionTests.swift): NUL, minimal environment, prepared-workspace retarget, SBPL encoding, invalid profile marker. |
| EL | [ExecutorLifecycleRegressionTests.swift](../../Tests/RVIsolationTests/ExecutorLifecycleRegressionTests.swift): cancellation before dispatch, reserve-before-apply, reserved exit replay, concurrent same-authorization dispatch. |
| RA | [RuntimeAdversarialTests.swift](../../Tests/RVIsolationTests/RuntimeAdversarialTests.swift): wrappers, traversal, links, rename, fake secrets, control files, concurrent workspaces, surviving child and host signal. |
| IT | [IsolationApplyTests.swift](../../Tests/RVIsolationTests/IsolationApplyTests.swift), [HostLaunchTests.swift](../../Tests/RVIsolationTests/HostLaunchTests.swift), [LocalExecutorTests.swift](../../Tests/RVIsolationTests/LocalExecutorTests.swift), [SeatbeltContainmentTests.swift](../../Tests/RVIsolationTests/SeatbeltContainmentTests.swift), [LandlockApplyTests.swift](../../Tests/RVIsolationTests/LandlockApplyTests.swift), [LandlockContainmentTests.swift](../../Tests/RVIsolationTests/LandlockContainmentTests.swift). Platform-specific branches must be read with run artifacts. |
| UT | [IsolationPlanTests.swift](../../Tests/RVDomainTests/IsolationPlanTests.swift), backend compilation tests in IT, [OpenCodeCommandTests.swift](../../Tests/RVCLITests/OpenCodeCommandTests.swift). |
| CP | [runtime-cli-proof.py](../../Scripts/runtime-cli-proof.py) and JSONL artifact above. Real CLI, kernel effects and explicit omissions. |
| LP | [isolation-linux-adversarial.py](../../Scripts/isolation-linux-adversarial.py) and `linux/reviewed/{environment,results,command}.json`. Distinguishes C units with Landlock stubs from actual kernel checks. |

## Hardening pass — 2026-09-21, macOS 27 arm64

Command: `Scripts/swift-6.4 test --filter 'IsolationApplyTests|HostLaunchTests|IsolationApplyLandlockTests|OpenCodeCommandTests|SeatbeltCapabilityTests|RuntimeAdversarialTests|IsolationConformanceTests|SeatbeltContainmentTests|IsolationPlanTests'`. Exit 0. Suites: IsolationApply (both Seatbelt and Landlock compile suites), HostLaunch, OpenCode command, SeatbeltCapability, RuntimeAdversarial, IsolationConformance, SeatbeltContainment, IsolationPlan.

`SeatbeltCapabilityTests.containedProcessCannotConnectOrResolve` runs one native client twice. Outside the sandbox it receives loopback TCP, UDP, IPv6 TCP, `1.1.1.1:443`, a Unix socket, and a DNS answer. Inside `IsolationBackends.apply` the same client prints `errno=1` for each connect or send and `dns rc=` without `dns ok`. A `/bin/sh` child does the same. No listener received a sandboxed payload. `containedProcessCannotReadSiblingFile` copies nothing from a sibling file.

| ID | This pass | Why |
|---|---|---|
| 2.2, 3.4, 3.13, 3.14 | PARTIAL | macOS denies the tested outside reads. Linux does not enforce them; it refuses the launch. `/usr`, `/bin`, `/System`, `/Library`, and `/dev` remain readable so programs can start. `file-read-metadata` on `/Users`, `/private`, `/tmp`, and `/var` allows path walks, not file contents in the tests. |
| 2.3, 4.1–4.5 | PARTIAL | macOS kernel denials above, including a child shell. No host/domain allowlist exists. Linux is refusal, not a tested network namespace. |
| 2.4, 5.1 | PARTIAL | macOS `kill -TERM` of a harness-owned `sleep` fails and the process remains. Debugger attachment, Mach/XPC delegation, and `/usr/bin/osascript` were not accepted as proof. `mach-lookup` is still an unfiltered Seatbelt allow. |
| 3.5, 3.9 | PARTIAL | Ordinary outside writes stay denied. A preexisting hard link makes `prepare`/`spawn` return `workspaceContainsInodeAlias` and leaves the outside file unchanged. That is a scan, not a kernel inode rule. A link created after the scan is not covered. |
| 3.1, 3.2 | PARTIAL | Workspace read and write work on macOS. They are the contained plan, not an extra grant. Linux does not launch. |
| 11.1–11.5, 11.9 | PARTIAL / PASS as before for writes | The profile is `(deny default)` and is applied by `/usr/bin/sandbox-exec` before the payload. Invalid profiles still do not run the payload. Determinism is same-input source equality in `compileSeatbeltProfile_contained_isDenyDefaultWorkspaceScope`. |
| 12.1, 12.6, 12.9 | FAIL for positive enforcement | `compileLandlockRuleset` returns `containedGuaranteesUnsupported` for a real directory after path checks. The write-only helper is not used as a fallback. Direct helper tests of bad argv still exist. No supported-kernel Landlock run was available here. |
| 1.1, 1.6–1.8, 7.*, 8.2–8.4, 9.5–9.6, 9.11, 13.* | FAIL | Unchanged. Descendants do not re-enter `LocalExecutor`. No runtime identity, audit sink, or session revocation. A background child can still write inside the workspace after its parent returns. |
| 16.A–16.C | PARTIAL on macOS | A, B, and the tested interpreter/shell wrappers hold on this Mac for ordinary paths. Linux and the hardlink race do not. |
| 16.D | PASS for tested init failures | Bad Seatbelt profile, missing workspace, and unsupported Landlock guarantees do not run the payload. |
| 16.E | PARTIAL | Separate workspaces cannot write each other. Outside reads are denied by the same profile. There is no identity separating two agents beyond their workspace paths. |
| 16.F, 16.G | FAIL | No runtime identity and no structured launch audit. |
| 16.H | PARTIAL | Adversarial and capability suites now assert the denials above. Python's `/usr/bin/python3` stub and Node outside `/usr/bin` are printed NOT TESTED. |

## Criterion-level final matrix

### 1. Execution ownership

| ID | Criterion | Verdict | Boundary, bypass and executable evidence |
|---|---|---|---|
| 1.1 | Every agent command uses executor | FAIL | CLI → H → A launches host; children spawn directly without E/semantic authorization. RA wrappers prove child execution but not executor ownership. |
| 1.2 | No alternate unsupervised RV path | PARTIAL | H/E reject observed/mediated; A retains explicit unsandboxed API. CP recursive-RV retains write fence only; no universal RV authority boundary. |
| 1.3 | Shell/script/interpreter descendants restricted | PARTIAL | S write fence inherited in RA wrappers/shebang/nested tests. Reads/network/signals remain available; L positive enforcement unproven. |
| 1.4 | No silent unrestricted fallback | PASS | Contained CLI/H/E/A paths reject unavailable/invalid controls; IT `apply_contained_withoutUsableWorkspaceOrBackend_failsClosed`, CP startup markers, LP unsupported-kernel marker. No broader capability guarantee implied. |
| 1.5 | Initialization fails closed | PARTIAL | LB invalid-profile marker absent, CP bad inputs absent, LP unsupported setup absent. LP/actual Linux Swift sanitizer cover injected loader input; helper trust, path races and startup attestation remain unresolved. |
| 1.6 | Initiating agent recorded | FAIL | CLI/H/A/E have no identity parameter or issuance; ID is optional self-report. No attribution test possible for missing runtime event. |
| 1.7 | Effective policy/capabilities recorded | FAIL | D values reach A but no policy ID/capability audit sink exists; LOG hook history does not cover launch. |
| 1.8 | Children cannot escape supervision | FAIL | A waits immediate Process only. RA `knownGapChildOutlivesImmediateParentWithWriteAuthority` creates marker after parent returns. |

### 2. Default-deny isolation

| ID | Criterion | Verdict | Boundary, bypass and executable evidence |
|---|---|---|---|
| 2.1 | Minimum baseline authority | FAIL | S `(allow default)`; L write-class only. CP credential/network/signal GAP effects refute minimum authority. |
| 2.2 | Filesystem default deny | FAIL | S/L allow reads. RA 13 fake secret paths and CP 7 fake credentials readable outside grant. |
| 2.3 | Network default deny | FAIL | D `.unrestricted`; S/L no denial. CP seven socket/DNS-packet fixtures receive data. |
| 2.4 | Process interaction default deny | FAIL | No process capability. RA/CP TERM reaches test-owned unrelated process. |
| 2.5 | Sensitive host resources inaccessible | FAIL | RA fake secrets readable; CP Unix socket/network connections succeed. No private host-resource boundary. |
| 2.6 | Unknown capabilities cannot broaden | PARTIAL | D closed enums and A mismatch guards cover current slice; no complete capability configuration language or unknown-network parser test. |
| 2.7 | Missing policy cannot allow everything | FAIL | CLI constructs D write-only plan without semantic policy. Network/read/process authority is ambient when no policy is configured. |
| 2.8 | Compilation/init errors stop execution | PARTIAL | A/S/L reject covered invalid cases with absent markers (LB/CP/LP). Startup status is not authenticated; actual Linux Swift startup is tested only on an unsupported kernel. |

### 3. Filesystem isolation

| ID | Criterion | Verdict | Boundary, bypass and executable evidence |
|---|---|---|---|
| 3.1 | Allowed read works | PARTIAL | RA copies files successfully, but reads are ambient rather than explicitly granted; D has no read-grant type. |
| 3.2 | Allowed write works | PARTIAL | IT host/executor/Seatbelt inside markers, RA positive controls and CP write fence pass on macOS. Actual L inside-write enforcement not proven. |
| 3.3 | Read-only cannot mutate | FAIL | Ordinary outside writes denied, but RA preexisting hardlink alias mutates outside source. No typed read-only grants. |
| 3.4 | Outside read denied | FAIL | RA/CP fake secret content successfully copied. S/L deliberately do not restrict read. |
| 3.5 | Outside write denied | FAIL | Ordinary paths blocked, but RA `knownGapPreexistingHardlinkAliasIsReported` mutates outside inode. Inherited stdio and path races also unresolved. |
| 3.6 | Parent traversal denied | PARTIAL | RA `relativeTraversalCannotWriteOutsideWorkspace` tests three paths and absent markers on macOS. Read traversal unrestricted; Linux unproven. |
| 3.7 | Relative escape denied | PARTIAL | Same RA relative-write effects and fixed contained cwd; relative reads remain unrestricted. |
| 3.8 | Symlink escape denied | PARTIAL | RA new/preexisting chains deny outside writes; LB rejects prepared alias retarget. Reads and final launch races remain outside proof. |
| 3.9 | Hardlinks cannot bypass | FAIL | RA agent-created link denied, host-preexisting alias outside mutation succeeds on macOS. |
| 3.10 | Rename/move cannot escape | PARTIAL | RA `renameCannotMoveAcrossWriteBoundary` preserves both sources across export/import attempts on macOS; no actual Linux run. |
| 3.11 | Deliberate temporary permissions | PARTIAL | A sets TMPDIR to canonical write root; LB verifies value. No private session temp directory, mode/cleanup or revocation guarantee. |
| 3.12 | Home not implicitly granted | FAIL | A replaces HOME with workspace but absolute original-home paths remain readable; RA fake-home reads prove access model. |
| 3.13 | SSH denied unless granted | FAIL | RA/CP synthetic `.ssh/id_ed25519` readable without grant; no real keys accessed. |
| 3.14 | Credential/env/browser/keychain/cloud/git secrets denied | FAIL | RA 13 credential/store paths readable. LB/CP environment scrub passes only for inherited values, not filesystem/IPC secret authority. |

### 4. Network isolation

| ID | Criterion | Verdict | Boundary, bypass and executable evidence |
|---|---|---|---|
| 4.1 | No outbound without grant | FAIL | CP IPv4/IPv6 TCP/UDP fixture receives data; D/S/L have no deny capability. |
| 4.2 | Children inherit network deny | FAIL | CP shell → interpreter connections succeed. There is no network denial to inherit. |
| 4.3 | Localhost not exempt | FAIL | CP loopback TCP/UDP succeeds without grant. |
| 4.4 | Unix sockets explicit | FAIL | CP Unix stream/datagram payloads arrive. No socket capability/restriction. |
| 4.5 | DNS does not broaden | FAIL | CP local DNS-shaped datagram succeeds; no DNS authority boundary. System resolver not tested. |
| 4.6 | Host/domain rules resist raw IP bypass | NOT APPLICABLE | D supports no host/domain rules. No enforcement promise; future proxy/broker design required. |
| 4.7 | Unknown network config fails closed | FAIL | No network capability parser or failure path exists. Closed `.unrestricted` enum cannot stand in for absent requested behavior. |

### 5. Process / host escape

| ID | Criterion | Verdict | Boundary, bypass and executable evidence |
|---|---|---|---|
| 5.1 | Cannot signal arbitrary host process | FAIL | RA/CP TERM to harness-owned same-user unrelated process succeeds. No process policy. |
| 5.2 | Cannot inspect unrelated processes | FAIL | No PID namespace/process-visibility controls; actual inspection probe absent. Unproven is not satisfied. |
| 5.3 | Cannot attach debugger | PARTIAL | Platform baseline may restrict attachment; no RV process capability and no direct attachment test. L enforcement unavailable. |
| 5.4 | Cannot invoke privileged operations | FAIL | No explicit privilege-operation capability or negative probe; ambient OS permissions only. |
| 5.5 | Cannot elevate privilege | PARTIAL | L calls `PR_SET_NO_NEW_PRIVS`; no real L elevation probe; S baseline lacks an RV no-elevation guarantee. |
| 5.6 | Cannot manipulate RV | FAIL | RA workspace RV config writable; CP arbitrary same-user signaling and sockets available. Supervisor IPC attack not fully tested. |
| 5.7 | Cannot kill/alter supervisor | FAIL | No signal or lifecycle boundary. RA/CP unrelated-process signal proves missing restriction; CP externally kills owned supervisor and child authority survives. An agent directly killing supervisor is not separately probed. |
| 5.8 | Cannot modify RV binary/config/policy | FAIL | RA ordinary outside paths write-denied but workspace control files writable. H permits any chosen workspace; no protected subpaths. |
| 5.9 | Namespace boundaries validated where used | NOT APPLICABLE | RV installs no namespaces. Docker fixture boundaries cannot be credited to RV; required host isolation remains failed. |
| 5.10 | Dangerous syscalls restricted when seccomp used | NOT APPLICABLE | RV installs no seccomp filter; Docker's filter is external. No syscall capability guarantee. |

### 6. Policy → isolation compilation

| ID | Criterion | Verdict | Boundary, bypass and executable evidence |
|---|---|---|---|
| 6.1 | Typed policy/capabilities compile to isolation | PARTIAL | D typed isolation intent → S/L write fence; no semantic policy or identity-bound capability compilation. UT/IT cover only existing domain. |
| 6.2 | No loose security string interpretation | PARTIAL | D enums/A typed errors/H exhaustive host switch; E simple command parser and L argv/status protocol remain. No complete typed capabilities. |
| 6.3 | Invalid capability combinations rejected | PARTIAL | D restricted constructors, A request-family guards, IT mismatch tests; broader capability composition absent. |
| 6.4 | Unsupported capabilities explicit | PARTIAL | H rejects other hosts; A rejects backend/mode combinations in IT. Missing read/network/process capabilities have no request language. |
| 6.5 | Deterministic policy compilation | PARTIAL | D pure intent compilation; S/L depend on live realpath. No complete semantic-policy compiler/determinism proof. |
| 6.6 | Equivalent policies equivalent restrictions | PARTIAL | Value equality and fixed write mask exist; authenticated policies/capability normalization absent. LB checks alias retarget, not full policy equivalence. |
| 6.7 | Broadening explicit and observable | FAIL | D declares unrestricted network; CLI warns, but ambient reads/process/stdio and mutable control files have no audited capability grants. |
| 6.8 | Effective sandbox inspectable/explainable | PARTIAL | S profile source/L mask available; CLI explains write-only scope. A result lacks attested profile, policy, identity and PID/tree. |
| 6.9 | Independent compilation tests | PARTIAL | UT/IT test intent/profile/mask independent of spawn. Complete policy-capability language absent; real restrictions cannot be inferred from snapshots. |

### 7. Agent identity binding

| ID | Criterion | Verdict | Boundary, bypass and executable evidence |
|---|---|---|---|
| 7.1 | Stable runtime identity per agent | FAIL | CLI/H/A have no runtime identity issuer. `.opencode` is adapter tag only; no identity test. |
| 7.2 | Every action attributable | FAIL | Children bypass E; ID optional session string is not an execution principal. No process-tree attribution event. |
| 7.3 | Identity not self-declared string | FAIL | ID validates syntax only; no authenticated runtime binding. Impersonation rejection not implemented/testable. |
| 7.4 | Child identity retained | FAIL | A discards PID after wait and records no descendants/identity. RA child can outlive return. |
| 7.5 | Policy uses authenticated identity | FAIL | CLI builds D directly from workspace; no identity → policy lookup. |
| 7.6 | Cannot impersonate another agent | FAIL | No issuer, audience/session binding or capability principal. No cross-identity rejection tests. |
| 7.7 | Logs preserve identity across tree | FAIL | LOG lacks runtime tree events; CLI/A produce no structured identity audit. |

### 8. Capability lifetime

| ID | Criterion | Verdict | Boundary, bypass and executable evidence |
|---|---|---|---|
| 8.1 | Deliberate authority/session association | PARTIAL | E action fingerprint + plan is local dispatch association; H has no session/identity/capability lease. EL verifies local one-shot behavior only. |
| 8.2 | Authority expires deliberately | FAIL | No expiration. RA post-parent marker proves descendant retains workspace authority. |
| 8.3 | Children lose authority after session | FAIL | A waits immediate child, no group/cgroup/lease. RA surviving child writes after return. |
| 8.4 | Temporary grants revocable | FAIL | E consumes authorization locally but cannot revoke kernel authority of an active descendant. No revocation model/test. |
| 8.5 | No cross-agent capability leak | PARTIAL | RA simultaneous workspaces cannot cross-write; A environment sanitized. Ambient reads/network and inherited stdio defeat complete isolation. |
| 8.6 | Session reuse excludes stale grants | FAIL | No identity/session lease. EL prevents retry in one executor, not reuse/revocation across runtime sessions. |
| 8.7 | Concurrent differing agents isolated | PARTIAL | RA concurrent write grants and EL concurrent once-only dispatch pass locally; read/network/identity authority remains shared. |

### 9. Supervisor failure

| ID | Criterion | Verdict | Boundary, bypass and executable evidence |
|---|---|---|---|
| 9.1 | Policy parser failure | FAIL | No runtime policy parser bound to CLI launch; CP records NOT-TESTED instead of inventing failure coverage. |
| 9.2 | Isolation generation failure | PARTIAL | D missing workspace/S root/NUL/newline guards; LB/CP no-marker failures. Final races and broader policy compiler absent. |
| 9.3 | Sandbox startup failure | PARTIAL | LB invalid profile never executes inner marker; LP actual unavailable kernel exits 125. A can misreport Seatbelt establishment; helper status unauthenticated. |
| 9.4 | Process startup failure | PARTIAL | A maps `Process.run` error; CP missing executable prevents marker. Seatbelt inner-exec failure and Linux 126 share status-protocol limitations. |
| 9.5 | Logging failure | FAIL | No mandatory runtime audit sink. Launch is not gated on audit success; no injection test possible. |
| 9.6 | Child tracking failure | FAIL | No child tracker; descendants continue outside RV observation. RA post-parent child witness. |
| 9.7 | Malformed agent config | PARTIAL | CLI validates explicit executable/workspace and UT/CP reject malformed launch input. No complete agent configuration/policy schema. |
| 9.8 | Partial runtime initialization | PARTIAL | A prepared/established values and IT mismatch checks exist; LB invalid profile can still report established. |
| 9.9 | Cancellation | PARTIAL | EL pre-dispatch cancellation blocks execution without consumption; in-flight blocking wait has no cancellation/tree cleanup. |
| 9.10 | Process crash | PARTIAL | A returns immediate exit status, no crash-specific tree cleanup test; descendants remain unowned. |
| 9.11 | Supervisor termination | FAIL | No death/lease cleanup mechanism; CP kills its owned RV supervisor and observes the child writing after supervisor death. |

### 10. Direct bypass suite

| ID | Criterion | Verdict | Boundary, bypass and executable evidence |
|---|---|---|---|
| 10.1 | Dedicated adversarial suite and all requested techniques | PARTIAL | RA/LB/EL/CP/LP add real effects. [Inventory](adversarial-inventory.md) names every requested attack, known gap and omission; debugger/privilege/proc/daemon/real-Linux coverage incomplete. |

### 11. macOS acceptance

| ID | Criterion | Verdict | Boundary, bypass and executable evidence |
|---|---|---|---|
| 11.1 | Seatbelt applies before untrusted work | PARTIAL | A fixed wrapper and sanitized environment; LB invalid-profile marker absent, RA descendant write denial. Inherited handles/path races and unauthenticated establishment remain. |
| 11.2 | Deterministic Seatbelt generation | PARTIAL | S fixed escaping/template for canonical path; live resolution affects source and no independent full determinism/equivalence proof. |
| 11.3 | Kernel path denial | PASS | IT/RA/CP ordinary outside-write markers absent with inside positive controls on actual macOS. This is write-path denial only; hardlink gap explicitly fails 3.5/3.9. |
| 11.4 | Descendant inheritance | PASS | RA installed shell/interpreter/nesting/shebang/exec cases and CP recursive RV retain the tested write fence on actual macOS. Does not prove supervision or deny missing capabilities. |
| 11.5 | Apply failure prevents command | PASS | LB `invalidSeatbeltProfileDoesNotExecuteInnerCommand` verifies absent inner marker; CP missing/root workspace also never executes. Result attestation remains PARTIAL separately. |
| 11.6 | Profile injection impossible | PARTIAL | LB five hostile path classes retain actual write denial, S escapes quotes/backslashes and rejects NUL/newline. Finite tests do not prove universal impossibility; path races remain. |
| 11.7 | User paths encoded safely | PARTIAL | S encoding plus LB five actual kernel cases; root/NUL/newline rejected. All input/race classes not exhaustively proven. |
| 11.8 | Malformed input cannot broaden | PARTIAL | LB NUL, retarget, encoded paths and CP startup rejection; no full capability grammar and final path races unresolved. |
| 11.9 | Actual macOS enforcement tests | PASS | Real `/usr/bin/sandbox-exec` through IT/LB/RA/CP; filesystem/network/signal effects recorded. Passing evidence includes observable failures of requested guarantees. |

### 12. Linux acceptance

| ID | Criterion | Verdict | Boundary, bypass and executable evidence |
|---|---|---|---|
| 12.1 | Landlock before untrusted work | PARTIAL | L applies before exec; actual Swift startup strips LD_PRELOAD and prevents constructor marker (linux-swift.log). LP direct helper remains unsafe with hostile loader env; supported-kernel execution unproven. |
| 12.2 | Detect unsupported Landlock/kernel | PASS | LP actual ABI probe gets ENOSYS on `6.10.14-linuxkit`; helper exits 125. Source requires ABI >= 3. |
| 12.3 | Unsupported kernel never unrestricted | PASS | LP `actual-unsupported-kernel-fails-closed`: exit 125 and no inner marker. Does not attest trusted helper initialization on supported hosts. |
| 12.4 | No silent namespace fallback | NOT APPLICABLE | No RV namespaces implemented. Required process/host isolation remains failed. |
| 12.5 | Required seccomp failure closed | NOT APPLICABLE | No RV seccomp implementation or required-seccomp configuration. No syscall policy claimed. |
| 12.6 | Children retain constraints | PARTIAL | L design and LandlockContainmentTests exist; no actual supported-kernel child enforcement run. |
| 12.7 | proc/sys/devices/mounts/sockets/host visibility | FAIL | L handles write-class filesystem only; no read/network/PID/device boundary. Actual Linux attack probes unavailable. |
| 12.8 | Privilege escalation tested | FAIL | `no_new_privs` source is not executable elevation evidence; no real supported-kernel privilege test. |
| 12.9 | CI/container and real host behavior | PARTIAL | LP unsupported Docker kernel fails closed; actual Swift startup/sanitizer/helper lookup and stubbed C setup tests pass. No positive supported-kernel or real-host enforcement evidence. |

### 13. Auditability

| ID | Criterion | Verdict | Boundary, bypass and executable evidence |
|---|---|---|---|
| 13.1 | Which agent | FAIL | CLI/H/A/LOG have no runtime-issued identity event; ID insufficient. |
| 13.2 | Attempted action | PARTIAL | E carries action and hook history may record proposals; CLI descendants have no process execution stream. |
| 13.3 | Effective capabilities | FAIL | No typed runtime capability event or mandatory sink. CP JSONL is test evidence, not production audit. |
| 13.4 | Authorizing policy | FAIL | CLI plan has no identity-bound policy ID/version. |
| 13.5 | Applied sandbox | PARTIAL | A returns mode/family, S source/L mask inspectable; LB proves establishment record can be false. No persisted attested sandbox identity. |
| 13.6 | Denied operations | FAIL | No kernel-denial ingestion/structured event. Absent fixture effects are test evidence only. |
| 13.7 | Allowed operations | FAIL | No production exec audit; agent descendants unobserved. |
| 13.8 | Spawned PID | FAIL | A `Process` PID is not carried into result/event. |
| 13.9 | Child process tree | FAIL | No descendant tracker or tree events; RA child survives return. |
| 13.10 | Event time | FAIL | No runtime execution events/timestamps. Hook event times are a different path. |
| 13.11 | Decision rationale | PARTIAL | E authorization value exists; CLI/H lacks policy rationale and emitted decision. |
| 13.12 | Structured events without secrets; ingestion ready | FAIL | No runtime event model. Harness omits secret values, but production enterprise audit requirement remains absent. |

### 14. Test architecture

| ID | Criterion | Verdict | Boundary, bypass and executable evidence |
|---|---|---|---|
| 14.1 | Unit type/compile tests | PARTIAL | UT/IT and LB validation tests exist; full requested capability/identity language not implemented. |
| 14.2 | Real integration tests | PARTIAL | IT/CP exercise actual macOS; LP real unsupported-kernel rejection only. Supported Linux required. |
| 14.3 | Adversarial bypass suite | PARTIAL | RA/CP/LP dedicated suites and gap reporting added; complete attack/OS coverage remains incomplete per inventory. |
| 14.4 | Permanent regression per discovered bug | PARTIAL | LB/EL regress fixed NUL/env/retarget/replay/cancellation paths; LP regresses descriptor/open failures. Architectural gaps have witnesses or explicit omissions, not fixes. |
| 14.5 | Observable effects, not snapshots alone | PASS | Added tests assert file contents/absence, socket receipt, actual victim exit and marker counts. Linux mocked units explicitly labeled; they do not substitute for kernel proof. |

### 15. Architectural requirements

| ID | Criterion | Verdict | Boundary, bypass and executable evidence |
|---|---|---|---|
| 15.1 | Functional Swift/immutable domain | PARTIAL | D immutable structs/enums and E actor preserved; focused 142 tests pass and product snapshot preflight has 0 failures. Full checkout preflight and broader Swift gate remain red for recorded reasons. |
| 15.2 | Explicit states/strong types/exhaustive enums | PARTIAL | D/A/H typed state/mismatch tests; `EstablishedIsolation` attestation still unsound after wrapper failure. |
| 15.3 | Composition/DI/effects outside policy | PARTIAL | D compile pure; A backend closures and E compose side effects. Host descendants remain outside semantic policy path. |
| 15.4 | Pure deterministic policy compilation | PARTIAL | D pure intent; S/L live path effects; full policy-capability compiler absent. |
| 15.5 | Typed errors | PARTIAL | A/H/E/CLI typed errors and regression cases; helper startup/inner exit still conflated. |
| 15.6 | Concurrency/Sendable/no unnecessary shared state | PARTIAL | E actor and EL concurrency prove per-executor single dispatch; RA separate grants cross-write-denied. Blocking wait and unowned lifecycle remain. |
| 15.7 | Fail-closed security semantics | PARTIAL | Covered setup errors prevent markers and consumed authorization cannot replay. Default-allow authority, attestation and supervisor failures preclude global guarantee. |

### 16. Definition of done

| ID | Criterion | Verdict | Boundary, bypass and executable evidence |
|---|---|---|---|
| 16.A | Repo rw, SSH unreadable, outside unwritable | FAIL | RA/CP SSH fixture readable; RA preexisting hardlink mutates outside source. Ordinary write fence is insufficient. |
| 16.B | No network including children | FAIL | CP actual child-shell/interpreter IPv4/IPv6/Unix/DNS-packet connections succeed without grant. |
| 16.C | Wrappers/children cannot escape all restrictions | PARTIAL | RA/CP retain write fence across wrappers/recursive RV; hardlinks and missing capability/lifetime boundaries remain. |
| 16.D | Failed isolation never executes | PARTIAL | LB/CP/LP marker tests cover important failures. Linux dynamic-helper pre-main execution, trusted installation/races and startup handshake not fully proven. |
| 16.E | Concurrent agents cannot acquire authority | FAIL | RA denies cross-workspace writes, but unrestricted reads/network/processes and no identities refute complete authority separation. |
| 16.F | Identity + structured execution evidence | FAIL | CLI/H/A lack identity issuance and structured runtime audit. |
| 16.G | Explain X/Y/Z/P/S | FAIL | No authenticated X, policy P or attested/persisted sandbox S; CLI warning is scope disclosure only. |
| 16.H | Important negative guarantees automated | PARTIAL | Stronger effect-based write/startup/concurrency tests added; default-deny read/network/host/identity/lifetime guarantees fail or remain untested. |

## Reproduction commands and completion notes

Commands are run from the repository root. Swift builds/tests must be serialized. `--filter` limits the claim to the selected suites; no full-tree certification is implied.

```sh
Scripts/swift-6.4 test --filter 'RVIsolationTests|IsolationPlanTests|OpenCodeCommandTests|installSh_'
Scripts/swift-6.4 test --filter 'RVIsolationTests|RVDomainTests|RVCLITests' --skip CHookPipeTests.cHookProof
Scripts/gate.sh RVIsolationTests RVDomainTests RVCLITests
python3 -B Scripts/runtime-cli-proof.py --cli .build/security-audit/stage/rv
python3 -B Scripts/isolation-linux-adversarial.py --output .build/security-audit/linux/reviewed
Sources/rv-c/tests/run.sh
```

See the append-only [phase-10 handoff completion notes](../rv-agent/handoffs/phase-10-contained-host-launch.md) for exact commands actually observed, files changed, review corrections and final verification results. [Runtime boundary](runtime-boundary.md) documents the implemented architecture, trusted/untrusted components, OS-vs-RV checks and assumptions. [Adversarial inventory](adversarial-inventory.md) records each attempted technique, result and explicit omission. The boundary document classifies remaining work as release blockers, important hardening and future enhancements.

Independent code/security review approved the bounded hardening changes without remaining findings; that review does not certify the missing release guarantees. A real installed native OpenCode binary also passed staged C-frontend `--version` startup (exit 0, 1.18.31; [smoke evidence](evidence/opencode-smoke.json)). No interactive/model-backed OpenCode session was exercised; adversarial proofs used synthetic executables. The minimal environment can break shebangs requiring interpreters outside `/usr/bin:/bin`; explicit runtime capability/configuration support is future work. No release or commit was produced by this pass.

No secrets, wallet, MCP credential or enterprise authority should depend on this isolation slice as a complete security boundary until the blockers have executable negative evidence on both supported OSes.
