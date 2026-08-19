# Handoff — rv factory → implement T0

Kind: **complete** (factory Go Ready; next focus: implement T0)
Workspace: `/Users/chriskarani/CodingProjects/rv`
Date: 2026-08-17

## Goal status

Build **rv**: macOS 26 / Apple Silicon destructive-command guard for coding-agent **shell** hooks. Day-one win: Pi / Grok / OpenCode block `git reset --hard` via on-demand XPC (`rvd`) with in-process fallback.

**PLAN #20:** do not write the tokens `dcg` or `ryk` into any product file. Pin is `vendor/parity/PIN`. Extractor is `tools/extract-packs/`. Factory docs under `docs/factory/` may name the parity source.

The **factory is complete**. Next implement ticket is **T0** only. Do not start T1 in the same session unless the human says so.

| Artifact | Path | Status |
|---|---|---|
| Locked plan | `docs/factory/PLAN.md` | Done — wins every conflict |
| DCG 0.11.0 notes | `docs/factory/references/dcg-0.11.0-notes.md` | Done (pin + core rule names; stash-drop is allow + match) |
| Host contracts | `docs/factory/references/host-contracts-v1.md` | Done (aligned to PLAN miss policy) |
| Phase specs | `docs/factory/specs/` | Landed (8 files) |
| Adversarial reviews | `docs/factory/reviews/adversarial-*.md` | Landed; PLAN locked resolutions applied |
| Implement prompts | `docs/factory/prompts/T0.md` … `T9.md` | Prompt-only; each requires a human closing paragraph |
| Cohesiveness | `docs/factory/reviews/cohesiveness.md` | **Go Ready** |
| Stress tests | `docs/factory/reviews/stress-1.md`, `stress-2.md` | Landed; leftover host-contracts miss policy already matches PLAN #6 |
| Kickoff canvas | rv workspace canvases | Buttons dispatch the prompt files |

## What the next agent must read (in order)

1. `docs/factory/PLAN.md` — product law. Wins all conflicts.
2. The ticket spec under `docs/factory/specs/` (T0 = `phase-0-repo.md`).
3. This handoff.
4. The ticket prompt under `docs/factory/prompts/` (that file is **only** the prompt).
5. `docs/factory/references/dcg-0.11.0-notes.md` for T1+ (rule IDs, FN/FP landmines).

Do not re-grill. Do not re-derive allow/deny from a sibling repo. Work only in this tree. Do not copy factory source-project names into product files.

T0 scaffolds empty modules only. Do not implement evaluate, hooks, XPC, setup, or pretty CLI in T0.

## Files already touched (factory only)

- `docs/factory/PLAN.md`
- `docs/factory/HANDOFF.md` (this file)
- `docs/factory/STATUS.md`
- `docs/factory/references/dcg-0.11.0-notes.md`
- `docs/factory/references/host-contracts-v1.md`
- `docs/factory/specs/*.md` (all eight)
- `docs/factory/prompts/T0.md` … `T9.md`
- `docs/factory/reviews/` (adversarial + cohesiveness)

No `Package.swift` yet. Repo is otherwise empty git.

## Contracts the next implementer must not invent

T0 does not encode these as product code. Later tickets implement them. Do not weaken them in `AGENTS.md` / `PARITY.md`.

