---
title: Product takes from pinned 0.11.0 upstream (deny tip, system.disk default, rebase recovery)
version: 1.0
date_created: 2026-08-31
last_updated: 2026-08-31
owner: rv
tags:
  - architecture
  - design
  - process
  - packs
  - policy
  - hook
---

# Introduction

This specification is the implementation contract for the product takes chosen after comparing rv to the pinned 0.11.0 upstream guard. It is written so a later agent can implement without inventing scope.

**Tree truth first:** bounded wrapper unwrap (`unwrapCommand`, OPE-256) is already in `Sources/RVEngine/Unwrap.swift` and is wired through `analyzeSemantics` / `GatedEvaluate`. This program **verifies** that take. It does not reimplement it. It does not add full heredoc/AST.

The remaining takes are: (1) put the safer next step on hook deny text, (2) turn `system.disk` on for a fresh install, (3) auto-allow the two git-discard families only while a rebase is actually in progress. In-moment Ask unlock is **not** this program; it stays `docs/architecture/02.md` § Order step 6.

`docs/architecture/02.md` remains the 0.2 execute queue. This spec does not replace OPE-156. A human may run these tickets as a side program. Agents following AGENTS.md still start at the first unfinished 02.md item unless the human names this spec.

Companion implementor plan: `planning/2026-08-31-product-takes-implementable-program.md`. New-session handoff: `planning/2026-08-31-product-takes/HANDOFF.md` + `PROMPT.md`.

# 1. Purpose & Scope

## Purpose

Make the live hook feel like a seatbelt at the block: teach a safer next step, cover disk-wipe commands out of the box, and unstick agents that are in a real rebase — without copying upstream bypass env, redeemable codes on the hook wire, a fake “my stack” switch, or 95 packs on by default.

## Audience

Implementers of rv (Swift 6.3.3, macOS 26, Apple Silicon) using `tools/gate.sh`. Reviewers using the ticket DAG in §5b.

## In scope

- Verify existing unwrap: `bash -c` / `sh -c` / `zsh -c` / `python -c` / `node -e` / `ruby -e` plus sudo/env/command; fail-closed `.unwrapLimited`; pack deny remains a floor.
- Hook deny voice: keep the second sentence of `Deny.reason` on the one-line `hostDenyLine` (safer next step already stored in pack `description`).
- Day-one pack set becomes `{core.filesystem, core.git, system.disk}`. Single source: `dayOnePackIDs`.
- Rebase recovery: PolicyGate override when `.git` rebase state exists; only discard/restore worktree; `git reset --hard` stays deny.
- Docs/vocabulary: `CONTEXT.md` day-one packs, `docs/dev/PARITY.md`, doctor check copy, host-contract canonical deny line, adapter fixtures.

## Out of scope

- Full heredoc / language AST / stdin-into-psql reconstruction.
- Enabling the rest of the catalog, a named “stack” preset, or custom YAML packs.
- `RV_BYPASS` or any env the hook child honors to skip evaluate.
- Redeemable allow-once **code** on hook JSON / `hostDenyText`.
- Explicit `rv rebase-recover` cookie / `.rv/rebase-recovery-permit` (upstream has this; not this program).
- Host Ask / ApprovalBridge / new host adapters (`docs/architecture/02.md` step 6).
- Changing `Decision`. Ask stays `HardPolicyDecision`, not a third `Decision` case.
- SIMD / latency rewrite.
- Repo/CI `rv scan repo`, SARIF.
- TTY pretty panel copied onto the hook (no `═══` box, no essay).

## Assumptions

- Pinned upstream remains 0.11.0 (`vendor/parity/PIN`). Parity scoreboard is still decision + `rule_id` for core git/fs. Disk default-on is a **policy** take, not a scoreboard rewrite.
- Engine `evaluate` stays pure (no `FileManager` / `Date()` / `ProcessInfo`).
- `EvaluationRequest` still has no cwd. Cwd enters at `GatedEvaluate`.
- Pack `description` for `core.git:reset-hard` is already `git reset --hard destroys uncommitted changes. Use 'git stash' first.`
- `hostDenyWhy` currently keeps only the first sentence; that is why the stash tip never reaches the hook.
- `RulePinning.blocksAllowOverride` currently blocks allow-once for `builtin.action:working-tree-discard`. Rebase recovery is a **narrower** override and must run **before** that pin, and must not treat `reset --hard` as eligible.
- `PackRegistry.loadDayOne()` currently hardcodes `["core.filesystem", "core.git"]`. That list must derive from `dayOnePackIDs`.
- `PackSet.defaultIDs` currently duplicates the same two IDs. It must become `dayOnePackIDs` (RVPacks already imports RVDomain).

