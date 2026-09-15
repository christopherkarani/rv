---
title: Functional evolution — GitLiveProbe, one wired law, English compile chain
version: 1.0
date_created: 2026-09-15
last_updated: 2026-09-15
owner: rv
tags: [architecture, functional, evaluate, setup, policy]
---

# Introduction

Execute the three Strong candidates from `$TMPDIR/swift-functional-evolution-rv-20260915-041545.html` (HEAD `8ef53e4`, worktree `rapid-meadow-8a2e`).

1. **T1** — `GitLiveProbe` fills `GitAnalysisContext.currentBranch` / `isSharedBranch` at the live evaluate door, and yields rebase-in-progress from the same gitdir walk. Top recommendation.
2. **T2** — `HostAdapterInstallation.inspect` `.wired` means the C hook can exec sibling `rv-cli`. Doctor and scan consume that state.
3. **T3** — English compile chain (AFM else Fake) is a compiler value. `PolicyDraftCommand` does not catch `EnglishCompilerError` and re-run save.

Do not execute worth-exploring C04 (pin reconstructed force) or C05 (Host Ask wait door). Do not add `GitAnalysisWorld`. Do not add `EvaluatePolicyWorld`. Do not invent HookDoorPorts. Do not fold XPC miss into `HookDoor`. Do not type MachineConfig JSON. Do not rewrite setup as file-op plans.

Audience: fresh-context implementer and reviewer subagents. Toolchain: Swift 6.3.3 (`tools/swift-6.3.3`), language mode 6, macOS 26. Gate: `tools/gate.sh`. Warm `.build`. Never `swift package clean`. After the first compile in a worktree, `git restore Package.resolved` unless this ticket owns dependency changes.

# 1. Purpose & Scope

Close three leftover shell holes after the evaluation door, Policy gate, File tool, Scan classify world, UnlockableDeny, GitPushForceConstraint, FilesystemAnalysisWorld, and DenialLedgerRecord already landed.

## In scope

- RVService `GitLiveProbe` + `GatedEvaluate` git context + rebase fact.
- RVCLI `HostAdapterInstallation.inspect` sibling `rv-cli` check; `DoctorRun` projection; scan nudge agreement.
- RVPolicy/RVCLI English compile fallback as one compiler; `PolicyDraftCommand` single execute.

## Out of scope

- Scan classify probing HEAD (stays cwd-only).
- Scraping remotes / upstream / GitHub protected branches.
- `GitAnalysisWorld` enum.
- Pin from `GitAction.push` force (C04).
- Host Ask wait as one door (C05).
- Setup file-op interpreter.
- MachineConfig `[String: Any]` bag.
- Engine `evaluate` / `apply*(pack:command:)` leftover overloads.
- `Decision.ask`. File tool door. Pack JSON.

# 2. Definitions

| Term | Meaning |
|---|---|
| GitLiveProbe | RVService shell: read gitdir / HEAD into `GitAnalysisContext` plus rebase-in-progress. Engine stays pure. |
| Implicit refspec | `git push [--force-with-lease] [remote]` with no branch token. `analyzeGit.parsePush` uses `context.currentBranch`. |
| Shared by name | `main` or `master` (existing `ActionPolicyEngine.sharedBranchNames`). |
| Fail-open git | Default `isSharedBranch == false` plus nil `currentBranch` makes `--force-with-lease` `remoteBranchAsk` instead of the shared-branch wall. |
| Wired | Miss path ready: baked `rv` executable **and** sibling `rv-cli` executable next to it. |
| English compile chain | Try `FoundationModelsEnglishCompiler`, on `EnglishCompilerError` use `FakeEnglishCompiler`. One compile result, then optional save. |

# 3. Requirements, Constraints & Guidelines

## T1 — GitLiveProbe

- **REQ-101**: Add `GitLiveProbe` in RVService (enum or struct, value type). It must not live in RVEngine or RVDomain.
- **REQ-102**: `GitLiveProbe.facts(cwd:homeDirectory:)` (name may vary) returns a value with:

  ```swift
  struct GitLiveFacts: Sendable, Equatable {
      var analysis: GitAnalysisContext
      var rebaseInProgress: Bool
  }
  ```

  `analysis.workingDirectory` is `cwd`. `analysis.currentBranch` is the short name from `HEAD` when it is `ref: refs/heads/<name>`. Detached / missing / unborn HEAD → `currentBranch == nil`. `analysis.isSharedBranch` is true iff that name is `main` or `master`. Do not scrape remotes.
