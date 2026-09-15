---
title: Functional evolution — GitAnalysisWorld, one wired law, English compile chain
version: 1.0
date_created: 2026-09-15
last_updated: 2026-09-15
owner: rv
tags: [architecture, functional-core, git, setup, english-compile]
---

# Introduction

Execute the three Strong candidates from `$TMPDIR/swift-functional-evolution-rv-20260915-041447.html` (HEAD `8ef53e4`, branch `worktree/brave-river-e180` / `main`).

1. **T1** — `GitAnalysisWorld` is `unprobed | probed(GitAnalysisContext)`. Engine door takes `gitProbe` after unwrap, parallel to `filesystemProbe`. Top recommendation.
2. **T2** — `GitLiveProbe` in RVService fills that world from HEAD. Depends on T1.
3. **T3** — Inspect `.wired` means the C hook can exec sibling `rv-cli`. Doctor and scan use the same value.
4. **T4** — English compile chain is a value (AFM else Fake); `PolicyDraftRun` compiles then optionally saves.

Do not execute C04 (setup file-op plans) or C05 (typed MachineConfig). Do not revive evaluation door, Policy gate, File tool, ScanClassify filesystem world, UnlockableDeny, GitPushForceConstraint, FilesystemAnalysisWorld, DenialLedgerRecord, HookWirePorts, HookRequest sum, leftover `EvaluateSession.evaluate`.

Audience: fresh-context implementer and reviewer subagents. Toolchain: Swift 6.3.3 (`tools/swift-6.3.3`), language mode 6, macOS 26. Gate: `tools/gate.sh`. Warm `.build`. Never `swift package clean`. After the first compile in a worktree, `git restore Package.resolved` unless this ticket owns dependency changes.

# 1. Purpose & Scope

## Purpose

Make three programs match the functional-core law already written in `docs/dev/SWIFT.md` and the filesystem world that landed in #214:

- Git facts are a world value, injected after unwrap. Engine never reads disk.
- Host adapter `.wired` means miss-path ready (sibling `rv-cli` executable).
- English compile fallback is a compiler value, not an ArgumentParser catch around compile+save.

## Audience

Implementers of rv using `tools/gate.sh` and `tools/swift-6.3.3`.

## In scope

- RVDomain `GitAnalysisWorld`.
- RVEngine door `workingDirectory` + `gitProbe`; `analyzeSemantics` / `applySemantics` / `applyGitSemantics` take the world.
- RVScan `ScanClassify` stays git `.unprobed`.
- RVService `GitLiveProbe` + `GatedEvaluate` wiring; share gitdir resolution with `GitRebaseProbe`.
- RVCLI inspect sibling `rv-cli`; doctor projection; scan nudge.
- RVPolicy/RVCLI English compile chain; `PolicyDraftRun` compile then save.

## Out of scope

- Scraping remotes, upstream tracking, or GitHub protected-branch APIs.
- Fail-closed unresolved-path when HEAD is missing.
- Folding `GitRebaseProbe.rebaseInProgress` into analysis (PolicyGate fact).
- Scan inventing HEAD.
- FileManager in RVDomain / RVEngine.
- File tool door changes.
- Presenting `rv-cli` as a CLI surface.
- Widening `FakeEnglishCompiler` beyond the canned gitPush fixture.
- Foundation Models in Domain/Engine.
- Setup file-op plan rewrite (C04).
- Typed `MachineConfig` (C05).
- New SPM modules, new dependencies, toolchain bumps.

## Assumptions

- Hexagonal graph in `MODULES.md` is law.
- Packs already deny `git push --force` (`core.git:push-force-long`). The live hole is pack-allow `git push --force-with-lease` with no refspec on a shared-branch checkout, plus typed `gitPush(branch:)` missing the implicit refspec.
- `FilesystemAnalysisWorld` / `filesystemProbe` stay as they are.
- `GitPushForceConstraint` stays as it is.
- No live-HOME tests.

# 2. Definitions

| Term | Meaning |
|---|---|
| Git analysis world | Whether git repository facts were injected. Unprobed: pack deny is the floor; implicit refspec is nil; `isSharedBranch` is not consulted. Probed: HEAD / shared-by-name facts may fill `GitAnalysisContext`. |
| Git live probe | RVService read of gitdir HEAD after unwrap. Returns `.probed`. Missing gitdir / detached unknown branch is still `.probed` with `currentBranch == nil`, not `.unprobed`. |
| Implicit refspec | `parsePush` uses `context.currentBranch` when the command has no refspec positional. |
| Shared-by-name | `main` and `master` (`ActionPolicyEngine.sharedBranchNames`). |
| Wired | Host adapter installation from which the C hook can exec sibling `rv-cli`. Not “baked `rv` exists.” |
| English compile chain | Try AFM `EnglishCompiler`; on `EnglishCompilerError.unavailable` use `FakeEnglishCompiler`. One compile. Save is a later step. |

