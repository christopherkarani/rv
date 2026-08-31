# Program: Product takes (deny tip, system.disk default, rebase recovery)

**Date:** 2026-08-31  
**Status:** ready_for_implementor  
**Handoff (new session):** `planning/2026-08-31-product-takes/HANDOFF.md` + paste `planning/2026-08-31-product-takes/PROMPT.md`  
**Source plans:** `spec/spec-architecture-product-takes.md`, conversation lock (unwrap, deny tip, disk on, rebase auto-allow, Ask deferred)  
**Repo / branch assumptions:** `/Users/chriskarani/CodingProjects/rv` on current `main` (or integration branch with OPE-256 unwrap already merged). Apple Silicon, Swift 6.3.3 via `tools/swift-6.3.3`, warm `.build`.  
**Stop line:** This program does **not** implement Host Ask, heredoc/AST, catalog-wide default-on, custom packs, `RV_BYPASS`, allow-once codes on the hook wire, or `rv rebase-recover` cookies. Unwrap is **verify_only**. `docs/architecture/02.md` § Order remains the 0.2 queue (next item OPE-156 unless a human names this program).

---

## 0. One-line goal

Verify wrapper unwrap is already the live floor; put the pack’s safer next step on hook deny; default-enable `system.disk`; auto-allow rebase-documented git discards only while Git rebase state exists.

---

## 1. Tree-truth ledger

| ID | Slice / finding | Status | Evidence | Residual if partial |
|----|-----------------|--------|----------|---------------------|
| F-unwrap | `bash -c` / interpreter unwrap + fail-closed limits | landed | `Sources/RVEngine/Unwrap.swift`; MODULES.md OPE-256; `Tests/RVEngineTests/UnwrapTests.swift`; `Tests/RVServiceTests/GatedEvaluateWrapperSemanticsTests.swift` | Full heredoc/AST deferred (`phase-4-later.md`) |
| F-normalize | sudo/env/command/backslash | landed | `Sources/RVEngine/Normalize.swift` max 32 | none |
| F-deny-tip | Second sentence of pack `description` on hook | open | `hostDenyWhy` first-sentence only; `HostDenyTextTests.assertHookDenyHasNoBypassOrEssay` forbids `git stash`; fixtures pin `RV · Blocked. Destroys uncommitted changes.` | TTY `Suggestions.swift` already has stash/soft-reset essays |
| F-disk-default | `system.disk` default-on | open | `dayOnePackIDs` two ids; `PackRegistry.loadDayOne` hardcoded two names; `system.disk.json` `enabled_by_default: false`; `enablement_defaultsAreCoreOnly` | Rest of catalog stays off |
| F-rebase | Auto-allow discard during rebase | open | Pack `explanation` claims it; **zero** `rebase-merge` I/O in Sources; `RulePinning.blocksAllowOverride` pins `working-tree-discard` | Explicit permit cookie deferred |
| F-ask | Unlock in the host pause | deferred | `docs/architecture/02.md` step 6 OPE-264; `HostNativeAsk`; do not implement here | v1 TTY `allow-once` remains |
| F-stack-switch | One “databases+docker+k8s” toggle | deferred | Upstream has category expand only; `PackSet.expand(.category)` already exists | not a take |

---

## 2. Locked design decisions

| Decision | Choice | Rationale | Units affected |
|----------|--------|-----------|----------------|
| Unwrap | verify_only; no AST | Already OPE-256; highest-value take is done | w1-unwrap-verify |
| Hook tip source | Second sentence of `Deny.reason` after prefix strip | Pack JSON already holds it; RVHooks must not import Presentation | w1-deny-why, w1-deny-fixtures |
| Canonical reset-hard line | `RV · Blocked. Destroys uncommitted changes. Use 'git stash' first.` | Product moment; fixture blast is the work | w1-deny-fixtures |
| Tip caps | Drop sentence 2 if essay/bypass/newline/ANSI/box or total why > 180 scalars | Keep one-line hook voice | w1-deny-why |
| Ask line | Unchanged (`hostAskLine` + `hookUnlockNext`) | Deny ≠ Ask | w1-deny-why |
| Day-one source | Only `dayOnePackIDs`; `PackSet.defaultIDs == dayOnePackIDs`; `loadDayOne` maps that array | Three lists today would drift | w2-algebra |
| Disk policy | Add `system.disk` only | Upstream no-config includes disk; not 95 packs | w2-* |
| Rebase I/O | `GitRebaseProbe` in RVService; boolean into pure `PolicyGate.decide` | Engine stays pure; cwd already at GatedEvaluate | w3-probe, w3-gate |
| Rebase eligibility | `GitAction.discardWorktree` or restore with worktree; else four pack rule ids; **never** reset/clean/push | `working-tree-discard` builtin includes reset --hard | w3-eligible |
| Pin vs rebase | Rebase override **before** `RulePinning.blocksAllowOverride` | Otherwise semantic deny cannot recover | w3-gate |
| Rebase missing cwd / bad gitdir | `rebaseInProgress = false` | Fail closed | w3-probe |
| Cookie CLI | not in program | User take was automatic rebase-state only | deferred |
| Stack switch | not in program | Upstream does not have it | deferred |
| 02.md | Do not implement OPE-156/Ask in these waves | Separate queue | all |

