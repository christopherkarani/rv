# Phase 04 — macOS Seatbelt apply (probe command, fail closed)

## 1. Phase

**Name:** Apply a compiled `IsolationPlan` through a Seatbelt `IsolationBackend`

**Master-plan reference:** `RV_Agent_Implementation_Plan_v2.docx` Phase 2 — OS-isolated launch boundary (first implementation slice only: AGENT-007 backend + AGENT-009 Seatbelt inheritance). Does **not** start Landlock (AGENT-008), `rv <agent>` CLI, OpenCode launch, or the executor.

**Previous phase:** `docs/rv-agent/handoffs/phase-03-isolation-values.md` — planning-verified Complete on 2026-09-20.

## 2. Status

Implemented

## 3. Objective

Turn an `IsolationPlan` into an **established** enforcement record by applying macOS Seatbelt to a real process, and fail closed when a requested `.contained` plan cannot be established. Prove the first-slice guarantees against the kernel: writes outside the workspace are blocked, and a child of that process does not escape.

## 4. Why this phase exists

Phase 03 compiled isolation **intent**. `IsolationPlan.mode == .contained` still means “launch must establish these guarantees,” not “an agent is sandboxed.” The coding-agent close of 03 said the next phase is the one that actually applies OS containment. That is this file.

Master-plan Phase 2 also wants Landlock and `rv <agent>` in the same phase. The tree has no launcher, no adapter, and no Linux backend. Shipping Seatbelt + Landlock + CLI together would let a green compile hide a missing kernel proof. The smallest honest unit is: **consume `IsolationPlan`, apply Seatbelt on Darwin, fail closed everywhere else, record established mode only after the process is actually started under the profile.**

This slice unlocks:

```text
IsolationPlan                         (intended; Phase 03; stays pure)
        ↓ IsolationBackend.prepare    (profile / validation; no “established”)
IsolatedLaunchRequest
        ↓ IsolationBackend.run        (Process effect)
IsolatedRunResult.established         (only after successful spawn)
        ↓ later (NOT this phase)
rv <agent> / OpenCode / Landlock / executor
```

**Prepare is not establishment. A compiled profile is not a sandbox. `IsolationPlan.mode` is never rewritten to claim the kernel applied it.**

## 5. Current repository state

Inspected after Phase 03 verification on `feat/agent-isolation-values` (`b908714`).

### 5.1 What exists

- Phase 01: `AgentRequest` → `normalizeAgentRequest` → `ProposedAction`
- Phase 02: `AgentAuthorization.decide` → allowed / pending / denied
- Phase 03: `compileIsolationPlan` → `IsolationPlan` / `EnforcementMode` / `IsolationGuarantees` (`Sources/RVDomain/Isolation.swift`)
- `WorkingDirectory` / `RepositoryRoot` — nonempty path newtypes
- `Process()` only in setup `launchctl` / `systemctl`
- CLI still has no `rv agent` / `rv opencode` (`Sources/RVCLI/RV.swift`)
- **Zero** `IsolationBackend`, Seatbelt profile, `sandbox-exec` wrapper, or Landlock types

### 5.2 What Phase 03 made true (do not reopen)

- Observed / mediated compile to those modes only
- Contained without workspace fails `containedRequiresWorkspace`; `RepositoryRoot` cannot substitute
- Contained first-slice guarantees: `writesLimited(to: workspace)` + descent `.inherited` + network `.unrestricted`
- `IsolationPlan` / `IsolationGuarantees` production construction is compile or the internal first-slice factory
- Compile does not call `decide`

### 5.3 Semantic vs OS roots (still do not merge)

| Boundary | Type | Meaning |
| --- | --- | --- |
| Semantic in-repo / out-of-repo | `RepositoryRoot` + `FilesystemScope` | `ActionPolicyEngine` filesystem wall |
| OS write containment | isolation workspace (`WorkingDirectory`) | What Seatbelt must limit writes to |

`AllowedAction` does not sandbox a process. A Seatbelt apply does not skip `AgentAuthorization.decide`.

### 5.4 Master-plan conflicts (smallest adjustments)

1. **AGENT-007 says “wire Seatbelt into `rv <agent>` launch.”** There is no `rv <agent>` command. This phase ships the **backend + apply** that later launch will call. The CLI stays unchanged.
2. **AGENT-008 Landlock is a later handoff.** Same first-slice *intent*; different kernel. Do not add a Landlock case or a “sandbox works” flag.
3. **No existing Seatbelt types to “wire.”** This phase introduces `RVIsolation` and the Seatbelt backend.
4. **Do not inhabit `stronglyIsolated` / Tart / Apple Container.**
5. **`SafetyLevel` is still not `EnforcementMode`.**
6. **`ExecutingCommand` is still not a capability.** Do not reuse it as the sandboxed argv. Use `IsolatedCommand`.

## 6. Existing components to reuse

Must reuse:

- `compileIsolationPlan` / `IsolationPlan` / `EnforcementMode` / `IsolationGuarantees` from `Sources/RVDomain/Isolation.swift`
- `WorkingDirectory` as the containment workspace
- `RepositoryRoot` as optional recorded metadata only
- Swift Testing style from `Tests/RVDomainTests/IsolationPlanTests.swift` (exhaustive switches, fail-closed tables, operator probe)

Must not reuse / must not touch:

- `AgentAuthorization.decide` — apply does not authorize
- `HostNativeAsk.hookBound`
- `PolicyGate`
- `SafetyLevel`
- Hook codecs, `RV.swift` subcommands, `RVService` daemon launch
- external Seatbelt/Landlock implementations — do not copy them into this repo
- `ExecutingCommand` / `AllowedAction` as a launch argv

## 7. Architecture for this phase

```text
IsolationPlan
        │
        │  IsolationBackend.prepare   (pure enough: path resolve + SBPL)
        ▼
IsolatedLaunchRequest
  plan + command + family
  seatbelt profile present only for contained+seatbelt
  ✕ no EstablishedIsolation
        │
        │  IsolationBackend.run       (Process)
        ▼
Result<IsolatedRunResult, IsolationApplyError>
  success ⇒ EstablishedIsolation minted
  failure ⇒ no established contained record
```

Two complementary facts stay separate:

```text
AgentAuthorization          IsolationPlan           EstablishedIsolation
(semantic permit)           (OS intent)             (OS fact after spawn)
      │                           │                         │
      └──────── later runtime ────┴─────────────────────────┘
```

## 8. Type model

New module **`RVIsolation`** (library + `RVIsolationTests`). Domain stays free of `Process`, SBPL, and `#if os`.

`Package.swift`: add `RVIsolation` to `coreLibraryTargets` (depends on `RVDomain` only), `coreProducts`, and `coreTestTargets` (`RVIsolationTests` depends on `RVIsolation` only — one module dep, preflight-safe).

CI: add `RVIsolationTests` to `.github/workflows/release.yml` `Scripts/gate.sh` list. Darwin PR hook-grade job (`.github/workflows/pr.yml`) must run `Scripts/swift-6.4 test --filter RVIsolationTests` so Seatbelt kernel tests are not Linux-only-skipped. Linux `swift test` already runs the new target unfiltered — Linux tests must compile and the fail-closed cases must run.

### `IsolationBackendFamily`

```text
enum IsolationBackendFamily {
    case none
    case seatbelt
}
```

- **Represents:** Which apply path ran or will run.
- **Invariant:** Closed. No `.landlock` this phase. No `.unavailable` family — unavailability is an **error**, not a mode.
- **Who constructs:** backends / tests.

### `IsolationApplyError`

Minimum closed cases:

| Case | When |
| --- | --- |
| `backendUnavailable` | Contained requested and this backend cannot establish it (Linux `platform()`, injected unavailable, missing `/usr/bin/sandbox-exec`) |
| `backendMismatch` | `run` received a request whose `family` is not this backend’s family |
| `workspaceMustBeAbsolute` | Contained workspace path does not start with `/` |
| `workspaceDoesNotExist` | Contained workspace is not an existing directory |
| `workspacePathUnresolvable` | `realpath` / symlink resolve fails |
| `workspacePathUnsafe` | Path contains newline or NUL (cannot be an honest SBPL string) |
| `containedGuaranteesUnsupported` | Plan claims `.contained` but guarantees are not first-slice (unrestricted writes or `.notInherited`) |
| `profileNotApplicable` | `compileSeatbeltProfile` asked for observed/mediated |
| `processSpawnFailed` | `Process` failed to start (not a non-zero child exit) |

Do not add `downgradedToObserved`.

### `IsolatedCommand`

```text
struct IsolatedCommand {
    var executable: String
    var arguments: [String]
}
```

- **Represents:** Absolute argv the backend will start (the inner command, not `sandbox-exec`).
- **Invariant:** `executable` is nonempty and absolute (`hasPrefix("/")`). Empty / relative → fail at `prepare` (reuse `workspaceMustBeAbsolute` only for the workspace; add `commandExecutableMustBeAbsolute` if you want a distinct case — preferred).
- **Who constructs:** tests now; later CLI/adapter.
- **Not** `ExecutingCommand`, **not** `AllowedAction`.

### `SeatbeltProfile`

```text
struct SeatbeltProfile {
    var source: String
}
```

- **Represents:** SBPL text compiled from a contained plan.
- **Who constructs:** `compileSeatbeltProfile` only (internal init).
- **Who consumes:** Seatbelt `prepare` / tests / Darwin `run`.

### `compileSeatbeltProfile`

```text
func compileSeatbeltProfile(_ plan: IsolationPlan) -> Result<SeatbeltProfile, IsolationApplyError>
```

Rules:

| Plan | Result |
| --- | --- |
| `.observed` / `.mediated` | `.failure(.profileNotApplicable)` |
| `.contained` with first-slice guarantees + absolute resolvable workspace | SBPL below |
| `.contained` with wrong guarantees | `.failure(.containedGuaranteesUnsupported)` |

First-slice SBPL (lock this shape — it matches the guarantees):

```text
(version 1)
(allow default)
(deny file-write*
    (require-not (subpath "RESOLVED_WORKSPACE")))
```

- **Allow-default** is honest: first-slice does not jail the process. It limits **writes**.
- Do **not** emit `(deny default)`. That would claim a full jail.
- Do **not** emit network deny / `deny mach-lookup` / read limits.
- Escape `\` → `\\` and `"` → `\"` inside the quoted subpath. Reject newline / NUL (`workspacePathUnsafe`).
- Resolve symlinks (`URL(fileURLWithPath:).resolvingSymlinksInPath()`) **before** interpolation. `/tmp/...` must become `/private/tmp/...` when that is the real path.
- Write-limit path is the **workspace**, even when `plan.repositoryRoot` differs.
- `compileSeatbeltProfile` is available on **all** platforms (pure string). Linux tests inspect text; they do not run `sandbox-exec`.

### `IsolatedLaunchRequest`

```text
struct IsolatedLaunchRequest {
    var plan: IsolationPlan
    var command: IsolatedCommand
    var family: IsolationBackendFamily
    // internal: SeatbeltProfile? for family == .seatbelt
}
```

- **Represents:** A prepared launch. **Not established.**
- **Invariants:** `family == .seatbelt` ↔ profile present. `family == .none` ↔ no profile and plan.mode is `.observed` or `.mediated`.
- **Who constructs:** `prepare` only (internal init).

### `EstablishedIsolation`

```text
struct EstablishedIsolation {
    var mode: EnforcementMode
    var family: IsolationBackendFamily
}
```

- **Represents:** What was actually applied after a successful **spawn**.
- **Invariants (factory, not public memberwise):**
  - `.contained` ↔ `family == .seatbelt`
  - `.observed` / `.mediated` ↔ `family == .none`
  - never `.contained` + `.none`
  - never `.observed` / `.mediated` + `.seatbelt`
- **Who constructs:** `run` after `Process` starts. Internal init + factory.
- **Who consumes:** tests now; session/audit later.

A non-zero **child exit** is not an apply failure. Denied writes return `IsolatedRunResult` with `established.contained` and `exitStatus != 0`.

### `IsolatedRunResult`

```text
struct IsolatedRunResult {
    var established: EstablishedIsolation
    var exitStatus: Int32
}
```

### `IsolationBackend`

```text
struct IsolationBackend {
    var family: IsolationBackendFamily
    var prepare: (IsolationPlan, IsolatedCommand) -> Result<IsolatedLaunchRequest, IsolationApplyError>
    var run: (IsolatedLaunchRequest) -> Result<IsolatedRunResult, IsolationApplyError>
}
```

