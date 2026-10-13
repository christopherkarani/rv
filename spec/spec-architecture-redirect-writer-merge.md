---
title: Fuse redirect-lexer, writer flag-scan, and per-host settings-merge fan-outs
version: 1.0
date_created: 2026-10-09
owner: rv architecture pipeline
tags: architecture, deep-module, RVEngine, RVCLI, redirect-lexer, flag-scan, settings-merge
---

# Introduction

Three shallow-copy fan-outs sit on hot paths: a triplicated
redirect-operator grammar (three modules, three shapes, subtly different
operator sets), a parallel writer flag grammar that can desync from the
`FlagScan` deep module, and a line-for-line per-host settings-merge
duplication across four `RVCLI/Setup` files. Each fix today must land in
multiple places with no single seam of leverage. This spec fuses each
fan-out behind one narrow tested interface. All three fusions are
behavior-preserving refactors; no semantic change.

## 1. Purpose & Scope

Purpose: concentrate each duplicated grammar/policy behind one deep
module so operator-coverage, getopt, and occupancy-trap fixes land once,
with fast unit tests at each new seam.

Scope:

- **R1** (redirect-lexer unification): `Sources/RVEngine/` (3 named
  files + 1 new file) and one new test file under
  `Tests/RVEngineTests/`.
- **M1** (per-host settings-merge unification): `Sources/RVCLI/Setup/`
  (4 named files + at most 1 new file) and one new test file under
  `Tests/RVCLITests/`.
- **W1** (writer flag-scan rebuild over `FlagToken` events):
  `Sources/RVEngine/` (3 named files, stacked on R1) and one new test
  file under `Tests/RVEngineTests/`.

Out of scope: Cursor/Codex/OpenCode merges, `HostHooksMergeEngine`
itself, `HostWiring`, `SetupUninstall`, the JSONL fail-closed gate, the
`HostCodec` seam, the spawn/fd-hygiene fusion (sibling spec), the
launch-ceremony and wire-code candidates, the plugin-list round-trip,
and every landed spec (type-system enums, engine composition door,
rule-identity IPC helpers) — none relitigated here.

Audience: the R1/W1/M1 implementers, reviewers, and future maintainers
of the engine parse and setup paths. Assumes Swift 6.4, macOS 15 SDK,
Swift Testing. Line numbers below are main@04b4740c; each implementer
re-verifies them on their ticket branch.

## 2. Definitions

- **redirect operator**: shell output/input redirection syntax (`>`,
  `>|`, `>>`, `>&`, `&>`, `&>>`, `<>`, `<`, `<<`, `<<<`, `<<-`, `<&`)
  with optional leading fd digits (`2>`, `10>>`).
- **fd digits**: leading decimal digits naming the redirected file
  descriptor.
- **dup/close**: fd duplication or close (`2>&1`, `>&-`, `<&-`); never
  names a file destination.
- **attached**: operator glued to its target with no space (`>>file`,
  `2>err`).
- **getopt grammar**: long (`--long`, `--long=value`, unique-prefix
  abbreviation), clustered-short (`-rf`), next-word value consumption,
  and `--` terminator rules shared by the engine flag parsers.
- **`FlagToken` events**: structural per-word classification
  (`.positional`, `.long`, `.shorts`, `.shortEquals`, `.terminator`,
  `.loneDash`, `.dangling`) produced by `FlagToken.classify` and the
  `FlagScan` value-taking scan.
- **`WriterScan`**: today's writer-verb scan result (operands,
  flagValues, candidates, bare-hit sets, sawHelp, failed).
- **conflicted short**: a short flag that takes a value on one platform
  and is bare on the other (e.g. `cp -S`); consumes attached rest only.
- **candidate**: neighbor of an unknown bare long, also evaluated as a
  destination so a real-but-unlisted value-taker cannot desync the scan
  into a miss.
- **occupancy trap**: merge refuses to overwrite a foreign/tampered
  guard file without `--force` (`.occupied` inspection state).
- **stale-legacy**: our own superseded hook command (Claude v1
  `hook --host claude`); `.outdated`, rewritable without `--force`.
- **wired**: current hook command plus full matcher coverage plus an
  executable baked `rv` with sibling `rv-cli`.
