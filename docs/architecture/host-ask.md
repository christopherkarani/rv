# Host Ask

Investigation: OPE-267. Build map: [host-ask-plan.md](host-ask-plan.md) (OPE-268, historical). Product law: [02.md](02.md) § Host Ask.

**RV wire today:** Product Ask is `HostNativeAsk.verdict` → `decision:ask` JSON. Adapters honor that only. Spend-first: **Pi, OpenCode, Claude, Hermes** (confirm, then `hostAsk=spend`, then allow only if spend succeeds). Deny-or-TTY: **Grok, Codex, Cursor, OpenClaw**. Official Claude `permissionDecision:ask` and Hermes `{"action":"approve"}` are leftover-ask-as-permit — never the honor path. Missing `rv`, timeout, or crash is a host block (`rv missing` / `rv failed`), never silent allow.

**Allow-once is a PolicyGate grant.** TTY `rv allow-once` still mints into `AllowOnceStore`. Host Allow once is plant+spend this turn on that same store. Replay without a live grant asks or denies again.

## Pi

Official: [extensions](https://pi.dev/docs/latest/extensions) — `tool_call` returns `{ block: true, reason }` and may `await ctx.ui.confirm(...)` first.

RV: `rv-guard.ts.tmpl` + `PiHostCodec`. `pi.on("tool_call")`, `bash` only. Live deny: `{ block: true, reason }` plus display-only `rv-decision` card. Ask: `decision:ask` → `ctx.ui.confirm` → `hostAsk=spend` → allow only if spend allow.

1. **Pause?** Yes. `ctx.ui.confirm`; `hasUI` false / confirm false / throw → block, no spend.
2. **User sees:** Pi confirm, then either the tool runs once or the deny card.
3. **Back to RV?** Confirm-yes spends through PolicyGate this turn. Replay without a grant asks again.
4. **No pause / fail:** `{ block: true }`. Never silent allow.

## OpenCode

Official: [plugins](https://opencode.ai/docs/plugins/) — `tool.execute.before`; documented deny is `throw new Error`. Events include `permission.asked` / `permission.replied`. No official plugin return that waits, then resumes.

RV: `rv-guard.js.tmpl` + `OpenCodeHostCodec`. `bash` + TUI `session.shell` / `shell.env`. Live deny: toast `RV · Blocked`, then `throw new Error(reason)`. Ask: `decision:ask` → confirm / official permission once → `hostAsk=spend` → return only if spend allow.

1. **Pause?** Yes. Plugin confirm or official permission `once`. Missing confirm / reject / host `allow` create is not a permit.
2. **User sees:** OpenCode confirm or permission dialog, then the tool runs once or throws.
3. **Back to RV?** Confirm-yes spends through PolicyGate this turn. Replay without a grant asks again.
4. **No pause / fail:** throw. Never silent allow.

## Claude

Official: [hooks](https://code.claude.com/docs/en/hooks-guide) — `PreToolUse` `permissionDecision` is `allow` | `deny` | `ask` | `defer`. `"ask"` shows the native permission prompt. `PermissionRequest` fires when Claude is about to ask.

RV: `ClaudeHostCodec` + settings-merge `PreToolUse` / `Bash` + exclusive `~/.claude/hooks/rv-guard.py`. Live deny: exit 0 + JSON `permissionDecision: "deny"`. First-call Ask is short `{decision:ask}` at **exit 2** for that wrapper (confirm, then `hostAsk=spend`). Never emit official `permissionDecision: "ask"` (leftover-ask-as-permit; CL-later-ask). Allow is empty stdout.

1. **Pause?** Wrapper `osascript` confirm (or `RV_ASK_CONFIRM`). Official Claude `permissionDecision: "ask"` is not the honor path.
2. **User sees:** confirm dialog, then the tool runs only after spend allow. Deny is branded rich `RV · Blocked`.
3. **Back to RV?** Confirm-yes spends through PolicyGate. Official Claude Allow is not a grant. Allow-once remains TTY → next hook consume.
4. **No pause / leftover v1 command:** encodeAsk exit 2 blocks. Never silent allow. Stale `hook --host claude` is outdated rv: `rv setup` rewrites without `--force`.

## OpenClaw

Official: [hooks](https://docs.openclaw.ai/plugins/hooks), [permission requests](https://docs.openclaw.ai/plugins/plugin-permission-requests) — `before_tool_call` may `{ block: true, blockReason }` (terminal) or `requireApproval` (pauses; `allow-once` / `allow-always` / `deny` via approval UI or `/approve`; timeout / no route / cancel block). `block: true` wins over `requireApproval`.

RV: `rv-guard-openclaw.js.tmpl` + `OpenClawHostCodec`. Matcher `["exec"]`. Live deny: `{ block: true, blockReason }` (operator `{decision,reason}` JSON, exit 1). Tests forbid `requireApproval`. Host-only (OPE-266).

1. **Pause?** Not today. The host can pause on `requireApproval`. RV never returns it.
2. **User sees:** host block reason. No RV Ask UI. Official approval surfaces unused.
3. **Back to RV?** Official `onResolution` stays in the plugin and does not write `AllowOnceStore`. Today there is no callback. Host `allow-once` would run this call only — still not an RV grant. Allow-once is TTY → next hook consume.
4. **No pause:** `{ block: true }` or TTY. Never silent allow.

## Hermes

Official: [hooks](https://hermes-agent.nousresearch.com/docs/user-guide/features/hooks), [plugins](https://hermes-agent.nousresearch.com/docs/user-guide/features/plugins) — `pre_tool_call` may `{"action": "block", "message"}` or `{"action": "approve"}` (escalates to the human-approval gate; deny / timeout / gate error fail closed). Hook exceptions are isolated (would fail open). User plugins are opt-in: `hermes plugins enable rv-guard`.

RV: `rv-guard-hermes.py.tmpl` + `HermesHostCodec`. `terminal` only. Live deny: `{"action": "block", "message"}`. Ask: `decision:ask` → confirm (`RV_ASK_CONFIRM` in tests; production `request_tool_approval` with unique `rv-ask:<uuid>`) → `hostAsk=spend` → `None` only if spend allow. Never return `{"action": "approve"}` (leftover-ask-as-permit). Exceptions block (`rv failed`). Setup writes `~/.hermes/plugins/rv-guard/`; dark until enabled.

1. **Pause?** Yes. Confirm then spend. Missing gate / timeout / confirm-no → block, no spend.
2. **User sees:** Hermes approval prompt (or test confirm), then the tool runs once or a block message.
3. **Back to RV?** Confirm-yes spends through PolicyGate this turn. Replay without a grant asks again.
4. **No pause / fail:** `{"action": "block"}`. Never silent allow.

## Codex

Official: [hooks](https://developers.openai.com/codex/hooks) — PreToolUse documents `hookSpecificOutput.permissionDecision: deny` and this older block shape:

```json
{"decision":"block","reason":"..."}
```

Exit code `2` also blocks (stderr reason). `permissionDecision: "ask"` is leftover-ask-as-permit: Codex marks the hook failed and continues the tool.

RV: `rv-guard-codex.py.tmpl` + `CodexHostCodec`. Matcher `PreToolUse` / `Bash`. Live deny: official older `{"decision":"block","reason"}` on stdout, the 271 blocking reason on **stderr**, and process exit **2**. Exit 2 without a trimmed non-empty stderr reason fail-opens the tool (empty / whitespace / a bare newline is the same hole). Tests fail Claude `permissionDecision: deny`, stdout-only `block`, and missing-reason whitespace stderr as the honor path. `HostNativeAsk.capability(.codex)` is `denyOrTTY`. Host-only (OPE-269). No Ask.

1. **Pause?** Not today. Official `"ask"` would fail-open the tool. RV never emits it.
2. **User sees:** host block reason. No RV Ask UI.
3. **Back to RV?** Block JSON + exit 2 is one-way. Allow-once is TTY → next hook consume.
4. **No pause:** official `block` + trimmed non-empty stderr reason + exit 2, or TTY. Never silent allow.

## Cursor

Official: [hooks](https://cursor.com/docs/hooks.md) — `beforeShellExecution` documents this native stdout JSON (exit 0 = use the JSON):

```json
{"permission":"deny","user_message":"...","agent_message":"..."}
```

Allow is `{"permission":"allow"}`. Exit code `2` is Claude-compat deny, not the honor path. Nested Claude `hookSpecificOutput.permissionDecision` is third-party compat only ([third-party hooks](https://cursor.com/docs/reference/third-party-hooks)). `permission: "ask"` exists on `beforeShellExecution`. Default hook failure is fail-open; setup must set `failClosed: true`.

RV: `rv-guard-cursor.py.tmpl` + `CursorHostCodec`. Event `beforeShellExecution` (also decode `preToolUse` + `Shell`/`Bash` as shell). Live deny: official native `{"permission":"deny","user_message","agent_message"}` on stdout and process exit **0**. Empty / missing / whitespace stdout — including exit 0 — is official deny (`rv failed`), never allow. Tests fail Claude `permissionDecision`, Codex `decision: block` + exit 2, leftover `permission: ask`, and empty stdout + exit 0 as the honor path. `HostNativeAsk.capability(.cursor)` is `denyOrTTY`. Host-only (OPE-270). No Ask. `encodeAsk` equals `encodeDeny`.

1. **Pause?** Not today. Official `"ask"` is leftover-ask-as-permit on this ticket. RV never emits it.
2. **User sees:** host `user_message` / `agent_message`. No RV Ask UI.
3. **Back to RV?** Permission deny + exit 0 is one-way. Allow-once is TTY → next hook consume.
4. **No pause:** official `permission: deny` + exit 0, or TTY. Never silent allow.

## Unknowns

Pi `confirm` in print/RPC; whether OpenCode `permission.ask` (or an `ask()` on `tool.execute.before`) is live; whether Claude extra `hookSpecificOutput` keys on today's deny JSON (`ruleId` / `packId` / `severity` / `remediation`) fail-open a deny; OpenClaw approval-surface availability without a connected Gateway; Hermes approve-gate UI shape and whether a post-Allow retry re-enters `pre_tool_call`.
