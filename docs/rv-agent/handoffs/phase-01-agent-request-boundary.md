# Phase 01 — Typed AgentRequest boundary and OpenCode process normalization

## 1. Phase

**Name:** Typed AgentRequest boundary and first OpenCode process normalization

**Master-plan reference:** `RV_Agent_Implementation_Plan_v2.docx` Phase 1 — Typed runtime core (first implementation slice only)

**Tickets covered:** AGENT-002 (typed AgentRequest boundary), AGENT-004 (pure request normalization pipeline) — process/shell only

**Not this file:** master-plan Phase 0 is an audit, not a coding phase. The planning session that created this handoff performed that audit against the current tree. Findings are recorded in §5. Do not open a second Phase 0 implementation ticket.

## 2. Status

Complete

## 3. Objective

Establish a host-independent, fail-closed path from an untrusted process request to a validated `AgentRequest` and then to the existing `ProposedAction` model, proven with the first OpenCode process tools (`bash`, `session.shell`) and **without** creating an executable capability.

## 4. Why this phase exists

`rv <agent>` cannot own execution until a request is a stronger type than host JSON or a raw shell string. Today the only typed ingress is the hook door (`HookRequest` → pack `evaluate` / `evaluateWithSemantics` → `Decision` / `HookAuthorization`). That path grades host-invoked hooks; it does not launch agents, contain them, or authorize RV-owned effects.

This slice unlocks the first runtime trust transition:

```text
untrusted process request
        ↓ validate
AgentRequest
        ↓ analyzeSemantics (existing)
ProposedAction
```

The existence of `ProposedAction` must remain what it already is: a proposal, not a permit. Later phases attach policy, typed authorization, Seatbelt/Landlock launch, and `LocalExecutor`. Those must not start here.

## 5. Current repository state

Inspected on this tree (main). There are **no** previous `docs/rv-agent/handoffs/` files and **no** `AgentRequest`, `ExecutableAction`, `IsolationBackend`, Seatbelt, or Landlock types.

### 5.1 Product today

RV is a **hook-grade** guard (`README.md`). `rv` subcommands in `Sources/RVCLI/RV.swift`: `test`, `explain`, `packs`, `policy`, `scan`, `service`, `hook`, `setup`, `uninstall`, `doctor`, `allow-once`, `allowlist`, `safety`, `blocks`. There is no `rv agent` / `rv opencode` launcher.

`rv hook --host opencode` reads stdin through `OpenCodeHostCodec` and asks `rvd` / in-process evaluate to allow or deny. The host still executes the tool if the hook allows it. RV does not launch OpenCode and does not perform the privileged effect.

### 5.2 Modules that matter

| Module | Role now | Role this phase |
| --- | --- | --- |
| `RVDomain` | Values: `ProposedAction`, `ShellCommand`, `HookHost`, `SessionID`, `WorkingDirectory`, `SemanticAnalysis`, `GitAction`, `FilesystemAction`, `PendingApproval`, `HardPolicyDecision`, `BoundReview`, `Decision` | Own `RawAgentRequest`, `AgentRequest`, validation errors, and `ProposedAction` construction from analysis |
| `RVEngine` | `evaluate`, `evaluateWithSemantics`, `analyzeSemantics`, `unwrapCommand`, `applySemantics` | Own **normalize only**: `AgentRequest` → `Result<ProposedAction, _>` via `analyzeSemantics`. Do not call pack evaluate or policy |
| `RVHooks` | Host stdin codecs, `HookRequest`, `hookWire` | Small bridge: `HookRequest.shell` → `AgentRequest`. Reuse `OpenCodeHostCodec.decode`. Do not add a second JSON parser |
| `RVPolicy` | `PolicyGate`, typed rules, pending store | **Do not touch** |
| `RVService` | Hook evaluate door, approvals, XPC/unix | **Do not touch** |
| `RVCLI` | Commands including `hook` | **Do not add** `rv agent` / `rv opencode` |
| `RVHistory` | Deny-only JSONL ledger (200 rows / 7 days) | **Do not extend** |

### 5.3 Existing types (reuse, do not clone)

**Ingress (hook door, stays):**

- `HookRequest` (`Sources/RVHooks/HostCodec.swift`): `.shell`, `.file`, `.spend`
- `HookDecodeOutcome`: `.request`, `.foreign` (fail-open for other tools), `.malformed` (fail-closed)
- `OpenCodeHostCodec.decode` (`Sources/RVHooks/OpenCodeHostCodec.swift`): JSON `{ tool, args.command, cwd, sessionID|sessionId, hostAsk }`. Process tools are `bash` and `session.shell`. Empty command → `.malformed(.missingCommand)`. Non-shell → `.foreign`
- `HostCodec.proposedAction(from:)` builds **empty-effect** `ProposedAction` (fingerprint + supporting command only). Do not use this as the agent normalization path

**Identity / paths:**

