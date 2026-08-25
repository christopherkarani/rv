---
title: Session forensics under rv scan
version: 1.0
date_created: 2026-08-25
last_updated: 2026-08-26
owner: rv
tags:
  - architecture
  - tool
  - design
  - scan
  - forensics
---

# Introduction

This specification defines **session forensics** for rv: an offline CLI that discovers known agent session or transcript stores (or a user-supplied directory of known layouts), extracts shell-command candidate strings from surface host/tool fields, runs each candidate through the same pure `evaluate` path used by the live destructive-command guard, and reports **deny-only** findings.

Product fence (grill locks): [`docs/factory/specs/phase-4-session-scan.md`](../docs/factory/specs/phase-4-session-scan.md). Extractor ladder (surface → bounded unwrap → heredoc/AST) for forensics **and** the live guard: [`docs/factory/specs/phase-4-later.md`](../docs/factory/specs/phase-4-later.md) § Heredoc / AST roadmap. This document is the **implementable** architecture cut: requirements, interfaces, acceptance criteria, and a ticket DAG.

If this file and [`docs/factory/PLAN.md`](../docs/factory/PLAN.md) disagree, PLAN wins.

# 1. Purpose & Scope

## Purpose

Give an operator a local, read-only answer to: “Did my coding agents already run commands that rv’s day-one packs would deny?” without enabling `RVHistory`, without mutating hooks or policy, and without crawling the entire home directory.

## Audience

Implementers of rv (Swift 6.3 language mode 6, macOS 26, Apple Silicon) and reviewers using `implement-spec` / `swift-architecture-pipeline`.

## In scope

- CLI: `rv scan` and `rv scan sessions` (same behavior).
- Auto-discovery of **known host session roots** under an injectable home directory.
- Path argument: scan a directory tree for **known session layouts** only; `--include-glob` is allowed only with a path.
- Surface-field extraction only (stage 1 of the shared extractor ladder).
- `evaluate` deny-only findings; default day-one packs; optional `--packs`.
- Redacted command display by default; `--show-command` for full matching view.
- Default dedupe by matching view + `rule_id`; `--all-events` for per-event rows.
- Default time window 7 days; `--days N`; `--all`.
- Output modes: pretty, robot, browse.
- Exit 0 on successful scan even when findings exist; `--fail-on-findings` for a non-zero gate.
- Soft, non-mutating setup nudge when a `HookHost.setupSlotOrder` host adapter appears unwired (not Claude store hits until CL-T4).
- New SPM module `RVScan` plus Presentation/TUI/CLI wiring.
- Temp-HOME fixtures per host layout. No live-HOME tests.

## Out of scope

- `rv scan repo` (files, staged, git-diff, pre-commit, SARIF).
- Bounded unwrap, heredoc body recovery, or AST parsing (stages 2–3) — roadmap only.
- Opt-in `RVHistory` persist; writing history as a side effect of scan.
- Policy gate, allow-once spend, allowlist honor during scan classify.
- Secret-exfil finding taxonomy separate from evaluate deny.
- Mutating setup, packs, grants, or hooks from scan.
- Live hook codecs for Claude or other hosts (parallel release train; no code dependency).
- Linux, Windows, Intel, macOS 14/15 claims.
- OS Seatbelt / Landlock enforcement claims.
- Network pack install; analytics payloads carrying command text, paths, or secrets.
- `RV_BYPASS` or any skip-evaluate environment variable.

## Assumptions

- Day-one packs remain `core.git` and `core.filesystem`.
- `evaluate` order remains normalize → quick-reject → safe → destructive → default allow.
- Display `rule_id` slash form (`core.git/reset-hard`); robot JSON `rule_id` colon form (`core.git:reset-hard`) — match existing CLI/robot law.
- `ScanHome` (Domain newtype: non-empty injectable home path) exists for auto-root resolution; adapters may take that type or a directory `URL`. Tests never use live `$HOME` as the fixture root. Do not type scan roots as `RVPolicy.HomeDirectory`.
- Claude **hook** work may proceed in parallel tickets; session-store adapters must not import or require Claude hook codecs.

# 2. Definitions

