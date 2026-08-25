---
title: Claude Code host — rich shell deny (settings merge)
version: 1.0
date_created: 2026-08-25
owner: chriskarani
tags: [hosts, claude, rvhooks, setup]
---

# Claude Code host

Additive host after v1 Pi / Grok / OpenCode. Locked product choices: **settings merge only**, **Bash shell only**, **DCG-rich Claude deny wire**, **no live allow-once code**, **ask / secrets / MCP fenced later**.

Parity source for *decisions* remains DCG **0.11.0** engine. Claude *wire* follows current Claude Code hooks docs (`hookSpecificOutput.permissionDecision`), not Grok’s `{decision,reason}`.

If this file conflicts with `docs/factory/PLAN.md`, PLAN wins except where this spec explicitly amends Claude-only chrome (rich fields + `systemMessage`). Shared unlock law (no redeemable code on the host wire) is not amended.

## 1. Purpose & Scope

**In scope (CL-T1–T5):**

- `HookHost.claude` + `ClaudeHostCodec` + stdin/stdout fixtures
- `rv hook --host claude` dispatch through existing `hookWire` / evaluate / Policy gate
- Setup merge + uninstall + doctor for `~/.claude/settings.json`
- Branded rich deny JSON for Claude only
- Docs: this file, `host-contracts-v1.md` Claude row, MODULES / STATUS pointers

**Out of scope (fenced later tickets):**

| Ticket | Fence |
|---|---|
| **CL-later-ask** | Emit `permissionDecision: "ask"`. Never treat Claude ask-approve as allow-once. |
| **CL-later-secrets** | Read / Edit / Write secret-path guards (cc-safety-net competitive). |
| **CL-later-mcp** | MCP tool-name / args policy. |
| — | Claude plugin marketplace install; PowerShell matcher; Codex / Gemini codecs; `MessageDisplay`; `RV_BYPASS` / `DCG_BYPASS`; live HOME tests |

Audience: implementer and reviewer subagents. Base: current `worktree/lucky-river-7284` (or merge base with T0–T9 + C-hook green).

## 2. Definitions

- **Claude Host adapter:** rv-owned integration that turns a Claude `PreToolUse` Bash event into a `HookRequest` and returns Claude-native deny/allow wire plus optional `systemMessage` chrome.
- **Settings merge:** additive edit of `$HOME/.claude/settings.json` hooks; not an exclusive owned filename like `rv.json`.
- **rv fingerprint:** a PreToolUse command hook whose `command` string contains `hook --host claude`.
- **Rich deny:** Claude-only stdout object with `systemMessage`, `hookSpecificOutput.permissionDecision: "deny"`, reason, `ruleId`, `packId`, `severity`, and `remediation` (no redeemable code).
- **Short hostDenyText:** existing one-sentence voice (`Blocked … (pack/pattern). Run it in Terminal, or rv allow-once.`). Still the Pi/Grok/OpenCode reason; also the one-line spine inside Claude’s rich reason and `systemMessage`.

## 3. Requirements

### Wire / codec

- **REQ-001**: `HookHost` gains `claude` (`rawValue` `"claude"`). Unknown host decode stays fail-closed at IPC where already strict.
- **REQ-002**: `ClaudeHostCodec` decodes snake_case Claude stdin. Shell iff `hook_event_name == "PreToolUse"` and `tool_name == "Bash"`. Command from `tool_input.command` (non-empty string). `cwd` from `cwd` when non-empty. Other events / tools → `.foreign` → allow. Unreadable / missing command → `.malformed` → allow (Claude fail-open).
- **REQ-003**: Allow → empty stdout, exit `0`.
- **REQ-004**: Engine deny → exit `0` and JSON:

```json
{
  "systemMessage": "RV · Blocked\n<hostDenyText>",
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "<rich reason>",
    "ruleId": "<pack:pattern>",
    "packId": "<pack>",
    "severity": "<low|medium|high|critical>",
    "remediation": {
      "explanation": "<pack explanation or omitted>",
      "safeAlternative": "<short safer tip or omitted>",
      "allowOnceCommand": "rv allow-once"
    }
  }
}
```

- **REQ-005**: Rich reason body (Claude `permissionDecisionReason`) is multi-line, DCG-shaped teaching copy built only from Domain facts already on `EvaluationResult` / `RuleMatch`:
  1. Line: `RV · Blocked`
  2. Line: short `hostDenyText` (canonical one sentence)
  3. Section: `Reason:` + pack/match `reason`
  4. Section: `Explanation:` + `RuleMatch.explanation` when present (omit section if nil/empty)
  5. Section: `Rule:` + colon `rule_id`
  6. Section: `Command:` + `hookDenyCommandPreview(command)`
  7. Closing: `If you need this, run it in Terminal, or use rv allow-once in a TTY.`
- **REQ-006**: Never emit `allowOnceCode`, `allowOnceFullHash`, or any redeemable code. `remediation.allowOnceCommand` is exactly the string `rv allow-once` (verb name only). Omit empty `explanation` / `safeAlternative` keys rather than sending `""`.
- **REQ-007**: `safeAlternative` may be derived from match `reason` when no better Domain field exists; do **not** import `RVPresentation` into `RVHooks` for suggestion catalogs.
- **REQ-008**: Indeterminate → same Claude deny envelope; `permissionDecisionReason` and `systemMessage` use the incomplete-eval sentence only; omit `ruleId` / `packId` / `severity` / `remediation`.
- **REQ-009**: Do not emit `"permissionDecision": "ask"` or `"allow"` in this ship. Do not use exit `2` as the primary gate (JSON deny + exit 0). Do not write stderr panels on the success path.
- **REQ-010**: No command text in `os_log`. No `RV_BYPASS` or any env the hook child honors to skip evaluate.
- **REQ-011**: Grok / Pi / OpenCode codecs and adapters unchanged (still short deny). Claude is the only rich encoder.

