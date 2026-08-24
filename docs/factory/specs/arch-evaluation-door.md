---
title: Assemble the evaluation world once, behind a lazy door
version: 1.0
date_created: 2026-08-22
owner: chriskarani
tags: [architecture, swift, rvservice, rvcli, refactor]
---

# Introduction

One deliberate refactor from the 2026-08-22 architecture review (candidate 01, Strong): collapse the four ad-hoc assembly sites of "home + snapshots + enabled pack IDs + compiled session + allow-once store" into one package-internal assembly path behind `GatedEvaluate`, and make session construction lazy so an XPC-served hook never pays catalog parse / ICU compile in its own process.

Report: `/var/folders/ns/xmz0zmpj7p148vdgr4bwzp8h0000gn/T/swift-architecture-review-rv-20260822-1718.html`

## 1. Purpose & Scope

In scope:

- `Sources/RVService/GatedEvaluate.swift`, `EvaluateSession.swift`, `ServiceRuntime.swift` (assembly + lazy session + runtime adoption)
- `Sources/RVCLI/Service/ServiceClient.swift`, `Sources/RVCLI/CommandRun.swift` (CLI adoption of the same door; lazy fallback)
- Tests in `Tests/RVServiceTests/`, `Tests/RVCLITests/`

Out of scope: any wire change (`rv.ipc.v1` untouched), RVEngine/RVPacks/RVPolicy behavior, host adapters, setup/uninstall, analytics protocol.

Audience: implementer and reviewer subagents with sparse context. Assumption: base commit `637661a`.

## 2. Definitions

- **Door**: `GatedEvaluate` — peek/apply entry that runs the Evaluate session then the Policy gate.
- **Evaluation world**: HOME, `[PackSnapshot]`, enabled `[PackID]`, compiled `EvaluateSession`, `AllowOnceStore`.
- **Assembly**: producing an evaluation world from inputs; today duplicated at `EvaluateSession.init`, `ServiceRuntime.init`, `ServiceClient.init`, `CommandRun.evaluateCommand`.
- **Day-one**: `core.git` + `core.filesystem`; empty enabled set means none; catalog disable must not uncompile required rules.
- **Fallback**: client-side in-process evaluate when XPC is down or major-skewed. Product law: fallback must still evaluate — never allow because XPC missed.

## 3. Requirements, Constraints & Guidelines

- **REQ-001**: Exactly one non-test production site resolves the snapshot fallback chain (`loadAll` → `loadDayOne` → `[]`). The verbatim duplicate at `EvaluateSession.swift:22` / `ServiceRuntime.swift:41` must disappear.
- **REQ-002**: Exactly one producer computes the enabled-ID rule (catalog/effective IDs unioned with day-one). `ServiceRuntime.compileEnabledIDs(from:)` and the inline logic behind `EnabledPacks.resolve` collapse into that producer.
- **REQ-003**: `ServiceClient` must not construct an `EvaluateSession` eagerly. Session construction happens only when the in-process route actually runs (transport nil, send failure, decode failure, skew).
- **REQ-004**: All Decision outputs are byte-identical to pre-refactor behavior on all three routes (XPC hit, XPC down, XPC skew). Parity is proven by existing tests (`FallbackDownTests`, `FallbackSkewTests`, `AllowOnceGrantHonorTests`, corpus) staying green; tests may be updated only for construction API, never for expected Decisions.
- **REQ-005**: New surface is minimal and value-typed. Prefer `package` over `public` for anything new; keep `GatedEvaluate.run(_:command:cwd:home:store:now:)` semantics stable for callers.
- **REQ-006**: `CommandRun.evaluateCommand` keeps per-call freshness semantics it has today (fresh world per call), expressed through the shared assembly rather than a private `GatedEvaluate()` default.
- **REQ-007**: No `try!`/`!` on production paths; Swift 6 language mode; value types only outside the XPC edge; no new comments beyond what repo style already carries on touched declarations.
- **CON-001**: Toolchain fixed: `tools/gate.sh` via `tools/swift-6.3.3`. Do not raise tools/language/deployment targets. Do not wipe `.build`.
- **CON-002**: macOS 26 arm64 only; no Linux paths.
- **CON-003**: No env-based bypass; no command text in logs; history stays off.
- **GUD-001**: Keep the diff surgical: every changed line traces to assembly unification or laziness. Do not reformat adjacent code.
- **PAT-001**: Functional core / imperative shell — assembly is pure given injected home/snapshots/store; effects stay at process edges (already true via `PackRegistry`, `FileManager`).

## 4. Interfaces & Data Contracts

Target shape (names may adjust if the implementer finds a cleaner equivalent; document deviations in the PR body):