| Term | Meaning |
|---|---|
| **Session forensics** | Offline scan of host session/transcript stores → extract → `evaluate` → deny findings. Vocabulary: `CONTEXT.md`. |
| **`rv scan` / `rv scan sessions`** | CLI entry points for session forensics. Bare `rv scan` defaults to sessions. |
| **Repo/CI scan** | Later sibling (`rv scan repo`). Not this specification. |
| **Host session store** | On-disk layout owned by a coding agent (for example Claude project JSONL, Pi session files) that may contain shell tool payloads. |
| **Store adapter** | Code that discovers roots, lists candidate files under bounds, and maps file bytes to zero or more **extracted events**. |
| **Extracted event** | One candidate shell command string plus provenance (host id, optional session id, source path, optional timestamp). |
| **Surface extraction** | Reading known shell-tool JSON/fields only (stage 1). No `bash -c` unwrap, no heredoc body, no AST. |
| **Matching view** | The T1-normalized command text an `EvaluationResult` was decided on (`CONTEXT.md`). |
| **Finding** | An extracted event (or dedupe group) whose `evaluate` `Decision` is `deny`. |
| **Day-one packs** | `core.git` and `core.filesystem`. |
| **Policy gate** | Post-evaluate allow-once / allowlist step used by hooks. **Must not run** during session forensics classify. |
| **Soft setup nudge** | At most one trailing human-facing hint from **T9 CLI** to run `rv setup` / doctor when a **`HookHost.setupSlotOrder`** host (v1: Pi, Grok, OpenCode) that produced events looks unwired. Never mutates config. Not a `ScanReport` field. Claude store hits must not recommend `rv setup` until CL-T4 writes a Claude adapter. |
| **Hard caps** | Fixed limits on walk depth, file count, total bytes, and per-file size. Exceeding a cap stops further reads for that scope and is reported; it is not a crash. |

# 3. Requirements, Constraints & Guidelines

## Functional

- **REQ-001**: `rv scan` and `rv scan sessions` shall execute session forensics with identical classify semantics.
- **REQ-002**: With no path argument, the tool shall discover only **registered known host roots** under the injectable home directory. It shall not recursively walk the entire home directory. Auto mode shall never apply extra `--include-glob` patterns under that home.
- **REQ-003**: With a path argument, the tool shall walk that tree for **known session layouts** only, unless `--include-glob` adds explicit patterns **under that path**. Unknown files are skipped, not parsed as shell by default. `--include-glob` is **path-mode only**: if it is given with no path argument, the CLI shall fail with a usage error (non-zero; not a successful empty scan) and shall not walk HOME.
- **REQ-004**: Default time window shall be the last **7** days relative to `SessionScanRequest.now`, based on event timestamp when present, else file modification time. `--days N` overrides. `--all` disables the time filter (bounds still apply). The scan core must not call `Date()`.
- **REQ-005**: Extraction shall be **surface fields only** for this specification’s ship. Unknown shapes yield no event (not a deny).
- **REQ-006**: Classify shall call `RVEngine.evaluate` with snapshots loaded via `RVPacks` (bundled `PackRegistry` / pack JSON). Do not assemble `EvaluateSession`, `GatedEvaluate`, or any other RVService session. Pack set default = day-one. Secret-path catalog stays `SecretPathCatalog.dayOne` (`evaluate`’s default) unless a later secret-path finding changes that default. `--packs` may select enabled catalog packs or an explicit id list as defined in the CLI ticket; empty `--packs` must not silently mean “all catalog.”
- **REQ-007**: Only `Decision.deny` becomes a finding. Allow (including matched medium/low), and indeterminate, are omitted from the finding list.
- **REQ-008**: Scan classify shall not call Policy gate, shall not spend allow-once grants, shall not read allowlist to suppress denials, and shall not write `RVHistory` or any evaluation persist store.
- **REQ-009**: Default display of command text shall be **redacted** using the same user-visible shape as allow-once redaction today: first whitespace-separated token, then ` …` when more tokens exist; empty → `[redacted]`. `--show-command` shows the full matching view string.
- **REQ-010**: Default listing shall **dedupe** by matching view string + `rule_id` (colon form for the dedupe key). Each group exposes `count` and `last_seen`. `--all-events` emits one row per extracted deny event.
- **REQ-011**: Output modes shall be pretty, robot, and browse, reusing existing CLI mode wiring. Robot and pretty/browse share one finding schema; do not invent a parallel `--json` schema.
- **REQ-012**: Process exit code shall be **0** when the scan completes successfully, including when findings exist. With `--fail-on-findings`, exit **2** if the finding list (after dedupe rules for the chosen mode) is non-empty. Usage/parse errors keep existing ArgumentParser behavior.
- **REQ-013**: After findings (or after an empty successful scan), **T9 CLI** (not `RVScan`) may emit **at most one** soft setup nudge in pretty/browse when a discovered host kind that produced events (1) is in `HookHost.setupSlotOrder` (v1: Pi, Grok, OpenCode) and (2) has Host adapter installation state that is not `wired`. Claude store hits must not recommend `rv setup` until CL-T4 actually writes a Claude adapter (`HostAdapterInstallationSnapshot.installation(for: .claude)` is hard-coded `.missing` today; `setupSlotOrder` excludes Claude). Compute the nudge in `RVCLI` from installation state (`HostAdapterInstallationSnapshot`). Robot may include a boolean or short code field on the CLI robot document. `ScanReport` must not carry setup-nudge state. Scan must not call setup writers.
- **REQ-014**: First-ship store adapters shall include **Claude** session/transcript layouts and day-one hosts **Pi**, **Grok**, and **OpenCode** where a documented on-disk layout exists. A host with no readable layout documents “unsupported store” in adapter docs/tests and contributes zero events without failing the whole scan.
- **REQ-015**: `--host <id>` shall restrict discovery and adapters to that host kind.
- **REQ-016**: Hard caps (mandatory constants, package-visible):

  | Cap | Value |
  |---|---|
  | Max directory depth from scan root | `8` |
  | Max files opened/read | `10_000` |
  | Max total bytes read | `268_435_456` (256 MiB) |
  | Max single file bytes | `33_554_432` (32 MiB) |

  Hitting a cap shall stop further reads, record a structured warning in robot + pretty, and still emit findings gathered so far. Exit remains 0 unless `--fail-on-findings` applies to findings.

