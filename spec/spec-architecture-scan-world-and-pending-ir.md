---
title: Scan filesystem world and analyzed pending IR
version: 1.0
date_created: 2026-09-13
last_updated: 2026-09-13
owner: architecture-pipeline
tags: [architecture, scan, evaluate, pending, pin]
---

# Introduction

Execute the two Strong candidates from `$TMPDIR/swift-architecture-review-rv-20260913-001044.html` (HEAD `69c04d8`, branch `worktree/lucky-stone-a9f4`).

1. **C01** — Distinguish unprobed vs probed filesystem worlds. `ScanClassify` shares `evaluateWithSemantics` after #202; the door’s default empty context is fail-closed as `builtin.action:unresolved-path` for pack-allow writes. Live hook stay fail-closed when probed.
2. **C02** — Record analyzed `ProposedAction` on pending Host Ask (effects from Git/filesystem analysis, fingerprint still `ActionFingerprint.make`). Collapse `RulePinning.blocksAllowOverride(Deny)` and RulePinning toy parsers into `UnlockableDeny`.

Do not execute Worth-exploring C03 (`HookDoorPorts`). Do not fold miss into `HookDoor` (cli-thin CL2). Do not put `boundReview` on the evaluate IPC wire. Do not copy `FilesystemLiveProbe` into RVScan. Do not add an SPM target. Do not raise Swift tools / language mode.

# 1. Purpose & Scope

**Audience:** implement-spec agents on `rv` (Swift 6.3.3, language mode 6, macOS 26 Apple Silicon + Linux). Gate: `tools/gate.sh`. Warm `.build`. Never `swift package clean`.

**In scope:**

1. A compiler-visible filesystem probe state on `FilesystemAnalysisContext`.
2. `applyFilesystemSemantics` skipping unresolved-path tighten when unprobed; other semantic denials still tighten.
3. `FilesystemLiveProbe` always returning probed contexts (including missing cwd).
4. Scan classify tests proving pack-allow writes are not unresolved-path findings; unwrap-limited still is.
5. Optional reconstructed scan workspace when a session adapter already knows cwd from layout (T2).
6. `EvaluationResult` → pending `ProposedAction` with host-door fingerprint + analysis effects.
7. `hookWire` records that action, not the codec empty-effect stub.
8. `UnlockableDeny` as the only pin fact for PolicyGate, RebaseRecovery, and RulePinning result overload. Delete leftover Deny-only pin list and toy argv parsers.

**Out of scope:**

- HookDoorPorts / folding ServiceClient miss into HookDoor.
- OPE-156 codec-invented effects. Codecs may keep the empty-effect default `proposedAction` for decode-time IR; pending must not use it when analysis exists.
- PolicyPredicate cases beyond `gitPush`.
- File tool door (already landed on HEAD).
- EvaluationWorld re-assembly. Policy gate pipeline. SessionScan walk/extract/dedupe.
- Live Auto-review. `Decision.ask`.
- `Sources/rv-c/**`.
- Moving `FilesystemLiveProbe` out of RVService.

**Assumptions:**

- Hexagon unchanged. RVScan does not import RVService. Engine stays pure (no `FileManager` in RVEngine/RVDomain).
- `GatedEvaluate` already injects `FilesystemLiveProbe.context`.
- `ScanClassify` already calls `evaluateWithSemantics` with default probe `{ _ in .empty }`.
- `HostNativeAsk.verdict` already uses `EvaluationResult` + `UnlockableDeny`.
- Allow-once keys stay `{matchingView, cwd}`.

# 2. Definitions