Sendable closures. Factories on `IsolationBackends`:

| Factory | Family | Contained prepare | Contained run |
| --- | --- | --- | --- |
| `seatbelt()` | `.seatbelt` | compile profile | Darwin: `/usr/bin/sandbox-exec -p PROFILE <command>`. Non-Darwin: `backendUnavailable` |
| `unavailable()` | `.none` | contained → `backendUnavailable`. observed/mediated → request with `.none` | observed/mediated spawn unsandboxed; contained requests → `backendMismatch` or `backendUnavailable` |
| `platform()` | Darwin: `seatbelt()`. Else: `unavailable()` | as above | as above |

`run` must reject `request.family != backend.family` (`backendMismatch`).

`run` for Seatbelt on Darwin:

1. Confirm `/usr/bin/sandbox-exec` exists; else `backendUnavailable`
2. Start `Process` with executable `/usr/bin/sandbox-exec`, arguments `["-p", profile.source, command.executable] + command.arguments`
3. If workspace is present, set `currentDirectoryURL` to the resolved workspace
4. Inherit environment (secrets broker is later)
5. Drain or null stdout/stderr so the pipe cannot deadlock
6. `waitUntilExit`
7. On successful spawn: `EstablishedIsolation` mode equals `plan.mode` (contained first-slice), family `.seatbelt`, plus the child’s `terminationStatus`
8. Spawn failure (never started): `processSpawnFailed` — **no** `EstablishedIsolation`

`run` for `.none`: start `command.executable` directly (no `sandbox-exec`). Established mode equals the observed/mediated plan mode.

Do **not** wrap observed/mediated in `sandbox-exec`.

## 9. Functional boundaries

| Layer | Allowed |
| --- | --- |
| Domain | unchanged compile; no Process, no SBPL, no `#if os` |
| RVIsolation pure | path resolve, SBPL compile, `prepare`, factories |
| RVIsolation effect | `run` via `Foundation.Process` |
| State transitions | intended plan → prepared request → established result |
| Platform | `#if os(macOS)` only in RVIsolation run/path that invokes `sandbox-exec`. Profile compile stays portable |
| Permitted mutable state | local vars, the child `Process` |

Do not call `AgentAuthorization.decide` from prepare/run. Do not import `RVEngine`. `RVIsolation` depends on `RVDomain` only.

## 10. Exact implementation work

1. Add the `RVIsolation` target + `RVIsolationTests` in `Package.swift` as specified in §8.
2. Implement types + `compileSeatbeltProfile` + `IsolationBackends` in `Sources/RVIsolation/` (two files is enough: apply types/backend, Seatbelt profile).
3. Make `EstablishedIsolation` / `IsolatedLaunchRequest` / `SeatbeltProfile` production construction go through prepare/run or an internal factory so “contained + family none” cannot be minted from `RVEngine` / `RVHooks` / `RVCLI`.
4. Tests in `Tests/RVIsolationTests/`:
   - **All platforms** (`IsolationApply` suite): edges 1–11 in §16
   - **Darwin only** (`SeatbeltContainment` suite, `#if os(macOS)`): kernel write + inheritance proofs
5. Wire CI so Darwin actually runs `RVIsolationTests` (release.yml + pr.yml hook-grade). Linux already will.
6. Do **not** add Landlock, CLI `agent`/`opencode`, OpenCode spawn, `ExecutableAction`, or an `established` field on `IsolationPlan`.
7. Do **not** edit `Isolation.swift` except a comment pointer if useful. Prefer zero Domain edits.
8. Run filters in §17.

## 11. Files likely to change

**New:**

- `Sources/RVIsolation/IsolationApply.swift`
- `Sources/RVIsolation/SeatbeltProfile.swift`
- `Tests/RVIsolationTests/IsolationApplyTests.swift`
- `Tests/RVIsolationTests/SeatbeltContainmentTests.swift`

**Existing:**

- `Package.swift` — new library + test target
- `.github/workflows/release.yml` — add `RVIsolationTests` to the `gate.sh` list
- `.github/workflows/pr.yml` — Darwin hook-grade job runs `Scripts/swift-6.4 test --filter RVIsolationTests`

**Do not edit:** `Sources/RVDomain/Isolation.swift` (unless a one-line doc comment), `AgentAuthorization.swift`, `HostNativeAsk.swift`, `PolicyGate.swift`, `RV.swift`, `SafetyLevel.swift`.

## 12. Architecture constraints

- Functional core, imperative shell: SBPL compile is a value transform; `Process` stays in `run`.
- Illegal states unrepresentable: no `contained: Bool`; no established contained without family `.seatbelt`; no Landlock case; no “contained-if-possible.”
- Domain stays free of Process, Seatbelt, Landlock, and host JSON.
- Isolation apply does not authorize actions; `AgentAuthorization` does not apply isolation.
- First-slice **established** contained guarantees remain write-limit + inherit only. Do not promise network, read-limit, or secret-path OS blocks.
- Seatbelt and Landlock are **not equivalent**. This phase has one backend family.
- Fail closed: contained + no backend ⇒ error, never `.observed` / `.mediated`.
- `IsolationPlan.mode` stays intended. Only `EstablishedIsolation` may be spoken of as applied.
- Swift 6 / `Sendable`. No `@unchecked Sendable`.
- Do not add executor or adapter types.

## 13. Security invariants

- A requested `.contained` plan that cannot be established produces **no** `EstablishedIsolation` and **no** unsandboxed child started “anyway.”
- `EstablishedIsolation.contained` is minted only after `sandbox-exec` successfully **starts** the child on Darwin.
- Observed / mediated apply must not invoke `sandbox-exec` and must not report `.contained`.
- Write-limit path is the workspace, not `RepositoryRoot`.
- Descent is inherited: a `/bin/sh -c` child of the sandboxed process is still write-limited.
- Network unrestricted stays explicit in the profile (no network deny) so later code cannot assume “contained ⇒ no network.”
- `AllowedAction` is unchanged and still not executable.
- Profile text is compiled from the plan; it is not loaded from the user, the network, or another repo.

Known first-slice holes (document, do not “fix” by over-claiming):

- Symlink-out-of-workspace writes are not in the contract
- Reads, network, mach, and tty are unrestricted
- TOCTOU between exist-check and spawn is accepted
- This is not an OpenCode session