- **REQ-017**: `git reset --hard` extracted from a fixture store shall deny as `core.git:reset-hard` under day-one packs (parity with engine corpus).
- **REQ-018**: A path that does not exist shall fail closed with a non-zero usage/IO error (not exit 0 with empty findings pretending success).

## Security

- **SEC-001**: No command text, argv, or matching view in `os_log` or analytics events.
- **SEC-002**: Default output must not print full secrets shaped like tokens in argv; redaction is required unless `--show-command`.
- **SEC-003**: No `RV_BYPASS` and no environment variable that skips `evaluate`.
- **SEC-004**: Scan must not mutate hooks, config, grants, allowlists, or pack enablement.
- **SEC-005**: Tests use temp HOME / temp trees only. No live-HOME reads or writes as fixtures.
- **SEC-006**: Do not phone home from scan. Host store bytes stay local.

## Constraints

- **CON-001**: `RVEngine` must not import CLI, TUI, XPC, or session-store I/O. Extractors feed `EvaluationRequest`; they do not decide.
- **CON-002**: New module **`RVScan`** owns discovery, adapters, surface extract, bounds, dedupe, and classify orchestration. It may depend on `RVDomain`, `RVEngine`, `RVPacks`. It must not depend on `RVCLI`, `RVTUI`, `RVService`, `RVPolicy`, or `RVHooks` codecs.
- **CON-003**: `RVPresentation` / `RVTUI` own human frames. `RVCLI` owns ArgumentParser and mode selection only (thin).
- **CON-004**: `RVHistory` remains a stub / separate feature. Scan must not use it as the event source or write sink.
- **CON-005**: `RVHooks` host **codecs** are not session-store adapters. Do not parse PreToolUse stdin envelopes as the forensics file format unless a store file literally uses that shape; prefer dedicated store parsers.
- **CON-006**: Do not implement `rv scan repo` in this wave. Prefer omit from help rather than a mutating stub.
- **CON-007**: Do not write foreign product names into Sources/ or Tests/ (PLAN name-hygiene). Docs under `docs/factory/` may reference fences only as needed.
- **CON-008**: Platform claim stays macOS 26 Apple Silicon only.
- **CON-009**: Value types in Domain/Engine/Scan/Presentation. `class` only at existing XPC/`NSObject` edges.

