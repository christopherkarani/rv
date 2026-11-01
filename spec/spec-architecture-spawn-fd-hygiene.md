---
title: Fuse spawn / fd-hygiene fan-out into one deep module
version: 1.0
date_created: 2026-10-09
owner: rv architecture pipeline
tags: architecture, deep-module, RVIsolation, posix-spawn, fd-hygiene
---

# Introduction

Six copies of fd-relocation logic, two identical C-string vector types, two
byte-identical handshake-script constants, and two hand-rolled
handshake-prefix matchers are scattered across four RVIsolation modules.
Every fd-hygiene fix must land in multiple shallow copies on a
security-critical seam (a leaked fd into the sandbox is a cage escape).
This spec fuses them behind one narrow spawn-primitives interface with a
single implementation. Behavior-preserving refactor; no semantic change.

## 1. Purpose & Scope

Purpose: concentrate spawn fd-hygiene behind one tested interface so fixes
land once and slow integration spawns collapse into fast unit tests.

Scope: `Sources/RVIsolation/` (4 named files + 1 new file) and one new test
file under `Tests/RVIsolationTests/`. Out of scope: supervision-policy
merges (the two wait loops keep their divergent policies), socket-evaluate /
auth-matrix work (parked), any other architecture candidate.

Audience: the T1 implementer, reviewers, and future maintainers of the
spawn path. Assumes Swift 6.4, macOS 15 SDK, Swift Testing.

## 2. Definitions

- **fd**: POSIX file descriptor (`Int32`).
- **floor**: minimum fd number; descriptors below it are moved up so low
  numbers stay free for the child's granted set.
- **CLOEXEC**: close-on-exec flag; moved descriptors must carry it so
  `exec` never inherits them.
- **argv/envp vectors**: null-terminated C-string arrays for
  `posix_spawn`.
- **handshake**: nonce byte string the in-sandbox wrapper writes to prove
  containment before exec.
- **nonce**: random per-spawn string the parent expects back.
- **spawn primitives**: the new deep module (relocate + vectors +
  handshake script + prefix matcher).

## 3. Requirements, Constraints & Guidelines

- **REQ-001**: One shared `relocate` helper moves an fd at/above a floor
  via `F_DUPFD_CLOEXEC`, closes the original, and reports failure. All 6
  sites call it: `SessionSupervisor.swift` (2 inline sites),
  `RuntimeAdmissionSpawn.swift:74-87` and `:345-353`,
  `RuntimeTerminal.swift:864-872`, `WorkspaceInodeBoundary.swift:229-237`.
  Line numbers are main@04b4740c; implementer re-verifies.
- **REQ-002**: One shared C-string vector type replaces `SpawnPointers`
  (`SessionSupervisor.swift:1529-1558`) and `AdmissionSpawnPointers`
  (`RuntimeAdmissionSpawn.swift:448-475`). Both spawn paths
  (`SessionSupervisor.swift:598-599`,
  `RuntimeAdmissionSpawn.swift:302-303`) use it for argv and envp.
- **REQ-003**: One shared handshake-script constant replaces the two
  byte-identical literals (`SessionSupervisor.swift:7-8`,
  `RuntimeAdmissionSpawn.swift:217-218`). Both spawn paths use it.
- **REQ-004**: One shared handshake-prefix matcher kernel
  (expected-prefix accumulation + starts-with/count gate) is used by both
  wait loops (`waitForSeatbeltSession`,
  `SessionSupervisor.swift:1009-1075`; `waitForAdmittedPayload`,
  `RuntimeAdmissionSpawn.swift:355-405`). Loop supervision policies
  (admission service, cancellation, death observation, session-leader
  handling, kill/reap tails) stay exactly where they are.
- **REQ-005**: Delete the superseded private copies. No dead remnants, no
  compatibility shims, no re-export aliases.
- **REQ-006**: New unit tests at the spawn-primitives interface cover
  relocate, vectors, the script constant, and the matcher (see section 6).
- **SEC-001**: fd hygiene preserved exactly: each site keeps its current
  floor; no additional fd is inheritable by any child; moved fds carry
  CLOEXEC. Tests pin floors and CLOEXEC per site shape.
- **SEC-002**: The shared handshake script is byte-identical to the
  current literal (test pins the exact string).