```swift
// RVService — package-internal assembly, single producer
package enum EvaluationWorld {
    // The one snapshot fallback chain + the one enabled-ID rule live here.
    package static func assemble(
        home: String?,
        snapshots: [PackSnapshot]?,     // nil = resolve via REQ-001 chain
        catalog: PackCatalog?,          // when provided, drives REQ-002 rule
        store: AllowOnceStore?
    ) -> GatedEvaluate                  // session built lazily inside
}
```

- `GatedEvaluate` gains internal lazy-session support; its public `run`/`peek`/`apply` signatures do not change.
- `ServiceRuntime` builds its door through the assembly and keeps rebuild-on-enable behavior by reassembling (no second rule).
- `ServiceClient` stores a session provider instead of a constructed door; `CommandRun.evaluateCommand` requests a fresh world per call through the same assembly.

No Codable/wire type changes. No `rv.ipc.v1` method changes.

## 5. Acceptance Criteria

- **AC-001**: Given an answering XPC transport, When `rv hook` evaluates, Then no `EvaluateSession` is constructed in the CLI process (provable by test: provider closure not invoked).
- **AC-002**: Given transport down or major-skew, When a hook evaluates, Then results match pre-refactor expectations; `FallbackDownTests`, `FallbackSkewTests`, `AllowOnceGrantHonorTests` pass without weakening assertions.
- **AC-003**: `rg -n "loadAll\\(\\).{0,80}loadDayOne" Sources` shows exactly one production site; `compileEnabledIDs` exists at most once across modules.
- **AC-004**: `tools/gate.sh --quiet RVEngineTests RVCorpusTests RVServiceTests RVCLITests RVPolicyTests RVIPCTests` green on the ticket branch.
- **AC-005**: PR body records warm-hook timing before/after (debug `-Onone` at minimum; release if cheap) or states plainly that timing was not measurable this run — no invented numbers.

## 5b. Tickets (task graph)

| id | title | depends-on | exclusive-writes | acceptance | review-hint |
|---|---|---|---|---|---|
| T1 | One evaluation-world assembly + lazy session in RVService; ServiceRuntime adopts it | none | `Sources/RVService/GatedEvaluate.swift`, `Sources/RVService/EvaluateSession.swift`, `Sources/RVService/ServiceRuntime.swift`, `Sources/RVService/EvaluateWorld.swift` (new), `Tests/RVServiceTests/**`, `docs/factory/specs/arch-evaluation-door.md` (spec commit) | AC-002..AC-005 for service-side; AC-003 scoped to `Sources/RVService` | 101–1499 |
| T2 | ServiceClient + CommandRun adopt the shared door; lazy in-process fallback in CLI | T1 | `Sources/RVCLI/Service/ServiceClient.swift`, `Sources/RVCLI/CommandRun.swift`, `Tests/RVCLITests/**` | AC-001..AC-004 full | 101–1499 |

T2 stacks on T1's branch. Serialized because both touch the door's construction path.

## 6. Test Automation Strategy

- Framework: Swift Testing (`@Test`), matching existing suites.
- Determinism: temp HOME / injected snapshots / injected `AllowOnceStore(baseDirectory:)` as in current `HomeSeamTests`, `FakeXPCUnixSocketTests`.
- New tests: provider-not-invoked proof for the XPC-hit route (T2); single-assembly greps are checked by reviewer, not asserted in CI.
- Gate: `tools/gate.sh --quiet <filtered targets>` per AC-004; warm `.build` in each worktree before review.

## 7. Rationale & Context

Four construction sites with two verbatim-duplicate fallback chains produced the F1-class composition bug on PR #36 (warm-rvd false-allow) and waste work on the hottest path: every hook spawn parses the 861 KB catalog and compiles patterns even when rvd answers. One lazy assembly removes the drift surface and the wasted work without touching product law: down/skew still evaluates in-process.

## 8. Dependencies & External Integrations

None new. Uses existing `RVPacks.PackRegistry`, `RVService.PacksFacade`, `RVPolicy.AllowOnceStore`. XPC transport unchanged.

## 9. Examples & Edge Cases

- Empty catalog → day-one compile set (existing law, preserved by the one rule).
- `HOME` unset → empty-string home flows exactly as today (`processHOME()` semantics unchanged).
- Transport present but `send` throws mid-flight → fallback constructs the session then (first use), not at init.

## 10. Validation Criteria

All ACs above; plus reviewer confirms: no weakened test assertions, no unrelated file churn, `git diff --stat` limited to exclusive-writes paths.

## 11. Related Specifications / Further Reading

- `docs/factory/specs/phase-5-size-speed.md` (hook-speed baseline numbers)
- `docs/architecture/MODULES.md` (module ownership)
- HTML report: candidate 01 evidence