## Guidelines

- **GUD-001**: Prefer `some` store-adapter existentials only for heterogeneous adapter lists.
- **GUD-002**: Keep robot field names snake_case to match existing robot documents.
- **GUD-003**: Progress UX (spinner) is optional; if present, respect reduced-motion / plain flags like other TUI surfaces.
- **PAT-001**: One pipeline: `discover → read (capped) → extract surface → evaluate → filter deny → dedupe → render`.
- **PAT-002**: Shared future unwrap/AST stages plug in ahead of `evaluate` without changing Decision types.

# 4. Interfaces & Data Contracts

## 4.1 Module graph (additive)

| Target | New dependencies | Owns |
|---|---|---|
| `RVScan` (new) | `RVDomain`, `RVEngine`, `RVPacks` | Bounds, discovery, store adapters, extract, classify, dedupe |
| `RVScanTests` (new) | `RVScan` | Fixture trees under `Tests/RVScanTests/Fixtures/` |
| `RVPresentation` | Finding view models; prefer DTOs from Domain/Scan without file I/O in Presentation | Finding list view model |
| `RVTUI` | existing | Pretty/browse frames for findings |
| `RVCLI` | add `RVScan` | `Scan` command, flags, robot emission, setup-nudge read of installation state |

`Package.swift` gains library + test target for `RVScan`. Exclusive ticket owns that edit.

## 4.2 Public types (normative concepts)

Implementations may nest types. Split ownership so Domain stays `Date`/`FileManager`-free (`docs/architecture/MAP.md` Domain must-nots). **T1 must not edit `MAP.md`.**

**T1 on `RVDomain`:** `ScanBounds`, `ScanHome`, `ScanHostID`, and reuse of existing `RuleID` / `PackID` only. No `ExtractedEvent`, `ScanFinding`, `ScanReport`, or `Date` on Domain.

**T2 on `RVScan`:** `ExtractedEvent`, `ScanFinding`, `ScanWarning`, `ScanReport`, `SessionScanRequest`, `SessionScan`. Timestamps may be `Date?` here.

### Domain (T1)

```swift
public struct ScanBounds: Sendable {
    public var maxDepth: Int            // 8
    public var maxFiles: Int            // 10_000
    public var maxTotalBytes: Int64     // 268_435_456
    public var maxFileBytes: Int64      // 33_554_432
}

public enum ScanHostID: String, Sendable {
    case claude, pi, grok, opencode
}

public struct ScanHome: Hashable, Sendable {
    public let path: String            // non-empty; failable init. Not RVPolicy.HomeDirectory.
}
```

### RVScan (T2)

```swift
public struct ExtractedEvent: Sendable {
    public var host: ScanHostID
    public var sessionID: String?
    public var sourcePath: String
    public var occurredAt: Date?
    public var command: String
}

public struct ScanFinding: Sendable {
    public var host: ScanHostID
    public var sessionID: String?
    public var sourcePath: String
    public var occurredAt: Date?
    public var ruleID: RuleID
    public var packID: PackID
    public var matchingView: String
    public var count: Int
    public var lastSeen: Date?
}

public struct ScanWarning: Sendable {
    public var code: String
    public var message: String
}

public struct ScanReport: Sendable {
    public var findings: [ScanFinding]
    public var warnings: [ScanWarning]
    public var filesScanned: Int
    public var eventsExtracted: Int
}

public struct SessionScanRequest: Sendable {
    // optional root path, ScanHome, host filter, days/`all`, pack ids, allEvents, bounds
    public var now: Date               // injected; scan core must not call Date()
}

public struct SessionScan: Sendable {
    public func run(_ request: SessionScanRequest) throws -> ScanReport
}
```

`ScanReport` does not include setup-nudge state. T9 CLI reads Host adapter installation state and may set robot `setup_nudge`.

`SessionScanRequest.now` is the clock for the default 7-day window (AC-005). CLI supplies `Date()`; tests inject a fixed instant. Render flags such as `showCommand` may remain CLI-only.

## 4.3 Robot document (session scan)