Unresolved forks: **none**.

---

## 3. Global reject list

- `RV_BYPASS` or any hook-honored skip-evaluate env
- Allow because XPC missed
- Redeemable allow-once code on `hostDenyText` / deny fixtures
- `═══` / box-drawing / ANSI on hook deny
- Import `RVPresentation` from `RVHooks` or `RVPolicy`
- `FileManager` / `Date()` inside `RVEngine.evaluate`
- Full heredoc/AST, stdin-into-REPL tracing
- Enabling packs other than adding `system.disk` to day-one
- Named stack preset (databases+docker+k8s as one id)
- `rv rebase-recover` / `.rv/rebase-recovery-permit`
- Host Ask codecs / ApprovalBridge / new hosts
- `swift package clean` / wipe `.build` to prove compile
- Live-HOME tests / `NSHomeDirectory()` as fixture root
- Command text in `os_log`
- Foreign product names in `install.sh` / README hero / adapter user strings
- Changing `Decision` to add Ask
- Treating `builtin.action:working-tree-discard` as rebase-eligible without `GitAction` check
- Reimplementing `Unwrap.swift` when T1 gates are green

---

## 4. Program e2e oracle pack

| # | Command | Expect | Notes |
|---|---------|--------|-------|
| 1 | `tools/gate.sh RVEngineTests` then filter unwrap if needed; or full `RVEngineTests` | PASS | darwin |
| 2 | `tools/swift-6.3.3 test --filter hostDenyText_resetHardIsWhatAndWhy` | PASS; output/golden contains stash tip | darwin |
| 3 | `tools/c-hook-proof.sh` | PASS against new `CANONICAL` | darwin; after w1-deny-fixtures |
| 4 | `tools/swift-6.3.3 test --filter enablement_defaultsAreCoreOnly` | PASS; set includes `system.disk`, excludes postgres | darwin; after w2 |
| 5 | `tools/swift-6.3.3 test --filter GatedEvaluateRebase` (name TBD from T8) | PASS | darwin; after w3 |
| 6 | `rg -n "RV · Blocked. Destroys uncommitted changes[^\.]" Tests Sources tools docs/factory/references/host-contracts-v1.md` | no honor-path hits (stash clause present) | polarity: fail if old exact line remains in fixtures |
| 7 | `rg -n "RV_BYPASS" Sources` | no matches in Sources | fail-on-match |

---

## 5. Ownership matrix (program)

