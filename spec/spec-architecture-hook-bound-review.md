---
title: Wire BoundReview through the live hook door
version: 1.0
date_created: 2026-08-27
last_updated: 2026-08-27
owner: rv
tags: [architecture, functional-swift, hooks, ask]
---

# Introduction

Execute the Strong candidate from the 2026-08-27 functional-evolution
report (`/tmp/swift-functional-evolution-rv-20260827-201349.html`):

**Wire `BoundReview` through the live hook door.**

`ActionPolicyEngine`, `HardPolicyDecision`, `BoundReview`, and
`HostNativeAsk` already exist. Pi / OpenCode adapters already pause on
`decision: "ask"` then callback `hostAsk: "spend"`. The production first
call still maps pack `Decision` only (`bound: nil`), so product Ask never
fires unless a test injects `BoundReview`.

Naive `ActionPolicyEngine` wiring is forbidden: empty effects are
`.reviewEligible`, and `ShadowReviewRunner.liveDecision` maps that to
`.mandatoryHuman`. That would Ask `git status`. This slice projects
`.reviewEligible` to `.allow` on the hook door only.

Base: `origin/main` (`fe66584`). Toolchain: swift-tools 6.3 / 6.3.3
(`tools/swift-6.3.3`), language mode 6, macOS 26 only. Gate:
`tools/gate.sh`. Never wipe `.build`.

# 1. Purpose & Scope

**Audience:** fresh-context implementer and reviewer subagents on isolated
worktrees.

**In scope:**

- A pure hook-live projection: `EvaluationResult` + `ProposedAction` →
  `BoundReview`.
- First-call `hookWire` / `hookBody` always pass that `BoundReview`.
- Default `HostCodec.proposedAction(from:)` so every host produces
  `.shell` with empty effects (fingerprint matches existing OpenClaw /
  Hermes shape).
- Tests that prove pack-allow does not Ask, pack-deny stays deny, and
  builtin `mandatoryHuman` (typed effects) Asks only on spend-first hosts.

**Out of scope:**

- IR analyzers / filling `ActionEffectKind` from command text (OPE-156).
- `PendingApproval` persistence (OPE-246).
- Live `ReviewBind` / AFM Auto-review (OPE-253).
- Handshake `HelloAck.ok` enum.
- Setup Claude merge / `SetupSlotSnapshot` dictionary.
- Explain / Classify flattening.
- Changing `ShadowReviewRunner.liveDecision` (shadow stays
  reviewEligible → mandatoryHuman).
- New SPM modules. `Package.swift` edits.
- `RV_BYPASS`. Live-HOME tests. Command text in logs.
- Making Ask a `Decision` case. Claude official
  `permissionDecision: "ask"`.

**Assumptions:**

- Packs still deny `git reset --hard`. Quiet allow is unchanged.
- Claude / Grok / OpenClaw / Hermes stay deny-or-TTY on
  `mandatoryHuman`.
- Spend callback path (`hostAsk: "spend"`) is unchanged.
- Empty-effect `ProposedAction` is the live codec output until OPE-156.

# 2. Definitions

| Term | Meaning |
|---|---|
| Hook-live bound | `BoundReview` used on first-call host wire. `.reviewEligible` is `.allow`, not Ask. |
| Shadow live | `ShadowReviewRunner.liveDecision`: `.reviewEligible` is `.mandatoryHuman`. Do not reuse for the hook door. |
| Pack fallback | `PackFallback(result)` from the Evaluate session. `.allow` / `.deny` / pack-incomplete. Never `.ask` from `EvaluationResult` today. |
| Spend-first | Pi, OpenCode. `HostAskCapability.spendFirst`. |
| Deny-or-TTY | Grok, Claude, OpenClaw, Hermes. |

# 3. Requirements, Constraints & Guidelines

- **CON-001**: Value types only in Domain/Hooks. No `try!` / `!` on production paths.
- **CON-002**: Ask is not a `Decision` case. Host deny text remains the block.
- **CON-003**: Exclusive write paths below are hard. Do not edit Engine evaluate, PolicyGate, Setup, IPC envelope, or AFM reviewer.
- **CON-004**: No live-HOME tests. No `RV_BYPASS`. No command text in `os_log`.
- **GUD-001**: Deepen `HostNativeAsk` / `hookBody`. No new protocol. No effect algebra.
- **PAT-001**: Specialists: `swift-functional-core`, `.grok/skills/swift-hook-xpc`, `swift-testing-pro`.