# 2. Definitions

| Term | Meaning |
|---|---|
| **Pinned upstream** | destructive_command_guard **0.11.0** (`vendor/parity/PIN`). Source of pack JSON and these product takes. Not a binary we ship. |
| **Day-one packs** | The default enabled set for a missing/unreadable HOME and a fresh config. After this spec: `core.filesystem`, `core.git`, `system.disk`. |
| **`dayOnePackIDs`** | `Sources/RVDomain/RVDomain.swift`. **Only** algebra source for that set. |
| **`hostDenyText` / `hostDenyLine`** | One-line hook deny in `Sources/RVHooks/HostDenyText.swift`. Codecs copy it. They do not invent a second sentence. |
| **Safer next step** | Second sentence of `Deny.reason` after the first `. ` split, command prefix already stripped. Example: `Use 'git stash' first.` |
| **Canonical reset-hard deny** | After this spec: `RV · Blocked. Destroys uncommitted changes. Use 'git stash' first.` |
| **Unwrap** | `unwrapCommand` in RVEngine. Already shipped (OPE-256). |
| **Rebase in progress** | After resolving the Git dir from cwd, `rebase-merge` **or** `rebase-apply` exists as a **directory** under that Git dir. Same signals as upstream 0.11.0 automatic recovery. |
| **Rebase-eligible discard** | `GitAction.discardWorktree`, or `GitAction.restore` with `worktree == true`; **or**, if `gitAction` is nil, pack rule IDs `checkout-discard`, `checkout-ref-discard`, `restore-worktree`, `restore-worktree-explicit`. |
| **Policy override `rebaseRecovery`** | New `PolicyOverride` case. Does not spend `AllowOnceStore`. Does not write allowlist. |
| **`corePacksReady`** | After this spec: every id in `dayOnePackIDs` compiled into the session. Doctor message lists those ids, not a hardcoded two-pack string. |

# 3. Requirements, Constraints & Guidelines

## Functional — unwrap (verify)

- **REQ-010**: `bash -c 'git reset --hard'` must deny with the same floor as `git reset --hard` (pack and/or semantic). Existing tests in `Tests/RVEngineTests/UnwrapTests.swift`, `AnalyzeSemanticsTests.swift`, `Tests/RVServiceTests/GatedEvaluateWrapperSemanticsTests.swift` stay green. Do not rewrite `Unwrap.swift` unless a gate is red.
- **REQ-011**: Quoted `rm -rf` / `git reset --hard` as **data** (e.g. `grep` / `echo`) must not unwrap to execution. Existing fixtures own this.
- **REQ-012**: Unquoted `-c`, command substitution, or depth/byte cap → `.unwrapLimited` → deny, never allow. Do not add heredoc/AST in this program.

## Functional — deny tip