- **REQ-103**: Reuse `FilesystemLiveProbe.discoverRepositoryRoot` and the existing gitdir-file parse (today in `GitRebaseProbe`). Worktree / submodule `.git` file stops at that checkout. Missing gitdir → `GitAnalysisContext(workingDirectory: cwd)` (unknown branch, `isSharedBranch == false`) and `rebaseInProgress == false`. **Not** a filesystem unresolved-path deny.
- **REQ-104**: `GatedEvaluate.evaluateWithSemantics` injects `facts.analysis` instead of `GitAnalysisContext(workingDirectory: cwd)`. Policy gate uses `facts.rebaseInProgress` instead of calling `GitRebaseProbe` after evaluate. One gitdir walk per evaluate.
- **REQ-105**: `GitRebaseProbe` either becomes a wrapper around `GitLiveProbe` or is deleted if all callers move. Do not leave two independent HEAD/gitdir readers.
- **REQ-106**: `ScanClassify` still builds `GitAnalysisContext(workingDirectory: event.workingDirectory)` only. Do not call `GitLiveProbe` from RVScan. RVScan must not import RVService.
- **REQ-107**: First failing service test: temp repo, `HEAD` → `refs/heads/main`, `GatedEvaluate.peek("git push --force-with-lease")` (no refspec) is `.deny` with `ActionPolicyEngine.Builtin.remoteSharedBranch.ruleID` and `boundReview == .deny(...)`. Same command with `HEAD` → `refs/heads/topic` is `.deny` with `remoteBranchAsk` and `boundReview == .mandatoryHuman(...)`. Same command with cwd that has no `.git` stays `remoteBranchAsk` (unknown, not unresolved-path).
- **REQ-108**: Existing `GatedEvaluateGitSemanticsTests.pushVersusForcePush_differAndForceStaysDenied` stays pack `core.git:push-force-long` for `git push --force origin main`. Pack `--force` is not this ticket’s hole.
- **CON-101**: No `FileManager` / `Date()` / `ProcessInfo` in RVDomain or RVEngine. No `GitAnalysisWorld` enum. Do not fail-closed as `builtin.action:unresolved-path` when HEAD is missing.
- **CON-102**: Do not change pack JSON. Do not probe scan. Do not fill `isSharedBranch` expecting to deny non-force `git push origin main` (builtin wall does not tag non-force push).
- **GUD-101**: Inject `FileManager` if tests need a fake; `FileManager.default` is acceptable if tests use real temp dirs (match `FilesystemLiveProbe` style).
- **GUD-102**: Update `CONTEXT.md` evaluation-door sentence and `docs/architecture/MODULES.md` Git/filesystem I/O sentence so Git facts enter through `GitLiveProbe` next to `FilesystemLiveProbe`.

## T2 — One wired law

- **REQ-201**: `HostAdapterInstallation.inspect` `.wired` requires baked `rv` executable **and** sibling `rv-cli` executable in the same directory as that baked path. Missing or non-exec `rv-cli` is `.broken`, including Claude.
- **REQ-202**: `DoctorRun.doctorHostState` maps `.wired` → `.wired` and `.broken` → `.broken` without re-parsing adapter bytes or calling `HostAdapterResources.load`. Delete `isExecutableRvCli` from DoctorRun.
- **REQ-203**: Scan nudge (`scanSetupNudgeRecommended`) keeps `snapshot.state(for:) != .wired`. After REQ-201 it agrees with doctor.
- **REQ-204**: Move `doctor_nonExecutableRvCliNextToBakedRvIsBrokenNotWired` (or equivalent) so inspect itself is `.broken`. Add one fixture that setup plan, doctor, and scan nudge agree.
- **REQ-205**: Fix the ClaudeSettingsMerge comment that says doctor/inspect check sibling without changing `HostAdapterInstallation`.
- **CON-201**: Do not fold File tool door into this ticket. Do not invent a third host-health enum. Do not change honor JSON.
- **GUD-201**: Setup copy may say broken where it previously said wired when `rv-cli` is missing. That is the product.

## T3 — English compile chain

