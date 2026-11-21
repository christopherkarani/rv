---
name: swift-hook-xpc
description: >
  rv hook and XPC wire. Use when changing hostDenyText, rv hook, rvd,
  LaunchAgent, dev.rv.evaluate, encodeAllow, hostDenyText == nil, hello
  skew, RV_BYPASS, Grok/Pi/OpenCode codecs, { block: true }, throw, Unix
  socket, --json/--robot, or rv doctor / broken. Also /swift-hook-xpc.
metadata:
  short-description: rv hook + XPC wire
---

# swift-hook-xpc

Internal. Hook / XPC / host / doctor wire. Evaluate stays in
`swift-evaluate-parity`. Module placement stays in `swift-hexagonal-spm`.

Ownership today (see `docs/architecture/MODULES.md`): **RVHooks** owns Pi /
Grok / OpenCode Host adapters (codecs, Hook mapper/voice, embedded adapter
resources). **RVService** owns XPC / `rvd` / EvaluateSession edge.
**RVCLI** owns `rv hook`, thin XPC client, setup mutations, and doctor command
wiring. **RVPresentation** / **RVTUI** own TTY pretty — not the hook deny path.
(Ticket history: T2 `hostDenyText`, T3 XPC, T4–T5 hosts, T6 setup, T7 doctor.)

Law: `docs/factory/PLAN.md`, `docs/factory/references/host-contracts-v1.md`,
`docs/factory/specs/phase-1b-ux.md`, `phase-1c-service.md`,
`phase-1d-hosts.md`. Wire table: [references/wire-matrix.md](references/wire-matrix.md).

## Load first

1. `docs/factory/references/host-contracts-v1.md`
2. T2 `hostDenyText` contract in `phase-1b-ux.md`
3. Fallback law in `phase-1c-service.md`
4. Host rows in `phase-1d-hosts.md`

Copy wording from those files. Do not paraphrase a second deny sentence.

## Steps

1. Switch on `Decision` in `RVCLI` (`rv hook`). Never infer allow from
   `hostDenyText == nil` or `matched != nil`.
2. Presentation produces `hostDenyText`. CLI binds a `String` and passes it
   to the codec. Codecs copy it. They do not rewrite it. `RVHooks` does not
   evaluate and does not import CLI / TUI / Presentation / Service.
3. T3/T4 only: down or skew `rvd` → in-process `evaluate`. The miss is not
   an allow. T2 must not add XPC, launchd, or `rvd`.
4. T3/T4 only: prove with a fixture — `git reset --hard` still denies when
   the listener is absent or hello is skewed; `git stash drop` is empty allow.
5. Run `tools/gate.sh` for the touched target(s) (e.g. `RVHooksTests`,
   `RVCLITests`, `RVServiceTests`).

## Switch on Decision (RVCLI / `rv hook`)

```swift
switch result.decision {
case .allow:
    codec.encodeAllow()
case .deny(_):
    // Missing T2 text is still a host block, not allow.
    codec.encodeDeny(reason: hostDenyText
        ?? "rv could not finish evaluating this command. Run it in Terminal.")
case .indeterminate(_):
    codec.encodeDeny(reason: hostDenyText
        ?? "rv could not finish evaluating this command. Run it in Terminal.")
}
```

`encodeDeny` takes `String`, not `String?`. Never
`if hostDenyText == nil { encodeAllow() }`. A nil fallback on deny is a
T2 hole; it must still `encodeDeny`, never the allow path.

Encode whatever `evaluate` returned. Medium/low allow is a T1 fact, proven
in corpus, not re-decided here.

`hostDenyText` (T2, `phase-1b-ux.md`):

| `Decision` | Return |
|---|---|
| `.allow` (including medium/low match) | `nil` |
| `.deny` | one sentence + display `rule_id` + next step |
| `.indeterminate` | PLAN incomplete-eval sentence — no pack `rule_id` |

Nil means allow **only after** you switched on `Decision`. HANDOFF /
cohesiveness “nil unless deny” is stale (that overshoot is FN-01).

Canonical deny line — copy from `host-contracts-v1.md`, do not paraphrase:

```
Blocked git reset --hard (core.git/reset-hard). Run it in Terminal, or rv allow-once.
```

That one line is the hook string. The pretty three-line TTY frame is
`rv test` / `explain` only. No redeemable code. No banner on allow.

