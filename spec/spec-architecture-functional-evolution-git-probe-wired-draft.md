---
title: Functional evolution — GitLiveProbe, one wired law, English compile chain
version: 1.0
date_created: 2026-09-15
last_updated: 2026-09-15
owner: rv
tags:
  - architecture
  - functional-core
  - git
  - setup
  - english-compile
---

# Introduction

Three Strong cuts from the 2026-09-15 functional-evolution review (HTML: `swift-functional-evolution-rv-20260915-040219.html`, HEAD `466c1e6`).

1. **FE-T1:** Live evaluate injects git repository facts (`GitLiveProbe`) the way it already injects filesystem facts. Scan stays unprobed.
2. **FE-T2:** `HostAdapterInstallation.wired` means the C hook can exec sibling `rv-cli`. Doctor and scan stop using a second classifier.
3. **FE-T3:** Product English-compile fallback is a compiler chain value. Compile then save. The ParsableCommand does not catch-retry `execute`.

Do not reopen the evaluation door, Policy gate, File tool, ScanClassify probe state, UnlockableDeny, GitPushForceConstraint, FilesystemAnalysisWorld, or DenialLedgerRecord.

# 1. Purpose & Scope

## Purpose

Finish the functional-core / imperative-shell split at three leftover seams: git facts at the live door, one installation health value, and English compile fallback.

## Audience

Implementers of rv (Swift 6.3.3, language mode 6, macOS 26 Apple Silicon and Linux aarch64/x86_64) using `tools/gate.sh` and `tools/swift-6.3.3`.

## In scope

- `GitLiveProbe` in RVService filling `GitAnalysisContext.currentBranch` from HEAD.
- `GatedEvaluate` passing that context into `evaluateWithSemantics`.
- Sharing gitdir resolution with `GitRebaseProbe` if that shrinks duplication without changing rebase behavior.
- Moving sibling `rv-cli` executability into `HostAdapterInstallation.inspect`.
- Thinning `DoctorRun.doctorHostState` to project `installation.state`.
- `EnglishCompileChain` (AFM then Fake) and splitting compile from persist in `PolicyDraftRun`.

## Out of scope

