# Cohesiveness

## Verdict (Go Ready)

Factory artifacts agree with PLAN locked resolutions. A T0 agent that reads HANDOFF + `prompts/T0.md` + PLAN will scaffold only (no evaluate, no executables, no ryk, no live HOME) and will not invent a forbidden product law. Kick off T0.

## Aligned

- **T0 isolation.** HANDOFF now says factory complete / next focus T0. T0 prompt + PLAN + phase-0 spec: library-only, twelve empty modules, no LICENSE, no DCG clone, serial, no T1. Contracts listed in HANDOFF are “do not invent,” not T0 product work.
- **Worktrees match PLAN and the canvas.** T0 serial; T1 serial after T0; T2∥T3 separate trees (`feat/t2-ux`, `feat/t3-service`); T4 then T5 same tree (`feat/t4-t5-hooks`); T6∥T7 split ownership (`feat/t6-install`, `feat/t7-doctor`); T8∥T9 after T1 (`feat/t8-allow-once`, `feat/t9-catalog`). Two agents never share a working tree.
- **hostDenyText.** Canonical deny sentence is identical in PLAN #8, T2 spec, T1d deny contract, T8, host-contracts, and HANDOFF. Never a redeemable code. `hostDenyText` is `nil` unless `Decision` is deny (medium/low / stash-drop is allow → empty hook stdout).
- **Decision.** `allow` | `deny(Deny)` | `indeterminate`. No `isDenied`. Medium/low allow + match. IPC/robot use a string discriminator plus optional deny payload.
- **Scoreboard.** DCG 0.11.0 engine source: critical/high deny; `git stash drop` allow + match; `git stash clear` deny; `$TMPDIR` not a safe `rm -rf` prefix; never quarantine `core.git:reset-hard`. Notes, T1 spec/prompt, T4 prompt, and HANDOFF agree.
- **Miss policy (PLAN #6).** `rvd` down/skew → in-process evaluate. Indeterminate → hook deny with the incomplete-eval sentence. Missing `rv` → Pi/OpenCode block `rv missing`; Grok host fail-opens if the process never starts. Started `rv` timeout/crash → Pi/OpenCode block. Deny JSON honored regardless of exit code.
- **allowOnce.consume.** Grant `{ command, cwd }`, not a plaintext code. TTY redeem only. T3 + T8 + prompts agree.
- **LaunchAgent.** T6 owns `$HOME/Library/LaunchAgents/dev.rv.evaluate.plist` from the T3 template, `KeepAlive` false. T3 does not load a live agent.
- **PackID.** `^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)?$` — `core.git`, `strict_git`, `package_managers`. No `PackID(rawValue:)!` on production paths.
- **Config.** `$HOME/.config/rv/` only. No `XDG_CONFIG_HOME`. No `NSHomeDirectory()`.
- **Executables (PLAN #4).** T0 library-only. T2 may add ArgumentParser `from: "1.7.0"` + `rv`. T3 adds `rvd`. T8/T9 must not add ArgumentParser or `@main`.
- **Prompts.** Each `T0.md`–`T9.md` is the prompt only (no template chrome). Each requires a short human closing paragraph. Canvas `runPrompt` loads those files and repeats the closing-summary rule.

## Patches applied

- `specs/phase-1b-ux.md` — `hostDenyText` → `String?` (nil on allow, including medium/low); robot `rule_id` colon form; PLAN #4 executable exception.
- `specs/phase-1-engine.md` — PackID regex pasted from PLAN #3.
- `specs/phase-1c-service.md` — T0 did not declare `rvd`; T3 adds the executable.
- `specs/phase-1d-hosts.md` — T5.1 + Q7 match PLAN #6 (missing `rv` blocks Pi/OpenCode); Q11 T6 owns LaunchAgent.
- `specs/phase-3-allow.md` — dropped production `XDG_CONFIG_HOME`; config is `$HOME/.config/rv` only.
- `references/host-contracts-v1.md` — Grok tool names; Pi/OpenCode missing-`rv` block (PLAN #6).
- `prompts/T1.md`, `T2.md`, `T4.md`, `T7.md`, `T8.md`, `T9.md` — same locks (PackID, hostDenyText nil, stash-drop allow, doctor `broken`, no ArgumentParser on T8/T9).
- `HANDOFF.md` — kind **complete**; next focus implement T0; locked contracts listed so T0 cannot invent a looser law.
- `STATUS.md` — cohesiveness row **Go Ready**; handoff complete; stress ×2 residual.

## Residual (non-blocking)

- Stress-1/2 now exist. Leftover host-contracts miss-policy sentence was aligned to PLAN #6. PLAN #20 (product-tree name hygiene) landed after this review: pin is `vendor/parity/PIN`; implement prompts forbid writing `dcg`/`ryk` into product files.
- Adversarial review files still describe some *pre-lock* holes (e.g. missing-`rv` fail-open). They are historical. Implementers follow PLAN + current specs + prompts.
- T1 `EvaluationResult` snippet nests `SafeMatch` awkwardly. The named `SafeMatch` type is required; T1 must not ship a non-Codable tuple. Not a T0 issue.
- T2 pretty display stays `pack/pattern`; robot / `RuleID.rawValue` stay `pack:pattern`. Already locked (PLAN #13).
- Phase 4+ remains fence-only. Canvas kickoff for T0 is the next human action.
