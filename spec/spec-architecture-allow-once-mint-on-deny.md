---
title: Mint allow-once on hook deny; TTY redeem is the daily unlock
version: 1.0
date_created: 2026-09-01
last_updated: 2026-09-02
owner: rv
tags: [architecture, policy, hooks, allow-once, ux]
---

# Introduction

Hook deny today does not mint a grant. The human must run `rv allow-once mint -- <command>` then `rv allow-once <code>` then wait for the agent to retry. That loop is the product failure. The Mac companion extra is not built, is Mac-only, and must never be required to unlock.

This specification makes hook deny mint a pending code, prints `rv allow-once <code>` on the deny the human already sees, and keeps TTY redeem as the only way that pending row becomes a spendable grant. Pi / OpenCode host Ask is unchanged: pause and spend this turn, no code. Consume, pins, allowlist, and rebase recovery stay as they are.

This spec **supersedes** factory PLAN unlock copy that forbids a redeemable code on `hostDenyText` / hook JSON, and **supersedes** `spec-architecture-product-takes.md` REQ-027 / REQ-030 where they forbid `allow-once` on first-call pack deny. Ledger schema, TTY redeem, and one-shot consume are unchanged (`spec-architecture-allow-once-ledger.md`).

Audience: fresh-context implementer/reviewer subagents. Toolchain: swift-tools 6.3 / 6.3.3, language mode 6. Gate: `tools/gate.sh`. Never wipe `.build`.

# 1. Purpose & Scope

**Purpose:** When an unlockable pack deny is about to go to the host, mint a pending allow-once row and put `rv allow-once <code>` on that deny so a human can redeem in a TTY and the next matching hook spends once.

**In scope:**

- `AllowOnceStore` mint from the hook apply path without a TTY.
- First-call hook **deny** copy: reason + `next` include the six-hex code when mint succeeded.
- Docs/help/README that currently show `rv allow-once 'git reset --hard'` or “never a code on deny.”
- Tests that currently forbid `allow-once` on pack deny JSON.

**Out of scope:**

- Mac companion extra / Island / dashboard Allow (never required; later client of the same ledger).
- Pending wait / this-call pause in rvd (OPE-246).
- Claude / Hermes / Grok official Ask (still deny-or-TTY).
- `RV_BYPASS` or any env a hook child honors.
- Changing grant key off `{matchingView, cwd}` (OPE-158).
- Changing jsonl schema, TTL (24h), lock file, or `AllowOnceLedger` consume/redeem rules.
- Making Ask a `Decision` case.
- Scan classify (must still not mint or spend).
- `rv test` / `rv explain` peek (must still not mint or spend).

**Assumptions:**

- Packs still deny `git reset --hard` as `core.git:reset-hard`.
- Redeem stays TTY-gated. A hooked child is not a TTY, so an agent that copies `rv allow-once <code>` into a hooked shell still fails redeem.
- Pi / OpenCode first-call Ask does not mint. Confirm-yes still `hostAsk: spend`.
- Product-tree files must obey factory PLAN #22 name hygiene. This spec is under `spec/` and obeys that.

# 2. Definitions

| Term | Meaning |
|---|---|
| Unlockable deny | Pack deny the Policy gate could spend: cwd present, nonempty matching view, not `RulePinning.blocksAllowOverride`, not indeterminate. |
| Pending row | `AllowOnceRecord.kind == .pending`. Hook consume does not spend this. |
| Granted row | After TTY `rv allow-once <code>`. Next matching apply may consume. |
| Mint-on-deny | Hook apply stayed deny and the store wrote a pending row, returning the plaintext 6-hex code. |
| Unlock line | With a code: `Paste in Terminal to allow once: rv allow-once <code>.` It sits after `RV · Blocked.` and before why so truncated host cards still show the paste. When mint failed or was skipped: `Run it in Terminal, or rv allow-once.` |
| Daily unlock | Human TTY redeem of the code printed on the deny. Not the Mac extra. Not `mint` first. |
| Spend-first | Pi, OpenCode. Pause on `decision: ask`; no code on that Ask. |

# 3. Requirements, Constraints & Guidelines