```json
{
  "schema": "rv.scan.sessions.v1",
  "findings": [
    {
      "host": "claude",
      "session_id": "optional",
      "path": "/tmp/fixture/session.jsonl",
      "occurred_at": "2026-08-20T12:00:00Z",
      "rule_id": "core.git:reset-hard",
      "pack_id": "core.git",
      "command_redacted": "git …",
      "command": null,
      "count": 3,
      "last_seen": "2026-08-24T18:00:00Z"
    }
  ],
  "warnings": [{ "code": "cap.files", "message": "Stopped after 10000 files" }],
  "files_scanned": 12,
  "events_extracted": 40,
  "setup_nudge": false
}
```

`setup_nudge` is filled by T9 CLI from installation state, not copied from `ScanReport`. When `--show-command` is set, `command` is the matching view string. When not set, `command` is null or omitted.

## 4.4 CLI flags

| Flag | Type | Default |
|---|---|---|
| `path` | optional directory | auto roots (required when `--include-glob` is set) |
| `--host` | optional `ScanHostID` | all registered |
| `--days` | `UInt` | `7` |
| `--all` | flag | off |
| `--packs` | optional string list | day-one |
| `--show-command` | flag | off |
| `--all-events` | flag | off |
| `--fail-on-findings` | flag | off |
| `--include-glob` | repeatable string | none; **path-mode only** |
| output mode | existing pretty/robot/browse | existing CLI default |

When `--all` and `--days` are both set, `--all` wins.

`--include-glob` with no `path` is a usage error (non-zero). Auto mode never applies extra globs under HOME.

## 4.5 Store adapter protocol

```swift
public protocol SessionStoreAdapter: Sendable {
    var host: ScanHostID { get }
    func roots(home: ScanHome) -> [URL]
    func recognizes(fileURL: URL) -> Bool
    func extract(fileURL: URL, data: Data) throws -> [ExtractedEvent]
}
```

Auto mode unions `roots(home:)` and never applies `--include-glob`. Path mode: walk path; call `recognizes` / `--include-glob`; then `extract`.

Concrete production paths are documented beside each adapter; fixtures live under `Tests/RVScanTests/Fixtures/`. Unsupported layout → zero roots, scan continues.

# 5. Acceptance Criteria

- **AC-001**: Given a temp tree with a Claude-layout fixture containing a Bash/shell tool payload `git reset --hard`, when `SessionScan` runs with day-one packs, then the report includes a deny finding with robot `rule_id` `core.git:reset-hard`.
- **AC-002**: Given the same fixture with only `git status` (allow), when scan runs, then findings are empty and exit is 0.
- **AC-003**: Given three identical deny events, when scan runs without `--all-events`, then one finding row has `count == 3`. With `--all-events`, three rows appear.
- **AC-004**: Given default redaction, when pretty/robot render a multi-token deny, then the command field shows first-token `…` form and not the full argv. With `--show-command`, full matching view appears.
- **AC-005**: Given an event older than 7 days and a newer deny relative to an injected `SessionScanRequest.now`, when default `--days 7` runs, then only the newer deny is reported. With `--all`, both are eligible (subject to caps). Tests must not rely on wall-clock `Date()`.
- **AC-006**: Given a successful scan with findings and without `--fail-on-findings`, when the CLI finishes, then exit code is 0. With `--fail-on-findings`, exit code is 2.
- **AC-007**: Given Policy allow-once grants that would honor the same matching view on a hook path, when scan classifies, then the finding still appears (Policy gate off).
- **AC-008**: Given scan execution, when completed, then no `RVHistory` file is created and no grant file is consumed.
- **AC-009**: Given a path walk that exceeds `maxFiles`, when scan stops, then a `cap.files` warning is present and prior findings are still returned.
- **AC-010**: Given auto mode under a temp home with only fixtures for registered roots, when scan runs, then files outside those roots are not read. Auto mode does not apply extra globs under HOME.
- **AC-011**: Given `--host pi`, when Claude-only fixtures exist, then no Claude findings appear.
- **AC-012**: Given unwired installation state for a `HookHost.setupSlotOrder` host (Pi, Grok, or OpenCode) that produced events, when pretty mode runs, then T9 CLI emits at most one setup nudge line and no setup files are written. Given Claude-only store events, pretty mode does **not** print `run rv setup` on the strength of those hits (CL-T4 has not written a Claude adapter). `RVScan` / `ScanReport` do not inspect installation state.
- **AC-013**: Given `rv scan repo` is not implemented, when users run `rv scan` / `rv scan sessions`, then behavior matches this spec; help does not advertise a working repo scanner.
- **AC-014**: The system shall not read or honor `RV_BYPASS`.
- **AC-015**: Gate: `tools/gate.sh` includes `RVScanTests` and touched `RVCLITests` / `RVPresentationTests` / `RVTUITests` as applicable.
- **AC-016**: Given `--include-glob` with no path argument (including auto mode plus `--include-glob '**/*.jsonl'`), when the CLI runs, then it exits non-zero as a usage error and does not walk HOME.