# 3. Requirements, Constraints & Guidelines

## T1 — GitAnalysisWorld + Engine door

- **REQ-101**: Add in RVDomain (next to `FilesystemAnalysisWorld`):

  ```swift
  public enum GitAnalysisWorld: Sendable, Equatable {
      case unprobed
      case probed(GitAnalysisContext)
  }
  ```

  `GitAnalysisContext` keeps `workingDirectory`, `currentBranch`, `isSharedBranch`. `.empty` remains the empty probed payload. No world injected is `.unprobed`, not `.probed(.empty)`.

- **REQ-102**: `evaluateWithSemantics` replaces `gitContext: GitAnalysisContext = .empty` with:

  ```swift
  workingDirectory: WorkingDirectory? = nil,
  gitProbe: (UnwrapOutcome) -> GitAnalysisWorld = { _ in .unprobed },
  ```

  Unwrap uses `workingDirectory` (same as today’s `gitContext.workingDirectory`). After unwrap, `let gitWorld = gitProbe(unwrapped)`. Default probe is `.unprobed`.

- **REQ-103**: `analyzeSemantics` / `applySemantics` take `GitAnalysisWorld` (default `.unprobed`) instead of copying `gitContext.currentBranch` / `isSharedBranch` onto every unwrap. Unprobed analysis may pass `GitAnalysisContext(workingDirectory: unwrappedCwd)` into `analyzeGit` so `-C` / cwd still parse; it must not pass a caller `currentBranch` / `isSharedBranch`.

- **REQ-104**: `applyGitSemantics` takes `GitAnalysisWorld`. `ActionPolicyEngine.isSharedTarget` consults `context.repository.isSharedBranch` only for `.probed`. Unprobed uses only `resources.branchName` against shared-by-name. Do not treat unprobed as “not a shared branch.”

- **REQ-105**: `EvaluateSession.evaluateWithSemantics` matches the Engine door (`workingDirectory` + `gitProbe`).

- **REQ-106**: `ScanClassify` passes `workingDirectory: event.workingDirectory` and `gitProbe: { _ in .unprobed }`. It may keep lexical filesystem probing. It must not read HEAD.

- **REQ-107**: Existing Engine tests that inject `GitAnalysisContext(isSharedBranch: true)` pass `gitProbe: { _ in .probed(GitAnalysisContext(isSharedBranch: true)) }` (or equivalent). Product behavior of those tests stays.

- **CON-101**: No `FileManager` / `ProcessInfo` / `Date()` in Domain or Engine.
- **CON-102**: Do not change `FilesystemAnalysisWorld` or `GitPushForceConstraint`.
- **CON-103**: Do not add `GitLiveProbe` in this ticket (T2).
- **GUD-101**: Keep `GitAnalysisContext` as the probed payload. Do not invent a second branch struct.
- **PAT-101**: Copy the filesystem door: probe closure after unwrap, default unprobed.

## T2 — GitLiveProbe

- **REQ-201**: Add `Sources/RVService/GitLiveProbe.swift`. `world(unwrapped:fallbackCwd:)` (names may match existing probe style) returns `.probed(GitAnalysisContext)`.
- **REQ-202**: Resolve repo from unwrapped working directory, else `fallbackCwd`. Reuse `FilesystemLiveProbe.discoverRepositoryRoot`. Worktree / submodule `.git` file stops at that checkout (same as filesystem).
- **REQ-203**: Read HEAD. Attached branch → `currentBranch` is that name (no `refs/heads/` prefix). `isSharedBranch` is shared-by-name on that branch. Detached HEAD or missing HEAD file → `currentBranch == nil`, `isSharedBranch == false`, still `.probed`.
- **REQ-204**: Missing cwd, missing repo, unreadable gitdir → `.probed` with nil branch, not `.unprobed`, not a filesystem unresolved deny.
- **REQ-205**: `GatedEvaluate.evaluateWithSemantics` injects `gitProbe: { unwrapped in GitLiveProbe.world(...) }` and `workingDirectory: cwd`. Stop constructing `GitAnalysisContext(workingDirectory: cwd)` as the only git fact.
- **REQ-206**: Share gitdir resolution with `GitRebaseProbe` (extract helper; rebase-in-progress stays a PolicyGate boolean after evaluate).
- **CON-201**: Do not scrape remotes. Do not put FileManager in Engine. Do not probe in RVScan.
- **CON-202**: Do not change host deny JSON keys.
- **GUD-201**: Symbolic-ref `ref: refs/heads/<name>` is enough. Packed-refs optional; missing name is unknown branch.
- **PAT-201**: Mirror `FilesystemLiveProbe.context` → `.probed`.