| Term | Meaning |
|---|---|
| Evaluation door | `evaluateWithSemantics`: pack evaluate → unwrap → probe → analyze → apply. Pack deny/indeterminate is the floor. |
| Filesystem world | Caller-supplied facts for `analyzeFilesystem` / `applyFilesystemSemantics`. |
| Unprobed | No filesystem I/O world was injected. Default `FilesystemAnalysisContext.empty`. Semantic unresolved-path must not tighten a pack allow. |
| Probed | A caller constructed a world (live probe). Missing cwd / missing repo root stays fail-closed unknown → unresolved-path. |
| Scan workspace | Optional cwd/home reconstructed from a session-store layout, not from the hook process directory. |
| Host-door fingerprint | `ActionFingerprint.make(host:session:cwd:command)`. Spend/clear pending identity. Not `shell:git.*` / `shell:fs.*`. |
| Analyzed pending action | `ProposedAction.shell` with host-door fingerprint, analysis effects/resources, supporting command, cwd scope. |
| Pin fact | `UnlockableDeny.isPinned(result)`. Secrets, builtin.action pack, unwrap-limited analysis, protected-path. `mandatoryHuman` is Ask/spend, not this pin. |
| Toy parser | `RulePinning`’s `unwrapLimitedCommand` / `secretPathHit` argv walks. Forbidden after T3. |

# 3. Requirements, Constraints & Guidelines

## T1 — Unprobed vs probed filesystem world

- **REQ-101**: `FilesystemAnalysisContext` carries a closed probe state. Names may match local style; the states are exactly `unprobed` and `probed`. `static let empty` is unprobed, empty facts, nil repo/cwd/home. Codable must round-trip the new field (default decode missing → `unprobed`).
- **REQ-102**: `applyFilesystemSemantics` (analysis overload, the one `applySemantics` calls): when the filesystem context is **unprobed** and `ActionPolicyEngine` would hardDeny `Builtin.unresolvedFilesystem`, keep the pack allow (or current pack verdict) and still attach `analysis`. Do not skip unwrap-limited (that is `applyUnwrapLimit`, not this ticket’s change). Do not skip protected-path / out-of-repo when those come from catalog or probed facts.
- **REQ-103**: When the context is **probed**, today’s fail-closed remains: missing repo root, uncertain resolution, unknown scope → `builtin.action:unresolved-path`. Existing `missingRepositoryRoot_isFailClosed` must pass **with an explicitly probed empty-repo context**, not via `empty`.
- **REQ-104**: `FilesystemLiveProbe.context` (both overloads that return a context) sets probed. Missing cwd still probed. RVService only.
- **REQ-105**: `ScanClassify` may keep the default probe. Empty default is unprobed, so pack-allow `echo hi > file` / `rm foo` must not become unresolved-path findings. `classify_semanticOnlyDeny_emitsFinding` (unwrap-limited python) still emits `Builtin.unwrapLimited`.
- **REQ-106**: Add ScanClassify tests for a pack-allow write (`echo hi > file` or `touch new.swift`) and a pack-allow `rm foo` (not `rm -rf /`). Findings empty. Do not write grant/history files.
- **CON-101**: Do not import RVService from RVScan. Do not add `FileManager` to RVEngine. Do not change Policy gate, AllowOnce, or live missing-cwd fail-closed.
- **CON-102**: Do not reconstruct adapter cwd in T1. That is T2.
- **GUD-101**: Prefer a stored enum on the existing struct over a wrapper type that every call site must rebuild.
- **PAT-101**: Pack floor helpers stay in `EvaluationResult.packFloor`. Do not add `isDenied`.

CONTEXT.md: replace the sentence that offline scan “semantic stages see empty contexts” with: offline scan is **unprobed**; pack deny stays the floor; unwrap-limited still tightens; unresolved-path does not tighten an unprobed allow. Live `GatedEvaluate` still injects a probed `FilesystemLiveProbe`.

## T2 — Scan workspace when the layout already knows cwd

- **REQ-201**: `ExtractedEvent` gains `workingDirectory: WorkingDirectory?` default nil. Existing memberwise call sites keep compiling (default nil).
- **REQ-202**: Adapters that already encode cwd in the store path must fill it when parseable:
  - Grok: `$HOME/.grok/sessions/<cwd>/...` — recover cwd from the path between `sessions` and the session-id directory when it looks like a filesystem path (absolute or the host’s documented slug). If recovery is not reliable without live I/O, leave nil rather than guess a relative slug that would probe-wrong.
  - Other adapters: fill only when the extracted JSON/envelope already has a cwd/workdir field the hook codecs already know. Do not invent process.cwd. Do not walk `$HOME` to realpath.