## T1 — Hook-live BoundReview projection

- **REQ-101**: `HostNativeAsk` (RVDomain) exposes a pure function that maps `HardPolicyDecision` to hook-live `BoundReview`:
  - `.hardAllow` → `.allow`
  - `.hardDeny(d)` → `.deny(d)`
  - `.mandatoryHuman(d)` → `.mandatoryHuman(d)`
  - `.reviewEligible` → `.allow` (uncovered is not Ask on the hook door)
- **REQ-102**: A second pure function maps `EvaluationResult` + `ProposedAction` + `ReviewContext` by calling `ActionPolicyEngine.evaluate` with that context and `EffectiveActionPolicy(packFallback: PackFallback(result))`, then REQ-101. Context is required. The live hook door may pass an empty `ReviewContext` until IR supplies repository facts.
- **REQ-103**: Do not change `ShadowReviewRunner.liveDecision`.
- **REQ-104**: Do not invent effects from command text.

## T2 — First-call door always binds

- **REQ-201**: `HostCodec` default `proposedAction(from: HookRequest) -> ProposedAction` matches the existing OpenClaw/Hermes fingerprint (`host:session:cwd:command`, empty effects, cwd on `ActionScope`, command as supporting evidence). OpenClaw/Hermes may keep explicit methods if they stay identical; do not diverge fingerprints.
- **REQ-202**: `hookBody` first call: `evaluate` then `HostNativeAsk` projection then `hookWire(..., bound:)`. `bound:` is not optional on first call.
- **REQ-203**: Spend path (`hostAsk == .spend`) unchanged: no BoundReview, `afterSpend: true`.
- **REQ-204**: Pack deny (`git reset --hard`) still encodes deny, never allow, never Ask. Pack allow (`git status`) encodes allow, never Ask.
- **REQ-205**: Existing injected-`bound: .mandatoryHuman` tests stay green (Pi/OpenCode Ask JSON, Claude/Grok deny).
- **REQ-206**: Claude `encodeAsk` stays rich-deny (`permissionDecision: "deny"`).

# 4. Interfaces & Data Contracts

```swift
extension HostNativeAsk {
    public static func hookBound(_ decision: HardPolicyDecision) -> BoundReview
    public static func hookBound(result: EvaluationResult, action: ProposedAction, context: ReviewContext) -> BoundReview
}
```

Names may be `boundForHook` / `hookLive` if clearer; one pair only.

Wire JSON for Pi/OpenCode Ask is unchanged:

```json
{"decision":"ask","continuation":"hostNative", ...}
```

`EvaluationResult` / `Decision` / `rv.ipc.v1` envelopes are unchanged.

# 5. Acceptance Criteria

- **AC-101**: Given empty-effect `ProposedAction` and pack-allow `EvaluationResult`, `HostNativeAsk.hookBound` returns `.allow`.
- **AC-102**: Given empty-effect action and pack-deny `core.git:reset-hard`, returns `.deny` of that rule (not Ask).
- **AC-103**: Given `effects: [.remoteSharedBranchMutation]`, private-branch context, pack-allow, returns `.mandatoryHuman` builtin remote-branch-ask.
- **AC-104**: Given `effects: [.workingTreeDiscard]`, pack-allow, returns `.deny` builtin working-tree-discard (hard deny wins).
- **AC-201**: Given Pi stdin `git reset --hard` with cwd, evaluate callback returning pack deny and a nonempty matching view, first-call `hookWire(host:stdin:)` encodes `decision: ask`. Missing cwd or empty matching view stays `decision: deny`. Deny-or-TTY hosts stay deny.
- **AC-202**: Given Pi stdin `git status` and evaluate callback returning pack allow, first-call encodes allow / empty stdout, not `decision: ask`.
- **AC-203**: Given `hookWire(from:result, bound: .mandatoryHuman)` Pi/OpenCode still encode Ask JSON; Claude/Grok still deny.
- **AC-204**: `tools/gate.sh --quiet RVDomainTests RVHooksTests` exits 0.

