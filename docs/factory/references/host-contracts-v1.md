# Host contracts (v1) — review notes

rv owns codecs. Do not copy ryk leftover-ask-as-permit. Do not copy DCG fail-open-on-error for Pi.

## Grok

- Discover: `~/.grok/hooks/*.json`. Setup writes an **rv-owned** file (e.g. `rv.json`), never `dcg.json`, never a foreign hook.
- Matcher: `PreToolUse` / `Bash` (Grok aliases to `run_terminal_cmd`).
- Stdin shape (camelCase): `hookEventName: "pre_tool_use"`, `toolName: "run_terminal_command"` or `run_terminal_cmd` or `Bash`. Also detect `GROK_SESSION_ID` / `GROK_HOOK_EVENT` / `GROK_WORKSPACE_ROOT`.
- Deny stdout: `{"decision":"deny","reason":"..."}`. Word is **deny**, not Hermes `block`.
- Documented preferred: JSON deny with exit 0. Exit 2 is also honored. Other exits fail-open at the host.
- Non-shell tools: pass through. No Read/Edit/MCP in v1.
- Occupied single slot: skip + one line. Do not overwrite foreign hooks.

## Pi

- Discover: `~/.pi/agent/extensions/*.ts` or project `.pi/extensions/*.ts`.
- Event: `pi.on("tool_call", …)`. Shell tool name is typically `bash`. Input: `event.input.command`.
- Deny: return `{ block: true, reason }`. Reason is `hostDenyText` (one sentence + rule_id + next step). That return is the block path.
- Display-only: `registerMessageRenderer` for `rv-decision` must return `{ render(width) => string[] }`, never a string. `sendMessage` on deny only (`triggerTurn: false`). Allow stays silent. Not the deny path. No confirm / Allow UI.
- DCG’s published recipe fails open if `dcg` is missing. **rv adapter (PLAN #6):** missing `rv` binary → Pi `{ block: true, reason: "rv missing" }`. A started `rv` that times out or crashes → `{ block: true, reason: "rv failed" }`. **`rvd` down/skew** still evaluates in-process and must deny. Doctor reports a missing/non-exec baked path as `broken`.
- Occupied slot: skip + one line. No ryk special-case.

## OpenCode

- Discover: `~/.config/opencode/plugins/` or project `.opencode/plugins/`.
- Event: `tool.execute.before` (and `command.execute.before` if the same shell payload exists). Shell only.
- Deny: throw/block with native text. Display-only TUI toast (`client.tui.showToast`, title `RV · Blocked`) is chrome, not the deny. Toast failure must still throw. Missing `rv` → throw `rv missing`. A started `rv` that times out or crashes → throw `rv failed`.
- DCG does not auto-install OpenCode; community plugins have shipped wrong JSON field names. rv must pin fixtures from a current OpenCode plugin API, not from a broken gist.
- Occupied slot: skip + one line.

## Claude Code (post-v1; see `docs/factory/specs/claude-host.md`)

- Discover: `~/.claude/`. Setup **merges** into `$HOME/.claude/settings.json` (shared file; not an exclusive owned filename). PLAN #11 filename occupancy and PLAN #20 `*.bak` whole-file rewrite do **not** apply to `settings.json`.
- Matcher: `PreToolUse` / `Bash` only. Absolute `…/rv hook --host claude`, `timeout` 5. Foreign hooks (incl. dcg) and non-hook keys (model / MCP / permissions) untouched. Occupied = rv-fingerprinted handler present but not current shape → skip unless `--force`. `--force` replaces **only** rv-fingerprinted handlers.
- Stdin (snake_case): `hook_event_name: "PreToolUse"`, `tool_name: "Bash"`, `tool_input.command`. `cwd` when present. Non-Bash tools: allow (empty). Malformed: allow (host fail-open).
- Deny stdout (exit 0): documented Claude fields only — `systemMessage` branded `RV · Blocked` + short hostDenyText; `hookSpecificOutput` with exactly `hookEventName`, `permissionDecision: "deny"`, rich `permissionDecisionReason`. Pack / rule / severity / remediation live inside the reason text. **No** extra `hookSpecificOutput` keys (`ruleId`, `packId`, `severity`, `remediation`, …): schema-invalid exit-0 JSON is a non-blocking error and the action proceeds. **No** `allowOnceCode` / redeemable code. Indeterminate: deny envelope + incomplete-eval sentence; no pack sections in the reason.
- Allow: empty stdout, exit 0. No `permissionDecision: "ask"` in this ship (CL-later-ask). No Read/Edit/Write/MCP matchers (CL-later-secrets / CL-later-mcp).

## OpenClaw (OPE-266; host only, no Ask)

- Discover: `~/.openclaw/` exists or `openclaw` on PATH. Linux and macOS only. No Windows path.
- Setup writes an **exclusive plugin directory** `$HOME/.openclaw/extensions/rv-guard/`:
  - `index.js` — rv-owned adapter (`__RV_BINARY__` baked)
  - `openclaw.plugin.json` — `id: "rv-guard"`, `activation.onStartup: true`
  - `package.json` — `"type": "module"` and `openclaw.extensions: ["./index.js"]`
  Occupancy is the exclusive `index.js` (same baked-path inspect as Pi / OpenCode). Do not merge `openclaw.json`.
- Real intercept: plugin typed lifecycle hook `before_tool_call` via `api.on(...)`, matcher `["exec"]`. Canonical shell tool is `exec`. `params.command` is the shell text; `params.workdir` is cwd. Outer code-mode exec (`toolKind: "code_mode_exec"`) is **foreign**, not shell.
- Adapter stdin to `rv hook --host openclaw` (rv-owned envelope, not “OpenClaw sent this”):

  ```json
  {
    "toolName": "exec",
    "params": { "command": "git status", "workdir": "/tmp/ws" },
    "cwd": "/tmp/ws",
    "sessionId": "sess_1",
    "sessionKey": "main",
    "toolKind": "exec"
  }
  ```

  Decode: unreadable JSON → deny. `toolName != "exec"` or `toolKind == "code_mode_exec"` → foreign allow. Exec with missing/empty `params.command` → deny. cwd is `params.workdir` then envelope `cwd`. session is `sessionId` then `sessionKey`.
- Deny: plugin returns `{ block: true, blockReason }` where `blockReason` is `hostDenyText`. `block: true` is terminal. **No** `requireApproval` (Ask is out of scope). Missing `rv` → `{ block: true, blockReason: "rv missing" }`. Timeout/crash → `{ block: true, blockReason: "rv failed" }`. Operator stdout is short `{decision,reason}` JSON and exit **1**.
- Session store: per-agent SQLite `$HOME/.openclaw/agents/<agentId>/agent/openclaw-agent.sqlite`, table `transcript_events (session_id, event_json, created_at)`. `extract(fileURL:data:)` uses **`data`**, never reopens the path. sqlite open / prepare / unreadable bytes **throw**. Empty valid `transcript_events` may return `[]`. Skip non-exec / unparseable rows.
- Occupied slot: skip + one line. No Ask UI. No AFM / ActionReviewer.

## Hermes (OPE-265; host only, no Ask)

- Discover: `~/.hermes/` exists or `hermes` on PATH. Linux and macOS only. No Windows path.
- Setup writes an **exclusive plugin directory** `$HOME/.hermes/plugins/rv-guard/`:
  - `__init__.py` — rv-owned adapter (`__RV_BINARY__` baked)
  - `plugin.yaml` — `name: rv-guard`, `provides_hooks: [pre_tool_call]`
  Occupancy is the exclusive `__init__.py` (same baked-path inspect as Pi / OpenCode / OpenClaw). Do not merge `config.yaml` and do not write gateway `~/.hermes/hooks/`. Hermes user plugins are opt-in: after setup, enable with `hermes plugins enable rv-guard`.
- Real intercept: plugin hook `pre_tool_call` via `ctx.register_hook(...)`. Canonical shell tool is `terminal`. `args.command` is the shell text; `args.workdir` is per-command cwd. `execute_code` and other tools are **foreign**, not shell.
- Adapter stdin to `rv hook --host hermes` (rv-owned envelope, not “Hermes sent this”):

  ```json
  {
    "toolName": "terminal",
    "args": { "command": "git status", "workdir": "/tmp/ws" },
    "cwd": "/tmp/ws",
    "sessionId": "sess_1",
    "taskId": "task_1"
  }
  ```

  Decode: unreadable JSON → deny. `toolName != "terminal"` → foreign allow. Terminal with missing/empty `args.command` → deny. cwd is `args.workdir` then envelope `cwd`. session is `sessionId` then `taskId`.
- Deny: plugin returns `{"action": "block", "message"}` where `message` is `hostDenyText`. **No** `{"action": "approve"}` (Ask is out of scope). Missing `rv` → `{"action": "block", "message": "rv missing"}`. Timeout/crash / hook exception → `{"action": "block", "message": "rv failed"}` (Hermes isolates hook errors and would otherwise fail open). Operator stdout is short `{decision,reason}` JSON and exit **1**.
- Session store: `$HOME/.hermes/state.db`, table `messages (session_id, tool_calls, timestamp)`. `tool_calls` is JSON (OpenAI-style `function.name` / `arguments.command`, or a top-level `name`). `extract(fileURL:data:)` uses **`data`**, never reopens the path. sqlite open / prepare / unreadable bytes **throw**. Empty valid `messages` may return `[]`. Skip non-terminal / unparseable rows.
- Occupied slot: skip + one line. No Ask UI. No AFM / ActionReviewer.

## Codex (OPE-269; host only, no Ask)

- Discover: `~/.codex/` exists or `codex` on PATH. Linux and macOS only. No Windows path.
- Setup writes an **exclusive adapter** `$HOME/.codex/hooks/rv-guard.py` (`__RV_BINARY__` baked) and **merges** `$HOME/.codex/hooks.json` (`PreToolUse` / `Bash`, `python3 …/rv-guard.py`, timeout 5, `statusMessage: RV`). Occupancy is the exclusive adapter, not the merge file. Foreign `hooks.json` siblings stay. `--force` replaces only the rv-fingerprinted adapter.
- Real intercept: Codex command hook `PreToolUse`, matcher `Bash`. Stdin (snake_case): `hook_event_name: "PreToolUse"`, `tool_name: "Bash"`, `tool_input.command`. cwd is `tool_input.workdir` then envelope `cwd`. session is `session_id` then `turn_id`. Non-Bash / non-PreToolUse: allow (empty). Unreadable JSON or missing/empty command: deny.
- Honor path (QA / live TUI): official older PreToolUse shape on stdout, the blocking reason on **stderr**, and process exit **2**:

  ```json
  {"decision":"block","reason":"<hostDenyText>"}
  ```

  stderr: `<hostDenyText>` (Chris 271 line for reset-hard: `RV · Blocked. Destroys uncommitted changes.`). Exit 2 without a stderr reason — including empty or whitespace-only / a bare newline — fail-opens the tool. Claude `hookSpecificOutput.permissionDecision: deny` is **not** the Codex honor path. Do not emit `"ask"` (`permissionDecision: ask` is leftover-ask-as-permit and continues the tool). `encodeAsk` equals `encodeDeny`. Operator and wrapper both emit `block` + a trimmed non-empty stderr reason + exit 2. Missing reason becomes `rv failed`, never a bare newline.
- Missing `rv` → `{"decision":"block","reason":"rv missing"}` + stderr `rv missing` + exit 2. Timeout/crash / non-JSON → `{"decision":"block","reason":"rv failed"}` + stderr `rv failed` + exit 2. Wrapper maps leftover operator `decision: deny` onto the same official `block` + stderr + exit 2.
- Session store: `$HOME/.codex/sessions/**/rollout-*.jsonl`. Surface Bash / shell / local_shell with `tool_input.command`. `extract(fileURL:data:)` uses **`data`**, never reopens the path. Empty or non-UTF-8 `data` throws. Skip non-shell / unparseable rows.
- Occupied slot: skip + one line. No Ask UI. No AFM / ActionReviewer. Capability is deny-or-TTY (`.pi` / `.opencode` stay spendFirst).

## Cursor (OPE-270; host only, no Ask)

- Discover: `~/.cursor/` exists or `cursor` on PATH. Linux and macOS only. No Windows path.
- Setup writes an **exclusive adapter** `$HOME/.cursor/hooks/rv-guard.py` (`__RV_BINARY__` baked) and **merges** `$HOME/.cursor/hooks.json` (official native `hooks.beforeShellExecution` entry: `python3 …/rv-guard.py`, `failClosed: true`, timeout 5, schema `version: 1`). Occupancy is the exclusive adapter, not the merge file. Foreign `hooks.json` siblings stay. `--force` replaces only the rv-fingerprinted adapter. Do **not** write project `.cursor/hooks.json` (no foreign hook writes into repos).
- Real intercept: official Cursor command hook `beforeShellExecution` ([hooks](https://cursor.com/docs/hooks.md)). Stdin: `command`, `cwd`, optional `conversation_id` / `generation_id` / `sandbox`. Also decode `preToolUse` + `tool_name` `Shell`/`Bash` as shell (`tool_input.command`); other tools and `afterShellExecution` are foreign allow. cwd is `tool_input.working_directory` then envelope `cwd` then `workspace_roots[0]`. session is `conversation_id` then `session_id` then `generation_id`. Unreadable JSON or missing/empty command: deny.
- Honor path (QA / live Agent): official native `beforeShellExecution` stdout JSON and process exit **0** (docs: “Exit code 0 — use the JSON output”):

  ```json
  {"permission":"deny","user_message":"<hostDenyText>","agent_message":"<hostDenyText>"}
  ```

  Allow (required because setup writes `failClosed: true`; empty stdout would block a harmless command):

  ```json
  {"permission":"allow"}
  ```

  Chris 271 line when we own the reason: `RV · Blocked. Destroys uncommitted changes.` Claude `hookSpecificOutput.permissionDecision: deny` is **not** the Cursor honor path (third-party compat only; [third-party hooks](https://cursor.com/docs/reference/third-party-hooks)). Codex `{"decision":"block"}` + exit 2 is **not** the Cursor honor path. Exit 2 ≡ `permission: deny` is documented Claude-compat; RV still emits exit 0 + native JSON. Do not emit `"permission":"ask"` (leftover-ask-as-permit). `encodeAsk` equals `encodeDeny`. Missing `rv` / timeout / crash / non-JSON / empty or whitespace-only stdout (including exit 0) → official deny with `rv missing` / `rv failed`. Empty stdout + exit 0 is **not** allow. Default Cursor hook failure is fail-open; `failClosed: true` is required so a miss is not silent allow.
- Session store: `$HOME/.cursor/projects/**/agent-transcripts/*.jsonl`. Surface `beforeShellExecution.command` and `preToolUse` Shell/Bash `tool_input.command`. `extract(fileURL:data:)` uses **`data`**, never reopens the path. Empty or non-UTF-8 `data` throws. Skip non-shell / unparseable rows.
- Occupied slot: skip + one line. No Ask UI. No AFM / ActionReviewer. Capability is deny-or-TTY (`.pi` / `.opencode` stay spendFirst; `.codex` stays denyOrTTY).
- Honest hole: cloud agents do not load user-level `~/.cursor/hooks.json` ([hooks](https://cursor.com/docs/hooks.md) — “User-level hooks (`~/.cursor/hooks.json`) are not available in cloud agents”).

## Shared deny text

`hostDenyText`: one sentence + display `rule_id` (`pack/pattern`) + next step. Never include a redeemable code. Canonical: `Blocked git reset --hard (core.git/reset-hard). Run it in Terminal, or rv allow-once.`
Allow (`Decision.allow`, including medium/low match): empty stdout, host-success exit. No banner.
Indeterminate (`Decision.indeterminate`): same wire as deny, reason `rv could not finish evaluating this command. Run it in Terminal.` — not empty allow. No pack `rule_id`. Switch on `Decision`; do not treat nil `hostDenyText` as allow.

## Unlock

No host Allow button. No `RV_BYPASS`. TTY `rv allow-once` is T8.