## 14. Enforcement guarantee

| Mode | This phase |
| --- | --- |
| observed | Can be **established** as `.none`: process runs unsandboxed. Honest. |
| mediated | Same as observed at the OS layer. Semantic RV is still a later composition. |
| contained | **Established on Darwin** via Seatbelt first-slice profile. **Not established** on Linux / unavailable — fail closed. No agent host is launched |

Limitations (must stay documented):

- No Landlock
- No `rv <agent>` / OpenCode
- Network is unrestricted even when contained is established
- Reads outside workspace are not blocked
- Semantic deny/allow still happens only in `AgentAuthorization`
- Current product remains hook-grade for hosts; this phase only sandboxes **probe commands** the tests (and later launch) pass in

## 15. Failure behavior

| Input | Outcome |
| --- | --- |
| contained + `platform()` on Linux / `unavailable()` | `backendUnavailable`, no plan rewrite, no process |
| contained + Seatbelt, missing `sandbox-exec` | `backendUnavailable` |
| contained + relative workspace | `workspaceMustBeAbsolute` |
| contained + missing directory | `workspaceDoesNotExist` |
| contained + insufficient guarantees (testable mint) | `containedGuaranteesUnsupported` |
| contained + Seatbelt Darwin, spawn ok, write denied | success result, `exitStatus != 0`, **established contained** |
| observed / mediated | unsandboxed run, established matches plan, family `.none` |
| prepare/run failure for contained | never return established observed “so the session can start” |

## 16. Tests

List these edges in the test file **before** production code.

### All platforms — `IsolationApply`

1. `compileSeatbeltProfile` on a compiled contained `/workspace` plan contains `(version 1)`, `(allow default)`, `file-write*`, `require-not`, and `subpath` with the resolved workspace; does **not** contain `deny default`; does **not** contain a network deny
2. contained plan with workspace `/ws` and `RepositoryRoot` `/repo` → profile subpath is `/ws` (resolved), not `/repo`
3. `compileSeatbeltProfile` on observed (and mediated) → `profileNotApplicable`
4. `unavailable().prepare(contained)` → `backendUnavailable` (not a successful observed request)
5. `unavailable().prepare(observed)` then `run` → established `.observed`, family `.none`, no `sandbox-exec` in the argv
6. `unavailable().prepare(mediated)` then `run` → established `.mediated`, family `.none`
7. contained + relative workspace (`"repo"`) → `workspaceMustBeAbsolute`
8. contained + absolute workspace that does not exist → `workspaceDoesNotExist`
9. `EstablishedIsolation` factory rejects contained+`.none` and observed+`.seatbelt`
10. apply / prepare / run do not call `AgentAuthorization.decide` (no import of a decide test double; a comment + `rg` in verification is enough — do not add Domain coupling)
11. `platform()` contained prepare on non-Darwin is `backendUnavailable` (`#if !os(macOS)` or inject by calling `unavailable()` plus a portable `platform()` assertion)

### Darwin kernel — `SeatbeltContainment` (`#if os(macOS)`)

Create a unique temp workspace via `FileManager`; pass a **resolved absolute** `WorkingDirectory`. Clean up in `defer`. Use `/usr/bin/touch` and `/bin/sh` only as probe argv.

12. contained + `seatbelt()`: `touch` **inside** workspace → `exitStatus == 0`, file exists, `established.mode` is `.contained` with first-slice guarantees, family `.seatbelt`
13. contained + `seatbelt()`: `touch` **outside** workspace (sibling path, not `/tmp` guesswork) → `exitStatus != 0`, file **absent**, `established` still `.contained` / `.seatbelt`
14. contained + `seatbelt()`: `/bin/sh -c '/usr/bin/touch OUTSIDE'` → same as 13 (inheritance)
15. observed + workspace + `unavailable()` or `platform()` none-path: `touch` outside **succeeds** (control: observed is not secretly sandboxed)
16. contained + differing `RepositoryRoot`: outside-the-workspace write still blocked when the path is under the repo root but not the workspace

Do **not** `#expect` a skip when `sandbox-exec` is missing. Missing backend fails the test — that is the product.

### Operator probe

`isolationApply_operatorProbe_printsEstablishedModes` prints one line per case:

```text
requested=… established=… family=… exit=… error=…
```

Cases: contained inside, contained outside, contained child-outside (Darwin), observed outside, contained+unavailable.

### Adversarial

- contained cannot be “fixed” by running unsandboxed and returning `.contained`
- observed + workspace is not contained
- `RepositoryRoot` is not the Seatbelt subpath
- no Landlock / CLI / `established` field on `IsolationPlan`

## 17. Acceptance criteria

- [x] `RVIsolation` library and `RVIsolationTests` exist in `Package.swift`
- [x] `IsolationBackend`, `IsolationBackends.seatbelt/unavailable/platform`, `IsolatedCommand`, `IsolatedLaunchRequest`, `IsolatedRunResult`, `EstablishedIsolation`, `IsolationApplyError`, `SeatbeltProfile`, `compileSeatbeltProfile` exist as `Sendable` values
- [x] `IsolationBackendFamily` cases are only `none` and `seatbelt`
- [x] `compileSeatbeltProfile` emits allow-default + deny `file-write*` `require-not` `subpath` resolved workspace; no `deny default`; no network deny
- [x] Contained write-limit in the profile is the workspace, not `RepositoryRoot`
- [x] `prepare` never returns `EstablishedIsolation`
- [x] `EstablishedIsolation.contained` is minted only from a successful Seatbelt `run` spawn
- [x] Contained + `unavailable` / non-Darwin `platform()` fails `backendUnavailable` and does not start the inner command
- [x] Observed / mediated establish family `.none` and do not invoke `sandbox-exec`
- [x] Darwin: in-workspace write succeeds under Seatbelt
- [x] Darwin: out-of-workspace write is blocked by the kernel and the file is absent
- [x] Darwin: `/bin/sh` child cannot write outside the workspace
- [x] Production construction of request/profile/established is prepare/run or `internal` factory
- [x] `Sources/RVDomain/Isolation.swift` has no `Process`, no SBPL, no `#if os`
- [x] `AgentAuthorization.swift`, `HostNativeAsk.swift`, `PolicyGate.swift`, `RV.swift` are unchanged
- [x] `.github/workflows/release.yml` and Darwin `pr.yml` hook-grade run `RVIsolationTests`
- [x] Required tests exist and pass
- [x] `Scripts/swift-6.4 test --filter IsolationApply` exits 0
- [x] `Scripts/swift-6.4 test --filter SeatbeltContainment` exits 0 on Darwin
- [x] `Scripts/swift-6.4 test --filter IsolationPlan` and `--filter AgentAuthorization` still exit 0
- [x] Implementation Completion Notes in this file are filled in

