---
title: Pure allow-once ledger behind the actor shell
version: 1.0
date_created: 2026-08-23
last_updated: 2026-08-23
owner: rv
tags:
  - architecture
  - design
  - policy
  - functional-core
---

# Introduction

This specification extracts the allow-once spend state machine out of the
`AllowOnceStore` actor into a pure ledger over `[AllowOnceRecord]`. The actor
keeps every effect — jsonl load/write, `ExclusiveFileLock`, directory prep,
code generation, TTY/robot guards, IO-error mapping. The ledger becomes values
in, values out: no `FileManager`, no `Date()`, no `UUID()`, no `SecRandom`.
Spend semantics (mint collision, redeem expiry, consume precedence) become
testable as table tests over array literals.

This is the C1 Strong candidate of functional-evolution pass 6 (report:
`$TMPDIR/swift-functional-evolution-rv-20260823-2018.html`). It also retires
the known `AllowOnceStore.list` identical-branch if/else rider.

# 1. Purpose & Scope

## Purpose

Make allow-once decision semantics deterministic-testable without filesystem
ceremony while preserving behavior byte-for-byte: identical jsonl format,
identical lock discipline, identical public API (`AllowOnceStore` signatures,
`AllowOnceConsumeStatus`, `AllowOnceError`).

## Audience

Implementers of rv (Swift 6.3.3, macOS 26, Apple Silicon, language mode v6)
and reviewers using `swift-pr-review`.

## In scope

- New pure namespace `AllowOnceLedger` in RVPolicy.
- Rewriting `AllowOnceStore` methods to shell → ledger → shell.
- New pure test target file `Tests/RVPolicyTests/AllowOnceLedgerTests.swift`.
- Removing the `list()` duplicate construction branch.

## Out of scope

- Any change to the public `AllowOnceStore` API surface.
- Any change to jsonl schema, date strategy, key sorting, permissions, lock
  placement, or file paths (`RVPolicyPaths`).