- `HookHost` including `.opencode` (`Sources/RVDomain/HookHost.swift`)
- `SessionID` / `WorkingDirectory`: `init?(validating:)` fails on `""`; absence is `Optional`
- `ShellCommand`: raw string wrapper; **empty is representable**
- `ActionFingerprint.make(host:session:cwd:command:)` — host-door identity used by `EvaluationResult.pendingAction` and grants
- `GitAction.proposedAction` / `FilesystemAction.proposedAction` use **semantic** fingerprints (`shell:git.*` / `shell:fs.*`). Those are a different IR. **Do not** use them for this runtime path

**Semantics:**

- `analyzeSemantics(_:gitWorld:filesystemWorld:)` (`Sources/RVEngine/AnalyzeSemantics.swift`) — unwrap then git/filesystem analyzers. Pure
- `SemanticAnalysis`: `.git`, `.filesystem`, `.wrapper`, `.unwrapLimited`, `.unknown`
- `SemanticAction`: `.git` / `.filesystem` only (closed subject on `ShellAction.analysis`)
- `EvaluationResult.pendingAction(host:session:cwd:command:)` (`Sources/RVDomain/EvaluationResult.swift`) copies git/filesystem effects onto `ProposedAction.shell`. For `.wrapper`, `.unwrapLimited`, and `.unknown` it stores **empty effects and `analysis: nil`**, so unwrap-limited is **indistinguishable** from unknown on `ProposedAction`. The agent path must not inherit that loss: unwrap-limited must fail closed **before** a `ProposedAction` exists
- `ExecutingCommand` is the innermost unwrapped command text. It is **not** an authorized executable. Do not rename or wrap it as `ExecutableAction`

**Policy (later phases — do not call):**

- Pack door: `Decision` = allow / deny / indeterminate. **Never Ask** (`Sources/RVDomain/Decision.swift`)
- Semantic door: `ActionPolicyEngine.evaluate(action: ProposedAction, ...)` → `HardPolicyDecision` (`hardAllow` / `hardDeny` / `mandatoryHuman` / `reviewEligible`)
- Product Ask: `BoundReview` and `HookAuthorization` (`.allow` / `.denyPinned` / `.denyUnlockable` / `.ask`)
- `RVPolicy.PolicyDecision` is **allowlist / allow-once / rebase override**, not ALLOW/ASK/DENY. **Do not reuse that name** for authorization outcomes
- `PolicyGate` spends grants. Not this phase

**Approvals (later):** `PendingApproval`, `ApprovalID`, `PendingApprovalState` in `Sources/RVDomain/PendingApproval.swift`. Already typed. Do not invent a parallel pending type.

**Execution today:** `Process()` appears only in setup (`LaunchctlApplying`, `SystemctlApplying`). There is no agent executor and no sandbox launch.

**Audit today:** `RVHistory.DenialLedger` is deny-only, redacted, capped. Not a session/action lifecycle log.

**OpenCode bypasses (honest, current):** `Sources/RVHooks/Resources/hosts/rv-guard.js.tmpl` gates `tool.execute.before` for `bash` / `session.shell` and `shell.env`. Read / write / edit / grep / web / MCP / agent-spawned children are **not** mediated. A host that never calls the hook is not blocked. No OS containment exists.

### 5.4 Master-plan conflicts (smallest adjustments)

1. **Seatbelt / Landlock are not in this repository.** Phase 2 must introduce isolation backends. This phase must not stub fake containment types or claim `contained`.
2. **`PolicyDecision` is already taken** by pack-override gating. Future authorization enum must use a new name (`AuthorizationOutcome` or similar). Not this phase.
3. **`HookRequest` is not `AgentRequest`.** `.spend` is hook PolicyGate. Do not widen `HookRequest` into the runtime model and do not replace the hook door.
4. **`spec/` is gitignored.** The master plan file is local-only. This handoff in `docs/rv-agent/handoffs/` is the durable in-repo record.

### 5.5 Agreed vertical-slice path (Phase 0 exit)

First host: **OpenCode**. First operations: **process/shell** (`bash`, `session.shell`).

```text
OpenCode process tool
        ↓ OpenCodeHostCodec.decode          (exists; hook JSON stays in RVHooks)
        ↓ HookRequest.shell
        ↓ AgentRequest.validate             (this phase)
        ↓ analyzeSemantics                  (exists)
        ↓ ProposedAction                    (exists; proposal only)
        ↓ ActionPolicyEngine + BoundReview  (later)
        ↓ typed authorization / ExecutableAction  (later)
        ↓ RV LocalExecutor                  (later)
        ↓ IsolationBackend at launch        (later; Seatbelt / Landlock)
```

## 6. Existing components to reuse

Must reuse; must not duplicate:

- `OpenCodeHostCodec.decode` and fixtures under `Tests/RVHooksTests/Fixtures/opencode/`
- `HookRequest.shell` as the already-validated OpenCode process envelope (command present)
- `HookHost.opencode`, `SessionID`, `WorkingDirectory`, `ShellCommand`
- `analyzeSemantics` / `unwrapCommand` / `UnwrapLimits` / `analyzeGit` / `analyzeFilesystem`
- `ProposedAction.shell` + `ShellAction` + `ActionFingerprint.make(host:session:cwd:command:)`
- `EvaluationResult.pendingAction` **construction recipe** for git/filesystem/unknown — extract or twin a Domain helper; do not change hook `pendingAction` behavior
- `commandByteCap` (`65_536`) in `Sources/RVEngine/Evaluate.swift` — agent command size must match (see type model)
- Swift Testing style in `Tests/RVDomainTests/ProposedActionFileTests.swift`, `Tests/RVEngineTests/AnalyzeSemanticsTests.swift`, `Tests/RVHooksTests/OpenCodeHookTests.swift`

Must not create:

- A second OpenCode JSON envelope in `RVDomain`
- A second semantic analyzer or pack engine
- `ExecutableAction`, `AllowedAction`, `IsolationPolicy`, `EnforcementMode`, `LocalExecutor`, CLI launcher
- A new SPM library target (`RVAgent` / `RVRuntime`) — YAGNI until launch/executor would force `Process` into Domain

## 7. Architecture for this phase

```text
                    RVHooks                         RVDomain                    RVEngine
                 ┌─────────────┐                 ┌────────────┐              ┌──────────────┐
OpenCode stdin → │ decode      │ → HookRequest   │            │              │              │
                 │ .shell only │ ───────────────►│ validate   │ → AgentRequest
                 └─────────────┘   or Raw strings│            │───────► analyzeSemantics
                                                 │            │              │      ↓
                                                 │ proposed   │◄─────────────│ normalize
                                                 │ (from      │              └──────────────┘
                                                 │  analysis) │
                                                 └─────┬──────┘
                                                       ▼
                                                 ProposedAction
                                                 (not executable)
```

Control flow is a pure pipeline. No process spawn, no sockets, no menu bar, no pack files, no policy bind.

OpenCode tool IDs stay in `RVHooks`. Domain sees only “process request” values.

## 8. Type model

### `RawAgentRequest`

- **Represents:** Untrusted process-request fields before validation.
- **Invariant:** May be incomplete, empty, or oversized. Holding one never implies a valid session request.
- **Who constructs:** Tests, future adapter, hook bridge. Public initializer is allowed.
- **Who consumes:** `AgentRequest.validate` only.
- **Shape (illustrative names; keep closed and small):**

```text
enum RawAgentRequest {
    case process(RawAgentProcessRequest)
}

struct RawAgentProcessRequest {
    var host: HookHost
    var command: String
    var workingDirectory: String?
    var session: String?
}
```

Do not put OpenCode `tool` / `hostAsk` on this type. Tool classification is finished before Domain sees a process case.

### `AgentRequest`

- **Represents:** A validated process request the runtime may **normalize**. Not a policy decision. Not a capability.
- **Invariant:** Command is nonempty after trim and `utf8.count <= AgentRequestLimits.maxCommandUTF8Count`. Empty string cwd/session are not stored (`nil` via existing validators). File and spend requests are unrepresentable.
- **Who constructs:** Only `AgentRequest.validate` (and an overload that takes already-typed `ShellCommand` + `WorkingDirectory?` + `SessionID?`). `AgentProcessRequest` initializer must be `package` or equivalent so tests use `@testable import` and production code cannot bypass validate.
- **Who consumes:** `normalizeAgentRequest` in `RVEngine`.

```text
enum AgentRequest {
    case process(AgentProcessRequest)
}

struct AgentProcessRequest {
    var host: HookHost
    var command: ShellCommand
    var workingDirectory: WorkingDirectory?
    var session: SessionID?
}
```

Reuse `HookHost`. Do not invent `AgentID` this phase.

### `AgentRequestLimits`

- `maxCommandUTF8Count` must equal `commandByteCap` (`65_536`).
- Add an `RVEngineTests` assertion that the two constants stay equal so Domain does not import Engine.

### `AgentRequestValidationError`

Exhaustive typed error, `Sendable`, `Equatable`. Minimum cases:

- `missingCommand` — nil, empty, or whitespace-only
- `commandTooLarge` — exceeds `maxCommandUTF8Count`
- `unsupportedKind` — hook bridge rejects `.file` and `.spend`

No stringly error bag.

### `AgentNormalizationError`

- `unwrapLimited` — `analyzeSemantics` innermost is `.unwrapLimited`
- Optional wrap of validation if you compose validate+normalize; prefer keeping validate separate

Unknown analysis is **not** an error. It becomes `ProposedAction.shell` with empty effects / nil `analysis`, same as today’s `pendingAction` unknown path. Policy will later fail closed on uncovered actions. This phase must not invent authorization.

### `ProposedAction` construction (new Domain helper)

Add a focused Domain function, for example:

```text
ProposedAction.process(
    host:session:cwd:command:analysis:
) -> Result<ProposedAction, AgentNormalizationError>
```

Rules:

| `analysis.innermost` | Result |
| --- | --- |
| `.unwrapLimited` | `.failure(.unwrapLimited)` — no `ProposedAction` |
| `.git` / `.filesystem` | `.success(.shell)` with effects/resources/analysis from that action, fingerprint `ActionFingerprint.make(host:session:cwd:command:)`, `supportingCommand` = command, `scope.workingDirectory` = cwd |
| `.unknown` | `.success(.shell)` with empty effects, `analysis: nil`, same fingerprint rule |
| `.wrapper` | Use `innermost` (never treat wrappers as a separate action family) |

Do not change `EvaluationResult.pendingAction` (hook door keeps dropping unwrap-limited on the stored action; hook policy still sees `EvaluationResult.analysis`).

### Types this phase must **not** add

`ExecutableAction`, `AllowedAction`, `ApprovedAction`, `DeniedAction` (runtime), `IsolationPolicy`, `IsolationGuarantees`, `EnforcementMode`, `IsolationBackend`, `AgentAdapter` protocol, `Executor`.

## 9. Functional boundaries

| Layer | Allowed |
| --- | --- |
| Pure logic | `AgentRequest.validate`, OpenCode-independent field checks, `ProposedAction.process(...)`, `normalizeAgentRequest` = `analyzeSemantics` + Domain construction |
| State transitions | None. No session actor, no pending ledger writes |
| Effects | None. No `Process`, files, sockets, XPC, menu bar, clocks required |
| Platform | None. No `#if os` isolation code |
| Permitted mutable state | None beyond local function vars |

No `Task.detached`, no `@unchecked Sendable`, no singleton, no `Manager`. No protocol whose only job is “abstraction.”

`RVHooks` bridge is a pure function: `HookRequest` → `Result<AgentRequest, AgentRequestValidationError>`.

## 10. Exact implementation work

1. Add Domain types and `AgentRequest.validate` for `RawAgentRequest.process` in a new file such as `Sources/RVDomain/AgentRequest.swift`. Reject missing/whitespace/oversized commands. Map empty cwd/session strings to `nil` via `WorkingDirectory(validating:)` / `SessionID(validating:)`.
2. Add a typed overload `AgentRequest.validate(host:command:workingDirectory:session:)` for values that already passed hook decode.
3. Add `ProposedAction.process(host:session:cwd:command:analysis:)` (name may vary) in Domain next to `ProposedAction` / `EvaluationResult`. Fail on unwrap-limited. Reuse the git/filesystem/unknown construction of `pendingAction` **including host-door fingerprints**.
4. Add `normalizeAgentRequest(_:gitWorld:filesystemWorld:) -> Result<ProposedAction, AgentNormalizationError>` in a new file such as `Sources/RVEngine/NormalizeAgentRequest.swift`. Call `analyzeSemantics` only. Default worlds `.unprobed` (same as analyzer defaults). Do not call `evaluate`, `evaluateWithSemantics`, `applySemantics`, `ActionPolicyEngine`, or `PolicyGate`.
5. Add `agentRequest(from: HookRequest)` in `Sources/RVHooks` (new small file). `.shell` → typed validate. `.file` / `.spend` → `.failure(.unsupportedKind)`. Do not decode JSON here.
6. Domain tests: validation table (empty, whitespace, oversized, valid OpenCode-shaped fields, nil cwd/session).
7. Engine tests: normalize `git reset --hard` → git reset + `workingTreeDiscard`; benign `git status` / `echo hello` → `ProposedAction.shell` without claiming git analysis you cannot prove; `rm` / protected-path examples using existing analyzer expectations; unwrap-limited fixtures from `AnalyzeSemanticsTests` (`bash -c git reset --hard`, `zsh -c $CMD`) produce **no** `ProposedAction`.
8. Hooks tests: existing OpenCode fixtures `allow-git-status.json` and `deny-git-reset-hard.json` plus `session.shell` decode → `AgentRequest.process` with `host == .opencode`. Non-shell fixture stays `.foreign` at decode (no `AgentRequest`). File/spend `HookRequest` values fail the bridge.
9. One composition test (add `RVEngine` to `RVHooksTests` dependencies in `Package.swift` if needed): OpenCode stdin fixture → decode → `AgentRequest` → `normalizeAgentRequest` → `ProposedAction`. Assert the result type is `ProposedAction` and that no new executable type is produced.
10. Assert `AgentRequestLimits.maxCommandUTF8Count == commandByteCap` in Engine tests.
11. Do not register CLI commands. Do not edit host plugin JS except if a comment were required — it is not required.
12. Run focused tests: `RVDomainTests` filter AgentRequest, `RVEngineTests` filter NormalizeAgentRequest / AnalyzeSemantics (no regressions), `RVHooksTests` filter OpenCode / AgentRequest.

## 11. Files likely to change

**New:**

