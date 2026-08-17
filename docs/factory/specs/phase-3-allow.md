# Phase 3 — Allow path (T8)

Locked law: [`docs/factory/PLAN.md`](../PLAN.md). If this spec and PLAN disagree, PLAN wins. Parity source is DCG **0.11.0** decisions / `rule_id`s, not DCG’s `DCG_BYPASS`, 24-hour standing exceptions, or agent-visible `allowOnceCode`. Not ryk. Implement only in `~/CodingProjects/rv`.

T8 is the operator unlock after a hook deny. The product moment stays “user forgets rv until a block.” Unlock is **not** a host button and **not** an environment variable.

## Goal

Ship a deny-and-unlock loop that a human can finish without teaching the agent to permit itself.

1. **Unlock (locked):** run the same command in Terminal (human shell is not a v1 host hook), **or** `rv allow-once <code>` in a **TTY**. No host Allow button.
2. **Allow-once:** TTY mint prints a single-use code once; TTY redeem writes a one-shot grant; the next matching evaluate consumes the grant and allows **once**. A second identical agent command denies again.
3. **Allowlist:** permanent user-layer exceptions (`rule` or exact command) with a required reason, applied after engine deny, silent on hook allow.
4. **Store:** `AllowOnceStore` is an **actor**. Codes are **single-use**. Non-TTY must refuse to mint or consume **interactively**.
5. **No skip-evaluate env.** No `RV_BYPASS`. No environment variable the hook child honors to skip `evaluate`.

Gate: **L1** (RVPolicy + CLI command types) **+ TTY-gated tests** (injected TTY probe; do not open a real TTY to prove a **decision**).

## Non-goals

- Host codecs, hook JSON envelopes, Pi renderer, OpenCode toast (T4 / T5). T8 must not put a redeemable code in `hostDenyText`.
- `rvd` transport, launchd, Unix-socket production, `rv service status` (T3). T8 implements consume **semantics**; T3 owns the `allowOnce.consume` Codable / XPC wire.
- Full `install.sh` / `rv setup` / `rv uninstall` (T6). T8 only names allow-once / allowlist files and completion fragments those commands must copy or delete.
- `rv doctor` (T7). Doctor may later read store paths; T8 does not probe hosts or `rvd`.
- Remaining pack catalog or `rv packs` (T9). Do not enable extra packs.
- DCG `DCG_BYPASS`, 24-hour default exceptions, `--single-use` flag (rv is single-use only), rebase-recovery mode, project auto-trust allowlists, `/etc/rv/allowlist.toml`, regex / prefix allowlist selectors.
- Host Allow / leftover-ask-as-permit UI. Mac app allow-once UI (Phase 4+; app is another `allowOnce.consume` client, not a new permit channel).
- History persist, `os_log` of command text, scan, SARIF, heredoc/AST, MCP, Intel, Linux/Windows, macOS 14/15.
- Implementing inside ryk. Installing or rebinding ryk.

## Depends on

| Ticket | Why T8 needs it |
|---|---|
| **T0** | `RVPolicy` + `RVCLI` + matching test targets exist. Style contract in `AGENTS.md` / `docs/dev/SWIFT.md`. No new modules. |
| **T1** | `Decision`, `Severity`, `PackID`, `RuleID`, `ShellCommand`, `EvaluationRequest`, `EvaluationResult`, `evaluate`. Corpus green. Engine stays pure (no `Date()` / `FileManager` / `ProcessInfo`). |
| **T2 (CLI wire)** | ArgumentParser `@main` `rv`, `ThemeProbe` (`stdinIsTTY` / `stdoutIsTTY`), `hostDenyText` next action already names `rv allow-once` **without** a fabricated code. T8 adds subcommands; it does not invent `@main` or the ArgumentParser pin. |

Do not start T8 product code until T1 corpus is green. Spec authoring may precede that.

T8 does **not** wait for T3–T7 or T9. If T2 is not merged yet, implement RVPolicy + tests first on the T1-green SHA; rebase onto T2 before adding ArgumentParser CLI files. Do not add an ArgumentParser package dependency — that is T2’s merge.

T3 / T4 call sites: if `rvd` / `rv hook` already evaluate, T8 must route the engine result through `PolicyGate` (see allow-once). If those call sites do not exist yet, export `PolicyGate` and document that T3/T4 **must** call it; an unwired store is not an unlock.