- **REQ-203**: When `ExtractedEvent.workingDirectory` is non-nil, `ScanClassify` injects a **lexical** filesystem context: probed, that cwd, `repositoryRoot` only if it can be derived **without** `FilesystemLiveProbe` / `FileManager` (if it cannot, keep repo nil and remain fail-closed for writes — that is correct probed-unknown). Prefer: probed + cwd + catalog `.dayOne` + empty facts so `classifyFilesystemTarget` uses `lexicalFilesystemPath`. Protected-path lexical hits still deny. In-repo vs out-of-repo only when `repositoryRoot` is known; otherwise unresolved-path is allowed for probed-unknown (fail-closed).
- **REQ-204**: When workingDirectory is nil, behavior is T1 unprobed.
- **CON-201**: Depends on T1. Do not copy `FilesystemLiveProbe.swift` into RVScan. Do not `import RVService`. No live symlink following in scan.
- **CON-202**: Do not enable Policy gate in classify. No grant spend. No RVHistory writes.
- **GUD-201**: If Grok path recovery is ambiguous, tests document nil. A later ticket can add live scan probe; this ticket must not.

## T3 — Analyzed pending action + one pin fact

- **REQ-301**: Domain grows one function (name local: `pendingAction` / `analyzedProposedAction`) on `EvaluationResult` or a small enum next to it:

  ```
  host + session + cwd + command + result
    → ProposedAction.shell(
         fingerprint: ActionFingerprint.make(...),
         effects/resources from gitAction ?? filesystemAction,
         scope.workingDirectory: cwd,
         supportingCommand: command
       )
  ```

  If analysis is `.unknown` or `.unwrapLimited` without git/fs action, effects may be empty; fingerprint still `make`. Never use analyzer `shell:git.*` fingerprints for pending identity.
- **REQ-302**: `hookBody` in `HookDispatch` records `pendingAction` from the **evaluated** `EvaluationResult` plus `HookRequest` host/session/cwd/command. Clear uses the same action. Stop passing `codec.proposedAction(from: request)` into `recordHostAsk` / `clearHostAsk` when a result exists. Spend-first path that evaluates via `spendHostAsk` uses that result the same way.
- **REQ-303**: `HostCodec.proposedAction` default empty-effect stub may remain for protocol completeness / tests. Production pending must not depend on it when `evaluate` already ran.
- **REQ-304**: `RulePinning.hardStop(in:)` uses `ActionPolicyEngine.evaluate(action:)` on the stored action (effects filled). Delete `unwrapLimitedCommand` and `secretPathHit` / `pathCandidates` toy parsers. Unwrap-limited hard stop: `unwrapLimited` effect or `supportingCommand` is not re-tokenized; if the stored action has no effects, `hardStop` may return nil for unwrap (live evaluate already pinned via `UnlockableDeny` on the result). Secret-path hard stop: catalog match on resources.path / supporting path only if already on the action; do not reimplement `SecretPathMatching` walks. If a test today plants `cat .env` with empty effects and expects `.secretPath`, change the fixture to carry a protected/secret resource or accept that empty-effect pending cannot preview that stop (prefer fixture with effects).
- **REQ-305**: `RulePinning.blocksAllowOverride(EvaluationResult)` stays a one-line forward to `UnlockableDeny.isPinned`. **Delete** `blocksAllowOverride(Deny)` **or** make it unavailable (`package` + unused). `RebaseRecovery.isUnoverridableHardStop` must not use a Deny rule-id table. It uses `UnlockableDeny.isPinned` except it still returns false for `Builtin.workingTreeDiscard` so rebase can lift that pin. Secrets / protected-path / unwrap-limited stay unoverridable via the same `UnlockableDeny` / analysis checks already in `RebaseRecovery`.
- **REQ-306**: `gitPushPredicate(from:)` keeps matching `GitAction.push` / `.remoteSharedBranchMutation` on the **stored** action. A test must evaluate a force-push (or construct `EvaluationResult` with `.git(.push(...))`) through `pendingAction` and prove `RulePinning.preview` emits a v2 gitPush draft, not fingerprint v1.
- **CON-301**: Do not encode `boundReview` on `EvaluationResult` Codable / `EvaluateReply`. Do not change AllowOnce keys. Do not fold miss into HookDoor. Do not add `HookDoorPorts` (C03).
- **CON-302**: Pending JSONL: extra effect keys are additive Codable. Old empty-effect rows still decode. Preview on old rows stays fingerprint v1 / generic sentence.
- **PAT-301**: `UnlockableDeny` remains the Ask/mint/spend pin. Do not invent `isPinned` on `Deny` as a second table of builtin rule ids.