| Path / glob | Exclusive unit id | Wave |
|-------------|-------------------|------|
| `Sources/RVEngine/Unwrap.swift` | w1-unwrap-verify (only if red) | W1 |
| `Sources/RVHooks/HostDenyText.swift` | w1-deny-why | W1 |
| `Tests/RVHooksTests/HostDenyTextTests.swift` | w1-deny-why | W1 |
| `Tests/RVHooksTests/Fixtures/**` | w1-deny-fixtures | W1 |
| `Tests/RVHooksTests/AdapterHookTests.swift` | w1-deny-fixtures | W1 |
| `Tests/RVServiceTests/HookEvaluateTests.swift` | w1-deny-fixtures | W1 |
| `Tests/RVCLITests/HookDispatchTests.swift` `HookCommandTests.swift` `LinuxCHookTests.swift` | w1-deny-fixtures | W1 |
| `Tests/RVTUITests/Fixtures/snapshots/phase-1b/host-deny-text-git-reset-hard.txt` | w1-deny-fixtures | W1 |
| `docs/factory/references/host-contracts-v1.md` | w1-deny-fixtures | W1 |
| `tools/c-hook-proof.sh` | w1-deny-fixtures | W1 |
| `Sources/RVDomain/RVDomain.swift` `PackID.swift` | w2-algebra | W2 |
| `Sources/RVPacks/PackEnablement.swift` `PackRegistry.swift` | w2-algebra | W2 |
| `Sources/RVPacks/Resources/packs/system.disk.json` `index.json` | w2-algebra | W2 |
| `Tests/RVDomainTests/NewtypeTests.swift` | w2-algebra | W2 |
| `Tests/RVPacksTests/EnablementTests.swift` `PackLoadTests.swift` | w2-algebra | W2 |
| `Tests/RVCorpusTests/**` (disk rows) | w2-tests-docs | W2 |
| `Sources/RVService/DoctorSnapshotBuilder.swift` | w2-tests-docs | W2 |
| `CONTEXT.md` `docs/dev/PARITY.md` `docs/factory/specs/phase-4-later.md` `docs/architecture/MODULES.md` `docs/architecture/MAP.md` | w2-tests-docs | W2 |
| Remaining `rg` two-pack literals in Tests/Sources | w2-tests-docs | W2 |
| `Sources/RVPolicy/RebaseRecovery.swift` `PolicyGate.swift` | w3-eligible-gate | W3 |
| `Tests/RVPolicyTests/**` (decide + eligibility) | w3-eligible-gate | W3 |
| `Sources/RVService/GitRebaseProbe.swift` `GatedEvaluate.swift` | w3-probe | W3 |
| `Tests/RVServiceTests/GatedEvaluateRebaseRecoveryTests.swift` | w3-service-tests | W3 |

Waves must not run w1-deny-why ∥ w1-deny-fixtures (shared HostDenyTextTests golden). W2 algebra ∥ tests-docs serialize (tests depend on algebra). W3 eligible-gate then probe then tests.

---

## 6. Waves

### Wave W1 — Unwrap proof + hook deny tip

- **Depends on waves:** none  
- **mode:** standard  
- **max_units:** 3  
- **max_parallel:** 2  
- **agent_budget:** 512  
- **product_oracle_cmds:**  
  - `tools/gate.sh RVEngineTests RVHooksTests`  
  - `tools/c-hook-proof.sh` (after fixtures unit)  
- **Wave done when:** unwrap still green; canonical deny includes stash tip; c-hook-proof PASS

#### Unit: w1-unwrap-verify

- **Title:** Prove OPE-256 unwrap is the take  
- **Mode:** verify_only  
- **Goal:** Confirm wrapped `git reset --hard` still denies; do not rewrite unwrap  
- **Acceptance:**
  1. `UnwrapTests` / `GatedEvaluateWrapperSemanticsTests` / `AnalyzeSemanticsTests` wrapped reset-hard cases PASS
  2. No product edit if green
- **Composition acceptance:** N/A (lib)  
- **Live smoke:** `tools/gate.sh RVEngineTests RVServiceTests` → exit 0  
- **Depends on:** none  
- **Parallel-safe with:** w1-deny-why (disjoint)  
- **Code paths (exclusive):** none unless gate fail → `Sources/RVEngine/Unwrap.swift` only  
- **Test paths (exclusive):** none (read-only)  
- **Gates:**  
  - `tools/gate.sh RVEngineTests RVServiceTests`  
- **Reject (local):** heredoc parser, new WrapperKind, changing maxDepth defaults  
- **Residuals allowed:** no heredoc/AST  
- **Fat?:** no  
- **Skills to inject:** `.grok/skills/swift-evaluate-parity` if gap-fill  

#### Unit: w1-deny-why

- **Title:** Keep sentence 2 on `hostDenyLine`  
- **Mode:** implement  
- **Goal:** `hostDenyWhy` / `hostDenyLine` per spec REQ-020–028  
- **Acceptance:**
  1. `hostDenyText` for reset-hard reason with stash sentence equals canonical line in spec §4.2
  2. One-sentence builtin reasons still one clause; no newline/box/ANSI; no allow-once
