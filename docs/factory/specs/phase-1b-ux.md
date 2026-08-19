# Phase 1b — UX (T2)

Source of truth: [`docs/factory/PLAN.md`](../PLAN.md). Parity source is DCG **0.11.0** decisions/`rule_id`s, not DCG’s denial box, stderr-rich hook warnings, or Rust renderers. Not ryk. Work only in `~/CodingProjects/rv`.

T2 is the human-facing **block** in Terminal: `rv test` and `rv explain` so an operator can see *why* a command dies and what to do next. The product moment stays “user forgets rv until a block.” Pretty panels exist so that moment is readable. They must never leak into Pi / Grok / OpenCode.

## Goal

Ship pretty, snapshot-stable CLI UX for **TTY human** `rv test` and `rv explain`, plus the presentation stack those commands sit on.

- **Allow is silent** on the host/hook path. No banner, no panel, no “allowed by rv.”
- **Pretty deny / explain / packs** render only on TTY human CLI (`rv test`, `rv explain`). Packs pretty is a view-model + renderer in this ticket; the `rv packs` command stays T9.
- **Voice:** Hooks stay one fact, one next action (`hostDenyText`). `rv test` pretty is a labeled briefing: `Command` plus caret match, then Pack / Pattern / Reason / Explanation / Source, ending in `Result: BLOCKED|ALLOWED|INCOMPLETE`. Wrap at the live TTY width (tests pin 80). Labels dim; pack cyan, pattern yellow, essay titles silver, `Result` red/green. `rv explain` is a nested tree: `RV EXPLAIN` title, uppercase `Decision: DENY|ALLOW|INCOMPLETE`, pack `explanation` with blank section breaks, matched regex, and a day-one Suggestions catalog. No `═══` box, no second command echo, no latency dump, no interactive prompt.
- **Stack:** `RVTheme` + `RVPresentation` + `RVTUI`, driven by a thin `RVCLI` pretty shell. TUI is `reduce` + `render` → `[String]`. No I/O in `reduce`/`render`.
- **Modes:** robot / pretty / browse. Browse is eligible only when both stdin and stdout are TTYs and the process is not `--json` / `--robot` / `--plain` / `CI` / `NO_COLOR`.
- **Gate:** L2 — pretty + deny snapshots green on the T1 SKILL.md / core-pack corpus. Decisions stay T1’s; T2 only renders them.

After T1 is green, T2 may run in a worktree **in parallel with T3**. T2 must not own IPC / XPC / launchd.

## Non-goals

- Hook codecs, host JSON envelopes, Pi `registerMessageRenderer`, OpenCode toast (T4 / T5).
- `rvd`, `rv.ipc.v1`, Unix-socket test transport, launchd plist, `rv service status`, thin XPC client (T3).
- `install.sh`, `rv setup` / `uninstall`, live-dotfile wiring (T6).
- `rv doctor` command (T7). T2 may add a `DoctorViewModel` **type** so Presentation’s public surface matches PLAN; it must not grow a doctor CLI or service probe.
- TTY `allow-once` mint / consume (T8). Deny copy may *name* `rv allow-once` as the next action. Do not invent `RV_BYPASS`. Do not print a fabricated one-time code.
- Remaining catalog packs or `rv packs` as a user command (T9). Day-one packs stay `core.git` + `core.filesystem`.
- Scan, SARIF, heredoc/AST, Mac app, Intel, Linux/Windows, older macOS.
- Evaluating commands (T1 owns `evaluate`). T2 calls T1 in-process.
- Opening a TTY, raw `termios`, alternate screen, or a live key-read loop as an acceptance requirement.
- Copying DCG rich-stderr-on-hook behavior. DCG may paint a box on hook stderr; rv must not.

## Depends on

