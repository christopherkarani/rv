# Phase 02 — Typed authorization outcomes

## 1. Phase

**Name:** Typed authorization outcomes (allowed / pending / denied)

**Master-plan reference:** `RV_Agent_Implementation_Plan_v2.docx` Phase 1 — Typed runtime core (second implementation slice)

**Tickets covered:** AGENT-003 (proposed → allowed / pending / denied distinction only). Not AGENT-010 (`ExecutableAction` / executor). Not AGENT-006 (isolation values).

**Previous phase:** `docs/rv-agent/handoffs/phase-01-agent-request-boundary.md` — planning-verified Complete on 2026-09-20.

## 2. Status

Implemented

## 3. Objective

Compile an existing `ProposedAction` through `ActionPolicyEngine` and `ReviewBind` into a **new** exhaustive authorization type so allow, ask, and deny are distinct values, and so a denied or pending proposal cannot be represented as an allowed capability.

## 4. Why this phase exists

Phase 01 made a process request into a `ProposedAction`. That value is still only a proposal. The hook door then collapses product Ask onto `Decision.deny` (`BoundReview.decision`) or quietly allows `reviewEligible` via `HostNativeAsk.hookBound`. The runtime must not inherit either collapse.

This slice unlocks the second trust transition:

```text
ProposedAction
        ↓ ActionPolicyEngine.evaluate (existing)
HardPolicyDecision
        ↓ ReviewBind.apply (existing)
BoundReview
        ↓ map (this phase)
AgentAuthorization
  ├─ allowed(AllowedAction)     // capability to proceed later; not executable yet
  ├─ pending(PendingAuthorization) // ASK intent; not a store write
  └─ denied(DeniedAction)       // no allowed value exists
```

The invariant remains: **the existence of an action does not imply permission to execute it.** After this phase, **the existence of `AllowedAction` still does not execute anything.** It only proves policy authorized the proposal. `ExecutableAction` and `LocalExecutor` come later.

## 5. Current repository state

Inspected after Phase 01 verification on this tree (`8f0df68` / equivalent AgentRequest sources).

### 5.1 What Phase 01 landed

- `RawAgentRequest` / `AgentRequest` — process only (`Sources/RVDomain/AgentRequest.swift`)
- `normalizeAgentRequest` — `analyzeSemantics` only (`Sources/RVEngine/NormalizeAgentRequest.swift`)
- `ProposedAction.process` — unwrap-limited fails closed (`Sources/RVDomain/AgentNormalization.swift`)
- `agentRequest(from: HookRequest)` — `.shell` only (`Sources/RVHooks/AgentRequestBridge.swift`)
- No `ExecutableAction`, no isolation types, no `rv <agent>` CLI

### 5.2 Policy machinery to reuse (do not clone)

| Type / function | File | Use |
| --- | --- | --- |
| `ActionPolicyEngine.evaluate(action:context:policy:gitWorld:)` | `Sources/RVDomain/ActionPolicyEngine.swift` | Hard verdict. **Pass `gitWorld` explicitly.** Default `.unprobed` matches the Engine door |
| `ActionPolicyEngine.evaluate(action:context:policy:)` | same | ReviewContext-only overload **treats git as probed**. Do not use this for the runtime door |
| `ActionPolicyEngine.bind` | same | Calls the probed overload. **Do not call** for this door |
| `ReviewBind.apply(hardDecision:review:)` | `Sources/RVDomain/HardPolicyDecision.swift` | Advisory review bind. Missing/weak/conflicting review on `reviewEligible` → `mandatoryHuman(fallback)` |
| `HardPolicyDecision` | same | `hardAllow` / `hardDeny` / `mandatoryHuman` / `reviewEligible` |
| `BoundReview` | same | `allow` / `deny` / `mandatoryHuman`. `.decision` maps Ask → pack `Decision.deny` — **do not use `.decision` as the runtime outcome** |
| `EffectiveActionPolicy` | `ActionPolicyEngine.swift` | overlay + packFallback + typed rules |
| `ActionPolicyVerdict` / `ActionPolicyExplanation` | same | keep explanation on the authorized/denied/pending value |
| `ApprovalReason` | `Sources/RVDomain/PendingApproval.swift` | `.mandatoryHuman` / `.reviewAsk` / `.hostAsk` |
| `PendingApproval` / `PendingApprovalRequest` | same | **Do not construct** in this phase (needs `Date` / store IDs) |
| `ActionReview` / `ActionReviewerError` | `Sources/RVDomain/ActionReviewer.swift` | Optional review input. Errors: `.unsupported`, `.timeout` |
| `HostNativeAsk.hookBound` | `Sources/RVDomain/HostNativeAsk.swift` | Hook product: `reviewEligible` → **`.allow`**. **Forbidden** on the agent runtime door |
| `PolicyGate` / `RVPolicy.PolicyDecision` | `Sources/RVPolicy/PolicyGate.swift` | Allowlist / allow-once overrides. **Do not touch or reuse the name** |
| `HookAuthorization` | `Sources/RVDomain/HookAuthorization.swift` | Hook ask/mint. **Do not reuse** |

