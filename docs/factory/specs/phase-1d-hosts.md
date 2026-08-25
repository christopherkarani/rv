# Phase 1d — Hosts + install (T4–T7)

Locked law: [`docs/factory/PLAN.md`](../PLAN.md). If this spec and PLAN disagree, PLAN wins. Implement only in `~/CodingProjects/rv`. Not ryk. Do not implement inside ryk. Do not install or rebind ryk.

Parity source is DCG **0.11.0** decisions / `rule_id`s, not DCG’s Claude-first installer, rich hook stderr, or `DCG_BYPASS`. Host wire shapes below are taken from the host’s own docs (and DCG only where it restates those docs). If a field is not in **Open questions** and not in a cited host contract, do not emit it.

## Goal

Ship the day-one product moment: **Pi / Grok / OpenCode shell hooks** block `git reset --hard` with native host deny text, then stay quiet on allow.

Phase 1d is four tickets on one ladder:

| Ticket | Outcome | Gate |
|---|---|---|
| **T4** | Grok `HostCodec` + `rv hook` + stdin/stdout fixtures | L3 |
| **T5** | Pi + OpenCode shell codecs + rv-owned adapters + fixtures | L3 |
| **T6** | `install.sh` + `rv setup` / `uninstall` on a **temp HOME** | L4 |
| **T7** | `rv doctor` (service + hosts + packs) | L1 |

After this phase a real-HOME hero install (`curl | sh`) plus `rv setup` is what wires hooks. Tests never do that to the operator’s live `~/.grok`, `~/.pi`, or `~/.config/opencode`.

## Non-goals

- Evaluating commands (T1 owns `evaluate`). Codecs extract a shell string; CLI calls evaluate.
- Pretty / browse panels on the hook path (T2). Hooks use `hostDenyText` only.
- Inventing `doctorSnapshot` IPC fields (T3 owns `rv.ipc.v1`). T7 **reads** the T3 snapshot if present; it does not redesign IPC.
- TTY `allow-once` mint / consume (T8). Deny copy may name `rv allow-once`. Do not print a fabricated code. **No `RV_BYPASS`.**
- Remaining catalog packs or `rv packs` (T9). Day-one packs stay `core.git` + `core.filesystem`.
- Claude, Codex, Gemini, Copilot, Cursor, Hermes, Antigravity, or any other host.
- Read / Edit / Write / MCP / `apply_patch` / `user_bash` hooks.
- Pi `ctx.ui.confirm` / `notify` as the deny path. OpenCode toast as the deny path. Display-only Pi `registerMessageRenderer` and OpenCode `client.tui.showToast` are allowed (not the deny path).
- Host Allow button, leftover-ask-as-permit, `permission.ask` as a permit channel.
- Project-local hooks (`.grok/hooks/`, `.pi/extensions/`, `.opencode/plugins/`) in v1.
- Writing `~/.grok/config.toml`, `~/.claude/settings.json`, `~/.cursor/hooks.json`, Pi `settings.json`, or `opencode.json`.
- Merging into foreign hook files (`dcg.json`, other `*.ts` / `*.js`).
- ryk detection or special-case.
- License, telemetry, SaaS, network pack install, Mac app, Linux/Windows/Intel/macOS 14/15.
- Claiming OS-enforced / Seatbelt. Grade is **hook**. Agents can still edit hook files — doctor may say so; do not pretend otherwise.

## Depends on

| Ticket | Why Phase 1d needs it |
|---|---|
| **T0** | `RVHooks` + `RVCLI` + `RVHooksTests` exist. Empty-module `swift test` green. |
| **T1** | `Decision`, `RuleID`, `PackID`, `ShellCommand`, `EvaluationRequest` / `EvaluationResult`, `evaluate`, SKILL.md + core-pack corpus. **T4 must not start before T1 is green.** |
| **T2** | `hostDenyText(from:command:)` is the only hook reason string. T2 snapshots lock voice. T4–T7 must not invent a second deny sentence. |
| **T3** | Optional at T4 compile time: thin XPC client + in-process fallback + `doctorSnapshot`. If T3 is merged, `rv hook` uses it. If not, `rv hook` evaluates in-process. **Never allow because `rvd` is down or skewed.** |

T8 is not a dependency. Unlock text may mention `rv allow-once` without implementing it.

## Parallel / worktree

- **T4 before T5.** Same module (`RVHooks`), same worktree: `feat/t4-t5-hooks`, branched from the T1-green SHA (merge T2/T3 as needed for `hostDenyText` / XPC client).
- **T4 must not start before T1.** No Grok fixtures against a stub `evaluate`.
- **T5 does not start** until T4’s L3 Grok fixtures are green (codec + `rv hook` exist).
- **T6 and T7 may run in parallel worktrees** (`feat/t6-install`, `feat/t7-doctor`) **only if file ownership is split** as below. Both branch from a SHA that already has T4 fixtures (PLAN: “after T4 fixtures exist”). If T7 needs a setup path that this spec does not name, T7 waits for T6.
- Two agents **must not** share a working tree. Use git worktrees from the same base SHA.
- **`Package.swift`:** do not add/remove modules. T4–T7 only add sources and test fixtures under existing targets. RVHooks embeds Host adapter resources; RVCLI embeds the LaunchAgent resource. If that ownership edit collides with T3/T7, stop and write a merge plan.