- `Sources/RVDomain/AgentRequest.swift`
- `Sources/RVDomain/AgentNormalization.swift` or helper on `ProposedAction` in an existing Domain file
- `Sources/RVEngine/NormalizeAgentRequest.swift`
- `Sources/RVHooks/AgentRequestBridge.swift` (name flexible)
- `Tests/RVDomainTests/AgentRequestTests.swift`
- `Tests/RVEngineTests/NormalizeAgentRequestTests.swift`
- `Tests/RVHooksTests/OpenCodeAgentRequestTests.swift` (or extend `OpenCodeHookTests.swift` if smaller)

**Existing, small edits only:**

- `Package.swift` — `RVHooksTests` may depend on `RVEngine` for the composition test
- `Sources/RVDomain/ProposedAction.swift` or `EvaluationResult.swift` only if the shared construction helper lives there. **Do not change** `pendingAction` semantics

**Do not change:** `ActionPolicyEngine.swift`, `PolicyGate.swift`, `HookDispatch.swift` evaluate path, CLI `RV.swift`, OpenCode plugin templates, history ledger.

## 12. Architecture constraints

- Functional core: values in, values out. Effects stay unborn.
- Illegal states unrepresentable: no `AgentRequest` with empty command; no process+file combo; no `approved: Bool`.
- `ProposedAction` must remain unauthorized. The public normalize API returns `ProposedAction`, not an executable wrapper.
- Host JSON and OpenCode tool names stay in `RVHooks`.
- Do not replace or bypass `HookRequest` / `hookWire`.
- Do not introduce a parallel action IR.
- Do not couple Domain to Engine, Process, or hooks.
- Swift 6 / `Sendable` on every new type. No `@unchecked Sendable`.
- Do not add isolation or executor scaffolding “for later.”

## 13. Security invariants

- Validation failure produces no `AgentRequest`.
- Unwrap-limited produces no `ProposedAction`.
- No API added in this phase accepts `ProposedAction` and performs an effect.
- Normalize must not treat supporting command text as sufficient to skip `analyzeSemantics`.
- Fingerprints for this path are host-door (`ActionFingerprint.make`), never semantic `shell:git.*` grant keys.
- Hook `.foreign` (Read and other OpenCode tools) must not be coerced into `AgentRequest.process`.
- `.spend` must not become a runtime process request.
- Oversized commands never reach the analyzer.

## 14. Enforcement guarantee

**This phase provides no new enforcement.**

| Mode | This phase |
| --- | --- |
| observed | Types and tests only. No live session telemetry change |
| mediated | Unchanged. Still only when a host calls `rv hook` |
| contained | **Not provided.** Seatbelt/Landlock do not exist |

Limitations (must remain documented; do not paper over):

- OpenCode file tools, web, MCP, and child processes bypass this model
- Allowed hook evaluations still execute **inside the host**, not an RV executor
- Producing `ProposedAction` is not permission to run
- No OS inheritance, no sandbox profile, no Landlock ruleset

## 15. Failure behavior

Fail closed:

| Input | Outcome |
| --- | --- |
| Missing / empty / whitespace command | `missingCommand`, no `AgentRequest` |
| Command `utf8.count > 65536` | `commandTooLarge`, no `AgentRequest` |
| `HookRequest.file` or `.spend` | `unsupportedKind`, no `AgentRequest` |
| Unwrap-limited analysis | `unwrapLimited`, no `ProposedAction` |
| Unknown analysis | `ProposedAction` exists; **not** an allow; **not** an executable |
| Decode `.foreign` | No bridge call; no process request |

Never map failure to “run the raw string anyway.”

## 16. Tests

### Pure unit (`RVDomainTests`)

- Valid process raw request (OpenCode-shaped host/cwd/session/command) → `.process`
- Empty, `""`, whitespace command → `missingCommand`
- Empty cwd/session strings → `nil` fields, request still valid
- Command of `commandByteCap + 1` UTF-8 bytes → `commandTooLarge`
- `AgentProcessRequest` cannot be built from public API without validate (compile-time / package-init; if only package init, `@testable` is the test seam)

### Normalize / reducer (`RVEngineTests`)

- `git reset --hard` → `ProposedAction.shell` with `gitAction == .reset(mode: .hard, target: nil)` and `.workingTreeDiscard` in effects
- `echo hello` or `git status` → success `ProposedAction.shell`; do not invent a git case the analyzer does not emit
- Filesystem delete / protected-path case already pinned in `AnalyzeSemanticsTests` (e.g. `env -C /tmp/.ssh rm config`) → filesystem analysis on the proposed shell action
- `bash -c git reset --hard` and `zsh -c $CMD` → `.failure(.unwrapLimited)`
- `bash -c 'git reset --hard'` → success with wrapper peeled (innermost git reset), same as analyzer
- `AgentRequestLimits.maxCommandUTF8Count == commandByteCap`
- Return type is `ProposedAction` (no executable type in the module)