## Parallel / worktree

- **After T1:** T8 and T9 may run in **separate git worktrees** from the **same T1-green SHA**.
- **Branch:** `feat/t8-allow-once`. Sibling T9: `feat/t9-catalog`. Agents must not share a working tree.
- **T8 owns:** `RVPolicy` allowlist + allow-once actor + `PolicyGate`; CLI `allow-once` / `allowlist`; TTY-gated CLI tests; completion **fragments** for those subcommands; the uninstall **path contract** for those files.
- **T8 must not:** invent `RV_BYPASS`; enable extra packs; add/remove/retarget `Package.swift` modules; own full uninstall; rewrite T2 `test` / `explain`; put `allowOnceCode` on the hook wire; fight T9 for `rv packs`.
- **`Package.swift`:** no graph edit. Only add sources under existing `RVPolicy` / `RVCLI` / their tests.
- **CLI namespace:** add `allow-once` and `allowlist` only. Do not add `service`, `hook`, `setup`, `doctor`, `packs`.
- If T2 and T8 both touch `RVCLI` root command registration, rebase; do not reformat T2’s `test` / `explain` files.

## allow-once (TTY only)

### Unlock law

Two operator paths, and only these:

| Path | Who | Hook? | Store? |
|---|---|---|---|
| Run the command in Terminal | Human | No (v1 hooks are Pi / Grok / OpenCode shell events only) | None |
| `rv allow-once <code>` on a TTY | Human | No — this is the CLI redeem | Redeem writes a grant; next matching evaluate consumes it |

There is **no** host Allow button. There is **no** “ask → permit” leftover. The agent-visible deny stays T2’s one sentence + `rule_id` + next step:

```
Blocked git reset --hard (core.git/reset-hard). Run it in Terminal, or rv allow-once.
```

Do not append a redeemable code to `hostDenyText`, hook JSON, or pretty `rv test` / `rv explain`. T2 already forbids a fabricated code; T8 must not start printing a real one on those surfaces.

### Three operations (do not collapse)

| Op | Interactive? | TTY? | Actor method | Effect |
|---|---|---|---|---|
| **Mint** | Yes | **Required** | `mint` | Create pending row (code **hash** + command fingerprint + cwd). Print plaintext code **once** on stdout. |
| **Redeem** | Yes | **Required** | `redeem` | `rv allow-once <code>` spends the pending code and writes a **single-use grant**. Code cannot be redeemed again. |
| **Consume** | No | Not required | `consume` | Hook / `rvd` / in-process evaluate: if a grant matches normalized command + cwd, flip deny → allow and spend the grant. This is IPC `allowOnce.consume`. |

Interactive mint/redeem without both stdin and stdout as TTYs **must refuse** (non-zero exit, no store mutation, no code printed). `CI` also refuses interactive mint/redeem. `--json` / `--robot` on mint or redeem refuses (those flags are not a TTY operator). Piped hook stdin is non-TTY → redeem fails if the agent tries `rv allow-once <code>`.

Consume is **not** interactive. The hook child may consume a grant that a human already redeemed. Consume must not mint or print a code.

### Actor store

`public actor AllowOnceStore` in `RVPolicy`. All mint / redeem / consume / list / clear serialize through the actor. No `class` except the existing XPC `RVService` edge. `Sendable` records. No `try!` / `!` on production paths.