- **REQ-301**: Add a small `EnglishCompileChain: EnglishCompiler` (RVPolicy, next to `FoundationModelsEnglishCompiler`). `compile` tries AFM; on `EnglishCompilerError` calls `FakeEnglishCompiler`. Other errors still throw. Do not catch inside `PolicyDraftCommand`.
- **REQ-302**: `PolicyDraftCommand.run` constructs `EnglishCompileChain()` (or injects it) and calls `PolicyDraftRun.execute` **once**. Delete the `catch is EnglishCompilerError { execute(... Fake ...) }` retry.
- **REQ-303**: `PolicyDraftRun.execute` stays compile then optional upsert. Do not retry upsert because compile fell back.
- **REQ-304**: Tests: a compiler that throws `EnglishCompilerError.unavailable` as the AFM stand-in, then Fake, still compiles the canned gitPush fixture; arbitrary English still refuses; `--save` with Fake fixture writes once (no double upsert). Command-level test: `EnglishCompilerError` is not caught in `PolicyDraftCommand` (execute once).
- **CON-301**: Do not widen Fake to guess English. Fake still emits `GitPushForce.force` (does not match `--force-with-lease`). Foundation Models stay out of Domain/Engine. Do not make `EnglishCompiler` synchronous.
- **GUD-301**: Keep `FoundationModelsEnglishCompiler` injectable for unit tests that must not hit AFM.

# 4. Interfaces & Data Contracts

## GitLiveFacts

| Field | Type | Notes |
|---|---|---|
| `analysis` | `GitAnalysisContext` | cwd + optional branch + shared-by-name |
| `rebaseInProgress` | `Bool` | rebase-merge or rebase-apply directory exists |

HEAD parse: first line `ref: refs/heads/<name>` → `<name>`. Anything else → nil branch.

## HostAdapterInstallation.wired

Baked path prefix `/`, `isExecutableFile(baked)`, and `isExecutableFile(sibling rv-cli)`.

## EnglishCompileChain

`EnglishCompiler` with no stored AFM instance required beyond what `FoundationModelsEnglishCompiler` already does. Product fallback is this type, not ArgumentParser.

# 5. Acceptance Criteria

- **AC-101**: Given a temp git repo on `main`, when live `GatedEvaluate` peeks `git push --force-with-lease` with no refspec, then the Decision is deny `builtin.action` remote-shared-branch (hard deny bind), not `remoteBranchAsk`.
- **AC-102**: Given the same command with no `.git`, when live peek runs, then the Decision is `remoteBranchAsk` / mandatoryHuman, not unresolved-path.
- **AC-103**: Scan classify still does not read HEAD.
- **AC-201**: Given baked `rv` executable and non-exec sibling `rv-cli`, when inspect runs, then state is `.broken`; doctor and scan nudge agree.
- **AC-202**: Doctor no longer loads `HostAdapterResources` for the wired check.
- **AC-301**: Given AFM unavailable, when `rv policy draft --english` uses the canned fixture, then Fake compiles without a second `PolicyDraftRun.execute`.
- **AC-302**: `--save` plus AFM unavailable does not upsert twice.

# 5b. Tickets (task graph)

Independent. Frontier is T1, T2, T3 in parallel.

### T1 — GitLiveProbe at the evaluate door

- **depends-on**: none
- **exclusive-writes**:
  - `Sources/RVService/GitLiveProbe.swift` (new)
  - `Sources/RVService/GatedEvaluate.swift`
  - `Sources/RVService/GitRebaseProbe.swift`
  - `Tests/RVServiceTests/GitLiveProbeTests.swift` (new)
  - `Tests/RVServiceTests/GatedEvaluateGitSemanticsTests.swift`
  - `CONTEXT.md`
  - `docs/architecture/MODULES.md`
  - `spec/spec-architecture-functional-live-git-wired-english.md`
- **acceptance**: AC-101, AC-102, AC-103. `tools/gate.sh RVServiceTests` green.
- **review-hint**: 101–1499 (`GatedEvaluate.swift` is ~476 lines today)
- **specialist**: `swift-functional-architecture` + `swift-evaluate-parity`

### T2 — One wired law

- **depends-on**: none
- **exclusive-writes**:
  - `Sources/RVCLI/Setup/HostAdapterInstallation.swift`
  - `Sources/RVCLI/Doctor/DoctorRun.swift`
  - `Sources/RVCLI/Setup/ClaudeSettingsMerge.swift`
  - `Tests/RVCLITests/HostAdapterInstallationTests.swift`
  - `Tests/RVCLITests/DoctorTests.swift`
  - `Tests/RVCLITests/ScanNudgeTests.swift`
