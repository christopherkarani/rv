# tools/

Scripts that serve the grok harness, not the product binary. Every script here is
agent-facing: it converts a rule that lives in a skill or a factory doc into an
exit-code assertion, so an agent (grok, fx, codex) can prove compliance instead
of claiming it.

Product code lives under `Sources/`. This directory never imports or is imported
by the Swift package.

## Inventory

| Script | Purpose | Source of truth |
|---|---|---|
| `preflight.sh` | Encodes the four grok-skill checklists as 16 exit-code assertions. Run before claiming a ticket is done. | `.grok/skills/*/SKILL.md` preflight sections |
| `extract-packs/extract_core_packs.py` | One-shot extract of day-one pack JSON from a local v0.11.0 checkout. Does not clone or vendor Rust. | `vendor/parity/PIN`, `docs/dev/PARITY.md` |

## preflight.sh

```sh
tools/preflight.sh              # all 16 checks, exit 1 on failure
tools/preflight.sh --quiet      # only print failures and warnings
tools/preflight.sh --check NAME # run one check (see --list)
tools/preflight.sh --list       # list available checks
```

Does not run `swift test`. Pair with the module gate:

```sh
tools/preflight.sh && swift test --filter <Target>Tests
```

### What it checks (and what it does not)

| Check | Catches | Does not |
|---|---|---|
| `value-types` | `class` outside RVService | `struct`/`actor` (correct) |
| `no-isdenied` | boolean `isDenied` | `Decision` enum (correct) |
| `no-force-unwrap` | `try!` in Sources | `try!` in Tests (test-only) |
| `no-exported-import` | new `@_exported` outside RVEngine/RVPacks | known T1 debt (warns) |
| `evaluate-pure` | `Date()`/`FileManager`/`ProcessInfo` in RVEngine | same in other modules (allowed) |
| `no-bypass` | `RV_BYPASS` | |
| `no-ns-home` | `NSHomeDirectory()` | `ProcessInfo.processInfo.environment["HOME"]` (correct) |
| `no-os-log-cmdtext` | os_log/Logger usage (warns for manual review) | can't detect command text in log calls structurally |
| `name-hygiene` | `dcg`/`ryk` in product files | same in `docs/factory/` (allowed), agent dotfiles (warns) |
| `no-xctest` | `import XCTest` | `import Testing` (correct) |
| `no-main-in-library` | `main.swift`/`@main` in library targets | same in `Sources/rv`/`Sources/rvd` (correct) |
| `graph-no-engine-packs` | `import RVPacks` in RVEngine | |
| `corpus-quarantine` | `reset-hard`/`fork-bomb` in quarantine.json | |
| `corpus-landmines` | missing required allow-rows in near-miss.json | |
| `corpus-structure` | malformed corpus JSON | |
| `test-target-isolation` | `*Tests` listing 3+ modules (only RVCorpusTests may) | 2-module test targets (warns) |

Warnings are known debt or pre-existing config, not failures. Exit code is the
failure count.

### Adding a check

1. Add a `check_*` function that returns 0 (pass) or 1 (fail).
2. Register it in `ALL_CHECKS` and `print_list`.
3. If it covers a skill checkbox, cite that skill in the function comment.
4. Test it against the current tree (should pass) and a deliberate violation.

## Planned scripts

These are the next tools to add as the codebase grows. Each has a clear trigger
— when that condition is met, the script should exist.

| Script | Trigger | Purpose |
|---|---|---|
| `swift-6.3.3` | Any agent session that compiles | Puts 6.3.3 first on PATH, execs the real swift. Eliminates the `/usr/bin/swift` 6.2.4 trap. Replaces the manual `export PATH=...` repeated in every skill. |
| `worktree-cleanup.sh` | After each ticket merge | Prunes stale/merged worktrees with `--dry-run`. The repo currently has 21 worktrees, many detached in `/var/folders` temp dirs. |
| `gate.sh` | When CI is added | Runs `preflight.sh` + `swift test --filter <Target>Tests` for changed modules. Wraps the two-step gate into one. |
| `parity-check.sh` | When `dcg` is on PATH (post-v1) | Compares `rv test` vs `dcg test` agree-rate. PLAN says this is the long-term scoreboard, not a v1 gate. |
| `branch-protection.sh` | When parallel tickets resume | Verifies a worktree is on the correct branch for its ticket (e.g. `feat/t2-ux`) and was branched from the right SHA. Prevents two agents sharing a tree. |
| `corpus-coverage.sh` | When new packs are added (T9) | Reports which patterns have deny + near-miss fixtures and which don't. T1 requires both per destructive pattern. |

## Conventions

- Scripts are POSIX bash (`#!/usr/bin/env bash`), not zsh.
- Exit 0 on pass, non-zero on failure. No output to stderr on success.
- `--quiet` suppresses passes, keeps failures and warnings.
- `--list` documents available checks without running them.
- Scripts do not modify the tree. Read-only assertions only.
- Scripts do not require 6.3.3 on PATH — that's the caller's responsibility
  (see `docs/dev/SWIFT.md`). `preflight.sh` works on any Swift version.