- **Clock:** every mutating method takes `now: Date` from the caller. The actor does not call `Date()` so tests do not flake. CLI/service supplies `Date()`.
- **Paths:** injected `baseDirectory: URL` (tests). Production default: `$HOME/.config/rv` (process `HOME` only). Do not read `XDG_CONFIG_HOME`. Do not use `NSHomeDirectory()`. Create the directory `0700` and files `0600` when writing.
- **File:** `allow-once.jsonl` under that directory (one file, `kind` = `pending` \| `granted` \| `consumed`). T6 deletes this file; do not invent a second live path.
- **No plaintext code on disk.** Store `code_hash` (SHA-256 of the raw code bytes). DCG 0.11.0 writes `short_code` in `pending_exceptions.jsonl` — rv must not.
- **No raw command on disk.** Store `command_fingerprint` = SHA-256 of T1-normalized command text, plus a **redacted** display string for TTY list. Full argv is a TTY `explain` / `test` / mint privilege only.
- **Code:** 6 lowercase hex characters from `SecRandomCopyBytes` (or equivalent CSPRNG). Not derived from the command (DCG’s hash-derived digits are guessable if time + cwd + command leak). Collision on mint → regenerate (bounded retries), then fail typed.
- **Single-use (locked, DCG divergence):** no 24-hour standing grant. No `--single-use` flag. Pending unused codes expire after 24 hours (`expires_at`). A redeemed grant expires after 24 hours if never consumed. Expired rows are ignored and may be pruned on the next write.
- **Scope:** exact normalized command **and** exact cwd. No project-wide allow-once in v1.
- **Corrupt lines:** skip (fail-open for hook evaluate; do not crash the hook). `list` / `validate` may report skipped lines.
- **Atomic consume:** on-disk compare-and-swap (write temp + replace, or equivalent) so two **processes** (two in-process hook children while `rvd` is down) cannot both consume one grant. Actor isolation is not enough across processes. Two concurrent evaluates — including a two-process test — spend exactly one grant.

Record shape (normative fields; JSONL one object per line):

```
schema_version = 1
kind           = pending | granted | consumed
code_hash      = hex SHA-256
command_fingerprint
command_redacted
cwd
rule_id?       = T1 RuleID if known at mint
created_at, expires_at, consumed_at?
```

Reject `schema_version != 1` rows.

### CLI

| Command | TTY | Behavior |
|---|---|---|
| `rv allow-once mint -- <command>` | Required | Normalize via T1 (do not require a deny). Write pending. Print one pretty line: `allow-once code: a1b2c3` and `rv allow-once a1b2c3`. Robot refused. |
| `rv allow-once <code>` | Required | Redeem. One line: granted (redacted command + cwd). Exit `0`. Unknown / expired / already-spent / wrong TTY → exit `2`, no grant. |
| `rv allow-once` (no args) | Required | Usage only. Name mint + redeem. Do not mint. |
| `rv allow-once list` | TTY for pretty; `--json` allowed on TTY | Redacted rows. **Never** print plaintext codes (they are not stored). `--json` is hashes + redacted + kind. |
| `rv allow-once clear` | Required | Delete pending + granted rows. Consumed/expired may be dropped in the same rewrite. |

Exit `2` = operator / TTY / usage failure (not an engine deny). Do not use T2’s `rv test` exit `1` for TTY refuse.

TTY probe is CLI-only (reuse T2 `ThemeProbe` fields). `RVPolicy` takes a `TTYCapability` value the CLI builds — Policy does not call `isatty`.

```swift
public struct TTYCapability: Equatable, Sendable {
    public var stdinIsTTY: Bool
    public var stdoutIsTTY: Bool
    public var ci: Bool
}

public func allowsInteractiveAllowOnce(_ tty: TTYCapability) -> Bool {
    tty.stdinIsTTY && tty.stdoutIsTTY && !tty.ci
}
```

Tests inject `TTYCapability`; they do not open a TTY. A test that needs a TTY to prove a **decision** is in the wrong module — grant-match tests preload the actor.

### PolicyGate (engine stays pure)

Evaluation order stays DCG: normalize → quick-reject → safe → destructive → default allow. Allowlist / allow-once are **not** PatternEngine rules.

```
engine.evaluate(request) -> EvaluationResult
PolicyGate.apply(result, request, cwd, allowlist, store, now) -> PolicyDecision
```

`PolicyGate` lives in `RVPolicy`. It must not import CLI, TUI, XPC, or Hooks.

```swift
public enum PolicyOverride: Equatable, Sendable {
    case none
    case allowlist
    case allowOnce
}

public struct PolicyDecision: Equatable, Sendable {
    public var result: EvaluationResult
    public var override: PolicyOverride
}
```

Rules:

1. If engine `Decision` is allow, return it with `.none`. Do **not** consume a grant. If engine `Decision` is indeterminate, return deny-for-incomplete-eval (PLAN miss policy). Do **not** treat indeterminate as allow.
2. If engine denies and the user allowlist matches (rule id **or** exact normalized command), return allow + `.allowlist`. Do not consume a grant.
3. Else if engine denies and `store.consume` matches fingerprint + cwd, return allow + `.allowOnce`.
4. Else return the engine deny + `.none`.