### 5.3 Builtin outcomes already proven in tests

Reuse `ActionPolicyFixtures` in `Tests/RVDomainTests/ActionPolicyEngineTests.swift` rather than inventing new IR:

| Fixture | `HardPolicyDecision` |
| --- | --- |
| `forcePush()` on shared `main` | `.hardDeny(remoteSharedBranch)` |
| `forcePush(branchName: "topic")` on private context | `.mandatoryHuman(remoteBranchAsk)` |
| `filesystem` overwrite/create `insideRepository` | `.hardAllow` (`inRepository`) |
| `filesystem` write `outsideRepository` / protected path | `.hardDeny` |
| `uncovered(supportingCommand: "echo hello")` | `.reviewEligible(fallback: uncovered)` |
| working-tree discard / `git reset --hard` effects | `.hardDeny(workingTreeDiscard)` |

`GitAction.push` only adds `.remoteSharedBranchMutation` when force is not `.none`. A non-force `git push origin main` therefore normalizes to **uncovered / reviewEligible** today. This phase must treat that as **pending** when no review is supplied (fail closed), not as hook-style quiet allow.

### 5.4 Name collisions (do not create)

- `RVPolicy.PolicyDecision` — pack override wrapper
- `Decision` — pack allow/deny/indeterminate, never Ask
- `ExecutingCommand` — unwrapped command text, not a capability
- `AllowedAction` as a boolean or `approved: true` on `ProposedAction`

## 6. Existing components to reuse

Must reuse:

- `ActionPolicyEngine.evaluate(action:context:policy:gitWorld:)`
- `ReviewBind.apply`
- `EffectiveActionPolicy`, `ReviewContext`, `GitAnalysisWorld`
- `ActionPolicyExplanation`
- `ApprovalReason` (values only)
- Phase 01 `normalizeAgentRequest` / `ProposedAction.process` for composition tests
- `ActionPolicyFixtures` and existing engine tests as the oracle for hard verdicts
- `ActionReview.make` / `ActionPolicyFixtures.qualifiedAllow` for review-bind cases

Must not create:

- A second policy engine or rule table
- `ExecutableAction`, `LocalExecutor`, `ExecutionContext`
- `IsolationPolicy` / `EnforcementMode` / `IsolationBackend`
- CLI `rv agent` / `rv opencode`
- Pending-approval store writes, clocks, minted `ApprovalID`s
- Changes to `HostNativeAsk.hookBound` or hook evaluate
- File-tool `AgentRequest` cases

## 7. Architecture for this phase