# 4. Interfaces & Data Contracts

### FilesystemAnalysisContext (T1)

Existing fields remain. Add:

```swift
public enum FilesystemProbeState: String, Sendable, Equatable, Codable {
    case unprobed
    case probed
}
```

`FilesystemAnalysisContext.probe` (or `availability`) stored. `empty` → `.unprobed`. Live probe → `.probed`.

### ExtractedEvent (T2)

```swift
public var workingDirectory: WorkingDirectory? = nil
```

### Pending action (T3)

`EvaluationResult` keeps Codable without `boundReview`. New function is not Codable. `ProposedAction` / `ShellAction` already Codable with effects.

Fingerprint field on pending records stays host-door `make`.

### Pin (T3)

| Call site | After |
|---|---|
| `PolicyGate` | `RulePinning.blocksAllowOverride(result)` → `UnlockableDeny.isPinned` |
| `RebaseRecovery` | `UnlockableDeny` + working-tree-discard exception (already in file) |
| `HostNativeAsk` | unchanged (`UnlockableDeny.matches`) |
| `GatedEvaluate.mintUnlockCode` | unchanged |

# 5. Acceptance Criteria

- **AC-101**: Given ScanClassify day-one packs, when classify `echo hi > file`, then findings are empty.
- **AC-102**: Given ScanClassify, when classify `python -c "mystery(payload)"`, then one finding `builtin.action:unwrap-limited`.
- **AC-103**: Given `applyFilesystemSemantics` with **probed** context, nil repo, pack-allow write, then deny `unresolvedFilesystem`.
- **AC-104**: Given `applyFilesystemSemantics` with `FilesystemAnalysisContext.empty` (unprobed), pack-allow write, then decision stays allow and analysis is filesystem.
- **AC-105**: Given GatedEvaluate live path (existing FilesystemBoundaryProbe tests), out-of-repo / unresolved still deny.
- **AC-201**: Given ExtractedEvent with a workingDirectory, when that adapter fills it, ScanClassify passes a probed lexical context (T2). Nil cwd stays unprobed.
- **AC-301**: Given evaluate of `git push --force origin feature` (or equivalent GitAction.push with remoteSharedBranchMutation) then `pendingAction`, `RulePinning.draft` is v2 typed pin JSON with `gitPush`, not v1 fingerprint-only.
- **AC-302**: `RebaseRecoveryTests` still allow eligible discard during rebase; `blocksAllowOverride(Deny)` is gone or unused; `UnlockableDeny.isPinned` is the pin.
- **AC-303**: `rg "unwrapLimitedCommand|func secretPathHit" Sources/RVPolicy/RulePinning.swift` is empty after T3.
- **AC-304**: `git reset --hard` still denies on the live door; `git stash drop` still allows. No `RV_BYPASS`.

## 5b. Tickets (task graph)