- **Composition acceptance:** codecs still copy `hostDenyText` unchanged  
- **Live smoke:** `tools/swift-6.3.3 test --filter hostDenyText_resetHardIsWhatAndWhy` → PASS  
- **Depends on:** none  
- **Parallel-safe with:** w1-unwrap-verify  
- **Code paths (exclusive):** `Sources/RVHooks/HostDenyText.swift`  
- **Test paths (exclusive):** `Tests/RVHooksTests/HostDenyTextTests.swift`  
- **Gates:**  
  - `tools/gate.sh RVHooksTests`  
- **Reject (local):** importing RVPresentation; changing `hostAskLine`  
- **Residuals allowed:** TTY Suggestions catalog unchanged  
- **Fat?:** no  
- **Skills to inject:** `.grok/skills/swift-hook-xpc`  

#### Unit: w1-deny-fixtures

- **Title:** Honor-path fixtures and contracts  
- **Mode:** implement  
- **Goal:** Every pinned canonical deny string updated  
- **Acceptance:**
  1. All files in exclusive list contain the new canonical string (or updated equivalent for Claude JSON)
  2. `tools/c-hook-proof.sh` CANONICAL matches
- **Composition acceptance:** AdapterHookTests still forbid bypass env and boxes  
- **Live smoke:** `tools/c-hook-proof.sh` → exit 0  
- **Depends on:** w1-deny-why  
- **Parallel-safe with:** none  
- **Code paths (exclusive):** `docs/factory/references/host-contracts-v1.md`, `tools/c-hook-proof.sh`  
- **Test paths (exclusive):** `Tests/RVHooksTests/Fixtures/**`, `Tests/RVHooksTests/AdapterHookTests.swift`, `Tests/RVServiceTests/HookEvaluateTests.swift`, `Tests/RVCLITests/HookDispatchTests.swift`, `Tests/RVCLITests/HookCommandTests.swift`, `Tests/RVCLITests/LinuxCHookTests.swift`, `Tests/RVTUITests/Fixtures/snapshots/phase-1b/host-deny-text-git-reset-hard.txt`  
- **Gates:**  
  - `tools/gate.sh RVHooksTests RVCLITests RVServiceTests RVTUITests`  
- **Reject (local):** putting allow-once code in fixtures  
- **Residuals allowed:** display-only Pi card copy if it duplicates hostDenyText via codec (update if asserted)  
- **Fat?:** no (many files, one string)  
- **Skills to inject:** `.grok/skills/swift-hook-xpc`  

---

### Wave W2 — `system.disk` day-one

- **Depends on waves:** none (can run after or parallel to W1; no shared files)  
- **mode:** standard  
- **max_units:** 2  
- **max_parallel:** 1  
- **agent_budget:** 512  
- **product_oracle_cmds:**  
  - `tools/gate.sh RVDomainTests RVPacksTests RVCorpusTests RVServiceTests RVCLITests RVPresentationTests`  
- **Wave done when:** three-id day-one; disk deny on; extras still off; doctor copy honest

#### Unit: w2-algebra

- **Title:** Single-source day-one includes `system.disk`  
- **Mode:** implement  
- **Goal:** spec REQ-040–044  
- **Acceptance:**
  1. `dayOnePackIDs` raw values are `core.filesystem`, `core.git`, `system.disk`
  2. `loadDayOne` loads those ids; JSON `enabled_by_default` true; index `default_enabled` includes disk
- **Composition acceptance:** `PackSet.defaultIDs` is `dayOnePackIDs`  
- **Live smoke:** `tools/swift-6.3.3 test --filter enablement_defaultsAreCoreOnly` → PASS (set includes `system.disk`, excludes postgres)  
- **Depends on:** none  
- **Parallel-safe with:** none (serialize with w2-tests-docs)  
- **Code paths (exclusive):** `Sources/RVDomain/RVDomain.swift`, `Sources/RVDomain/PackID.swift`, `Sources/RVPacks/PackEnablement.swift`, `Sources/RVPacks/PackRegistry.swift`, `Sources/RVPacks/Resources/packs/system.disk.json`, `Sources/RVPacks/Resources/packs/index.json`  
- **Test paths (exclusive):** `Tests/RVDomainTests/NewtypeTests.swift`, `Tests/RVPacksTests/EnablementTests.swift`, `Tests/RVPacksTests/PackLoadTests.swift`  
- **Gates:**  
  - `tools/gate.sh RVDomainTests RVPacksTests`  