- Scraping remotes / upstream / GitHub protected branches for `isSharedBranch`.
- Fail-closed deny when gitdir or HEAD is missing (unknown branch, not unresolved-path).
- Changing Scan classify to probe git (offline/unprobed stays cwd-only).
- Setup/uninstall file-op plan rewrite (C04).
- Typed `MachineConfig` for `config.json` (C05).
- `EvaluateSession.evaluate` pack-only door.
- `PolicyPredicate.gitPush` optional-force constraint (PR #213).
- FilesystemAnalysisWorld memberwise `probe:` drop (PR #214).
- New SPM modules, new dependencies, toolchain bumps.
- Live-HOME tests. Live Apple Intelligence in tests.

## Assumptions

- Pack `core.git:push-force-long` already denies `--force`. The live hole is `--force-with-lease` (pack allow) plus implicit refspec / HEAD name.
- `ActionPolicyEngine.sharedBranchNames` is `{main, master}`. Filling `currentBranch` is enough for those names. Do not invent a second shared-branch list.
- Product law: `rv policy draft` uses Apple Intelligence when available and `FakeEnglishCompiler` when it is not.
- Hexagonal graph in `docs/architecture/MODULES.md` is law. Engine stays free of `FileManager`.

# 2. Definitions

| Term | Meaning |
|---|---|
| **GitLiveProbe** | RVService read of gitdir + HEAD → `GitAnalysisContext`. No Engine I/O. |
| **Unknown branch** | Missing cwd, missing gitdir, detached HEAD, or unreadable HEAD. `currentBranch == nil`. Not a deny. |
| **Wired** | Owned adapter is current and sibling `rv-cli` next to the baked `rv` path is executable. Miss path can exec the operator. |
| **EnglishCompileChain** | `EnglishCompiler` that tries AFM then Fake on `EnglishCompilerError.unavailable`. |
| **Unprobed git** | Scan classify: `GitAnalysisContext(workingDirectory: event.workingDirectory)` only. |

# 3. Requirements, Constraints & Guidelines

## GitLiveProbe (FE-T1)

- **REQ-001**: Add `GitLiveProbe` in RVService. `context(cwd: WorkingDirectory?) -> GitAnalysisContext` sets `workingDirectory` to `cwd` and `currentBranch` from the current checkout’s HEAD name when it is a named branch.
- **REQ-002**: Named branch is the suffix of `ref: refs/heads/<name>` in `HEAD`. Detached SHA HEAD is unknown branch.
- **REQ-003**: Reuse existing repo-root / gitdir discovery (`FilesystemLiveProbe.discoverRepositoryRoot` and `GitRebaseProbe` gitdir file parse). Worktree / submodule `.git` file stops at that checkout.
- **REQ-004**: `isSharedBranch` may be `true` only when `currentBranch` is `main` or `master` (same names as `ActionPolicyEngine`). Do not set it from remotes. Prefer leaving `isSharedBranch` false and relying on name-based `resources.branchName` once `currentBranch` fills the implicit refspec — either is acceptable if tests in REQ-006 pass.
- **REQ-005**: `GatedEvaluate`’s engine call uses `GitLiveProbe.context(cwd: cwd)` instead of `GitAnalysisContext(workingDirectory: cwd)`.
- **REQ-006**: In a temp git repo on `main`, live `GatedEvaluate.peek` of `git push --force-with-lease` (no refspec) denies `builtin.action` remote shared-branch (same rule id as `ActionPolicyEngine.Builtin.remoteSharedBranch`). The same command with `cwd` pointing at a directory with no gitdir does not invent `main`.
- **REQ-007**: `ScanClassify` still builds `GitAnalysisContext(workingDirectory: event.workingDirectory)` only. Do not call `GitLiveProbe` from RVScan (RVScan must not import RVService).
- **CON-001**: No `FileManager` / `Process` in RVDomain or RVEngine.
- **CON-002**: Missing gitdir is not `builtin.action:unresolved-path` and not unwrap-limited.
- **GUD-001**: Keep `GitRebaseProbe` behavior identical. Share private gitdir helpers if both files stay in RVService.
- **PAT-001**: Mirror `FilesystemLiveProbe`: enum of static functions, tests in `RVServiceTests` with a temp repo, never live HOME.

## One wired law (FE-T2)

- **REQ-008**: `HostAdapterInstallation.inspect` returns `.wired` only when baked `rv` is an executable absolute path **and** sibling `rv-cli` next to that path is executable. Otherwise a current-looking adapter is `.broken`.
- **REQ-009**: `DoctorRun.doctorHostState` for `.wired` returns `.wired` without re-loading adapter templates or calling `ClaudeSettingsMerge.inspectionState` / `bakedRvPath` again. Non-wired cases still map `installation.state`.
- **REQ-010**: Scan nudge (`scanSetupNudgeRecommended`) keeps using `snapshot.state(for:) != .wired`. After REQ-008 that sees miss-path unreadiness.
- **REQ-011**: Existing doctor test `doctor_nonExecutableRvCliNextToBakedRvIsBrokenNotWired` stays green. Add an inspect-level test that the snapshot itself is `.broken` when `rv-cli` is non-executable.
- **CON-003**: Do not change File tool door classification (`fileTools(for:)`).
- **CON-004**: Do not rewrite `SetupRun.interpret` or uninstall in this ticket.
- **GUD-002**: Setup may now report broken where it previously reported wired for a missing operator sibling. Update setup tests if they asserted wired without `rv-cli`.

## English compile chain (FE-T3)

- **REQ-012**: Add a public or package `EnglishCompiler` in RVPolicy (name `EnglishCompileChain` or equivalent) that calls `FoundationModelsEnglishCompiler` and on `EnglishCompilerError` (unavailable) calls `FakeEnglishCompiler`. Other errors propagate.
- **REQ-013**: `PolicyDraftCommand.run` constructs that chain once and calls `PolicyDraftRun.execute` once. It must not catch `EnglishCompilerError` to retry `execute`.
- **REQ-014**: `PolicyDraftRun.execute` compiles first. Persist (`TypedRuleStore` upsert) runs only after a `.preview` with `save && allowedToSave`. A store error must not fall through to Fake.
- **REQ-015**: Fixture English `"never allow force-push to main"` still previews/saves the canned gitPush deny when the primary compiler is unavailable. `"be careful in prod"` still refuses. Tests inject compilers; they never call live Foundation Models.
- **CON-005**: Foundation Models stay out of RVDomain / RVEngine. Fake stays in Domain.
- **CON-006**: Do not change `EnglishCompiler` to synchronous `Result`.
- **GUD-003**: Keep robot/pretty render as they are.

## Shared

- **CON-007**: Swift 6.3.3, language mode 6, `tools/gate.sh` for touched test targets. Do not wipe `.build`.
- **CON-008**: No `try!` / IUO on production paths. No `isDenied`. Value types in Domain/Engine/Packs/Presentation. `class` only at XPC/`NSObject`.
- **CON-009**: Fixtures stay under `Tests/`. No live-HOME tests.
- **CON-010**: One user command `rv`. Do not present `rv-cli` as a CLI.
- **GUD-004**: TDD: failing test, then minimal production change.
- **GUD-005**: Small diffs. Do not restyle unrelated files.

# 4. Interfaces & Data Contracts

## GitLiveProbe

```swift
enum GitLiveProbe {
    static func context(cwd: WorkingDirectory?) -> GitAnalysisContext
}
```

`GitAnalysisContext` stays the Domain value. No new Engine type.

## Wired

`HostAdapterInstallation` cases unchanged. `.wired` meaning changes per REQ-008.

## EnglishCompileChain

```swift
struct EnglishCompileChain: EnglishCompiler {
    func compile(_ english: String) async throws -> EnglishCompileResult
}
```

Primary and fallback are injectable for tests.

# 5. Acceptance Criteria

- **AC-001**: Temp repo, branch `main`, `GatedEvaluate.peek("git push --force-with-lease")` → deny `ActionPolicyEngine.Builtin.remoteSharedBranch`.
- **AC-002**: Same command, cwd with no `.git` → does not deny that builtin rule (no invented branch). Pack/other rules unchanged.
- **AC-003**: `ScanClassify` source still has no `GitLiveProbe` / `FileManager` HEAD read.
- **AC-004**: `tools/gate.sh RVServiceTests` green after FE-T1.
- **AC-005**: Inspect snapshot `.broken` when baked `rv` is executable and sibling `rv-cli` is not.
- **AC-006**: `DoctorRun` does not call `HostAdapterResources.load` or `ClaudeSettingsMerge.inspectionState` inside `doctorHostState` for the wired path.
- **AC-007**: `tools/gate.sh RVCLITests` green after FE-T2 and after FE-T3.
- **AC-008**: `PolicyDraftCommand.run` has a single `PolicyDraftRun.execute` call.
- **AC-009**: Chain unavailable → Fake fixture English still compiles; store errors do not invoke Fake.

# 5b. Tickets (task graph)

| id | title | depends-on | exclusive-writes | acceptance | review-hint | specialist |
|---|---|---|---|---|---|---|
| FE-T1 | GitLiveProbe at GatedEvaluate | none | `Sources/RVService/GitLiveProbe.swift` (new), `Sources/RVService/GitRebaseProbe.swift`, `Sources/RVService/GatedEvaluate.swift`, `Sources/RVService/FilesystemLiveProbe.swift` (only if extracting a shared gitdir helper), `Tests/RVServiceTests/GitLiveProbeTests.swift` (new), `Tests/RVServiceTests/GatedEvaluateGitSemanticsTests.swift` | AC-001, AC-002, AC-003, AC-004 | 101–1499 | swift-functional-architecture, swift-evaluate-parity |
| FE-T2 | One wired law (sibling rv-cli in inspect) | none | `Sources/RVCLI/Setup/HostAdapterInstallation.swift`, `Sources/RVCLI/Doctor/DoctorRun.swift`, `Tests/RVCLITests/DoctorTests.swift`, `Tests/RVCLITests/SetupTests.swift` (only if wired assertions break), `Tests/RVCLITests/HostAdapterInstallationTests.swift` (create if missing) | AC-005, AC-006, AC-007 (this ticket) | 101–1499 | swiftify-codebase-architecture, swift-functional-architecture |
| FE-T3 | English compile chain; compile then save | none | `Sources/RVPolicy/EnglishCompileChain.swift` (new) or `Sources/RVPolicy/FoundationModelsEnglishCompiler.swift`, `Sources/RVCLI/Commands/PolicyDraftCommand.swift`, `Tests/RVPolicyTests/EnglishCompileChainTests.swift` (new) and/or `Tests/RVCLITests/PolicyDraftCommandTests.swift` | AC-007 (this ticket), AC-008, AC-009 | 101–1499 | swift-functional-architecture, swift-testing-pro |

Independent tickets. Parallel. Do not touch each other’s exclusive writes. Each PR may add a copy of this spec file if the base branch does not already contain it.

# 6. Test Automation Strategy

- **Test Levels**: Swift Testing unit tests in the module that owns the behavior. Decisions that need a git checkout are proven in `RVServiceTests` with a temp directory, not RVCLI TTY tests.
- **Frameworks**: Swift Testing. No XCTest.
- **Test Data**: temp `FileManager` directories; `git init` + `symbolic-ref` or write `.git/HEAD`. Never `$HOME`.
- **Gate**: `tools/gate.sh RVServiceTests` (T1), `tools/gate.sh RVCLITests` (T2, T3), plus `tools/gate.sh RVPolicyTests` if T3 adds Policy tests.
- **Coverage**: the acceptance tests above. Do not add corpus rows.

# 7. Rationale & Context

Filesystem already has a live probe. Git analysis context already has `currentBranch`, and `parsePush` already uses it as the implicit refspec. The live door passed cwd only, so `git push --force-with-lease` on `main` without a refspec could not hit the shared-branch wall. That is ambient state, not a missing type.

Doctor re-parsed adapter bytes to require sibling `rv-cli` after inspect had already said wired. Scan nudge used the weaker meaning. One installation value is the deep-module move.

English compile fallback lived in a `catch` around compile+save. Product law belongs in a compiler value.

# 8. Dependencies & External Integrations

### External Systems
- **EXT-001**: Local git checkout (`.git` / gitdir file). Read-only.

### Third-Party Services
- None. AFM stays behind existing `#if canImport(FoundationModels)`.

### Infrastructure Dependencies
- **INF-001**: Swift 6.3.3, `tools/gate.sh`, warm `.build`.

### Data Dependencies
- None.

### Technology Platform Dependencies
- **PLT-001**: macOS 26 / Linux as in `Package.swift`. No deployment-target bump.

### Compliance Dependencies
- **COM-001**: No command text in `os_log`. No live-HOME tests.

# 9. Examples & Edge Cases

```text
# FE-T1
tempRepo/.git/HEAD = "ref: refs/heads/main"
GatedEvaluate.peek("git push --force-with-lease")
→ deny builtin.action remoteSharedBranch

tempDir/ (no .git)
GatedEvaluate.peek("git push --force-with-lease")
→ not that builtin deny

HEAD = "abc123..." (detached)
→ currentBranch nil

# FE-T2
baked rv executable, rv-cli mode 0644
→ HostAdapterInstallation.broken
→ doctor grok=broken, scan nudge true if that host produced events

# FE-T3
EnglishCompileChain, AFM throws .unavailable
compile("never allow force-push to main") → preview canned deny
compile("be careful in prod") → refuse uncompilable
```

# 10. Validation Criteria

- All AC-* for the ticket.
- `tools/gate.sh` for the ticket’s test target.
- No new `FileManager` in `Sources/RVEngine` or `Sources/RVDomain`.
- `git grep GitLiveProbe Sources/RVScan` is empty after T1.

# 11. Related Specifications / Further Reading

- `docs/architecture/MODULES.md`
- `docs/architecture/english-compile.md`
- `docs/dev/SWIFT.md`
- `spec/spec-architecture-functional-core-depth.md` (landed; do not reopen)
- HTML: `/var/folders/ns/xmz0zmpj7p148vdgr4bwzp8h0000gn/T/swift-functional-evolution-rv-20260915-040219.html`
