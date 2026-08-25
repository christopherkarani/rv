# Phase 4+ — Session forensics (`rv scan`)

Fence spec. Not an implement ticket. Not a kickoff.

Locked product map from a grill session. If this file and [`PLAN.md`](../PLAN.md) disagree, PLAN wins. Extractor ladder law also lives in [`phase-4-later.md`](phase-4-later.md) (**Heredoc / AST roadmap**).

Parity source remains DCG **0.11.0** decisions / `rule_id`s. Repo remains `~/CodingProjects/rv`. Never implement inside sibling products. Do not invent `RV_BYPASS`.

**No implement kickoff until** tickets in [`spec/spec-architecture-session-scan.md`](../../../spec/spec-architecture-session-scan.md) § 5b are cut into worktrees with exclusive writes. This fence alone does not authorize product code; the architecture spec is the implementable cut.

## Goal

Offline **host-session forensics**: read known agent session/transcript stores (or a user-supplied folder of known layouts), extract shell command candidates, run them through the same pure `evaluate`, and list where a **deny** would fire — so a human sees destructive commands that already ran.

This is **not**:

- Live hook enforcement (that remains PreToolUse / host adapters)
- Opt-in `RVHistory` (separate Phase 4+ item; history stays off by default)
- Repo/CI file scan (files, staged, git-diff, pre-commit) — later sibling under the same CLI umbrella

## CLI surface

| Form | Meaning |
|---|---|
| `rv scan` | Default = session forensics (this feature) |
| `rv scan sessions` | Explicit alias for the default |
| `rv scan repo` (later) | Repo/CI / file scan — **not** specified here; must not steal session semantics |

Flags (session forensics):

| Flag | Behavior |
|---|---|
| *(no path)* | Auto-discover **known host session roots** (bounded; never recursively crawl `$HOME`) |
| `<path>` | Scan that tree for **known session layouts** only |
| `--include-glob` | Opt-in extra globs under a path (still hard-capped) |
| `--host` | Restrict to one host store kind |
| `--days N` | Time window (default **7**) |
| `--all` | All readable history in scope (still hard-capped) |
| `--packs` | Override pack set (default = **day-one only**: `core.git` + `core.filesystem`) |
| `--show-command` | Show full matching view (default = **redacted** command text) |
| `--all-events` | Do not dedupe (default = dedupe) |
| `--fail-on-findings` | Non-zero exit when any deny finding exists (default exit **0** on successful scan even with findings) |

Output modes: **pretty**, **robot**, **browse** — one finding schema; do not invent a third JSON dialect beside robot.

## Finding semantics

| Rule | Law |
|---|---|
| Detection | Same `RVEngine.evaluate` (normalize → quick-reject → safe → destructive → default). Same `Decision` + `rule_id`. |
| Threshold | **Deny only.** Soft/matched allow and incomplete are out of the default finding list. |
| Packs | Default **day-one**. Optional `--packs` for enabled or explicit IDs. |
| Policy gate | **Off.** Do not honor or spend allow-once grants. Do not consult allowlist for “would allow.” Classify the string only. |
| History | **Do not write** `RVHistory` (or any persist) as a side effect of scan evaluate. |
| Dedupe | Default: collapse by **matching view + `rule_id`**; show count + last-seen. `--all-events` = one row per extracted event. |
| Display | Redacted command by default; `--show-command` for full matching view. Robot/JSON follows the same redaction unless `--show-command`. |
| Post-finding | **Read-only.** List findings. If host adapters look unwired, **one soft nudge** toward `rv setup` / doctor. Scan must not install hooks, enable packs, or mutate config. |

A finding is “this extracted command **denies** under the chosen packs,” not proof of exfiltration, not a new risk taxonomy, and not “the live hook blocked it in that session.”

## Host corpus

- **Broad known stores** for wow: Claude session/transcript layouts plus day-one hosts (Pi, Grok, OpenCode) where stores are readable.
- Additional hosts = additive **store adapters** (discovery + field map → command strings). Not a home spider.
- **Claude hook codecs** and **Claude session-store adapters** may ship on the **same release train** as **parallel tickets** with **no hard code dependency**. Docs must not claim “rv blocked this in Claude” unless that host’s hook adapter is actually wired.

## Extraction (first ship vs later)

| Stage | This feature’s first ship | Later (shared ladder) |
|---|---|---|
| 1. Surface fields | **Yes** — known shell-tool fields only | — |
| 2. Bounded unwrap | No | Yes — forensics then optional live guard |
| 3. Heredoc + AST | No | Yes — forensics first; live guard config-gated / after FP+latency gate |

Law: extractors feed `EvaluationRequest`; they do not replace evaluate. Full ladder for **session forensics and the live destructive-command guard** is in [`phase-4-later.md`](phase-4-later.md) § Heredoc / AST roadmap.

## Bounds and privacy

- No recursive `$HOME` crawl. Known roots + path mode + optional globs only.
- Hard caps on depth, file count, and bytes (exact numbers = implement ticket; must exist).
- No command text in `os_log`.
- No raw secrets in default output; redaction matches history-oriented rules when history exists.
- Scan must not silently enable history, analytics phone-home from host stores, or network pack install.

## Architecture (when implemented)

- Hexagonal: discovery/extract adapters → `EvaluationRequest` → engine. Decisions stay in Domain/Engine.
- CLI/TUI adapter owns formatting (pretty / robot / browse).
- Prefer a dedicated module or package-internal adapter for host session stores; do not put I/O or transcript parsing in `RVEngine`.
- `RVHistory` remains a separate opt-in persist feature — not the source of truth for this scan.

## Non-goals

- Repo/CI / SARIF / pre-commit file scanning (sibling under `rv scan repo` later).
- Secret-exfil “findings” as a second taxonomy (out of first ship; deny-only destructive evaluate only).
- Drafting or installing new packs/policies from findings.
- Mutating hooks, grants, allowlists, or pack enablement from scan.
- Live-HOME tests; Seatbelt/OS-enforcement claims; Linux/Windows claims.
- Replacing or forking evaluate for a “scan risk score.”

## Open (implement-time, not product forks)

- Per-host production path strings (fixtures + adapter comments; no live HOME).
- Whether browse shares the TTY pager used by other operator surfaces.
- Exact `--packs` CLI parsing shape (enabled vs explicit ids) — constrained by architecture REQ-006; finalize in T8.

Hard caps, robot schema `rv.scan.sessions`, and ticket exclusive-writes are locked in [`spec/spec-architecture-session-scan.md`](../../../spec/spec-architecture-session-scan.md).

If an implement prompt cites this fence without following that architecture spec’s § 5b exclusive-writes, refuse and return to `docs/factory/PLAN.md` / `STATUS.md`.

## Definition of done (for this fence only)

- This file exists at `docs/factory/specs/phase-4-session-scan.md`.
- [`phase-4-later.md`](phase-4-later.md) Scan row distinguishes **session forensics** (this file) from **repo/CI** scan.
- Heredoc/AST shared ladder remains in `phase-4-later.md`; first ship of this feature stays surface extraction.
- Implementable architecture + ticket DAG: [`spec/spec-architecture-session-scan.md`](../../../spec/spec-architecture-session-scan.md).
- No product code was required to land this fence.