## 5b. Tickets (task graph)

```
T1 Domain ScanBounds + ScanHome + ScanHostID
T2 RVScan module + walk + adapter protocol + Date DTOs (blocked by T1)
T3 Classify pipeline (evaluate deny-only)              (blocked by T2)
T4 Claude store adapter + fixtures                     (blocked by T2)
T5 Pi + Grok + OpenCode adapters + fixtures            (blocked by T2)
T6 Dedupe + time window                                (blocked by T3)
T7 Presentation + TUI frames                           (blocked by T6)
T8 CLI rv scan / rv scan sessions + robot + flags      (blocked by T4, T5, T7)
T9 Setup nudge + fail-on-findings + gate               (blocked by T8)
T10 Docs cross-links                                   (blocked by T9)
```

Wave 1: **T1**. Wave 2: **T2**. Wave 3: **T3 ∥ T4 ∥ T5**. Wave 4: **T6**. Wave 5: **T7**. Wave 6: **T8**. Wave 7: **T9**. Wave 8: **T10**.

| id | title | depends-on | exclusive-writes | acceptance | review-hint |
|---|---|---|---|---|---|
| **T1** | Scan bounds, `ScanHome`, `ScanHostID` on Domain | none | `Sources/RVDomain/ScanTypes.swift` (new); `Tests/RVDomainTests/ScanTypesTests.swift` (new) | Types are `Sendable`; bounds constants match REQ-016; reuse `RuleID` / `PackID`; `ScanHome` is a non-empty-path newtype (not `RVPolicy.HomeDirectory`); **no** `Date`/`FileManager`/`ExtractedEvent`/`ScanFinding`/`ScanReport` on Domain; do not edit `MAP.md` | `≤100` |
| **T2** | `RVScan` target, walker caps, `SessionStoreAdapter`, Date-bearing DTOs | T1 | `Package.swift` (add `RVScan` + `RVScanTests` only); `Sources/RVScan/**` (scaffold, bounds, walker, protocol, `ExtractedEvent`/`ScanFinding`/`ScanReport`/`SessionScanRequest`); `Tests/RVScanTests/WalkerBoundsTests.swift` (new); `docs/architecture/MODULES.md` (RVScan row only) | Walker stops at depth/files/bytes caps with warnings; no live HOME; `roots(home:)` takes Domain `ScanHome` or `URL`, not `RVPolicy.HomeDirectory`; `ExtractedEvent.occurredAt` / `ScanFinding.lastSeen` may be `Date?`; `SessionScanRequest.now: Date`; `ScanReport` has no setup-nudge field | `101–1499` |
| **T3** | Classify: events → evaluate → deny findings | T2 | `Sources/RVScan/Classify/**` (new); `Tests/RVScanTests/ClassifyTests.swift` (new) | AC-001/002/007/008 against in-memory events; day-one default; call `RVEngine.evaluate` with `RVPacks`-loaded snapshots; secrets `.dayOne`; no `EvaluateSession` / `GatedEvaluate` / RVService / Policy import | `101–1499` |
| **T4** | Claude session store adapter + fixtures | T2 | `Sources/RVScan/Adapters/Claude/**` (new); `Tests/RVScanTests/Fixtures/claude/**` (new); `Tests/RVScanTests/ClaudeAdapterTests.swift` (new) | AC-001 via Claude fixture tree; unrecognized files skipped | `101–1499` |
| **T5** | Pi, Grok, OpenCode store adapters + fixtures | T2 | `Sources/RVScan/Adapters/Pi/**` (new); `Sources/RVScan/Adapters/Grok/**` (new); `Sources/RVScan/Adapters/OpenCode/**` (new); matching `Tests/RVScanTests/Fixtures/{pi,grok,opencode}/**` + adapter tests (new) | Each host extracts a documented shell field or documents zero-root unsupported with a test; host filter unit-tested | `101–1499` |
| **T6** | Time window + dedupe | T3 | `Sources/RVScan/Dedupe.swift` (new); `Sources/RVScan/TimeWindow.swift` (new); `Tests/RVScanTests/DedupeTimeTests.swift` (new) | AC-003, AC-005 using injected `SessionScanRequest.now` (no `Date()` in TimeWindow) | `≤100` |
| **T7** | Presentation + TUI finding frames | T6 | `Sources/RVPresentation/Scan/**` (new); `Sources/RVTUI/Scan/**` (new); matching new Presentation/TUI tests only | Pretty lines include rule_id + redacted command; browse renders frames without opening a TTY | `101–1499` |
| **T8** | CLI `Scan` command, robot schema, flags | T4, T5, T7 | `Sources/RVCLI/Commands/ScanCommand.swift` (new); `Sources/RVCLI/Robot/ScanRobot.swift` (new); `Sources/RVCLI/RV.swift` (register subcommand only); `Sources/RVPresentation/RobotPayloads.swift` (`RobotSchema.scanSessions` constant only); `Tests/RVCLITests/ScanCommandTests.swift` (new); `Package.swift` (`RVCLI` → add `RVScan` dependency only) | AC-004, AC-006, AC-010, AC-011, AC-013, AC-016; robot schema `rv.scan.sessions.v1` next to existing `RobotSchema` constants | `101–1499` |
| **T9** | Setup nudge + fail-on-findings + gate | T8 | `Sources/RVCLI/Commands/ScanCommand.swift` (nudge + exit only); `Tests/RVCLITests/ScanNudgeTests.swift` (new); `tools/gate.sh` (`RVScanTests` filter only) | AC-006, AC-012, AC-015; CLI computes the nudge from Host adapter installation state for `HookHost.setupSlotOrder` hosts only; Claude store hits must not recommend `rv setup` until CL-T4; do not add `setupNudgeRecommended` to `ScanReport` | `101–1499` |
| **T10** | Docs cross-links | T9 | `docs/factory/STATUS.md` (board note only); `docs/factory/specs/phase-4-session-scan.md` (implement pointer + ticket ids only) | Fence points at this spec; STATUS lists it | `≤100` |