## 18. Non-goals

- Landlock / Linux establishment of contained
- `rv agent` / `rv opencode` / launching OpenCode
- `ExecutableAction` / `LocalExecutor`
- Approval store / menu-bar
- Network-blocked or read-limited guarantees
- `stronglyIsolated` / Tart / Apple Container
- Changing hook quiet-allow
- Merging workspace with `RepositoryRoot`
- Adding `established` onto `IsolationPlan`
- Copying Seatbelt profiles from another repository
- `sandbox_init` / libsandbox
- Stripping the process environment

## 19. Risks / questions discovered

| Item | Resolution from the tree |
| --- | --- |
| Put Seatbelt in `RVDomain`? | No. Domain stays Process/SBPL-free. New `RVIsolation` target |
| Put apply in `RVEngine` / `RVCLI` / `RVService`? | No. Engine is semantics; CLI/service are the wrong product meaning |
| Implement Landlock now because Phase 2 lists it? | No. One kernel, one honest family |
| Add `rv <agent>` because AGENT-007 says launch? | No. Backend first; CLI is a later handoff |
| Deny-default jail so it “looks contained”? | No. First-slice contract is write-limit + inherit |
| Skip Darwin tests if `sandbox-exec` missing? | No. Fail the test |
| Set `IsolationPlan.mode` after apply? | No. Intended stays on the plan; established is a new value |
| Fold into `AgentAuthorization`? | No. Complementary layers |
| Reuse `ExecutingCommand`? | No. Not a capability type |

## 20. Handoff notes for next phase

Likely next: **Linux Landlock apply** of the same `IsolationPlan` first-slice (write-limit + inherit), fail closed when the ABI cannot establish it, still no CLI/OpenCode/executor.

When that starts:

- Consume `IsolationPlan` + `IsolationBackend` from this phase; add `.landlock` as a **new** family when a backend exists, not as a synonym for `.seatbelt`
- Do not claim Seatbelt ⇔ Landlock
- If Landlock cannot inherit to children, fail closed — do not downgrade to observed
- Still no Tart / Apple Container
- `AllowedAction` still does not execute
- First host remains OpenCode; adapter/CLI is still later

---

# Implementation Prompt

Grok Build prompt (authoritative architecture remains this handoff, §§1–20). Copy the block below into a fresh Grok Build session:

```text
You are implementing one RV <agent> slice in this Swift 6.4 repo. Implement it. Do not only propose. Continue until every acceptance criterion is met and adversarial review is complete. Do not start the next phase (Landlock, rv agent/opencode CLI, OpenCode launch, executor).

Gate irreversible git actions (force-push, hard reset, dropping commits) with user confirmation. Proceed on reversible source/test/handoff/CI edits.

## Authority
Read all of `docs/rv-agent/handoffs/phase-04-seatbelt-apply.md` before writing code. Type model (§8), SBPL shape (§8/`compileSeatbeltProfile`), security invariants (§13), non-goals (§18), and this checklist are the contract. If a file path in the handoff drifted, inspect the tree and reconcile — do not invent a parallel isolation model.

Reuse:
- `compileIsolationPlan` / `IsolationPlan` (`Sources/RVDomain/Isolation.swift`)
- `WorkingDirectory` as the workspace; `RepositoryRoot` as optional metadata only
Do not extend `SafetyLevel`. Do not call `AgentAuthorization.decide` from apply. Do not import RVEngine from RVIsolation. Do not edit Isolation.swift except a one-line comment if needed.

## Goal
Add `RVIsolation` with `IsolationBackend` so a contained `IsolationPlan` is established on Darwin by running the inner command under `/usr/bin/sandbox-exec` with a first-slice Seatbelt profile (allow default + deny writes outside the resolved workspace). Contained without a backend fails closed. `IsolationPlan.mode` stays intended. `EstablishedIsolation` is minted only after a successful spawn.

## Edge cases to encode before production code
1. `compileSeatbeltProfile(contained)` → allow-default + deny file-write* require-not subpath(resolved workspace); no deny default; no network deny
2. contained workspace `/ws` + repositoryRoot `/repo` → profile subpath is `/ws`, not `/repo`
3. `compileSeatbeltProfile(observed|mediated)` → `profileNotApplicable`
4. `unavailable().prepare(contained)` → `backendUnavailable` (not observed)
5. observed prepare+run via unavailable → established observed, family none, no sandbox-exec
6. mediated prepare+run → established mediated, family none
7. contained + relative workspace `"repo"` → `workspaceMustBeAbsolute`
8. contained + missing directory → `workspaceDoesNotExist`
9. EstablishedIsolation factory rejects contained+none and observed+seatbelt
10. Darwin: touch inside workspace succeeds; established contained+seatbelt
11. Darwin: touch outside workspace fails; file absent; established still contained
12. Darwin: `/bin/sh -c` touch outside fails (inheritance)
13. observed touch outside succeeds (control: not secretly sandboxed)
14. Darwin: write under repositoryRoot but outside workspace is blocked
15. non-Darwin `platform()` contained → `backendUnavailable`

## Acceptance criteria
Treat each item as binary and observable.
- [ ] `Package.swift` has `RVIsolation` (depends on `RVDomain`) and `RVIsolationTests` (depends on `RVIsolation`)
- [ ] `Sources/RVIsolation/IsolationApply.swift` and `SeatbeltProfile.swift` exist with the types in the handoff §8
- [ ] Every new type is `Sendable` (and `Equatable` where useful)
- [ ] `IsolationBackendFamily` has exactly `none` and `seatbelt` — no `landlock`, no `contained: Bool`
- [ ] `compileSeatbeltProfile` matches edge 1–3; tests name those cases
- [ ] `IsolationBackends.unavailable().prepare(.contained)` returns `.failure(.backendUnavailable)` — test name records this
- [ ] Observed/mediated run never invokes `/usr/bin/sandbox-exec` and never returns `.contained`
- [ ] `EstablishedIsolation.contained` is created only inside Seatbelt `run` after `Process` starts — production inits are `internal`
- [ ] Darwin `SeatbeltContainment` tests cover inside write, outside write, `/bin/sh` child, repo-root-is-not-workspace
- [ ] Missing `sandbox-exec` does not skip tests; the apply path fails closed
- [ ] `Tests/RVIsolationTests/IsolationApplyTests.swift` lists the portable edges and uses exhaustive `switch` on errors / modes
- [ ] TDD: IsolationApply/Seatbelt tests were RED before RVIsolation implementation (record that sequence)
- [ ] `Scripts/swift-6.4 test --filter IsolationApply` exits 0
- [ ] `Scripts/swift-6.4 test --filter SeatbeltContainment` exits 0 on this Darwin machine
- [ ] `Scripts/swift-6.4 test --filter IsolationPlan` exits 0
- [ ] `Scripts/swift-6.4 test --filter AgentAuthorization` exits 0
- [ ] `.github/workflows/release.yml` gate list includes `RVIsolationTests`
- [ ] `.github/workflows/pr.yml` Darwin hook-grade job runs `Scripts/swift-6.4 test --filter RVIsolationTests`
- [ ] `rg -n "landlock|rv opencode|ExecutableAction|stronglyIsolated" Sources/RVIsolation Sources/RVCLI/RV.swift` shows no Landlock/CLI/executor from this phase
- [ ] `Sources/RVDomain/Isolation.swift` still has no `#if os` and no `Process`
- [ ] `AgentAuthorization.swift`, `HostNativeAsk.swift`, `PolicyGate.swift`, `RV.swift` are unchanged
- [ ] Manual probe recorded (commands + stdout) — see Workflow step 4
- [ ] This handoff §17 checkboxes updated; Implementation Completion Notes filled
- [ ] Adversarial review sub-agent completed with no open blockers