- **descriptor**: per-host data (constants plus small predicates)
  parameterizing a shared module; per-host behavior differences live in
  the descriptor, shared policy in the module.
- **stacked branch**: W1's branch starts from R1's ticket branch (not
  from `main`) because both tickets write
  `Sources/RVEngine/ParseFilesystemWriters.swift`.

## 3. Requirements, Constraints & Guidelines

### R1 — redirect-lexer unification

- **REQ-001** [R1]: One redirect-operator lexer module in exactly one
  new file (`Sources/RVEngine/RedirectOperatorLexer.swift`, or the
  equivalent single new file if repo conventions demand a different
  name) owns the single operator table. All three call sites consume it:
  `ParseFilesystemCreateRead.swift` (`redirectTargets :236-272`,
  `isRedirectOperator :278-289`, `attachedRedirectTarget :291-346`,
  `stripRedirectFdDigits :350-358`), `NormalizeSegments.swift`
  (`tokenizeFilesystemWords`/`splitMidWordRedirects :51-72`,
  `splitRedirectPieces`/`redirectRunEnd :74-146`), and
  `ParseFilesystemWriters.swift` (`stripWriterRedirectWords` +
  `stripWriterAttachedWord :391-439`).
- **REQ-002** [R1]: Entry points consumed outside R1's write set keep
  their exact signatures and behavior, reimplemented over the lexer:
  `isRedirectOperator` (called by `Normalize.swift:297` sed-script
  masking and pinned by `ParseFilesystemCreateReadTests`),
  `isFdDup` (pinned by tests), `stripWriterRedirectWords` (called by
  `CdTracking.swift:90,161` and every writer parser),
  `tokenizeFilesystemWords` / `splitMidWordRedirects` (called by
  `AnalyzeFilesystem.swift`, `CdTracking.swift`, and
  `MidWordRedirectSplitTests` / `CdTrackingTests`).
- **REQ-003** [R1]: Delete the superseded private copies. No dead
  remnants, no compatibility shims, no re-export aliases. Private
  helpers (`attachedRedirectTarget`, `stripRedirectFdDigits`,
  `splitRedirectPieces`, `redirectRunEnd`, `stripWriterAttachedWord`,
  `writerInputSeparators`) are replaced by lexer calls; the Writers
  stripper uses structured lexing instead of `contains(">&")` /
  `contains("<&")` substring tests.
- **REQ-004** [R1]: Operator-coverage parity per call site. The union
  lives in one table, but each caller's policy keeps its exact reading:
  `isRedirectOperator` still excludes `<&` (input-dups never name a
  destination); the splitter still handles `<<`, `<<<`, `<<-`, `<>`,
  `<&` with dup/close gluing; the Writers stripper still drops
  input/heredoc operators WITHOUT target-eating (target stays an
  operand) and drops attached input words and fd dups/closes whole.
- **REQ-005** [R1]: New unit tests at the lexer interface cover
  classification, splitting, and stripping (see section 6).

### M1 — per-host settings-merge unification

- **REQ-006** [M1]: One shared merge/inspect policy module (at most one
  new file under `Sources/RVCLI/Setup/`), parameterized over a per-host
  descriptor (layout, matchers, hook type, timeout, fingerprints,
  command builders/parsers, stale-legacy predicate), concentrates the
  occupancy-trap merge/inspect policy duplicated in
  `hookCommand`/`adapterPath(in:)`/`bakedRvPath(in:)`/
  `matchesCurrentHook` (`ClaudeSettingsMerge.swift:40-90` vs
  `AntigravityHooksMerge.swift:40-82`),
  `inspectionState(of:)` (`:187-232` vs `:169-199`),
  `writeClaudeSettings` vs `writeAntigravityHooks`
  (`SetupHostWrites.swift:288-342` vs `:345-399`), and `inspectClaude`
  vs `inspectAntigravity`
  (`HostAdapterInstallation.swift:245-276` vs `:278-309`).