| Worktree | Owns | Must not edit |
|---|---|---|
| `feat/t4-t5-hooks` | `Sources/RVHooks/**` including embedded Host adapter resources, `Tests/RVHooksTests/**`, `rv hook` in `RVCLI` | `install.sh`, setup/uninstall writers, `rv doctor` |
| `feat/t6-install` | `install.sh`, `rv setup` / `uninstall`, Host adapter detection and filesystem mutations | `RVHooks` behavior, `rv doctor` |
| `feat/t7-doctor` | `rv doctor`, `DoctorViewModel` fields, doctor tests | `install.sh`, setup/uninstall, hook codecs |

T7 reads the **T6 path contract** in this spec (owned filenames, detect rules, occupied-skip). It does not discover new paths.

## T4 Grok

Grok is the only v1 host with a **native command-hook stdin/stdout protocol**. T4 implements that protocol and the `rv hook` process Grok execs. Pi and OpenCode do **not** speak this envelope; do not pretend they do.

Sources for the wire (do not “fix” them into Claude shape):

- [xAI Hooks](https://docs.x.ai/build/features/hooks)
- [Grok Build `10-hooks.md`](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-pager/docs/user-guide/10-hooks.md) (same contract as a current `~/.grok/docs/user-guide/10-hooks.md`)

### T4.1 What Grok runs

Personal hooks are every `*.json` under `~/.grok/hooks/`. T6 writes **only** `$HOME/.grok/hooks/rv.json`. T4’s job is the process that file will exec.

`rv.json` shape (T6 writes it; T4 fixtures may embed the same object):

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "/abs/path/to/rv hook --host grok",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

Rules:

- Event key in the **file** is `PreToolUse`. The **stdin** event name is `pre_tool_use`.
- `matcher` is `"Bash"`. Grok aliases Claude `Bash` → `run_terminal_command` and still matches `Bash`. An omitted matcher would also fire on Read/Edit/MCP — **forbidden**.
- `type` is `"command"` only. No `"http"`.
- `timeout` is `5` (Grok’s documented default). The hook must finish well under that. Do not raise it to hide a slow evaluate.
- `command` is an absolute path to the installed `rv` plus `hook --host grok`. Write `$HOME/.local/bin/rv` at setup time (curl install). Do not probe Homebrew.
- Do not register `PostToolUse`, `Stop`, `SessionStart`, or any other event.

### T4.2 Stdin (Grok → `rv hook`)

JSON object on stdin. Documented `PreToolUse` example:

```json
{
  "hookEventName": "pre_tool_use",
  "sessionId": "abc-123",
  "cwd": "/Users/you/project",
  "workspaceRoot": "/Users/you/project",
  "permissionMode": "default",
  "toolName": "run_terminal_command",
  "toolInput": { "command": "npm test" },
  "timestamp": "2026-04-14T12:00:00Z"
}
```

**Required for evaluate (T4):**

| Field | Treat as |
|---|---|
| `hookEventName` | Must be `pre_tool_use` to classify as Grok. Other events: exit 0, empty stdout (passive / not our gate). |
| `toolName` | Shell iff `run_terminal_command` **or** `run_terminal_cmd` **or** `Bash`. Anything else: allow (empty stdout, exit 0). Do not evaluate. |
| `toolInput.command` | The shell string. Missing / empty / non-string: allow. |

**Accepted if present, not required, not logged:** `sessionId`, `cwd`, `workspaceRoot`, `permissionMode`, `timestamp`, `promptId`, `toolUseId`, `toolInputTruncated`. Do not persist them. Do not put `command` in `os_log`.

**Env Grok injects** (reserved; useful for tests, not a substitute for stdin): `GROK_HOOK_EVENT`, `GROK_HOOK_NAME`, `GROK_SESSION_ID`, `GROK_WORKSPACE_ROOT`, `CLAUDE_PROJECT_DIR`. Do **not** skip evaluate because `permissionMode` is `bypassPermissions` or because any `GROK_*` / `RV_*` env is set.

`run_terminal_cmd` vs `run_terminal_command`: current Grok docs and the installed user guide use `run_terminal_command`. DCG 0.11.x accepts both after their issue #319. T4 accepts both. Do not invent a third spelling.

Unknown extra stdin keys: ignore. Do not require them. Do not fail closed.

### T4.3 Stdout + exit ( `rv hook` → Grok)

Grok fail-open: timeout, crash, malformed output, or a non-`deny` result **does not block**. Only an explicit `deny` blocks. A `deny` JSON on stdout is honored **regardless of exit code**. Exit `2` is also an explicit deny (stderr can supply a reason if JSON has none). Other exits are fail-open.

T4 locked behavior:

| Evaluate | stdout | exit | Notes |
|---|---|---|---|
| Allow (non-shell, default-allow, medium/low match) | **empty** | `0` | Silent. Do not emit `{"decision":"allow"}`. Do not emit a reason. Empty command is the Parse failure row (`missingCommand`), not this one. |
| Deny (engine deny) | `{"decision":"deny","reason":"<hostDenyText>"}` plus a trailing newline | `0` | JSON is the gate. `reason` is T2 `hostDenyText` only. |
| Indeterminate (oversize / budget / core packs unloadable) | `{"decision":"deny","reason":"rv could not finish evaluating this command. Run it in Terminal."}` | `0` | Not empty allow. No pack `rule_id`. |
| Parse failure / unreadable stdin / missing command | `{"decision":"deny","reason":"<malformedHookSentence>"}` plus a trailing newline | `0` | Fail-closed. No pack `rule`/`next`. Evaluate is not called. No pretty stderr. |
| `rvd` down or version-skewed | *(evaluate in-process, then the Allow, Deny, or Indeterminate row)* | — | Never allow *because* XPC missed. Never treat in-process `indeterminate` as the Allow row. |

Do **not**:

- Use `"decision":"block"` (Hermes). Grok ignores that as a block keyword.
- Use Claude `hookSpecificOutput.permissionDecision`.
- Emit `updatedInput` / rewrite the command.
- Put extra required keys on stdout (`ruleId`, `packId`, `allowOnceCode`, …). Grok’s documented deny object is `decision` + `reason`. Put `rule_id` **inside** `reason` via `hostDenyText`. Extra keys are not part of this contract (see Open questions).
- Write pretty panels, box drawing, or CSI to stdout or stderr. Stderr stays empty on the success path. Grok may surface the first stderr line; do not use that channel.
- Treat `matched != nil` as deny. Medium/low match (`git stash drop`) is allow: empty stdout. Encode deny JSON only when `Decision` is `deny` or `indeterminate`.

### T4.4 `rv hook` CLI

T2 reserved this name. T4 adds it.

```
rv hook [--host grok]
```

- Reads stdin to EOF. No TTY. Not a pretty/browse mode.
- T4: `--host` defaults to `grok` when omitted. T5 keeps that default **only** when stdin is a Grok envelope (`hookEventName == "pre_tool_use"` or shell `toolName` in the T4.2 set). Pi/OpenCode adapters must pass `--host`.
- Calls evaluate (XPC if T3 is present and healthy, else in-process). Same `EvaluationRequest` T1 already tests.
- Switch on `Decision`, never on `matched != nil` and never on `hostDenyText == nil` alone.
- `Decision.allow` (including medium/low match) → empty stdout, exit 0.
- `Decision.deny` → T4.3 deny JSON, exit 0.
- `Decision.indeterminate` → T4.3 indeterminate deny JSON, exit 0, even if `hostDenyText` is nil.
- No `RV_BYPASS`. No `--force`. No env the child honors to skip evaluate.

`RVHooks` owns decode/encode. `RVCLI` owns I/O, evaluate, and `hostDenyText`. `RVHooks` must not import CLI, TUI, Presentation, or XPC.

Suggested surface (names may match T1 style; keep it this small):

```swift
public enum HookHost: String, Equatable, Sendable {
    case grok
    // T5 adds: case pi, case opencode
}

public struct HookRequest: Equatable, Sendable {
    public var host: HookHost
    public var command: ShellCommand?    // nil → allow, do not evaluate
}

public struct HookWire: Equatable, Sendable {
    public var stdout: String            // empty on allow
    public var exitCode: Int32
}

public protocol HostCodec: Sendable {
    var host: HookHost { get }
    func decode(_ stdin: String) -> HookRequest
    func encodeAllow() -> HookWire
    func encodeDeny(reason: String) -> HookWire
}
```

T4 ships `GrokHostCodec` only. `decode` never throws into a crash path; garbage → `command == nil`. `encodeDeny` is used for engine deny **and** indeterminate (different `reason`). There is no `encodeAllow` path for `Decision.indeterminate`.

### T4.5 Fixtures (L3)

Checked-in under `Tests/RVHooksTests/Fixtures/grok/`. Each case is stdin file + expected stdout + expected exit. Drive `GrokHostCodec` **and** `rv hook --host grok` (process or in-module CLI entry) with `HOME` set to a temp directory.

| Fixture | Stdin gist | Expect |
|---|---|---|
| `allow-git-status.json` | `toolName: run_terminal_command`, `toolInput.command: git status` | empty stdout, exit 0 |
| `deny-git-reset-hard.json` | `command: git reset --hard` | stdout JSON `decision=deny`, `reason` equals T2 `hostDenyText` for that result (contains `core.git/reset-hard` or T1’s locked `RuleID` display, and `rv allow-once`), exit 0 |
| `deny-reason-is-one-line.json` | same deny | `reason` has no `\\n`, no `═`, no CSI |
| `allow-non-shell-read.json` | `toolName: read_file` (or `Read`) | empty stdout, exit 0, **evaluate not called** |
| `deny-empty-command.json` | `toolInput: {}` | deny JSON, reason is `malformedHookSentence(.missingCommand)`, no pack `rule`/`next`, **evaluate not called**, exit 0 |
| `allow-legacy-run-terminal-cmd.json` | `toolName: run_terminal_cmd`, `git status` | empty stdout, exit 0 |
| `ignore-passive-session-start.json` | `hookEventName: session_start` | empty stdout, exit 0 |
| `malformed.txt` | not JSON | deny JSON, reason is `malformedHookSentence(.unreadable)`, no pack `rule`/`next`, **evaluate not called**, exit 0 |
| `allow-medium-stash-drop.json` | `command: git stash drop` | empty stdout, exit 0 — **not** deny JSON |
| `deny-indeterminate-oversize.json` | command longer than 65_536 bytes that also contains `git reset --hard` | deny JSON, reason is the incomplete-eval sentence, no pack `rule_id`, exit 0 |

Also assert: codec does not emit `block`, `hookSpecificOutput`, or `updatedInput` on deny.

## T5 Pi and OpenCode

Neither host pipes JSON to a subprocess. Both are in-process JS/TS. T5 ships **rv-owned adapters** that call `rv hook --host …` and map the result onto the host’s **documented** deny API. The JSON between adapter and `rv hook` is an **RV adapter contract**, not a Pi/OpenCode protocol. Do not document it as if the host sent it.

T5 adds `HookHost.pi`, `HookHost.opencode`, `PiHostCodec`, `OpenCodeHostCodec`, and the two adapter templates T6 will install.

### T5.1 Pi — host contract (not stdin)

Sources:

- [Pi Extensions](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md)
- [pi.dev extensions](https://pi.dev/docs/latest/extensions)

Pi loads TypeScript from:

| Path | v1 setup |
|---|---|
| `~/.pi/agent/extensions/*.ts` | **Write** `$HOME/.pi/agent/extensions/rv-guard.ts` |
| `~/.pi/agent/extensions/*/index.ts` | Do not use |
| `.pi/extensions/*.ts` | Do not write (project-local; needs trust) |
| `settings.json` `"extensions"` array | Do not edit |

Factory: `export default function (pi) { … }`. Node built-ins (`node:child_process`, `node:fs`, …) are available.

**Gate:** evaluate only on `pi.on("tool_call", …)`. Display-only `registerMessageRenderer` is chrome.

| Host field | v1 use |
|---|---|
| `event.toolName` | Evaluate only `"bash"`. All other tools (including `read`, `write`, `edit`): return nothing. |
| `event.input.command` | Shell string when `toolName === "bash"`. |
| `event.input.timeout` | Ignore. |
| return `{ block: true, reason }` | Deny. `reason` is `hostDenyText`. This is the block path. |
| return `{ block: true, reason, terminate: true }` | **Do not use.** Stops the agent, not just the tool. |
| mutate `event.input` | **Do not.** No rewrite. |
| `ctx.ui.confirm` / `notify` / `custom` | **Do not.** That is a host Allow / extra UI. |
| `pi.registerMessageRenderer` | Display-only deny card for `rv-decision`. Must return `{ render(width) => string[] }`, never a string. Not the deny path. |
| `pi.sendMessage` | Deny only. `customType` `rv-decision`, `display: true`, `triggerTurn: false`. Allow stays silent. A throw here must not fail-open. |
| `user_bash` | **Do not hook.** User `!` is Terminal-like, not the agent shell tool. |

Pi documents: `tool_call` **errors block the tool (fail-safe)**. PLAN miss policy: cannot spawn `rv` (ENOENT) → return `{ block: true, reason: "rv missing" }`. A started `rv` that times out or crashes → `{ block: true, reason: "rv failed" }`. Honor deny JSON regardless of exit code. `rvd` down/skew is not this case — `rv hook` still in-process-evaluates and must deny. Do not catch-and-allow a missing binary.

DCG’s Pi recipe calls `dcg --robot test` and maps exit `1` → `{ block: true, reason }`. rv does **not** reuse DCG robot mode. The adapter calls `rv hook --host pi`.

### T5.2 OpenCode — host contract (not stdin)

Sources:

- [OpenCode Plugins](https://opencode.ai/docs/plugins/)
- [OpenCode Tools](https://opencode.ai/docs/tools/) (built-in tool name `bash`, args include `command`)

Discovery (auto-load; do not edit `opencode.json`):

| Path | v1 setup |
|---|---|
| `~/.config/opencode/plugins/` | **Write** `$HOME/.config/opencode/plugins/rv-guard.js` |
| `.opencode/plugins/` | Do not write |
| `opencode.json` `"plugin"` npm array | Do not edit |

Official plugin: named export of an async function that returns a hooks object. Hook key is the **top-level dotted string** `"tool.execute.before"`. Nested `tool: { execute: { before } }` is wrong (OpenCode treats `tool` as custom-tool registration).

Documented callback:

```ts
"tool.execute.before": async (input, output) => { /* input.tool, input.sessionID, input.callID, output.args */ }
```

| Host field | v1 use |
|---|---|
| `input.tool` | Evaluate only `"bash"`. Skip `read`, `write`, `edit`, `apply_patch`, MCP, custom tools. |
| `output.args.command` | Shell string for `bash`. |
| `throw new Error(reason)` | Deny. Message is `hostDenyText`. This is the documented abort. |
| `client.tui.showToast` | Display-only chrome on deny. Title `RV · Blocked`, message Why/Cmd/Meta/Next (parsed from `hostDenyText` + command). Variant `error`. Bind the method. Call `{ body }`-wrapped first; the plugin client is the legacy SDK (errors resolve, never throw), so fall back to flat only when the wrapped result carries `.error`. Best-effort; never skip throw if toast fails. Throw text stays `hostDenyText`. Do not `console.log` / `console.error` (OpenCode dumps those into the TUI). |
| mutate `output.args` | **Do not.** |
| `"tool.execute.after"` | Do not register. |
| `permission.ask` | Do not register (Allow-button territory). |
| toast as the deny path | **Forbidden.** |

Allow = return without throwing. Official examples use `input.tool === "bash"` and `output.args.command`. Do not invent a `shell` alias unless a later Open question is closed.

Community DCG plugins spawn `dcg` and throw on deny. T5 does the same shape with `rv hook --host opencode`. Do not send Claude `tool_name` / `hookSpecificOutput` and claim OpenCode defined it.

### T5.3 RV adapter stdin/stdout (not a host protocol)

Adapters spawn:

```
<abs-path-to-rv> hook --host pi        # or opencode
```

stdin is JSON **we** define so fixtures can lock the codec. It mirrors the host fields we actually read — it is not something Pi or OpenCode writes to a pipe.

**Pi adapter → `rv hook --host pi` stdin:**

```json
{ "toolName": "bash", "input": { "command": "git reset --hard" } }
```

**OpenCode adapter → `rv hook --host opencode` stdin:**

```json
{ "tool": "bash", "args": { "command": "git reset --hard" } }
```

**`rv hook --host pi|opencode` stdout / exit** (RV-owned, adapter-only):

| Evaluate | stdout | exit |
|---|---|---|
| Allow | empty | `0` |
| Deny | `{"decision":"deny","reason":"<hostDenyText>"}` plus newline | `1` |
| Indeterminate | `{"decision":"deny","reason":"rv could not finish evaluating this command. Run it in Terminal."}` plus newline | `1` |

Exit `1` is for the adapter (Pi/OpenCode have no Grok-style stdout parser). The host never sees this JSON. The adapter:

- deny JSON (`decision=deny`) **regardless of exit code** → Pi `{ block: true, reason }` / OpenCode `throw new Error(reason)`
- empty stdout + exit `0` → allow (return / do not throw)
- cannot spawn `rv` (ENOENT) → Pi `{ block: true, reason: "rv missing" }` / OpenCode throw the same. Grok’s host fail-opens if the process never starts.
- started `rv` times out, crashes, or returns non-JSON → Pi/OpenCode **block** with `rv failed`. Not silent allow.

Do not call `rv test --robot` from adapters. That schema is `rv.test.v1` (T2), a human/script surface, not a host codec.

Absolute `rv` path: T6 bakes it into the adapter at setup (same as Grok `command`). Do not rely on the host’s `PATH`.

### T5.4 Fixtures (L3)

`Tests/RVHooksTests/Fixtures/pi/` and `…/opencode/`.

| Fixture | Expect |
|---|---|
| `pi/allow-git-status.json` | empty, exit 0 |
| `pi/deny-git-reset-hard.json` | deny JSON, exit 1, `reason` == `hostDenyText` |
| `pi/allow-non-shell-read.json` | `toolName: read` → empty, exit 0, no evaluate |
| `opencode/allow-git-status.json` | empty, exit 0 |
| `opencode/deny-git-reset-hard.json` | deny JSON, exit 1, same `reason` as Pi/Grok for the same command |
| `opencode/allow-non-shell-read.json` | `tool: read` → empty, exit 0, no evaluate |

Adapter unit tests (string/source fixtures, not a live Pi/OpenCode):

- Pi template: registers `tool_call` plus display-only `registerMessageRenderer`; no `confirm`; no `terminate: true`; no `user_bash`. Renderer returns a component, never a string. Deny posts one `rv-decision` message; allow posts none.
- OpenCode template: top-level `"tool.execute.before"` only; display-only `showToast` on deny; no nested `tool.execute`; no `permission.ask`. Toast failure still throws.
- Both: non-`bash` returns without spawning `rv` (or spawns and codec allows — prefer skip-spawn).
- deny JSON + exit 0 → still block / throw (honor deny regardless of exit).
- ENOENT spawn → block / throw `rv missing`.
- started `rv` timeout or crash → block / throw `rv failed`.

Same `hostDenyText` for `git reset --hard` across Grok `reason`, Pi `reason`, and OpenCode `Error` message.

## T6 install and setup

Hero: `curl -fsSL …/install | sh` on a **real HOME** (operator machine, when the human asks). Quiet binary install into `$HOME/.local/bin`, then `rv setup`. **v1 is curl only.** No Homebrew formula, tap, bottle, `post_install`, or brew README path. Homebrew is Phase 4+.

Tests use a temp `HOME`. Never write the operator’s live `~/.grok`, `~/.pi`, or `~/.config/opencode` unless the human asked.

### T6.1 Path contract (T7 reads this)

All setup / uninstall / doctor host probes honor **`$HOME` only** (process environment). Do not use `NSHomeDirectory()` / `homeDirectoryForCurrentUser` — on macOS those can ignore `HOME` and punch the operator’s real dotfiles.

| Kind | Path | Owned? |
|---|---|---|
| Config | `$HOME/.config/rv/` | yes (create on first setup if needed) |
| Grok hook | `$HOME/.grok/hooks/rv.json` | yes |
| Pi adapter | `$HOME/.pi/agent/extensions/rv-guard.ts` | yes |
| OpenCode adapter | `$HOME/.config/opencode/plugins/rv-guard.js` | yes |
| Hero binaries | `$HOME/.local/bin/rv`, `$HOME/.local/bin/rvd` | yes (install.sh) |

**Foreign (never write, never rewrite, never delete):**

- `$HOME/.grok/hooks/*` except `rv.json`
- `$HOME/.grok/config.toml`, `trusted_folders.toml`, Claude/Cursor compat files Grok also reads
- `$HOME/.pi/agent/extensions/*` except `rv-guard.ts`
- Pi `settings.json`, project `.pi/`
- `$HOME/.config/opencode/plugins/*` except `rv-guard.js`
- `opencode.json` / `.opencode/`
- anything ryk, anything dcg

**Host detected** (any one is enough):

| Host | Detect |
|---|---|
| Grok | `$HOME/.grok` is a directory **or** `grok` is on `PATH` |
| Pi | `$HOME/.pi` is a directory **or** `pi` is on `PATH` |
| OpenCode | `$HOME/.config/opencode` is a directory **or** `opencode` is on `PATH` |

Do not `mkdir` a host tree to “detect” it. Only mkdir the owned parent (`hooks/`, `extensions/`, `plugins/`) after that host is detected.

**Occupied single slot:** v1 hosts are multi-file, so the exclusive slot is the **owned filename**. If that path exists and is **not** the current rv template (command/path/`--host`/matcher/`tool_call`/`tool.execute.before` as shipped), **skip** that host (TTY hollow + skip clause; non-TTY one line). Do not merge. Do not backup-and-overwrite. Do not special-case `dcg.json` or ryk. A foreign `dcg.json` beside `rv.json` is fine (Grok runs both; first `deny` wins).

If no host is detected: setup still succeeds. No wizard. TTY closer: `No hosts yet` / `Next  rv setup`. Non-TTY: one line to run `rv setup` after a host exists.

If a host was wired: TTY paints the host list (circle-only color) and closes with `Setup complete` / `Next  rv test 'git reset --hard'`. Grok reload `/hooks` is a clause on the Grok row. Occupied is a hollow circle plus a skip clause on that row. Voice: one fact, one next action.

### T6.2 `install.sh`

Repo root: `install.sh`. macOS **26** + **arm64** only. Refuse other `uname` with one line; do not install.

Behavior:

1. Install `rv` and `rvd` into `$HOME/.local/bin` (create the dir). Do not `sudo`.
2. Do not require a host to be present.
3. Run `"$HOME/.local/bin/rv" setup`. Setup owns the TTY show. `install.sh` does not paint a second UI.
4. Hostless setup is still success: binary is installed; closer tells the user to run `rv setup` after a host exists.
5. Do not curl pack JSON. Do not hit telemetry. Do not write foreign hooks.

Release URL / checksum source: see Open questions. Until that is closed, `install.sh` may install from a path or `RV_INSTALL_BIN` override so L4 tests do not need the network. Network-to-GitHub is not an L4 gate.

Do not add a Homebrew formula, tap, bottle, or brew install paragraph. Setup bakes `$HOME/.local/bin/rv` (or `RV_INSTALL_BIN` in tests). Do not call `brew --prefix`.

### T6.3 `rv setup` / `rv uninstall`

```
rv setup
rv uninstall
```

`setup`:

- Idempotent. Second run with matching templates is a no-op (exit 0, no extra chatter).
- If the owned file exists and matches except the `rv` absolute path, rewrite the path (binary moved). That is still an rv-owned file.
- Occupied owned name → skip that host (hollow circle + skip clause on TTY; one line on non-TTY); continue other hosts.
- Does not start a wizard. Does not enable extra packs. Does not reopen `rv test` / `rv explain`.
- **TTY show (pretty only):** three slots — Grok, Pi, OpenCode. All words use default terminal color. **Only the circle is colored:** `○` `Palette.muted`, `●` `Palette.heading` (cyan) when that host is wired. Activity is one default-color status line (`looking for hosts` / `wiring Pi`). LaunchAgent is written, not listed. Packs stay off-camera.
- **TTY closer:** `Setup complete` then `Next  rv test 'git reset --hard'`. Hostless: `No hosts yet` then `Next  rv setup`.
- **Non-TTY / `--robot` / `CI`:** no circles. One line. Same decisions as TTY.
- **Installs** the T3 LaunchAgent template to `$HOME/Library/LaunchAgents/dev.rv.evaluate.plist` with the resolved `rvd` path, `KeepAlive` false, `launchctl bootstrap` if needed. Uninstall removes only that plist. Hooks still work in-process if launchd is down.
- Does not write the operator’s HOME in tests — tests set `$HOME`.

`uninstall`:

- Deletes **only** the owned files in the path table (and `$HOME/.config/rv/` if T6 created it).
- Does not delete foreign hooks or host products.
- Does not uninstall ryk or dcg.
- Idempotent if files are already gone.
- Leaves empty parent dirs alone (do not `rm -rf ~/.grok`).

Host adapter resources live in `Sources/RVHooks/Resources/hosts/` (`rv.json.tmpl`, `rv-guard.ts.tmpl`, `rv-guard.js.tmpl`). T6 consumes them through the RVHooks interface and owns only setup mutations.

### T6.4 L4 tests (temp HOME)

`Tests/RVCLITests/SetupTests` (or equivalent). Each test: `mkdir` temp dir, `setenv("HOME", …)`, run setup/uninstall, assert files, tear down.

| Case | Assert |
|---|---|
| Hostless | no `~/.grok`, `~/.pi`, `~/.config/opencode` created; exit 0; stdout has one line mentioning `rv setup` |
| Grok only | `$HOME/.grok` pre-created; writes `hooks/rv.json` equal to the RVHooks Grok adapter rendered with the baked `rvPath`; leftover `__RV_BINARY__` absent; no other files under `.grok`. Adapter-contract (`PreToolUse` / `matcher: Bash` / `rv hook --host grok`) is `Tests/RVHooksTests/AdapterHookTests` |
| Pi only | writes `rv-guard.ts` equal to the RVHooks Pi adapter rendered with the baked `rvPath`; no `settings.json` edit |
| OpenCode only | writes `rv-guard.js` equal to the RVHooks OpenCode adapter rendered with the baked `rvPath` |
| Occupied `rv.json` | pre-write foreign JSON at owned path; setup skips; file bytes unchanged; one skip line |
| Foreign `dcg.json` | left untouched; `rv.json` still written |
| Idempotent setup | two runs; second is quiet and bytes unchanged |
| Uninstall | owned files gone; `dcg.json` / foreign extension still there |
| `$HOME` isolation | after tests, the operator’s real `~/.grok/hooks/rv.json` (if any) is unchanged — assert by not using the real HOME |
| LaunchAgent | writes `$HOME/Library/LaunchAgents/dev.rv.evaluate.plist` from the T3 template; `KeepAlive` false; uninstall removes only that plist |

Do not run `install.sh` against the real HOME in CI. An `install.sh` smoke may use temp `HOME` + `RV_INSTALL_BIN`.

## T7 doctor

`rv doctor` is a **read** of service + hosts + packs. It does not wire hooks, does not fix files in v1 (no `--fix`), does not write HOME.

T2 left `DoctorViewModel` as a type stub. T7 fills it. T7 must not add setup writers.

### T7.1 What it reports

One fact per line (pretty) or one JSON object (`--robot` / non-TTY, T2 resolver). No pack essays. No command argv.

| Area | Checks | Source |
|---|---|---|
| Service | `rvd` reachable? version match? fallback-would-work? LaunchAgent `dev.rv.evaluate` loaded? | T3 `doctorSnapshot` if present; else local probes T3 documented. If T3 is absent, print `service: not installed` and continue. |
| Packs | `core.git` + `core.filesystem` enabled; extras off | T1/T9 registry. Do not enable anything. |
| Hosts | For each v1 host: **missing** (not detected), **wired** (owned file matches template **and** the baked `rv` path is executable), **broken** (template matches but path missing/non-exec), **occupied** (owned name exists, not ours), **absent-file** (detected, no owned file) | T6 path contract + `$HOME` |
| Grade | Remind: protection is **hook**, not Seatbelt | one line, not a lecture |

Do not scan or print foreign hook contents beyond “occupied / foreign file present at owned name.” Do not mention ryk unless you are listing a generic occupied skip (you should not name ryk).

Exit (v1):

| State | exit |
|---|---|
| Binary ok, packs day-one ok, zero or more hosts wired | `0` (hostless is a **warn line**, not a failure — matches hostless install) |
| Owned file occupied, or detected host unwired | `0` + one warn line per host (operator can run `rv setup`) |
| Unreadable `$HOME/.config/rv/` or pack registry broken | `1` |
| `rvd` version-skewed (T3 present) | `0` + warn (evaluate still in-process). Do not claim the hook is down. |

If this exit matrix fights a later T3 `doctorSnapshot` contract, T3 wins for the service block only; host/pack lines stay as above.

### T7.2 Tests (L1, temp HOME)

- Build `DoctorViewModel` from fixtures (in-memory paths), no live XPC required.
- Temp `HOME` with wired Grok file → host status `wired`.
- Temp `HOME` with foreign `rv.json` → `occupied`.
- Temp `HOME` empty → hosts `missing`, exit 0, mentions `rv setup`.
- Temp `HOME` with a template-matching owned file whose baked `rv` path is `/nonexistent/rv` → host status `broken`, not `wired`.
- Robot snapshot: no box chars, no argv, no `os_log` of commands.
- Do not touch the operator’s real dotfiles.

## Deny text contract

Hook deny is **native host text only**. Same string on all three hosts. Producer is T2 `hostDenyText`. Codecs copy it into the host field. They do not re-sentence it.

Canonical T2 example (do not paraphrase):

```
Blocked git reset --hard (core.git/reset-hard). Run it in Terminal, or rv allow-once.
```

Rules:

- **One sentence** + `rule_id` + **one** next step. One line. No `Tip:`, no alternative list, no second command echo, no DCG box.
- `rule_id` display follows T1/T2 (`core.git/reset-hard` in T2 snapshots). Do not invent a third spelling. DCG’s identity is `core.git` + `reset-hard`.
- Unlock **may** say: run it in Terminal, or `rv allow-once <code>` in a TTY. Until T8, do **not** fabricate `<code>` — T2’s `or rv allow-once` is enough.
- No host Allow button. No leftover-ask-as-permit. No `RV_BYPASS`.
- **Grok:** that string is JSON `reason` only.
- **Pi:** that string is `{ block: true, reason }`. A display-only `rv-decision` card may also appear; it is not the block path.
- **OpenCode:** that string is `throw new Error(reason)`. A display-only TUI toast may also appear; it is not the block path.
- Allow: empty. No “allowed by rv.”

## Files to create

Product files (implement tickets; **this spec does not create them**):

```
Sources/RVHooks/HostCodec.swift
Sources/RVHooks/GrokHostCodec.swift
Sources/RVHooks/PiHostCodec.swift          # T5
Sources/RVHooks/OpenCodeHostCodec.swift    # T5
Sources/RVCLI/HookCommand.swift
Sources/RVCLI/SetupCommand.swift           # T6
Sources/RVCLI/UninstallCommand.swift       # T6
Sources/RVCLI/DoctorCommand.swift          # T7
Sources/RVHooks/Resources/hosts/rv.json.tmpl
Sources/RVHooks/Resources/hosts/rv-guard.ts.tmpl
Sources/RVHooks/Resources/hosts/rv-guard.js.tmpl
Sources/RVPresentation/DoctorViewModel.swift   # T7 fills T2 stub
install.sh
Tests/RVHooksTests/GrokHookTests.swift
Tests/RVHooksTests/PiHookTests.swift
Tests/RVHooksTests/OpenCodeHookTests.swift
Tests/RVHooksTests/Fixtures/grok/*
Tests/RVHooksTests/Fixtures/pi/*
Tests/RVHooksTests/Fixtures/opencode/*
Tests/RVCLITests/SetupTests.swift
Tests/RVCLITests/DoctorTests.swift
```

Do not add Claude/Codex codecs. Do not add files under a ryk tree.

## Acceptance

1. `printf '%s' '<grok deny stdin>' | rv hook --host grok` → deny JSON, `reason` is `hostDenyText`, exit 0. `git status` → empty stdout, exit 0.
2. Same command through `--host pi` and `--host opencode` → same `reason`; exit 1 on deny; adapters would block / throw.
3. Non-shell tool names never evaluate.
4. `HOME=/tmp/rv-l4-… rv setup` wires only detected hosts’ **owned** files; foreign files unchanged; occupied owned name skipped (TTY skip clause; non-TTY one line); hostless TTY closer is `No hosts yet` / `Next  rv setup` (non-TTY one `rv setup` line) and exits 0.
5. `HOME=/tmp/… rv uninstall` removes only owned files.
6. `HOME=/tmp/… rv doctor` reports service (if T3), day-one packs, and host wired/missing/occupied without writing.
7. `curl | sh` on a real HOME is the only v1 install path (human-run). No Homebrew.
8. Day-one win: inside a wired Grok/Pi/OpenCode session, `git reset --hard` is blocked by native text. Allow stays silent.

## Test plan

- **L3 (T4 then T5):** fixture table above. Prefer in-process codec tests; add a `rv hook` process test if the CLI entry is easy. `HOME` is temp even for hook tests (no setup required for codec tests).
- **L4 (T6):** temp-HOME setup/uninstall matrix. Never `rv setup` without overriding `HOME` in automated tests.
- **L1 (T7):** doctor view-model + CLI against fake paths / fake snapshot.
- **Corpus:** deny fixtures use T1’s `git reset --hard` row. Do not invent a new verdict.
- **Live hosts:** not a CI gate. Manual, and only when the human asks to wire this machine.
- **Isolation check:** automated tests fail the ticket if they write under the operator’s real `~/.grok`, `~/.pi`, or `~/.config/opencode`.

## Forbidden

- `RV_BYPASS` or any env the hook child honors to skip evaluate.
- Allowing because `rvd` is down or skewed (in-process evaluate).
- Treating Grok `permissionMode: bypassPermissions` as skip-evaluate.
- Hooking Read / Edit / MCP / `user_bash` / `apply_patch`.
- Pi confirm/notify as deny UX, Pi renderer as the deny path, OpenCode toast as the deny path.
- Host Allow button / `permission.ask` permit UI / leftover-ask rewrite.
- Claude `hookSpecificOutput` as the Grok/Pi/OpenCode deny document.
- Hermes `"decision":"block"` as the Grok deny keyword.
- `updatedInput` / mutating Pi `event.input` / mutating OpenCode `output.args`.
- Pretty panels, ANSI, or DCG-style stderr boxes on the hook path.
- Writing foreign hook files or shared config (`config.toml`, `settings.json`, `opencode.json`).
- Overwriting an occupied owned filename.
- ryk special-case; implementing inside ryk; installing/rebinding ryk.
- Automated tests writing the operator’s live HOME.
- Command text in `os_log`. Default history stays off.
- Claiming Seatbelt / OS-enforced / Linux / Windows / macOS 14/15.
- Telemetry, SaaS, network install of packs.
- Starting T4 before T1. Starting T5 before T4 fixtures. Parallel T6/T7 without the ownership split.

## Open questions

1. **Hero `install.sh` artifact URL and checksum.** Repo is `christopherkarani/rv`, but the GitHub release asset name, signing, and whether T6 vendors a local binary for L4 are not locked. Do not invent a CDN. Tests may use `RV_INSTALL_BIN`.
2. **Whether Grok ever sends the shell string under a key other than `toolInput.command`.** Documented field is `command`. Do not also read invented `cmd` / `CommandLine` keys unless a captured real envelope shows them.
3. **Whether extra Grok stdout keys (`ruleId`, …) are safe.** Grok documents `decision` + `reason` only. DCG adds ergonomics fields and says the parser is permissive. v1 must not require them. Adding them later is optional and not an L3 gate.
4. **Grok deny exit `0` vs `2`.** Both block when deny JSON is present. This spec locks exit `0` + JSON (JSON is the gate; matches DCG’s preferred path). If a future Grok build ignores JSON without exit `2`, capture that envelope and revisit — do not switch speculatively.
5. **OpenCode tool names besides `bash`.** Official docs and plugins use `bash` + `args.command`. If a build emits `shell` or another alias, record it; do not assume it.
6. **Pi adapter spawn API.** Docs promise Node built-ins; DCG uses `node:child_process`. If a Pi build lacks `spawn`, that is a captured-runtime question — do not switch to a made-up Pi stdin protocol.
7. **Adapter miss when `rv` is missing.** Locked (PLAN #6): Pi/OpenCode **block** with `rv missing`. Grok’s host fail-opens if the process never starts. A started `rv` that times out or crashes → Pi/OpenCode **block** with `rv failed`.
8. **T3 `doctorSnapshot` field names.** T7 consumes T3’s types when they exist. Do not invent a second snapshot schema here.
9. **T1 `RuleID` display (`core.git/reset-hard` vs `core.git:reset-hard`).** T2 snapshots use slash. Host `reason` must match T2 `hostDenyText`, not a new form.
10. **Project-local / `--project` hook install.** Not v1. Grok project hooks also need `/hooks-trust`.
11. **Launchd install from `rv setup`.** Locked (PLAN #10): T6 owns writing `$HOME/Library/LaunchAgents/dev.rv.evaluate.plist` from the T3 template, `KeepAlive` false. T3 does not load a live agent.
12. **Whether `rv hook` without `--host` should auto-detect only Grok.** T4 defaults to Grok. T5 may detect a Grok envelope when `--host` is omitted. Do not auto-detect Pi/OpenCode from adapter JSON as if a host sent it.

## Definition of done

- T4 L3 green: Grok fixtures + `rv hook --host grok` match T4.3. T1 corpus decision for `git reset --hard` is unchanged.
- T5 L3 green: Pi + OpenCode codecs + adapter templates; same `hostDenyText`; Pi display-only card; OpenCode display-only toast; no Allow UI.
- T6 L4 green: temp-HOME setup/uninstall idempotent; foreign files untouched; occupied skip; hostless one line; `install.sh` refuses non-macOS-26-arm64.
- T7 L1 green: doctor reports service (or “not installed”), day-one packs, and host wired/missing/occupied/broken/absent-file without writing HOME.
- Worktree rules held: T4 before T5; T4 after T1; T6/T7 parallel only with the ownership split.
- No product code in ryk. No live-HOME writes from tests.
- Day-one win is one human step away: hero install on a real HOME (when asked) → host blocks `git reset --hard` with the deny sentence above.