- **REQ-020**: `hostDenyLine(command:reason:)` shall be `RV · Blocked. ` + why, where why is sentence 1 of `hostDenyWhy` plus, when present, a space and sentence 2.
- **REQ-021**: Sentence split remains the first `. ` in the stripped reason (same as today’s first-sentence cut). Sentence 2 is the remainder up to the next `. ` or end, then a period if missing. A third sentence is dropped (no essay).
- **REQ-022**: Strip the command preview prefix from the front of the reason **before** splitting sentences (keep current `hostDenyWhy` prefix strip).
- **REQ-023**: If sentence 2 is empty, or contains `allow-once`, `ALLOW-`, `redeem`, `RV_BYPASS`, or a newline, omit sentence 2.
- **REQ-024**: If the full `hostDenyLine` would contain U+001B, `═`, `┌`, or a newline, omit sentence 2 (keep sentence 1 only). Still one line.
- **REQ-025**: If sentence 1 + sentence 2 together exceed **180** Unicode scalars after `RV · Blocked. `, omit sentence 2.
- **REQ-026**: `RVHooks` must **not** import `RVPresentation`. Do not call `suggestions(for:)`. The pack `description` second sentence is the hook tip. TTY `Suggestions.swift` stays TTY-only.
- **REQ-027**: Hook JSON still must not include a redeemable allow-once code. `hookUnlockNext` may remain on **Ask** lines only (`hostAskLine`). First-call pack **deny** `next` stays nil.
- **REQ-028**: Allow remains silent. Indeterminate remains `incompleteEvalSentence` (no tip).
- **REQ-029**: Update every pinned canonical string listed in §9 from `RV · Blocked. Destroys uncommitted changes.` to `RV · Blocked. Destroys uncommitted changes. Use 'git stash' first.`
- **REQ-030**: `assertHookDenyHasNoBypassOrEssay` (and copies) must **stop** forbidding `git stash` on reset-hard deny. They must still forbid `allow-once`, `Terminal`, `git reset --hard` as command echo, boxes, ANSI, redeem codes.

## Functional — system.disk default-on

- **REQ-040**: `dayOnePackIDs` is exactly `[core.filesystem, core.git, system.disk]` in that array’s current sort-or-literal order. Lock order as **sorted by `rawValue`**: `core.filesystem`, `core.git`, `system.disk` (matches `loadDayOne` sort). Update `Tests/RVDomainTests/NewtypeTests.swift` `dayOnePackIDs_areNonFailableConstants`.
- **REQ-041**: Add `PackID.systemDisk` next to `coreGit` / `coreFilesystem`.
- **REQ-042**: `PackSet.defaultIDs` shall be `dayOnePackIDs` (no second literal list).
- **REQ-043**: `PackRegistry.loadDayOne` shall load `dayOnePackIDs.map(\.rawValue)`, not a hardcoded two-name array. Empty-pack throw still applies to each day-one document.
- **REQ-044**: `Sources/RVPacks/Resources/packs/system.disk.json` `"enabled_by_default": true`. `index.json` `"default_enabled"` includes `system.disk`.
- **REQ-045**: `PackSet.effectiveOrdered(enabled: [], disabled: [], …)` includes `system.disk` and still excludes `database.postgresql` / `containers.docker` until enabled.
- **REQ-046**: Operator can still `rv packs disable system.disk`. Disabled wins after expansion (existing algebra).
- **REQ-047**: Fresh HOME / nil HOME walk compiles all three. Empty `[packs] enabled` in config still means **none extra**; defaults still union (existing `defaults.union(on).subtracting(off)`). Do not change “empty enabled means none” for the **request** `enabledPacks` field (cli-thin law).
- **REQ-048**: Day-one evaluate of a catastrophic disk command denies. Minimum corpus (add under `Tests/RVCorpusTests` or `Tests/RVEngineTests`):
  - deny: `mkfs.ext4 /dev/disk0` (or the first matching destructive pattern in `system.disk.json`)
  - deny: `dd if=/dev/zero of=/dev/rdisk0 bs=1m` (device `of=`; not `of=file.bin`)
  - allow: `dd if=/dev/zero of=./out.bin` (safe `dd-file-out`)
  - allow: `lsblk`, `df`, `mount` with no args (existing safe patterns)
- **REQ-049**: `enablement_k8sCategoryAddsThreePlusCore` expected `raw.count` becomes **6** (three day-one + three k8s). Any other test that assumed day-one cardinality 2 must use `dayOnePackIDs.count` or be updated.
- **REQ-050**: Doctor packs check message: include all three ids (e.g. `core.filesystem, core.git, and system.disk loaded`). `DoctorSnapshotBuilder` must not keep the two-pack sentence.
- **REQ-051**: `CONTEXT.md` **Day-one packs**: three ids; “v1 evaluate always uses these” updates to the new set. Catalog still does not imply extras on.
- **REQ-052**: `docs/dev/PARITY.md` Catalog section: default-on includes `system.disk`; remaining catalog still default-off. `docs/factory/specs/phase-4-later.md` “system.disk stays off” row is **superseded** for disk only; remaining-packs default-on stays later.
- **REQ-053**: Do not enable `system.permissions`, `system.services`, or any other pack by accident.