| id | title | depends-on | exclusive-writes | acceptance | review-hint |
|---|---|---|---|---|---|
| T1 | Unprobed vs probed filesystem world | none | `Sources/RVDomain/SemanticAnalysis.swift`; `Sources/RVEngine/ApplyFilesystemSemantics.swift`; `Sources/RVService/FilesystemLiveProbe.swift`; `Tests/RVEngineTests/ApplyFilesystemSemanticsTests.swift`; `Tests/RVScanTests/ClassifyTests.swift`; `CONTEXT.md` | AC-101, AC-102, AC-103, AC-104, AC-105; `tools/gate.sh RVEngineTests RVScanTests RVServiceTests` (filter existing + new names) | 101–1499 |
| T2 | Scan workspace from store layout | T1 | `Sources/RVScan/SessionStoreAdapter.swift`; `Sources/RVScan/Classify/ScanClassify.swift`; `Sources/RVScan/Adapters/Grok/GrokStoreAdapter.swift`; `Sources/RVScan/Adapters/Claude/ClaudeSessionStoreAdapter.swift`; `Sources/RVScan/Adapters/Pi/PiStoreAdapter.swift`; `Sources/RVScan/Adapters/OpenCode/OpenCodeStoreAdapter.swift`; `Sources/RVScan/Adapters/OpenClaw/OpenClawStoreAdapter.swift`; `Sources/RVScan/Adapters/Hermes/HermesStoreAdapter.swift`; `Sources/RVScan/Adapters/Codex/CodexStoreAdapter.swift`; `Sources/RVScan/Adapters/Cursor/CursorStoreAdapter.swift`; `Tests/RVScanTests/ClassifyTests.swift` (workspace cases only; do not revert T1 tests); `Tests/RVScanTests/GrokAdapterTests.swift` (and other `Tests/RVScanTests/*AdapterTests.swift` only if that adapter’s extract signature change forces a compile fix) | AC-201; `tools/gate.sh RVScanTests` | 101–1499 |
| T3 | Analyzed pending IR + UnlockableDeny pin | none | `Sources/RVDomain/EvaluationResult.swift`; `Sources/RVHooks/HookDispatch.swift`; `Sources/RVPolicy/RulePinning.swift`; `Sources/RVPolicy/RebaseRecovery.swift`; `Tests/RVDomainTests/` (new pendingAction tests or EvaluationResult tests); `Tests/RVPolicyTests/RulePinningTests.swift`; `Tests/RVPolicyTests/RebaseRecoveryTests.swift`; `Tests/RVHooksTests/HookMapperTests.swift` (only if recordPending fingerprint tests live there; otherwise the file that asserts pending action) | AC-301, AC-302, AC-303, AC-304; `tools/gate.sh RVDomainTests RVPolicyTests RVHooksTests` | 101–1499 |

Independent: T1 ∥ T3. T2 after T1.

If T2 adapter tests live under a different filename, that ticket still owns all `Sources/RVScan/Adapters/**` listed. Do not edit `HookDoor.swift` / `ServiceRuntime.swift` / `ServiceClient.swift` unless a compile forces a one-line call-site change; prefer HookDispatch only.

Specialist: `swift-functional-architecture` + repo `swift-hexagonal-spm` (graph) + `swift-evaluate-parity` for T1 classify/evaluate doors + `swift-hook-xpc` for T3 pending/pin.

# 6. Test Automation Strategy

- **Test Levels**: Swift Testing unit tests in the module that owns the type. Decision tests do not open a TTY.
- **Frameworks**: `import Testing`. No XCTest. No live HOME.
- **Gate**: `tools/gate.sh <Target>Tests` via `tools/swift-6.3.3`. Warm `.build`. Copy `.build` from the parent repo into the worktree if missing (do not `swift package clean`).
- **T1**: Engine applyFilesystemSemantics + ScanClassify classify tests. Keep FilesystemBoundaryProbeTests green (probed live).
- **T2**: Adapter extract fills cwd or explicitly nil; classify with injected cwd.
- **T3**: Domain pendingAction fingerprint ≠ semantic fingerprint; RulePinning preview; RebaseRecovery; no toy parsers.
- **Coverage**: New behavior has a named test. Do not assert line counts.

