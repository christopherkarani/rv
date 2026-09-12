# File-tool secrets W3 — session start

Paste this. Do not re-grill. Do not rewrite W1/W2.

Repo: `/Users/chriskarani/CodingProjects/rv`
Parent: `planning/2026-09-12-file-tool-secrets-implementable-program.md`
Landed: W1+W2 on `feat/file-tool-secrets` — PR https://github.com/christopherkarani/rv/pull/199
Law: `AGENTS.md`, `CONTEXT.md`, `docs/factory/STATUS.md`, `docs/factory/references/host-contracts-v1.md`

## Job

Give **Pi, OpenCode, Hermes, Codex, and OpenClaw** the same file-tool door Claude / Cursor / Grok already have.

If the host’s own Read / Edit / Write (or that host’s real alias) points at a catalog secret path, rv denies it. Ordinary project files allow. Shell `git reset --hard` still denies on every host you touch.

`rv setup` is still the only enable step. No new CLI. No second install command.

## Reuse (do not invent a second door)

- `FileToolAction` / `evaluateFile` / `evaluateFileTool`
- Path fields: first non-empty of `file_path`, `path`, `target_file`, `target`
- Same catalog. Catalog hits stay pinned. Host-auth rows never go on `secret.allow_paths`
- Empty path → deny (same voice as missing shell command on that host)
- Packs never see file tools. No fake `cat <path>`
- File evaluate is injected. RVHooks still must not import RVEngine

## Per host (amend the contract, then the codec + setup)

Do not copy Claude matchers blindly. Read the live adapter and `host-contracts-v1.md` first. If a host has no real file tool, write that residual and stop for that host. Do not invent a tool name.

| Host | Today | This wave |
|---|---|---|
| Pi | `tool_call` / `bash` only | Also the host’s real file tools. Deny is still `{ block: true, reason }`. Card stays display-only. Missing rv still blocks. |
| OpenCode | `tool.execute.before` / `bash` (+ `session.shell`) | Also the host’s real file tools. Deny is still throw. Toast stays display-only. Missing rv still throws. |
| Hermes | `pre_tool_call` / `terminal` only | Also the host’s real file tools. `execute_code` stays foreign. Deny is still `{action:block,message}`. Never `{action:approve}`. |
| Codex | `PreToolUse` matcher `Bash` only | Add named `Read` / `Edit` / `Write` matchers (do not omit matcher — MCP stays off the hook). Honor path stays official `block` + stderr reason + exit 2. `write_stdin` is residual unless you prove an official intercept. |
| OpenClaw | `before_tool_call` matcher `exec` only | Also the host’s real file tools if they exist. `exec` stays the shell door. `code_mode_exec` stays foreign. Deny is still `{ block: true, blockReason }`. No `requireApproval`. |

Doctor must say file-tool wired for each host you actually hook. Occupied slot: skip + one line. No foreign overwrite.

## Split (do not flatten)

- Pi / OpenCode / Hermes: one W3 wave. Entry: W1 green (it is).
- Codex / OpenClaw: own host-contract amendment first. Codex matcher + `write_stdin` gap. OpenClaw is exec-only today.

Write a short program under `planning/` before coding if the tree still has no W3 wave file. Then implement. Do not start coding from this prompt’s vibes.

## Reject

- Grep / Glob / MCP / `apply_patch`
- Host Ask, OPE-156, `ProposedAction.file` / `.mcp`, GUI
- `RV_BYPASS`; allow because XPC missed
- Official Claude `permissionDecision: ask`
- Live-HOME tests
- Competitor names in tree files
- Changing Grok fail-open
- Turning `RVHistory` into allow-logging

## Proof

Isolated HOME. Named-host file-tool deny + ordinary allow + shell reset-hard still denies. `rv setup` writes the new matchers. `rv blocks` records the deny (tool name is the host’s file tool, not a fake Bash).

Gate: `tools/gate.sh RVHooksTests RVCLITests` (and Domain/Engine if you touch them). Warm `.build`. Do not wipe `.build`.
