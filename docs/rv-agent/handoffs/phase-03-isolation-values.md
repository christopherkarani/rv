# Phase 03 — Isolation values (compile-time, no launch)

## 1. Phase

**Name:** Isolation policy, guarantees, and enforcement-mode values

**Master-plan reference:** `RV_Agent_Implementation_Plan_v2.docx` Phase 1 — Typed runtime core (final implementation slice of Phase 1: AGENT-006). Does **not** start master-plan Phase 2 (Seatbelt / Landlock launch).

**Previous phase:** `docs/rv-agent/handoffs/phase-02-typed-authorization.md` — planning-verified Complete on 2026-09-20.

## 2. Status

Complete

## 3. Objective

Add a host-independent, fail-closed **compile** of isolation intent into `IsolationPlan` / `EnforcementMode` / `IsolationGuarantees` values so later launch can apply Seatbelt or Landlock against an explicit contract — without claiming any session is contained and without launching a process.

## 4. Why this phase exists

Authorization (Phase 02) decides whether RV will mediate a proposal. Containment is a different layer: it limits what the agent can do **directly**. The master plan requires those layers to stay complementary, and it requires honest `EnforcementMode` values.

Today the tree has **no** isolation types. If Phase 2 invented Seatbelt profiles without a typed contract, logs and tests would have nothing truthful to record, and `contained` could be attached as a slogan.

This slice unlocks:

```text
session workspace + requested isolation
        ↓ compileIsolationPlan  (pure, this phase)
IsolationPlan
  mode: observed | mediated | contained(IsolationGuarantees)
        ↓ later launch (NOT this phase)
Seatbelt / Landlock apply or fail closed
        ↓ later session record
established EnforcementMode (only after launch succeeds)
```

**Compile is not establishment.** A successful compile of `.contained` means “launch must establish these guarantees,” not “the agent is contained.”

## 5. Current repository state

Inspected after Phase 02 verification on `feat/agent-typed-authorization` (`d1ae21d`).

### 5.1 What exists

- Phase 01: `AgentRequest` → `normalizeAgentRequest` → `ProposedAction`
- Phase 02: `AgentAuthorization.decide` → allowed / pending / denied
- `WorkingDirectory` and `RepositoryRoot` — nonempty path newtypes (`Sources/RVDomain/WorkingDirectory.swift`, `RepositoryRoot.swift`)
- `SafetyLevel` — operator posture (`normal` / `strict`). **Not** an enforcement mode
- `HomePath` — home identity for secret-path allowlists, not a sandbox root
- CLI still has no `rv agent` / `rv opencode` (`Sources/RVCLI/RV.swift`)
- `Process()` only in setup launchctl/systemctl
- **Zero** Seatbelt, Landlock, `sandbox-exec`, `IsolationBackend`, or `EnforcementMode` types

### 5.2 Semantic vs OS roots (do not merge)

| Boundary | Type | Meaning |
| --- | --- | --- |
| Semantic in-repo / out-of-repo | `RepositoryRoot` + `FilesystemScope` | `ActionPolicyEngine` filesystem wall |
| OS write containment (future) | isolation **workspace** (`WorkingDirectory`) | What Seatbelt/Landlock must limit writes to |

They often coincide. They are not the same type and must not be collapsed. `AllowedAction` for an in-repo write does not imply the agent is sandboxed; a contained plan does not skip `AgentAuthorization.decide`.

### 5.3 Master-plan conflicts (smallest adjustments)

1. **No existing sandbox types to “wire.”** This phase **introduces values only**. Phase 2 introduces backends.
2. **Do not inhabit `stronglyIsolated`.** Tart / Apple Container / VMs are later. Omitting the case is better than a dead case.
3. **`SafetyLevel` is not `EnforcementMode`.** Do not extend it.
4. **Analytics `PlatformSnapshot` is not isolation.** Do not reuse it.

## 6. Existing components to reuse

Must reuse:

- `WorkingDirectory` as the containment workspace path
- `RepositoryRoot` as an optional recorded fact on the plan, never as a second OS sandbox
- Swift Testing style from `Tests/RVDomainTests/AgentAuthorizationTests.swift` (exhaustive switches, fail-closed tables)

Must not reuse / must not touch:

- `AgentAuthorization.decide` — do not fold isolation into policy
- `HostNativeAsk.hookBound`
- `PolicyGate`
- `SafetyLevel`
- Hook codecs, CLI, `RVService` process launch
- external Seatbelt/Landlock implementations — do not copy them into this repo this phase

## 7. Architecture for this phase