- **acceptance**: AC-201, AC-202. `tools/gate.sh RVCLITests` green.
- **review-hint**: 101–1499 (`HostAdapterInstallation.swift`)
- **specialist**: `swift-functional-architecture`

### T3 — English compile chain

- **depends-on**: none
- **exclusive-writes**:
  - `Sources/RVPolicy/EnglishCompileChain.swift` (new)
  - `Sources/RVCLI/Commands/PolicyDraftCommand.swift`
  - `Tests/RVPolicyTests/EnglishCompileChainTests.swift` (new)
  - `Tests/RVCLITests/PolicyDraftCommandTests.swift`
- **acceptance**: AC-301, AC-302. `tools/gate.sh RVPolicyTests RVCLITests` green.
- **review-hint**: 101–1499 (`PolicyDraftCommand.swift`)
- **specialist**: `swift-functional-architecture` + `swift-testing-pro`

# 6. Test Automation Strategy

- **Test Levels**: Swift Testing unit tests in the module that owns the change. Service tests use temp dirs, not live HOME.
- **Frameworks**: Swift Testing. No XCTest.
- **Test Data**: Temp git repos via `FileManager` in `RVServiceTests`. Adapter fixtures already in `RVCLITests`.
- **CI/CD**: `tools/gate.sh` on 6.3.3. Do not wipe `.build`.
- **Coverage**: The three AC pairs above. No new corpus rows (pack `--force` unchanged).
- **Performance**: Not in scope.

# 7. Rationale & Context

Filesystem already injects a live world. Git analysis already takes `GitAnalysisContext`. The live door never filled it. Pack regex already denies `--force`; `--force-with-lease` is the documented safer alternative and is the builtin wall / Ask split. Missing HEAD must not be treated like missing filesystem cwd (fail-closed unresolved).

“Wired” currently means two things. CONTEXT already says installation is derived once.

English product law already says AFM else Fake. The catch in ArgumentParser re-runs save.

# 8. Dependencies & External Integrations

### External Systems

- **EXT-001**: Git working copy on disk (read-only HEAD / gitdir). Not the `git` binary.

### Third-Party Services

- None. AFM is already in-process via Foundation Models when present.

### Infrastructure Dependencies

- **INF-001**: Swift 6.3.3 toolchain via `tools/swift-6.3.3`.

### Data Dependencies

- None.

### Technology Platform Dependencies

- **PLT-001**: macOS 26 / Linux aarch64/x86_64. Language mode 6.

### Compliance Dependencies

- **COM-001**: No command text in `os_log`. No live-HOME tests. No `RV_BYPASS`.

# 9. Examples & Edge Cases

```text
# T1 — live main, implicit force-with-lease
cwd = /tmp/repo (HEAD refs/heads/main)
command = git push --force-with-lease
→ deny builtin.action:remote-shared-branch (hard)

# T1 — live topic
HEAD refs/heads/topic
→ deny builtin.action:remote-branch-ask (mandatoryHuman)

# T1 — no gitdir
→ remote-branch-ask, not unresolved-path

# T1 — pack --force still pack
git push --force origin main
→ core.git:push-force-long

# T2
baked rv exec + rv-cli missing → inspect .broken
doctor .broken, scan nudge true if host in event set

# T3
AFM throws unavailable, english = canned fixture, --save
→ Fake preview, one upsert
```

# 10. Validation Criteria

- Exclusive-write paths respected.
- `tools/gate.sh` green for each ticket’s targets.
- Engine remains free of FileManager.
- Scan does not import RVService.
- No new SPM module.
- Reviewers use `swift-pr-review` (101–1499 bucket) unless a changed Swift file is ≤100 or ≥1500 LOC.

# 11. Related Specifications / Further Reading

- `CONTEXT.md` — evaluation door, Host adapter installation state, English compile
- `docs/architecture/MODULES.md`
- `docs/architecture/english-compile.md`
- `docs/dev/PARITY.md`
- `$TMPDIR/swift-functional-evolution-rv-20260915-041545.html`
- Prior FE `$TMPDIR/swift-functional-evolution-rv-20260915-040219.html` (466c1e6; same Strong set, not landed here)