- **Reject (local):** enabling other system.* or database packs  
- **Residuals allowed:** analytics two-pack literals fixed in w2-tests-docs  
- **Fat?:** no  
- **Skills to inject:** `.grok/skills/swift-hexagonal-spm`, `.grok/skills/swift-evaluate-parity`  

#### Unit: w2-tests-docs

- **Title:** Cardinality, corpus, doctor, vocabulary  
- **Mode:** implement  
- **Goal:** REQ-045–053; hunt hardcoded two-pack lists  
- **Acceptance:**
  1. Disk corpus deny/allow rows exist (spec REQ-048); doctor message lists three ids
  2. CONTEXT + PARITY + phase-4-later disk-default row updated; remaining complete-set two-pack literals gone
- **Composition acceptance:** `rv packs disable system.disk` still subtracts disk (facade/disable test or new)  
- **Live smoke:** `tools/swift-6.3.3 test --filter packLoad_decodesDayOneNameSets` → PASS (three snapshots; git/fs name-sets unchanged)  
- **Depends on:** w2-algebra  
- **Parallel-safe with:** none  
- **Code paths (exclusive):** `Sources/RVService/DoctorSnapshotBuilder.swift`, `CONTEXT.md`, `docs/dev/PARITY.md`, `docs/factory/specs/phase-4-later.md`, `docs/architecture/MODULES.md`, `docs/architecture/MAP.md`, plus remaining Sources/Tests files that still treat `["core.filesystem", "core.git"]` as the **complete** day-one set. Do not edit w2-algebra files.  
- **Test paths (exclusive):** `Tests/RVCorpusTests/**` (add disk rows), `Tests/RVPacksTests/CatalogLoadTests.swift` if it pins `default_enabled`, `Tests/RVAnalyticsTests/RVAnalyticsTests.swift` if it pins two packs as the full default, doctor tests that pin the two-pack loaded sentence  
- **Gates:**  
  - `tools/gate.sh RVDomainTests RVPacksTests RVCorpusTests RVServiceTests RVCLITests RVPresentationTests RVAnalyticsTests`  
- **Reject (local):** flipping remaining catalog default-on  
- **Residuals allowed:** TUI doctor snapshots if they list packs — update if gate fails  
- **Fat?:** borderline (many test literals). Stay in one unit so day-one meaning cannot split.  
- **Skills to inject:** none extra  

---

### Wave W3 — Rebase recovery

- **Depends on waves:** none (independent of W1/W2; may follow either)  
- **mode:** full  
- **max_units:** 3  
- **max_parallel:** 1  
- **agent_budget:** 1024  
- **product_oracle_cmds:**  
  - `tools/gate.sh RVPolicyTests RVServiceTests`  
- **Wave done when:** temp rebase dir allows checkout -- / restore worktree; reset --hard still denies

#### Unit: w3-eligible-gate

- **Title:** Pure eligibility + PolicyGate order  
- **Mode:** implement  
- **Goal:** REQ-060–066  
- **Acceptance:**
  1. `RebaseRecovery.isEligible` true for discard/restore-worktree denies; false for reset-hard even if rebaseInProgress true
  2. `decide(..., rebaseInProgress: true)` allows eligible discard **even when** `RulePinning.blocksAllowOverride` would block allow-once; does not consume store
- **Composition acceptance:** default `rebaseInProgress: false` preserves all existing PolicyGate tests  
- **Live smoke:** `tools/gate.sh RVPolicyTests` → exit 0  
- **Depends on:** none  
- **Parallel-safe with:** none  
- **Code paths (exclusive):** `Sources/RVPolicy/RebaseRecovery.swift` (new), `Sources/RVPolicy/PolicyGate.swift`  
- **Test paths (exclusive):** `Tests/RVPolicyTests/RebaseRecoveryTests.swift` (new), existing `Tests/RVPolicyTests/*PolicyGate*` files that must compile against new `decide` signature (add default arg so most call sites unchanged)  
- **Gates:**  
  - `tools/gate.sh RVPolicyTests`  
- **Reject (local):** FileManager in RVPolicy; treating builtin working-tree-discard as always eligible  
- **Residuals allowed:** no CLI cookie  
- **Fat?:** no  
- **Skills to inject:** `.grok/skills/swift-evaluate-parity`  