**Parallelism:** After T2, **T3 ∥ T4 ∥ T5** on separate worktrees with exclusive paths. **T6** waits on T3. **T8** waits on T4 ∧ T5 ∧ T7.

**`Package.swift`:** T2 adds targets; T8 may add `RVScan` to `RVCLI` dependencies only.

# 6. Test Automation Strategy

- **Test Levels**: Unit (walker caps, classify, dedupe, adapters); CLI integration (ArgumentParser + temp trees); no TTY required to prove Decision.
- **Frameworks**: Swift Testing (`import Testing`). No XCTest.
- **Test Data Management**: Synthetic session JSON/JSONL under `Tests/RVScanTests/Fixtures/`. Temp directories only. Never live HOME.
- **CI/CD Integration**: `tools/gate.sh` runs `RVScanTests` once the module exists; scan CLI tests in `RVCLITests`.
- **Coverage Requirements**: No new percentage gate. Required: deny `git reset --hard`, allow omitted, dedupe counts, redaction default, caps warning, `--fail-on-findings` exit 2, Policy gate not consulted.
- **Performance Testing**: Not a CI gate. Optional wall-time note on a 1k-file fixture in the T9 prove list.

# 7. Rationale & Context

Live hooks prevent future damage. Operators also need a retrospective: agents may have run destructive shell before rv was wired. Session forensics reuses **decision parity** (same engine, same `rule_id`) so findings are explainable with existing explain/corpus law, rather than a second risk heuristic list.

Default day-one packs keep the baseline story stable when users toggle catalog packs. Optional `--packs` covers simulating an enabled set.