# 5b. Tickets (task graph)

| id | title | depends-on | exclusive-writes | acceptance | review-hint |
|---|---|---|---|---|---|
| T1 | Hook-live BoundReview projection | none | `Sources/RVDomain/HostNativeAsk.swift`, `Tests/RVDomainTests/HostNativeAskTests.swift` | AC-101–104 | `≤100` if HostNativeAsk stays under 100 new lines in the largest changed file; else `101–1499` |
| T2 | First-call door always binds | T1 | `Sources/RVHooks/HookDispatch.swift`, `Sources/RVHooks/HookMapper.swift`, `Sources/RVHooks/HostCodec.swift`, `Sources/RVHooks/OpenClawHostCodec.swift`, `Sources/RVHooks/HermesHostCodec.swift`, `Tests/RVHooksTests/HostAskHookTests.swift` | AC-201–204 | `101–1499` |

Specialist for both: `swift-functional-core` + `.grok/skills/swift-hook-xpc` + `swift-testing-pro`.

# 6. Test Automation Strategy

- **Test Levels**: Swift Testing unit tests in `RVDomainTests` and `RVHooksTests`.
- **Frameworks**: Swift Testing (`import Testing`). No XCTest.
- **Test Data**: Fixtures already in `ActionPolicyEngineTests` / `HostAskHookTests`. Reuse denys and stdin JSON. No live HOME.
- **CI/CD**: `tools/gate.sh --quiet RVDomainTests` then `RVHooksTests`. Warm `.build`.
- **Coverage**: The four domain cases and two live `hookWire(host:stdin:)` cases above. Do not add per-host codec snapshot churn.

# 7. Rationale & Context

Pass 6 left Engine / PolicyGate / SetupWorkPlan pure. 0.2 Ask types landed beside the v1 pack door. OPE-264 taught adapters to pause on Ask JSON, but Swift never emits it on first call.

The strangler is one projection plus one call site. Filling effects later (OPE-156) lights Ask without another door rewrite. Mapping `.reviewEligible` to Ask now would fail-open every unmatched command into a host pause.

# 8. Dependencies & External Integrations

- **EXT-001**: None. Host adapters already parse `decision: "ask"`.
- **PLT-001**: macOS 26, Swift 6.3.3, language mode 6.

# 9. Examples & Edge Cases

```swift
let action = ProposedAction.shell(
    ShellAction(
        fingerprint: ActionFingerprint(rawValue: "pi:::git status"),
        supportingCommand: ShellCommand(rawValue: "git status")
    )
)
let allow = EvaluationResult(outcome: .plain, matchingView: MatchingView("git status"))
let context = ReviewContext(repository: RepositoryReviewContext())
HostNativeAsk.hookBound(result: allow, action: action, context: context) // .allow — not Ask
```

Pack deny of `git reset --hard` with empty effects: `.deny(reset-hard)`, mapper encodes deny.

Typed `remoteSharedBranchMutation` on branch `topic` + pack allow: `.mandatoryHuman`; Pi encodes Ask; Grok encodes deny.

Indeterminate evaluate: `PackFallback` is `.deny(packIncomplete)` → hook-live `.deny`, never allow.

# 10. Validation Criteria

- `tools/gate.sh --quiet RVDomainTests RVHooksTests` exits 0.
- `rg 'bound: BoundReview\\? = nil' Sources/RVHooks/HookDispatch.swift` is empty (first call passes a value).
- `rg 'reviewEligible' Sources/RVPolicy/ShadowReviewRunner.swift` still maps to `.mandatoryHuman`.
- Corpus / `git reset --hard` deny unchanged.

# 11. Related Specifications / Further Reading

- `docs/architecture/02.md` (strangler, Host Ask before Auto-review)
- `docs/architecture/MODULES.md`
- `CONTEXT.md` (Ask is not a Decision case)
- HTML report: `/tmp/swift-functional-evolution-rv-20260827-201349.html`