## Functional — rebase recovery

- **REQ-060**: New pure function in **RVPolicy** (name locked): `RebaseRecovery.isEligible(result: EvaluationResult) -> Bool`. No I/O.
- **REQ-061**: Eligible iff **all** of: decision is deny; rule is not `core.git:reset-hard` / `reset-merge` / `clean-force` / any `push-force-*`; and either (a) innermost `GitAction` is rebase-eligible discard, or (b) `gitAction` is nil and `deny.ruleID` is one of the four pack ids in §2.
- **REQ-062**: Innermost `GitAction.reset` (any mode), `.clean`, `.push`, `.switchBranch`, `.stash` → **not** eligible. `reset --hard` during rebase stays deny.
- **REQ-063**: `builtin.action:working-tree-discard` is eligible **only** when innermost `GitAction` is rebase-eligible discard. Do not key off the builtin rule id alone.
- **REQ-064**: New `PolicyOverride.rebaseRecovery`. `PolicyGate.decide` parameters: add `rebaseInProgress: Bool` (default `false` at every existing call site, then wire the real value from GatedEvaluate).
- **REQ-065**: Order inside deny branch of `decide`: (1) if `rebaseInProgress && isEligible` → allow + `.rebaseRecovery`; (2) else `RulePinning.blocksAllowOverride` → stay deny; (3) allowlist; (4) allow-once. Rebase recovery **must** run before the working-tree-discard pin so it can fire.
- **REQ-066**: `PolicyGate.apply` / `peek` / `spendHostAllowOnce` must pass `rebaseInProgress` through. Rebase recovery must **not** call `AllowOnceStore.consume` or `HostGrantWriter.plantAndSpend`.
- **REQ-067**: I/O in **RVService** only. New `GitRebaseProbe` (file: `Sources/RVService/GitRebaseProbe.swift`) next to `FilesystemLiveProbe`. Reuse `FilesystemLiveProbe.discoverRepositoryRoot(from:)`. If no repo root → `false`. If `.git` is a **directory**, Git dir = `repo/.git`. If `.git` is a **file**, parse a single `gitdir: <path>` line (trim; relative paths resolve against `repo`). If parse fails or path missing → `false` (not in progress; stay deny). Then `true` iff `gitdir/rebase-merge` or `gitdir/rebase-apply` exists and `FileManager` reports **isDirectory**.
- **REQ-068**: `GatedEvaluate.evaluateWithSemantics` / `gated` reads `GitRebaseProbe.rebaseInProgress(cwd:)` when cwd is non-nil and honor-able. Missing cwd → `false` (same as allow-once skip).
- **REQ-069**: Tests use a **temp directory** git layout (create `.git/` dir + `rebase-merge/`). No live HOME. No real `git rebase` required. Cases:
  1. rebase dir present + `git checkout -- file` → allow, override rebaseRecovery
  2. rebase dir absent + same command → deny
  3. rebase dir present + `git reset --hard` → deny
  4. rebase dir present + `git restore .` (worktree) → allow
  5. rebase dir present + `git restore --staged .` → deny (not worktree discard)
  6. worktree `.git` file pointing at a gitdir that has `rebase-merge` → allow for checkout --
  7. cwd nil → deny for checkout -- even if some other folder is rebasing
- **REQ-070**: Pack JSON `explanation` for checkout-discard / restore-worktree already claims auto-allow during rebase. After this ticket that claim must be **true**. Do not add `rv rebase-recover` CLI.
- **REQ-071**: `rv test` / peek in a rebasing temp repo allows the eligible command (state, not a grant). Document in `rv explain` only if an ExplainStep already exists for policy override; otherwise residual: robot JSON decision is allow. Do not invent a second Decision.

## Security

- **SEC-001**: No `RV_BYPASS`. No env skip of evaluate.
- **SEC-002**: Never allow because XPC missed.
- **SEC-003**: Rebase recovery is not a general working-tree-discard hole. `reset --hard` / `clean -f` / force-push stay denied during rebase.
- **SEC-004**: Unreadable Git dir → not in progress → deny. Do not fail open.
- **SEC-005**: No command text in `os_log`.
- **SEC-006**: Hook deny still must not carry a mint/redeem code.
- **SEC-007**: `core.secrets` and protected-path hard stops stay unoverridable (rebase eligibility must not include them).