Do not add `isDenied`. Do not change T1’s closed `Decision` into a boolean. If T1’s `EvaluationResult` has no override field, keep `PolicyOverride` on `PolicyDecision` only.

Hook / `rvd` / in-process fallback **must** use `PolicyDecision.result` as the verdict they encode. Quiet allow: empty host stdout on allow, including allowlist / allow-once allow.

IPC semantic payload (T3 encodes this; T8 implements the function):

```
allowOnce.consume
request:  { command: String, cwd: String }
response: { consumed: Bool }
```

`now` is the service’s clock, not a client-supplied permit. Unix socket remains **tests only**. Production transport stays XPC. T8 must not add a second IPC.

### What the hook child must ignore

The evaluate path (hook child, `rvd`, in-process fallback) must **not** honor any of these as skip-evaluate or skip-policy:

`RV_BYPASS`, `DCG_BYPASS`, `RV_ALLOW`, `RV_SKIP`, `RV_DISABLE`, `RV_NO_EVAL`, `RV_ALLOW_ONCE`, `RV_ALLOW_ONCE_SECRET`, `DCG_ALLOW_ONCE_SECRET`, `DCG_PENDING_EXCEPTIONS_PATH`, `DCG_ALLOW_ONCE_PATH`, `RV_PENDING_PATH`.

Test path injection is the `AllowOnceStore` initializer (`baseDirectory`), not process env. `HOME` resolves the default directory only (`$HOME/.config/rv`). Do not read `XDG_CONFIG_HOME`. They must not skip `evaluate`.

## allowlist

Permanent exceptions. DCG 0.11.0 shape, narrowed for v1.

### Layers (v1)

| Layer | Path | v1 |
|---|---|---|
| User | `$HOME/.config/rv/allowlist.toml` | **Required.** Always loaded when present. |
| Project | `.rv/allowlist.toml` or `.dcg/allowlist.toml` | **Inert.** A checked-in repo file must not grant itself permission. Do not honor a `RV_CONFIG` / `DCG_CONFIG` trust switch in v1. |
| System | `/etc/rv/allowlist.toml` | **Not v1.** |

After join, `realpath` the user file (and its parent). If the file is a symlink into the workspace being evaluated, treat as missing (no user store). Unreadable / invalid TOML: fail-open for hook evaluate (ignore file, do not crash). `rv allowlist validate` reports the error.

Directory `0700`, file `0600` on write.

### Entry

```toml
[[allow]]
rule = "core.git:reset-hard"
reason = "Used for CI pipeline cleanup"
added_at = "2026-01-08T12:00:00Z"

[[allow]]
exact_command = "rm -rf ./build"
reason = "Safe build directory cleanup"
added_at = "2026-01-08T12:00:00Z"
```

- `reason` is **required** and must be non-empty after trim.
- Selectors in v1: `rule` (T1 `RuleID`) **or** `exact_command` (compared to T1-normalized command). Not both on one row. No `pattern` / `command_prefix` / `risk_acknowledged` in v1.
- `rule` accepts DCG `pack:pattern` (`core.git:reset-hard`). If T1’s display form is `core.git/reset-hard`, the CLI accepts both and stores T1’s canonical `RuleID`. Do not invent a third id dialect.
- Optional `expires_at` (ISO-8601). Expired rows do not match; `validate` warns; `list` marks them. No `prune` command in T8 (operator `remove` is enough).
- `added_at` written by CLI on add.

Load into a value-type `AllowlistSnapshot` (not an actor). Matching is pure given the snapshot + normalized command + `RuleID` from the engine deny. The file I/O wrapper may be an actor (`AllowlistStore`) if it shares the config directory with allow-once; or a struct with an injected `baseDirectory`. Either way: no `Date()` inside the matcher — pass `now` for expiry.

### CLI

| Command | TTY | Behavior |
|---|---|---|
| `rv allowlist add <rule> -r "<reason>"` | Required | Append user-layer rule. |
| `rv allowlist add-command "<command>" -r "<reason>"` | Required | Append exact normalized command. |
| `rv allowlist remove <rule\|command>` | Required | Remove matching user-layer row(s). |
| `rv allowlist list` | Optional | Effective user rows. `--json` robot. |
| `rv allowlist validate` | Optional | Exit `0` if file missing or valid; `2` if invalid TOML / rows. |