```text
ProposedAction
        │
        │  ActionPolicyEngine.evaluate(..., gitWorld:)
        ▼
HardPolicyDecision + ActionPolicyExplanation
        │
        │  ReviewBind.apply(hardDecision, review)
        ▼
BoundReview
        │
        │  AgentAuthorization.decide  (pure map)
        ▼
┌────────────────┬─────────────────────────┬─────────────────┐
│ AllowedAction  │ PendingAuthorization    │ DeniedAction    │
│ (hardAllow or  │ (mandatoryHuman, or     │ (hardDeny, or   │
│  review allow) │  reviewEligible without │  review deny)   │
│                │  a sufficient allow)    │                 │
└────────────────┴─────────────────────────┴─────────────────┘
        │
        ✕ no Process, no store, no executor
```

Default `review` is `.failure(.unsupported)`: no reviewer ran. That is fail-closed for `reviewEligible`.

Callers that later have a real `ActionReview` pass `.success(review)`. They await the reviewer **outside** this function (already the Domain rule for `ReviewBind`).

## 8. Type model

### `AllowedAction`

- **Represents:** A proposal that policy authorized.
- **Invariant:** Can only be produced by `AgentAuthorization.decide` (or a package/internal mapper it owns). Holding one is not a permit to spawn a process.
- **Who constructs:** The decide mapper only. `init` is `internal` / `package` as needed so sibling modules cannot mint one from a raw `ProposedAction`.
- **Who consumes:** Tests now; later `ExecutableAction.policyAllowed` / executor. Nothing in this phase consumes it for effects.
- **Payload:** `action: ProposedAction`, `explanation: ActionPolicyExplanation`

### `DeniedAction`

- **Represents:** A proposal that policy rejected. No allowed capability exists for this decision.
- **Invariant:** Distinct type from `AllowedAction`. Cannot be passed where `AllowedAction` is required.
- **Who constructs:** decide mapper only.
- **Who consumes:** Tests / later adapter denial encoding.
- **Payload:** `action`, `deny: Deny`, `explanation`

### `PendingAuthorization`

- **Represents:** ASK intent. Human approval is required before an allowed value can exist.
- **Invariant:** Not `PendingApproval` (no `createdAt` / `expiresAt` / store identity). Not executable. Not `AllowedAction`.
- **Who constructs:** decide mapper only.
- **Who consumes:** Later approval effect layer will turn this into `PendingApprovalRequest` with clock + `ApprovalID`.
- **Payload:** `action`, `reason: ApprovalReason`, `deny: Deny`, `explanation`
- **Reason rule:**
  - `HardPolicyDecision.mandatoryHuman` → `.mandatoryHuman`
  - `HardPolicyDecision.reviewEligible` bound to `BoundReview.mandatoryHuman` → `.reviewAsk`
  - Do not emit `.hostAsk` (hook spend-first)

### `AgentAuthorization`

```text
enum AgentAuthorization {
    case allowed(AllowedAction)
    case pending(PendingAuthorization)
    case denied(DeniedAction)
}
```

- **Represents:** Exhaustive runtime policy outcome. Ask is a case, not `Decision.deny`.
- **Invariant:** Exactly one case. No `allowed && pending`. No boolean flags.
- **Who constructs:** `AgentAuthorization.decide(...)` only (enum cases are the public surface of that function’s return).
- **Who consumes:** Tests; later runtime reducer / adapter.

### `AgentAuthorization.decide`

Illustrative signature (keep `Sendable`, pure):

```text
static func decide(
    action: ProposedAction,
    context: ReviewContext = ReviewContext(repository: RepositoryReviewContext()),
    policy: EffectiveActionPolicy = .empty,
    gitWorld: GitAnalysisWorld = .unprobed,
    review: Result<ActionReview, ActionReviewerError> = .failure(.unsupported)
) -> AgentAuthorization
```

Algorithm:

1. `let verdict = ActionPolicyEngine.evaluate(action:context:policy:gitWorld:)`
2. `let bound = ReviewBind.apply(hardDecision: verdict.decision, review: review)`
3. Map:

| BoundReview | Hard zone (from verdict) | Result |
| --- | --- | --- |
| `.allow` | `hardAllow` or `reviewEligible` | `.allowed` |
| `.deny(deny)` | `hardDeny` or review-deny | `.denied` |
| `.mandatoryHuman(deny)` | `mandatoryHuman` | `.pending` reason `.mandatoryHuman` |
| `.mandatoryHuman(deny)` | `reviewEligible` | `.pending` reason `.reviewAsk` |

`ReviewBind` already encodes: hard deny stays deny; hard allow stays allow; mandatoryHuman stays pending; reviewEligible depends on review quality.

### Types this phase must **not** add

`ExecutableAction`, `ApprovedAction` (user-approved wrap — next approval slice), isolation enums, executor protocols.

## 9. Functional boundaries

| Layer | Allowed |
| --- | --- |
| Pure logic | `evaluate` + `ReviewBind` + map to `AgentAuthorization` |
| State transitions | Value-level only. No `PendingApprovalState` writes |
| Effects | None. No clock, filesystem, process, XPC, menu bar |
| Platform | None |
| Permitted mutable state | Local vars only |

No `Task.detached`, actors, singletons, or “AuthorizationManager.”

Do not change hook dispatch. Do not persist pending records.

## 10. Exact implementation work

1. Add `Sources/RVDomain/AgentAuthorization.swift` with `AllowedAction`, `DeniedAction`, `PendingAuthorization`, `AgentAuthorization`, and `decide`.
2. Implement decide as evaluate(`gitWorld:`) + `ReviewBind.apply` + exhaustive map. Default review `.failure(.unsupported)`.
3. Keep constructors of the three payloads non-public (`internal` preferred so `RVEngine` cannot mint `AllowedAction` without decide).
4. Domain tests in `Tests/RVDomainTests/AgentAuthorizationTests.swift` using `ActionPolicyFixtures`:
   - in-repo write/create → `.allowed`, explanation `inRepository`
   - force-push `main` → `.denied` `remoteSharedBranch`
   - force-push `topic` → `.pending` reason `.mandatoryHuman` `remoteBranchAsk`
   - working-tree discard / reset-hard fixture → `.denied` `workingTreeDiscard`
   - unprotected out-of-repo write → `.denied` `outsideRepository`
   - protected-path write → `.denied` `protectedPath`
   - uncovered `echo hello` + default review → `.pending` reason `.reviewAsk` (not `.allowed`)
   - uncovered + `qualifiedAllow` review → `.allowed`
   - uncovered + weak/low-confidence or conflicting review → `.pending` `.reviewAsk`
   - hard deny + stub allow review still `.denied` (review cannot lift hard deny)
   - `BoundReview.decision` on a pending case is pack-deny; `AgentAuthorization` must still be `.pending`
   - `HostNativeAsk.hookBound(.reviewEligible)` is `.allow`; decide on the same uncovered action with default review must **not** be `.allowed`
5. Composition tests (Engine): `normalizeAgentRequest` then `decide`:
   - `git reset --hard` → denied working-tree discard
   - `echo hello` / `git status` → pending reviewAsk
   - `echo hi > file` with `FilesystemAnalysisWorld.probed` repo context (same as `AnalyzeSemanticsTests`) → allowed in-repository write
   - `env -C /tmp/.ssh rm config` → denied protected path
   - unwrap-limited still fails at normalize; authorize is not called
6. Do not add CLI, isolation types, executor, or `PolicyGate` calls.
7. Do not edit `HostNativeAsk.hookBound` to “fix” quiet allow. Document the difference; tests pin it.
8. Run `RVDomainTests` filters `AgentAuthorization` and `ActionPolicyEngine` (no regressions), plus the new Engine composition filter.

## 11. Files likely to change

**New:**

- `Sources/RVDomain/AgentAuthorization.swift`
- `Tests/RVDomainTests/AgentAuthorizationTests.swift`
- `Tests/RVEngineTests/NormalizeThenAuthorizeTests.swift` (name flexible)

