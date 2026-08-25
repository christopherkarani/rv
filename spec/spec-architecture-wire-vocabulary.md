---
title: Wire Vocabulary Closure — typed host dispatch, closed error payloads, phantom-method retirement
version: 1.0
date_created: 2026-08-23
owner: rv
tags: [architecture, type-system, ipc, hooks]
---

# Introduction

Execute the Strong candidate from functional-evolution pass 5
(`$TMPDIR/swift-functional-evolution-rv-20260823-1400.html`). This is the sanctioned
C3+C4 deferred work from the 2026-08-23 discovery report; its TH-series blocker merged
(#59/#61/#62). Two serialized tickets close the last stringly-typed seam in an otherwise
typed codebase:

1. **WV-T1** — the hook host identity decodes as a closed value at the wire boundary,
   and the codec-dispatch body exists exactly once (today it is duplicated line-for-line
   between rvd's `HookDoor` and the CLI replay path `HookRun`).
2. **WV-T2** — `IPCError` payloads become closed vocabulary (`protocolSkew` carries
   `SkewReason?`; `engine(String)` junk drawer becomes named cases), `ExplainStage.name`
   becomes the existing `ExplainStep.ID`, and the phantom `allowOnceConsume` wire method
   is retired.

Base SHA: `d478064` (main). Toolchain: swift-tools 6.3 / toolchain 6.3.3
(`tools/swift-6.3.3`), language mode 6, macOS 26 only. Gate: `tools/gate.sh`. Never wipe
`.build` to prove a compile.

Audience: fresh-context implementer/reviewer subagents. Collision plan: WV-T1/T2 touch
small disjoint regions of `Sources/RVService/ServiceRuntime.swift`, which open PRs
#58/#60 are rewriting elsewhere in the file — accepted trivial-rebase class, same
precedent the board took for #66/#67 stacking on RobotDocument appends.

## 1. Purpose & Scope

Reduce runtime ambiguity at the `rv.ipc.v1` boundary so that adding a fourth host or a
new skew reason is a compiler-checked change, the rvd answer and the C-hook replay child
cannot drift, and no wire method advertises behavior the product forbids.

In scope: RVIPC, RVHooks, RVService hook/skew/error regions, RVDomain host identity,
RVCLI `Hook` command plumbing, tests for all of these.
Out of scope: transport (`XPCEvaluateClient`, `XPCServiceTransport`), evaluate door
(`GatedEvaluate`, `EvaluateSession`, `EvaluateWorld` — owned by #58/#60), output
rendering, setup flow, analytics.

## 2. Definitions

| Term | Meaning |
|---|---|
| Host family | The closed three-case set grok / pi / opencode (`HookHost`) |
| Codec dispatch | decode stdin → evaluate → `hookWire(from:command:using:)` body |
| Wire-stable | Raw values pinned across releases; changing one breaks shipped clients |
| Phantom method | Declared+Codable wire method whose dispatch always returns `.unknownMethod` |
| Deep module | Simple interface hiding substantial implementation (Ousterhout) |

## 3. Requirements, Constraints & Guidelines

### WV-T1

- **REQ-101**: `HookHost` moves to RVDomain (identity: raw values `"grok"`, `"pi"`,
  `"opencode"` unchanged, still `String`-raw, `Codable`, `Sendable`, `Equatable`,
  `Hashable`). RVHooks keeps the hook-wire behavior extension (`denyExitCode`) and any
  other hook-specific members; RVHooks/RVCLI/RVService references compile unchanged
  apart from imports. The "duplication is accepted" comment at `IPCMethods.swift:403`
  is deleted along with the reason for it.
- **REQ-102**: `HookEvaluateParams.host` becomes that closed type with strict decoding:
  an unknown host string fails `init(from:)` with `DecodingError.dataCorrupted`. Wire
  bytes for valid hosts are unchanged (same key, same strings). `ExplainStage`-style
  precedent: `EvaluationPath`/`SkewReason` strict enums.
- **REQ-103**: Exactly one production codec-dispatch body exists, in RVHooks, e.g.
  `public func hookWire(host:stdin:evaluate:) async -> HookWire`: one exhaustive
  `switch host` selecting the concrete codec (no existentials needed — generic inner
  function over `some HostCodec`), one decode→evaluate→hookWire body. `.foreign`
  still encodes allow; `.malformed` fails closed through `encodeDeny`.
- **REQ-104**: `HookDoor.run(host:stdin:evaluate:)` keeps its signature shape but takes
  the closed host type and delegates to the single dispatch; its default/unknown-host
  arm and `IPCError.engine("unknown host")` throw disappear (unrepresentable).
- **REQ-105**: RVCLI `Hook.run(stdin:evaluate:)` loses its own host→codec switch and
  calls the same single dispatch; the `HookRun` namespace is deleted if it becomes an
  empty shell. `rv hook --host <invalid>` keeps today's observable CLI behavior
  (ArgumentParser rejects unknown case before evaluation).
- **REQ-106**: `ServiceRuntime.makeHookEvaluateResult` passes `params.host` through;
  its catch-all `catch { return .error(.engine("hook evaluate failed")) }` region is
  WV-T2 scope — do not restructure it here beyond what the type change forces.

### WV-T2

- **REQ-201**: `IPCError.protocolSkew(String)` becomes `protocolSkew(SkewReason?)`.
  Producers: `acknowledge`-miss paths map real reasons to cases; the protocol-name echo
  at `ServiceRuntime.swift:140` maps to `.protocolSkew(.protocolSkew)`; the implicit-
  hello fallback literal `?? "protocol"` disappears (the ack already carries the enum);
  "handshake required" becomes a dedicated `case handshakeRequired` encoded under its
  own coding key (`true`). Decoding stays total over the closed set; unknown payloads
  fail decode like today.
- **REQ-202**: `IPCError.engine(String)` is replaced by named cases for its four
  producers: `.hookFailed`, `.packMutationFailed` (both enable/disable failure sites),
  plus keep existing named cases. No `String`-associated engine case remains.
- **REQ-203**: `ExplainStage.name` becomes `RVDomain.ExplainStep.ID`; encoding uses the
  raw value so frame bytes stay identical (`normalize`, `quick-reject`, `safe`,
  `destructive`, `default`). `elapsedMs` untouched.
- **REQ-204**: The `allowOnceConsume` wire method is retired: remove `IPCMethod`
  and `IPCResult` cases, `AllowOnceConsumeParams/Reply`, their CodingKeys arms, the
  `ServiceRuntime` dispatch arm (:165–166), the `implicitHelloSemver` arm (:133), the
  `logIfNeeded` arm (:404–405), and the round-trip test rows. PLAN.md confirms no
  consumer: allow-once is TTY-only and the hook wire never carries codes
  (`docs/factory/PLAN.md:17,158`; `CONTEXT.md` Allow-once grant).
- **REQ-205**: Golden-frame tests pin byte-identical encoding for: valid-host
  `hookEvaluate` request/reply, `HelloAck` skew reasons, `ExplainReply.stages`, and the
  C-fixture byte pin `"protocolSkew":"major version"` (rv-c/tests/json_reply_test.c:67)
  continues to hold without editing the C side.
- **CON-001**: No toolchain/deployment-target changes; Swift 6 language mode strictness
  holds; value types only outside the XPC edge.
- **CON-002**: No new protocols, no `Any`/force casts, no new dependencies. Prefer
  exhaustive `switch` so future cases fail compilation loudly (GUD-001 repo idiom).
- **CON-003**: Forbidden list holds: no bypass envs, no command text in logs/analytics,
  history off, no live-HOME tests.
- **CON-004**: Client and daemon ship together (same justification as the SkewReason
  FE3-T2 landing): error-payload byte changes on non-skew paths are acceptable; skew
  bytes themselves must not change.
- **PAT-001**: Follow established idioms: `EvaluationPath` strict enum decode
  (IPCMethods.swift:41–44,59–72), `ClassifyRisk.derive` totality, `ExclusiveFileLock`
  deep-module style, `AllowOnceError` typed errors.

## 4. Interfaces & Data Contracts

```swift
// RVDomain (moved from RVHooks; behavior stays behind)
public enum HookHost: String, Codable, Hashable, Sendable {
    case grok
    /// Pi adapter wire, not a host protocol.
    case pi
    /// OpenCode adapter wire, not a host protocol.
    case opencode
}

// RVHooks — the one dispatch body
public func hookWire(
    host: HookHost,
    stdin: String,
    evaluate: @Sendable (ShellCommand, String?) async -> EvaluationResult
) async -> HookWire
// one switch host → concrete codec → shared generic body<C: HostCodec>

// RVIPC
public struct HookEvaluateParams: Sendable, Equatable, Codable {
    public var host: HookHost        // strict decode; unknown fails dataCorrupted
    public var stdin: String
    public var clientSemver: String?
}

public enum ExplainStageName /* spelling may match ExplainStep.ID directly */ { }

public struct ExplainStage: Sendable, Equatable, Codable {
    public var name: ExplainStep.ID  // rawValue bytes identical
    public var elapsedMs: Double
}

public enum IPCError: Error, Sendable, Equatable, Codable {
    case unknownMethod
    case decodeFailed
    case handshakeRequired                 // was .protocolSkew("handshake required")
    case protocolSkew(SkewReason?)         // was .protocolSkew(String); nil = unclassified
    case hookFailed                        // was .engine("hook evaluate failed")
    case packMutationFailed                // was .engine("pack enable failed")
    case packNotFound(PackID)
    case allowOnceNotFound
    case allowOnceAlreadyConsumed
    case allowOnceExpired
}
```

Callers after both tickets: `HookDoor.run` = reply mapping only; `Hook` command = stdin +
dispatch + exit-code mapping; `ServiceRuntime` = pass-through + named error mapping.

## 5. Acceptance Criteria

- **AC-101 (T1)**: `rg -n 'case \.grok' Sources` shows the family declared once
  (RVDomain) plus exhaustive consumers; zero rawValue string switches over hosts remain
  in RVService/RVCLI production code.
- **AC-102 (T1)**: `rg -n 'decode\(stdin\)' Sources` matches exactly one production site
  (the RVHooks dispatch body); HookDoor and Hook contain no codec-selection switches.
- **AC-103 (T1)**: Decoding a `HookEvaluateParams` frame with `"host":"nope"` throws
  `DecodingError`; golden round-trip for a valid frame is byte-identical to pre-ticket.
- **AC-104 (T1)**: Existing hook parity tests (Grok/Pi/OpenCode deny JSON + exit codes)
  pass unmodified in intent; `tools/gate.sh` green.
- **AC-201 (T2)**: `rg -n '"handshake required"|?? "protocol"' Sources` returns nothing;
  `rg -n '\.engine\(' Sources` returns only the enum definition removal diff — zero
  producers/consumers remain.
- **AC-202 (T2)**: `rg -n 'allowOnceConsume' Sources Tests` matches nothing; envelope
  decode of a legacy `allowOnceConsume` request falls into the existing unknown-key
  failure path (`unknownMethod`-style response preserved by the decoder's else branch —
  verify with a test).
- **AC-203 (T2)**: Golden frames prove byte-identical JSON before/after for
  HelloAck-skew, EvaluateReply, ExplainReply stages, and the C fixture's
  `"protocolSkew":"major version"` bytes.
- **AC-204 (T2)**: Every producer/consumer of `IPCError` compiles exhaustively; adding
  a hypothetical case breaks the build (verified by reviewer inspection, not committed).
- **AC-205 (all)**: `tools/gate.sh` passes preflight + filtered tests on each ticket
  branch; `git grep -nE 'as!|try!'` shows no new occurrences; no TODO/FIXME left.

## 5b. Tickets (task graph)

| Field | WV-T1 | WV-T2 |
|---|---|---|
| `id` | WV-T1 | WV-T2 |
| `title` | Typed host identity + single codec dispatch | Closed error payloads, typed stage name, retire phantom method |
| `depends-on` | none | WV-T1 |
| `exclusive-writes` | `Sources/RVDomain/**` (HookHost.swift new), `Sources/RVHooks/**`, `Sources/RVIPC/IPCMethods.swift` (host field region), `Sources/RVService/HookDoor.swift`, `Sources/RVService/ServiceRuntime.swift` (makeHookEvaluateResult signature only), `Sources/RVCLI/Commands/HookCommand.swift`, `Tests/RVDomainTests/**`, `Tests/RVHooksTests/**`, `Tests/RVIPCTests/HookEvaluateRoundTripTests.swift`, `Tests/RVServiceTests/HookEvaluateTests.swift`, `Tests/RVCLITests/**` (hook-related) | `Sources/RVIPC/IPCMethods.swift`, `Sources/RVIPC/IPCEnvelope.swift`, `Sources/RVService/ServiceRuntime.swift` (skew/error/log/dispatch regions), `Tests/RVIPCTests/**`, `Tests/RVServiceTests/{OneShotEvaluateTests,FakeXPCUnixSocketTests,ServiceRuntime*Tests}.swift`, `Tests/rv-c fixture pins (read-only)` |
| `acceptance` | AC-101…104, AC-205 | AC-105 n/a, AC-201…205 |
| `review-hint` | largest changed file likely IPCMethods ≈638 LOC → `swift-pr-review` | same routing |

Parallel-safe: **No** — both tickets edit `IPCMethods.swift` and disjoint
`ServiceRuntime.swift` regions. Serialize WV-T2 onto WV-T1's branch.

Specialist skills: `swift-type-system-architecture` (vocabulary closure),
`swift-concurrency` (the `@Sendable` evaluate closure), repo skill
`.grok/skills/swift-evaluate-parity` only if hook parity goldens need interpretation.

## 6. Test Automation Strategy

- Framework: Swift Testing (`@Test`, `#expect`) per repo convention; fakes stay in
  `Tests/`.
- Hermeticity: no live HOME; temp-dir stores where stores are touched (they are not,
  except deletion fallout in ServiceRuntime tests using existing fixtures).
- Golden discipline: capture pre-ticket bytes for the five pinned frames (valid
  hookEvaluate req/reply, HelloAck skew ×3, ExplainReply stages, error shapes) inside
  each ticket's first commit, then assert equality after the change within the same
  ticket.
- Gate: `tools/gate.sh` on the ticket branch before review handoff; full gate before PR
  ready-marking.

## 7. Rationale & Context

Every remaining runtime fallback in the seam (`?? "protocol"`, unknown-host mid-dispatch
throw, four prose engine errors) is deleted rather than relocated; the twin dispatch
drift hazard between rvd and the C-hook replay child is eliminated; the wire stops
advertising `allowOnceConsume`, which product law reserves to the TTY + Policy gate.
The pattern family (strict-decode closed enums with wire-stable raw values) is already
established by `EvaluationPath`, `SkewReason`, `DoctorCheckID`, `ClassifyRisk` — this is
debt pay-down on the same loom, not a new architecture.

## 8. Dependencies & External Integrations

None new. Darwin/Foundation as today; no third-party packages. The C hook
(`Sources/rv-c`) is read-only this run: it already validates hosts C-side
(`is_valid_host`, rv.c:116–153) and never sends invalid ones; its test pins survive
byte-identically.

## 9. Examples & Edge Cases

- Unknown host on the wire from a hostile client: decode fails → existing
  `handleIncoming` catch returns `.error(.decodeFailed)` — strictly better than today's
  post-decode `.engine("unknown host")`, same connection semantics.
- Implicit-hello evaluate with wrong major semver during core-pack outage: ack wins
  (hello precedes dispatch); order unchanged.
- Legacy frames containing `allowOnceConsume` keys: decoder's terminal else branch
  already yields `dataCorrupted` → `.error(.decodeFailed)` response; pin with a test.
- `ExplainStep.ID` future case additions: encoder emits new kebab strings; old daemons
  decoding them fail stage decode — acceptable under ship-together law (same as
  SkewReason rationale).

## 10. Validation Criteria

Per ticket: gate green; AC bullets demonstrably true (grep outputs quoted in PR body);
golden equality proven; reviewer findings fixed; final pass clean; PR opened (stacked
WV-T2 → WV-T1). Branch names: `arch/<run-id>/WV-T1`, `arch/<run-id>/WV-T2`.

## 11. Related Specifications / Further Reading

- `$TMPDIR/swift-functional-evolution-rv-20260823-1400.html` (discovery report, candidate 01)
- `spec/spec-architecture-fe3-doors.md` (one-door lineage this extends)
- `spec/spec-architecture-functional-evolution-3.md` (SkewReason precedent, §4 T2)
- `docs/factory/PLAN.md` (conflict arbiter), `docs/architecture/MODULES.md`, `CONTEXT.md`