`--user` is accepted as an alias for the only writable layer (so DCG muscle memory works). `--project` / `--system` refuse with one line: not in v1.

Mutations (add / add-command / remove) use the same `allowsInteractiveAllowOnce` gate as allow-once. List / validate may run non-TTY (CI / robot).

Allowlist allow is **silent** on the hook path (same as engine allow). `rv test` pretty may show T2’s allow frame (`allow`) — do not add an “allowed by allowlist” banner on hook stdout.

## Completions / uninstall touchpoints

T6 owns `install.sh`, `rv setup`, and `rv uninstall`. T8 does **not** implement uninstall. T8 only makes the allow-path files discoverable and completable.

### Paths T6 must delete (rv-owned)

Publish from `RVPolicy` so T6 does not hardcode strings in a second dialect:

```swift
public enum RVPolicyPaths: Sendable {
    public static func allowlistFile(inConfigDir configDir: URL) -> URL
    public static func allowOnceFile(inConfigDir configDir: URL) -> URL
}
```

| Path | Writer | Uninstall |
|---|---|---|
| `<configDir>/allowlist.toml` | T8 CLI | T6 deletes if present |
| `<configDir>/allow-once.jsonl` | T8 actor | T6 deletes if present |

`configDir` is `$HOME/.config/rv` (process `HOME` only). T6 may delete the whole `~/.config/rv` directory if empty or if T6’s manifest says so — that is T6’s decision. T8 must not delete `config.toml`, launchd plists, or hook fragments.

If T6’s uninstall already has a file list, T8 may add **only** these two paths (or a call to `RVPolicyPaths`). If T6 has not landed, T8 ships the enum; T6 reads this spec.

Tests must not write the operator’s real `~/.config/rv`.

### Completions

Add fragments so `rv allow-once` and `rv allowlist` tab-complete. Full completion ownership for `test` / `explain` / `setup` stays with the ticket that created those commands (T2 / T6).

Create (if missing) or extend:

```
share/completions/rv.zsh
share/completions/rv.bash
share/completions/rv.fish
```

Complete subcommands: `allow-once` → `mint`, `list`, `clear`, and a code placeholder; `allowlist` → `add`, `add-command`, `list`, `remove`, `validate`. Do not complete redeemable codes from disk (they are hashed).

T6’s installer, when it exists, copies these into the same place it already copies completions. T8 must not write the operator’s live fpath. T8 must not invent a second installer.

## Files to create

Do not delete or edit `docs/factory/PLAN.md`. Do not write files outside this repo. Do not add a `LICENSE`.

| Path | Role |
|---|---|
| `Sources/RVPolicy/AllowOnceRecord.swift` | Value types: record, fingerprint, `TTYCapability`, `allowsInteractiveAllowOnce`. |
| `Sources/RVPolicy/AllowOnceStore.swift` | `actor` mint / redeem / consume / list / clear. |
| `Sources/RVPolicy/Allowlist.swift` | TOML snapshot, selectors, pure match. |
| `Sources/RVPolicy/AllowlistStore.swift` | Load / write user `allowlist.toml` (injected base dir). |
| `Sources/RVPolicy/PolicyGate.swift` | `PolicyDecision` / `PolicyOverride` / `apply`. |
| `Sources/RVPolicy/RVPolicyPaths.swift` | Uninstall path contract. |
| `Sources/RVCLI/AllowOnceCommand.swift` | ArgumentParser `allow-once` group. |
| `Sources/RVCLI/AllowlistCommand.swift` | ArgumentParser `allowlist` group. |
| `Tests/RVPolicyTests/AllowOnceStoreTests.swift` | Single-use, hash-at-rest, expiry, atomic consume, injected clock/dir. |
| `Tests/RVPolicyTests/AllowlistTests.swift` | Reason required, rule + exact match, expiry, inert project file, poisoned symlink. |
| `Tests/RVPolicyTests/PolicyGateTests.swift` | Deny→allow overlay; no consume on engine allow; allowlist before allow-once. |
| `Tests/RVPolicyTests/NoBypassEnvTests.swift` | Evaluate/policy still runs when skip-shaped envs are set in the test process. |
| `Tests/RVCLITests/AllowOnceTTYTests.swift` | Injected `TTYCapability`: refuse mint/redeem when not both TTYs or `CI`. |
| `Tests/RVCLITests/AllowlistCommandTests.swift` | Mutation refuse without TTY; list/validate allowed. |
| `share/completions/rv.zsh` | Fragments for allow-once / allowlist (create or extend). |
| `share/completions/rv.bash` | Same. |
| `share/completions/rv.fish` | Same. |

