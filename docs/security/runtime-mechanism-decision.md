# RV runtime mechanism decision — blocked P0s

Last updated: 2026-10-12. Audit base for this record: clean `main` at `04b4740cb9d8638d41781f6cc660ba8b84a8a6e0`. **Release status: NOT SATISFIED.** This file records the four P0 mechanism decisions that cannot be closed with a contained code fix on this base, the safe partial that is in place for each, and the exact evidence required to close each one. It is the `runtime-mechanism-decision.md` record proposed by gate U02 in [the remediation plan](runtime-remediation-plan.md). It is not evidence that the blocked guarantees hold.

The original audit was performed against a dirty tree (`854e691` plus uncommitted hardening). Every file reference below was re-checked on clean `main` at `04b4740c` and holds there; verdicts quoted from [the acceptance matrix](runtime-acceptance.md) describe the audited tree and are consistent with the code positions on `main`, but were not re-run for this docs-only change. Where the audit evidence and `main` could differ (for example the exact `sysctl` MIB set that broke `ld`/`zsh`), this record says so rather than assuming the dirty-tree result.

Tracking issues: [ISO-01](https://github.com/christopherkarani/rv/issues/396), [ISO-02](https://github.com/christopherkarani/rv/issues/397), [ISO-03-Linux](https://github.com/christopherkarani/rv/issues/398), [ISO-04](https://github.com/christopherkarani/rv/issues/399).

| P0 | Invariant in one line | Safe partial in place | Blocked on |
|---|---|---|---|
| ISO-01 | Contained code cannot read host argv/env via `sysctl` | Narrowing refused: it broke `ld`/`zsh`; blanket allow remains, documented as open | Proved `sysctl-name` allowlist that keeps the toolchain working |
| ISO-02 | Supervisor `SIGKILL` still ends descendant authority | Process-group `SIGKILL` + copy-back on close, supervisor alive only | Independent guardian process |
| ISO-03-Linux | Linux enforces the contained plan or refuses | Refusal: `containedGuaranteesUnsupported` before exec | Landlock ABI >= 3 host with positive enforcement |
| ISO-04 | Every descendant exec re-enters semantic authorization | Inherited Seatbelt + one brokered command/GET | Endpoint Security vs brokered-exec feasibility decision |

## ISO-01 — Host argv/env readable via `sysctl` (R4)

**Invariant.** A contained (Seatbelt) process must not be able to read the argv or environment of host processes outside its sandbox. Process-visibility must be limited to the sandbox itself; `sysctl` reads that expose other processes (`KERN_PROC`, `KERN_PROCARGS`, `KERN_PROCARGS2`, and equivalents) must be denied.

**Evidence on `main`.** [SeatbeltProfile.swift](../../Sources/RVIsolation/SeatbeltProfile.swift) line 967 emits a blanket `(allow sysctl-read)` with no `sysctl-name` restriction, so a contained process can query host process argv/env via `sysctl`. [runtime-boundary.md](runtime-boundary.md) line 58 documents the blanket allow. Acceptance criterion 5.2 (Cannot inspect unrelated processes) is FAIL with no actual inspection probe, and [the adversarial inventory](adversarial-inventory.md) lists unrelated-process inspection as not tested sufficiently. A per-MIB narrowing attempt broke `ld` (dynamic linker) and `zsh` startup, which depend on `sysctl` MIBs during launch; that narrowing was not landed, so the blanket allow remains on clean `main`. The failing MIB set was observed on the dirty audit tree and must be re-derived on `main` before any new attempt.

**Why blocked.** Seatbelt `sysctl-read` filtering is coarse. Denying the proc MIBs while keeping every MIB the toolchain baseline needs (dynamic linker, `zsh`, `swiftc`/`clang`, SwiftPM) requires an enumerated allowlist proved against the real toolchains. Shipping the naive per-MIB fix breaks normal launches, so no safe narrowed profile exists on this base.

**Safe partial in place.** None that closes the invariant. The narrowing was refused because it broke `ld`/`zsh`, and the blanket `(allow sysctl-read)` is retained and documented as a known gap. Sanitizing the direct child's environment at spawn does not mitigate host argv/env readable through `sysctl`. This is a refusal to ship a broken fix, not a mitigation.

**Evidence required to close.**

1. A narrowed profile in `SeatbeltProfile.swift` with explicit `sysctl-name` rules that deny the proc-argv/env MIBs.
2. macOS probes showing a contained process is denied reading a synthetic host process's argv/env via `sysctl`, with a positive control that the probe ran.
3. Toolchain regression evidence (`ld`, `zsh`, `swiftc`/`clang`, SwiftPM linking) passing inside the narrowed profile via the relevant Seatbelt test suites — the case that broke previously.
4. Acceptance 5.2 and this file updated with the proved MIB set and OS/kernel versions. A profile-text snapshot alone does not close this P0.

## ISO-02 — Supervisor `SIGKILL` orphans the process tree

**Invariant.** Workspace authority must end when the supervisor dies for any reason, including `SIGKILL`. No descendant may retain workspace write authority, the mounted private volume, or admission capability after the RV supervisor process is killed.

**Evidence on `main`.** [runtime-boundary.md](runtime-boundary.md) line 73: "If the RV process itself is killed with SIGKILL, this cleanup does not run, and the group can keep the mounted volume." Line 85 restates that pipe cleanup does not run, and line 93 lists the gap as a release blocker. Acceptance 5.7 and 9.11 are FAIL; the retained CLI proof includes "child authority after supervisor SIGKILL" as a GAP witness. Cleanup in [SessionSupervisor.swift](../../Sources/RVIsolation/SessionSupervisor.swift) (`terminateSession`, `stopOwnedSession`) and [ProcessGroupRecovery.swift](../../Sources/RVIsolation/ProcessGroupRecovery.swift) (`ProcessGroupRecovery.terminate`) only runs when a surviving RV process executes it. No independently running guardian exists on this base.

**Why blocked.** The supervisor performs cleanup over its own process groups, and a `SIGKILL`ed supervisor cannot run any cleanup. Closing this requires a guardian process that survives the supervisor, detects its death (lease/heartbeat or parent-death signal), then kills the recorded process groups, closes admission pipes, and unmounts the workspace volume. The guardian's own death and PID-reuse safety (the leader start-time proof in [ProcessGroupRecovery.swift](../../Sources/RVIsolation/ProcessGroupRecovery.swift)) also need analysis, per remediation gate U02 question 4. That is a new trusted component, not a contained fix.

**Safe partial in place.** Normal lifetime is covered while the supervisor lives: on cancellation, runtime return, or workspace close, RV `SIGKILL`s the owned process group and waits until it is empty, then copy-back publishes the workspace once on close. `setsid`/`setpgid` are denied in the Seatbelt profile so descendants cannot leave the group during normal lifetime. Only the supervisor-`SIGKILL` case is open, and it is documented as outside the boundary rather than claimed closed.

**Evidence required to close.**

1. A guardian design and implementation whose lifetime is independent of the supervisor, with its own death behavior specified.
2. A macOS probe that starts a contained runtime with a background or double-forked descendant, `SIGKILL`s the supervisor, and observes the descendant dead, admission pipes closed, and the volume no longer writable by the orphan — with a positive control that the descendant was alive before the kill.
3. PID-reuse safety evidence (recorded pgid plus leader start time) so guardian cleanup cannot signal an unrelated reused group.
4. Acceptance 5.7/9.11 and this file updated to the proved result. Cleanup tests that keep the supervisor alive do not close this P0.

## ISO-03-Linux — Landlock enforcement unproven

**Invariant.** A Linux contained launch must enforce the same guarantees as the macOS contained plan — workspace-scoped filesystem access, denied network, denied signals to outside processes — before any untrusted code runs, or it must refuse to launch. A weaker sandbox must never be substituted silently.

**Evidence on `main`.** [LandlockApply.swift](../../Sources/RVIsolation/LandlockApply.swift) (`prepareLandlock`) returns `containedGuaranteesUnsupported` for every contained plan and does not exec. [LandlockRuleset.swift](../../Sources/RVIsolation/LandlockRuleset.swift) and `landlock_apply.c` implement only write-class bits (including `REFER`/`TRUNCATE`), require ABI >= 3, and install no read/execute/network rules, namespaces, seccomp, or PID controls. [runtime-boundary.md](runtime-boundary.md) line 60 records that actual Landlock enforcement was not available on the tested kernel, and line 96 lists Linux enforcement as a release blocker. Acceptance 12.1/12.6 are FAIL/PARTIAL for positive enforcement; retained evidence (`evidence/linux-results.json`, `evidence/linux-environment.json`) shows kernel `6.10.14-linuxkit` returning `ENOSYS` with `CONFIG_SECURITY_LANDLOCK` unset — rejection proved, enforcement not.

**Why blocked.** No available Linux host has Landlock ABI >= 3 with `CONFIG_SECURITY_LANDLOCK` enabled, so positive enforcement cannot be proved. The only kernel exercised so far cannot apply Landlock at all and can prove rejection only. Docker's own namespaces/seccomp in the fixture belong to Docker and are not RV evidence.

**Safe partial in place.** Refusal. Linux contained launch returns `containedGuaranteesUnsupported` before exec, the write-only helper is not used as a fallback, and unsupported-kernel fail-closed behavior is proved. No weaker sandbox is offered in its place.

**Evidence required to close.**

1. A named Linux host or CI job with Landlock ABI >= 3, recording kernel version, architecture, and `CONFIG_SECURITY_LANDLOCK` state.
2. Positive enforcement probes on that host (declared access allowed; credential reads, aliases, traversal, rename, mount escape, child bypass denied; network/signal limits enforced), each with a positive execution control, via `Scripts/isolation-linux-adversarial.py --require-enforcement` and the Linux Swift containment suites.
3. Continued fail-closed proof on a deliberately incapable kernel.
4. Acceptance section 12 and this file updated with the host evidence. Landlock-stubbed C tests and Docker-provided isolation do not close this P0.

## ISO-04 — Descendants bypass semantic authorization

**Invariant.** Every descendant execution must cross RV semantic authorization (`AgentAuthorization.decide`) before user code runs. Approving the initial agent argv must not approve arbitrary descendant behavior; a child that never re-enters RV policy must not gain effectful authority beyond inherited kernel restrictions.

**Evidence on `main`.** [runtime-boundary.md](runtime-boundary.md) line 31: "`LocalExecutor.perform` is an independent authorized-action API. It is not called for the OpenCode process or its tools. Agent-created descendants do not re-enter `perform`, policy evaluation or approval." [LocalExecutor.swift](../../Sources/RVIsolation/LocalExecutor.swift) (`perform`) authorizes only the brokered path — one shell command or one HTTPS GET over the admission pipes, decided by `AgentAuthorization.decide` — while direct `fork`/`execve` descendants never take that path. Acceptance section 7 is FAIL (7.2/7.4/7.7), 8.2 and 8.4 are FAIL, and 13.9 (Child process tree) is FAIL with no descendant tracker. The remediation plan's "Execution ownership" decision requires every child execution to cross an unavoidable RV authorization boundary and states that inherited restrictions, hooks, PATH wrappers, and post-exec observation alone do not satisfy it.

**Why blocked.** Seatbelt can inherit kernel restrictions to descendants, but it cannot make each descendant `exec` re-enter RV semantic authorization. Closing this needs a feasibility decision between (a) Apple Endpoint Security `AUTH_EXEC` mediation via an entitled system extension and (b) a brokered-exec design that funnels all execution through the RV broker. Neither exists on this base: there is no Endpoint Security client, entitlement, or install path, and no broker descendants are forced through (`fork`/`execve`/`posix_spawn` remain directly available inside the profile). Either option is a platform-mechanism program (remediation gate U02 question 1), not a contained fix.

**Safe partial in place.** Kernel inheritance plus a narrow broker, honestly scoped. Descendants inherit the deny-default Seatbelt profile (workspace-only writes, loopback-only networking, same-sandbox signals), and exactly one brokered shell command or one HTTPS GET per admission-pipe request is semantically authorized, spawned by RV as a copy under the same profile. Direct descendants are kernel-contained but not semantically authorized; that distinction is documented rather than claimed as mediation.

**Evidence required to close.**

1. A recorded mechanism decision (Endpoint Security vs brokered-exec) with deployability (entitlements, install, OS versions), bypass analysis (native spawn APIs, interpreter syscalls, IPC services, recursive RV), and failure behavior.
2. Probes showing an unapproved descendant exec is blocked before user code runs (no marker written), with a positive control that an approved exec runs, across shell, interpreter, nested shell, shebang, and `posix_spawn` paths on macOS.
3. Attribution evidence that each mediated exec carries runtime/session/execution identity, and that revocation or expiry stops later descendant dispatch.
4. Acceptance sections 7/8/13 and this file updated to the proved result. Seatbelt inheritance, PATH wrappers, hooks, or post-exec observation alone do not close this P0.

## Decision

None of the four P0s is fixed by this change, and none is claimed satisfied. The safe behavior on `main` — refusal on Linux, documented known gaps on macOS — is preserved, and each P0 stays open in its tracking issue until the evidence listed above exists. A platform mechanism that cannot pass its probes must keep strict launches closed (`unsupportedGuarantee`) rather than gaining a weaker successful mode.