## T3 — One wired law

- **REQ-301**: `HostAdapterInstallation.inspect` `.wired` requires sibling `rv-cli` executable next to the baked `rv` path (same rule as today’s `DoctorRun.isExecutableRvCli`). Missing or non-exec sibling is `.broken` with existing bytes.
- **REQ-302**: `DoctorRun.doctorHostState` for `.wired` returns `installation.state` without a second `HostAdapterResources.load`. Non-wired cases still return `installation.state`.
- **REQ-303**: `scanSetupNudgeRecommended` keeps `snapshot.state(for:) != .wired`. After REQ-301, a baked-`rv` tree without exec `rv-cli` nudges.
- **CON-301**: Do not fold File tool door into this ticket. Do not present `rv-cli` as a product CLI.
- **GUD-301**: Move `isExecutableRvCli` next to inspect (package helper). Doctor may call it only if still needed for a non-install path — prefer delete.
- **PAT-301**: One classifier. Projections only.

## T4 — English compile chain

- **REQ-401**: Add a small `EnglishCompileChain` (RVPolicy) that is `EnglishCompiler`: `compile` tries AFM (`FoundationModelsEnglishCompiler`), and on `EnglishCompilerError.unavailable` only, uses `FakeEnglishCompiler`. Other errors propagate. Cancellation propagates.
- **REQ-402**: `PolicyDraftCommand` constructs the chain once. It does not `catch EnglishCompilerError` and retry `PolicyDraftRun.execute`.
- **REQ-403**: `PolicyDraftRun.execute` compiles, then if `save && preview.allowedToSave` upserts. Compile failure never upserts. Write failure does not compile again.
- **CON-401**: Fake stays the canned gitPush fixture. Do not guess English. Foundation Models stay out of Domain/Engine.
- **GUD-401**: Tests inject `EnglishCompileChain(primary:unavailable, fallback:Fake)` or equivalent; do not require a live model.
- **PAT-401**: Chain is a value. Command maps HOME/flags/IO.

# 4. Interfaces & Data Contracts

```swift
public enum GitAnalysisWorld: Sendable, Equatable {
    case unprobed
    case probed(GitAnalysisContext)
}

public func evaluateWithSemantics<E: PatternEngine>(
    _ request: EvaluationRequest,
    packs: [PackSnapshot],
    secrets: SecretPathCatalog = .dayOne,
    safety: SafetyLevel = .normal,
    allowPaths: SecretAllowPathSet = .empty,
    home: String? = nil,
    patterns: E,
    compiled: CompiledPacks<E.Compiled>,
    workingDirectory: WorkingDirectory? = nil,
    gitProbe: (UnwrapOutcome) -> GitAnalysisWorld = { _ in .unprobed },
    filesystemProbe: (UnwrapOutcome) -> FilesystemAnalysisWorld = { _ in .unprobed },
    policy: EffectiveActionPolicy = .empty
) -> EvaluationResult

enum GitLiveProbe {
    static func world(
        unwrapped: UnwrapOutcome,
        fallbackCwd: WorkingDirectory?
    ) -> GitAnalysisWorld  // always .probed
}

struct EnglishCompileChain: EnglishCompiler {
    // AFM then Fake on unavailable
}
```

CONTEXT.md evaluation door: path I/O via `filesystemProbe`; git facts via `gitProbe` after unwrap; defaults unprobed; live `GatedEvaluate` injects both live probes. Scan git stays unprobed.

# 5. Acceptance Criteria