Keep `Sources/RVPolicy/RVPolicy.swift` as the module umbrella if T0 left an empty enum; do not replace the module with a `class`.

Do **not** add: `RV_BYPASS` docs, a host Allow renderer, Unix-socket production client, pack JSON, `install.sh`, or files under a ryk tree.

## Acceptance

T8 passes when all of the following are true:

1. `AllowOnceStore` is an `actor`. Mint/redeem/consume/list/clear are isolated. Tests use a temp directory, not the operator `HOME`.
2. Codes are single-use: redeem spends pending; consume spends grant; second redeem and second consume fail closed.
3. Plaintext codes never hit disk. `allow-once.jsonl` fixtures in tests contain `code_hash`, never `short_code` / raw code.
4. Interactive mint and redeem refuse when `stdinIsTTY && stdoutIsTTY` is false, or `CI` is true. Hook-shaped stdin (JSON pipe) cannot redeem.
5. `rv allow-once <code>` on an injected TTY redeem → next `PolicyGate.apply` on the same normalized command + cwd allows once, then denies.
6. Running the command in Terminal remains a documented unlock and needs no grant (no v1 human-shell hook).
7. `hostDenyText` / hook JSON still have **no** redeemable code. Next action still names `rv allow-once` (T2 lock).
8. Grep of `Sources/` and `Tests/` (except this spec and PLAN citations) finds **no** `RV_BYPASS` honor path and no `ProcessInfo` / env read that skips `evaluate` or `PolicyGate`.
9. User allowlist add requires `-r` / `--reason`. Project / system layers do not grant. Invalid TOML does not crash evaluate.
10. `RVPolicyPaths` names `allowlist.toml` and `allow-once.jsonl`. Completions mention `allow-once` and `allowlist`. No second uninstall command.
11. T1 SKILL.md / core-pack corpus still green. T8 did not change engine verdicts; it only overlays policy.
12. `Package.swift` module graph unchanged. No extra packs enabled. No ryk edits. No live-HOME writes.
13. `swift test` green for `RVPolicyTests` and the new `RVCLITests` (L1 + TTY-gated). If T2’s `rv` executable is present, `rv allow-once --help` and `rv allowlist --help` work.

## Test plan

Slice: L0 compile, L1 these modules, TTY-gated CLI with **injected** probes. No L3 hook fixture ownership. No L4 live-dotfile uninstall.

| Layer | What |
|---|---|
| L0 | `swift build` with T8 sources in existing targets. |
| L1 store | Mint → hash on disk; redeem once; redeem twice fails; consume once; consume twice fails; expired pending/grant ignored; corrupt JSONL line skipped; concurrent consume (two tasks **and** two processes) spends exactly one grant. |
| L1 allowlist | Rule match; exact-command match after normalize; missing reason rejected; expired row ignored; project file in a temp repo ignored; symlink-into-workspace ignored. |
| L1 gate | Engine allow + leftover grant → allow, grant **not** consumed. Engine deny + allowlist → allow, grant not consumed. Engine deny + grant → allow + consumed. Engine deny + nothing → deny. |
| L1 no-bypass | With `RV_BYPASS=1`, `DCG_BYPASS=1`, and `RV_DISABLE=1` set in the test process, `PolicyGate` still denies `git reset --hard` when no grant/allowlist exists. |
| TTY-gated | `TTYCapability(false, false, false)` → mint/redeem/clear/allowlist add refuse, store unchanged. `(true, true, true)` CI → refuse. `(true, true, false)` → mint+redeem succeed against temp dir. |
| Negative | No test opens a real TTY to prove a **decision**. No test writes `~/.config/rv` on the operator machine. No test plants `allowOnceCode` on a hook codec. |
| Completions | Fragments exist and contain `allow-once` / `allowlist` / `mint` / `add`. No live fpath install. |

Do not require `dcg` or `ryk` on PATH. `dcg test` agree-rate is not a v1 gate.

Suggested table rows (command fingerprints from T1 normalize, not guessed ryk ids):