**Existing, only if a tiny shared fixture extract is cleaner:**

- `Tests/RVDomainTests/ActionPolicyEngineTests.swift` — prefer importing/reusing `ActionPolicyFixtures` as-is (it is file-private today). If needed, lift fixtures to `package` / a shared test support file **without** changing engine assertions.

**Do not change:** `PolicyGate.swift`, `HookDispatch.swift`, `HostNativeAsk.swift`, `NormalizeAgentRequest.swift` (unless a test helper), `RV.swift`, isolation/executor files (they must stay absent).

## 12. Architecture constraints

- Reuse `ActionPolicyEngine` + `ReviewBind`. No parallel rule engine.
- Do not name the new enum `PolicyDecision`.
- Do not use `ActionPolicyEngine.bind` or the probed-only `evaluate` overload for this door.
- Do not use `HostNativeAsk.hookBound` for this door.
- Do not use `BoundReview.decision` as the runtime authorization (it erases Ask).
- `AllowedAction` is not `ExecutableAction` and must not grow an `execute` method.
- `PendingAuthorization` is not a ledger row.
- Functional core: values in, values out.
- Swift 6 / `Sendable`. No `@unchecked Sendable`.
- Do not add isolation or executor scaffolding.

## 13. Security invariants

- Deny never produces `AllowedAction`.
- Pending never produces `AllowedAction`.
- Hard deny cannot be lifted by an allow review.
- Overlay/typed-rule allow cannot weaken a built-in hard deny (already engine law; pin via decide).
- Missing reviewer on `reviewEligible` is pending, not allow.
- No new API accepts `ProposedAction` or `AllowedAction` and performs an effect.
- Unwrap-limited still cannot become `ProposedAction`; therefore it cannot become `AllowedAction`.
- `.hostAsk` is not a runtime authorization reason.

## 14. Enforcement guarantee

**Still no new runtime enforcement toward the OS or host process.**

| Mode | This phase |
| --- | --- |
| observed | Types/tests only |
| mediated | Unchanged hook door. New types are not wired into `hookWire` |
| contained | **Not provided** |

This phase **does** mediate **in type space**: unauthorized proposals cannot inhabit `AllowedAction`. That is not OS containment and not hook mediation.

Limitations:

- Hook path still quiet-allows `reviewEligible` via `hookBound`
- No executor; `AllowedAction` cannot run the tool
- OpenCode file/MCP/child paths still bypass
- Pending is not delivered to a human yet

## 15. Failure behavior

| Input | Outcome |
| --- | --- |
| Hard deny | `.denied`, no `AllowedAction` |
| Mandatory human | `.pending` `.mandatoryHuman`, no `AllowedAction` |
| Review-eligible, no/weak/conflict review | `.pending` `.reviewAsk`, no `AllowedAction` |
| Review-eligible, sufficient aligned allow | `.allowed` |
| Review-eligible, sufficient aligned deny | `.denied` |
| Hard allow | `.allowed` |
| Normalize unwrap-limited | No `ProposedAction`; decide is not invoked |
| Policy/review functions throw | They do not throw today; keep decide non-throwing |

Never map pending or deny to allow because “the hook would have allowed it.”

## 16. Tests

### Pure unit (`RVDomainTests`)

All cases in §10 step 4. Also:

- Exhaustive switch in tests so a new case would fail to compile if someone adds booleans later (switch on the result, not `if allowed`).
- `AllowedAction` / `DeniedAction` / `PendingAuthorization` cannot be constructed from a raw `ProposedAction` in a non-`@testable` sense as far as the public API allows. If `internal` init + `@testable` exists, pin that it is a test seam like Phase 01.

### Composition (`RVEngineTests`)

§10 step 5. These prove Phase 01 + Phase 02 compose without packs or `PolicyGate`.

### Integration / hooks

Do **not** rewire `hookWire`. Optional negative test: hook `hookBound` vs decide divergence on uncovered (can live in Domain tests).

### Platform / containment