## Constraints

- **CON-001**: Hexagon: unwrap stays RVEngine; enablement RVPacks + `dayOnePackIDs` in RVDomain; rebase I/O RVService; rebase eligibility + PolicyGate RVPolicy; deny sentence RVHooks; TTY suggestions RVPresentation.
- **CON-002**: Value types in Domain/Engine/Packs/Presentation. No `try!` / `!` on production paths.
- **CON-003**: Tests: Swift Testing. Temp HOME / temp git dir. No live-HOME writes.
- **CON-004**: Gate: `tools/gate.sh <Module>Tests` via `tools/swift-6.3.3`. Keep `.build` warm. Do not `swift package clean` to prove compile.
- **CON-005**: Do not start OPE-156 or Host Ask as part of this spec.
- **CON-006**: Do not invent a databases+docker+kubernetes “stack” switch. Category expand (`enabled = ["database"]`) already exists in `PackSet.expand`.
- **CON-007**: Protocol stays `rv.ipc.v1`. No new IPC verb required (evaluate/hookEvaluate already return `EvaluationResult` after PolicyGate).
- **CON-008**: Do not import RVPresentation from RVHooks or RVPolicy.
- **CON-009**: Do not put foreign product names in `install.sh`, README hero, or adapter user-visible strings. Factory/spec files may name the 0.11.0 pin.

## Guidelines

- **GUD-001**: Prefer extending `hostDenyWhy` over a parallel tip catalog.
- **GUD-002**: Prefer `dayOnePackIDs` in tests instead of new string literals.
- **GUD-003**: Doctor / analytics events that list enabled packs will pick up `system.disk` automatically if they already dump `dayOnePackIDs` / catalog.enabledIDs. Hardcoded two-pack strings must be hunted (`rg "core.git and core.filesystem"`).

## Patterns

- **PAT-001**: PolicyGate stays a pure `decide` plus I/O wrappers. Probe at the door, boolean into `decide`.
- **PAT-002**: FilesystemLiveProbe already walks cwd for `.git` with `fileExists` (file or directory). GitRebaseProbe must distinguish file vs directory for gitdir resolution.
- **PAT-003**: Adapter fixtures under `Tests/RVHooksTests/Fixtures/{pi,grok,opencode,claude,openclaw,hermes,codex,cursor}/` are the honor path. Update them in the same deny-tip ticket as `HostDenyText.swift`.

# 4. Interfaces & Data Contracts

## 4.1 `dayOnePackIDs`

```swift
// Sources/RVDomain/RVDomain.swift
public let dayOnePackIDs: [PackID] = [
    PackID(rawValue: "core.filesystem"),
    PackID(rawValue: "core.git"),
    PackID(rawValue: "system.disk"),
]
```

`EvaluationRequest.makeDayOne` already uses `dayOnePackIDs` — no new API.

## 4.2 `hostDenyLine`

Input: `command`, `reason` (full pack/builtin reason).  
Output: one line. Reset-hard golden:

```
RV · Blocked. Destroys uncommitted changes. Use 'git stash' first.
```

Builtin one-sentence reasons stay `RV · Blocked. <Capitalized sentence>.` with no second clause.

## 4.3 `PolicyOverride`

```swift
public enum PolicyOverride: Equatable, Sendable {
    case none
    case allowlist
    case allowOnce
    case rebaseRecovery
}
```

`PolicyGate.decide` gains `rebaseInProgress: Bool = false`.

## 4.4 `RebaseRecovery.isEligible`

Pure. Reads `result.decision`, `result.analysis.innermost`, `result.analysis.gitAction` (walk wrappers). See REQ-060–063.

## 4.5 `GitRebaseProbe`

```swift
enum GitRebaseProbe {
    static func rebaseInProgress(cwd: WorkingDirectory?) -> Bool
}
```

Uses `FileManager.default`. Tests create directories; do not inject a protocol unless an existing probe pattern requires it (FilesystemLiveProbe does not).