Display `rule_id` is slash (`core.git/reset-hard`). Robot JSON `rule_id` is
colon (`core.git:reset-hard`).

## Landmines (name them)

- **FP-02:** do not emit hook text on allow+match (`git stash drop`).
- **FN-01:** do not “fix” FP-02 with nil⇒allow. Indeterminate with nil text
  still host-blocks with the PLAN sentence.
- Current law is the T2 three-state function + switch on `Decision`.

## XPC (T3 / T4 / T6)

- Protocol `rv.ipc.v1`. Production: Mach / LaunchAgent `dev.rv.evaluate`.
  On-demand. Idle-exit ~5m. Not KeepAlive. Numbers live in `phase-1c-service.md`
  (connect ~200ms, request ~500ms, then in-process).
- Unix socket: **tests only**. Production `rvd` has no `--socket`.
- Skew hello → drop the connection, then in-process. Do not evaluate
  against the skewed listener.
- Do not set `HelloAck.ok = true` if `core.git` / `core.filesystem` are
  missing or empty. Client then falls back in-process; hooks deny per PLAN #6.
- T3 ships the plist **template** only. T6 writes
  `$HOME/Library/LaunchAgents/dev.rv.evaluate.plist`. T3 does not live-load.
- `indeterminate` passes through. Hooks encode it as deny.
- `class` / `NSObject` live only at `RVService`.

## Hosts (v1: Grok, Pi, OpenCode)

Shell tools only. Matcher `Bash` is required (an omitted matcher hooks
Read / Edit / MCP). No host Allow button. No leftover ask UI. No
`permission.ask`. Pi `registerMessageRenderer` is display-only
chrome for `rv-decision` and must return `{ render(width) => string[] }`,
never a string. `{ block: true, reason }` remains the deny path.
OpenCode `client.tui.showToast` is display-only chrome (title `RV · Blocked`,
body Why/Cmd/Meta/Next). `throw new Error(reason)` remains the deny path.
Toast failure must still throw.
`permissionMode` / `bypassPermissions` is not a skip.

Occupied = the **owned filename** is present and is not the current rv
template. Foreign siblings are not occupied. Occupied → skip + one line.

Missing `rv` binary vs down `rvd` are different holes. See wire-matrix.
`rvd` down still evaluates. The hook child always evaluates. There is no
`RV_BYPASS` and no other env a hook child honors to skip evaluate.

## TUI (not a host path)

`reduce` + `render` → `[String]`. No I/O in `RVTUI`. Browse only if both
stdin and stdout are TTYs and the process is not
`--json` / `--robot` / `--plain` / `CI` / `NO_COLOR`. Pretty deny exists
on a human TTY only (`rv test` / `explain`). Hooks get `hostDenyText`.
Do not use a TTY to prove allow vs deny.

No command text in `os_log`. History stays off by default.

## Preflight

**Run `tools/gate.sh` for the touched hook/XPC/CLI targets.** It runs
`tools/preflight.sh` then filtered tests on 6.3.3. Then re-read the remaining
list for semantic judgments.

- [ ] Encode path switches on `Decision` in CLI; codecs take `encodeDeny(reason:)`.
- [ ] `git stash drop` → empty allow (not a host block).
- [ ] Oversize / budget / missing core packs → host deny, incomplete-eval
      sentence, **even if `hostDenyText` is nil**. No pack `rule_id`.
- [ ] No listener and skewed hello both still deny `git reset --hard`.
- [ ] Empty-core handshake is not `ok`.
- [ ] Codecs copy `hostDenyText`; they do not invent a second sentence.
- [ ] No `RV_BYPASS` and no other hook-child env that skips evaluate.
- [ ] Adapters honor `decision=deny` JSON regardless of exit.
- [ ] Pi renderer returns `{ render(width) => string[] }`, never a string. Deny posts `rv-decision`; allow posts none.
- [ ] OpenCode deny toasts then throws `hostDenyText`. Toast failure still throws. Allow toasts none.
- [ ] Grok emit is JSON + exit 0 (do not emit exit 2). Extra keys stay off.
- [ ] No command text in logs. Unix socket not used in production code.
- [ ] TUI render is `[String]` and does not open a TTY. No TTY to prove Decision.
- [ ] Fixtures use a temp `HOME`. No `NSHomeDirectory()`.
- [ ] Doctor: missing / non-exec baked `rv` path is `broken`, not `wired`.