| Ticket | Why T2 needs it |
|---|---|
| **T0** | `Package.swift` already declares empty `RVPresentation`, `RVTheme`, `RVTUI`, `RVCLI` (+ test targets). `swift test` green on empty modules. Swift style copied into `AGENTS.md` / `docs/dev/SWIFT.md`. |
| **T1** | Public value types T2 **consumes, does not redefine**: `Decision`, `Severity`, `PackID`, `RuleID`, `ShellCommand`, `EvaluationRequest`, `EvaluationResult`, `PatternEngine`, `evaluate`. SKILL.md corpus green for `core.git` + `core.filesystem`. |

Do not start T2 product code until T1 corpus is green. Spec authoring may precede that.

T2 evaluates **in-process** through `RVEngine`. It does not wait for T3. If T3 later inserts a thin XPC client in `RVCLI`, that is T3’s merge; T2 must not add the client.

## Parallel / worktree

- **Branch:** `feat/t2-ux`, git worktree from the **T1-green SHA**.
- **Sibling:** T3 on `feat/t3-service` from the **same** base SHA. Agents must not share a working tree.
- **T2 owns:** `RVPresentation`, `RVTheme`, `RVTUI`, CLI pretty (`test`, `explain`, output-mode resolver, pretty/robot writers).
- **T3 owns:** `RVIPC`, `RVService`, launchd, thin XPC client, `rv service status`.
- **`Package.swift`:** PLAN locked resolution 4 — T2 may add `apple/swift-argument-parser` `from: "1.7.0"`, executable product `rv`, and `Sources/RVCLI/main.swift`. Do not add target or product `rvd`. Do not add, remove, or retarget **library** modules. Do not add XPC / Network / Service deps. Do not stop for those assigned `rv` / ArgumentParser lines. If any other graph edit looks required, stop and write a merge plan with T3.
- **CLI namespace:** T2 adds `test` and `explain` only. Do not add `service`, `hook`, `setup`, `doctor`, `packs`, `allow-once`.
- T2 must **not** own IPC / XPC / launchd files, plists, or types.

## View models and render APIs

Hexagonal: engine never imports CLI, TUI, or XPC. Presentation never imports CLI. Theme never decides allow/deny. TUI never opens a TTY.

Value types only. `Sendable`. No `class` in these three modules. No `try!` / `!` on production paths. Prefer `some`; `any` only for mixed renderer lists.

### RVPresentation — view models, no ANSI

Owns deny / explain / packs / doctor **view models**. Must not emit ANSI, box-drawing as a theme concern, `FileHandle`, `ProcessInfo`, or `isatty`.

```swift
public struct DenyViewModel: Equatable, Sendable {
    public var decision: Decision          // .deny only
    public var command: ShellCommand       // full argv; TTY test/explain only
    public var packID: PackID
    public var ruleID: RuleID
    public var fact: String                // one sentence, no trailing tip
    public var nextAction: String          // one imperative
}

public struct TestViewModel: Equatable, Sendable {
    public var command: ShellCommand
    public var span: MatchSpan?            // remapped onto command
    public var matchedLabel: String?       // colon rule_id
    public var packDisplay: String?
    public var patternName: String?
    public var reason: String?             // full pack reason on deny
    public var explanation: String?        // pack essay on deny
    public var source: String?             // "pack" on deny
    public var resultWord: String          // ALLOWED | BLOCKED | INCOMPLETE
    public var resultTone: DecisionTone
}

public enum ExplainStep: Equatable, Sendable {
    enum Scan { case skipped, scanned }
    enum Hit { case none, rule(RuleID) }
    enum Fallthrough { case allow, incomplete }
    case normalize                          // display outcome: prepared
    case quickReject(Scan)
    case safe(Hit)
    case destructive(Hit)
    case `default`(Fallthrough)
    // display: label = stage name; outcome text has no microseconds
}

public struct ExplainViewModel: Equatable, Sendable {
    public var command: ShellCommand
    public var normalized: String
    public var decision: Decision
    public var packID: PackID?
    public var ruleID: RuleID?
    public var patternName: String?
    public var severity: Severity?
    public var fact: String                // allow: "allow"; deny: reason sentence
    public var explanation: String?        // pack essay; pretty explain prints it
    public var regex: String?              // matched pattern text; explain only
    public var nextAction: String?         // nil on allow
    public var steps: [ExplainStep]
    public var suggestions: [ExplainSuggestion]  // day-one catalog; omit group if empty
    // Display seams for TUI (no Decision switch in RVTUI):
    // heading, decisionWord, explainDecisionWord, decisionTone,
    // ruleDisplay, packDisplay, severityDisplay
}

public struct PackRow: Equatable, Sendable {
    public var id: PackID
    public var enabled: Bool
    public var summary: String
}

public struct PacksViewModel: Equatable, Sendable {
    public var rows: [PackRow]
}

public struct DoctorViewModel: Equatable, Sendable {
    // Type stub for PLAN surface. T7 fills fields. T2 must not probe hosts or rvd.
}
```