```text
IsolationCompileRequest
  requested: observed | mediated | contained
  workspace: WorkingDirectory?
  repositoryRoot: RepositoryRoot?
        │
        │  compileIsolationPlan   (pure)
        ▼
Result<IsolationPlan, IsolationCompileError>

IsolationPlan.mode
  .observed
  .mediated
  .contained(IsolationGuarantees)
        │
        ✕ no Process, no Seatbelt, no Landlock, no session “established” flag
```

Two complementary facts stay separate:

```text
AgentAuthorization          IsolationPlan
(semantic permit)           (OS intent)
      │                           │
      └──────── later runtime ────┘
```

## 8. Type model

Place types in `Sources/RVDomain/Isolation.swift` (one file is enough).

### `RequestedIsolation`

```text
enum RequestedIsolation {
    case observed
    case mediated
    case contained
}
```

- **Represents:** What the caller asked compile to plan.
- **Invariant:** Closed. No “contained-if-possible” boolean.
- **Who constructs:** Tests and later CLI/session. Public.
- **Who consumes:** `compileIsolationPlan` only.

### `FilesystemContainment`

```text
enum FilesystemContainment {
    case unrestricted
    case writesLimited(to: WorkingDirectory)
}
```

Do not add read-limitation or allow-lists this phase.

### `NetworkContainment`

```text
enum NetworkContainment {
    case unrestricted
}
```

A single case is honest: the first vertical slice **does not promise** network restriction. Do not add `.blocked` until a backend will enforce it. A one-case enum documents the hole better than a `Bool = false` that someone later flips.

### `DescentContainment`

```text
enum DescentContainment {
    case notInherited
    case inherited
}
```

Contained first-slice plans must use `.inherited` (agent children stay in the same OS ruleset). `.notInherited` is representable so tests can prove compile **rejects** it for `.contained`.

### `IsolationGuarantees`

```text
struct IsolationGuarantees {
    var filesystem: FilesystemContainment
    var network: NetworkContainment
    var descent: DescentContainment
}
```

- **Represents:** Concrete restrictions a backend would have to establish.
- **Invariant for `.contained`:** `filesystem == .writesLimited(to: workspace)` AND `descent == .inherited`. Network stays `.unrestricted`.
- **Who constructs:** `compileIsolationPlan` / an `internal` first-slice factory. Not a public memberwise init that can mint “contained but unrestricted.”
- **Who consumes:** `EnforcementMode.contained`, later launch.

Avoid a bag of `Bool`s.

### `EnforcementMode`

```text
enum EnforcementMode {
    case observed
    case mediated
    case contained(IsolationGuarantees)
}
```

- **Represents:** The **intended** mode on an `IsolationPlan`, or later the **established** mode after launch.
- **Invariant:** `.contained` always carries guarantees. There is no `.contained` without associated values. No `.stronglyIsolated`.
- **This phase:** `IsolationPlan.mode` is **intended only**. Do not add `established: EnforcementMode` that equals `.contained` — that would lie.
- **Who constructs:** compile (production). Internal payload inits as needed.
- **Who consumes:** tests now; session/audit/launch later.

### `IsolationPlan`

```text
struct IsolationPlan {
    var requested: RequestedIsolation
    var workspace: WorkingDirectory?
    var repositoryRoot: RepositoryRoot?
    var mode: EnforcementMode
}
```

- **Represents:** Compiled isolation intent.
- **Invariants:**
  - `requested == .contained` ↔ `mode` is `.contained` and `workspace != nil`
  - if `.contained(guarantees)` and `writesLimited(to: dir)`, then `workspace == dir`
  - `requested == .observed` ↔ `mode == .observed` (no contained associated value)
  - `requested == .mediated` ↔ `mode == .mediated`
- **Who constructs:** `compileIsolationPlan` only (fileprivate init).
- **Who consumes:** tests; later launch.

### `IsolationCompileError`

Minimum:

- `containedRequiresWorkspace`

If you also reject an internally constructed insufficient guarantee set through a package helper, add `containedRequiresWriteLimitAndInheritance` — only if that path exists. Prefer making insufficient `.contained` unrepresentable through compile + internal factory.

### `compileIsolationPlan`

```text
func compileIsolationPlan(
    _ request: IsolationCompileRequest
) -> Result<IsolationPlan, IsolationCompileError>
```

or `Isolation.compile(_:)`.

Rules:

| Request | Result |
| --- | --- |
| `.observed` | `.success` mode `.observed`. Workspace/root optional, recorded if present |
| `.mediated` | `.success` mode `.mediated`. Same optional paths. Means semantic RV mediation is the intended story, not OS containment |
| `.contained` + workspace | `.success` mode `.contained` with first-slice guarantees: writes limited to **that** workspace, descent inherited, network unrestricted |
| `.contained` + nil workspace | `.failure(.containedRequiresWorkspace)` |

`IsolationCompileRequest` is the untrusted/optional input (public). Empty string workspace is already impossible if the field is `WorkingDirectory?`.

### Types this phase must **not** add

`IsolationBackend`, `prepare`, Seatbelt profile text, Landlock ruleset, `sandbox-exec` wrappers, `ExecutableAction`, CLI launcher, `established` session record that claims containment.

## 9. Functional boundaries

| Layer | Allowed |
| --- | --- |
| Pure logic | compile request → `IsolationPlan` |
| State transitions | None |
| Effects | None |
| Platform | None. No `#if os`, no Darwin/Linux backend files |
| Permitted mutable state | Local vars only |

Do not call `AgentAuthorization.decide` from compile. Do not import Engine.

## 10. Exact implementation work

1. Add Domain types and `compileIsolationPlan` in `Sources/RVDomain/Isolation.swift` (or a tight pair of files).
2. Make `IsolationGuarantees` / `IsolationPlan` production construction go through compile or an `internal` first-slice factory so “contained + unrestricted writes + not inherited” cannot be minted from `RVEngine` / `RVHooks`.
3. Domain tests in `Tests/RVDomainTests/IsolationPlanTests.swift`:
   - observed, no workspace → observed plan, mode `.observed`
   - observed, with workspace → still `.observed` (workspace recorded, **not** contained)
   - mediated, with workspace → `.mediated`, not contained
   - contained + `/repo` workspace → `.contained` writesLimited(`/repo`) + inherited + network unrestricted; `workspace` equals the write limit
   - contained + optional `RepositoryRoot` records the root and still uses **workspace** for write limit (even if root differs)
   - contained + nil workspace → `containedRequiresWorkspace`
   - observed/mediated never produce `.contained`
   - contained plan’s `requested` is `.contained`
   - exhaustive switch on `EnforcementMode` (three cases)
   - `@testable` may see internal inits; pin that compile is the production door
4. Negative type-level tests: a contained plan must not have `filesystem == .unrestricted` or `descent == .notInherited`.
5. Do **not** add Seatbelt/Landlock source, CLI, or authorization changes.
6. Do **not** add an “established mode” field set to contained.
7. Run `RVDomainTests` filter Isolation / IsolationPlan, plus a quick `AgentAuthorization` filter to prove no accidental coupling.

## 11. Files likely to change

**New:**

- `Sources/RVDomain/Isolation.swift`
- `Tests/RVDomainTests/IsolationPlanTests.swift`

**Existing:** none required. Do not edit `AgentAuthorization.swift`, `HostNativeAsk.swift`, `RV.swift`, `Package.swift` (unless a new test file needs nothing extra — Domain tests already depend on `RVDomain`).

## 12. Architecture constraints

- Functional compile: values in, values out.
- Illegal states unrepresentable: no `contained: Bool`; no `.contained` without guarantees; no `.stronglyIsolated`.
- Domain stays free of Process, Seatbelt, Landlock, and host JSON.
- Isolation compile does not authorize actions; `AgentAuthorization` does not compile isolation.
- First-slice contained guarantees are **write-limit + inherit** only. Do not promise network, read-limit, or secret-path OS blocks.
- Seatbelt and Landlock are **not equivalent**; this phase must not encode a single “sandbox works” flag.
- No `#if os` in Domain.
- Swift 6 / `Sendable`. No `@unchecked Sendable`.
- Do not add executor or adapter types.

## 13. Security invariants

- Compile of `.contained` without a workspace fails closed.
- A compiled `.observed` or `.mediated` plan must not be reportable as contained.
- `.contained` guarantees must name the workspace they limit writes to.
- Descent for contained first-slice is inherited. A plan that would let children escape is not a successful contained compile.
- Network unrestricted must remain explicit so later code cannot assume “contained ⇒ no network.”
- No API added here launches a process or writes a sandbox profile.
- `AllowedAction` is unchanged and still not executable.

## 14. Enforcement guarantee

**This phase provides no OS enforcement and no new hook mediation.**

| Mode | This phase |
| --- | --- |
| observed | Can be **planned** as a value |
| mediated | Can be **planned** as a value (semantic RV only; matches today’s hook-grade product if later chosen) |
| contained | Can be **planned** as intended guarantees. **Not established.** No agent is sandboxed |

