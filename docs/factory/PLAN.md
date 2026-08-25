# rv — locked plan (product + architecture + agent flow)

Source of truth for factory specs, handoff, and implement prompts.
Parity source: [Dicklesworthstone/destructive_command_guard](https://github.com/Dicklesworthstone/destructive_command_guard) **0.11.0**.
Not ryk. Not line-for-line Rust. Repo: `~/CodingProjects/rv` (`christopherkarani/rv`).

## Decisions (locked)

- **Job:** Mac-native destructive-command guard for coding-agent **shell** hooks. Day-one win: Pi / Grok / OpenCode block `git reset --hard` via a fast XPC-backed hook. User forgets rv until a block. Not a ryk replacement. Not a `dcg` binary alias. Mac app later, same `rv.ipc.v1`.
- **Name:** `rv` (CLI/hook client), `rvd` (XPC service). Prefix `RV_`. Config `~/.config/rv/`.
- **Parity source:** DCG **0.11.0** decisions/packs/contracts.
- **Platform v1:** **macOS 26, Apple Silicon only.** No Linux/Windows. No claimed 14/15 matrix. Linux pack *patterns* and the `careful_company_running_windows` egress packs may live in the catalog as data; do not claim those OSes. The `windows.*` OS packs are excluded from the bundled catalog.
- **XPC is in v1.** App is not. `rvd` is **on-demand** LaunchAgent (`dev.rv.evaluate`), idle-exit ~5m. Not KeepAlive by default. Down/skew → **in-process evaluate**. Never allow because XPC missed.
- **Install:** v1 is **curl only.** Hero is `curl -fsSL …/install | sh` (real HOME → `$HOME/.local/bin/{rv,rvd}`, then `rv setup`). No Homebrew formula, tap, bottle, or `post_install` in v1. T6 must not add a formula stub or brew README path. Homebrew is Phase 4+. `install.sh` places binaries and execs `rv setup`. Setup owns the TTY show.
- **Hosts v1:** **Pi, Grok, OpenCode only.** Shell/command tools only. No Read/Edit/MCP.
- **Deny UX:** Native host deny **text** is the block path (one sentence + `rule_id` + next step). Pi also posts a display-only transcript card (`registerMessageRenderer` + `sendMessage`, customType `rv-decision`). OpenCode also shows a display-only TUI toast (`client.tui.showToast`, title `RV · Blocked`). Card and toast are chrome, not the deny. Pi renderer must return `{ render(width) => string[] }`, never a string. OpenCode `throw new Error(reason)` remains the abort. Toast failure must still throw. No host Allow, no confirm, no leftover-ask.
- **Unlock:** Run command in Terminal, or `rv allow-once <code>` in a **TTY**. No host Allow button. **No `RV_BYPASS`.**
- **Day-one packs:** `core.git` + `core.filesystem` only. Rest catalog, off until enabled.
- **Setup mutations:** only rv-owned files. Foreign hooks untouched. Occupied owned name → skip that host (TTY hollow + skip clause; non-TTY one line) unless `rv setup --force` (backup `*.bak`, then rewrite). Uninstall removes only rv files. **No ryk special-case.**
- **Hostless install:** success. TTY closer: `No hosts yet` then `Next  rv setup`. Non-TTY: one line to run `rv setup` after a host exists.
- **Privacy:** no command text in `os_log`. History **off** by default; when on, no raw secrets. Full command only in TTY `explain`/`test`. Anonymous product analytics (installs / DAU / host+pack counters) may run **opt-out** via `RVAnalytics` / PostHog; never command text, paths, or secrets; never from host hook processes.
- **License:** deferred.
- **Repo:** work only in `~/CodingProjects/rv`. Never implement inside ryk.

## What 1:1 means (v1 vs later)

**v1 scoreboard:** same decision + `rule_id` as DCG **0.11.0 engine source** (critical/high → deny; medium/low → allow + match). SKILL.md marketing rows that disagree are quarantine fixtures, not the scoreboard. Hook JSON/exit codes for **Grok / Pi / OpenCode shell events**. Quiet allow, native deny text.

**Later (not v1 gate):** remaining bundled packs enabled-by-default (95 IDs stay in catalog, off; `windows.*` stay excluded), Claude/Codex/etc., scan (session forensics fence `docs/factory/specs/phase-4-session-scan.md`; repo/CI later), MCP, heredoc/AST (shared extract ladder for session forensics **and** the live destructive-command guard — surface → bounded unwrap → heredoc/AST; details in `docs/factory/specs/phase-4-later.md`), SARIF, Mac app, Intel, older macOS, Homebrew.

`dcg test` vs `rv test` agree-rate is the long-term scoreboard when `dcg` is on PATH. Do not block v1 on it.

## Architecture

Hexagonal. Engine never imports CLI, TUI, or XPC. Each module: small public API, `package` internals, own test target, one page in `docs/architecture/MODULES.md`.

| Module | Owns | Must not |
|---|---|---|
| **RVDomain** | `Decision`, `Severity`, `PackID`, `RuleID`, `EvaluationRequest/Result`, Explain pipeline | I/O, TTY, XPC |
| **RVEngine** | normalize, quick-reject, safe then destructive, deadline, `PatternEngine` | pack files, hooks |
| **RVPacks** | registry, bundled JSON, enable/disable | decisions, rendering |
| **RVPolicy** | config merge, allowlist, allow-once | rendering |
| **RVHooks** | **Pi / Grok / OpenCode** Host adapters: shell codecs, Hook mapper/voice, embedded adapter resources | evaluation, setup mutations |
| **RVIPC** | `rv.ipc.v1` Codable | transport details |
| **RVService** | XPC listener, warm registry, launchd | ArgumentParser, SwiftUI |
| **RVPresentation** | deny/explain/packs/doctor view models | ANSI |
| **RVTheme** | palettes, pure capability detect | business rules |
| **RVTUI** | `FrameRenderer` `render` → `[String]` | opening a TTY |
| **RVCLI** | ArgumentParser, output mode, thin XPC client, fallback, Host adapter setup mutations | regex, pack parse |
| **RVHistory** | later; off by default | logging full argv |
| **RVAnalytics** | anonymous install / DAU / product counters (PostHog); opt-out config | command text, paths, secrets; hook-process network |

**Dependency law:** arrows down. A test that needs a TTY to prove a **decision** is in the wrong module.

**Evaluation order (DCG):** normalize → quick-reject → safe patterns first → destructive → default allow.

**PatternEngine:** protocol; ICU first; packs are **data** (JSON extract from DCG), not 99 Swift files. Corpus quarantines mismatches.

**IPC (app-ready, app not built):** `evaluate`, `explain`, `classify`, `listPacks`, `setPackEnabled`, `allowOnce.consume`, `doctorSnapshot`. Unix socket **tests only**.

## Swift style contract

- Value types only in Domain/Engine/Packs/Presentation. `class` only at XPC/`NSObject` `RVService` edge.
- Newtypes: `PackID`, `RuleID`, `ShellCommand`. Closed `Decision` enum. No boolean `isDenied`.
- Small capability protocols (`PatternEngine`, `HostCodec`, `FrameRenderer`). Prefer `some`; `any` only for mixed lists.
- Functional core / imperative shell. Pure `evaluate` (no `Date()` / `FileManager` / `ProcessInfo`).
- Typed errors. `Sendable` + actors for stores. No `try!` / `!` on production paths.
- TUI: `FrameRenderer.render` → `[String]`.

Copy into `AGENTS.md` and `docs/dev/SWIFT.md` at T0.

## UX laws

- Allow: **silent**. No banner on hook allow.
- Deny: host-native reason string is the block path. Pi may show a display-only transcript card. Pretty denial panel only on TTY `rv test` / `explain` / human CLI.
- Two modes: robot / pretty. No browse TUI. `--json`/`--robot` force robot; automatic is pretty when stdout is a TTY, otherwise robot. `--plain`/`CI`/`NO_COLOR`/`TERM=dumb` kill color.
- `rv setup`: no wizard, no pack list, no LaunchAgent row, no questions. TTY pretty plays a short paced ceremony (search → wire hosts → `Hooks wired`). `install.sh` sets `RV_FROM_INSTALL=1` so setup also shows a theatrical download bar and closes with `Install complete, run rv explain "rm -rf" to test`. Slot marks are `◦` / `•` (`Palette.muted` / `Palette.heading`); progress bar uses thin horizontal rules. Occupied stays hollow with a skip clause unless `--force` (backup + rewrite owned name). Hostless: `No hosts yet` / `Next  rv setup`. Non-TTY / `--robot` / `CI`: one line, no ceremony sleeps. Quiet when a second matching run writes nothing.
- `rv uninstall`: removes only rv-owned files. TTY pretty paces host removal (`Removing Hooks` → hollow circles → `✓ Hooks removed` → `Uninstall complete`). Occupied owned names stay hollow with `left occupied`. Closer follows `didRemoveAnything` (same contract as robot): nothing deleted → `Already clean` (still paint occupied slots when present); non-host artifact deletes with no host slots → `Uninstall complete` without a fake host show. Robot: `Uninstall complete.` / `Already clean.` One line, no sleeps.
- Voice: one fact, one next action. Vercel-quiet.

## Slice ladder

1. **L0 compile:** `swift build`
2. **L1 module:** that target’s tests
3. **L2 corpus:** SKILL.md + core pack fixtures
4. **L3 hook contract:** stdin JSON → stdout + exit for Grok, then Pi, then OpenCode
5. **L4 setup:** install/uninstall idempotence on a **temp HOME**

## Tickets (execute in order)

| Ticket | Phase | Outcome | Gate |
|---|---|---|---|
| **T0** | 0 | Repo + `Package.swift` + empty modules + `AGENTS.md` + `swift test` | L0 |
| **T1** | 1 | Domain types + engine + two packs + SKILL.md corpus | L2 |
| **T2** | 1b | `rv test` / `explain` pretty + deny snapshot | L2 |
| **T3** | 1c | `rvd` + IPC + fallback + `rv service status` | L1 + fake XPC |
| **T4** | 1d | Grok shell hook fixture + `rv hook` | L3 |
| **T5** | 1d | Pi + OpenCode shell codecs + fixtures | L3 |
| **T6** | 1d | `install.sh` + `rv setup` / `uninstall` (temp HOME) | L4 |
| **T7** | 1d | `rv doctor` (service + hosts + packs) | L1 |
| **T8** | 3 | TTY `allow-once` | L1 + TTY-gated tests |
| **T9** | 2 | Remaining pack JSON import (disabled) + `rv packs` | L2 |

Do not start T4 before T1. Do not start T6 against the operator’s live dotfiles.

## Parallel / worktree rules

- **T0** is serial. No other ticket starts until `swift test` is green on empty modules.
- After T0: **T1 only** on `main` / `feat/t1-engine`. No parallel sibling until T1 corpus is green.
- After T1: **T2 and T3 may run in parallel** in **separate git worktrees** (`feat/t2-ux`, `feat/t3-service`). They must not both edit `Package.swift` module graph without a merge plan. T2 owns Presentation/Theme/TUI/CLI pretty. T3 owns IPC/Service/launchd/thin client.
- **T4 then T5 are serial** on one worktree (`feat/t4-t5-hooks`). Same `RVHooks` module.
- After T4 fixtures exist: **T6 and T7 may run in parallel worktrees** if T6 owns `install.sh` + setup/uninstall and T7 owns `doctor` only. If doctor needs setup file paths, T7 waits for T6 or reads the T6 spec contract.
- **T8 and T9 may run in parallel worktrees** after T1 (`feat/t8-allow-once`, `feat/t9-catalog`). T8 must not invent `RV_BYPASS`. T9 must not enable extra packs by default.
- Phase 4+ is **not** a v1 kickoff. Spec only; no implement button until v1 ships.

When two agents run in parallel they **must** use git worktrees from the same base SHA. They must not share a working tree.

## Forbidden (product law)

- `RV_BYPASS` or any env the hook child honors to skip evaluate.
- Allowing because `rvd` is down (must in-process evaluate).
- Evaluating against a version-skewed `rvd` (in-process + doctor warn).
- Hooking Read/Edit/MCP in v1.
- Pi renderer as the deny path, Pi confirm/Allow UI, leftover-ask-as-permit, or OpenCode toast as the deny path in v1.
- Host Allow / leftover-ask-as-permit UI.
- Writing foreign hook files. Writing the human’s real HOME from tests.
- Persisting raw command text to os_log or default history.
- Claiming OS-enforced / Seatbelt. Grade is **hook**.
- Claiming Linux/Windows/macOS 14/15 support.
- Command text, paths, or secrets in analytics payloads. Analytics calls from host hook processes. Network install of packs.
- Implementing this product inside ryk.
- Installing or rebinding ryk on this machine.
- Writing the tokens `dcg` or `ryk` into any product file outside `docs/factory/`.

## What rv is not

- Not ryk (no Seatbelt, no policy YAML, no leftover-ask rewrite, no ryk detection).
- Not FM steward.
- Not fail-closed on unknown commands (DCG default-allow).
- Not Linux/Windows/older macOS in v1.
- Not a system daemon. Not KeepAlive by default.
- Not adversarial security. Agents can still edit hook files — say so.

## Locked resolutions (factory)

These close implementer forks. Specs that disagree are wrong. Adversarial FN + known-unknowns (2026-08-17) required this list.

1. **Decision shape.** `Decision` is `allow` | `deny(Deny)` | `indeterminate(IndeterminateReason)`. A `Deny` always has `ruleID` + `reason`. Medium/low matches stay `allow` with `EvaluationResult.matched` set. IPC/robot encode a string discriminator plus optional deny payload. There is no warn case and no boolean `isDenied`.
2. **Scoreboard is DCG 0.11.0 engine source, not SKILL.md marketing.** critical/high → deny. medium/low → allow + match (`git stash drop` is allow, `git stash clear` is deny). `$TMPDIR` is not a safe `rm -rf` prefix. Quarantine stale SKILL.md rows. Never quarantine `core.git:reset-hard`.
3. **PackID.** `^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)?$` — dotted child optional (`core.git`, `strict_git`, `package_managers`). Category/preset strings are not PackIDs. No `PackID(rawValue:)!` on production paths.
4. **Executables.** T0 is library-only. T2 may add ArgumentParser `from: "1.7.0"`, executable `rv`, and `Sources/RVCLI/main.swift`. T3 may add executable `rvd` (T0 did not declare that target). T8/T9 must not add ArgumentParser or `@main`.
5. **T8 vs T2.** Policy types + PolicyGate may start after T1 (parallel with T9). CLI `allow-once` / `allowlist` rebase onto T2.
6. **Miss policy — never allow because evaluation did not finish.**
   - `rvd` down/skew → in-process evaluate (must still deny).
   - `indeterminate` (oversize or budget) → hook **deny** with short hostDenyText, no pack rule_id: “rv could not finish evaluating this command. Run it in Terminal.”
   - Missing `rv` binary (adapter cannot spawn) → hook-grade residual: Pi/OpenCode **block** with a short “rv missing” reason; Grok’s host fail-opens if the process never starts. A **started** `rv` that times out or crashes → Pi/OpenCode **block**. Honor deny JSON regardless of exit code.
7. **Grok deny wire.** `{"decision":"deny","reason":"<hostDenyText>"}` + exit 0. Accept `run_terminal_command` and `run_terminal_cmd`. Empty stdout on allow. Do not emit exit 2. No `block` keyword.
8. **hostDenyText** never includes a redeemable code. Canonical: `Blocked git reset --hard (core.git/reset-hard). Run it in Terminal, or rv allow-once.`
9. **allowOnce.consume** spends a grant `{ command, cwd }`, not a plaintext code. Code redeem is TTY CLI only.
10. **LaunchAgent owner is T6.** `rv setup` writes `$HOME/Library/LaunchAgents/dev.rv.evaluate.plist` from the T3 template, `KeepAlive` false. T3 does not load a live agent. Hooks still work in-process if launchd is down.
11. **Occupied** means the **owned filename** is present and is not the current rv template. Foreign siblings (`dcg.json`, other extensions) are not occupied. Hostless = no v1 host detected.
12. **Config dir** is `$HOME/.config/rv/` (process `HOME` only). No `NSHomeDirectory()`. No `XDG_CONFIG_HOME` in v1.
13. **RuleID.** Canonical `rawValue` is `pack:pattern`. Display / hostDenyText uses `pack/pattern`. Robot JSON `rule_id` is the colon form.
14. **Normalize** is role-aware: strip quote characters on argv0/flags; mask only data-role arguments. `"git" reset --hard` and `git reset '--hard'` deny.
15. **Day-one packs missing or unloadable** → do not serve allow. T3 must not handshake `ok` with an empty core registry. Evaluate returns indeterminate (then hook deny per #6).
16. **ICU load.** Quarantine a non-compiling pattern by name; still load the pack. Never quarantine `reset-hard` or `fork-bomb`. Critical/high catalog compile-fail must not silently skip at T9 enable.
17. **Quick-reject** must force-scan `core.filesystem` on empty-paren / fork-bomb shapes so `:(){ :|:& };:` is not keyword-missed.
18. **Doctor `wired`** requires the baked `rv` path to be executable. Missing path is `broken`.
19. **Doctor show.** TTY pretty is sectioned (`Service` / `Hosts` / `Packs` / `Config` / `Next`): circle marks, silver heads, status ink. Packs lists day-one IDs only; extras are a count (`extras off` / `+N extras`), not a full · roster. Occupied Next is `rv setup --force` (not plain setup). Missing / absent-file / broken Next is `rv setup`. Robot stays `rv.doctor.v1` JSON. No paced ceremony.
20. **Setup `--force`.** Plain `rv setup` still skips occupied owned names. `rv setup --force` moves the occupied owned file to `*.bak` (removes dangling symlinks) then writes the current template. Foreign siblings stay untouched. Explicit opt-in only.
21. **On-disk allow-once** uses atomic compare-and-swap so two in-process hook children cannot both consume one grant.
22. **Product-tree name hygiene.** Files created or edited **outside** `docs/factory/` must not contain the tokens `dcg` or `ryk` (any case, as a substring). That includes `Sources/`, `Tests/`, `Package.swift`, `README.md`, `AGENTS.md`, `docs/dev/`, `docs/architecture/`, `vendor/`, `tools/`, `install.sh`, and host templates. Factory docs under `docs/factory/` may name the parity source and the sibling project. Product copy, comments, identifiers, paths, env names, and fixture keys use `rv`, `upstream`, `pinned 0.11.0`, `vendor/parity/`, and `tools/extract-packs/` only. Pin file is `vendor/parity/PIN`. Extract flag is `--source-root`. Quarantine field is `pinned_0_11_0`. Do not honor or mention a `.dcg/` config dir in product code. T0 acceptance includes a product-tree grep that those tokens are absent.
23. **Install show.** v1 install is curl only. `install.sh` copies binaries then `RV_FROM_INSTALL=1 exec rv setup`. TTY pretty may pace download + host wiring; that is not a wizard. Ink: default text; colored marks/progress only (`Palette.muted` / `Palette.heading`). After a wired **install** ceremony the next action is `rv explain "rm -rf"`. Plain `rv setup` closes with `Hooks wired`. Robot stays one line.
24. **Uninstall show.** TTY pretty paces owned-hook removal (`Removing Hooks` → empty circles → `Uninstall complete`). Occupied names are left alone (`left occupied`). Pretty and robot share the `didRemoveAnything` closer: no deletes → `Already clean`; deletes with no host motion → bare `Uninstall complete`. Robot is one line. Never deletes foreign hooks.

## First implementation slice

1. Create product files in `~/CodingProjects/rv` (this repo).
2. T0 → T1 only. Stop when SKILL.md corpus is green.
3. Do not wire this machine’s live Grok/Pi/OpenCode until the human asks.