## Product law

- **REQ-001**: The Mac companion is never required to unlock. Linux, SSH, and a closed extra must still unlock via TTY redeem of a code minted on deny.
- **REQ-002**: No `RV_BYPASS`. No env a hook child honors to skip evaluate or mint.
- **REQ-003**: Grant remains one-shot `{matchingView, cwd}`. Replay after consume is deny. Mutated command or cwd does not match.
- **REQ-004**: Code redeem stays TTY CLI only (`allowsInteractiveAllowOnce`). `--json` / `--robot` / `CI` / missing stdin or stdout TTY still refuse redeem. Hook apply never redeems a code.
- **REQ-005**: `rv allow-once mint -- <command>` remains as a pre-arm path. It is not the daily path. Daily path is: deny already has a code → `rv allow-once <code>`.
- **REQ-006**: Host Ask on spend-first hosts is unchanged and preferred when the host paused. Ask JSON must not carry a redeemable code (`hostAskLine` keeps `hookUnlockNext` without a code).

## Mint-on-deny

- **REQ-101**: After `GatedEvaluate` / `PolicyGate.apply` stays **deny**, and the deny is unlockable, the same process that will later consume (rvd on XPC hookEvaluate, operator on in-process miss) calls a **non-TTY** mint and gets a 6-hex plaintext code.
- **REQ-102**: That mint writes `kind: .pending` through existing `AllowOnceLedger.mint` (hash only on disk, 24h TTL, flock + atomic rename). It must not write `.granted`.
- **REQ-103**: Skip mint when any of: decision is allow or indeterminate; `RulePinning.blocksAllowOverride`; cwd nil; matching view empty; override is allowlist or rebaseRecovery (apply already allowed). Peek / explain / classify / scan never mint.
- **REQ-104**: Mint failure (lock timeout, encode, collision after retries, missing HOME/store) → still deny, **without** a code. Never allow because mint failed. Never block the hook window on an unbounded lock wait; bound the wait and skip the code (same fail-closed deny).
- **REQ-105**: New store API is package-visible, not a human CLI. Suggested name: `AllowOnceStore.mintFromDeny(matchingView:cwd:ruleID:now:) async -> String?`. It must not check TTY or `robot`. Empty matching view → `nil`. Do not reuse `insertGranted` (that writes `.granted` and would let the next hook through without redeem).
- **REQ-106**: Do not put the plaintext code on `EvaluationResult`. Thread it as an optional `String` from the hook apply shell into `hookWire` / `encodeDeny` only.
- **REQ-107**: XPC `hookEvaluate` mints on the server. The client must not mint a second row for the same deny. In-process miss mints once on the operator store (same `$HOME/.config/rv/allow-once.jsonl` when HOME is set).
- **REQ-108**: `PolicyGate.apply` consume-of-granted is unchanged and runs **before** mint-on-deny. A live granted row still allows and spends; no new pending row.

## Deny copy

- **REQ-201**: When a code was minted, first-call pack deny `next` is `Paste in Terminal to allow once: rv allow-once <code>.` Code is the 6 lowercase hex characters from mint. No other punctuation inside the code.
- **REQ-202**: The same unlock line is inserted in the host-visible deny **reason** immediately after `RV · Blocked.` and **before** why, so hosts that truncate `reason` still show the paste. Why (pack sentence 1 ± tip) stays the product-takes rules (stash tip, no boxes, no ANSI, no command echo of `git reset --hard`).
- **REQ-203**: `shouldOmitDenySentence2` still omits pack sentence 2 if that sentence contains `allow-once` / `ALLOW-` / `redeem` / `RV_BYPASS`. The **unlock line is not sentence 2**. It is a separate clause after the brand and is required when a code exists.
- **REQ-204**: One line. No U+001B, no `═`, no `┌`, no newline in the full reason. If brand + unlock + why would contain those, keep why and put the unlock line only in `next`.
- **REQ-205**: When mint was skipped or failed, `next` on first-call pack deny may stay nil (today) **or** use `hookUnlockNext` without a code. Do not invent a fake code. Canonical reset-hard why without a code remains `RV · Blocked. Destroys uncommitted changes. Use 'git stash' first.`
- **REQ-206**: Ask JSON (`encodeAsk`) must not include a 6-hex code. `hostAskLine` is unchanged.
- **REQ-207**: Post-spend deny (`afterSpend: true`) must not mint and must not print a new code.
- **REQ-208**: Codex stderr honor reason and Cursor `user_message` / `agent_message` receive the same reason string as other hosts (brand + unlock + why when a code exists). Do not add extra JSON keys Codex/Cursor will drop or fail-open on.
- **REQ-209**: `assertHookDenyHasNoBypassOrEssay` (and copies) must **stop** forbidding `allow-once` and `Terminal` on deny **when a code was minted**. They must still forbid `RV_BYPASS`, boxes, ANSI, newlines, and echoing the command `git reset --hard`. Add a dedicated assertion that a minted deny contains `rv allow-once ` followed by exactly six hex digits.