- **AC-101**: Default `evaluateWithSemantics` git probe is `.unprobed`. `git push --force-with-lease` (no refspec) with a typed `gitPush(force: .exactly(.forceWithLease), branch: "main")` does **not** match. Pack allow stays allow unless a name-based refspec is present.
- **AC-102**: `gitProbe: { _ in .probed(GitAnalysisContext(currentBranch: "main", isSharedBranch: true)) }` on `git push --force-with-lease` (no refspec) parses refspec `main` and builtin shared-branch hard-denies (`remote-shared-branch`). Typed allow cannot beat that wall.
- **AC-103**: `ScanClassify` of a pack-allow force-with-lease event does not read HEAD (no `GitLiveProbe` / `FileManager` in RVScan). Git world is unprobed.
- **AC-201**: Temp repo on `main`, live `GatedEvaluate.peek("git push --force-with-lease")` (no refspec) returns builtin `remote-shared-branch` (or equivalent `ActionPolicyEngine.Builtin.remoteSharedBranch`). Not `mandatoryHuman` / `remoteBranchAsk`.
- **AC-202**: Same peek with no `.git` directory does not add unresolved-path and does not invent `main`. Pack allow stays allow (landmine).
- **AC-203**: `GitRebaseProbe.rebaseInProgress` still works; gitdir helper is shared, not duplicated as two parsers with different symlink rules.
- **AC-301**: Inspect of baked executable `rv` plus non-executable sibling `rv-cli` is `.broken`, not `.wired`.
- **AC-302**: `doctor_nonExecutableRvCliNextToBakedRvIsBrokenNotWired` stays green without a second adapter parse in `doctorHostState`.
- **AC-303**: Scan nudge is true for a host whose inspect state is `.broken` for that reason.
- **AC-401**: Chain with AFM unavailable compiles `"never allow force-push to main"` to the Fake preview. Arbitrary English still refuses.
- **AC-402**: `PolicyDraftCommand` source has no `catch is EnglishCompilerError` around `PolicyDraftRun.execute`.
- **AC-403**: Save after compile: write failure does not invoke Fake. Compile refuse does not write `policy.toml`.

# 5b. Tickets (task graph)

| id | title | depends-on | exclusive-writes | acceptance | review-hint |
|---|---|---|---|---|---|
| T1 | GitAnalysisWorld + Engine gitProbe | none | `Sources/RVDomain/SemanticAnalysis.swift`, `Sources/RVDomain/ActionPolicyEngine.swift`, `Sources/RVEngine/EvaluateWithSemantics.swift`, `Sources/RVEngine/AnalyzeSemantics.swift`, `Sources/RVEngine/ApplySemantics.swift`, `Sources/RVEngine/ApplyGitSemantics.swift`, `Sources/RVEngine/AnalyzeGit.swift` (only if implicit refspec needs a world, prefer not), `Sources/RVService/EvaluateSession.swift`, `Sources/RVScan/Classify/ScanClassify.swift`, `CONTEXT.md`, `docs/architecture/MODULES.md` (git probe sentence only), `Tests/RVEngineTests/**` that pass `gitContext:`, `Tests/RVScanTests/**` as needed for unprobed git, `Tests/RVServiceTests/EvaluateSessionTests.swift` if the session door signature moves, `spec/spec-architecture-functional-git-world.md` | AC-101, AC-102, AC-103 | 101–1499 |
| T2 | GitLiveProbe at GatedEvaluate | T1 | `Sources/RVService/GitLiveProbe.swift` (new), `Sources/RVService/GitRebaseProbe.swift`, `Sources/RVService/GatedEvaluate.swift`, `Sources/RVService/FilesystemLiveProbe.swift` only if extracting a shared gitdir helper into an existing Service file — prefer GitLiveProbe owning the helper and GitRebaseProbe calling it, `Tests/RVServiceTests/GatedEvaluateGitSemanticsTests.swift`, `Tests/RVServiceTests/GitLiveProbeTests.swift` (new) | AC-201, AC-202, AC-203 | 101–1499 |
| T3 | One wired law | none | `Sources/RVCLI/Setup/HostAdapterInstallation.swift`, `Sources/RVCLI/Doctor/DoctorRun.swift`, `Sources/RVCLI/Commands/ScanCommand.swift` (nudge only if a comment/call must change; behavior should follow inspect), `Tests/RVCLITests/HostAdapterInstallationTests.swift`, `Tests/RVCLITests/DoctorTests.swift`, `Tests/RVCLITests/ScanNudgeTests.swift` | AC-301, AC-302, AC-303 | 101–1499 |
| T4 | English compile chain | none | `Sources/RVPolicy/EnglishCompileChain.swift` (new) or next to `FoundationModelsEnglishCompiler.swift` if a new file is refused, `Sources/RVPolicy/FoundationModelsEnglishCompiler.swift` (only if chain lives here — prefer new file), `Sources/RVCLI/Commands/PolicyDraftCommand.swift`, `Tests/RVPolicyTests/EnglishCompileChainTests.swift` (new), `Tests/RVCLITests/PolicyDraftCommandTests.swift` | AC-401, AC-402, AC-403 | 101–1499 |