## Workflow
1. **Decompose / explore (sub-agent)** — Confirm Isolation.swift public API (`compileIsolationPlan`, `WorkingDirectory`). Confirm no existing IsolationBackend. Confirm Package.swift / preflight one-dep test-target rule. Return exact paths only.

2. **Strong TDD (required)** — Author `IsolationApplyTests.swift` first (portable edges 1–9, 15), then `SeatbeltContainmentTests.swift` (Darwin 10–14), then the operator probe.
   a. List the edges in the test files.
   b. Write failing tests (RED). Run `Scripts/swift-6.4 test --filter IsolationApply` and confirm failure is “type/symbol missing” or missing target — not an unrelated-module break.
   c. Add the Package.swift target, then implement the minimum in `Sources/RVIsolation/` (GREEN).
   d. Refactor only while green. Keep the diff to RVIsolation + its tests + Package.swift + the two workflow files + this handoff.

3. **Integrate** — Re-run:
   - `Scripts/swift-6.4 test --filter IsolationApply`
   - `Scripts/swift-6.4 test --filter SeatbeltContainment`
   - `Scripts/swift-6.4 test --filter IsolationPlan`
   - `Scripts/swift-6.4 test --filter AgentAuthorization`
   Green tests are necessary, not sufficient.

4. **Manual / runtime verification (required — tests alone are not done)**
   After the suite is green:
   - Run `Scripts/swift-6.4 test --filter isolationApply_operatorProbe --verbose`
   - Record exact command + printed `requested=… established=… family=… exit=… error=…` lines
   - On Darwin, take the compiled profile string from a contained plan and run `/usr/bin/sandbox-exec -p '<profile>' /usr/bin/touch <outside-path>` yourself; record the exit code and that the file is absent. This is the kernel witness, not a mock.
   - Run: `rg -n "landlock|IsolationBackend|sandbox-exec" Sources` and record that Landlock is absent and Seatbelt apply lives only in RVIsolation
   Do not declare done on “IsolationApply tests passed” without the probe output and the direct `sandbox-exec` witness.

5. **Adversarial sub-agent review (required before done)** — Spawn a review agent that did **not** write RVIsolation. Brief it to attack:
   - contained fail-open to observed / unsandboxed run labeled contained
   - observed+workspace reported as contained
   - public mint of contained+family none
   - network claimed blocked
   - write limit uses RepositoryRoot
   - children escape via /bin/sh
   - Landlock/CLI/OpenCode/executor/`established` on IsolationPlan sneaking in
   - missing Darwin kernel evidence or skipped sandbox-exec
   - Domain polluted with Process / `#if os`
   Return blocker / major / nit. Fix blockers (and cheap majors). Re-run IsolationApply + SeatbeltContainment + IsolationPlan + AgentAuthorization + the operator probe + the sandbox-exec witness. Only then mark complete.

6. **Handoff** — Update §17 checkboxes and the Implementation Completion Notes in this same file. Do not create a second results file. Do not begin Landlock or CLI.

## Constraints (do this instead)
- Consume IsolationPlan; do not invent a second isolation policy struct.
- Fail contained-without-backend closed; do not downgrade it to observed/mediated.
- First-slice profile is write-limit + inherit only; keep network unrestricted as the absence of a network rule plus Domain `NetworkContainment.unrestricted`.
- Keep apply out of AgentAuthorization (call prepare/run, not decide).
- Leave hook quiet-allow (`HostNativeAsk.hookBound`) as-is.
- Use `/usr/bin/sandbox-exec -p`; do not call `sandbox_init` or copy profiles from another repo.