None.

### Adversarial

- Stub allow review on force-push main still denied
- Overlay allow on protected path still denied
- Uncovered default review is not allowed
- decide does not call `PolicyGate` / pack evaluate

## 17. Acceptance criteria

- [x] `AgentAuthorization` is an exhaustive `Sendable` enum with `allowed` / `pending` / `denied`
- [x] `AllowedAction`, `PendingAuthorization`, and `DeniedAction` are distinct types; public construction of the payloads is only through `decide`
- [x] `decide` uses `ActionPolicyEngine.evaluate(..., gitWorld:)` and `ReviewBind.apply` only
- [x] `decide` does not call `HostNativeAsk.hookBound` or `ActionPolicyEngine.bind`
- [x] The new enum is not named `PolicyDecision`
- [x] In-repo write/create fixtures authorize to `.allowed`
- [x] Force-push of `main` is `.denied`; force-push of a private topic is `.pending` `.mandatoryHuman`
- [x] Uncovered / `echo hello` with default review is `.pending` `.reviewAsk`, not `.allowed`
- [x] Hard deny cannot become `.allowed` via allow review
- [x] `BoundReview.decision` collapsing Ask to deny is not used as the runtime case
- [x] `normalizeAgentRequest` then `decide` covers reset-hard deny, benign pending, probed in-repo allow, protected-path deny
- [x] Unwrap-limited still produces no `ProposedAction` and therefore no `AllowedAction`
- [x] No `ExecutableAction`, executor, isolation types, CLI launcher, or `PolicyGate` wiring
- [x] `HostNativeAsk.hookBound` behavior is unchanged
- [x] Required tests exist and pass
- [x] Implementation Completion Notes in this file are filled in

## 18. Non-goals

- `ExecutableAction` / `LocalExecutor` / running the command
- Persisting `PendingApproval` or menu-bar / TTY ask
- User `ApprovedAction` after human resolution
- Isolation policy values or Seatbelt/Landlock
- Changing hook quiet-allow for `reviewEligible`
- Pack evaluate inside decide
- File-tool `AgentRequest`
- Second host
- CLI launcher
- Secrets / MCP / audit stream

## 19. Risks / questions discovered

| Item | Resolution from the tree |
| --- | --- |
| Reuse `PolicyDecision`? | No. Already pack-override in `RVPolicy` |
| Reuse `ActionPolicyEngine.bind`? | No. It uses the probed `evaluate` overload |
| Reuse `hookBound`? | No. `reviewEligible` → allow. Runtime must fail closed |
| Is non-force `git push origin main` ASK today? | Effects are empty unless force. Uncovered → pending via ReviewBind. Honest and fail-closed |
| Build `PendingApproval` now? | No. Needs clock and IDs (effects) |
| Add `ExecutableAction`? | No. No executor consumer yet |
| Isolation enums this slice? | No. Separate phase |

## 20. Handoff notes for next phase

Likely next smallest slice after this (do not implement now):

- Isolation **values** (`IsolationPolicy`, `IsolationGuarantees`, `EnforcementMode`) as pure Domain enums — still no launch
- **or** approval effect: `PendingAuthorization` → `PendingApprovalRequest` + existing pending store / menu-bar path
- **or** `ExecutableAction` + `LocalExecutor` once allow/pending/deny is solid

Do not skip to Seatbelt/Landlock launch until authorization types exist and isolation values can record honest guarantees.

Remember:

- Call `evaluate(..., gitWorld:)` not the probed convenience overload
- `ExecutingCommand` is still not a capability
- `AllowedAction` is still not an executor argument until `ExecutableAction` exists
- Hook door remains a different product mapping

---

# Implementation Prompt