Limitations (must stay documented):

- No Seatbelt profile, no Landlock ruleset
- No child-process test against a real kernel
- Network is unrestricted even in a contained **plan**
- Reads outside workspace are not in the first-slice contract
- Semantic deny/allow still happens only in `AgentAuthorization`
- Current product remains hook-grade until Phase 2 launch + Phase 4 adapter

## 15. Failure behavior

| Input | Outcome |
| --- | --- |
| contained, missing workspace | `containedRequiresWorkspace`, no `IsolationPlan` |
| contained, valid workspace | Plan with first-slice guarantees; **not** a live sandbox |
| observed / mediated | Plan with that mode; never `.contained` |
| Insufficient guarantees if a factory is asked to build them | Do not return `.contained` |

Never map a failed contained compile to `.observed` or `.mediated` “so the session can start.” That fail-open belongs to no phase; launch (Phase 2) must fail closed when contained was requested and cannot be established.

## 16. Tests

### Pure unit (`RVDomainTests`)

All cases in §10 step 3–4.

Property-style pins:

- contained success ⇒ `writesLimited` workspace == `plan.workspace`
- contained success ⇒ `descent == .inherited`
- contained success ⇒ `network == .unrestricted`
- observed/mediated ⇒ `mode` has no guarantees associated value

### Reducer / authorization

None required. Do not call `decide` inside isolation tests except a single optional comment/test that the modules compile independently (not required).

### Integration / platform / containment

None. No kernel tests.

### Adversarial

- contained without workspace cannot be “fixed” by supplying only `RepositoryRoot`
- observed + workspace is not contained
- mediated is not a backdoor to contained

## 17. Acceptance criteria

- [x] `RequestedIsolation`, `EnforcementMode`, `IsolationGuarantees`, `IsolationPlan`, and `compileIsolationPlan` exist as `Sendable` values
- [x] `EnforcementMode` cases are only `observed`, `mediated`, `contained(IsolationGuarantees)` — no `stronglyIsolated`, no booleans
- [x] Contained compile requires `WorkingDirectory`; failure is typed
- [x] Successful contained plan limits writes to that workspace, marks descent inherited, and leaves network unrestricted
- [x] Observed and mediated compiles never produce `.contained`
- [x] Contained write-limit path equals `plan.workspace`
- [x] `RepositoryRoot` is optional metadata and cannot substitute for workspace
- [x] Production construction of a contained plan goes through compile (internal payload inits only)
- [x] No Seatbelt, Landlock, `Process`, CLI launcher, `IsolationBackend`, or `established` contained session record
- [x] `AgentAuthorization` / hook / `PolicyGate` are unchanged
- [x] Required tests exist and pass
- [x] Implementation Completion Notes in this file are filled in

## 18. Non-goals

- Applying Seatbelt or Landlock
- `IsolationBackend.prepare`
- Launching OpenCode or any agent
- `ExecutableAction` / executor
- Approval store / menu-bar
- Network-blocked guarantees
- Read-only or secret-path OS rules
- `stronglyIsolated` / Tart / Apple Container / Linux containers
- Changing hook quiet-allow
- Merging workspace with `RepositoryRoot`
- CLI `rv opencode`

## 19. Risks / questions discovered

| Item | Resolution from the tree |
| --- | --- |
| Reuse `SafetyLevel`? | No. Operator posture, not enforcement |
| Implement Seatbelt now because Phase 2 is next? | No. Values first; launch is the next master-plan phase |
| Promise Landlock == Seatbelt? | No. Same first-slice **intent**; backends differ later |
| Include network block in first-slice contained? | No. Not implemented; claiming it would lie |
| Put platform enum on the plan? | No this phase. Avoid unused `macOS`/`linux` ceremony until a backend exists |
| Fold into `AgentAuthorization`? | No. Complementary layers |

## 20. Handoff notes for next phase

Next master-plan phase is **OS-isolated launch** (Phase 2): `IsolationBackend` as an effect capability, Seatbelt on macOS, Landlock on Linux, fail closed when a requested `.contained` plan cannot be established, record **established** `EnforcementMode` only after apply succeeds, inheritance tests.

When that starts:

- Consume `IsolationPlan` from this phase; do not invent a second policy struct
- `compileIsolationPlan` stays pure; apply is the effect
- If Landlock ABI cannot provide write-limit + inherit, fail closed — do not downgrade to observed silently
- Seatbelt and Landlock tests must be platform-specific
- Still no Tart / Apple Container
- `AllowedAction` still does not execute; launch containment is not authorization
- First host remains OpenCode; adapter/CLI is still later