## CLI and docs

- **REQ-301**: `rv allow-once <code>` remains redeem. Usage text already lists mint / code / list / clear. Keep it.
- **REQ-302**: README Commands must not show `rv allow-once 'git reset --hard'` as if that minted a grant. Show:

  ```
  rv allow-once a1b2c3   # redeem the code from a hook deny
  ```

  Table row “Allow once” must say the next matching call in this working directory after redeeming the code from a block.
- **REQ-303**: `HelpCatalog` root Everyday (or Advanced) must name `allow-once`. Help for the command: redeem the six-character code from a hook deny; `mint` is optional pre-arm.
- **REQ-304**: `CONTEXT.md` **Allow-once grant**: hook deny of an unlockable pack deny mints pending; TTY redeem grants; Policy gate spends. The hook wire **may** carry the code on deny `reason` / `next`. It must not carry a granted row. Evaluate session still does not honor grants.
- **REQ-305**: Do not edit `docs/factory/PLAN.md` in this program (factory arbiter). This spec is the unlock-copy law for product files. Implementors update `docs/factory/references/host-contracts-v1.md` only if that file is touched by the same docs ticket; otherwise leave factory docs to a follow-up.

## Constraints

- **CON-001**: Hexagonal graph unchanged. No new SPM module. `evaluate()` stays pure (no mint). Mint is Policy/Service/CLI shell.
- **CON-002**: Value types in Domain/Engine/Packs/Policy. Actor stays `AllowOnceStore`. No `try!` / `!` on production paths.
- **CON-003**: No live-HOME tests. Temp HOME / isolated allow-once dirs only.
- **CON-004**: Product-tree files this spec adds or edits obey factory PLAN #22 name hygiene.
- **CON-005**: A test that needs a real TTY to prove a **decision** is in the wrong module. Inject `TTYCapability` for redeem tests. Mint-from-deny tests must pass with `stdinIsTTY: false`.
- **CON-006**: Scan classify, `rv test`, `rv explain` stay peek: no mint, no spend.

- **GUD-001**: Prefer threading `unlockCode: String?` into `hookWire(from:…)` over hanging state on `EvaluationResult`.
- **PAT-001**: Same pattern as `spendHostAsk`: hookBody gets an optional callback from ServiceClient / ServiceRuntime, not a store import in RVHooks if that would invert the graph. RVHooks may take the already-minted code as a `String?`. RVService / RVCLI own the store call.

# 4. Interfaces & Data Contracts

## Store (RVPolicy)

```swift
extension AllowOnceStore {
    /// Hook deny mint. Not TTY-gated. Returns plaintext 6-hex or nil.
    package func mintFromDeny(
        matchingView: MatchingView,
        cwd: WorkingDirectory,
        ruleID: RuleID?,
        now: Date,
        ttl: TimeInterval = 24 * 60 * 60
    ) async -> String?
}
```

Nil on empty matching view, lock/encode failure, or collision after the existing 8 retries. Success returns the same code `mint` would print.

## Hook mapper (RVHooks)

```swift
func hookWire<C: HostCodec>(
    from result: EvaluationResult,
    command: ShellCommand,
    using codec: C,
    bound: BoundReview? = nil,
    cwd: WorkingDirectory? = nil,
    afterSpend: Bool = false,
    unlockCode: String? = nil
) -> HookWire
```

