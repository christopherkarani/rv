# Phase 1 — Engine (T1)

Locked law: [`docs/factory/PLAN.md`](../PLAN.md). If this spec and PLAN disagree, PLAN wins. Implement only in `~/CodingProjects/rv`. Never implement inside ryk. Do not edit ryk.

Parity source: [Dicklesworthstone/destructive_command_guard](https://github.com/Dicklesworthstone/destructive_command_guard) **0.11.0** (git tag `v0.11.0`, commit `2ed7eeef1ae63d204495f02312c657dd6d9bf73d`). Parity is the same **decision + `rule_id`**, not line-for-line Rust.

This ticket is **L2**: Domain types + a pure `evaluate` + two bundled pack JSON files + a SKILL.md / core-pack corpus that is green.

Day-one win this ticket must prove in-process (no hook, no XPC, no TTY):

```
git reset --hard  →  deny  core.git:reset-hard
```

Confirmed against DCG 0.11.0 `src/packs/core/git.rs`, `tests/corpus/canonical.toml` (`git.destructive.reset-hard`), and `tests/golden_isomorphism.rs`. Not a ryk ID. Not `core.git:force-push`.

## Goal

Give later tickets a real engine they can call without importing CLI, TUI, or XPC.

A fresh agent finishing T1 must leave behind:

1. Value-type Domain APIs: `Decision`, `Severity`, `PackID`, `RuleID`, `ShellCommand`, `EvaluationRequest`, `EvaluationResult`.
2. `RVEngine.evaluate` that is **pure** and runs this order: **normalize → quick-reject → safe patterns first → destructive → default allow**.
3. `PatternEngine` protocol with an **ICU** implementation first.
4. Day-one packs only, as **JSON data**: `core.git` + `core.filesystem`. Not 99 Swift files.
5. An L2 corpus: SKILL.md golden table + deny / near-miss fixtures + a quarantine list for SKILL.md drift and ICU mismatches.
6. `swift test` green, including the corpus. Gate **L2**.

After T1, T2 (pretty `rv test` / `explain`) and T3 (`rvd` + IPC + fallback) may start in **separate worktrees**. They consume this engine. They do not reimplement it.

## Non-goals

- Pretty / robot / browse CLI, ArgumentParser, `@main` `rv` (T2).
- `rvd`, `rv.ipc.v1` transport, launchd, XPC, in-process fallback wiring (T3). T1 evaluate is the function T3 will call; T1 does not speak XPC.
- Host codecs, hook stdin JSON, `install.sh`, `rv setup` / `uninstall`, `rv doctor` (T4–T7).
- Allow-once / allowlist / `RVPolicy` merge (T8).
- Remaining catalog JSON or `rv packs` (T9). Do not import the other 97 packs.
- Heredoc / AST / `python -c` / `bash -c` inner-language matching (Phase 4+). Canonical DCG cases that require `heredoc.*` packs are **out of this corpus**.
- Git alias semantic analysis and `branch-dynamic-token` semantic pass. Those 0.11.0 rules use an unsatisfiable regex `(?!)` plus a Rust parser. Extract the rows as data; do not write the parser.
- Config overrides, confidence scoring, rebase-recovery permits, graduated response, session counts, branch-awareness I/O, history.
- `Date()`, `FileManager`, `ProcessInfo`, TTY detection, `os_log` of command text, network, telemetry.
- Vendoring the DCG Rust tree. Cloning DCG into this repo. Installing or detecting `dcg` / ryk as a T1 requirement.
- License file. Executables `rv` / `rvd`. Third-party SPM dependencies.
- Linux, Windows, Intel, macOS 14/15 claims.

## Depends on

**T0 must be done.** Do not start T1 until `swift test` is green on the empty twelve-module graph, `vendor/parity/PIN` reads `version=0.11.0` / `tag=v0.11.0`, and `docs/dev/PARITY.md` exists.

T1 fills placeholders T0 reserved:

| T0 placeholder | T1 fills |
|---|---|
| `Sources/RVDomain/*.swift` | Real types. Remove the empty-module-only API. |
| `Sources/RVEngine/*.swift` | Normalize, quick-reject, `PatternEngine`, `evaluate`. |
| `Sources/RVPacks/Resources/packs/` | `core.git.json`, `core.filesystem.json`. |
| `Tests/RVEngineTests/Fixtures/corpus/` | SKILL.md table + deny + near-miss + quarantine. |
| `tools/extract-packs/` | Optional one-shot extractor. Committed JSON is the in-repo source of truth. |
| `vendor/parity/EXTRACT.md`, `docs/dev/PARITY.md` | Confirmed 0.11.0 `rule_id`s and extract notes. |

T0 library graph stays. `RVEngine` still depends only on `RVDomain`. `RVEngine` still **must not** import `RVPacks`, CLI, TUI, or XPC. Packs decode JSON into Domain snapshots; Engine evaluates snapshots.

Allowed `Package.swift` delta: add **one** test target, `RVCorpusTests`, depending on `RVDomain`, `RVEngine`, and `RVPacks`. Do not add library products, executables, or SPM dependencies. Do not give `RVEngine` a `RVPacks` dependency.

Toolchain: same as T0 (Apple Silicon, macOS 26, Swift 6.2).

## Parallel / worktree

- **T1 waits for T0.** No `feat/t1-engine` work until T0’s definition of done is true.
- **T1 is serial on the product.** After T0: T1 only, on `main` / `feat/t1-engine`. No parallel sibling until this corpus is green.
- **After T1:** T2 and T3 may run in parallel in **separate git worktrees** from the same base SHA (`feat/t2-ux`, `feat/t3-service`). They must not share a working tree. They must not both edit the `Package.swift` module graph without a merge plan. T2 owns Presentation / Theme / TUI / CLI pretty. T3 owns IPC / Service / launchd / thin client.
- T8 (`feat/t8-allow-once`) and T9 (`feat/t9-catalog`) may also fork after T1. T8 must not invent `RV_BYPASS`. T9 must not enable extra packs by default.
- Do not start T4 before T1. Do not start T6 against the operator’s live dotfiles.

## Types and APIs (EvaluationRequest/Result, Decision, PackID, RuleID, ShellCommand, PatternEngine, evaluate)

All of these are value types in `RVDomain` except `PatternEngine` + `evaluate` (Engine) and JSON loading (Packs). `Sendable` + `Equatable`. No `class`. No boolean `isDenied`. No `try!` / IUO on production paths.

### Newtypes

```swift
public struct PackID: RawRepresentable, Hashable, Sendable {
    public var rawValue: String  // "core.git"
    public init(rawValue: String) { self.rawValue = rawValue } // non-failable; never `!`
    public init?(validating rawValue: String) { /* PLAN regex or nil */ }
}

public struct RuleID: Hashable, Sendable {
    public var pack: PackID
    public var pattern: String   // "reset-hard"
    public var rawValue: String { "\(pack.rawValue):\(pattern)" }
}

public struct ShellCommand: RawRepresentable, Hashable, Sendable {
    public var rawValue: String  // original argv line; never logged
}
```

`PackID` rawValue must match `^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)?$` (dotted child optional: `core.git`, `strict_git`, `package_managers`). Category/preset strings are not PackIDs. Do not use a regex that rejects T9 IDs. `RuleID` is always `pack:pattern` (DCG 0.11.0 shape). Parse `core.git:reset-hard` into those two fields. Do not invent a third segment. No `PackID(rawValue:)!` on production paths.

### Decision and Severity

```swift
public struct Deny: Sendable, Equatable {
    public var ruleID: RuleID
    public var reason: String
}

public enum IndeterminateReason: Sendable, Equatable {
    case budgetExhausted
    case commandTooLarge
    case corePacksUnavailable
}

public enum Decision: Sendable, Equatable {
    case allow
    case deny(Deny)
    case indeterminate(IndeterminateReason)
}

public enum Severity: String, Sendable, Equatable {
    case low, medium, high, critical
}

extension Severity {
    public var blocksByDefault: Bool {
        self == .critical || self == .high
    }
}
```

PLAN wins: do not ship a flat `String` `Decision`. A deny always carries `ruleID` + `reason`.

Locked mapping from DCG 0.11.0 `src/packs/mod.rs`:

| Severity | DCG default mode | rv `Decision` |
|---|---|---|
| `critical`, `high` | deny | `deny` |
| `medium` | warn (does **not** block) | `allow`, with `matched` populated |
| `low` | log (does not block) | `allow`, with `matched` populated |

rv has **no warn-as-permit wire**. A medium match is not a deny. `git stash drop` is `core.git:stash-drop` / medium in 0.11.0 — result is **allow** plus a match, not deny. SKILL.md’s “blocks stash drop” row is stale; quarantine it (see Corpus).

`indeterminate` is for a proven incomplete evaluation (budget exhausted, or command longer than the T1 bound). It is **never** treated as allow by later hook/XPC tickets. T1 tests must assert that. Do not use `Date()` to implement the budget.

### Pack snapshots (Domain values, not files)

Engine never opens a pack file. It receives immutable snapshots:

```swift
public struct NamedPattern: Sendable, Equatable {
    public var name: String
    public var pattern: String
}

public struct DestructiveRule: Sendable, Equatable {
    public var name: String
    public var pattern: String
    public var severity: Severity
    public var reason: String
    public var explanation: String?
}

public struct PackSnapshot: Sendable, Equatable {
    public var id: PackID
    public var name: String
    public var description: String
    public var keywords: [String]
    public var safe: [NamedPattern]
    public var destructive: [DestructiveRule]
}
```

`RVPacks` decodes bundled JSON into `[PackSnapshot]`. That is the only pack I/O.

### EvaluationRequest / EvaluationResult

```swift
public struct EvaluationBudget: Sendable, Equatable {
    public var maxPatternAttempts: Int
}

public struct EvaluationRequest: Sendable, Equatable {
    public var command: ShellCommand
    public var enabledPacks: [PackID]          // T1 day-one helper supplies both
    public var budget: EvaluationBudget?       // nil = unlimited; still cap command bytes
}

public struct RuleMatch: Sendable, Equatable {
    public var ruleID: RuleID
    public var packID: PackID
    public var patternName: String
    public var severity: Severity
    public var reason: String
    public var explanation: String?
}

public struct SafeMatch: Sendable, Equatable {
    public var pack: PackID
    public var name: String
}

public struct EvaluationResult: Sendable, Equatable {
    public var decision: Decision
    public var matched: RuleMatch?             // deny, or allow-from-medium/low
    public var matchedSafe: SafeMatch?         // required named type; no tuples (T3 Codable)
    public var quickRejected: Bool
}
```

Do not add host, cwd, env, TTY, or clock fields to the request. Do not leave `matchedSafe` as a tuple.

T1 command-byte cap (pure, no I/O): **65_536 bytes**. Oversize → `indeterminate`, `quickRejected == false`. Empty / whitespace-only after trim → `allow` (nothing to run), not indeterminate.

Day-one convenience (Engine or Packs test helper, not a policy engine):

```swift
public let dayOnePackIDs: [PackID] = [
    PackID(rawValue: "core.filesystem"),
    PackID(rawValue: "core.git"),
] // non-failable init(rawValue:); never `PackID(rawValue:)!`
```

Enabled-pack order is **lexicographic by `PackID.rawValue`** (both are core-tier). That is `core.filesystem` then `core.git`. A safe match suppresses **only that pack**. It must not suppress the other pack.

### PatternEngine

```swift
public protocol PatternEngine: Sendable {
    associatedtype Compiled: Sendable
    func compile(_ pattern: String) throws -> Compiled
    func matches(_ compiled: Compiled, in text: String) -> Bool
}

public struct ICUPatternEngine: PatternEngine { /* NSRegularExpression / ICU */ }
```

- **ICU first.** Apple `NSRegularExpression` (or an ICU-backed Swift `Regex` wrapper) is the T1 engine. Do not add a Rust `fancy-regex` crate or a second SPM regex library.
- Compile **at pack load / snapshot compile**, not inside the hot `evaluate` loop. `evaluate` matches already-compiled patterns.
- If a pattern fails to compile: quarantine that **pattern name** and every corpus row that needs it; **still load the pack**. Do not retarget the row. Do not rewrite the pattern to pass ICU.
- Never quarantine `core.git:reset-hard` or `core.filesystem:fork-bomb` — those compile failures fail T1 (load error, not a skip).
- Prefer `some PatternEngine` at `evaluate`. Use `any` only if a test injects a fake.

DCG 0.11.0 patterns use POSIX classes (`[:alnum:]`) and lookaheads. Those are ICU-legal. The two semantic git rules use `(?!)` (never matches). Leave them in JSON; ICU will not fire them. That is correct for T1.

### evaluate

```swift
public func evaluate(
    _ request: EvaluationRequest,
    packs: [PackSnapshot],
    patterns: some PatternEngine,
    compiled: CompiledPacks  // engine-owned, compiled with `patterns`
) -> EvaluationResult
```

Exact signature may fold `compiled` into a small `Evaluator` struct that holds `some PatternEngine` + compiled snapshots. The callable name is `evaluate`. It must not read disk, spawn processes, look at `ProcessInfo`, or format ANSI.

**Evaluation order (locked):**

1. **Normalize** the command into a matching view (see below). Keep the original `ShellCommand` for the result; do not require it on the result in T1.
2. **Quick-reject.** If the matching view has no enabled-pack keyword as a real token / keyword hit, return `allow` with `quickRejected == true`. No regex.
3. **Per enabled pack** (lexicographic), **safe patterns first**. A safe hit skips that pack’s destructive list only.
4. **Destructive patterns** for packs that were not safely skipped. First blocking match (critical/high) → `deny` + `RuleMatch`. First medium/low match → remember it and keep scanning for a blocking match; if none, `allow` + that `RuleMatch`.
5. **Default allow.** Unknown commands are allowed. rv is not fail-closed.
6. **Core packs required.** If `core.git` or `core.filesystem` is missing, empty, or failed to load, return `indeterminate(.corePacksUnavailable)`. Do not default-allow `git reset --hard` on an empty registry.

Multi-segment (T1, bounded): split the matching view on top-level `&&`, `||`, `;`, `|` (not inside `'…'` / `"…"`). Evaluate each segment. First `deny` / `indeterminate` wins. If every segment allows, also evaluate the full string once so an anchored `^…$` filesystem safe/deny can still see the whole line. This is the 0.11.0 registry shape (`check_command` then `check_command_single`), not a global “first safe allow wins.”

### Normalize (T1 subset)

Normalize is Engine-owned, pure, and tested. It is **not** the full DCG tokenizer.

T1 must do, in order, on a copy used only for matching:

1. Trim ASCII/Unicode whitespace.
2. Role-aware quote handling (DCG-shaped): strip quote *characters* on argv0 and flag tokens so `"git" reset --hard` and `git reset '--hard'` still deny. Mask only **data-role** quoted arguments (`echo`/`printf` payloads, `git commit -m`, …) so `echo "git reset --hard"` and `git commit -m "fix rm -rf"` cannot match. **Do not** mask `` `…` `` or `$(…)` — 0.11.0 denies those when they contain `git reset --hard`.
3. Iteratively strip a **small** wrapper set, max 32 iterations: `sudo` (optional short flags), `env` + `NAME=value` assignments, `command` except `command -v` / `command -V` (those stay allow / query), leading `\`. Stop when nothing strips.
4. Strip an absolute path on the first executable token only: `/usr/bin/git` → `git`, `/bin/rm` → `rm`. Do not rewrite argument paths.

Do **not** expand `$TMPDIR` / `${TMPDIR}`. 0.11.0 treats those as caller-controlled and **denies** `rm -rf ${TMPDIR}/build` as `core.filesystem:rm-rf-general`. SKILL.md’s “`$TMPDIR` is safe” line is stale.

Out of T1 normalize: `nice` / `timeout` / `mise` / PowerShell / cmd.exe, full heredoc flattening, git-alias expansion, FileManager cwd.

### Quick-reject

Keywords come from the enabled snapshots, not a hard-coded `git|rm` pair.

Day-one keywords, from 0.11.0 pack source:

- `core.git`: `git`
- `core.filesystem`: `rm`, `find`, `unlink`, `truncate`, `shred`, `tar`, `dd`, `mv`, `cp`, `ln`, `rsync`, plus the redirect tokens listed in `src/packs/core/filesystem.rs` (`>/`, `> /`, `>~`, …).

Keyword hits must be **word-boundary / token** aware enough that `digit`, `.gitignore`, and masked quoted data do not enable a pack. SIMD/`memchr` is a DCG optimization, not a T1 requirement. A correct sequential scan is enough.

`ls -la`, `echo hello`, `rg -n pattern README.md` (after data-role quote-mask) → quick-reject allow.

Force-scan `core.filesystem` when the matching view has an empty-paren / function-definition shape (`:(){`, or DCG’s documented `filesystem_semantic_scan_required` trigger) so `core.filesystem:fork-bomb` is not keyword-missed. Never quarantine `fork-bomb`.

## Pack data shape (JSON, not 99 Swift files)

DCG 0.11.0 ships packs as Rust (`src/packs/core/git.rs`, `src/packs/core/filesystem.rs`). rv stores **extracted JSON**. Do not generate one Swift file per rule or per pack beyond a decoder + registry.

Align with DCG’s external pack schema (`docs/pack.schema.yaml` at v0.11.0), plus rv fields T1 needs:

```json
{
  "schema_version": 1,
  "id": "core.git",
  "name": "Core Git",
  "version": "0.11.0",
  "description": "Protects against destructive git commands that can lose uncommitted work, rewrite history, or destroy stashes",
  "enabled_by_default": true,
  "keywords": ["git"],
  "safe_patterns": [
    {
      "name": "checkout-new-branch",
      "pattern": "(?:^|[^[:alnum:]_-])git\\s+(?:\\S+\\s+)*checkout\\s+-b\\s+",
      "description": "Creating a new branch"
    }
  ],
  "destructive_patterns": [
    {
      "name": "reset-hard",
      "pattern": "<extract the 0.11.0 reset-hard regex; schema only — do not copy a homemade walker onto push-force-long>",
      "severity": "critical",
      "description": "git reset --hard destroys uncommitted changes. Use 'git stash' first.",
      "explanation": "git reset --hard discards ALL uncommitted changes…"
    }
  ]
}
```

The `reset-hard` regex above is **schema-only**. Extract the real 0.11.0 pattern strings from source. Do not copy this walker onto `push-force-long` / `push-force-short`.

Rules:

- Filenames: `Sources/RVPacks/Resources/packs/core.git.json` and `core.filesystem.json`. IDs inside must match.
- `enabled_by_default` is `true` only for these two. T9 will add files with `false`.
- `description` on a destructive pattern is the short deny reason (DCG `reason`). `explanation` is the long form (optional; T2 will print it).
- Pattern strings are the 0.11.0 regexes, not Swift-rewritten approximations. If ICU needs a different escape, record it in quarantine — do not “simplify” a pattern to make a test pass.
- Semantic-only 0.11.0 rows stay in JSON with their real names and the unsatisfiable pattern `(?!)`:
  - `core.git:git-alias-semantic-unverified`
  - `core.git:branch-dynamic-token`
  - `core.filesystem:sed-exec-unverified` if present in 0.11.0 source with the same trick
- Do not encode suggestions as executable Swift. If you keep them, use a JSON array of `{ "command", "description" }` and ignore it in T1 evaluate.

### Confirmed 0.11.0 `rule_id`s (do not use the stale names in `dcg-0.11.0-notes.md`)

Those notes guessed `core.git:force-push` and `core.filesystem:rm-rf`. **Wrong for 0.11.0.** Use these, confirmed from `docs/packs/core.md` + pack source at tag `v0.11.0`:

**`core.git` safe:** `checkout-new-branch`, `checkout-orphan`, `restore-staged-long`, `restore-staged-short`, `clean-dry-run-short`, `clean-dry-run-long`.

**`core.git` destructive:** `git-alias-semantic-unverified`, `branch-dynamic-token`, `checkout-discard`, `checkout-ref-discard`, `restore-worktree`, `restore-worktree-explicit`, `reset-hard`, `reset-merge`, `clean-force`, `push-force-long`, `push-force-short`, `branch-force-delete`, `stash-drop`, `stash-clear`.

**`core.filesystem` safe (name checklist):** `rm-rf-tmp`, `rm-fr-tmp`, `rm-rf-var-tmp`, `rm-fr-var-tmp`, `rm-r-f-tmp`, `rm-f-r-tmp`, `rm-r-f-var-tmp`, `rm-f-r-var-tmp`, `rm-recursive-force-tmp`, `rm-force-recursive-tmp`, `rm-recursive-force-var-tmp`, `rm-force-recursive-var-tmp`, `find-delete-tmp`, `find-delete-var-tmp`, `unlink-tmp`, `unlink-var-tmp`, `unlink-help`, `truncate-help`, `truncate-grow`, `truncate-tmp`, `truncate-var-tmp`, `shred-help`, `shred-tmp`, `shred-var-tmp`, `tar-remove-files-tmp`, `tar-remove-files-var-tmp`, `dd-tmp`, `dd-var-tmp`, `dd-help`, `mv-tmp`, `mv-var-tmp`, `mv-help`, `mv-to-trash`.

**`core.filesystem` destructive (name checklist):** `sed-exec-unverified`, `cp-sensitive-then-delete`, `ln-symlink-sensitive-then-delete`, `rsync-sensitive-then-delete`, `rm-rf-root-home`, `rm-r-f-separate-root-home`, `rm-recursive-force-root-home`, `rm-rf-general`, `rm-glob-home`, `rm-r-f-separate`, `rm-recursive-force-long`, `find-delete-root-home`, `find-delete-general`, `unlink-root-home`, `unlink-general`, `truncate-zero-root-home`, `truncate-zero-general`, `shred-root-home`, `shred-general`, `tar-remove-files-root-home`, `tar-remove-files-general`, `dd-overwrite-root-home`, `dd-overwrite-general`, `mv-sensitive-source-root-home`, `mv-dynamic-path`, `redirect-truncate-root-home`, `redirect-truncate-dynamic-path`, `fork-bomb`.

Extract from **source** (`git.rs` / `filesystem.rs`). `docs/packs/core.md` is the name checklist. If source and the doc drift, **source wins**, and you record the drift in `vendor/parity/EXTRACT.md`. A `RVPacksTests` test must assert the committed JSON contains exactly the extracted name set (no silent adds/drops).

### Extractor

Committed JSON is what `swift test` loads. A one-shot script under `tools/extract-packs/` may exist. It must take a local `--source-root` already at tag `v0.11.0`. It must not `git clone`, `curl`, or vendor Rust into rv. T0’s question (“Swift tool vs script”) is resolved: **script or documented hand-extract, not a new SPM executable.**

## Corpus (SKILL.md + deny/near-miss fixtures)

L2 corpus lives at `Tests/RVEngineTests/Fixtures/corpus/` and is executed by `RVCorpusTests` (evaluate + bundled packs). JSON, not TOML — no extra decoder dependency.

```json
{
  "schema_version": 1,
  "source": "dcg-0.11.0",
  "cases": [
    {
      "id": "skill.deny.reset-hard",
      "command": "git reset --hard",
      "expected": "deny",
      "rule_id": "core.git:reset-hard",
      "reason_contains": "destroys uncommitted changes"
    }
  ]
}
```

Allow rows may omit `rule_id`. Deny rows must include `rule_id` + `reason_contains`. Medium-allow rows (stash-drop) include `rule_id` and `"expected": "allow"`.

### Files

| File | Role |
|---|---|
| `skill-table.json` | Every command-like row in 0.11.0 `SKILL.md` “What It Blocks” / “What It ALLOWS” / edge-case tables, with **0.11.0 decisions** (not stale skill prose). |
| `deny.json` | Extra core-pack true positives from 0.11.0 (path prefix, flag order, wrappers, multi-segment). |
| `near-miss.json` | Safe / substring / dry-run / temp-dir / `--force-with-lease` cases that must stay allow. |
| `quarantine.json` | SKILL.md vs 0.11.0 drift, ICU mismatches, semantic-only rules. **Never a silent decision change.** |

### SKILL.md golden table (0.11.0 decisions)

Encode these as `skill-table.json`. Comments here are spec-only.

**Deny (critical/high):**

| Command | `rule_id` | Status |
|---|---|---|
| `git reset --hard` | `core.git:reset-hard` | **Confirmed** 0.11.0 |
| `git reset --hard HEAD~1` | `core.git:reset-hard` | Confirmed |
| `git reset --merge` | `core.git:reset-merge` | Confirmed name |
| `git checkout -- .` / `git checkout -- file.txt` | `core.git:checkout-discard` | Confirmed |
| `git checkout main -- file.txt` | `core.git:checkout-ref-discard` | Confirmed name |
| `git restore file.txt` | `core.git:restore-worktree` | Confirmed |
| `git restore --worktree file.txt` / `git restore -W file.txt` | `core.git:restore-worktree-explicit` | Confirmed |
| `git restore -S -W file.txt` | `core.git:restore-worktree-explicit` | Confirmed (worktree wins) |
| `git clean -f` / `git clean -fd` | `core.git:clean-force` | Confirmed |
| `git push --force` / `git push --force origin main` | `core.git:push-force-long` | Confirmed (not `force-push`) |
| `git push -f origin main` | `core.git:push-force-short` | Confirmed |
| `git branch -d feature` / `-D` / `--delete` / `-f` / `-M` / `-C` | `core.git:branch-force-delete` | Confirmed name |
| `git stash clear` | `core.git:stash-clear` | Confirmed |
| `rm -rf /` / `rm -rf /home/user` | `core.filesystem:rm-rf-root-home` | Confirmed |
| `rm -rf /var/log` / `rm -rf ./src` | `core.filesystem:rm-rf-general` | Confirmed |
| `/usr/bin/git reset --hard` | `core.git:reset-hard` | SKILL.md path table |
| `/usr/local/bin/git checkout -- .` | `core.git:checkout-discard` | SKILL.md path table |
| `/bin/rm -rf /home/user` | `core.filesystem:rm-rf-root-home` | SKILL.md path table |
| `rm -fr /var/log`, `rm -r -f /var/log`, `rm --recursive --force /var/log` | filesystem deny (`rm-fr` / `rm-r-f-separate` / `rm-recursive-force-long` or root-home if path is home) | SKILL.md flag-order table; **verify pattern name against 0.11.0** if a row is ambiguous |

**Allow (safe pattern or default-allow):**

| Command | Why |
|---|---|
| `git status`, `git log`, `git diff`, `git add`, `git commit`, `git push`, `git pull`, `git fetch`, `git stash`, `git stash pop`, `git stash list` | SKILL.md “always safe”; default allow |
| `git checkout -b feature` / `git checkout -b feature/one` | safe `checkout-new-branch` |
| `git checkout --orphan topic` | safe `checkout-orphan` |
| `git restore --staged file.txt` / `git restore -S file.txt` | safe restore-staged-* |
| `git clean -n` / `git clean --dry-run` | safe clean-dry-run-* |
| `git push --force-with-lease` | SKILL.md; 0.11.0 `push-force-long` negative lookahead |
| `rm -rf /tmp/build` / `rm -rf /var/tmp/build` | safe tmp / var-tmp |
| `command -v git` / `command -V git` | 0.11.0 query form; allow |

**Near-miss (must allow):**

| Command | Why |
|---|---|
| `echo "git reset --hard"` | substring / quoted data |
| `rg -n "rm -rf" README.md` | quoted data |
| `git commit -m "fix rm -rf detection"` | quoted data |
| `git commit -m "git push --force"` | data-role quotes; not `push-force-long` |
| `"git" status` | quoted argv0 still git, but safe |
| `ls -la` | quick-reject |
| `git push --force-with-lease` | 0.11.0 `(?![-a-z])` on `--force` |
| `git push --force-with-lease --force-if-includes` | lease form, not `--force` |
| `git push origin feature--force` | branch name is not `--force` |
| `git push origin feature-f` | not `-f` force-push |
| `git push origin main && echo done --force` | later-segment `--force` is not `git push --force` |
| `git restore . --staged` | safe `restore-staged-*` (flag any position) |
| `git restore file.txt --staged` | same |

**Deny near-miss companions (must deny, same `rule_id` as the bare command):**

| Command | `rule_id` |
|---|---|
| `"git" reset --hard` | `core.git:reset-hard` |
| `git reset '--hard'` | `core.git:reset-hard` |
| `sudo git reset --hard` | `core.git:reset-hard` |
| `env GIT_DIR=.git git reset --hard` | `core.git:reset-hard` |
| `command git reset --hard` | `core.git:reset-hard` |
| `\git reset --hard` | `core.git:reset-hard` |
| `git status && git reset --hard` | `core.git:reset-hard` |
| `test -f marker \|\| git reset --hard` | `core.git:reset-hard` |
| `echo ok; git reset --hard` | `core.git:reset-hard` |
| `echo ok \| git reset --hard` | `core.git:reset-hard` |
| `echo $(git reset --hard)` | `core.git:reset-hard` |
| `` echo `git reset --hard` `` | `core.git:reset-hard` |
| `rm -rf /tmp/safe /etc/passwd` | filesystem deny (safe tmp must **not** win on mixed paths) |

### Quarantine (do not silently change decisions)

`quarantine.json` is a first-class fixture. The runner **asserts rv follows `pinned_0_11_0`**, and also asserts we did not “fix” the row by changing `expected` to whatever ICU happened to do.

Known SKILL.md drift vs 0.11.0 (must be listed):

| id | Command | SKILL.md claims | 0.11.0 actual | rv follows |
|---|---|---|---|---|
| `skill.stale.tmpdir-allow` | `rm -rf ${TMPDIR}/build` | allow (temp) | **deny** `core.filesystem:rm-rf-general` (`tests/corpus/canonical.toml` `rm.safe.tmpdir-brace`) | 0.11.0 deny |
| `skill.stale.stash-drop-block` | `git stash drop` | blocked | match `core.git:stash-drop`, severity **medium** → does not block | **allow** + matched rule |
| `skill.counts.34-16` | (meta) | “34 safe / 16 destructive” | real core packs are much larger | ignore counts; extract full packs |

Also quarantine:

- Any ICU compile or match disagreement with a 0.11.0 fixture. Keep the DCG decision + `rule_id`. File the pattern name. Do not retarget.
- Semantic-only rules (`git-alias-semantic-unverified`, `branch-dynamic-token`): no T1 deny expected from regex.
- Heredoc / `python -c` / `bash -c` canonical rows (`heredoc.python:shutil_rmtree`, `heredoc.bash:rm_rf`): **not in T1 corpus**. Do not implement a fake deny.

If a quarantine row starts matching 0.11.0 without a documented extract fix, the suite should fail (stale quarantine), same spirit as DCG `known_failing`.

Hook-malformed JSON cases (`empty`, `{not json`, non-string command, `tool_name: Read`) are **T4/T5**, not T1. T1 evaluates a `ShellCommand`, not a host envelope.

## Files to create

Do not delete or edit `docs/factory/PLAN.md`. Do not write files outside `~/CodingProjects/rv`. Do not touch ryk.

### Domain

```
Sources/RVDomain/PackID.swift
Sources/RVDomain/RuleID.swift
Sources/RVDomain/ShellCommand.swift
Sources/RVDomain/Decision.swift
Sources/RVDomain/Severity.swift
Sources/RVDomain/PackSnapshot.swift
Sources/RVDomain/EvaluationRequest.swift
Sources/RVDomain/EvaluationResult.swift
```

Remove or shrink T0’s empty `public enum RVDomain {}` so the public API is these types. Keep the `arm64` `#error` guard in the module.

### Engine

```
Sources/RVEngine/PatternEngine.swift
Sources/RVEngine/ICUPatternEngine.swift
Sources/RVEngine/Normalize.swift
Sources/RVEngine/QuickReject.swift
Sources/RVEngine/Evaluate.swift
Sources/RVEngine/CompiledPacks.swift
```

### Packs

```
Sources/RVPacks/PackJSON.swift
Sources/RVPacks/PackRegistry.swift
Sources/RVPacks/Resources/packs/core.git.json
Sources/RVPacks/Resources/packs/core.filesystem.json
```

Delete the T0 `.gitkeep` once the JSON exists. Registry in T1 returns only these two snapshots. `enabled_by_default` is true for both.

### Tests + corpus

```
Tests/RVDomainTests/NewtypeTests.swift
Tests/RVEngineTests/NormalizeTests.swift
Tests/RVEngineTests/QuickRejectTests.swift
Tests/RVEngineTests/EvaluateOrderTests.swift
Tests/RVEngineTests/PatternEngineTests.swift
Tests/RVEngineTests/Fixtures/corpus/skill-table.json
Tests/RVEngineTests/Fixtures/corpus/deny.json
Tests/RVEngineTests/Fixtures/corpus/near-miss.json
Tests/RVEngineTests/Fixtures/corpus/quarantine.json
Tests/RVPacksTests/PackLoadTests.swift
Tests/RVCorpusTests/CorpusTests.swift
```

`Package.swift`: add `RVCorpusTests` only.

### Docs the implementer updates (T0 files, T1 content)

- `docs/dev/PARITY.md` — write the confirmed `core.git:reset-hard` day-one line and the SKILL.md drift table.
- `vendor/parity/EXTRACT.md` — source paths, JSON dest, name-set counts, source-wins rule.
- `tools/extract-packs/README.md` — how to regenerate JSON from a local v0.11.0 checkout. Optional script beside it.

Do not add `LICENSE`. Do not vendor `SKILL.md` or `*.rs`.

## Acceptance

T1 passes when all of the following are true:

1. `swift build` and `swift test` are green (L0 + L1 + **L2**).
2. `evaluate("git reset --hard")` with day-one packs returns `Decision.deny` and `matched.ruleID.rawValue == "core.git:reset-hard"`. Same for `git reset --hard HEAD~1` and `/usr/bin/git reset --hard`.
3. Evaluation order is tested: a safe `git checkout -b x` allows; `git checkout -- .` denies `core.git:checkout-discard`; `ls -la` is `quickRejected`; unknown `echo hello` allows.
4. Safe is **per-pack**: a filesystem safe match must not suppress a git deny on another segment (`git reset --hard && rm -rf /tmp/x` denies `core.git:reset-hard`).
5. Default-allow holds. Medium `git stash drop` allows with `core.git:stash-drop` matched, and does not deny.
6. `rm -rf /tmp/build` allows; `rm -rf /var/log` denies `core.filesystem:rm-rf-general`; `rm -rf ${TMPDIR}/build` denies `core.filesystem:rm-rf-general` (not allow).
7. Near-misses in `near-miss.json` all allow. Quoted `echo "git reset --hard"` allows. `"git" reset --hard` and `git reset '--hard'` deny. `` echo `git reset --hard` `` and `echo $(git reset --hard)` deny `core.git:reset-hard`.
7b. Required extra denies: `find ./src -delete` (or `/` root-home variant), `unlink ~/.ssh/id_ed25519`, `> /etc/passwd` / redirect-truncate, `rm -rf ~`, `git push -f`. Canonical fork-bomb denies; a non-bomb function stays allow. `git push -uf` denies only if the extracted 0.11.0 `push-force-short` regex matches; if it does not, record that in `vendor/parity/EXTRACT.md` — do not rewrite the regex.
7c. Missing or unloadable `core.git` / `core.filesystem` → `Decision.indeterminate(.corePacksUnavailable)`. Not allow. Not a fake `deny` rule_id.
7d. Command longer than 65_536 bytes → `Decision.indeterminate(.commandTooLarge)`, `quickRejected == false`. Not allow.
7e. Every non-semantic destructive name in the T1 JSON checklists has a `deny.json` or `skill-table.json` true-positive, except documented `(?!)` rows and named ICU quarantines. Never quarantine `reset-hard` or `fork-bomb`.
7f. Near-miss table rows above (including `--force-with-lease`, `feature--force`, `git commit -m "git push --force"`, `git restore . --staged`) all allow.
8. Only two pack JSON files exist under `Resources/packs`. No third pack. No 99 Swift rule files.
9. `evaluate` production paths contain no `Date()`, `FileManager`, `ProcessInfo`, TTY, XPC, or `os_log` of the command.
10. ICU is the only `PatternEngine` in production. Quarantine file exists and does not rewrite 0.11.0 decisions.
11. `RVEngine` still does not import `RVPacks` / CLI / TUI / Service.
12. Factory law intact: `docs/factory/PLAN.md` unchanged. No ryk edits. No `RV_BYPASS`.

## Test plan

Run on the operator’s Apple Silicon Mac, repo root. Do not point tests at the human’s real `~/.config`. Do not invoke `dcg`, `ryk`, or host CLIs. Do not wire live Grok / Pi / OpenCode.

1. `uname -m` → `arm64`. `swift --version` → 6.2.x.
2. `swift test` (full package).
3. `swift test --filter RVCorpusTests` — L2. Must include `skill.deny.reset-hard`.
4. `swift test --filter EvaluateOrderTests` — order + per-pack safe + default allow + oversize indeterminate.
5. `swift test --filter PackLoadTests` — both JSON files decode; name sets match the checklist (or EXTRACT.md source-wins list); every pattern compiles on ICU.
6. Grep Domain/Engine/Packs `Sources` for `Date(`, `FileManager`, `ProcessInfo`, `isatty`, `NSXPC`, `os_log`. Expect no matches on production paths.
7. Grep for `RV_BYPASS` — none.
8. `ls Sources/RVPacks/Resources/packs` — exactly two `*.json` files.
9. Confirm `Package.swift` still has no executable products and no package dependencies, plus `RVCorpusTests`.

No L3 hook fixtures and no L4 temp-HOME setup in T1.

## Forbidden

From PLAN, and T1-specific:

- `RV_BYPASS` or any env `evaluate` honors to skip matching.
- Allowing because a pattern failed to compile, ICU disagreed, or XPC is absent (XPC is not in this ticket).
- Changing a 0.11.0 decision or `rule_id` to make ICU look correct. Quarantine instead.
- Implementing heredoc/AST, alias semantics, allowlist, allow-once, hooks, XPC, TTY pretty, or extra packs “while we’re here.”
- One Swift type per DCG rule. Packs are JSON.
- Using ryk IDs or the stale `core.git:force-push` / `core.filesystem:rm-rf` names from `docs/factory/references/dcg-0.11.0-notes.md`.
- Claiming OS-enforced / Seatbelt, Linux/Windows/14/15 support, or fail-closed unknown commands.
- Command text in `os_log` or a default history store.
- Implementing inside ryk. Installing or rebinding ryk. Editing `docs/factory/PLAN.md`.
- Starting T2/T3 in the same working tree before this corpus is green.

## Open questions

Resolved in this spec (do not re-litigate):

- `git reset --hard` → **deny** `core.git:reset-hard` (confirmed 0.11.0).
- Packs are JSON extract, not 99 Swift files. Day-one IDs are `core.git` and `core.filesystem`.
- `Decision` is allow / deny / indeterminate. Medium is allow + match.
- `$TMPDIR` and SKILL.md stash-drop prose follow **0.11.0 behavior**, quarantined against the skill text.
- Extractor is a one-shot script or hand-extract, not a new executable product.
- `RVCorpusTests` is the one allowed `Package.swift` add.
- ICU first. Quarantine mismatches.

Still open (later tickets; T1 must not invent product answers):

- Whether T2 `rv test` prints medium matches as a pretty warning (still an allow).
- Exact oversize / budget numbers after T1 if T3 wants a tighter hook deadline (T1’s 65_536 / optional `maxPatternAttempts` may be tuned then **without** changing decisions).
- Remaining filesystem `rule_id` on a few flag-order rows marked verify-against-0.11.0 if extract names differ from the checklist — record in EXTRACT.md, do not guess.

## Definition of done

T1 is done when a cold `swift test` in `~/CodingProjects/rv` is green, `evaluate` is a pure function with the locked order, the only bundled packs are `core.git` and `core.filesystem` JSON, the L2 corpus is green, and **`git reset --hard` denies `core.git:reset-hard`**.

Gate: **L2**. Next: **T2 and T3 may parallel in worktrees.** T4 still waits for T1 (already satisfied once this gate is green). Stop. Do not wire this machine’s live hosts.