### Integration (`RVHooksTests`)

- `allow-git-status.json` → decode `.shell` → `AgentRequest` host `.opencode`, command `git status`
- `deny-git-reset-hard.json` → decode → `AgentRequest` command `git reset --hard`
- `session.shell` stdin used in `OpenCodeHookTests` → `AgentRequest`
- `allow-non-shell-read.json` → `.foreign`, no `AgentRequest`
- Synthetic `HookRequest.file` / `.spend` → `unsupportedKind`

### Composition

- One OpenCode process fixture through decode → validate → normalize → `ProposedAction` for `git reset --hard`

### Platform / containment / adversarial OS

None this phase (no backend).

### Adversarial / bypass (type-level)

- Prove file-tool and spend cannot enter `AgentRequest`
- Prove unwrap-limited cannot enter `ProposedAction`
- Prove normalize does not call or require packs

## 17. Acceptance criteria

- [x] `RawAgentRequest` / `AgentRequest` exist as immutable `Sendable` values; process is the only inhabited request family
- [x] `AgentRequest` is constructible only through validation (no public bypass initializer)
- [x] Empty, whitespace, and oversized commands fail closed with typed errors
- [x] Empty cwd/session strings become `nil` via existing validators
- [x] `HookRequest.shell` bridges to `AgentRequest`; `.file` and `.spend` do not
- [x] OpenCode `bash` and `session.shell` fixtures reach `AgentRequest` through `OpenCodeHostCodec.decode` (no second JSON parser)
- [x] OpenCode non-shell fixture remains `.foreign` and does not become `AgentRequest`
- [x] `normalizeAgentRequest` uses `analyzeSemantics` only and returns `ProposedAction` with host-door fingerprints
- [x] Git reset --hard normalizes to the existing `GitAction.reset(mode: .hard, target: nil)` proposal
- [x] Unwrap-limited commands produce no `ProposedAction`
- [x] Unknown / benign commands may produce `ProposedAction` but no executable/authorized type exists
- [x] No pack evaluate, `PolicyGate`, CLI launcher, isolation types, or executor were added
- [x] `pendingAction` hook semantics are unchanged
- [x] Required tests exist and pass
- [x] This handoff’s Implementation Completion Notes are filled in by the coding agent

## 18. Non-goals

- `rv <agent>` / `rv opencode` CLI
- Seatbelt, Landlock, Tart, Apple Container, Linux containers
- `IsolationPolicy` / `EnforcementMode` / `IsolationBackend`
- `ExecutableAction` / executor / `ExecutionContext`
- Policy ALLOW/ASK/DENY wiring, `ActionPolicyEngine` calls, approvals, allow-once
- File-tool `AgentRequest` cases
- Second host adapter
- MCP, secrets broker, audit event stream
- Changing OpenCode plugin mediation coverage
- New SPM library product
- Replacing `HookRequest` or changing hook fail-open `.foreign` behavior

## 19. Risks / questions discovered

| Item | Resolution from the tree |
| --- | --- |
| Is `HookRequest` enough? | No. `.spend` is hook-only. New `AgentRequest` is the runtime type; bridge only `.shell` |
| Should normalize run `evaluateWithSemantics`? | No. That applies pack + semantic **policy**. This phase is semantic **description** only |
| `git status` analysis? | No `GitAction` case for status. Expect unknown/`nil` analysis, still a valid proposal |
| Fingerprint which spelling? | Host-door `ActionFingerprint.make`. Semantic `shell:git.*` stays on `GitAction.proposedAction` for policy IR |
| Where do OpenCode tool IDs live? | `OpenCodeHostCodec` / plugin only |
| New module? | Not this phase |
| `PolicyDecision` name? | Already used. Deferred |

## 20. Handoff notes for next phase

After this phase passes planning verification, the next smallest slice of master-plan Phase 1 is typed authorization outcomes **without** launch or executor:

- Compile `ProposedAction` through existing `ActionPolicyEngine` + `BoundReview` into a **new** enum (not `RVPolicy.PolicyDecision`)
- `hardAllow` / allow bind → authorized value; `mandatoryHuman` → pending (reuse `PendingApproval` identities, do not execute); deny → no authorized value
- Introduce `ExecutableAction` only when an executor type is about to consume it (may be the following slice or Phase 3)
- Isolation **values** (`IsolationPolicy`, `IsolationGuarantees`, `EnforcementMode`) can land as pure Domain enums before Phase 2 applies Seatbelt/Landlock — still no process launch
- First host remains OpenCode; file tools and extra hosts stay out until the adapter phase
- Remember: `ExecutingCommand` ≠ executable capability; hook `pendingAction` still erases unwrap-limited on the stored `ProposedAction`

---

# Implementation Completion Notes

## Implementation Status

Complete

## Implementation Summary