- **REQ-007** [M1]: Per-host enums keep every entry point consumed
  outside M1's write set (`HostWiring.swift` merge/file-tools calls,
  `SetupUninstall.swift` uninstall/adapter-path calls, and the
  `HostHooksMergeTests`, `AntigravityHooksMergeTests`, `DoctorTests`,
  `SetupTests`, `HostWiringTests`, `ResidualLinux*` suites):
  `merge`, `uninstall`, `inspectionState(of:)`, `adapterPath(...)`,
  `hasFileToolMatchers`, `rvEntry`, `wiringDescriptor`, `matchers`, and
  both error enums (`ClaudeSettingsMergeError`,
  `AntigravityHooksMergeError` with current cases). They become thin
  delegates over the shared module; the error types stay distinct
  (tests pin each; `SetupHostWrites` maps each to its own
  `SetupError.hostHookOccupiedNeedsForce` host).
- **REQ-008** [M1]: The write branches keep their signatures (pinned by
  `SetupTests` and `ResidualLinuxEdgesTests`) with bodies delegating to
  one shared write helper; the private inspect branches
  (`inspectClaude`/`inspectAntigravity`) collapse into one
  parameterized inspect.
- **REQ-009** [M1]: The stale-legacy divergence stays per-host via the
  descriptor predicate: Claude's v1 `hook --host claude` outdated arm
  remains Claude-only; Antigravity's outdated state remains
  matcher-coverage-only. Timeouts (90 vs 10), layouts (nested vs
  grouped), fingerprints, and file names stay per-host data.
- **REQ-010** [M1]: New unit tests parameterize occupancy/outdated/wired
  cases over both hosts at the shared interface (see section 6).

### W1 — writer flag-scan rebuild over FlagToken events

- **REQ-011** [W1]: The writer scan is rebuilt as a thin policy layer
  over `FlagToken` events. Grammar mechanics — long unique-prefix
  resolution, short-cluster walk, `--` terminator, `-x=y` handling,
  dangling values — come from `FlagScan`/`FlagToken`
  (`FlagScan.swift:52-104` scan loop, `:136-153` short-value
  consumption, `:257-268` unique-prefix resolution); the parallel
  writer grammar (`scanWriterArgs :75-120`, `resolveWriterLong :126-143`
  including its `extractOutputValues` `:1338-1346` and sed `:1595`
  uses, `scanLongWriterFlag :145-191`,
  `scanShortWriterCluster :198-247`, `-t` pre-scan cluster walk
  `:264-340`) is deleted, not moved.
- **REQ-012** [W1]: Writer soundness policy is preserved exactly — every
  rule in the `ParseFilesystemWriters.swift:13-37` file header
  (unknown shorts fail; unknown `=`-longs skipped; unknown bare longs
  record candidates; `--no-*` bare by convention; conflicted shorts
  consume attached rest only; count-gated bare-vs-value calls;
  `--help`/`--version` return nil; redirect-target union; every `-t`
  override evaluates with `overrideAmbiguous` kept; BSD `install -D`
  collection with GNU-bare re-read) plus the `extractOutputValues`
  exact-output collection rules (`:1315-1322`).
- **REQ-013** [W1]: Entry points consumed outside W1's write set keep
  their exact signatures and behavior: `extractTargetDirectory`
  (called by `parseMv` in `ParseFilesystemMutations.swift:138`),
  `extractTargetDirectory` / `extractInstallDValues` (pinned directly
  by `ParseFilesystemWritersTests`), and the `WriterScan` shape
  (`operands`, `flagValues`, `candidates`, `bareShortHits`,
  `bareLongHits`, `sawHelp`, `failed`). `help`/`version` long
  resolution stays in the writer policy layer:
  `FlagValueSpec.resolveLong` deliberately leaves them unresolved, so
  the policy layer must reproduce `resolveWriterLong`'s help/version
  behavior (exact or unique-prefix, never a write) rather than inheriting
  the bare `FlagScan` reading.
- **REQ-014** [W1]: `FlagScan.swift` / `FlagToken.swift` changes are
  additive only. Every existing consumer (`parseRm` via
  `splitFlagTerminator`, all git/fs parsers) keeps its exact reading;
  `ShellPipelineParseTests` and the git/fs suites pass unmodified. Any
  new `FlagValueSpec` knob the writer policy needs must default to
  current behavior for existing specs.
- **REQ-015** [W1]: New unit tests at the writer-policy seam cover the
  grammar/policy split (see section 6).

### House rules (all tickets)

- **CON-001**: Behavior-preserving. No semantic change to any parse,
  merge, inspect, or write path, error mapping, or logging.