### Setup / doctor

- **REQ-012**: Detect Claude when `$HOME/.claude` exists. Do not mkdir `.claude` only to detect.
- **REQ-013**: Setup merges one PreToolUse entry into `$HOME/.claude/settings.json`:

```json
{
  "matcher": "Bash",
  "hooks": [
    {
      "type": "command",
      "command": "<absolute-rv> hook --host claude",
      "timeout": 5
    }
  ]
}
```

Absolute path = baked install `rv` (same resolution as other hosts). Never register bare `rv` on PATH. Matcher is **`Bash` only** (macOS product; no PowerShell).

- **REQ-014**: Merge rules: preserve foreign hooks (including `dcg`). If an rv-fingerprinted handler already matches the current template (modulo absolute path rewrite), treat as wired / path-fix only. If fingerprint present but shape is not current rv and `--force` is unset → **occupied** → skip. With `--force`, replace the rv-fingerprinted handler(s) only.
- **REQ-015**: Uninstall removes only rv-fingerprinted Claude handlers; leave the rest of `settings.json` (and the file itself if non-empty of foreign content).
- **REQ-016**: Doctor uses the same installation states as other hosts: missing / absent-file / occupied / broken / wired, interpreted for the shared settings file + fingerprint (broken = fingerprint present, baked `rv` missing or non-exec).

### Module graph

- **REQ-017**: `RVHooks` owns codec + fixtures + any Claude deny document builder (Domain-only inputs). `RVCLI` owns settings merge mutations and doctor formatting. `RVDomain` owns `HookHost.claude`. No new SPM modules. Engine / Packs / Policy / IPC evaluate verbs unchanged.
- **REQ-018**: Extend `hookWire(host:stdin:evaluate:)` and setup `SetupHostKind` / `OwnedPaths` / installation snapshot for Claude. Claude’s “owned path” for detection directory is `$HOME/.claude`; destination is `$HOME/.claude/settings.json` with merge semantics (not whole-file exclusive overwrite).

## 4. Constraints & Guidelines

- **CON-001**: Toolchain `tools/gate.sh` / Swift 6.3.3. Do not wipe `.build`.
- **CON-002**: macOS 26 Apple Silicon only.
- **CON-003**: Temp `HOME` in tests. No live-HOME mutation in CI.
- **CON-004**: Do not claim OS-enforced / Seatbelt. Grade remains hook.
- **GUD-001**: Prefer extending `HostCodec` with an optional rich payload or a Claude-specific encode path over forking a second hook runtime.
- **GUD-002**: Fixtures pin exact stdout JSON (stable key order via explicit encoder), including a `git reset --hard` rich deny and a silent allow (`git status` or empty foreign).
- **PAT-001**: Functional core / imperative shell — pure encode/decode in Hooks; FileManager only in CLI setup.

## 5. Acceptance criteria

- **AC-001**: Fixture: Claude Bash `git reset --hard` → exit 0, `permissionDecision` deny, `systemMessage` starts with `RV · Blocked`, `ruleId` `core.git:reset-hard`, no allow-once code fields, `allowOnceCommand` is `rv allow-once`.
- **AC-002**: Fixture: allow path (non-destructive or medium/low) → empty stdout, exit 0.
- **AC-003**: Fixture: indeterminate → Claude deny envelope, incomplete-eval sentence, no pack fields.
- **AC-004**: Fixture: `tool_name` Read/Edit/Write/MCP → empty allow (foreign).
- **AC-005**: Temp HOME setup: detected `.claude` → settings contain rv fingerprint + absolute `hook --host claude`; foreign PreToolUse entry unchanged; occupied fingerprint skipped without `--force`.
- **AC-006**: Uninstall removes only rv fingerprint; foreign hooks remain.
- **AC-007**: `tools/gate.sh` green for touched targets (`RVDomainTests`, `RVHooksTests`, `RVCLITests`, and any dispatch/service hook host enum tests).
- **AC-008**: Fresh-context review (subagent loads `swift-pr-review` + project `swift-hook-xpc`) returns no blocking issues before merge.

## 6. Ticket graph

| Ticket | Owns | Blocked by |
|---|---|---|
| **CL-T1** | This spec + `host-contracts-v1.md` Claude section (done when those files match this law) | — |
| **CL-T2** | `ClaudeHostCodec` + rich builder + `Tests/RVHooksTests` fixtures | CL-T1 |
| **CL-T3** | `HookDispatch` / CLI `--host claude` / domain enum / any IPC host mirror | CL-T2 |
| **CL-T4** | Setup merge, uninstall, doctor | CL-T3 |
| **CL-T5** | MODULES.md, STATUS.md, AGENTS pointers if needed; gate | CL-T4 |
| **CL-later-ask** | Ask UI | CL-T5 |
| **CL-later-secrets** | Secret file tools | CL-T5 |
| **CL-later-mcp** | MCP policy | CL-T5 |

Parallel: none until CL-T2 green. CL-T3/T4 may split worktrees only with exclusive file lists written into the PR.

## 7. Open questions (do not answer in code)

None for this ship. Ask / secrets / MCP remain fenced.

## 8. Definition of done

- Spec + host-contracts Claude row land.
- CL-T2–T5 meet ACs; gate green; fresh review clean.
- Later tickets named in STATUS as fenced, not started.