The first `rv <agent>` trust transition is now a typed, effect-free pipeline: untrusted process fields become `AgentRequest` only through fail-closed validation, then `normalizeAgentRequest` runs existing `analyzeSemantics` and builds a host-door `ProposedAction`. OpenCode process tools (`bash`, `session.shell`) reach that path through the existing `OpenCodeHostCodec` plus a Hooks bridge. File/spend/foreign stay out. Unwrap-limited analysis produces no `ProposedAction`. No capability, executor, isolation backend, pack evaluate, policy bind, or CLI launcher was added.

## Files Changed

**New**

- `Sources/RVDomain/AgentRequest.swift` — `RawAgentRequest`, `AgentRequest`, limits, validation errors
- `Sources/RVDomain/AgentNormalization.swift` — `AgentNormalizationError`, `ProposedAction.process`, shared `hostDoorShell`
- `Sources/RVEngine/NormalizeAgentRequest.swift` — `normalizeAgentRequest` (`analyzeSemantics` only)
- `Sources/RVHooks/AgentRequestBridge.swift` — `agentRequest(from: HookRequest)`
- `Tests/RVDomainTests/AgentRequestTests.swift`
- `Tests/RVEngineTests/NormalizeAgentRequestTests.swift`
- `Tests/RVHooksTests/OpenCodeAgentRequestTests.swift`

**Existing, small edits**

- `Package.swift` — `RVHooksTests` also depends on `RVEngine` for the composition test
- `Sources/RVDomain/EvaluationResult.swift` — `pendingAction` now calls the shared helper; behavior unchanged
- `docs/rv-agent/handoffs/phase-01-agent-request-boundary.md` — this completion record

**Not changed (intentionally)**

- `ActionPolicyEngine.swift`, `PolicyGate.swift`, hook evaluate dispatch, `RV.swift`, OpenCode plugin templates, `RVHistory`, isolation/executor types
- `Package.resolved` is **not** part of this phase. Darwin `swift test` / SourceKit resolve rewrites `originHash` (because `Package.swift` gained a test dependency) and drops Linux-only swift-crypto/asn1 pins. Do not commit that rewrite.

## Architecture Decisions Made

- Process is the only inhabited request family. File and spend stay on `HookRequest` and fail the bridge with `unsupportedKind`.
- Validation and normalize stay separate. `AgentRequest` is “may normalize,” not “may run.”
- `AgentProcessRequest` stored properties are immutable `let`. The production constructor is `AgentRequest.validate`. The memberwise initializer is `internal` so `@testable` Domain tests can see it and sibling modules (`RVEngine`, `RVHooks`) cannot bypass validate. `package` would have been visible package-wide.
- Command size is twinned: `AgentRequestLimits.maxCommandUTF8Count == 65_536`, kept equal to `commandByteCap` by an Engine test. Domain does not import Engine; `Evaluate.swift` was not edited.
- `ProposedAction.process` fails closed on `.unwrapLimited`. Hook `pendingAction` still stores an empty-effect shell action for that analysis via shared `ProposedAction.hostDoorShell`.
- Fingerprints on this path are host-door `ActionFingerprint.make`. Semantic `shell:git.*` / `shell:fs.*` stay on `GitAction.proposedAction` / `FilesystemAction.proposedAction`.
- Unknown / `git status` / `echo hello` succeed as empty-effect `ProposedAction.shell` with `analysis: nil`. That is not an allow.
- Host JSON and OpenCode tool IDs stay in `RVHooks`. The bridge does not parse stdin.

## Deviations From Handoff

- `RawAgentProcessRequest.command` is `String?`, not `String`. The error table includes nil; Optional is the honest untrusted field.
- Illustrative sketches used `var` fields; shipped types are `let` to match the immutability acceptance criterion.
- `AgentProcessRequest` init is `internal`, not `package`. Intent was “tests via `@testable`, production cannot bypass.” In SwiftPM, `package` is visible to `RVEngine` / `RVHooks`.
- Shared construction lives as `ProposedAction.hostDoorShell` rather than a twinned copy inside `pendingAction`.
- `RVHooksTests` depending on `RVEngine` is allowed by this handoff and triggers preflight `test-target-isolation` WARN (2 module deps). Not a failure.

## Tests Added / Updated

- `AgentRequestTests`: validation table (nil/empty/whitespace/oversize/at-cap, empty cwd/session → nil, typed hook overload, process-only family, internal-init seam); `ProposedAction.process` git/wrapper/unknown/filesystem/unwrap-limited; hook `pendingAction` still drops unwrap-limited on the stored action
- `NormalizeAgentRequestTests`: `git reset --hard`; `echo hello` / `git status` empty-effect proposals; `env -C /tmp/.ssh rm config` filesystem; `bash -c git reset --hard` and `zsh -c $CMD` → no `ProposedAction`; quoted `bash -c 'git reset --hard'` peels to git reset; cap equality; normalize without packs
- `OpenCodeAgentRequestTests`: `allow-git-status.json` / `deny-git-reset-hard.json` / `session.shell` → `AgentRequest.process` host `.opencode`; `allow-non-shell-read.json` stays `.foreign`; synthetic `.file` / `.spend` and decoded `hostAsk` spend → `unsupportedKind`; composition decode → validate → normalize → `ProposedAction` for git reset --hard

