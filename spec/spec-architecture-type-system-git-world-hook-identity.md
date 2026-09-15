---
title: Type-system remaining holes — Git branch world, HookRequest sum, approval identity, push vs delete
version: 1.0
date_created: 2026-09-15
last_updated: 2026-09-15
owner: rv
tags: [architecture, type-system, git, hooks, pending]
---

# Introduction

Execute the four Strong candidates from `$TMPDIR/swift-type-system-review-rv-20260915-041722.html` (HEAD `8ef53e4`).

1. **T1** — Git branch/sharedness is a world (`unprobed` | `probed`), not `isSharedBranch: Bool = false`. Top recommendation.
2. **T3** — `HookRequest` is a closed invocation (shell vs file). Independent of T1.
3. **T4** — `ApprovalIdentity` is `HookHost` + `SessionID`. Independent of T1/T3.
4. **T2** — `GitAction.push` is not a remote delete. Depends on T1 (`ActionPolicyEngine.swift`).

Do not implement GitLiveProbe I/O (reading `HEAD` / upstream). Do not revive ProposedAction IR (OPE-156). Do not add `Decision.ask`. Do not change host deny JSON keys. Do not unify `PacksConfig.enabled: [String]`. Do not move `HomeDirectory` into Domain. Do not collapse HostCodec into an enum.

Audience: fresh-context implementer and reviewer subagents. Toolchain: Swift 6.3.3 (`tools/swift-6.3.3`), language mode 6, macOS 26. Gate: `tools/gate.sh`. Warm `.build`. Never `swift package clean`. After the first compile in a worktree, `git restore Package.resolved` unless this ticket owns dependency changes.

# 1. Purpose & Scope

Make four illegal programs unrepresentable:

- `GitAnalysisContext(workingDirectory: cwd)` meaning the branch is not shared.
- `HookRequest(command: "", file: file, hostAsk: .spend)` — file+spend, or empty shell as a file event.
- `AgentIdentity(rawValue: "not-a-host")` and `SessionIdentity(rawValue: "")` as a pending identity.
- `PolicyMatch.matches(.gitPush(...), action: .push(..., delete: true))` as a typed gitPush hit.

## In scope

- RVDomain Git analysis context / review sharedness.
- RVEngine analyze/apply/evaluate door Git context plumbing.
- RVService `GatedEvaluate` live Git context.
- RVScan `ScanClassify` Git context.
- RVHooks `HookRequest` / codecs / `hookBody`.
- RVDomain pending identity types; RVService HookDoor mint; RVIPC pending list projection.
- RVDomain `GitAction.push` vs remote-ref delete; `PolicyMatch`; analyzer; pin reconstruction; delete extra `gitAction:` parameter on `ActionPolicyEngine.evaluate`.

## Out of scope

- GitLiveProbe (filesystem-style live git I/O).
- `GitBranchConstraint` / `GitRef` newtype on `PolicyPredicate.gitPush(branch:)`.
- `AllowOnceUnlockCode` moved to Domain (follow-up).
- `FilesystemTarget.scope` ∥ `protectedMatch`.
- Linux `ServiceTransport`.
- English-compile new predicates.
- C `rv` hook. Host adapter templates. Analytics `Any`.

# 2. Definitions

| Term | Meaning |
|---|---|
| Git branch world | Whether current branch / sharedness was probed. Unprobed: hook cwd may be known; sharedness is unknown. Probed: caller supplied current branch and sharedness. |
| Unprobed Git | Live hook and session-scan today. Name denylist on explicit `main`/`master` still runs. `isSharedBranch == false` is not a fact. |
| Probed Git | Tests and a future live probe. `isShared: true` is the shared-branch wall. |
| Hook invocation | Post-decode closed sum: shell command (optional spend intent) or file-tool action. Skip stays on `HookDecodeOutcome`. |
| Approval identity | Who may resume a pending Ask. v1 is always a `HookHost` plus nonempty `SessionID`. |

# 3. Requirements, Constraints & Guidelines

## T1 — Git branch world (top)

- **REQ-101**: In `Sources/RVDomain/SemanticAnalysis.swift` replace independent `currentBranch: String?` + `isSharedBranch: Bool = false` with:

  ```swift
  public enum GitBranchWorld: Sendable, Equatable {
      case unprobed
      case probed(currentBranch: String?, isShared: Bool)
  }

  public struct GitAnalysisContext: Sendable, Equatable {
      public var workingDirectory: WorkingDirectory?
      public var branchWorld: GitBranchWorld
  }
  ```

  `GitAnalysisContext.empty` is `{ workingDirectory: nil, branchWorld: .unprobed }`.
  `GitAnalysisContext(workingDirectory: cwd)` (no branch world) is unprobed cwd — **not** `isShared: false`.
  There is no default `isSharedBranch: Bool = false`.