T1, T3, T4 do not share exclusive-writes. Parallel. T2 starts from T1’s branch (`arch/<run>/T1`).

If a test file constructs `gitContext:` and was omitted above, T1 still owns it — grep `gitContext:` and include it rather than leaving the package unbuildable (exclusive-writes are a collision fence, not a compile set).

T2 must not edit Engine files; if the door is wrong, T1 is incomplete — fix T1, do not patch Engine from T2.

# 6. Test Automation Strategy

- **Test Levels**: Swift Testing unit in RVEngineTests, RVScanTests, RVServiceTests, RVCLITests, RVPolicyTests as listed.
- **Frameworks**: Swift Testing. No XCTest. No live HOME. Temp git repos for T2 only.
- **CI**: `tools/gate.sh RVEngineTests RVScanTests` (T1). T2: `RVServiceTests`. T3: `RVCLITests`. T4: `RVPolicyTests RVCLITests`.
- **Coverage**: unprobed implicit force-with-lease; probed injected HEAD; live temp `main` repo; missing gitdir; inspect sibling `rv-cli`; chain unavailable → Fake; no catch-retry in Command.

# 7. Rationale & Context

FilesystemAnalysisWorld (#214) made unprobed vs probed a compiler-checked world and moved path I/O to a probe after unwrap. Git still uses `GitAnalysisContext(workingDirectory: cwd)` with `isSharedBranch == false`, which `isSharedTarget` treats as “not shared.” A this-morning report proposed filling that struct before the door; that attaches hook-cwd HEAD after unwrap `env -C` and leaves scan looking probed. Probe-after-unwrap is the filesystem twin.

One wired law: doctor already knows miss path needs `rv-cli`; inspect and scan do not. Three surfaces, two meanings.

English compile: product law is AFM else Fake. Catching `EnglishCompilerError` around compile+save in ArgumentParser hides the chain from tests.

# 8. Dependencies & External Integrations

- **PLT-001**: Swift 6.3.3, language mode 6, macOS 26 / Linux aarch64/x86_64.
- **DAT-001**: Host deny JSON keys unchanged. policy.toml schema unchanged. blocks.jsonl unchanged.
- **COM-001**: No `RV_BYPASS`. No command text in `os_log`. No live-HOME tests. `rv-cli` is the on-disk operator sibling, not a CLI hero.

# 9. Examples & Edge Cases

```swift
// T1 unprobed — implicit refspec stays nil
evaluateWithSemantics(request, packs:…, patterns:…, compiled:…)
// gitProbe default .unprobed

// T1 probed injection
evaluateWithSemantics(
    request, packs:…, patterns:…, compiled:…,
    gitProbe: { _ in .probed(GitAnalysisContext(currentBranch: "main", isSharedBranch: true)) }
)

// T2 live
GitLiveProbe.world(unwrapped:unwrapped, fallbackCwd: cwd) // .probed

// T2 missing gitdir
// .probed(currentBranch: nil, isSharedBranch: false) — pack allow for force-with-lease

// T3
// baked rv exec + rv-cli 0644 → .broken

// T4
try await EnglishCompileChain().compile("never allow force-push to main")
// AFM unavailable → Fake preview
```

Detached HEAD: probed, nil branch, force-with-lease without refspec stays Ask (`remoteBranchAsk`), not shared-branch hard deny.

`git push --force origin main`: still pack deny `push-force-long`; world does not weaken a pack floor.

# 10. Validation Criteria

- `tools/gate.sh` filters named in §6 are green on each ticket branch.
- AC-101…AC-403 as listed.
- `git grep gitContext:` in Engine/Service/Scan production sources is empty after T1 (tests may still mention the old name in comments only if updated).
- `PolicyDraftCommand.swift` has no `catch is EnglishCompilerError`.
- `DoctorRun.doctorHostState` does not call `HostAdapterResources.load`.

# 11. Related Specifications / Further Reading

- `spec/spec-architecture-type-system-remaining-holes.md` (FilesystemAnalysisWorld)
- `docs/architecture/MODULES.md`
- `docs/architecture/english-compile.md`
- `CONTEXT.md` (evaluation door, Host adapter installation state)
- HTML: `$TMPDIR/swift-functional-evolution-rv-20260915-041447.html`