```text
Implement the active RV <agent> phase described in:

docs/rv-agent/handoffs/phase-02-typed-authorization.md

Read the handoff completely before changing code.

Treat its architecture constraints, security invariants, type-system
requirements, enforcement guarantees, tests, non-goals, and acceptance
criteria as authoritative.

Inspect the current repository before implementation and reconcile minor
code drift with the handoff rather than blindly following stale file
references.

Implement this phase completely and run the required verification.

Before finishing:
- update the acceptance-criteria checkboxes
- append the Implementation Completion Notes in the same handoff
- record files changed, architecture decisions, deviations, tests,
  verification results, limitations, technical debt, and context the
  next planning session needs

Do not begin the next phase.
```

---

# Implementation Completion Notes

## Implementation Status

Implemented

## Implementation Summary

`ProposedAction` now compiles through existing `ActionPolicyEngine.evaluate(..., gitWorld:)` and `ReviewBind.apply` into an exhaustive `AgentAuthorization` (`allowed` / `pending` / `denied`). The three payloads are distinct types with `internal` inits, so sibling modules cannot mint `AllowedAction` from a raw proposal. Default review is `.failure(.unsupported)`, so uncovered actions are pending `.reviewAsk`, not hook-style quiet allow. Hard deny stays denied even with a stub allow review. `AllowedAction` is still not executable. No executor, isolation types, CLI launcher, pending store, or `PolicyGate` wiring was added.

## Files Changed

**New**

- `Sources/RVDomain/AgentAuthorization.swift` — `AllowedAction`, `DeniedAction`, `PendingAuthorization`, `AgentAuthorization.decide`
- `Tests/RVDomainTests/AgentAuthorizationTests.swift`
- `Tests/RVDomainTests/ActionPolicyFixtures.swift` — lifted from the engine suite (assertions unchanged)
- `Tests/RVEngineTests/NormalizeThenAuthorizeTests.swift`

**Existing, tiny extract only**

- `Tests/RVDomainTests/ActionPolicyEngineTests.swift` — removed the file-private fixture enum; tests now use the shared file
- `docs/rv-agent/handoffs/phase-02-typed-authorization.md` — this completion record

**Not changed (intentionally)**

- `HostNativeAsk.swift` (`hookBound` still quiet-allows `reviewEligible`)
- `ActionPolicyEngine.swift`, `HardPolicyDecision.swift`, `NormalizeAgentRequest.swift`
- `PolicyGate.swift`, `HookDispatch.swift`, `RV.swift`
- Isolation / executor types remain absent

## Architecture Decisions Made

- Runtime door is `evaluate(..., gitWorld:)` with default `.unprobed`, then `ReviewBind.apply`, then a pure map. `ActionPolicyEngine.bind` and the probed convenience `evaluate` overload are not used.
- `BoundReview.decision` is not the runtime case. Ask stays `.pending`.
- Hard deny is unliftable at the map layer: if the hard zone is `.hardDeny`, the result is `.denied` even if `BoundReview` were somehow allow/ask.
- `AllowedAction` / `DeniedAction` / `PendingAuthorization` stored properties are `let`. Inits are `internal` (not `package`) so `RVEngine` cannot mint payloads; `@testable` Domain tests pin the seam.
- Pending reasons are only `.mandatoryHuman` (hard `mandatoryHuman`) and `.reviewAsk` (`reviewEligible` without a sufficient allow). `.hostAsk` is never emitted.
- No Engine authorize wrapper. Composition is `normalizeAgentRequest` then `AgentAuthorization.decide`.
- `ActionPolicyFixtures` were lifted to a shared Domain test file so authorization tests reuse the engine IR instead of cloning it.

## Deviations From Handoff

- `ProposedAction` has `gitAction` but no `filesystemAction` helper. The probed in-repo composition test asserts `action.resources.filesystemScope == .insideRepository` (same fact, current API).
- Extra Domain pins beyond the minimum table: implicit force-push with default unprobed `decide` is pending `.reviewAsk` (proves we do not use the probed overload); review-eligible + qualified deny is `.denied`; overlay allow cannot lift protected path; pending reason is never `.hostAsk`.
- Fixture lift is the extract the handoff already permitted.

## Tests Added / Updated