- **CON-002**: Preserve platform gating exactly. The touched files are
  pure Swift + Foundation already compiling on Linux; no new
  Darwin-only API. Linux-CI parity: CI runs the official Swift 6.4
  Linux tarball plus unfiltered `swift test` on ubuntu-24.04 (see
  `.github/workflows/pr.yml`); there is no Linux toolchain locally,
  so new code mirrors existing guard conventions and stays within
  APIs the touched modules already use.
- **CON-003**: Swift 6.4, strict concurrency clean. No new warnings. No
  `@unchecked Sendable` on new modules. No public API beyond what the
  call sites need (module-internal unless the package demands more).
- **CON-004**: Existing target suites pass unmodified. If a test
  references a removed symbol (via `@testable`), adapt it minimally
  and call it out in the PR body. No test deletions.
- **CON-005**: TDD with failing tests first on every ticket.
- **CON-006**: W1 is stacked on R1: W1's branch starts from R1's ticket
  branch, and W1's PR bases on R1's branch until R1 lands, because both
  tickets write `Sources/RVEngine/ParseFilesystemWriters.swift`. R1 and
  M1 are disjoint (RVEngine vs RVCLI) and may proceed in parallel.
- **GUD-001**: Follow `swift-feature-implementation`: baseline first,
  failing focused tests before the fusion, smallest coherent change.
- **GUD-002**: Each ticket is one PR against this spec. Do not fold a
  second fusion into a ticket's PR.

## 4. Interfaces & Data Contracts

Non-normative sketches; each implementer fits names to repo conventions.
What is normative: one lexer with one operator table (R1), one shared
merge/inspect policy parameterized over a per-host descriptor (M1), and
one flag grammar with a thin writer-policy layer over `FlagToken`
events (W1).

```swift
// R1: one redirect-operator lexer. Pure string functions, no I/O.
enum RedirectOperatorLexer {
    // Classify a standalone word: output-op, input-op, dup/close, or none.
    // Preserves isRedirectOperator's <&-exclusion via the caller's policy.
    static func classify(_ word: String) -> RedirectToken?
    // Split a mid-word token into alternating word/operator pieces,
    // fd digits glued left, dup/close targets glued right.
    static func splitPieces(_ word: String) -> [String]
    // Attached target of an output redirect, or nil for dups/closes.
    static func attachedTarget(_ word: String) -> String?
}

// M1: one shared merge/inspect policy over a per-host descriptor.
struct SettingsMergeDescriptor: Sendable {
    var matchers: [String]
    var hookType: String
    var timeout: Int
    var fingerprint: String
    var wiring: HostWiringDescriptor
    var hookCommand: @Sendable (String, String) -> String
    var adapterPath: @Sendable (String) -> String?
    var bakedRvPath: @Sendable (String) -> String?
    var isStaleLegacy: @Sendable (JSONValue) -> Bool  // Antigravity: always false
}

enum SettingsMergePolicy {
    static func matchesCurrentHook(_ hook: JSONValue, _ host: SettingsMergeDescriptor) -> Bool
    static func inspectionState(of root: [String: JSONValue], _ host: SettingsMergeDescriptor) -> InspectionState
    // Per-host enums keep their InspectionState / error types and delegate.
}

// W1: writer policy over FlagToken events. Grammar from FlagScan;
// unknown-flag soundness stays in the policy layer.
struct WriterPolicy {
    // Fold FlagToken events into the preserved WriterScan shape,
    // applying the file-header soundness rules (candidates, conflicted
    // shorts, help/version, count gating).
    static func fold(_ events: [FlagToken], config: WriterVerbConfig) -> WriterScan
}
```

## 5. Acceptance Criteria

- **AC-001** [R1]: Given the three redirect grammars, When grepping
  `attachedRedirectTarget|redirectRunEnd|splitRedirectPieces` under
  `Sources/`, Then matches exist only in the one new lexer file, and
  `rg 'contains\(">&"\)|contains\("<&"\)' Sources/` returns no matches.
- **AC-002** [R1]: Given `isRedirectOperator`, `isFdDup`,
  `stripWriterRedirectWords`, `tokenizeFilesystemWords`, and
  `splitMidWordRedirects`, When running the existing `RVEngineTests`
  suite unfiltered for that target, Then every pre-existing test
  passes unmodified, including `MidWordRedirectSplitTests`,
  `ParseFilesystemCreateReadTests`,
  `ParseFilesystemWritersTests`, and `CdTrackingTests`.
