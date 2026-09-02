# Status

Living map. Do **not** re-grill. Do **not** load `docs/factory/reviews/*` to implement.

**Read order:** `AGENTS.md` → this file (now / next / later) → `docs/architecture/MODULES.md` (what exists) → `docs/architecture/02.md` § Order (remaining 0.2) → relevant skill → `tools/gate.sh`

`docs/factory/PLAN.md` wins **v1 product-law** conflicts. It is not the execute queue. `MODULES.md` wins “is this type already in the tree?” `02.md` § Order is remaining 0.2 work against that tree.

## Now (2026-09-01)

v1 hook guard is shipped: C `rv` + `rvd`, day-one packs `core.git` + `core.filesystem` + `system.disk`, session forensics `rv scan`. Hosts: Pi, Grok, OpenCode, Claude, OpenClaw, Hermes, Codex, Cursor — vocabulary in `CONTEXT.md`.

0.2 types are in the tree. **Do not greenfield:** `ProposedAction` / `ActionFingerprint` (OPE-156 path), `analyzeGit` / `analyzeFilesystem` / `unwrapCommand` (254–256), `ActionPolicyEngine` (157), repo boundary (159), protected paths (160), pack `ExplainStep` (168), shadow review (250). Notes live in `MODULES.md`.

Factory T0–T9 are done. `planning/2026-08-31-product-takes*` is **landed** (deny tip, `system.disk` day-one, rebase probe). Do not treat those files as a kickoff.

Heredoc/AST is **not** installed. Fence: `docs/factory/specs/phase-4-later.md` § Heredoc / AST roadmap.

## Next

`docs/architecture/02.md` § Order — first item MODULES does **not** mark landed.

Steps 1–4 are landed. Host Ask (step 6) is Pi/OpenCode plus Claude/Hermes Ask wire (permissionDecision ask + PermissionRequest spend; Hermes spend then approve). Remaining: fingerprint grants / history (step 5), human click-through on Claude/Hermes TUI, then pending / app / live Auto-review (7–9).

Claude Ask is no longer the fenced default next. Remaining 0.2 is fingerprint grants / history, then pending / app / Auto-review.

Do not pick a ticket unless the human names one.

## Later (not the execute queue)

Fence: [`specs/phase-4-later.md`](specs/phase-4-later.md). Still later: heredoc/AST, MCP / Read / Edit hooks, repo/CI `rv scan repo`, SARIF, Mac app, Intel, older macOS, Homebrew, remaining catalog default-on, history on-by-choice.

Shipped out of that original later list: session `rv scan`, extra host adapters (Ask is 0.2, not “add the host”).

## Historical factory board

Archive of the v1 factory. Not the execute queue.

| | Ticket | Notes |
|---|---|---|
| Done | T0–T9 | Scaffold through catalog + `rv packs`. Allow-once and doctor live. |
| Done | maint | Operator-surface seams (setup analytics, ceremony snapshot, robot format). |
| Done | T10–T14 | Merged to `feat/t10-t14-size-speed` (PR #36 draft). Spec: [`specs/phase-5-size-speed.md`](specs/phase-5-size-speed.md). |
| Done | C hook T1–T5 | C `rv` pipes `hookEvaluate` to `rvd`; miss execs `rv-cli`. Spec: [`spec/spec-architecture-c-hook-pipe.md`](../../spec/spec-architecture-c-hook-pipe.md). |
| Done | session scan T1–T10 | `rv scan` / `rv scan sessions`. Spec: [`spec/spec-architecture-session-scan.md`](../../spec/spec-architecture-session-scan.md). |
| Done | Claude CL-T1–T5 | Codec, dispatch, settings merge, doctor, MODULES. Spec: [`specs/claude-host.md`](specs/claude-host.md). |
| Done | OpenClaw host (OPE-266) | Host only, no Ask. |
| Done | Hermes host (OPE-265 host) | Host only, no Ask. |
| Fenced | Claude CL-later-secrets / MCP | Read-Edit / MCP. Claude Ask landed in `02.md` step 6. |

## Specs

| File | How to read it |
|---|---|
| `specs/phase-0-repo.md` … `phase-3-allow.md` | Landed v1 factory |
| `specs/phase-4-later.md` | Remaining later fence, not a kickoff |
| `specs/phase-4-session-scan.md` | Implemented (T1–T10) |
| `specs/phase-5-size-speed.md` | Landed T10–T14 |
| [`spec/spec-architecture-c-hook-pipe.md`](../../spec/spec-architecture-c-hook-pipe.md) | Implemented |
| [`specs/claude-host.md`](specs/claude-host.md) | CL-T1–T5 implemented; later rows fenced |
| [`specs/cli-thin.md`](specs/cli-thin.md) | Implemented (CL1, CL3, CL4) |

Historical factory→T0 handoff: [`HANDOFF.md`](HANDOFF.md) (do not use as session start).
