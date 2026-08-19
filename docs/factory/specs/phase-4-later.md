# Phase 4+ — After v1

Fence spec. Not an implement ticket. Not a kickoff.

This file records work that is **explicitly after v1**. It does not authorize product code, a worktree, a `feat/phase-4*` branch, or an implement prompt.

**No implement kickoff for Phase 4+ until v1 tickets T0–T9 are done.** If those tickets are still open, treat any Phase 4+ implement request as out of scope and point back at `docs/factory/PLAN.md`.

Parity source remains DCG **0.11.0**. Repo remains `~/CodingProjects/rv`. Never implement inside ryk.

## Goal

Keep v1 small: Pi / Grok / OpenCode **shell** hooks, `core.git` + `core.filesystem`, on-demand `rvd` over `rv.ipc.v1`, macOS 26 Apple Silicon, quiet allow / native deny text.

Name the later surface so agents do not pull it into T0–T9. Name the contracts that must stay stable so later work is an additive client, pack-policy, or codec — not a rewrite.

v1 is done when T0–T9 meet their gates. Phase 4+ does not start because a later feature looks easy.

## Explicitly out of v1

These are later. They are not v1 gates, not T0–T9 acceptance, and not implied by “parity with DCG.”

| Later item | What it is | What v1 does instead |
|---|---|---|
| Remaining packs enabled-by-default | Policy decision to turn the rest of the catalog on for new installs | T9 imports remaining pack JSON **disabled**. Day-one packs stay `core.git` + `core.filesystem` only |
| Claude / Codex / etc. | Additional host codecs and setup writers (Claude Code, Codex, Gemini, Copilot, Cursor, Hermes, Antigravity, and any other DCG-shaped host) | Hosts are **Pi, Grok, OpenCode** shell/command tools only |
| Scan | `rv scan` (files, staged, git-diff, pre-commit / CI) | No scan command. Hook evaluates the command the agent proposed, not the repo |
| MCP | Hooking MCP / Read / Edit tools, **or** shipping an rv MCP server | Shell events only. No Read / Edit / MCP |
| Heredoc / AST | In-hook or scan-time heredoc / `python -c` / `bash -c` extraction and language-aware matching | Normalize + pack patterns on the command string. No AST pipeline |
| SARIF | Real SARIF 2.1.0 (or a deliberate alias policy) for CI | No SARIF. Robot / pretty / browse only |
| Mac app | SwiftUI (or other AppKit) companion: packs, doctor, allow-once, explain | `rvd` is in v1. The app is not. CLI / TTY is the human surface |
| Intel | `x86_64-apple-macos` as a claimed target | Apple Silicon only |
| Older macOS | Claimed 14 / 15 (or other) matrix | **macOS 26** only. Do not claim 14 / 15 |
| History on-by-choice | Optional `RVHistory` persist of evaluations after an explicit enable | History **off**. No default store. Full command only in TTY `explain` / `test` |
| Homebrew | Formula / tap / bottle; `brew install rv && rv setup` | v1 install is **curl only** (`install.sh` → `$HOME/.local/bin`). T6 must not add a formula |

Also later, not v1:

- `dcg test` vs `rv test` agree-rate as a ship gate (long-term scoreboard only; do not block v1 on `dcg` being on PATH).
- Linux / Windows runtimes (catalog may hold those pack *patterns* as data; do not claim those OSes).
- KeepAlive / always-on daemon (v1 `rvd` is on-demand, idle-exit ~5m).
- Pi confirm / Allow UI / leftover-ask-as-permit. Display-only Pi deny card and OpenCode toast are v1.
- License choice (still deferred).
- Homebrew formula / tap / bottle (v1 is curl only).

Windows / Linux pack JSON in the catalog is data, not a platform claim.

## Why these wait

Each item below is real DCG-shaped work. Pulling any of it into v1 breaks the day-one win: a fast XPC-backed shell hook that blocks `git reset --hard` on Pi / Grok / OpenCode, then stays quiet.