- **AC-003** [R1]: Given a clean checkout of the R1 branch, When
  running `swift build`, `swift test --filter RVEngineTests`, and
  `Scripts/preflight.sh --quiet` on macOS, Then all pass with no new
  warnings.
- **AC-004** [M1]: Given the two per-host merge modules, When grepping
  the `RV_BINARY=` command construction under
  `Sources/RVCLI/Setup/`, Then exactly one construction site remains
  (in the shared module), both per-host `hookCommand` delegates call
  it, and `rg 'private static func inspect(Claude|Antigravity)' Sources/`
  returns no matches (one parameterized inspect).
- **AC-005** [M1]: Given the existing `RVCLITests` suite, When running
  it unfiltered for that target, Then every pre-existing test passes
  unmodified, including `HostHooksMergeTests`,
  `AntigravityHooksMergeTests`, `HostAdapterInstallationTests`,
  `HostWiringTests`, `DoctorTests`, `SetupTests`, and the
  `ResidualLinux*` suites.
- **AC-006** [M1]: Given a clean checkout of the M1 branch, When
  running `swift build`, `swift test --filter RVCLITests`, and
  `Scripts/preflight.sh --quiet` on macOS, Then all pass with no new
  warnings.
- **AC-007** [W1]: Given the writer scan, When grepping
  `scanLongWriterFlag|scanShortWriterCluster|targetDirectoryTPosition`
  under `Sources/`, Then no private writer-grammar mechanics remain,
  `resolveWriterLong`'s unique-prefix loop delegates to the single
  long-resolution site, and the Writers file consumes `FlagToken`
  events for long/short/`--` mechanics.
- **AC-008** [W1]: Given the `WriterScan` shape and the file-header
  soundness rules, When running the existing `RVEngineTests` suite
  unfiltered for that target, Then every pre-existing test passes
  unmodified, including `ParseFilesystemWritersTests` (with its direct
  `extractTargetDirectory` / `extractInstallDValues` pins),
  `ParseFilesystemMutationsTests` (via `parseMv`'s
  `extractTargetDirectory` call), and `ShellPipelineParseTests`.
- **AC-009** [W1]: Given a clean checkout of the W1 branch (stacked on
  R1), When running `swift build`, `swift test --filter RVEngineTests`,
  and `Scripts/preflight.sh --quiet` on macOS, Then all pass with no
  new warnings.
- **AC-010** [all]: Given any ticket branch, When running full
  `swift test` (unfiltered, as CI does) if time permits, Then it
  passes; CI's Linux `swift test` is the final gate.

## 5b. Tickets (task graph)