Builders (pure; take T1 results + copy tables, not clocks):

| Function | Contract |
|---|---|
| `denyViewModel(from: EvaluationResult, command: ShellCommand) -> DenyViewModel?` | `nil` on allow. Never used by hook codecs. |
| `testViewModel(from: EvaluationResult, command: ShellCommand) -> TestViewModel` | Always. Pretty `rv test` frame. |
| `explainViewModel(from: EvaluationResult, command: ShellCommand) -> ExplainViewModel` | Always. Timing omitted or fixed `0` — snapshots must not flake. |
| `explainSteps(from: EvaluationResult) -> [ExplainStep]` | Projects `Decision` + `matched` / `matchedSafe` / `quickRejected` only. Does not re-run the pipeline. |
| `packsViewModel(enabled: [PackID], catalog: [(PackID, String)]) -> PacksViewModel` | Day-one rows: `core.git`, `core.filesystem`. Others off if present. |
| `hostDenyText(from: EvaluationResult, command: ShellCommand) -> String?` | `nil` on `Decision.allow` (medium/low match included). On `Decision.indeterminate`: PLAN incomplete-eval sentence, no pack `rule_id` (“rv could not finish evaluating this command. Run it in Terminal.”). On `Decision.deny`: **one sentence** + `rule_id` + next step. No panel, no ANSI, no second command echo, no redeemable code. T4/T5 consume this string for deny **and** indeterminate. They must still switch on `Decision` — `nil` is not a synonym for allow if the decision was never inspected. |

Voice lock (do not paraphrase in implementation):

| Surface | Allow | Deny |
|---|---|---|
| Hook / host | empty (T4/T5; T2 must not add a pretty hook helper) | `hostDenyText` only |
| `rv test` pretty | `Command:` + `Result: ALLOWED` | `TestViewModel` → Command + caret + Pack/Pattern/Reason/Explanation/Source + `Result: BLOCKED` |
| `rv test` robot | one JSON object, `decision: allow` | one JSON object, `decision: deny` |
| `rv explain` pretty | `RV EXPLAIN` + `Decision: ALLOW` + Command + Pipeline, no next action | `RV EXPLAIN` + `Decision: DENY` + Command + Match (incl. regex) + Explanation + Pipeline + Suggestions + Next |

Canonical deny fact (SKILL.md / DCG reason, not a new essay):

- `git reset --hard` → `git reset --hard destroys uncommitted changes`
- `rm -rf` outside temp → recursive deletion is dangerous (T1’s reason string; do not rewrite)

Canonical next action (T2, T8 not shipped):

```
run it in Terminal, or rv allow-once
```

Canonical `hostDenyText` example:

```
Blocked git reset --hard (core.git/reset-hard). Run it in Terminal, or rv allow-once.
```

`hostDenyText` is the product-moment sentence the agent will later show. Keep it one line. Do not append `Tip:`, alternatives lists, or “execute it manually in a terminal” twice.

### RVTheme — palettes + pure capability detect

Must not contain business rules, pack IDs, or `Decision`.