- **CON-001**: Behavior-preserving. No semantic change to any spawn path,
  error mapping, errno handling, or logging.
- **CON-002**: Preserve platform gating exactly. The new module must
  compile for every configuration CI builds (macOS Swift 6.4 and Linux
  `swift test`). No Darwin-only API outside the existing guard pattern;
  `RuntimeTerminal.swift` and `WorkspaceInodeBoundary.swift` sites must
  still compile wherever they compile today.
- **CON-003**: Swift 6.4, strict concurrency clean. No new warnings. No
  `@unchecked Sendable` on the new module. No public API beyond what the
  4 call sites need (module-internal unless the package demands more).
- **CON-004**: Existing `RVIsolationTests` pass unmodified. If a test
  references a removed private symbol (via `@testable`), adapt it
  minimally and call it out in the PR body. No test deletions.
- **CON-005**: Single ticket, single PR. The fusion is one inseparable
  outcome: leaving any copy behind fails the deletion test.
- **GUD-001**: Follow `swift-feature-implementation`: baseline first, TDD
  (failing focused tests before the fusion), smallest coherent change.
- **GUD-002**: Route all POSIX/unsafe-pointer work through
  `swift-systems-safety`, including its systems-boundary reference before
  touching descriptor or pointer code.
- **GUD-003**: Optional, only if shapes match exactly: factor the
  pipe()+CLOEXEC+relocate setup prologue shared by the two spawn
  functions. Do not stretch the interface to fit.

## 4. Interfaces & Data Contracts

Non-normative sketch; the implementer fits names to repo conventions. What
is normative: one function, one vector type, one constant, one matcher
type, all behind a narrow seam in one new file.

```swift
// Relocate fd at/above floor. Returns false on invalid fd or fcntl failure.
func relocateDescriptor(_ fd: inout Int32, above floor: Int32) -> Bool

// Null-terminated C-string vector; owns strdup storage until release().
struct SpawnCStringVector {
    init(_ values: [String])
    func withPointers<T>(
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> T
    ) -> T?
    func release()
}

// Byte-identical handshake wrapper script. Child writes $1 to fd 3,
// closes it, then execs the payload.
let spawnHandshakeScript: String

// Expected-prefix accumulation shared by both wait loops.
struct HandshakePrefixMatcher {
    init(expected: Data)
    // Returns true once accumulated bytes start with expected AND
    // accumulated count >= expected count.
    mutating func append(_ bytes: Data) -> Bool
}
```

Error mapping: `relocateDescriptor` returns `Bool` (matches 4 of 6
sites); the 2 inline `guard` sites convert to their existing failure
values unchanged.

## 5. Acceptance Criteria

- **AC-001**: Given the 6 relocation sites, When grepping
  `F_DUPFD_CLOEXEC` under `Sources/`, Then exactly one implementation
  site remains and all 6 call sites route through it.
- **AC-002**: Given the 2 vector types, When grepping `SpawnPointers`
  under `Sources/`, Then one type remains, used at both spawn paths for
  argv and envp.
- **AC-003**: Given the 2 script literals, When grepping the handshake
  literal under `Sources/`, Then it appears exactly once.
- **AC-004**: Given the 2 wait loops, When reading both bodies, Then both
  use the shared matcher kernel and neither supervision policy changed.
- **AC-005**: Given a clean checkout of the ticket branch, When running
  `swift build`, `swift test --filter RVIsolationTests`, and
  `Scripts/preflight.sh --quiet` on macOS, Then all pass with no new
  warnings.
- **AC-006**: Given the existing `RVIsolationTests` suite, When running
  it unfiltered for that target, Then every pre-existing test passes.

## 5b. Tickets (task graph)

| Field | T1 |
|---|---|
| `id` | T1 |
| `title` | Fuse spawn/fd-hygiene fan-out into one spawn-primitives module |
| `depends-on` | none |
| `exclusive-writes` | `Sources/RVIsolation/SpawnPrimitives.swift` (new; exactly one new source file — if repo conventions demand a different filename, that file instead), `Sources/RVIsolation/SessionSupervisor.swift`, `Sources/RVIsolation/RuntimeAdmissionSpawn.swift`, `Sources/RVIsolation/RuntimeTerminal.swift`, `Sources/RVIsolation/WorkspaceInodeBoundary.swift`, one new test file under `Tests/RVIsolationTests/`. No other files. |
| `acceptance` | AC-001..AC-006 green; new unit tests fail before / pass after (TDD); PR opened against the spec |
| `review-hint` | `>=1500` (`SessionSupervisor.swift` is 1560 LOC) |