## Verification Performed

### Build

`Scripts/swift-6.4 test` compiled the package (Swift 6.4, language mode 6). No new production warnings in the files this phase added.

### Unit Tests

Passed:

- `--filter AgentRequest` — `AgentRequest` suite (16 tests)
- `--filter NormalizeAgentRequest` — `NormalizeAgentRequest` suite (7 tests)
- `--filter AnalyzeSemantics` — existing analyzer suite, no regressions
- `--filter RVDomainTests` — 340 tests / 30 suites, including `EvaluationResult.pendingAction`
- `--filter RVEngineTests` — 368 tests / 25 suites

### Integration Tests

Passed:

- `--filter OpenCode` / `--filter AgentRequest` — `OpenCode AgentRequest` plus existing OpenCode hook/decode tests
- `--filter RVHooksTests` — 384 tests / 5 suites, including the decode → `AgentRequest` → `normalizeAgentRequest` → `ProposedAction` composition

### Platform / Containment Tests

None this phase. No isolation backend, no process launch, no `#if os` containment.

### Adversarial / Bypass Tests

Passed: file-tool and spend cannot enter `AgentRequest`; OpenCode Read stays `.foreign`; unwrap-limited cannot enter `ProposedAction` on the agent path; oversized/whitespace commands never become `AgentRequest`; normalize does not require packs.

### Preflight (structural)

Passed: value-types, no force-unwrap, evaluate-pure, graph-no-engine-packs. WARN only: `RVHooksTests` lists 2 module deps (`RVHooks`, `RVEngine`).

## Known Limitations

Unchanged from §14. This phase still provides no enforcement.

- OpenCode file tools, web, MCP, and child processes bypass this model
- Allowed hook evaluations still execute inside the host, not an RV executor
- Producing `ProposedAction` is not permission to run
- No OS inheritance, sandbox profile, or Landlock ruleset
- Hook `.foreign` remains fail-open at the host door
- Hook `pendingAction` still erases unwrap-limited on the stored `ProposedAction`; agent normalize does not

## Technical Debt Introduced

- Twin command-size constants (`AgentRequestLimits.maxCommandUTF8Count` and `commandByteCap`) kept in sync only by test
- `RVHooksTests` 2-module dependency trips a preflight warning
- `AgentProcessRequest`’s `internal` init does not re-validate; illegal empty commands are still representable inside `RVDomain` and `@testable` tests. Public API cannot construct them.
- Darwin `swift test` / SourceKit resolve rewrites `Package.resolved` (new originHash + drop Linux-only pins). Leave the committed pins as-is; do not include that rewrite in this phase.

## Important Context for Next Phase

- Next smallest slice remains typed authorization **without** launch or executor: compile `ProposedAction` through existing `ActionPolicyEngine` + `BoundReview` into a **new** enum. Do not reuse `RVPolicy.PolicyDecision`.
- `hardAllow` / allow bind → authorized value; `mandatoryHuman` → pending (reuse `PendingApproval` identities, do not execute); deny → no authorized value
- Do not introduce `ExecutableAction` until an executor is about to consume it
- Isolation **values** may land as pure Domain enums; still no process launch
- First host remains OpenCode; file tools stay out of `AgentRequest`
- `ExecutingCommand` is still not a capability
- Call `normalizeAgentRequest` / `ProposedAction.process` when unwrap-limited must fail closed. Do not reuse hook `pendingAction` for the runtime path
- `AgentRequest.validate` already enforces the 65_536 UTF-8 cap; do not send raw strings to `analyzeSemantics`
- Composition test lives in `RVHooksTests` and needs the `RVEngine` test dependency

## Acceptance Criteria Final State

All §17 checkboxes are marked done by this implementation. The next planning session still verifies independently.

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

Independent planning review of `Sources/RVDomain/AgentRequest.swift`, `AgentNormalization.swift`, `Sources/RVEngine/NormalizeAgentRequest.swift`, `Sources/RVHooks/AgentRequestBridge.swift`, and the three new test files. Focused suites passed on this tree: `AgentRequest` (16), `NormalizeAgentRequest` (7), `OpenCode AgentRequest` (7). `normalizeAgentRequest` calls only `analyzeSemantics`. File/spend/foreign cannot enter `AgentRequest`. Unwrap-limited produces no `ProposedAction` on the agent path. Hook `pendingAction` still drops unwrap-limited via shared `hostDoorShell`. No `ExecutableAction`, isolation backend, CLI launcher, pack evaluate, or `PolicyGate` wiring. Coding-agent deviations (`command` as `String?`, `internal` rather than `package` init, shared helper) preserve the invariants. Status string `Implemented` was not a planning-complete state; this verification is the Complete mark.