```swift
public enum OutputMode: Equatable, Sendable {
    case robot
    case pretty
    case browse
}

public enum RequestedMode: Equatable, Sendable {
    case automatic
    case robot
    case pretty
    case browse
}

public struct TTYPair: Equatable, Sendable {
    public var stdinIsTTY: Bool
    public var stdoutIsTTY: Bool
    public var isBrowseEligible: Bool   // both TTY
    public var canCarryColor: Bool      // stdout is TTY
}

public struct OutputForbid: Equatable, Sendable {
    public var json: Bool
    public var robot: Bool
    public var plain: Bool
    public var ci: Bool
    public var noColor: NoColor         // flag / env / termDumb
    public var isBrowseEligible: Bool   // not json/robot/plain/CI/NO_COLOR
    public var canCarryColor: Bool      // not plain/CI/color-off
}

public struct ThemeProbe: Equatable, Sendable {
    public var terminal: TTYPair
    public var forbid: OutputForbid
    public var columns: Int
    // Spec field names stay as computed accessors from the 10-bool initializer:
    // stdinIsTTY, stdoutIsTTY, jsonFlag, robotFlag, plainFlag, noColorFlag,
    // ci, noColorEnv, termDumb
    public var isBrowseEligible: Bool
}

public struct ColorCapability: Equatable, Sendable {
    public var colorsEnabled: Bool
}

public struct Palette: Equatable, Sendable {
    public var colorsEnabled: Bool
    // Named slots only. No Decision switch. CLI/TUI map severity → slot.
    public var reset: String
    public var fact: String
    public var muted: String
    public var deny: String
    public var allow: String
    public var heading: String     // Command / Pack: bold cyan
    public var mark: String        // Match / Suggestions: bold yellow
    public var trace: String       // Pipeline: bold blue
    public var silver: String      // essay titles (Why / Safe / Preview)
    public var regex: RegexInk     // meta / escape / posix name; empty when color off
}
```

Pure functions (no `ProcessInfo`, no `isatty` inside Theme — CLI builds `ThemeProbe`):

- `OutputMode(probe:requested:)` — see next section.
- `ColorCapability(probe:mode:)`
- `Palette(for: ColorCapability)` — when colors are off, every slot is `""` (or identity) so renderers never emit `0x1B`.
- Spec names until T9 (thin wrappers): `resolveOutputMode(probe:requested:)`, `colorCapability(probe:mode:)`, `palette(for:)`, `browseEligible(_:)`.

Robot mode **never** has color. `CI`, `NO_COLOR`, `--plain`, `--no-color`, `TERM=dumb` never have color.

### RVTUI — browse kit, no I/O

Owns the browse kit, `FrameRenderer`, and key map. Must not open a TTY, touch `FileHandle.standardInput`, sleep, or print.

```swift
public protocol FrameRenderer<Model>: Sendable {
    associatedtype Model
    func render(_ model: Model, palette: Palette) -> [String]
}

public struct BrowseState: Equatable, Sendable { /* selection + page; value type */ }
public enum BrowseEvent: Equatable, Sendable { case up, down, enter, quit, noop }

public func reduce(_ state: BrowseState, _ event: BrowseEvent) -> BrowseState
public func render(_ state: BrowseState, palette: Palette) -> [String]
```

- `reduce` and `render` are **pure**. A test that needs a real TTY to prove a frame is in the wrong module.
- Key map is data: `j`/`k`/`↑`/`↓` → `up`/`down`, `q`/`Esc` → `quit`, `Enter` → `enter`. Mapping bytes → `BrowseEvent` may live in TUI as a pure function; reading those bytes is CLI-only and **not** required for T2 acceptance.
- Pretty CLI calls a `FrameRenderer` **once** and writes the lines. It does not enter a read loop.
- T2 does **not** auto-enter browse for `rv test` / `rv explain`. Browse eligibility is proven by the resolver + `reduce`/`render` unit tests.

Renderers T2 must ship (all `render → [String]`, no trailing ANSI when `colorsEnabled == false`):

| Renderer | Model | Used by |
|---|---|---|
| `TestRenderer` | `TestViewModel` | `rv test` pretty |
| `ExplainRenderer` | `ExplainViewModel` | `rv explain`, `rv test --explain` |
| `PacksRenderer` | `PacksViewModel` | snapshots + T9 later |
| `BrowseRenderer` | `BrowseState` | TUI tests only in T2 |