Policy gate stays off because the command already executed; scan classifies strings and does not unlock or re-permit.

Surface extraction ships first so host field maps can harden before unwrap/AST complexity lands on the shared ladder used later by the live guard.

Claude store adapters ship for discovery without requiring Claude hook codecs in-process — same release train, parallel tickets, no hard dependency. Finding Claude transcripts must not claim rv blocked Claude, and must not nudge `rv setup`, until CL-T4 actually writes a Claude adapter.

# 8. Dependencies & External Integrations

### External Systems

- **EXT-001**: Host session/transcript directories on disk (Claude, Pi, Grok, OpenCode layouts) — read-only input. Formats owned by those hosts; rv adapters are best-effort parsers with fixtures.

### Third-Party Services

- None for scan. No network.

### Infrastructure Dependencies

- **INF-001**: Local filesystem read access under injectable home / user path.
- **INF-002**: Bundled pack JSON via `RVPacks` for evaluate (day-one always available).

### Data Dependencies

- **DAT-001**: Day-one pack patterns for deny parity (`core.git:reset-hard`, and related corpus denials).
- **DAT-002**: Fixture trees under `Tests/RVScanTests/Fixtures/`.

### Technology Platform Dependencies

- **PLT-001**: macOS 26, Apple Silicon, Swift 6.3 language mode 6 — existing pin.
- **PLT-002**: ArgumentParser CLI patterns already used by `RVCLI`.

### Compliance Dependencies

- **COM-001**: `docs/factory/PLAN.md` privacy and evaluate purity law.
- **COM-002**: History off-by-default forever until explicit enable (`phase-4-later.md`).

# 9. Examples & Edge Cases

```text
# Auto roots, last 7 days, pretty
rv scan

# Explicit alias
rv scan sessions --days 30

# Folder of known layouts
rv scan /tmp/agent-sessions --host claude

# Extra globs only with a path
rv scan /tmp/agent-sessions --include-glob '**/*.jsonl'

# Scripts / CI gate
rv scan --robot --fail-on-findings
# exit 0 → no deny findings
# exit 2 → one or more deny findings

# Full command text (operator opts in)
rv scan sessions --show-command --all-events
```

Edge cases:

- Empty store / no roots → empty findings, exit 0, no crash.
- Truncated JSONL line → skip line, continue; do not deny on parse failure.
- File larger than `maxFileBytes` → skip file, `cap.file-size` warning.
- Indeterminate evaluate → not a finding.
- Matching allow with RuleMatch (medium/low) → not a finding.
- `--all` and `--days` together → `--all` wins.
- `--include-glob` with no path (including `rv scan --include-glob '**/*.jsonl'`) → usage error; HOME is not walked.
- Claude-only transcript hits → no `run rv setup` nudge until CL-T4 writes a Claude adapter.

# 10. Validation Criteria

- All REQ/SEC/CON above have a mapped AC or ticket acceptance bullet.
- `tools/gate.sh` green for `RVScanTests` and scan-related `RVCLITests` on the integration branch.
- No live-HOME test.
- No command text in `os_log` from scan paths.
- No Policy gate spend under scan classify tests.
- Fence doc links to this specification and ticket ids after T10.
- Foreign product names absent from `Sources/` and `Tests/` touched by this wave.

# 11. Related Specifications / Further Reading

- [`docs/factory/specs/phase-4-session-scan.md`](../docs/factory/specs/phase-4-session-scan.md) — product fence / grill locks
- [`docs/factory/specs/phase-4-later.md`](../docs/factory/specs/phase-4-later.md) — Phase 4+ fence; Heredoc / AST roadmap
- [`docs/factory/PLAN.md`](../docs/factory/PLAN.md) — conflict arbiter
- [`CONTEXT.md`](../CONTEXT.md) — Session forensics vocabulary
- [`docs/architecture/MODULES.md`](../docs/architecture/MODULES.md) — module graph (updated in T2/T10)
- [`spec/spec-architecture-c-hook-pipe.md`](spec-architecture-c-hook-pipe.md) — ticket DAG style precedent
- [`docs/factory/specs/phase-1-engine.md`](../docs/factory/specs/phase-1-engine.md) — evaluate order / Decision law