#### Unit: w3-probe

- **Title:** Git dir rebase probe + GatedEvaluate  
- **Mode:** implement  
- **Goal:** REQ-067–068  
- **Acceptance:**
  1. Probe true iff rebase-merge or rebase-apply is a directory under resolved gitdir
  2. GatedEvaluate passes probe result into PolicyGate; nil cwd → false
- **Composition acceptance:** peek and apply both see the same boolean (state, not a grant)  
- **Live smoke:** `tools/gate.sh RVServiceTests` after tests land in next unit; this unit may ship probe + wiring with a small probe unit test in RVServiceTests if added here — prefer tests in w3-service-tests. If this unit has no test file, live smoke is compile + existing GatedEvaluateTests still PASS (`tools/gate.sh RVServiceTests`).  
- **Depends on:** w3-eligible-gate  
- **Parallel-safe with:** none  
- **Code paths (exclusive):** `Sources/RVService/GitRebaseProbe.swift` (new), `Sources/RVService/GatedEvaluate.swift`  
- **Test paths (exclusive):** none (next unit)  
- **Gates:**  
  - `tools/gate.sh RVServiceTests`  
- **Reject (local):** walking HOME; using process cwd when hook cwd nil  
- **Residuals allowed:** ExplainStep for override  
- **Fat?:** no  
- **Skills to inject:** none  

#### Unit: w3-service-tests

- **Title:** Temp-repo rebase matrix  
- **Mode:** implement  
- **Goal:** REQ-069–071  
- **Acceptance:**
  1. All seven cases in spec REQ-069 PASS
  2. No live HOME; no real `git rebase` required
- **Composition acceptance:** `git restore --staged` still denies during rebase  
- **Live smoke:** `tools/swift-6.3.3 test --filter GatedEvaluateRebaseRecovery` → PASS  
- **Depends on:** w3-probe  
- **Parallel-safe with:** none  
- **Code paths (exclusive):** none  
- **Test paths (exclusive):** `Tests/RVServiceTests/GatedEvaluateRebaseRecoveryTests.swift`  
- **Gates:**  
  - `tools/gate.sh RVServiceTests`  
- **Reject (local):** asserting allow on reset --hard  
- **Residuals allowed:** pack explanation already describes auto-allow; no JSON edit required if true  
- **Fat?:** no  
- **Skills to inject:** none  

---

## 7. Integration acceptance (program complete)

- [ ] Wrapped `git reset --hard` still denies (F-unwrap)
- [ ] Hook reset-hard deny includes stash tip; no code; no box (F-deny-tip)
- [ ] `c-hook-proof.sh` green
- [ ] Fresh install / nil HOME compiles `system.disk`; postgres still off (F-disk-default)
- [ ] `mkfs`/`dd` to device denies; `dd` to file allows (REQ-048)
- [ ] Rebase dir: checkout -- allows; reset --hard denies (F-rebase)
- [ ] Residuals registered: Ask, AST, stack switch, rebase cookie, remaining packs default-on
- [ ] 02.md execute queue not silently rewritten

---

## 8. Launch recipes

### Wave W1

```text
workflow name=implementor
agent_budget=512
args={
  task: "W1 unwrap verify + hook deny tip. VERIFY_ONLY w1-unwrap-verify if gates green. Follow /Users/chriskarani/CodingProjects/rv/planning/2026-08-31-product-takes-implementable-program.md §W1. Spec: /Users/chriskarani/CodingProjects/rv/spec/spec-architecture-product-takes.md",
  plan: "/Users/chriskarani/CodingProjects/rv/planning/2026-08-31-product-takes-implementable-program.md",
  mode: "standard",
  max_units: 3,
  max_parallel: 2,
  product_oracle_cmds: [
    "tools/gate.sh RVEngineTests RVHooksTests",
    "tools/c-hook-proof.sh"
  ],
  thrash_threshold: 2
}
```

PlanHarden: implementor Phase 0 inline, or standalone:

```text
workflow name=plan-harden
agent_budget=512
args={ task: "W1 product takes", plan: "/Users/chriskarani/CodingProjects/rv/planning/2026-08-31-product-takes-implementable-program.md", mode: "standard" }
```

Host gate: `./scripts/plan-harden-gate.sh` may not exist in this repo — **residual:** use implementor’s built-in PlanHarden if present; otherwise human review of spec + this file.