Pretty deny frame (color off, width-stable, command **once**). Labeled briefing on TTY only; hooks still get `hostDenyText` only. No tree, no `Next` row, no interactive prompt:

```
Command: git reset --hard
         ^^^^^^^^^^^^^^^^
         └── Matched: core.git:reset-hard

Pack: core.git
Pattern: reset-hard
Reason: git reset --hard destroys uncommitted changes. Use 'git stash' first.
Explanation: <flattened pack essay>

Source: pack
Result: BLOCKED
```

Pretty allow frame:

```
Command: git status

Result: ALLOWED
```

No banner, no pack list, no next action, no checkmark. Medium/low matches stay `Result: ALLOWED` (optional caret if a span exists). `Matched` uses the colon `rule_id` (`core.git:reset-hard`). Carets sit under the matched span; on a color TTY they are red and `Matched:` is yellow.

Pretty explain is a nested labeled tree. Flush-left root is `RV EXPLAIN` (unstyled). First child is `Decision: DENY|ALLOW|INCOMPLETE` (uppercase; deny red / allow green). Section titles are not one color: Command cyan, Match and Suggestions yellow, Pipeline blue, Explanation unstyled. Children use `├──` / `└──` / `│   ` guides: Command (`Input`), Match on a rule hit (Rule / Pack / Pattern / Regex / Severity / Reason), a top-level Explanation group when the pack essay is present, Pipeline, Suggestions when the day-one catalog has rows for that `rule_id`, and `Next` on deny. Incomplete eval has a top-level Reason leaf and **no** Match group. Pack `explanation` is flattened (wrap markers, `\ - ` bullets), keeps one blank spacer between sections, and is stripped of inline markdown (`**`, backticks, `[text](url)` → `text (url)`). Leave `_` in identifiers (`id_ed25519`, `O_TRUNC`). Match `Regex` is the raw pattern when color is off; on a color TTY it paints metas, escapes, and POSIX class names. Step names stay `normalize`, `quick-reject`, `safe`, `destructive`, `default`. No `μs`. Suggestions are Presentation copy keyed by `rule_id` (preview / safer / workflow / docs). Do not invent a one-time permit code. Do not copy a foreign product name. `rv test` pretty is the briefing above, not the explain tree. Hooks stay `hostDenyText` only — no panel, no regex, no suggestions.

### RVCLI — imperative shell

ArgumentParser. Builds `ThemeProbe` from real stdin/stdout TTY + env + flags. Calls `evaluate` in-process. Picks a renderer. Writes `[String]` to **stdout** (pretty and robot). Does not evaluate via XPC.

| Command | Behavior |
|---|---|
| `rv test <command>` | Evaluate. Exit `0` allow, `1` deny. Pretty or robot per resolver. |
| `rv test --explain <command>` | Same evaluate; `ExplainViewModel`. Same exits as `test`. |
| `rv explain <command>` | Same view model as `test --explain`. Exit `0` even on deny (inspection). |

Flags (global or per-command; all force the resolver): `--json`, `--robot`, `--plain`, `--no-color`. `--json` and `--robot` are aliases for robot mode.

Env the resolver honors: `CI`, `NO_COLOR`, `TERM=dumb`. No `RV_BYPASS`. A `RV_FORMAT=robot|pretty` env is optional; if added it must not override `--json`/`--robot`.

CLI must not import regex engines or parse pack JSON.

## Output modes (robot / pretty / browse)

Three modes. Resolver is the only place mode is chosen.

```
requested --json or --robot  →  robot   (always)
else if requested == browse and browseEligible  →  browse
else if requested == browse and not eligible    →  pretty if stdout TTY else robot
else if requested == pretty                     →  pretty (color still gated)
else if requested == automatic:
      stdout TTY                                 →  pretty
      else                                       →  robot
```

**Browse eligible** if and only if:

1. `stdinIsTTY && stdoutIsTTY`
2. not `--json`
3. not `--robot`
4. not `--plain`
5. not `CI`
6. not `NO_COLOR`

`TERM=dumb` and `--no-color` disable **color**, not browse eligibility, unless `--plain` / `CI` / `NO_COLOR` already fired. Locked PLAN text groups `NO_COLOR` with the browse forbid list — honor that: `NO_COLOR` ⇒ not browse eligible.

T2 CLI default `requested` is `.automatic`. T2 CLI **never** requests `.browse`. A future command may; the kit and gate must already be correct.

| Context | Mode | Color | Notes |
|---|---|---|---|
| `rv test` in Terminal | pretty | on | Human block |
| `rv test --plain` / `NO_COLOR` / `CI` | pretty or robot per table | off | No ESC `0x1B` |
| `rv test --json` / `--robot` | robot | off | One JSON object on stdout |
| Piped stdout | robot | off | Scripts |
| Both TTYs, no forbid flags | browse *eligible* | on | T2 does not enter it |
| Pi / Grok / OpenCode hook | **not a T2 mode** | — | T4/T5 emit host JSON + `hostDenyText`. Zero pretty panels. |

Robot schema is **rv-owned**, not DCG `schema_version` 3:

```json
{"schema":"rv.test.v1","decision":"allow"}
```

```json
{"schema":"rv.test.v1","decision":"deny","pack_id":"core.git","rule_id":"core.git:reset-hard","reason":"git reset --hard destroys uncommitted changes"}
```

Allow robot payload stays minimal (no banner fields). Deny robot may include `command` because the operator passed it to `rv test`. Do not log that JSON to `os_log`.

Hook allow remains empty stdout — T4/T5. T2 must not add `prettyHookAllow` / `prettyHookDeny`.

## Snapshot fixtures

Checked-in goldens under `Fixtures/snapshots/phase-1b/`. Render with a **fixed** `ThemeProbe` (no real TTY), `colorsEnabled == false`, width 80. Compare `[String].joined(separator: "\n")` (trim one trailing newline). Decisions must match T1 corpus `rule_id`s.

| File | Input | Assert |
|---|---|---|
| `pretty-deny-git-reset-hard.txt` | `git reset --hard` | `Command`, caret, `Matched: core.git:reset-hard`, Pack/Pattern/Reason/Explanation/Source, `Result: BLOCKED` |
| `pretty-deny-rm-rf.txt` | T1 filesystem deny (e.g. `rm -rf ./src`, not a temp path) | `Matched: core.filesystem:rm-rf-general` + pack essay + `Result: BLOCKED` |
| `pretty-allow-git-status.txt` | `git status` | `Command: git status` + `Result: ALLOWED` |
| `pretty-explain-git-reset-hard.txt` | explain same deny | `RV EXPLAIN`, `Decision: DENY`, Match includes regex, top-level Explanation + Suggestions; no `μs` |
| `pretty-explain-git-status.txt` | explain allow | `RV EXPLAIN`, `Decision: ALLOW`, Command, steps, **no** next action |
| `pretty-packs-day-one.txt` | day-one catalog | `core.git` + `core.filesystem` enabled; no extra default-on packs |
| `robot-allow-git-status.json` | `rv test --robot` | `rv.test.v1` + `allow` |
| `robot-deny-git-reset-hard.json` | `rv test --robot` | `deny` + `pack_id` + `rule_id` + reason; parse as JSON |
| `host-deny-text-git-reset-hard.txt` | `hostDenyText` | one line; contains `core.git/reset-hard` and `rv allow-once`; no box chars |
| `nocolor-deny-no-esc.txt` | pretty deny with `NO_COLOR` / `colorsEnabled == false` | **zero** `0x1B` bytes |

Also assert (tests, not extra files): `hostDenyText` never contains `═`, `┌`, or CSI sequences; pretty allow never contains `BLOCKED` / `deny`; robot allow has no `reason` banner.