---

# Implementation Prompt

Grok Build prompt (authoritative architecture remains this handoff, §§1–20). Copy the block below into a fresh Grok Build session:

```text
You are implementing one RV <agent> slice in this Swift 6.4 repo. Implement it. Do not only propose. Continue until every acceptance criterion is met and adversarial review is complete. Do not start the next phase (Seatbelt, Landlock, IsolationBackend, executor, CLI).

Gate irreversible git actions (force-push, hard reset, dropping commits) with user confirmation. Proceed on reversible source/test/handoff edits.

## Authority
Read all of `docs/rv-agent/handoffs/phase-03-isolation-values.md` before writing code. Type model (§8), compile table (§8/`compileIsolationPlan`), security invariants (§13), non-goals (§18), and this checklist are the contract. If a file path in the handoff drifted, inspect the tree and reconcile — do not invent a parallel isolation model.

Reuse:
- `WorkingDirectory` (`Sources/RVDomain/WorkingDirectory.swift`) as the workspace
- `RepositoryRoot` (`Sources/RVDomain/RepositoryRoot.swift`) as optional metadata only
Do not extend `SafetyLevel`. Do not call `AgentAuthorization.decide` from compile. Do not import RVEngine from RVDomain.

## Goal
Add a pure `compileIsolationPlan` that turns `IsolationCompileRequest` into `IsolationPlan`. A successful `.contained` plan is intended guarantees for a later launch, not a claim that any agent is sandboxed.

## Edge cases to encode before production code
1. `.contained` + nil workspace → `.failure(.containedRequiresWorkspace)`
2. `.contained` + `RepositoryRoot` only (workspace nil) → same failure (root cannot substitute)
3. `.observed` + workspace `/repo` → `.observed`, workspace recorded, mode is not `.contained`
4. `.mediated` + workspace `/repo` → `.mediated`, not `.contained`
5. `.contained` + workspace `/repo` → writesLimited(to: `/repo`), descent `.inherited`, network `.unrestricted`, `plan.workspace == /repo`
6. `.contained` + workspace `/ws` + repositoryRoot `/repo` → write limit is `/ws`, root recorded, they may differ
7. Empty-string workspace is already unrepresentable as `WorkingDirectory`; do not add a String bypass
8. Observed/mediated never carry `IsolationGuarantees` on `EnforcementMode`
9. Contained first-slice must not use `filesystem == .unrestricted` or `descent == .notInherited`

## Acceptance criteria
Treat each item as binary and observable.
- [ ] `Sources/RVDomain/Isolation.swift` exists (or a tight Domain pair) with `RequestedIsolation`, `FilesystemContainment`, `NetworkContainment`, `DescentContainment`, `IsolationGuarantees`, `EnforcementMode`, `IsolationCompileRequest`, `IsolationCompileError`, `IsolationPlan`, `compileIsolationPlan`
- [ ] Every new type is `Sendable` (and `Equatable` where the handoff requires it)
- [ ] `EnforcementMode` has exactly three cases: `observed`, `mediated`, `contained(IsolationGuarantees)` — no `stronglyIsolated`, no `contained: Bool`
- [ ] `NetworkContainment` is `.unrestricted` only this slice
- [ ] `compileIsolationPlan(.contained)` with nil workspace returns `.failure(.containedRequiresWorkspace)` — test name records this
- [ ] `compileIsolationPlan(.contained)` with only `RepositoryRoot` set still fails `containedRequiresWorkspace` — test name records this
- [ ] `compileIsolationPlan(.observed)` with and without workspace returns `.observed` — workspace may be recorded, mode is never `.contained`
- [ ] `compileIsolationPlan(.mediated)` with workspace returns `.mediated`, never `.contained`
- [ ] Successful contained plan: `writesLimited(to: workspace)`, `descent == .inherited`, `network == .unrestricted`, write-limit path == `plan.workspace`
- [ ] Contained plan with differing `RepositoryRoot` still limits writes to `workspace`
- [ ] Production construction of `IsolationPlan` / contained `IsolationGuarantees` is compile or `internal` factory — `RVEngine`/`RVHooks` cannot mint contained+unrestricted
- [ ] `Tests/RVDomainTests/IsolationPlanTests.swift` exists; tests use exhaustive `switch` on `EnforcementMode` / compile `Result`
- [ ] TDD: IsolationPlan tests were RED before Isolation.swift implementation (record that sequence)
- [ ] `Scripts/swift-6.4 test --filter IsolationPlan` exits 0
- [ ] `Scripts/swift-6.4 test --filter AgentAuthorization` exits 0 (no coupling regression)
- [ ] `rg -n "sandbox-exec|sandbox_init|landlock|IsolationBackend|stronglyIsolated" Sources` shows no new backend/launch types from this phase
- [ ] `Sources/RVCLI/RV.swift` has no new `agent`/`opencode` subcommand
- [ ] `AgentAuthorization.swift`, `HostNativeAsk.swift`, `PolicyGate.swift` are unchanged
- [ ] No `#if os` in the new Domain isolation file(s)
- [ ] Manual probe recorded (commands + stdout) — see Workflow step 4
- [ ] This handoff §17 checkboxes updated; Implementation Completion Notes filled
- [ ] Adversarial review sub-agent completed with no open blockers