- **REQ-102**: `GitAnalysisContext.reviewContext` maps:
  - `.unprobed` → `GitSharedness.unknown`
  - `.probed(_, isShared: true)` → `.shared`
  - `.probed(_, isShared: false)` → `.notShared`

- **REQ-103**: In `RepositoryReviewContext` replace `isSharedBranch: Bool = false` with:

  ```swift
  public enum GitSharedness: Sendable, Equatable, Codable {
      case unknown
      case notShared
      case shared
  }
  ```

  Codable: missing key decodes as `.unknown`, never as not-shared. Shadow-review prompt text uses the enum, not a Bool.

- **REQ-104**: `ActionPolicyEngine.isSharedTarget`:
  - `.shared` → true (builtin remote-shared-branch wall).
  - `.notShared` and `.unknown` → existing name denylist on `resources.branchName` only (`main` / `master`).
  - `.unknown` must **not** take a “not shared” arm.

- **REQ-105**: Live door (`GatedEvaluate`) and `ScanClassify` pass `GitAnalysisContext(workingDirectory: cwd, branchWorld: .unprobed)` (cwd nil → still unprobed). They must not pass `isShared: false`.

- **REQ-106**: `AnalyzeSemantics` must copy `branchWorld` through when rebuilding context with unwrapped cwd. Do not flatten to `isSharedBranch: gitContext.isSharedBranch`.

- **REQ-107**: Tests that currently pass `GitAnalysisContext(isSharedBranch: true)` become `.probed(currentBranch: …, isShared: true)`. Tests that pass `RepositoryReviewContext(isSharedBranch: false)` as “private repo” become `.notShared`. Tests that meant “no git facts” use `.unknown` / unprobed.

- **REQ-108**: A compile-or-behavior test proves `GitAnalysisContext(workingDirectory: cwd)` does not inhabit sharedness-false. `git push --force origin HEAD` with unprobed context stays **not** `builtin.action:remote-shared-branch-mutation` (denylist miss). `git push --force origin main` still hits the denylist. `GitAnalysisContext(branchWorld: .probed(currentBranch: "main", isShared: true))` still hard-denies force-push as shared.

- **CON-101**: No `Context<Probed>` phantom. No GitLiveProbe I/O. No generics. Cwd stays on `GitAnalysisContext` so unwrap / `ActionScope` keep hook cwd.
- **CON-102**: Do not edit T3/T4 exclusive files. Do not split `GitAction.push` in this ticket.
- **GUD-101**: First failing tests: unprobed constructor is not shared; probed shared still walls. Then change the type.

## T2 — GitAction.push vs deleteRemoteRef (depends on T1)

- **REQ-201**: Replace `GitAction.push(remote:refspec:force:delete:)` with:

  ```swift
  case push(remote: String?, refspec: String?, force: GitPushForce)
  case deleteRemoteRef(remote: String?, refspec: String?)
  ```

  AnalyzeGit: `--delete` / `-d` / `:refspec` → `.deleteRemoteRef`. Ordinary push (including `--force`) → `.push`. Effect scope for delete remote ref stays `.remote`. Effects: delete remote ref keeps `.remoteSharedBranchMutation` (today’s `delete: true` arm).

- **REQ-202**: `PolicyMatch.matchesGitPush` matches only `.push`. Delete the `delete == false` Bool guard.

- **REQ-203**: `RulePinning.gitPushAction` / `gitPushPredicate` reconstruct from analyzed `GitAction.push` (force taken from the action, including `.forceWithLease`). Stop hard-coding `GitPushForce.force` and `delete: false`. Do not pin a delete-remote as gitPush.

- **REQ-204**: Remove `gitAction: GitAction? = nil` from `ActionPolicyEngine.evaluate(action:context:policy:gitAction:)`. Typed rules and the builtin wall must see the same operation. `applyGitSemantics` already has `GitAction`; pass it only into `typedRestriction` / match, not as a second disagreeing argument beside a `ProposedAction` built from a different action.

- **REQ-205**: Tests: `git push origin :topic` does not match `PolicyPredicate.gitPush`. `git push --force-with-lease origin feature` pins `.exactly(.forceWithLease)`, not `.force`. Existing force-push explain strings still work.