- **Remaining packs enabled-by-default.** T9’s job is a disabled catalog plus `rv packs`. Flipping defaults is a product decision (false-positive rate, deny UX, doctor noise). Doing it during import mixes “data is present” with “policy is on.”
- **Claude / Codex / etc.** Each host is its own stdin JSON, exit-code, and deny-shape contract. v1 already serializes Grok then Pi then OpenCode (T4 → T5). More codecs before those fixtures are green multiplies hook bugs and setup writers. Codex in particular rejects unknown deny fields; that is a later codec, not a reason to change v1 deny text.
- **Scan.** Scan is a file/CI product: extractors, path filters, fail-on severity, pre-commit install. It is not the hook. Shipping it in v1 invents a second evaluation driver before the first hook contract is proven.
- **MCP.** Read / Edit / MCP events are not shell. They need new codecs, a wider threat story, and a clear “what rv is not” rewrite. v1 is shell-only so the hook path stays one shape.
- **Heredoc / AST.** Bounded extract + parse + inner-shell recursion is a latency and false-positive program. v1’s engine is normalize → quick-reject → safe → destructive → default allow on the command string. AST work must not become a T1 corpus blocker.
- **SARIF.** SARIF is a CI report schema. v1 output modes are robot / pretty / browse. Teaching every command a `sarif` alias (or a real SARIF emitter) before `rv scan` exists is wasted surface.
- **Mac app.** The plan already made IPC app-ready. Building SwiftUI before T3’s `evaluate` / fallback / `rv service status` are real creates a second client against a moving contract.
- **Intel / older macOS.** A claimed matrix is test hardware, install artifacts, and support. v1 is macOS 26 Apple Silicon so “it runs here” is one sentence.
- **History on-by-choice.** Persist is a privacy program (redaction, retention, path, enable UX). Shipping a default-on store in v1 violates the privacy law below. The module can exist later; the default cannot flip casually.

v1 also refuses work that is easy to disguise as “later polish”: `RV_BYPASS`, allow-because-XPC-missed, foreign hook writes, live-HOME tests, telemetry, Seatbelt claims, or implementing inside ryk. Those stay forbidden after v1 too.

## Contracts that must stay stable so later work is cheap

Later features plug in. They do not fork the product.

1. **One IPC: `rv.ipc.v1`.** The Mac app uses this contract. Do not invent a second IPC, a second Codable surface, a private app-only XPC protocol, or a SwiftUI-shaped request type. Add methods by versioning `rv.ipc.v1` (or a later `rv.ipc.v2` that the app and CLI both speak) — never “app IPC” vs “hook IPC.”
2. **v1 IPC verbs stay.** `evaluate`, `explain`, `classify`, `listPacks`, `setPackEnabled`, `allowOnce.consume`, `doctorSnapshot`. Unix socket remains **tests only**. Production transport stays XPC (`dev.rv.evaluate`).
3. **Hexagonal law.** Engine never imports CLI, TUI, XPC, or SwiftUI. Domain stays I/O-free. A Mac app, MCP server, or `rv scan` is another adapter. `RVHistory` must not become the place decisions are made.
4. **Evaluation order (DCG).** normalize → quick-reject → safe patterns first → destructive → default allow. Heredoc / AST / scan extractors, when they exist, feed `EvaluationRequest` — they do not replace this order.
5. **Packs are data.** Catalog JSON, enable/disable in `RVPacks` / `RVPolicy`. Do not explode the remaining packs into 99 Swift files. T9’s disabled import is the later enable switch.
6. **Identity and files.** Name `rv` / `rvd`, prefix `RV_`, config `~/.config/rv/`. Setup mutates only rv-owned files. Uninstall removes only rv files. No ryk special-case. No `RV_BYPASS` ever.
7. **Host codecs live in `RVHooks`.** New hosts are new codecs + fixtures, not a second hook runtime. v1 codecs stay Pi / Grok / OpenCode shell events.
8. **Deny UX law.** Allow is silent. Hook deny is native host text (one sentence + `rule_id` + next step). Pi may show a display-only transcript card; the block path is still `{ block: true, reason }`. OpenCode may show a display-only TUI toast; the block path is still `throw new Error(reason)`. Pretty panels stay TTY `rv test` / `explain` / human CLI. Later hosts must not require a renderer or toast to be correct.
9. **Unlock law.** Terminal, or `rv allow-once <code>` in a TTY. No host Allow button. The app, if built, is another client of `allowOnce.consume` — not a new permit channel.
10. **Fallback law.** `rvd` down or version-skewed → in-process evaluate. Never allow because XPC missed. The app must not treat “service down” as permit.
11. **Platform claims stay honest.** v1 claims macOS 26 Apple Silicon only. Later Intel / older macOS / Linux / Windows are new claimed targets with tests — not a README edit.
12. **Scoreboard.** v1: same decision + `rule_id` as DCG on the SKILL.md table and the core-pack corpus; hook JSON/exit codes for Grok / Pi / OpenCode shell events. Later agree-rate vs `dcg test` is additive.