## Workflow
1. **Decompose / explore (sub-agent)** — Confirm there is no existing isolation type. Confirm `WorkingDirectory`/`RepositoryRoot` validators. Confirm `SafetyLevel` is unrelated. Return exact paths only.

2. **Strong TDD (required)** — Author `Tests/RVDomainTests/IsolationPlanTests.swift` first, covering every edge case above.
   a. List the 9 edges in the test file.
   b. Write failing tests (RED). Run `Scripts/swift-6.4 test --filter IsolationPlan` and confirm failure is “type/symbol missing” or assertion fail — not a build break in unrelated modules.
   c. Implement the minimum in `Sources/RVDomain/Isolation.swift` (GREEN).
   d. Refactor only while green. Keep the diff to Domain + this test file + this handoff.

3. **Integrate** — Re-run:
   - `Scripts/swift-6.4 test --filter IsolationPlan`
   - `Scripts/swift-6.4 test --filter AgentAuthorization`
   Green tests are necessary, not sufficient.

4. **Manual / runtime verification (required — tests alone are not done)**
   This slice is a library API (no CLI). After the suite is green, exercise the **public** compile function the way an operator would inspect a value:
   - Add a test `isolationCompile_operatorProbe_printsIntendedModes` that calls `compileIsolationPlan` for observed, mediated, contained+/repo, and contained+nil workspace; `#expect` the outcomes; `print` one line per case: `requested=… mode=… error=…`
   - Run: `Scripts/swift-6.4 test --filter isolationCompile_operatorProbe --verbose`
   - Record exact command + printed lines in Implementation Completion Notes.
   - Run: `rg -n "sandbox-exec|sandbox_init|landlock|IsolationBackend" Sources || true` and record that no launch backend appeared.
   Do not declare done on “IsolationPlan tests passed” without that probe output.

5. **Adversarial sub-agent review (required before done)** — Spawn a review agent that did **not** write Isolation.swift. Brief it to attack:
   - contained+root-only fail-open
   - observed+workspace reported as contained
   - public mint of unrestricted `.contained`
   - network claimed blocked
   - Seatbelt/Landlock/CLI/`established` containment sneaking in
   - missing manual probe evidence
   - `SafetyLevel` reused
   Return blocker / major / nit. Fix blockers (and cheap majors). Re-run IsolationPlan + AgentAuthorization + the operator probe. Only then mark complete.

6. **Handoff** — Update §17 checkboxes and the Implementation Completion Notes in this same file. Do not create a second results file. Do not begin Phase 2 launch.

## Constraints (do this instead)
- Compile values in, values out. Put effects in no new type.
- Fail contained-without-workspace closed; do not downgrade it to observed/mediated.
- First-slice contained guarantees are write-limit + inherit only; keep network unrestricted as an explicit enum case.
- Keep isolation compile out of `AgentAuthorization` (call compile, not decide).
- Leave hook quiet-allow (`HostNativeAsk.hookBound`) as-is.