| Field | R1 | M1 | W1 |
|---|---|---|---|
| `id` | R1 | M1 | W1 |
| `title` | Unify the triplicated redirect grammar behind one lexer | Unify the per-host settings-merge triplication behind one policy module | Rebuild the writer flag scan as policy over FlagToken events |
| `depends-on` | none | none | R1 (stacked branch: W1 branches from R1's branch) |
| `exclusive-writes` | `Sources/RVEngine/RedirectOperatorLexer.swift` (new; exactly one new source file — if repo conventions demand a different filename, that file instead), `Sources/RVEngine/ParseFilesystemCreateRead.swift`, `Sources/RVEngine/NormalizeSegments.swift`, `Sources/RVEngine/ParseFilesystemWriters.swift`, one new test file under `Tests/RVEngineTests/`. No other files. | `Sources/RVCLI/Setup/ClaudeSettingsMerge.swift`, `Sources/RVCLI/Setup/AntigravityHooksMerge.swift`, `Sources/RVCLI/Setup/SetupHostWrites.swift`, `Sources/RVCLI/Setup/HostAdapterInstallation.swift`, at most one new file under `Sources/RVCLI/Setup/`, one new test file under `Tests/RVCLITests/`. No other files. | `Sources/RVEngine/ParseFilesystemWriters.swift`, `Sources/RVEngine/ShellPipeline/Parse/FlagScan.swift`, `Sources/RVEngine/ShellPipeline/Parse/FlagToken.swift`, one new test file under `Tests/RVEngineTests/`. No other files. |
| `acceptance` | AC-001..AC-003 green; new lexer unit tests fail before / pass after (TDD); PR opened against this spec | AC-004..AC-006 green; new parameterized host tests fail before / pass after (TDD); PR opened against this spec | AC-007..AC-009 green (+AC-010 if time permits); new policy-seam tests fail before / pass after (TDD); PR based on R1's branch, opened against this spec |
| `review-hint` | `>=1500` (`ParseFilesystemWriters.swift` is 1901 LOC) | `101–1499` (largest write is `SetupHostWrites.swift` at 415 LOC) | `>=1500` (`ParseFilesystemWriters.swift` is 1901 LOC at main; re-measure post-R1) |

Frontier: R1 and M1 are ready and may proceed in parallel (disjoint
trees). W1 is blocked until R1's branch exists, then stacks on it.

## 6. Test Automation Strategy

- **Test Levels**: Unit (new: one new test file per ticket at the new
  seam) + existing target suites (`RVEngineTests` for R1/W1,
  `RVCLITests` for M1) as the no-regression gate.
- **Frameworks**: Swift Testing (`import Testing`, `@Test`, `#expect`,
  `@testable import RVEngine` / `RVCLI`), matching each target's
  existing files.
- **New unit cases** (minimum):
  - R1 (lexer): classify every operator in the table (`>`, `>|`,
    `>>`, `>&`, `&>`, `&>>`, `<>`, `<`, `<<`, `<<<`, `<<-`, `<&`)
    with and without fd digits; dup/close vs file-target readings
    (`2>&1` dup, `>&-` close, `>&1b` file `1b`, `>&file` file);
    split gluing (`b>/tmp/x`, `a2>>b`, `a2>&1` keeps `2>&1` glued);
    strip policy (output ops drop with target, input/heredoc ops drop
    without target-eating, attached input words and dups drop whole).
  - M1 (shared policy): occupancy/outdated/wired matrix parameterized
    over both hosts — foreign guard is occupied, tampered command is
    occupied, stale-legacy is outdated (Claude) vs occupied-equivalent
    handling (Antigravity has no legacy arm), partial matchers are
    outdated, full current coverage is wired with baked path;
    `force=false` merge throws the per-host occupied error,
    `force=true` rewrites.
  - W1 (policy seam): `FlagToken`-event folds reproducing the
    file-header rules — unknown short fails, unknown bare long records
    candidate, unknown `=`-long skipped, `--no-*` bare, conflicted
    short attached-only, `--help`/`--version` (exact and unique-prefix)
    set sawHelp, `-t` overrides evaluated with ambiguity flag,
    dangling value fails.
- **Test Data Management**: pure string/JSON fixtures built inline; no
  network, no filesystem writes outside the existing `FileOps` fakes.
- **CI/CD Integration**: repo gate is `Scripts/preflight.sh --quiet` +
  `swift test` (see `.github/workflows/pr.yml`). Each implementer runs
  preflight + their target suite locally; full `swift test` runs if
  time permits (AC-010).
- **Coverage Requirements**: every new symbol at each seam has a direct
  unit test. No coverage theater on untouched parsers or hosts.
- **Performance Testing**: none (cold parse/setup paths; no hot loop).

## 7. Rationale & Context

Each fusion passes the deletion test. R1: deleting any one redirect
copy into a sibling would silently change operator coverage (each copy
handles a different set), proving the grammar is real complexity to
concentrate, not boilerplate to move — one lexer with one operator
table, per-caller policy preserved. M1: deleting either per-host merge
module would just move identical occupancy-trap logic into the survivor,
proving neither copy has independent depth — one policy module over a
per-host descriptor, with the stale-legacy arm as descriptor data since
it genuinely differs. W1: deleting `scanWriterArgs` outright would move
real policy (candidates, conflicted shorts, count gating) into every
`parseCp`/`parseTee`/… body — worse — but deleting only its grammar
core while keeping a thin policy layer over `FlagToken` events
concentrates the grammar in `FlagScan` and leaves soundness policy
where it belongs. W1 stacks on R1 because both rewrite
`ParseFilesystemWriters.swift` (redirect stripping, then flag grammar);
landing R1 first keeps each PR's diff reviewable. All three seams are
in-process (pure string/JSON functions), so no port/adapter work is
needed. Discovery: `/tmp/architecture-review-2026-10-09.html` (cards
2–4), explorer notes `/tmp/arch-explore-engine.md` and
`/tmp/arch-explore-clidomain.md`, all outside the repo.

## 8. Dependencies & External Integrations

None. In-process refactors; no new packages, services, or data sources.

### Technology Platform Dependencies

- **PLT-001**: Swift 6.4 toolchain, macOS 15 SDK for local runs; Linux
  Swift 6.4 for CI parity (no Linux-only APIs; no new Darwin-only
  APIs — the touched modules already compile on Linux).

## 9. Examples & Edge Cases

```swift
// R1: one table, three preserved readings.
RedirectOperatorLexer.classify("2>")    // output-op (isRedirectOperator: true)
RedirectOperatorLexer.classify("<&")    // dup-op (isRedirectOperator: false — caller policy)
RedirectOperatorLexer.splitPieces("a>&1b") // ["a", ">&", "1b"] — FILE 1b, not fd 1
RedirectOperatorLexer.splitPieces("2>&1")  // ["2>&1"] — dup stays glued

// M1: one policy, per-host descriptors.
SettingsMergePolicy.inspectionState(of: staleLegacyRoot, claude)      // .outdated
SettingsMergePolicy.inspectionState(of: partialMatcherRoot, antigravity) // .outdated
SettingsMergePolicy.inspectionState(of: foreignGuardRoot, eitherHost) // .occupied

// W1: grammar from events, policy in the fold.
WriterPolicy.fold([.long(name: "help", value: nil)], config: cp) // sawHelp (policy layer)
WriterPolicy.fold([.shorts(letters: ["z"], value: nil)], config: cp) // failed (unknown short)
```

Edge cases:

- R1: `isRedirectOperator` keeps excluding `<&` even though the table
  contains it (input-dups never name a destination); the sed-script
  mask in `Normalize.swift:297` depends on this exact reading.
  Quoted, ANSI-C, and substitution-carrying words never split; plain
  `$VAR` words do (M-03: `echo hi>$F` reads like the spaced form).
- M1: Claude's v1 `hook --host claude` command contains neither the
  current fingerprint check alone nor a foreign guard — the
  stale-legacy predicate must test legacy-without-current exactly as
  today. The two error types stay distinct; collapsing them would
  force test edits, which CON-004 forbids.
- W1: `FlagValueSpec.resolveLong` leaves `help`/`version` unresolved
  by design while `resolveWriterLong` resolves them (exact or
  unique-prefix); the writer policy layer reproduces the writer
  reading. `mv -StDIR` keeps reading suffix `tDIR` (value short
  blocks `-t`); `-t` after a conflicted short keeps setting
  `overrideAmbiguous`; abbreviated `--targ DIR` overrides keep
  evaluating alongside exact forms.

## 10. Validation Criteria

- Per ticket: its AC range green on its ticket branch (AC-001..AC-003
  for R1, AC-004..AC-006 for M1, AC-007..AC-009 for W1, AC-010 when run).
- `git diff main...<branch> --stat` (W1: `R1-branch...W1-branch
  --stat`) touches only that ticket's exclusive-write paths plus this
  spec file.
- Adversarial review (routed by file size) + final pass clean, fixes
  committed to the ticket branch.
- One PR per ticket: R1 and M1 base `main`; W1 bases R1's branch until
  R1 lands. Each PR body links this spec + its ticket id + review
  skills used.

## 11. Related Specifications / Further Reading

- `spec/spec-architecture-type-system-enums.md` (landed; not relitigated)
- `spec/spec-architecture-engine-composition-door.md` (not relitigated)
- `spec/spec-architecture-rule-identity-ipc-helpers.md` (not relitigated)
- `spec/spec-architecture-spawn-fd-hygiene.md` (sibling fusion spec; not relitigated)
- Discovery report: `/tmp/architecture-review-2026-10-09.html` (outside repo)
- Parked follow-ups (later runs, NOT this spec): JSONL fail-closed
  gate sharing, `HostCodec` deepening, launch-ceremony evidence
  bundling, wire-code mapping move, plugin-list round-trip reuse.
