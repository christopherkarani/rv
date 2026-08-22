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
| `swift-6.3.3` | Puts the `.swift-version` toolchain first on `PATH`, then `exec`s `swift`. Eliminates the `/usr/bin/swift` 6.2.x trap. | `.swift-version`, `docs/dev/SWIFT.md` |
| `gate.sh` | `preflight.sh` + filtered `swift test` via `swift-6.3.3`. Explicit filter or infer from git-changed modules (union when multi-module / `Package.swift`). | `AGENTS.md` gate |
| `worktree-cleanup.sh` | Dry-run (default) lists safe stale worktrees; `--apply` prunes only clean detached `/var/folders` temps and clean fully-merged `feat/*`. | Parallel ticket hygiene |
| `extract-packs/extract_core_packs.py` | One-shot extract of day-one pack JSON from a local v0.11.0 checkout. Does not clone or vendor Rust. | `vendor/parity/PIN`, `docs/dev/PARITY.md` |
| `release.sh` | `clang -Os` C hook staged as `rv`; SPM product `rv` staged as `rv-cli`; `rvd`; `strip -x`; `*_RVPacks.bundle`. | `docs/dev/SWIFT.md` (Release artifacts) |

## swift-6.3.3

```sh
tools/swift-6.3.3 --version          # expect Apple Swift version 6.3.3
tools/swift-6.3.3 test --filter RVDomainTests
```

Fails with a clear message if the pinned RELEASE toolchain is missing under
`~/Library/Developer/Toolchains/`.

## gate.sh

```sh
tools/gate.sh                         # preflight + inferred filters
tools/gate.sh --quiet RVEngineTests   # quiet preflight + explicit filter
tools/gate.sh --filter RVCorpusTests
```

Does not run an unfiltered full `swift test` by default. If nothing maps from
git changes, or an empty `--filter` is given, exit 2 — never green after
preflight alone with zero tests.

## worktree-cleanup.sh

```sh
tools/worktree-cleanup.sh             # dry-run: list safe candidates
tools/worktree-cleanup.sh --apply     # prune only the narrow safe set
```

Never removes the primary (main) checkout. Dirty or untracked worktrees are
not candidates; `--apply` refuses `--force` removal.

## preflight.sh

```sh
tools/preflight.sh              # all 16 checks, exit 1 on failure
tools/preflight.sh --quiet      # only print failures and warnings
tools/preflight.sh --check NAME # run one check (see --list)
tools/preflight.sh --list       # list available checks
```

Does not run `swift test`. Prefer the one-shot gate:

```sh
tools/gate.sh --quiet <Target>Tests
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

| Script | Trigger | Purpose |
|---|---|---|
| `parity-check.sh` | When `dcg` is on PATH (post-v1) | Compares `rv test` vs `dcg test` agree-rate. PLAN says this is the long-term scoreboard, not a v1 gate. |
| `branch-protection.sh` | When parallel tickets resume | Verifies a worktree is on the correct branch for its ticket (e.g. `feat/t2-ux`) and was branched from the right SHA. Prevents two agents sharing a tree. |
| `corpus-coverage.sh` | When new packs are added (T9) | Reports which patterns have deny + near-miss fixtures and which don't. T1 requires both per destructive pattern. |

## Conventions

- Scripts are POSIX bash (`#!/usr/bin/env bash`), not zsh. Prefer bash 3.2-safe constructs (macOS `/bin/bash`).
- Exit 0 on pass, non-zero on failure. No output to stderr on success (except tools that intentionally print status).
- `--quiet` suppresses passes, keeps failures and warnings (preflight / gate).
- `--list` documents available checks without running them (preflight).
- `preflight.sh` does not modify the tree. `worktree-cleanup.sh --apply` is the only mutator here.
- Prefer `tools/swift-6.3.3` / `tools/gate.sh` over a manual `export PATH=…xctoolchain…`.