### Wave W2

```text
workflow name=implementor
agent_budget=512
args={
  task: "W2 system.disk day-one. Follow plan §W2.",
  plan: "/Users/chriskarani/CodingProjects/rv/planning/2026-08-31-product-takes-implementable-program.md",
  mode: "standard",
  max_units: 2,
  max_parallel: 1,
  product_oracle_cmds: [
    "tools/gate.sh RVDomainTests RVPacksTests RVCorpusTests RVServiceTests"
  ]
}
```

### Wave W3

```text
workflow name=implementor
agent_budget=1024
args={
  task: "W3 rebase recovery. Follow plan §W3 and spec REQ-060–071.",
  plan: "/Users/chriskarani/CodingProjects/rv/planning/2026-08-31-product-takes-implementable-program.md",
  mode: "full",
  max_units: 3,
  max_parallel: 1,
  product_oracle_cmds: [
    "tools/gate.sh RVPolicyTests RVServiceTests"
  ]
}
```

### Resume / only_units

```text
only_units: ["w1-deny-fixtures"]
```

---

## 9. PR / review plan

- One PR per wave preferred (hook voice vs pack defaults vs policy I/O).
- Security-sensitive: W3 rebase (do not allow reset --hard). Prefer adversarial review on W3.
- Plan completeness: score this ledger, not 02.md tickets.
- After W1: hook-xpc skill + fixture honor paths.
- After W2: hexagonal SPM + “empty enabled means none” still true on the **request** field.

---

## 10. Deferred programs (explicit)

| Program | Why deferred | Entry criteria |
|---------|--------------|----------------|
| Host Ask (02.md step 6) | In-moment unlock without TTY; pause protocols | OPE-156 IR + analyzers per 02.md order; then OPE-264 |
| Heredoc / AST | Latency + FP program | phase-4-later extractor ladder; forensics first |
| Remaining packs default-on | FP/doctor noise | explicit product decision after disk take measured |
| Custom YAML packs / pack validate | not a take | later catalog UX |
| `rv rebase-recover` cookie | automatic state is enough for the take | if agents still stuck after rebase finishes |
| Stack preset | upstream does not have it | only if we invent rv-specific UX |
| SIMD | not the product gap | after profiling hook p95 |

---

## 11. Suggested workflow extensions (optional)

This repo has `tools/gate.sh`, not `./scripts/plan-harden-gate.sh`. Implementor PlanHarden host path may no-op. Reviewers should treat `spec/spec-architecture-product-takes.md` + this file as PLAN_READY after human read.

W2 `max_units: 2` is below full-mode’s 8-unit floor — **standard is correct**. Do not pad fake units.

---

## Implementor notes (copy into unit tasks)

**Deny tip algorithm** (`hostDenyWhy` + `hostDenyLine`):

1. Trim `reason`.
2. Strip command preview prefix (existing).
3. Split on first `. `. Left = sentence 1. Remainder = rest.
4. Sentence 2 = rest up to next `. ` or EOL; drop further sentences.
5. Capitalize sentence 1 as today; ensure both sentences end with `.`.
6. Omit sentence 2 per REQ-023–025.
7. Return `RV · Blocked. \(s1)` or `RV · Blocked. \(s1) \(s2)`.

**GitRebaseProbe:**

1. `cwd` nil → false.
2. `discoverRepositoryRoot` nil → false.
3. `root/.git`: if directory, gitdir = that path; if file, parse `gitdir:`; else false.
4. `fileExists` isDirectory on `gitdir/rebase-merge` or `gitdir/rebase-apply`.

**Eligibility helper** (innermost analysis):

```
switch gitAction {
case .discardWorktree: eligible
case .restore(_, _, true, _): eligible
case .reset, .clean, .push, .switchBranch, .stash, .createBranch, .deleteBranch, .deleteTag, .rebase, .restore(_, _, false, _): not eligible
case nil: pack rule id ∈ {checkout-discard, checkout-ref-discard, restore-worktree, restore-worktree-explicit}
}
deny.ruleID pattern reset-hard|reset-merge|clean-force|push-force-* → not eligible
```

**GatedEvaluate:** after `evaluateWithSemantics`, before PolicyGate, `let rebasing = GitRebaseProbe.rebaseInProgress(cwd: cwd)` and pass into `decide`/`apply`/`peek`.