## History / privacy constraints that apply even later

These are product law. Phase 4+ does not relax them.

- **History is off by default forever until explicitly enabled.** “On-by-choice” means a user (or a clearly documented config key they set) turns it on. New installs, upgrades, the Mac app, MCP, and scan must not silently start a store. There is no “we’ll default it on once the app ships.”
- **No command text in `os_log`.** Not argv, not the raw line, not a “debug” copy. Service and CLI logs may carry `rule_id`, `pack_id`, decision, host, and timing — not the command.
- **No raw secrets.** When history is on, persist redacted records only. Tokens, keys, passwords, and secret-shaped flags do not hit disk. Full command text remains a TTY `explain` / `test` privilege, not a log or history default.
- **`RVHistory` must not log full argv** as a side effect of evaluate. Evaluate stays pure relative to persistence; history is an explicit, disabled-by-default adapter.
- **No telemetry, SaaS, or network install of packs** — later or not.

Default-off is the privacy feature. The later work is the opt-in path, not a new default.

## Open questions

Do not answer these in T0–T9. Do not “pick a default” in product code to get unblocked.

- After T9, do remaining catalog packs ever become enabled-by-default, or stay opt-in forever (possibly with a documented profile)?
- Host order after Pi / Grok / OpenCode: Claude first, Codex first, or installer-detected only?
- MCP later means: intercept MCP / Read / Edit tool events, ship an rv MCP server, or both?
- Heredoc / AST: in the interactive hook (latency budget), scan-only, or a config-gated hook path?
- SARIF: real SARIF 2.1.0 only on `rv scan` (DCG’s split), with `sarif` as a JSON alias elsewhere — or SARIF nowhere until scan exists?
- History enable UX: config key, `rv history on`, app toggle (still `rv.ipc.v1`), retention, and redaction rules?
- Intel / older macOS: claimed support with CI, or best-effort unsigned extras?
- Mac app shape: menu-bar companion vs settings window — **same IPC either way**?
- When, if ever, does `dcg test` / `rv test` agree-rate become a gate?
- License: still deferred; Phase 4+ does not choose it.

## Definition of done (for this spec only)

This spec is done when all of the following are true. It is **not** done when any later feature exists.

- This file lives at `docs/factory/specs/phase-4-later.md` and is the fence for post-v1 work.
- The later surface is enumerated: remaining-packs default, Claude/Codex/etc., scan, MCP, heredoc/AST, SARIF, Mac app, Intel, older macOS, history on-by-choice.
- Privacy law is written as forever: history off until explicit enable; no command text in `os_log`; no raw secrets.
- Mac app is specified as a client of **the same** `rv.ipc.v1`. A second IPC is forbidden.
- Kickoff rule is written: no Phase 4+ implement work until v1 T0–T9 are done.
- No product code, no ryk edits, and no extra files were required to “start” Phase 4+.

If an implement prompt cites this file before T0–T9 are done, the correct action is to refuse and return to the v1 ticket list in `docs/factory/PLAN.md`.