- Names: `rv`, `rvd`, `RV_`, `~/.config/rv/`. Config is process `HOME` only. No `NSHomeDirectory()`. No `XDG_CONFIG_HOME` in v1.
- Platform: macOS 26, arm64 only.
- Hosts v1: Pi, Grok, OpenCode. Shell/command only.
- Packs v1: `core.git` + `core.filesystem` on; rest catalog off.
- Evaluate order: normalize → quick-reject → safe → destructive → default allow.
- **Decision:** `allow` \| `deny(Deny)` \| `indeterminate(IndeterminateReason)`. A deny always has `ruleID` + `reason`. No `isDenied`. Medium/low stay allow with `matched` (`git stash drop` allow; `git stash clear` deny).
- **Scoreboard:** DCG 0.11.0 **engine source**, not SKILL.md marketing. `$TMPDIR` is not a safe `rm -rf` prefix. Never quarantine `core.git:reset-hard`.
- **PackID:** `^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)?$` (`core.git`, `strict_git`, `package_managers`).
- **hostDenyText** never includes a redeemable code. Canonical: `Blocked git reset --hard (core.git/reset-hard). Run it in Terminal, or rv allow-once.` Nil/empty unless `Decision` is deny.
- XPC down/skew → in-process evaluate. Never allow because XPC missed. Indeterminate → hook deny with “rv could not finish evaluating this command. Run it in Terminal.”
- Missing `rv` binary → Pi/OpenCode block with `rv missing`; Grok’s host fail-opens if the process never starts. A started `rv` that times out or crashes → Pi/OpenCode block.
- **allowOnce.consume** spends a grant `{ command, cwd }`, not a plaintext code.
- **LaunchAgent owner is T6.** T3 ships the `dev.rv.evaluate` template (`KeepAlive` false). T3 does not load a live agent.
- No `RV_BYPASS`. No host Allow button. Unlock is Terminal or TTY `rv allow-once`.
- History off. No command text in `os_log`.
- Grade is **hook**. Not Seatbelt / OS-enforced.
- Pin: `vendor/parity/PIN` version `0.11.0`, tag `v0.11.0`, tag object `6d4fcaef45d6b207a291158dc4077e54e6be685c`, commit `2ed7eeef1ae63d204495f02312c657dd6d9bf73d`.
- **Name hygiene (PLAN #20):** product tree outside `docs/factory/` must not contain `dcg` or `ryk`.
- Executables: T0 library-only. T2 may add ArgumentParser `from: "1.7.0"` + `rv`. T3 may add `rvd`. T8/T9 must not add ArgumentParser or `@main`.

## Parallel / worktree (do not improvise)

- T0 serial. T1 after T0, serial.
- After T1 corpus green: T2 and T3 in **separate worktrees** (`feat/t2-ux`, `feat/t3-service`).
- T4 then T5 serial on the same tree (`feat/t4-t5-hooks`).
- T6 and T7 in parallel worktrees only if file ownership is split as in PLAN (`feat/t6-install`, `feat/t7-doctor`).
- T8 and T9 after T1 in separate worktrees (`feat/t8-allow-once`, `feat/t9-catalog`).
- Two agents never share one working tree.

## How to verify (factory)

- Specs exist for phases 0, 1, 1b, 1c, 1d, 2, 3, 4+.
- Reviews exist: FP, FN, known-unknowns, stress ×2, cohesiveness **Go Ready**.
- Each implement prompt is the prompt only (no template chrome) and ends with a human closing paragraph.
- Canvas kickoff buttons dispatch those prompts.

## How to verify (T0, when kicked off)

Follow `docs/factory/specs/phase-0-repo.md` acceptance literally. Gate is `swift test` on empty modules. Do not start T1 in the same session unless the human says so.

## What not to redo

- Product grilling (hosts, XPC, deny UX, unlock, packs, privacy).
- Treating a sibling repo’s pack dump or leftover-ask-as-permit as rv law.
- Copying a foreign bypass env or Claude-only hook docs into product files.
- Implementing Phase 4+ (scan, MCP, Mac app, extra hosts) before T0–T9.

## Open risks

- Semantic-only upstream rules (git alias, branch-dynamic) cannot be ICU text matches. T1 must quarantine them.
- Host stdin/stdout contracts for Pi / Grok / OpenCode must be taken from those hosts, not from a leftover-ask rewrite wire.
- v1 install is curl only (`install.sh` → `$HOME/.local/bin`, then `rv setup`). Homebrew is Phase 4+; T6 must not add a formula. TTY setup: default-color text, circle-only cyan; next command is `rv test 'git reset --hard'`.
- Tests that write the operator’s live `~/.grok` / `~/.pi` / `~/.config/opencode` are a ship-stopper.

## Suggested skills

- `tdd` — corpus/fixture first for T1+; T0 is compile smoke only.
- `swift-concurrency` / `swift-generics` — T1 engine and T3 service.
- `prompt-engineer` — only if a kickoff prompt must be revised; do not add template chrome.
- `handoff` — overwrite this file at the end of each ticket.

## Close every implement session with

A short human paragraph: what changed, which acceptance boxes are proven, how much closer to the day-one win (Pi/Grok/OpenCode block `git reset --hard`), and what is still open. Do not commit unless the human asked.