Corpus overlap: every SKILL.md deny T1 already pins must have a pretty deny snapshot **or** share the deny renderer via a table-driven test that checks `rule_id` + fact + next action. Do not invent new verdicts.

## Files to create

Fill T0’s empty targets. Do not create `RVIPC` / `RVService` / launchd / hook sources.

```
Sources/RVPresentation/DenyViewModel.swift
Sources/RVPresentation/ExplainViewModel.swift
Sources/RVPresentation/PacksViewModel.swift
Sources/RVPresentation/DoctorViewModel.swift
Sources/RVPresentation/HostDenyText.swift
Sources/RVTheme/OutputMode.swift
Sources/RVTheme/ThemeProbe.swift
Sources/RVTheme/ColorCapability.swift
Sources/RVTheme/Palette.swift
Sources/RVTUI/FrameRenderer.swift
Sources/RVTUI/BrowseState.swift
Sources/RVTUI/Reduce.swift
Sources/RVTUI/Render.swift
Sources/RVTUI/KeyMap.swift
Sources/RVTUI/TestRenderer.swift
Sources/RVPresentation/TestViewModel.swift
Sources/RVTUI/ExplainRenderer.swift
Sources/RVTUI/PacksRenderer.swift
Sources/RVCLI/OutputModeResolver.swift
Sources/RVCLI/ThemeProbeFactory.swift
Sources/RVCLI/main.swift
Sources/RVCLI/Commands/TestCommand.swift
Sources/RVCLI/Commands/ExplainCommand.swift
Sources/RVCLI/RobotWriter.swift
Sources/RVCLI/PrettyWriter.swift
Tests/RVPresentationTests/DenyViewModelTests.swift
Tests/RVPresentationTests/HostDenyTextTests.swift
Tests/RVThemeTests/OutputModeTests.swift
Tests/RVTUITests/ReduceRenderTests.swift
Tests/RVTUITests/SnapshotTests.swift
Tests/RVCLITests/TestExplainExitTests.swift
Fixtures/snapshots/phase-1b/*.txt
Fixtures/snapshots/phase-1b/*.json
```

If T0 used a single stub file per module, replace the stub; do not leave a second public API. Snapshot loader must not write the operator’s real `HOME`.

## Acceptance

1. `rv test "git reset --hard"` on a TTY-simulated pretty probe prints the deny snapshot and exits `1`.
2. `rv test "git status"` pretty prints `Command: git status` and `Result: ALLOWED`, exits `0`. No banner.
3. `rv explain "git reset --hard"` pretty matches the explain snapshot and exits `0`.
4. `--json` / `--robot` emit `rv.test.v1` JSON only. No ANSI. No pretty panel.
5. `--plain`, `NO_COLOR`, `CI`: no `0x1B` bytes. Browse resolver returns non-browse.
6. Browse eligible only when both stdin+stdout TTY and not `--json`/`--robot`/`--plain`/`CI`/`NO_COLOR`.
7. `reduce` + `render` unit tests cover up/down/quit without a TTY.
8. `hostDenyText` is `nil` on allow (including medium/low match). On indeterminate it is the PLAN incomplete-eval sentence with no pack `rule_id`. On deny it is one sentence + `rule_id` + next step, no redeemable code. No pretty panel helper exists for hooks.
9. T1 SKILL.md corpus still green. T2 did not change verdicts.
10. No new IPC / XPC / launchd files. `Package.swift` library graph unchanged except the PLAN #4 `rv` executable + ArgumentParser pin (or a written merge plan exists).
11. Full command text appears only in TTY `test` / `explain` (and robot JSON the operator requested). Nothing sent to `os_log`.

## Test plan

Slice ladder: L0 compile, then L1 these modules, then L2 snapshots + T1 corpus still green.