# 7. Rationale & Context

#202 made ScanClassify share the evaluation door. The door’s default probe is empty. `classifyFilesystemScope` returns `.unknown` without a repo root. `ActionPolicyEngine.filesystemHit` hardDenies unresolved-path. Engine already tests that (`missingRepositoryRoot_isFailClosed`). Session forensics then lists ordinary writes as unresolved-path. Unprobed vs probed makes the default honest without weakening the live hook.

Host Ask records `HostCodec.proposedAction`, documented as empty-effect. `GitAction.proposedAction` already fills effects. Pin preview and typed gitPush drafts look at those effects and never see them on live pending rows. RulePinning also keeps a Deny-only pin list and toy unwrap/secret parsers that can disagree with `UnlockableDeny`. One analyzed action + one pin fact.

# 8. Dependencies & External Integrations

### External Systems

- **EXT-001**: Host session stores (Grok/Claude/Pi/…) — T2 reads layout only; no live hook.

### Third-Party Services

None.

### Infrastructure Dependencies

- **INF-001**: Swift 6.3.3 toolchain via `tools/swift-6.3.3`. macOS 26 / Linux.

### Data Dependencies

- **DAT-001**: Existing `pending-approvals.jsonl` rows with empty effects must still decode.

### Technology Platform Dependencies

- **PLT-001**: Swift tools 6.3, language mode 6. Do not bump.

### Compliance Dependencies

- **COM-001**: No command text in `os_log`. No `RV_BYPASS`. Analytics never carries command text.

# 9. Examples & Edge Cases

```swift
// T1 unprobed: pack-allow write is not unresolved-path
let pack = try runFilesystemPack("echo hi > file")
let composed = applyFilesystemSemantics(
    pack: pack,
    command: ShellCommand(rawValue: "echo hi > file")
    // context defaults to .empty → unprobed
)
#expect(composed.decision == .allow)

// T1 probed: same write, no repo → unresolved-path
var probed = FilesystemAnalysisContext.empty
probed.probe = .probed
let closed = applyFilesystemSemantics(
    pack: pack,
    command: ShellCommand(rawValue: "echo hi > file"),
    context: probed
)
#expect(closed.decision == .deny) // Builtin.unresolvedFilesystem

// T3 fingerprint
let result = /* evaluate git push --force origin topic */
let action = result.pendingAction(host: .pi, session: sid, cwd: cwd, command: cmd)
#expect(action.fingerprint == ActionFingerprint.make(host: .pi, session: sid, cwd: cwd, command: cmd))
#expect(action.effects.kinds.contains(.remoteSharedBranchMutation))
```

# 10. Validation Criteria

- All exclusive-write files for a ticket compile under 6.3.3.
- `tools/gate.sh` for that ticket’s targets is green on a warm `.build`.
- `git reset --hard` still denies; stash drop still allows (T3 / existing corpus).
- RVScan sources still have no `import RVService` / `import RVPolicy` / `GatedEvaluate`.
- No new `class` in Domain/Engine/Packs/Presentation.
- No `try!` / IUO on production paths.
- No `@_exported import` added.

# 11. Related Specifications / Further Reading

- `docs/architecture/MODULES.md` — hexagon; RVScan must not import Service.
- `CONTEXT.md` — Evaluation door, ScanClassify, UnlockableDeny, Host adapter.
- `spec/spec-architecture-session-scan.md` — classify is deny-only, ungated.
- `spec/spec-architecture-hook-door-fingerprint.md` — host-door fingerprint spelling; do not put boundReview on the evaluate wire.
- `docs/architecture/english-compile.md` — PolicyPredicate.gitPush only; typed allow cannot beat the wall.
- HTML: `/var/folders/ns/xmz0zmpj7p148vdgr4bwzp8h0000gn/T/swift-architecture-review-rv-20260913-001044.html`