- **CON-201**: No new English-compile predicate for delete. W1 remains gitPush only.
- **CON-202**: Exclusive writes below. Must not edit T1-only files except `ActionPolicyEngine.swift` (this ticket owns it after T1 merges).

## T3 — HookRequest closed invocation

- **REQ-301**: In `Sources/RVHooks/HostCodec.swift`:

  ```swift
  public enum HookInvocation: Equatable, Sendable {
      case shell(command: ShellCommand, ask: HostAskHookIntent?)
      case file(FileToolAction)
  }

  public struct HookRequest: Equatable, Sendable {
      public var host: HookHost
      public var cwd: WorkingDirectory?
      public var session: SessionID?
      public var invocation: HookInvocation
  }
  ```

  No `command: ShellCommand` plus optional `file`. No empty `ShellCommand(rawValue: "")` for file events. `hostAsk` exists only on `.shell`.

- **REQ-302**: Shell-only codecs (Pi, OpenCode, OpenClaw, Hermes, Codex) construct `.shell(command:ask: nil)` (Claude may set ask). File codecs (Grok, Claude, Cursor) construct `.file` with no command and no ask.

- **REQ-303**: `hookBody` switches on `invocation`. File path: `hookFileBody`. Shell + `ask == .spend`: spend. Else evaluate shell. File+spend does not compile.

- **REQ-304**: Default `proposedAction(from:)` is shell-only for `.shell`. File requests must not go through the empty-command shell fingerprint.

- **REQ-305**: File-tool deny voice must not call `hostDenyLine(command: ShellCommand(rawValue: ""))`. Use the deny reason / rule without pretending a shell command existed (keep host JSON keys unchanged). Empty `FileToolPath` still fail-closes as malformed.

- **REQ-306**: Tests: constructing a request with both a file and spend does not compile. Claude file decode has no ask. Empty command without file is malformed, not a request.

- **CON-301**: Skip stays `HookDecodeOutcome.foreign` / `.malformed`. Do not add `.skip` on `HookRequest`. Do not change HostCodec into an enum of hosts. Do not edit HookDoor identity construction (T4).
- **GUD-301**: Keep `HookRequest` as the wire-facing struct so `recordHostAsk` signatures stay `HookRequest`.

## T4 — Approval identity is HookHost + SessionID

- **REQ-401**: `ApprovalIdentity.agent` is `HookHost`. Delete unconstrained `AgentIdentity` or make it uninhabited in production (prefer delete + fix tests).
- **REQ-402**: `ApprovalIdentity.session` is `SessionID`. Delete unconstrained `SessionIdentity` (or type-alias only if Codable keys require the old name — prefer `SessionID`). Empty session does not compile.
- **REQ-403**: `HookDoor.recordPending` / `clearPending` pass `request.host` and `request.session` without `rawValue` round-trip.
- **REQ-404**: `PendingIPC.item(from:)` uses `record.identity.agent` as `HookHost`. Delete `HookHost(rawValue:)` + drop. Unknown agent on durable decode fails (same spirit as ledger host T2).
- **REQ-405**: `PendingApprovalLedger.validate` no longer checks empty agent/session strings for identity; the types forbid them. Keep other validate rules.
- **REQ-406**: Tests that used `AgentIdentity(rawValue: "agent-1")` use `HookHost.pi` (or another real host). The `not-a-host` omit test is replaced by a decode-failure test or deleted as unrepresentable.

- **CON-401**: Do not invent `enum AgentIdentity { case hook; case other }`. v1 is hosts only.
- **CON-402**: Do not change `HookRequest` invocation shape (T3). Identity fields stay `host` / `session` on the request struct.

# 4. Interfaces & Data Contracts

## GitAnalysisContext (T1)

Callers:

| Caller | Construction |
|---|---|
| `GatedEvaluate` live door | `GitAnalysisContext(workingDirectory: cwd, branchWorld: .unprobed)` |
| `ScanClassify` | same, event cwd |
| Shared-branch tests | `.probed(currentBranch: "main", isShared: true)` |
| `AnalyzeGit` implicit refspec tests | `.probed(currentBranch: "topic", isShared: false)` or unprobed + current branch only if you keep currentBranch on probed |

`evaluateWithSemantics(gitContext:)` stays `GitAnalysisContext` (cwd + world). Do not wrap the whole struct in an extra enum if that would drop hook cwd.

## HookRequest (T3)