## 4.6 No IPC change

`hookEvaluate` still returns codec stdout. Deny reason bytes change because `hostDenyText` changes. Hosts that compare exact strings (fixtures) must update. Hosts that display `reason` will show the tip without adapter logic changes.

# 5. Acceptance Criteria

- **AC-010**: Given existing unwrap tests, When `tools/gate.sh RVEngineTests RVServiceTests --filter` wrapper/unwrap names, Then they pass without Unwrap.swift edits.
- **AC-020**: Given deny reason `git reset --hard destroys uncommitted changes. Use 'git stash' first.`, When `hostDenyText` runs, Then output is the canonical reset-hard deny in §4.2, one line, no `allow-once`, no command `git reset --hard`.
- **AC-021**: Given Pi/Grok/OpenCode/Claude/OpenClaw/Hermes/Codex/Cursor reset-hard fixtures, When codecs encode deny, Then stdout/stderr honor paths contain the new canonical string.
- **AC-040**: Given empty enabled/disabled config and bundled index, When `PackSet.effectiveOrdered`, Then set is the three day-one ids and not `database.postgresql`.
- **AC-041**: Given `rv test 'mkfs.ext4 /dev/disk0'` (or locked corpus row) with default packs, Then decision is deny and rule pack is `system.disk`.
- **AC-042**: Given `rv packs disable system.disk` then the same mkfs command, Then packs no longer deny that disk rule (git/fs unchanged).
- **AC-060**: Given temp repo with `.git/rebase-merge/` and cwd there, When gated apply `git checkout -- foo`, Then allow with rebaseRecovery; When `git reset --hard`, Then deny.
- **AC-061**: Given the same commands without rebase directories, Then checkout -- denies.

# 5b. Tickets (task graph)

| id | title | depends-on | exclusive-writes | acceptance | review-hint |
|---|---|---|---|---|---|
| T1 | Verify unwrap take; gap-fill only if red | none | none unless gate fail → `Sources/RVEngine/Unwrap.swift` | AC-010 | ≤100 if no edit |
| T2 | Second sentence on `hostDenyLine` | none | `Sources/RVHooks/HostDenyText.swift`, `Tests/RVHooksTests/HostDenyTextTests.swift` | AC-020 | 101–1499 |
| T3 | Canonical deny fixtures + host contracts + c-hook-proof | T2 | `Tests/RVHooksTests/Fixtures/**`, `Tests/RVHooksTests/AdapterHookTests.swift`, `Tests/RVServiceTests/HookEvaluateTests.swift`, `Tests/RVCLITests/HookDispatchTests.swift`, `Tests/RVCLITests/HookCommandTests.swift`, `Tests/RVCLITests/LinuxCHookTests.swift`, `Tests/RVTUITests/Fixtures/snapshots/phase-1b/host-deny-text-git-reset-hard.txt`, `docs/factory/references/host-contracts-v1.md`, `tools/c-hook-proof.sh` | AC-021 | 101–1499 |
| T4 | Day-one algebra = three packs + tests that go red immediately | none | `Sources/RVDomain/RVDomain.swift`, `Sources/RVDomain/PackID.swift`, `Sources/RVPacks/PackEnablement.swift`, `Sources/RVPacks/PackRegistry.swift`, `Sources/RVPacks/Resources/packs/system.disk.json`, `Sources/RVPacks/Resources/packs/index.json`, `Tests/RVDomainTests/NewtypeTests.swift`, `Tests/RVPacksTests/EnablementTests.swift`, `Tests/RVPacksTests/PackLoadTests.swift` | AC-040, REQ-049 (k8s count 6) | 101–1499 |
| T5 | Doctor, CONTEXT, PARITY, disk corpus, remaining two-pack literals | T4 | `Tests/RVCorpusTests/**` (disk rows), `Tests/RVPacksTests/CatalogLoadTests.swift` (if `default_enabled` asserted), `Sources/RVService/DoctorSnapshotBuilder.swift`, `CONTEXT.md`, `docs/dev/PARITY.md`, `docs/factory/specs/phase-4-later.md`, `docs/architecture/MODULES.md`, `docs/architecture/MAP.md`, plus remaining `rg` hits for `core.git and core.filesystem` / complete-set literals `["core.filesystem", "core.git"]` in Tests/Sources (not files T4 already updated) | AC-041, AC-042, REQ-050–052 | ≥1500 |
| T6 | `RebaseRecovery` + `PolicyOverride` + `PolicyGate.decide` order | none | `Sources/RVPolicy/PolicyGate.swift`, new `Sources/RVPolicy/RebaseRecovery.swift`, `Tests/RVPolicyTests/**` (new + existing decide tests) | REQ-060–066 unit tests without FileManager | 101–1499 |
| T7 | `GitRebaseProbe` + GatedEvaluate plumbing | T6 | `Sources/RVService/GitRebaseProbe.swift`, `Sources/RVService/GatedEvaluate.swift` | REQ-067–068 | 101–1499 |
| T8 | Temp-repo rebase tests | T7 | `Tests/RVServiceTests/GatedEvaluateRebaseRecoveryTests.swift` (new) | AC-060, AC-061, REQ-069 | 101–1499 |