`encodeDeny(..., next:)` on first-call unlockable pack deny:

- `unlockCode == "a1b2c3"` → `next` = `Paste in Terminal to allow once: rv allow-once a1b2c3.`
- reason = `RV · Blocked. ` + unlock + `" "` + why when REQ-204 allows combining.

Helper (name may vary):

```swift
public func hookUnlockNext(code: String?) -> String {
    if let code, code.count == 6, code.allSatisfy(\.isHexDigit) {
        return "Paste in Terminal to allow once: rv allow-once \(code)."
    }
    return hookUnlockNext
}
```

Keep the existing `hookUnlockNext` constant as the no-code string.

## Hook apply shell (RVService / RVCLI)

After in-process or rvd `apply` returns deny, if unlockable:

```swift
let code = await store.mintFromDeny(
    matchingView: result.matchingView,
    cwd: cwd,
    ruleID: deny.ruleID,
    now: now
)
```

Pass `code` into `hookWire`. Spend-first Ask branch must not call `mintFromDeny`. `hostAsk: spend` uses existing `spendHostAsk` only.

## Example deny JSON (Grok / Pi / OpenCode)

```json
{
  "decision": "deny",
  "reason": "RV · Blocked. Paste in Terminal to allow once: rv allow-once a1b2c3. Destroys uncommitted changes. Use 'git stash' first.",
  "rule": "core.git/reset-hard",
  "next": "Paste in Terminal to allow once: rv allow-once a1b2c3."
}
```

Ask JSON must not contain `a1b2c3` or `rv allow-once a1b2c3` as a minted code (the no-code `hookUnlockNext` sentence is allowed on Ask).

## Daily human loop

```
1. Agent runs git reset --hard in /repo (cwd on the hook).
2. Hook apply denies, mints pending, prints the unlock line with a1b2c3.
3. Human, in a TTY in any directory: rv allow-once a1b2c3
   → granted git … (cwd /repo)
4. Agent retries the same command in /repo → consume → allow once.
5. Second retry → deny, new mint, new code.
```

# 5. Acceptance Criteria

- **AC-001**: Given unlockable `git reset --hard` with cwd `/tmp/ws` and an isolated store, when hook apply runs for Grok (or Pi) first-call **deny**, then the store has a `.pending` row for that matching view + cwd, stdout JSON `next` matches `Paste in Terminal to allow once: rv allow-once [0-9a-f]{6}.`, `reason` starts with `RV · Blocked. Paste in Terminal to allow once:`, and `decision` is `deny`.
- **AC-002**: Given that pending code, when `AllowOnceCLI.redeem` runs with an interactive TTYCapability, then the row is `.granted`. A following `PolicyGate.apply` allows once; a second apply denies.
- **AC-003**: Given the same pending code, when redeem is invoked with `stdinIsTTY: false` or `robot: true`, then redeem throws `ttyRequired` / `robotRefused` and the row stays `.pending`. A following hook apply still denies.
- **AC-004**: Given missing cwd on the hook JSON, when apply denies, then no pending row is written and JSON contains no six-hex `rv allow-once` code.
- **AC-005**: Given `core.secrets` or `builtin.action` pin deny, when apply runs, then no mint and no code on the wire.
- **AC-006**: Given a spend-first Pi first-call that pauses (`decision: ask`), when encoding Ask, then JSON has no minted six-hex code and the store gained no new pending row from that Ask.
- **AC-007**: Given `rv test 'git reset --hard'` / `rv explain` / scan classify, when they run against a store that has no grant, then they do not mint. Peek still does not spend.
- **AC-008**: Given mintFromDeny lock failure, when hook apply denies, then exit is still deny (nonzero or host deny JSON) and stdout has no six-hex unlock line.
- **AC-009**: Given README and `rv help` after this change, when a human reads the allow-once examples, then they show redeeming a code, not `rv allow-once 'git reset --hard'`.
- **AC-010**: Given two hook children racing one pending mint+later granted consume, when both apply the same matching view + cwd after one TTY redeem, then exactly one allow (existing CAS/lock).