`HookDecodeOutcome.request(HookRequest)` unchanged as a case. Envelope JSON unchanged.

## Pending Codable (T4)

`ApprovalIdentity` JSON: `agent` encodes `HookHost` raw value (`pi`, `grok`, …). `session` encodes nonempty string. Existing rows with valid hosts still decode. Rows with `"not-a-host"` fail decode.

## GitAction Codable (T2)

New case `deleteRemoteRef`. Existing fixtures with `delete: true` on push must migrate. Host JSON unchanged.

# 5. Acceptance Criteria

- **AC-101**: Given live `GatedEvaluate` Git context, when evaluating `git push --force origin HEAD`, then the result is not `builtin.action:remote-shared-branch-mutation` solely from defaulted not-shared. Given `.probed(..., isShared: true)`, when the same command, then the shared-branch wall still fires.
- **AC-102**: `GitAnalysisContext(isSharedBranch: true)` does not compile.
- **AC-201**: `PolicyMatch.matches(.gitPush(force: .any, branch: nil), action: .deleteRemoteRef(...))` is false. There is no `delete:` on `.push`.
- **AC-202**: Pin of a force-with-lease push is `.exactly(.forceWithLease)`.
- **AC-301**: File-tool decode cannot carry `HostAskHookIntent`. `hookBody` is an exhaustive switch on `HookInvocation`.
- **AC-302**: `HookRequest(..., command: "", file: file)` does not compile.
- **AC-401**: `ApprovalIdentity(session: SessionID?, agent: String)` does not compile. `HookDoor` has no `AgentIdentity(rawValue: request.host.rawValue)`.
- **AC-402**: `tools/gate.sh` green for the ticket’s test filter. No `swift package clean`.

# 5b. Tickets (task graph)

| id | title | depends-on | exclusive-writes | acceptance | review-hint |
|---|---|---|---|---|---|
| T1 | GitBranchWorld unprobed or probed | none | `spec/spec-architecture-type-system-git-world-hook-identity.md`; `Sources/RVDomain/SemanticAnalysis.swift`; `Sources/RVDomain/ActionReviewer.swift`; `Sources/RVDomain/ActionPolicyEngine.swift`; `Sources/RVDomain/ReviewSanitizer.swift`; `Sources/RVEngine/AnalyzeSemantics.swift`; `Sources/RVEngine/ApplyGitSemantics.swift`; `Sources/RVEngine/ApplySemantics.swift`; `Sources/RVEngine/EvaluateWithSemantics.swift`; `Sources/RVEngine/AnalyzeGit.swift` (context field reads only — no push/delete split); `Sources/RVService/GatedEvaluate.swift`; `Sources/RVService/EvaluateSession.swift`; `Sources/RVScan/Classify/ScanClassify.swift`; `Sources/RVPolicy/ReviewPromptBuilder.swift`; matching tests under `Tests/RVDomainTests`, `Tests/RVEngineTests`, `Tests/RVServiceTests`, `Tests/RVScanTests`, `Tests/RVPolicyTests` that construct `GitAnalysisContext` / `RepositoryReviewContext.isSharedBranch` | AC-101, AC-102, AC-402 (`RVDomainTests` + `RVEngineTests` + `RVServiceTests` git/evaluate filters) | 101–1499 |
| T3 | HookRequest closed invocation | none | `Sources/RVHooks/HostCodec.swift`; `Sources/RVHooks/HookDispatch.swift`; `Sources/RVHooks/HostDenyText.swift` (file deny sentence only); `Sources/RVHooks/GrokHostCodec.swift`; `Sources/RVHooks/ClaudeHostCodec.swift`; `Sources/RVHooks/CursorHostCodec.swift`; `Sources/RVHooks/PiHostCodec.swift`; `Sources/RVHooks/OpenCodeHostCodec.swift`; `Sources/RVHooks/OpenClawHostCodec.swift`; `Sources/RVHooks/HermesHostCodec.swift`; `Sources/RVHooks/CodexHostCodec.swift`; `Tests/RVHooksTests/**` | AC-301, AC-302, AC-402 (`RVHooksTests`) | 101–1499 |
| T4 | ApprovalIdentity is HookHost + SessionID | none | `Sources/RVDomain/PendingApproval.swift`; `Sources/RVDomain/PendingApprovalLedger.swift`; `Sources/RVService/HookDoor.swift`; `Sources/RVService/PendingIPC.swift`; `Sources/RVService/ServiceRuntime.swift` (empty-session check only); `Sources/RVIPC/IPCPending.swift` if identity fields are mentioned; `Tests/RVDomainTests/PendingApprovalLedgerTests.swift`; `Tests/RVServiceTests/PendingDispatchTests.swift`; `Tests/RVServiceTests/PendingResolveGrantTests.swift`; `Tests/RVIPCTests/PendingAndRuleRoundTripTests.swift`; other tests that construct `AgentIdentity` / `SessionIdentity` | AC-401, AC-402 (`RVDomainTests` pending + `RVServiceTests` pending + `RVIPCTests` pending) | 101–1499 |
| T2 | GitAction.push vs deleteRemoteRef | T1 | `Sources/RVDomain/GitAction.swift`; `Sources/RVDomain/PolicyMatch.swift`; `Sources/RVDomain/ActionPolicyEngine.swift`; `Sources/RVEngine/AnalyzeGit.swift`; `Sources/RVPolicy/RulePinning.swift`; matching tests (`Tests/RVDomainTests` PolicyMatch/GitAction, `Tests/RVEngineTests/AnalyzeGitTests.swift`, `Tests/RVPolicyTests/RulePinningTests.swift`, `Tests/RVEngineTests/ApplyGitSemantics*.swift` only if force/delete fixtures require it) | AC-201, AC-202, AC-402 | 101–1499 |