| Setup | Command | cwd | Expect |
|---|---|---|---|
| none | `git reset --hard` | `/tmp/a` | deny `core.git` reset-hard |
| redeemed grant for that pair | `git reset --hard` | `/tmp/a` | allow once, then deny |
| grant for `/tmp/a` | `git reset --hard` | `/tmp/b` | deny (cwd scope) |
| grant for reset-hard | `git status` | `/tmp/a` | allow (engine), grant unused |
| allowlist `core.git:reset-hard` | `git reset --hard` | any | allow (silent overlay) |

## Forbidden

All of PLAN **Forbidden (product law)**, plus T8-specific:

- `RV_BYPASS` or any env the hook child honors to skip evaluate or `PolicyGate`.
- Host Allow button, leftover-ask-as-permit, printing a redeemable code on host deny text or hook JSON.
- Interactive mint or redeem from a non-TTY (hook child, pipe, `CI`).
- 24-hour standing allow-once (DCG default). `--single-use` as an opt-in — single-use is the only mode.
- Storing plaintext codes or raw command argv in `allow-once.jsonl`.
- Trusting a checked-in project allowlist. Honoring `DCG_CONFIG` / `RV_CONFIG` to activate one in v1.
- Allowing because `rvd` is down (must in-process evaluate, then still apply policy).
- Putting allowlist / allow-once I/O inside `RVEngine` / `RVDomain`.
- A test that opens a TTY to prove a **decision**.
- Writing foreign hook files or the human’s real `HOME`.
- Persisting raw command text to `os_log` or default history.
- Claiming OS-enforced / Seatbelt. Grade is **hook**.
- Claiming Linux / Windows / macOS 14/15.
- Implementing inside ryk. Installing or rebinding ryk.
- Enabling extra packs. Editing T9 catalog JSON except by accident of a shared worktree — don’t.
- Owning full uninstall, `install.sh`, or live completion install.
- Inventing a second IPC or a production Unix socket.
- Telemetry, SaaS, network install of packs.
- Editing `docs/factory/PLAN.md`.

## Open questions

Resolved for T8 (do not re-litigate):

- Unlock is Terminal or TTY `rv allow-once <code>`. No host Allow. No `RV_BYPASS`.
- Codes are single-use. Store is an actor. Non-TTY refuses interactive mint/redeem.
- Host deny text names `rv allow-once` and does **not** carry a code (T2).
- User allowlist only. Project/system layers do not grant in v1.
- Completions + path contract only; T6 owns uninstall.
- T8 may start after T1 in parallel with T9; CLI files rebase onto T2.

Still open (do not block T8; do not invent a host protocol):

1. **T1 `RuleID` display** — slash (`core.git/reset-hard`) vs colon (`core.git:reset-hard`). CLI accepts both; storage follows T1 canonical. Re-diff when T1 lands.
2. **Optional `expires_at` on allowlist rows** — implement if cheap; not an acceptance blocker if add/list/remove/reason work.
3. **T3 Codable names** for `allowOnce.consume` — semantic payload is locked above; field names follow T3 when that spec lands. T8 does not ship a second wire.
4. **Whether T6 copies `share/completions/`** — T8 writes fragments; if T6 chooses a different completions root, move files in the T6 merge, do not invent a second installer here.
5. **Defense-in-depth pack** that denies `rv allow-once` / `rv allowlist add` on the **agent** hook path — not v1. TTY refuse is the control. T9 must not enable extra packs to fake this.

## Definition of done

T8 is done when a fresh agent can say: **a block stays a block until a human in Terminal runs the command, or redeems a single-use code on a TTY — and the agent cannot skip evaluate to get there.**

- `feat/t8-allow-once` contains Policy store + gate + CLI subcommands + TTY-gated tests only.
- Actor store, hashed codes, single-use redeem + consume, cwd-scoped grants.
- Non-TTY mint/redeem refuse. No `RV_BYPASS`. No code on host deny text.
- User allowlist with required reason; project allowlist inert.
- Completions fragments and `RVPolicyPaths` exist; T6 still owns uninstall.
- T1 corpus still green. No extra packs. No ryk. No live-HOME writes.
- Gate: **L1 + TTY-gated tests**. Next: T9 may already be in flight; T4–T7 must call `PolicyGate` once those tickets exist.