# 5b. Tickets (task graph)

| id | title | depends-on | exclusive-writes | acceptance | review-hint |
|---|---|---|---|---|---|
| T1 | `mintFromDeny` on `AllowOnceStore` (no TTY) | none | `Sources/RVPolicy/AllowOnceStore.swift`, `Tests/RVPolicyTests/AllowOnceStoreTests.swift` (or new `MintFromDenyTests.swift`) | AC-003 (store-level: false TTY still mints; empty view nil); existing mint/redeem/consume tests stay green | `101–1499` |
| T2 | Call mint after apply deny; thread `unlockCode` without changing `EvaluationResult` | T1 | `Sources/RVService/GatedEvaluate.swift`, `Sources/RVService/ServiceRuntime.swift`, `Sources/RVService/HookDoor.swift`, `Sources/RVCLI/Service/ServiceClient.swift`, `Tests/RVServiceTests/GatedEvaluateTests.swift`, `Tests/RVCLITests/AllowOnceGrantHonorTests.swift` | AC-001 store pending; AC-004 no cwd; AC-005 pin; AC-007 peek/scan do not mint | `101–1499` |
| T3 | Deny JSON reason + `next` carry the code | T2 | `Sources/RVHooks/HostDenyText.swift`, `Sources/RVHooks/HookMapper.swift`, `Sources/RVHooks/HookDispatch.swift`, `Tests/RVHooksTests/HostDenyTextTests.swift`, `Tests/RVHooksTests/HookMapperTests.swift`, `Tests/RVHooksTests/HostAskHookTests.swift` | AC-001 JSON next/reason; AC-006 Ask has no code; AC-008 no fake code on mint fail | `101–1499` |
| T4 | Host codec / adapter fixtures for minted deny | T3 | `Tests/RVHooksTests/PiHookTests.swift`, `Tests/RVHooksTests/OpenCodeHookTests.swift`, `Tests/RVCLITests/HostAskSpendTests.swift`, `Tests/RVCLITests/HookCommandTests.swift`, plus Grok/Claude/Codex/Cursor deny tests that pin reason strings | Pi/OpenCode Ask unchanged; Grok/Claude/Codex/Cursor deny with code still honor-path deny (not allow) | `101–1499` |
| T5 | CLI help + README + CONTEXT | T3 | `README.md`, `CONTEXT.md`, `Sources/RVCLI/Help/HelpCatalog.swift`, `Tests/RVCLITests/AllowOnceTTYTests.swift` (usage/help if pinned), `Tests/RVCLITests/RobotDocumentGoldenTests.swift` only if help goldens exist | AC-009 | `≤100` |

Independent: none after T1. T4 may start when T3’s mapper API is on the branch. T5 must not land examples that T3 does not yet emit.

# 6. Test Automation Strategy

- **Test levels**: Swift Testing unit/integration in `RVPolicyTests`, `RVServiceTests`, `RVHooksTests`, `RVCLITests`. No real TTY. No live HOME.
- **Frameworks**: Swift Testing (`@Test`, `#expect`). Existing `isolatedAllowOnceDirectory()` / `TTYCapability` injection.
- **Test data**: temp allow-once dirs; fixture stdin JSON with explicit `cwd`.
- **CI**: `tools/gate.sh` then at least `tools/gate.sh RVPolicyTests RVHooksTests RVCLITests RVServiceTests`.
- **Coverage**: AC-001–AC-008 in tests. AC-009 is file content assertions or a help test. AC-010 may reuse existing two-process consume coverage; do not drop it.
- **Manual (required before calling the program done):** In a real TTY, trigger a Grok or Pi **deny** of `git reset --hard` with cwd present, copy `rv allow-once <code>`, redeem, retry once (allow) and twice (deny). On Pi Ask, confirm-yes still runs once with no code on the Ask JSON. Corpus is not a substitute.

# 7. Rationale & Context

The two-step mint CLI is complete and unused as a daily loop. Humans see a block and need a paste, not a second command to create a paste. The Mac extra cannot be that paste: it is unbuilt, Mac-only, and easy to miss.