## Return ONLY
- Acceptance criteria status: each item pass/fail + evidence (test name or command)
- Changes: file paths + one-sentence purpose
- Tests: names + which edges each covers
- TDD evidence: RED command/output then GREEN command/output
- Manual verification: exact commands + printed probe lines + sandbox-exec witness + rg result
- Sub-agents used: role + ownership
- Adversarial review: summary + blockers fixed (or none)
- Handoff: confirmation that §17 and Completion Notes were updated
```

---

# Implementation Completion Notes

## Implementation Status

Implemented

## Implementation Summary

Added `RVIsolation` with `IsolationBackend` so a compiled `IsolationPlan` can be applied. Contained plans are prepared into a first-slice Seatbelt profile (allow-default + deny `file-write*` outside the POSIX-`realpath` workspace) and, on Darwin, run under `/usr/bin/sandbox-exec -p`. `EstablishedIsolation.contained` is minted only after `Process.run()` starts that sandboxed child. Contained without a backend (`unavailable()`, non-Darwin `platform()`, missing `sandbox-exec`) is `backendUnavailable` — never rewritten to observed/mediated. Observed/mediated establish family `.none` and exec the inner command directly. `IsolationPlan.mode` stays intended. Production callers use `IsolationBackends.apply`, which selects the unsandboxed path for observed/mediated and `platform()` for contained so Darwin launch does not have to pick a factory by mode. `IsolatedCommand` cannot represent a relative executable. `spawn` takes only a prepared `IsolatedLaunchRequest`, so contained argv is always `sandbox-exec`. No Landlock, no `rv agent`/`opencode` CLI, no executor, no `decide` from apply.

## Files Changed

**New**

- `Sources/RVIsolation/IsolationApply.swift` — backend types, prepare/run, `EstablishedIsolation` factory
- `Sources/RVIsolation/SeatbeltProfile.swift` — `compileSeatbeltProfile` / first-slice SBPL
- `Tests/RVIsolationTests/IsolationApplyTests.swift` — portable edges 1–9, 15 + operator probe
- `Tests/RVIsolationTests/SeatbeltContainmentTests.swift` — Darwin kernel edges 10–14

**Existing**

- `Package.swift` — `RVIsolation` (depends on `RVDomain`) + `RVIsolationTests` (depends on `RVIsolation`)
- `.github/workflows/release.yml` — `RVIsolationTests` added to `Scripts/gate.sh` list
- `.github/workflows/pr.yml` — Darwin hook-grade runs `Scripts/swift-6.4 test --filter RVIsolationTests`
- `docs/rv-agent/handoffs/phase-04-seatbelt-apply.md` — this completion record

**Not changed (intentionally)**

- `Sources/RVDomain/Isolation.swift`
- `Sources/RVDomain/AgentAuthorization.swift`
- `Sources/RVDomain/HostNativeAsk.swift`
- `Sources/RVPolicy/PolicyGate.swift`
- `Sources/RVCLI/RV.swift`
- `Sources/RVDomain/SafetyLevel.swift`

## Architecture Decisions Made

- Consume `IsolationPlan` from Phase 03. Do not invent a second isolation policy struct.
- `IsolationBackendFamily` is closed: `none | seatbelt`. Unavailability is an error, not a family.
- `prepare` returns `IsolatedLaunchRequest` only. `EstablishedIsolation` is created in `spawn` after `Process.run()` succeeds.
- First-slice SBPL is allow-default + deny writes outside the workspace. No `(deny default)`. No network deny.
- Workspace path interpolated into SBPL is POSIX `realpath` when the directory exists. `URL.resolvingSymlinksInPath()` on current Darwin keeps `/var` and can rewrite `/private/tmp` → `/tmp`, which Seatbelt does not treat as the kernel path.
- Nonexistent compile fixtures (`/workspace`, `/ws`) fall back to the URL path so portable profile-shape tests stay filesystem-free.
- `unavailable().prepare(.contained)` is `backendUnavailable` before any process starts.
- `platform()` is `#if os(macOS)` `seatbelt()` else `unavailable()`.
- `IsolationBackends.apply` is the production door: observed/mediated → `unavailable()`, contained → `platform()`. Factories stay for tests and injection.
- `IsolatedCommand.init?` / `make` reject empty and relative executables. `IsolatedLaunchRequest.Launch` is `seatbelt(profile)` or `unsandboxed` so a nil profile cannot pair with `.seatbelt`.
- `spawn` is `fileprivate` and takes `IsolatedLaunchRequest` only. It cannot mint contained from a raw inner argv.
- Existing directories that `realpath` cannot resolve fail prepare as `workspacePathUnresolvable`. URL fallback stays compile-only for missing fixtures.
- Production inits for request / profile / established / run result / backend are `internal`.
- `RVIsolationTests` depends on `RVIsolation` only (preflight one-dep). Tests `import RVDomain` as a same-package transitive module. No new `@_exported` (preflight fails those outside RVEngine/RVPacks).
- Added `commandExecutableMustBeAbsolute` (handoff-preferred distinct case).

## Deviations From Handoff

Profile resolve uses POSIX `realpath` instead of only `URL.resolvingSymlinksInPath()`, because that Foundation API does not produce the kernel path on this Darwin (`/tmp` stays `/tmp`; `/private/tmp` can become `/tmp`). The handoff’s required outcome (`/tmp` → `/private/tmp` in the SBPL subpath) is what `realpath` implements. URL resolve remains the fallback for nonexistent compile fixtures.

## Tests Added / Updated

`IsolationApply` (18) and `SeatbeltContainment` (5):

1. `compileSeatbeltProfile_contained_isAllowDefaultWriteLimit_noDenyDefaultOrNetworkDeny` — edge 1
2. `compileSeatbeltProfile_contained_writeLimitIsWorkspaceNotRepositoryRoot` — edge 2
3. `compileSeatbeltProfile_observedAndMediated_returnsProfileNotApplicable` — edge 3
4. `unavailable_prepare_contained_returnsBackendUnavailable` — edge 4
5. `unavailable_prepareAndRun_observed_establishesObservedFamilyNone_withoutSandboxExec` — edge 5
6. `unavailable_prepareAndRun_mediated_establishesMediatedFamilyNone` — edge 6
7. `seatbelt_prepare_contained_relativeWorkspace_returnsWorkspaceMustBeAbsolute` — edge 7
8. `seatbelt_prepare_contained_missingDirectory_returnsWorkspaceDoesNotExist` — edge 8
9. `establishedIsolation_rejectsContainedNoneAndObservedSeatbelt` — edge 9
10. `seatbelt_touchInsideWorkspace_succeedsAndEstablishesContained` — Darwin edge 10
11. `seatbelt_touchOutsideWorkspace_isBlockedFileAbsent_stillEstablishedContained` — Darwin edge 11
12. `seatbelt_binShChild_cannotWriteOutsideWorkspace` — Darwin edge 12
13. `observed_touchOutsideWorkspace_succeeds_notSecretlySandboxed` — Darwin edge 13
14. `seatbelt_writeUnderRepositoryRootOutsideWorkspace_isBlocked` — Darwin edge 14
15. `platform_contained_prepare_isBackendUnavailable_onNonDarwin` — edge 15 (Darwin asserts `platform().family == .seatbelt`)