| Layer | What |
|---|---|
| L0 | `swift build` with T2 sources in existing targets |
| L1 Theme | Table of `ThemeProbe` × `RequestedMode` → `OutputMode` + `ColorCapability`. Include both-TTY happy path, `--json`, `--robot`, `--plain`, `CI`, `NO_COLOR`, stdin-only TTY, stdout-only TTY, `TERM=dumb`. |
| L1 Presentation | Allow (including medium/low match) → `denyViewModel == nil` and `hostDenyText == nil`; indeterminate → PLAN incomplete-eval sentence, no pack `rule_id`; deny → fact/nextAction; `hostDenyText` one line; explain steps have no timing |
| L1 TUI | `reduce` navigation; `render` line counts; color-off renders contain no `0x1B`; key map is pure |
| L2 snapshots | All files in Snapshot fixtures; byte-compare |
| L2 corpus | Re-run T1 SKILL.md + core-pack fixtures |
| CLI | Exit codes for `test` / `explain`; robot JSON parses; pretty writer joins renderer lines with `\n` |
| Negative | No test opens a TTY to prove a **decision**. No test writes `~/.config/rv` on the operator machine. |

Do not require `dcg` on PATH. `dcg test` agree-rate is not a v1 gate.

## Forbidden

All of PLAN **Forbidden (product law)**, plus T2-specific:

- Pretty panels, ANSI, or box drawing in any hook-shaped API or “host pretty” helper.
- Injecting pretty into Pi / Grok / OpenCode — including “just stderr, like DCG.”
- `RV_BYPASS` or any env the future hook child honors to skip evaluate.
- Allowing because `rvd` is down (T2 never talks to `rvd`).
- I/O, `Date()`, `FileManager`, `ProcessInfo`, or `isatty` inside Presentation / Theme detect / TUI `reduce`/`render`.
- ANSI inside `RVPresentation`.
- Opening a TTY from `RVTUI`.
- Owning or editing IPC / XPC / launchd / `RVService` / `RVIPC`.
- Host Allow button, leftover-ask-as-permit, Pi confirm as deny UX, OpenCode toast.
- Writing foreign hook files or the human’s real `HOME` from tests.
- Persisting raw command text to `os_log` or default history.
- Claiming OS-enforced / Seatbelt. Grade is **hook**.
- Claiming Linux / Windows / macOS 14/15.
- Implementing inside ryk. Installing or rebinding ryk.
- Fighting T3 on the `Package.swift` module graph without a merge plan.
- Shipping `rv packs` / `rv doctor` / `rv allow-once` / `rv service` in this ticket.

## Open questions

1. **Browse entry:** T2 leaves browse as a gated kit. Confirm T9 (`rv packs`) is the first command allowed to request `.browse`, not `rv test`.
2. **`RV_FORMAT`:** Optional env. Skip unless a T0/T3 flag convention needs it.
3. **Robot `command` field on deny:** Included so scripts can correlate; confirm redaction policy if T8/history later logs robot output (history stays off by default).
4. **Exact filesystem deny argv** for `pretty-deny-rm-rf.txt` — use whatever T1’s corpus pins; do not invent a new path class.
5. **`DoctorViewModel` fields** — T7 specifies. T2 keeps an empty stub if T0 already exported the type.
6. **Unicode vs ASCII** — snapshots are ASCII. A later palette may add unicode only when `colorsEnabled && !termDumb`; not a T2 gate.

## Definition of done

T2 is done when a fresh agent can say: **the block is visible in Terminal, invisible on allow, and impossible to inject into a host.**

- `feat/t2-ux` contains Presentation / Theme / TUI / CLI pretty only.
- `rv test` / `rv explain` pretty + robot + host-deny-text snapshots are green (L2).
- Allow pretty is `Command` + `Result: ALLOWED`; hook pretty does not exist.
- Browse cannot turn on unless both stdin+stdout are TTYs and none of `--json` / `--robot` / `--plain` / `CI` / `NO_COLOR` apply.
- `reduce` / `render` are pure and TTY-free.
- T1 corpus still green. Verdicts unchanged.
- No IPC / XPC / launchd ownership. No ryk edits. No `RV_BYPASS`.
- Voice on hook deny: one fact, one next action (`hostDenyText`). Pretty `rv test` is the labeled briefing, not that sentence.