Showing the code on deny means the agent can also read it. Redeem remains TTY-gated, so a hooked child that runs `rv allow-once <code>` still fails. That is the accepted trade: daily unlock works; the agent does not get a granted row for free. Spend-first Ask remains the better door when the host can wait.

Factory PLAN forbade a redeemable code on the wire so the agent could not teach itself the unlock. That lock is what made rv a hindrance. This spec replaces it for pack deny only.

# 8. Dependencies & External Integrations

### External Systems

- **EXT-001**: Host adapters (Pi, Grok, OpenCode, Claude, OpenClaw, Hermes, Codex, Cursor) — already installed by `rv setup`. They must keep honoring deny JSON / native deny. No adapter rewrite except if a template asserts “no allow-once on deny” in tests.

### Third-Party Services

None.

### Infrastructure Dependencies

- **INF-001**: `$HOME/.config/rv/allow-once.jsonl` + `.allow-once.lock` — existing.
- **INF-002**: `rvd` hookEvaluate — must mint on the server so XPC and miss share one file.

### Data Dependencies

- **DAT-001**: Existing `AllowOnceRecord` schema version 1. No new fields.

### Technology Platform Dependencies

- **PLT-001**: Swift 6.3.3, language mode 6. macOS 26 is the claimed v1 platform; the TTY loop must not assume a menu extra (Linux operators use the same CLI).

### Compliance Dependencies

- **COM-001**: Factory PLAN #22 product-tree name hygiene.
- **COM-002**: No command text in `os_log`. Unlock line may appear on host stdout/stderr; that is the hook voice, not a log.

# 9. Examples & Edge Cases

```text
# Daily
rv allow-once a1b2c3

# Still valid pre-arm (not required)
rv allow-once mint -- git reset --hard

# Invalid (must not be documented as unlock)
rv allow-once 'git reset --hard'
```

Edge cases:

- Empty matching view / missing cwd → no mint.
- `git checkout -- file` builtin pin → no mint.
- `cat ~/.ssh/id_ed25519` secrets → no mint.
- Allowlist already allowing → apply never stays deny → no mint.
- Granted row present → apply consumes, allow, no mint.
- Peek `rv test` after pending (not yet redeemed) → still deny (peek checks `.granted` via `hasGrant`, not `.pending`). After redeem, peek may show allow without spending (existing).
- Pi Ask cancel → host block; no code on the Ask; user can retry (Ask again) or TTY-mint manually. Do not mint on Ask in this spec.
- Codex: reason on stderr includes unlock suffix; no extra JSON keys.

# 10. Validation Criteria

- [ ] `mintFromDeny` tests green with `stdinIsTTY: false`.
- [ ] Hook deny with cwd mints pending and prints `rv allow-once` + 6 hex.
- [ ] TTY redeem then one allow, second deny.
- [ ] Non-TTY redeem still refused.
- [ ] Ask JSON has no minted code.
- [ ] Peek/scan do not mint.
- [ ] README / help / CONTEXT match the daily loop.
- [ ] Files this spec adds or edits pass factory PLAN #22 name hygiene.
- [ ] `tools/gate.sh RVPolicyTests RVHooksTests RVCLITests RVServiceTests` green.
- [ ] Manual line in §6 actually run.

# 11. Related Specifications / Further Reading

- `spec/spec-architecture-allow-once-ledger.md` — ledger purity; do not restack.
- `spec/spec-architecture-product-takes.md` — REQ-027 / REQ-030 superseded for minted pack deny copy only; stash tip and no-bypass remain.
- `spec/spec-architecture-pack-coverage-policy-gate.md` — gate order; consume still before mint-on-deny.
- `CONTEXT.md` — vocabulary to update (REQ-304).
- `docs/architecture/02.md` — Host Ask still before Auto-review; extra still not this program.
- `docs/factory/PLAN.md` — conflict arbiter for v1 hook guard; this spec wins on unlock copy for product files.
- `docs/factory/specs/phase-3-allow.md` — original T8 three ops (mint / redeem / consume); mint-on-deny is an additional mint caller, not a collapse of redeem.