Single ticket per CON-005. Frontier: T1 is ready.

## 6. Test Automation Strategy

- **Test Levels**: Unit (new: relocate / vectors / script / matcher) +
  existing target integration suite (`RVIsolationTests`) as the
  no-regression gate.
- **Frameworks**: Swift Testing (`import Testing`, `@Test`, `#expect`,
  `@testable import RVIsolation`), matching the target's existing files.
- **New unit cases** (minimum):
  - relocate: fd below floor moves at/above floor, carries CLOEXEC,
    original closed; fd already above floor untouched; fd -1 returns
    false; use real `pipe()` fds, close everything created.
  - vectors: `withPointers` yields argv content + null terminator;
    empty input still yields just the terminator; `release()` frees
    (run under the default test sanitizer config; no leak diagnostics).
  - script: shared constant equals the exact pinned literal.
  - matcher: split-packet accumulation establishes; wrong prefix never
    establishes; exact-boundary count establishes; empty appends are
    harmless.
- **Test Data Management**: real fds only, created and closed in-test.
  No fixtures, no network, no sandbox escape.
- **CI/CD Integration**: repo gate is `Scripts/preflight.sh --quiet` +
  `swift test` (see `.github/workflows/pr.yml`). Implementer runs
  preflight + the RVIsolationTests target locally; full `swift test` is
  CI's job but the implementer runs it if time permits.
- **Coverage Requirements**: every new public-within-module symbol has a
  direct unit test. No coverage theater on the untouched loops.
- **Performance Testing**: none (spawn-path cold code; no hot loop).

## 7. Rationale & Context

The deletion test passes for the four fused pieces (relocate, vectors,
script, matcher kernel): deleting any copy into the shared module
concentrates real complexity behind one tested interface. It fails for a
full wait-loop merge: the loops' supervision policies genuinely differ
(admission service vs session-leader exit vs death observation), so a
merge would move the complexity plus add a wide policy interface — the
loops stay separate, sharing only the matcher kernel. All fused pieces
are in-process (pure fd/syscall helpers), so no port/adapter seam is
needed. Discovery: `/tmp/architecture-review-2026-10-09.html` (card 1),
explorer notes `/tmp/arch-explore-isolation.md`, both outside the repo.

## 8. Dependencies & External Integrations

None. In-process refactor; no new packages, services, or data sources.

### Technology Platform Dependencies
- **PLT-001**: Swift 6.4 toolchain, macOS 15 SDK for local runs; Linux
  Swift 6.4 for CI parity (no Linux-only APIs; guard Darwin-only ones).

## 9. Examples & Edge Cases

```swift
// Relocate shapes that must all keep working:
var a: Int32 = 3;  relocateDescriptor(&a, above: 16) // moves, closes 3
var b: Int32 = 20; relocateDescriptor(&b, above: 16) // untouched, true
var c: Int32 = -1; relocateDescriptor(&c, above: 16) // false, no syscall crash
```

Edge cases: `fcntl` failure returns false and leaves the original fd
open (caller maps to its existing error); concurrent spawns never share
fds (each prologue owns its pipe); matcher fed more bytes than expected
still establishes exactly once (callers gate on their own flag).

## 10. Validation Criteria

- AC-001..AC-006 green on the ticket branch.
- `git diff main...<branch> --stat` touches only exclusive-write paths
  plus this spec file.
- Adversarial review (routed by file size) + final pass clean, fixes
  committed to the ticket branch.
- One PR, base `main`, body links this spec + T1 + review skills used.

## 11. Related Specifications / Further Reading

- `spec/spec-architecture-type-system-enums.md` (landed; not relitigated)
- `spec/spec-architecture-engine-composition-door.md` (not relitigated)
- `spec/spec-architecture-rule-identity-ipc-helpers.md` (not relitigated)
- Discovery report: `/tmp/architecture-review-2026-10-09.html` (outside repo)
- Parked follow-ups (later runs, NOT this spec): redirect-lexer
  unification, writer flag-scan rebuild, per-host settings-merge
  unification.
