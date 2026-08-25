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

## Shared deny text

`hostDenyText`: one sentence + display `rule_id` (`pack/pattern`) + next step. Never include a redeemable code. Canonical: `Blocked git reset --hard (core.git/reset-hard). Run it in Terminal, or rv allow-once.`
Allow (`Decision.allow`, including medium/low match): empty stdout, host-success exit. No banner.
Indeterminate (`Decision.indeterminate`): same wire as deny, reason `rv could not finish evaluating this command. Run it in Terminal.` — not empty allow. No pack `rule_id`. Switch on `Decision`; do not treat nil `hostDenyText` as allow.

## Unlock

No host Allow button. No `RV_BYPASS`. TTY `rv allow-once` is T8.