- `AgentAuthorizationTests` (18): in-repo write/create allowed; force-push `main` denied; force-push `topic` pending `.mandatoryHuman`; working-tree discard / out-of-repo / protected-path denied; uncovered default/weak/conflict/timeout pending `.reviewAsk`; qualified allow → allowed; qualified deny → denied; stub allow cannot lift hard deny; `BoundReview.decision` pack-deny stays `.pending`; `hookBound` quiet-allow vs decide pending; implicit unprobed vs probed overload; overlay allow on protected path; no packs; internal-init seam; exhaustive switches on the result
- `NormalizeThenAuthorizeTests` (6): `git reset --hard` denied working-tree discard; `echo hello` / `git status` pending `.reviewAsk`; probed `echo hi > file` allowed `inRepository`; `env -C /tmp/.ssh rm config` denied protected path; unwrap-limited produces no `ProposedAction`; compose without packs
- `ActionPolicyEngineTests`: assertions unchanged; fixtures moved only

## Verification Performed

### Build

`Scripts/swift-6.4 test` compiled the package (Swift 6.4, language mode 6). No new production warnings in the files this phase added. Pre-existing CLI test warnings only.

### Unit Tests

Passed:

- `--filter AgentAuthorization` — `AgentAuthorization` suite (18 tests)
- `--filter ActionPolicyEngine` — `ActionPolicyEngine` (19) + `ActionPolicyEngineTypedRule` (13) + existing shadow-wire suite (3); no engine regressions
- `--filter NormalizeThenAuthorize` — `NormalizeThenAuthorize` suite (6 tests)

### Integration Tests

Engine composition is the Phase 01 + Phase 02 integration. No hook rewire. `hookBound` vs decide divergence is pinned in Domain tests.

### Platform / Containment Tests

None. This phase does not provide OS containment.

### Adversarial / Bypass Tests

Passed: stub allow on force-push `main` stays denied; overlay allow on protected path stays denied; uncovered default review is not allowed; implicit force-push does not take the probed shared-branch deny; decide does not require packs or `PolicyGate`.

## Known Limitations

- Hook path still quiet-allows `reviewEligible` via `HostNativeAsk.hookBound`
- No executor; `AllowedAction` cannot run the tool
- OpenCode file/MCP/child paths still bypass
- Pending is not delivered to a human and is not a `PendingApproval` row
- Unwrap-limited still cannot become `ProposedAction`; authorize is not invoked
- `ExecutingCommand` is still not a capability

## Technical Debt Introduced

- `ActionPolicyFixtures` are now shared across two Domain suites. Keep them assertion-stable; do not grow them into a second policy table.
- `@testable` can still mint payload types. That is the documented Phase 01-style seam, not a production API.
- `decide` has no Engine façade. Later slices should call Domain `decide` rather than adding a parallel authorize function.

## Important Context for Next Phase

- Call `AgentAuthorization.decide` / `evaluate(..., gitWorld:)`. Do not use `ActionPolicyEngine.bind`, the probed convenience `evaluate`, `HostNativeAsk.hookBound`, or `BoundReview.decision` as the runtime outcome.
- `AllowedAction` is still not an executor argument. Do not add `execute` or skip to `ExecutableAction` until a consumer exists.
- `PendingAuthorization` is ASK intent only. The next approval slice may turn it into `PendingApprovalRequest` with clock + `ApprovalID`. Do not construct `PendingApproval` here.
- Isolation **values** (`IsolationPolicy`, `IsolationGuarantees`, `EnforcementMode`) can land as pure Domain enums without launch. Do not skip to Seatbelt/Landlock.
- Hook door remains a different product mapping. Do not “fix” `hookBound` quiet allow in an authorization or isolation slice.
- `normalizeAgentRequest` then `decide` is the composition. Unwrap-limited still dies at normalize.

## Acceptance Criteria Final State

Coding-agent checkboxes above are marked done.
Completion is independently verified by the next planning session.