- `PolicyGate`, `AllowlistStore`, CLI commands.
- Concurrency structure of the actor (it stays an actor).
- The known env-only failure `cHookProof_stagedBinariesAndTempHome`
  (pre-existing; not this ticket's gate).

## Assumptions

- Base commit d478064 (= origin/main). Open PRs #58–#72 do not touch RVPolicy;
  zero merge-order risk.
- `Tests/RVPolicyTests/*` use `@testable import RVPolicy` so a non-public
  ledger is visible to tests.

# 2. Definitions

| Term | Meaning |
|---|---|
| **Ledger** | Pure function namespace over `[AllowOnceRecord]`; all inputs explicit, no effects. |
| **Shell** | The `AllowOnceStore` actor: owns I/O, locking, randomness, guards, error mapping. |
| **Decision status** | Outcome of a ledger transition that is not an I/O failure. |
| **IO failure** | Lock or encode/write failures; remain store-only and map onto `.lockFailed` / `.unavailable` / thrown errors exactly as today. |
| **Matching view** | T1-normalized command text (see CONTEXT.md). |
| **Fingerprint** | `commandFingerprint(_:)` = SHA-256 of the matching view (existing helper). |

# 3. Requirements, Constraints & Guidelines

- **REQ-001**: All spend/expiry/prune decisions move from `AllowOnceStore`
  into pure `AllowOnceLedger` functions taking every input as a parameter
  (records, hashes, fingerprints, cwd, `now`, `ttl`).
- **REQ-002**: `AllowOnceLedger` functions contain none of: `FileManager`,
  `Date()` default arguments, `UUID()`, `SecRandomCopyBytes`, locks, or any
  throw of `.lockFailed` / `.encodeFailed` for I/O reasons.
- **REQ-003**: Public behavior is preserved exactly: same prune rules, same
  precedence, same returned statuses/errors per scenario listed in §5.
- **REQ-004**: `AllowOnceStore.list(now:)` builds rows through one code path.
- **REQ-005**: Every existing mutation stays inside `withFileLock` exactly as
  today: mint, redeem, insertGranted, consume, clear. Read-only paths
  (`hasGrant`, `list`) keep their current unlocked raw reads.
- **REQ-006**: Ledger types/functions need not be `public`; module-internal is
  correct since the store is the sole production caller.
- **CON-001**: Swift 6.3.3, language mode v6, strict concurrency; value types
  only in RVPolicy.
- **CON-002**: Do not touch files outside §6 exclusive writes.
- **GUD-001**: Follow repo style contract in AGENTS.md (typed errors, closed
  enums, no boolean flags, no comments unless essential).

# 4. Interfaces & Data Contracts

New file `Sources/RVPolicy/AllowOnceLedger.swift`:

```swift
enum AllowOnceLedger {
    enum RedeemOutcome: Equatable, Sendable {
        case granted(records: [AllowOnceRecord], row: AllowOnceListRow)
        case expired(records: [AllowOnceRecord])
    }

    enum ConsumeOutcome: Equatable, Sendable {
        case consumed(tokenID: String, records: [AllowOnceRecord])
        case expired([AllowOnceRecord])
        case alreadyConsumed
        case notFound
    }

    static func mint(
        records: [AllowOnceRecord],
        codeHash: String,
        fingerprint: String,
        redacted: String,
        cwd: String,
        ruleID: RuleID?,
        now: Date,
        ttl: TimeInterval
    ) throws(AllowOnceError) -> [AllowOnceRecord]

    static func redeem(
        records: [AllowOnceRecord],
        codeHash: String,
        now: Date
    ) throws(AllowOnceError) -> RedeemOutcome

    static func consume(
        records: [AllowOnceRecord],
        fingerprint: String,
        cwd: String,
        now: Date
    ) -> ConsumeOutcome

    static func rows(records: [AllowOnceRecord], now: Date) -> [AllowOnceListRow]

    static func keepConsumed(records: [AllowOnceRecord], now: Date) -> [AllowOnceRecord]
}
```

Semantics each function must reproduce (from current `AllowOnceStore`):

| Function | Semantics to preserve |
|---|---|
| `mint` | First prune `expiresAt >= now \|\| kind == .consumed`; if any remaining pending record has equal `codeHash` and `expiresAt >= now`, throw `.collision` without writing; else append new pending record. |
| `redeem` | Find pending with matching hash → missing: throw `.alreadySpent` if granted/consumed share the hash, else `.unknownCode`; found but `expiresAt < now`: remove **only that pending** (do not prune other expired pending/granted) and return `.expired(records:)`; found and valid: flip to `.granted`, prune expired pending/granted, return `.granted(records:, row:)` of the granted record. |
| `consume` | Filter indices by fingerprint AND cwd. Prefer a granted record with `expiresAt >= now`: flip to `.consumed`, stamp `consumedAt = now`, prune expired granted, return `.consumed(tokenID: its codeHash, records:)`. Else if any related granted record is expired: prune expired granted, return `.expired(records:)`. Else if any related consumed: `.alreadyConsumed`. Else `.notFound`. |
| `rows` | Keep records where `expiresAt >= now \|\| kind == .consumed`; map each kept record to `AllowOnceListRow` via one shared construction. |
| `keepConsumed` | Keep only `kind == .consumed && expiresAt >= now`. |

Actor mapping (stays in `AllowOnceStore`):

- `consume(...)` maps `.consumed(tokenID, r)` → write r → `.consumed(tokenID:)`;
  `.expired(r)` → write r → `.expired`; others returned unwritten; IO catch →
  `.unavailable` (unchanged).
- `redeem(...)` writes returned records inside the lock on both `.granted`
  and `.expired`, then throws `.expired` upward after writing on the expired
  path — net observable behavior identical to today (expired path wrote, then
  threw `.expired`). Ledger `redeem` throws only `.unknownCode` /
  `.alreadySpent`; expiry is `RedeemOutcome.expired`, not a thrown error, so
  the caller can persist the remaining records.
- `hasGrant`, `insertGranted`, `clear`, `mint` keep their current shapes; only
  their inner transitions delegate to the ledger.

# 5. Acceptance Criteria

- **AC-001**: Given array-literal ledgers, pure tests cover: mint collision
  vs fresh hash; redeem grant / expired / alreadySpent / unknownCode;
  consume fresh / expired / alreadyConsumed / notFound / wrong-cwd; rows
  retention incl. consumed-past-expiry; clear retention — all with zero
  filesystem access.
- **AC-002**: Existing `AllowOnceStoreTests.swift` and
  `AllowOnceRecordRoundTripTests.swift` pass unmodified.
- **AC-003**: `rg 'FileManager|Date\(\)|UUID\(\)|SecRandom' Sources/RVPolicy/AllowOnceLedger.swift`
  returns nothing.
- **AC-004**: `list()` has a single `AllowOnceListRow` construction site.
- **AC-005**: `tools/gate.sh` green except the pre-existing env-only
  `cHookProof_stagedBinariesAndTempHome`.

## Tickets

| Field | Value |
|---|---|
| id | AL-T1 |
| title | Pure allow-once ledger behind the actor shell |
| depends-on | none |
| exclusive-writes | `Sources/RVPolicy/AllowOnceLedger.swift` (new), `Sources/RVPolicy/AllowOnceStore.swift`, `Tests/RVPolicyTests/AllowOnceLedgerTests.swift` (new) |
| acceptance | AC-001 … AC-005 |
| review-hint | Largest changed Swift file ≈ 344 LOC (`AllowOnceStore.swift`) → `101–1499` bucket → `swift-pr-review` |

# 6. Test Automation Strategy

- **Levels**: pure unit (new ledger tests), existing integration
  (store tests with temp dirs + real locks stay green untouched).
- **Framework**: Swift Testing (`@Test`), matching existing suite style.
- **Gate**: `tools/gate.sh` with the toolchain at `tools/swift-6.3.3`;
  warm `.build`; never clean-build to prove compilation.

# 7. Rationale & Context

Today every semantic proof about spending a grant requires a real directory,
a lock file, and disk I/O; only the two concurrency tests genuinely need that.
Extracting the ledger makes expiry/precedence rules values-in/values-out,
confines allow-once edits to one value module plus a thin I/O shell, removes
the `.unavailable` conflation from decision outcomes at the internal seam, and
retires the known `list()` rider naturally. RVPolicy is untouched by open PRs
#58–#72, so this lands with zero merge-order risk.

# 8. Dependencies & External Integrations

- **DAT-001**: jsonl store file under `$HOME/.config/rv` — format unchanged;
  round-trip tests are the contract.
- **INF-001**: `ExclusiveFileLock` — unchanged; placement preserved per REQ-005.