## Return ONLY
- Acceptance criteria status: each item pass/fail + evidence (test name or command)
- Changes: file paths + one-sentence purpose
- Tests: names + which of the 9 edges each covers
- TDD evidence: RED command/output then GREEN command/output
- Manual verification: exact commands + printed probe lines + rg result
- Sub-agents used: role + ownership
- Adversarial review: summary + blockers fixed (or none)
- Handoff: confirmation that §17 and Completion Notes were updated
```

---

# Implementation Completion Notes

## Implementation Status

Implemented

## Implementation Summary

Added a pure Domain `compileIsolationPlan` that turns `IsolationCompileRequest` into `IsolationPlan`. Observed and mediated compile to those modes only. Contained without `WorkingDirectory` fails closed as `.containedRequiresWorkspace`; `RepositoryRoot` cannot substitute. A successful contained plan carries first-slice intended guarantees — `writesLimited(to: workspace)`, descent `.inherited`, network `.unrestricted` — and is not an established sandbox. `IsolationGuarantees` / `IsolationPlan` inits are `internal`; production construction is compile or `firstSliceContained`. No Seatbelt, Landlock, `IsolationBackend`, CLI launcher, or `AgentAuthorization` coupling.

## Files Changed

**New**

- `Sources/RVDomain/Isolation.swift` — isolation values and `compileIsolationPlan`
- `Tests/RVDomainTests/IsolationPlanTests.swift` — nine compile edges, exhaustive switches, operator probe

**Existing**

- `docs/rv-agent/handoffs/phase-03-isolation-values.md` — this completion record

**Not changed (intentionally)**

- `Sources/RVDomain/AgentAuthorization.swift`
- `Sources/RVDomain/HostNativeAsk.swift`
- `Sources/RVPolicy/PolicyGate.swift`
- `Sources/RVCLI/RV.swift`
- `Sources/RVDomain/SafetyLevel.swift`
- `Package.swift`

## Architecture Decisions Made

- Compile is a free function: values in, `Result` out. No effects, no `#if os`, no `Process`.
- `EnforcementMode` is exactly `observed | mediated | contained(IsolationGuarantees)`. No `stronglyIsolated`, no `contained: Bool`, no `established` field.
- `NetworkContainment` is `.unrestricted` only so later code cannot assume “contained ⇒ no network.”
- `IsolationGuarantees.init` and `IsolationPlan.init` are `fileprivate` so other Domain files cannot mint contained+unrestricted. `@testable` can still call internal `firstSliceContained`.
- First-slice factory `IsolationGuarantees.firstSliceContained(workspace:)` is the only production guarantee constructor; compile uses it.
- Workspace is `WorkingDirectory?`. Empty string is already unrepresentable; no `String` bypass was added.
- Isolation compile does not call `AgentAuthorization.decide`.

## Deviations From Handoff

None on the type model or compile table. `containedRequiresWriteLimitAndInheritance` was not added because insufficient `.contained` is not a compile input; the first-slice factory does not accept a guarantee bag.

Adversarial nits left unfixed (not blockers/majors): operator probe `mode=contained` does not print the write-limit path (assertions still pin it).

## Tests Added / Updated

`IsolationPlanTests` (13), mapped to the nine edges:

1. `contained_withoutWorkspace_failsContainedRequiresWorkspace` — contained + nil workspace
2. `contained_repositoryRootOnly_failsContainedRequiresWorkspace` — contained + root only
3. `observed_withWorkspace_returnsObservedNotContained` — observed + `/repo` (also `observed_withoutWorkspace_returnsObserved`)
4. `mediated_withWorkspace_returnsMediatedNotContained` — mediated + `/repo`
5. `contained_withWorkspace_writesLimitedInheritedNetworkUnrestricted` — contained + `/repo` first-slice
6. `contained_differingRepositoryRoot_limitsWritesToWorkspace` — write limit `/ws`, root `/repo`
7. `emptyStringWorkspace_isUnrepresentableAsWorkingDirectory` — no String bypass
8. `observedAndMediated_neverCarryIsolationGuarantees` — no guarantees on those modes
9. `containedFirstSlice_rejectsUnrestrictedFilesystemAndNotInheritedDescent` — compile + factory

Also: `enforcementMode_hasExactlyThreeCases`; `isolationPlan_productionConstruction_isCompileOrInternalFactory`; `isolationCompile_operatorProbe_printsIntendedModes`.

## Verification Performed

### Build

`Scripts/swift-6.4 test --filter IsolationPlan` compiled RVDomain + RVDomainTests (Swift 6.4). No `#if os` in `Isolation.swift`.

### Unit Tests

TDD sequence:

**RED** — tests authored first; `Isolation.swift` absent.

```text
Scripts/swift-6.4 test --filter IsolationPlan
```

Failure was type/symbol missing in `IsolationPlanTests.swift` only, not an unrelated-module break. Representative diagnostics:

```text
IsolationPlanTests.swift:194:22: error: cannot find type 'IsolationPlan' in scope
IsolationPlanTests.swift:329:35: error: cannot find type 'EnforcementMode' in scope
IsolationPlanTests.swift:19:22: error: cannot find 'compileIsolationPlan' in scope
IsolationPlanTests.swift:20:13: error: cannot find 'IsolationCompileRequest' in scope
error: Build failed
```

**GREEN** — after adding `Sources/RVDomain/Isolation.swift`:

```text
Scripts/swift-6.4 test --filter IsolationPlan
Test run with 12 tests in 1 suite passed after 0.001 seconds.
```

**Integrate** (after operator probe test):

```text
Scripts/swift-6.4 test --filter IsolationPlan
Suite "IsolationPlan" passed after 0.001 seconds.
Test run with 13 tests in 1 suite passed after 0.001 seconds.

Scripts/swift-6.4 test --filter AgentAuthorization
Suite "AgentAuthorization" passed after 0.001 seconds.
Test run with 23 tests in 1 suite passed after 0.001 seconds.
```

### Integration Tests

None. Isolation compile does not call `decide`. AgentAuthorization filter is the no-coupling regression.

### Platform / Containment Tests

None. This phase does not provide OS containment.

### Manual / operator probe

```text
Scripts/swift-6.4 test --filter isolationCompile_operatorProbe --verbose
```

Printed lines:

```text
requested=observed mode=observed error=none
requested=mediated mode=mediated error=none
requested=contained mode=contained error=none
requested=contained mode=none error=containedRequiresWorkspace
```

`Test isolationCompile_operatorProbe_printsIntendedModes() passed after 0.001 seconds.`
`Test run with 1 test in 1 suite passed after 0.001 seconds.`

Backend scan:

```text
rg -n "sandbox-exec|sandbox_init|landlock|IsolationBackend" Sources || true
```

Empty (no launch backend). `stronglyIsolated` appears only as a denial comment on `EnforcementMode`.

### Adversarial / Bypass Tests

Independent `code-reviewer` sub-agent (did not write `Isolation.swift`). Verdict: APPROVE. Blockers: none. Majors: none. Attack vectors 1–7 all pass (contained+root-only fail-open; observed+workspace as contained; public mint of unrestricted contained; network claimed blocked; Seatbelt/Landlock/CLI/`established`; missing probe; SafetyLevel reuse).

## Known Limitations

- Compile is intended guarantees only. No agent is sandboxed.
- Network remains unrestricted even on a contained plan.
- Reads outside the workspace are not in the first-slice contract.
- Semantic deny/allow still happens only in `AgentAuthorization`.
- Current product remains hook-grade until Phase 2 launch + later adapter.
- `@testable` can still call internal `firstSliceContained`. Memberwise inits are fileprivate.

## Technical Debt Introduced

- Memberwise inits are fileprivate. Do not widen them to `internal`, `package`, or `public`. Keep `firstSliceContained` internal.
- Operator probe `mode=contained` does not print the write-limit path; assertions do.

## Important Context for Next Phase

- Consume `IsolationPlan` from this phase. Do not invent a second isolation policy struct.
- `compileIsolationPlan` stays pure. Apply (Seatbelt / Landlock) is the effect and is not started here.
- If a requested `.contained` plan cannot be established, fail closed. Do not downgrade to observed/mediated.
- Record **established** `EnforcementMode` only after apply succeeds. This phase’s `IsolationPlan.mode` is intended only.
- Seatbelt and Landlock are not equivalent; do not add a “sandbox works” flag.
- `AllowedAction` still does not execute. Isolation compile still does not authorize.
- Leave `HostNativeAsk.hookBound` quiet-allow as-is.

## Acceptance Criteria Final State

Coding-agent checkboxes in §17 are marked done.
Completion is independently verified by the next planning session.

---

# Planning Verification

## Verification Date

2026-09-20

## Result

Complete

## Verified Against

- implementation
- tests
- architecture constraints
- security invariants
- enforcement guarantees
- acceptance criteria

## Notes

Independent planning review of `Sources/RVDomain/Isolation.swift` and `Tests/RVDomainTests/IsolationPlanTests.swift` on `feat/agent-isolation-values` (`b908714`). Focused suites passed on this tree: `IsolationPlan` (13), `AgentAuthorization` (23). `compileIsolationPlan` is a pure `Result` — no `Process`, no `#if os`, no `decide`. Observed / mediated never produce `.contained`. Contained without `WorkingDirectory` is `.containedRequiresWorkspace`; `RepositoryRoot` cannot substitute. First-slice contained guarantees are `writesLimited(to: workspace)` + `.inherited` + network `.unrestricted`. Memberwise inits are `fileprivate`; production door is compile / internal `firstSliceContained`. `rg` over `Sources` has no `sandbox-exec`, `sandbox_init`, `landlock`, or `IsolationBackend`. `RV.swift` still has no `agent` / `opencode` command. Coding-agent PR summary is accurate: this is a typed isolation compile, not a sandbox. Status string `Implemented` was not a planning-complete state; this verification is the Complete mark.