Frontier: T1, T3, T4 in parallel. T2 starts after T1’s commit is the base.

# 6. Test Automation Strategy

- **Test Levels**: Swift Testing unit tests in the module that owns the type.
- **Frameworks**: Swift Testing (`import Testing`). No XCTest.
- **TDD**: failing test that names the illegal program, then the type change, then gate.
- **Gate**: `tools/gate.sh <Filter>`. Warm `.build` in the worktree. Never `swift package clean`. After first resolve, `git restore Package.resolved` unless this ticket owns it.
- **Filters**: T1 `RVDomainTests` + `RVEngineTests` + relevant Service/Scan; T3 `RVHooksTests`; T4 pending tests; T2 PolicyMatch + AnalyzeGit + RulePinning.

# 7. Rationale & Context

Filesystem already shipped `FilesystemAnalysisWorld`. Git still uses a defaulted Bool, and the live door constructs it every evaluate. That is an extra-allow dressed as a fact.

File-tool is a product door. `HookRequest` is still a product of optional fields; dispatch order is the type.

Pending Ask is always a v1 host. Parallel string newtypes exist only so tests can plant `"not-a-host"` and prove a drop. The compiler should refuse the plant.

`git push --delete` is not a gitPush matcher input. The Bool on `.push` is why PolicyMatch has a runtime guard and why pin reconstructs `delete: false`.

# 8. Dependencies & External Integrations

### Technology Platform Dependencies
- **PLT-001**: Swift 6.3.3, language mode 6, macOS 26 / Linux aarch64-x86_64 as in `Package.swift`.

### Data Dependencies
- **DAT-001**: Durable pending JSON may contain `agent` strings. Valid `HookHost` raw values keep decoding. Unknown agents fail.

No new packages.

# 9. Examples & Edge Cases

```swift
// T1 live door — cwd known, sharedness unknown
GitAnalysisContext(workingDirectory: cwd, branchWorld: .unprobed)

// T1 test wall
GitAnalysisContext(
    workingDirectory: cwd,
    branchWorld: .probed(currentBranch: "main", isShared: true)
)

// T3 file
HookRequest(host: .grok, cwd: cwd, session: session, invocation: .file(file))

// T3 shell spend
HookRequest(
    host: .claude,
    cwd: cwd,
    session: session,
    invocation: .shell(command: command, ask: .spend)
)

// T4
ApprovalIdentity(session: sessionID, agent: .pi)

// T2
GitAction.push(remote: "origin", refspec: "main", force: .force)
GitAction.deleteRemoteRef(remote: "origin", refspec: "topic")
```

# 10. Validation Criteria

- Illegal constructors listed in §1 do not compile, or the ticket’s AC proves the equivalent.
- `tools/gate.sh` for the ticket filter is green.
- No host deny JSON key changes (golden hook tests).
- No `Decision.ask`. No ProposedAction new cases.
- Worktree: no leftover `Package.resolved` noise.

# 11. Related Specifications / Further Reading

- `spec/spec-architecture-type-system-remaining-holes.md` (landed force constraint, filesystem world, ledger types)
- `docs/architecture/MODULES.md`
- HTML: `$TMPDIR/swift-type-system-review-rv-20260915-041722.html`
