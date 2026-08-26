# Host Ask investigation (OPE-267)

Investigation only. No Ask code. Main `d67c383`. Linux + macOS.

**RV wire today:** allow or deny before the command runs. None of these five pause for Ask. `HookMapper` switches on `Decision`. Allow is empty stdout / exit 0. Deny and indeterminate call `encodeDeny` (Claude is the only rich encoder). Adapters honor `decision=deny` regardless of exit; missing `rv`, timeout, or crash is a host block (`rv missing` / `rv failed`), never silent allow. `HardPolicyDecision.mandatoryHuman` / `BoundReview` still project to `Decision.deny` on this wire. `ApprovalContinuation.hostNative` is a domain type only.

**Allow-once is a PolicyGate grant, not host Ask.** `rv allow-once` mints/redeems on a TTY into `AllowOnceStore`. The next matching `rv hook` evaluate (`GatedEvaluate` `.apply` → `PolicyGate.apply`) spends `{matchingView, cwd}` and returns allow. A host Allow, if one existed, would not write that grant. The other unlock is run the same command in Terminal (not a hooked shell).

## Pi

Official: [extensions](https://pi.dev/docs/latest/extensions) — `tool_call` returns `{ block: true, reason }` and may `await ctx.ui.confirm(...)` first.

RV: `rv-guard.ts.tmpl` + `PiHostCodec`. `pi.on("tool_call")`, `bash` only. Live deny: `{ block: true, reason }` (operator `{decision,reason}` JSON, exit 1) plus display-only `rv-decision` card. Tests forbid `confirm`.

1. **Pause?** Not today. The host can hold `tool_call` on `ctx.ui.confirm` (TUI/RPC; print/JSON `hasUI` is false and `confirm` returns false). RV never calls it.
2. **User sees:** deny card (Why/Cmd/Meta/Next) and the host block reason. No Allow prompt. No TTY.
3. **Back to RV?** Deny is one-way. Confirm-yes would return and the command would run — no PolicyGate grant. Allow-once is TTY → next hook consume.
4. **No pause:** `{ block: true }` or TTY. Never silent allow.

## OpenCode

Official: [plugins](https://opencode.ai/docs/plugins/) — `tool.execute.before`; documented deny is `throw new Error`. Events include `permission.asked` / `permission.replied`. No official plugin return that waits, then resumes.

RV: `rv-guard.js.tmpl` + `OpenCodeHostCodec`. `bash` only. Live deny: toast `RV · Blocked`, then `throw new Error(reason)` (operator `{decision,reason}` JSON, exit 1). Tests forbid `permission.ask`.

1. **Pause?** Not today. Plugin path is throw (deny) or return (allow). Host permission config can require approval; that prompt is OpenCode's and does not reach PolicyGate.
2. **User sees:** toast chrome, then a thrown error. No Ask prompt from RV.
3. **Back to RV?** Throw is one-way deny. Allow-once is TTY → next hook consume.
4. **No pause:** throw or TTY. Never silent allow.

## Claude

Official: [hooks](https://code.claude.com/docs/en/hooks-guide) — `PreToolUse` `permissionDecision` is `allow` | `deny` | `ask` | `defer`. `"ask"` shows the native permission prompt. `PermissionRequest` fires when Claude is about to ask.

RV: `ClaudeHostCodec` + settings-merge `PreToolUse` / `Bash`. Live deny: exit 0 + JSON `permissionDecision: "deny"` (never `"ask"`; `claude-host.md` CL-later-ask). Allow is empty stdout. Rich `systemMessage` / `permissionDecisionReason`.

1. **Pause?** Not today. The host can pause if RV emitted `"ask"`. RV emits `"deny"`.
2. **User sees:** branded rich deny (`RV · Blocked` + reason). No Ask prompt from RV.
3. **Back to RV?** Deny JSON is one-way. A later Claude Allow would run the tool inside Claude — not a PolicyGate grant (`claude-host.md`: never treat ask-approve as allow-once). Allow-once is TTY → next hook consume.
4. **No pause:** deny or TTY. Never silent allow.

## OpenClaw

Official: [hooks](https://docs.openclaw.ai/plugins/hooks), [permission requests](https://docs.openclaw.ai/plugins/plugin-permission-requests) — `before_tool_call` may `{ block: true, blockReason }` (terminal) or `requireApproval` (pauses; `allow-once` / `allow-always` / `deny` via approval UI or `/approve`; timeout / no route / cancel block). `block: true` wins over `requireApproval`.

RV: `rv-guard-openclaw.js.tmpl` + `OpenClawHostCodec`. Matcher `["exec"]`. Live deny: `{ block: true, blockReason }` (operator `{decision,reason}` JSON, exit 1). Tests forbid `requireApproval`. Host-only (OPE-266).

1. **Pause?** Not today. The host can pause on `requireApproval`. RV never returns it.
2. **User sees:** host block reason. No RV Ask UI. Official approval surfaces unused.
3. **Back to RV?** Official `onResolution` stays in the plugin and does not write `AllowOnceStore`. Today there is no callback. Host `allow-once` would run this call only — still not an RV grant. Allow-once is TTY → next hook consume.
4. **No pause:** `{ block: true }` or TTY. Never silent allow.

## Hermes

Official: [hooks](https://hermes-agent.nousresearch.com/docs/user-guide/features/hooks), [plugins](https://hermes-agent.nousresearch.com/docs/user-guide/features/plugins) — `pre_tool_call` may `{"action": "block", "message"}` or `{"action": "approve"}` (escalates to the human-approval gate; deny / timeout / gate error fail closed). Hook exceptions are isolated (would fail open). User plugins are opt-in: `hermes plugins enable rv-guard`.

RV: `rv-guard-hermes.py.tmpl` + `HermesHostCodec`. `terminal` only. Live deny: `{"action": "block", "message"}` (operator `{decision,reason}` JSON, exit 1). Tests forbid `"action": "approve"`. Adapter catches exceptions and blocks (`rv failed`). Setup writes `~/.hermes/plugins/rv-guard/`; dark until enabled. Host-only (OPE-265).

1. **Pause?** Not today. The host can pause on `approve`. RV never returns it.
2. **User sees:** block message on the host / model. No Ask UI from RV.
3. **Back to RV?** A later Hermes-gate Allow would run the tool inside Hermes — not a PolicyGate grant. Allow-once is TTY → next hook consume.
4. **No pause:** `{"action": "block"}` or TTY. Never silent allow.

## Unknowns

Pi `confirm` in print/RPC; whether OpenCode `permission.ask` (or an `ask()` on `tool.execute.before`) is live; whether Claude extra `hookSpecificOutput` keys on today's deny JSON (`ruleId` / `packId` / `severity` / `remediation`) fail-open a deny; OpenClaw approval-surface availability without a connected Gateway; Hermes approve-gate UI shape and whether a post-Allow retry re-enters `pre_tool_call`.