Also: `isolationBackendFamily_hasExactlyNoneAndSeatbelt`; `isolationApply_operatorProbe_printsEstablishedModes`; `isolatedCommand_rejectsEmptyAndRelativeExecutable`; `apply_observedAndMediated_doNotRequireCallerToPickUnavailable`; `apply_contained_withoutUsableWorkspaceOrBackend_failsClosed`; `seatbelt_prepare_observed_returnsProfileNotApplicable`; `compileSeatbeltProfile_newlineWorkspace_returnsWorkspacePathUnsafe`; `seatbelt_prepare_launchArguments_areSandboxExecProfileAndInnerArgv`.

## Verification Performed

### TDD

**RED (missing target)** — tests authored first; no `RVIsolation` target:

```text
Scripts/swift-6.4 test --filter IsolationApply
warning: No matching test cases were run
```

**RED (symbol missing)** — `Package.swift` target + stub `@_exported`-free module (`IsolationApply.swift` was `import RVDomain` only):

```text
Scripts/swift-6.4 test --filter IsolationApply
IsolationApplyTests.swift:337:27: error: cannot find 'IsolatedCommand' in scope
IsolationApplyTests.swift:370:22: error: cannot find type 'SeatbeltProfile' in scope
IsolationApplyTests.swift:401:20: error: cannot find type 'EstablishedIsolation' in scope
error: Build failed
```

Failure was missing apply types in `RVIsolationTests` only, not an unrelated-module break.

**GREEN** — after `Sources/RVIsolation/` implementation (and `realpath` so in-workspace writes match the kernel path):

```text
Scripts/swift-6.4 test --filter IsolationApply
Test run with 12 tests in 1 suite passed after 0.033 seconds.

Scripts/swift-6.4 test --filter SeatbeltContainment
Test run with 5 tests in 1 suite passed after 0.015 seconds.
```

### Integrate (after adversarial review; no code fixes)

```text
Scripts/swift-6.4 test --filter IsolationApply
Suite "IsolationApply" passed after 0.031 seconds. (12 tests)

Scripts/swift-6.4 test --filter SeatbeltContainment
Suite "SeatbeltContainment" passed after 0.014 seconds. (5 tests)

Scripts/swift-6.4 test --filter IsolationPlan
Suite "IsolationPlan" passed after 0.001 seconds. (13 tests)

Scripts/swift-6.4 test --filter AgentAuthorization
Suite "AgentAuthorization" passed after 0.001 seconds. (23 tests)
```

### Manual / operator probe

```text
Scripts/swift-6.4 test --filter isolationApply_operatorProbe --verbose
```

Printed lines:

```text
requested=contained established=contained family=seatbelt exit=0 error=none
requested=contained established=contained family=seatbelt exit=1 error=none
requested=contained established=contained family=seatbelt exit=1 error=none
requested=observed established=observed family=none exit=0 error=none
requested=contained established=none family=none exit=none error=backendUnavailable
```

`Test isolationApply_operatorProbe_printsEstablishedModes() passed after 0.032 seconds.`

### Darwin kernel witness (`sandbox-exec` directly)

First-slice profile compiled from a contained workspace (`realpath` `/private/tmp/rv-seatbelt-witness-rerun/ws`):

```text
/usr/bin/sandbox-exec -p '<profile>' /usr/bin/touch /tmp/rv-seatbelt-witness-rerun/outside.txt
touch: /tmp/rv-seatbelt-witness-rerun/outside.txt: Operation not permitted
exit=1
file=ABSENT
```

Control: unsandboxed `/usr/bin/touch` of a sibling path created the file (`control_file=PRESENT`).

### Backend scan

```text
rg -n "landlock|IsolationBackend|sandbox-exec" Sources
```

Landlock absent. `IsolationBackend` / `sandbox-exec` live only in `Sources/RVIsolation`.

```text
rg -n "landlock|rv opencode|ExecutableAction|stronglyIsolated" Sources/RVIsolation Sources/RVCLI/RV.swift
```

No matches.

`Sources/RVDomain/Isolation.swift` still has no `#if os` and no `Process`.

### Adversarial / Bypass Tests

Independent `code-reviewer` sub-agent (did not write `RVIsolation`). Verdict: **APPROVE**. Blockers: none. Majors: none. Attack vectors 1–12 all clean (contained fail-open; observed+workspace as contained; public mint contained+none; network claimed blocked; RepositoryRoot write limit; `/bin/sh` escape; Landlock/CLI/executor/`established` on the plan; skipped sandbox-exec; Domain Process/`#if os`; plan.mode rewrite; `decide` from apply; established before spawn).

## Known Limitations

- First-slice is write-limit + inherit only. Reads, network, mach, and tty are unrestricted.
- Symlink-out-of-workspace writes are not in the contract.
- TOCTOU between exist-check and spawn is accepted.
- This is not an OpenCode session and does not launch `rv agent`.
- Linux / unavailable cannot establish contained; they fail closed.
- `@testable` can still call internal factories. Memberwise production inits stay internal.

## Technical Debt Introduced

- POSIX `realpath` + URL fallback instead of the handoff’s Foundation-only resolve sentence. Keep the kernel path; do not switch back to URL-only on Darwin.
- `commandExecutableMustBeAbsolute` is extra vs the handoff minimum error table; keep it rather than overloading `workspaceMustBeAbsolute`.

## Important Context for Next Phase

- Consume `IsolationPlan` + `IsolationBackend` from this phase. Add `.landlock` as a **new** family when a backend exists, not as a synonym for `.seatbelt`.
- Do not claim Seatbelt ⇔ Landlock.
- If Landlock cannot inherit to children, fail closed — do not downgrade to observed.
- Still no Tart / Apple Container, no `rv agent` / OpenCode launch, no executor.
- `AllowedAction` still does not execute. Apply still does not call `decide`.
- Leave `HostNativeAsk.hookBound` quiet-allow as-is.

## Acceptance Criteria Final State

Coding-agent checkboxes in §17 are marked done. Independent `code-reviewer` adversarial pass reported no open blockers.