T1 ∥ T2 ∥ T4 ∥ T6. T3 after T2. T5 after T4. T7 after T6. T8 after T7.

Do not overlap T2 and T3 on `HostDenyText.swift`. T4 owns algebra plus the three test files that fail as soon as `dayOnePackIDs` grows. T5 must not edit those three test files or the algebra sources.

# 6. Test Automation Strategy

- **Test levels**: Swift Testing unit/integration. Live smoke: `tools/swift-6.3.3 run --skip-build` only if the `rv` product is already built; prefer `tools/gate.sh` filters plus `tools/c-hook-proof.sh` after T3.
- **Frameworks**: `import Testing`. No XCTest. No mocks unless an existing probe fakes FileManager (it does not — use temp dirs).
- **Test data**: `FileManager.default.temporaryDirectory` + unique UUID folders. `git init` optional; creating `.git/rebase-merge` is enough.
- **CI**: existing package tests. No new CI job.
- **Coverage**: binary ACs above. Disk corpus ≥ the four rows in REQ-048.
- **Performance**: not a gate. Residual: day-one compile includes `system.disk` patterns (larger than two packs). Do not add SIMD work.

Gate commands (copy into tickets):

```sh
tools/gate.sh RVEngineTests RVServiceTests
tools/gate.sh RVHooksTests
tools/gate.sh RVCLITests RVTUITests
tools/gate.sh RVDomainTests RVPacksTests RVCorpusTests RVServiceTests RVPresentationTests RVCLITests
tools/gate.sh RVPolicyTests
tools/gate.sh RVServiceTests
```

# 7. Rationale & Context

Unwrap is the highest-value take and is **already shipped**. Re-building it would fight MODULES.md OPE-256.

The deny is the product moment. Pack JSON already teaches “stash first”; `hostDenyWhy` throws that sentence away. Putting it back is a small hook-voice change with a large fixture blast radius (REQ-029).

`system.disk` is on by default in upstream 0.11.0 (with core packs). rv imported the pack and left it off. Turning it on is a policy flip, not a new engine. Cardinality-2 tests are the real work.

Rebase recovery is in pack `explanation` today but unimplemented. Agents get stuck on `checkout --` / `restore` during rebase. Upstream auto-allows those four rules when rebase state exists and still blocks `reset --hard`. Semantic `working-tree-discard` would swallow that unless eligibility uses `GitAction`. Engine purity forbids checking `.git` inside `evaluate`.

Ask-in-the-host is the remaining “unlock where you were blocked” take. It needs pause protocols and is already queued as 02.md Host Ask. Implementing a 6-digit code on the hook would violate T8 unlock law. This spec therefore **defers** Ask.

A “one stack switch” was considered and rejected: upstream has **category expand**, not a databases+docker+kubernetes product switch. rv already expands `database` / `containers` / `kubernetes` tokens.

# 8. Dependencies & External Integrations

### External Systems
- **EXT-001**: Git repository layout on disk (`.git` dir or `gitdir:` file, `rebase-merge` / `rebase-apply`). Read-only probe.

### Third-Party Services
- None.

### Infrastructure Dependencies
- **INF-001**: `tools/gate.sh` + `tools/swift-6.3.3` + warm `.build`.
- **INF-002**: Existing XPC `hookEvaluate` path; C hook proof script `tools/c-hook-proof.sh`.

### Data Dependencies
- **DAT-001**: Bundled `system.disk.json` and `core.git.json` descriptions/explanations.
- **DAT-002**: `vendor/parity/PIN` 0.11.0 (do not bump).

### Technology Platform Dependencies
- **PLT-001**: macOS 26 Apple Silicon, Swift 6.3 language mode 6, tools 6.3.3.

### Compliance Dependencies
- **COM-001**: AGENTS.md forbidden list: no bypass env, no command text in os_log, no live-HOME tests, no Seatbelt claim.

# 9. Examples & Edge Cases

## Deny tip

```swift
// reason from pack description
"git reset --hard destroys uncommitted changes. Use 'git stash' first."
// → "RV · Blocked. Destroys uncommitted changes. Use 'git stash' first."

"Discarding working-tree files is a built-in hard deny."
// → "RV · Blocked. Discarding working-tree files is a built-in hard deny."

"A. B. C. D."
// → "RV · Blocked. A. B."   // third+ dropped
```

## Disk

```text
# default on
rv test 'mkfs.ext4 /dev/disk0'     # deny system.disk
rv test 'dd if=/dev/zero of=out.bin'  # allow (file of=)
rv packs disable system.disk
rv test 'mkfs.ext4 /dev/disk0'     # allow (unless another pack hits)
```

## Rebase

```text
repo/.git/rebase-merge/   # directory exists
cwd = repo
git checkout -- foo.swift    # allow (rebase recovery)
git reset --hard             # deny
git push --force             # deny
```

Worktree:

```text
repo/.git  # file: "gitdir: /tmp/worktrees/agent/git"
/tmp/worktrees/agent/git/rebase-apply/  # directory
# checkout -- from repo cwd → allow
```

# 10. Validation Criteria

- [ ] T1 unwrap gates green without scope creep into AST.
- [ ] Canonical reset-hard deny string updated in every path in REQ-029 / T3 exclusive-writes.
- [ ] `rg "RV · Blocked. Destroys uncommitted changes[^\.]"` has no stale honor-path hits (string without the stash clause). Exception: comments that describe the *old* string in this spec.
- [ ] `rg "core.git and core.filesystem loaded"` is gone or updated.
- [ ] `dayOnePackIDs` / `loadDayOne` / `PackSet.defaultIDs` / `index.json` `default_enabled` / `system.disk.json` `enabled_by_default` agree.
- [ ] Rebase tests cover allow discard, deny reset-hard, missing cwd, worktree gitdir.
- [ ] `tools/gate.sh` for every touched module is green.
- [ ] No `RV_BYPASS`. No allow-once code on deny fixtures.

# 11. Related Specifications / Further Reading

- `planning/2026-08-31-product-takes-implementable-program.md` — implementor waves/units
- `planning/2026-08-31-product-takes/HANDOFF.md` + `PROMPT.md` — new-session kickoff
- `docs/architecture/02.md` — 0.2 execute queue; Host Ask is step 6; do not greenfield unwrap
- `docs/architecture/MODULES.md` — OPE-256 unwrap, PolicyGate, hexagon
- `docs/architecture/host-ask.md` / `host-ask-plan.md` — deferred Ask
- `docs/factory/specs/phase-3-allow.md` — unlock law; rebase-recovery was out of T8
- `docs/factory/specs/phase-4-later.md` — heredoc/AST later; remaining packs later; this spec carves `system.disk` default-on
- `docs/factory/references/` pinned 0.11.0 notes — pack catalog and “rebase-recover is not v1” (superseded for automatic rebase-state only)
- `docs/factory/references/host-contracts-v1.md` — canonical deny line (T3)
- `docs/dev/PARITY.md` — catalog defaults
- `CONTEXT.md` — day-one packs vocabulary
- `Sources/RVEngine/Unwrap.swift`, `Sources/RVHooks/HostDenyText.swift`, `Sources/RVPolicy/PolicyGate.swift`, `Sources/RVService/FilesystemLiveProbe.swift`
