---
title: Type-system seams for rv — typed credentials, MAC purposes, closed vocabularies, fingerprints, admission outcome
version: 1.0
date_created: 2026-11-03
owner: swift-type-system-architecture pipeline (run 32d41850)
tags: [architecture, type-system, enums, newtypes, security, rv, RVIsolation, RVMCP, RVDomain, RVCLI]
---

# Introduction

This spec turns the five type-system candidates and four exploration bugs from the
2026-11-03 Swift type-system review of `rv` into tickets. In every candidate, a typed value
is turned back into a `String`, or one opaque value stands for several shapes. Several of
these seams fail open. The report was generated locally and is not reproduced here.
This spec stands alone.

## 1. Purpose & Scope

Purpose: move invariants that today live in comments, string literals, `default:` arms, and
runtime re-parsing into the type system, without changing any persisted or wire bytes except
where a ticket says so explicitly.

In scope: `RVIsolation` (secrets, gateway), `RVMCP`, `RVMCPCustodianCore`, `RVPolicy`,
`RVDomain` (fingerprints, runtime admission), `RVEngine` (self-protection, runtime-admission
normalize), `RVLaya`, `rv-judge`, `RVService` (JudgeGate, operator ceremonies), `RVIPC`,
`RVCLI` (egress, secrets, audit, managed, report, help, operator), and their tests.

Out of scope: toolchain or deployment-target changes; `IPCResult` channel split; `~Copyable`
fds; the cancellation-flag refactor; `ProposedAction.network`; `HelpDocumented` protocol;
`ProgramName` newtype beyond what B3 needs; moving `SecretDefinition` legality rules into
the type (follow-up only).

Audience: implement-spec subagents (fresh context, sparse pointers).

Assumptions: Swift 6.4, `swiftLanguageModes: [.v6]`, app-internal libraries (no external
conformers, no ABI stability). Base for independent tickets: `origin/main` at `3d3b0228`.

## 2. Definitions

- **Byte-identical**: encoded JSON/JSONL/XPC/robot bytes are unchanged for every value that
  exists today. Prove it with a golden or round-trip test that pins the literal bytes.
- **Closed vocabulary**: a finite set of string spellings owned by one module and compared
  by literal in code.
- **Fail-open**: on an unknown or new value, the code takes the permissive path (allow,
  "active", compliant, exit 0) instead of the restrictive one.
- **Robot output**: machine-readable stdout chosen by `ctx.explicitRobot` / `--json`. Its
  bytes are a contract.
- **Untrusted text**: any string that an agent, a sandboxed process, or a remote peer can
  influence. It must pass through `DisplayedText.field` (human) or
  `DisplayedText.escapeJSONScalars` (robot) before stdout.
- **Gateway-only secret**: a secret whose `SecretDefinition.gatewayOnly` is true (AWS SigV4,
  OAuth). Its resolved value must never be handed out as plain text.

## 3. Requirements, Constraints & Guidelines

- **REQ-001 (C1)**: A resolved secret SHALL be a closed enum (`token` / `awsCredentials` /
  `oauth`), parsed once at the provider/adapter boundary. No site outside that boundary may
  call `AWSCredentialSet(SecretValue)` or `OAuthAccessToken(SecretValue)`.
- **REQ-002 (C1)**: `SecretGateway.Entry` SHALL hold its credential as an enum (`substituted`
  / `signed(AWSCredentialSet, AWSSigningBinding)`), so a signed entry holding a non-AWS value
  cannot be represented. The `signing: AWSSigningBinding?` + "value is a credential set"
  comment invariant SHALL be deleted.
- **REQ-003 (C1)**: Text consumers (`RVMCP/MCPGatewayRuntime`, `RVCLI/AuditForward`) SHALL get
  plain text only through an accessor that returns `nil` for gateway-only secrets. The manual
  `if secret.gatewayOnly` checks SHALL be removed in favour of handling that `nil`.
- **SEC-001 (C2)**: Custodian MAC purposes SHALL be a `String`-raw `Codable` enum on the wire
  (`grant`, `code`, `argument-keys`, `mcp.json`). `enrollment` SHALL NOT be a member of the
  wire type. `allowedPurposes: Set<String>` SHALL be deleted.
- **REQ-004 (C2)**: The custodian verify result SHALL be a three-case enum (`valid`, `forged`,
  `noKey`) at the Swift API. The wire representation stays byte-identical.
- **REQ-005 (C3)**: Each closed vocabulary in §4c SHALL be a `String`-raw enum and switched on
  exhaustively, with no `default:`. Every listed fail-open scenario SHALL become a compile
  error or a fail-closed path.
- **REQ-006 (C4)**: Every `ActionFingerprint` producer SHALL build its raw value through one
  injective encoder. Components containing none of `\`, `,`, `:` (and non-empty lists) SHALL
  encode byte-identically to today. Components containing them SHALL be escaped (`\\`, `\,`,
  `\:`), and an empty list encodes as `\[]`. This changes persisted fingerprint text for every
  runtime HTTP fingerprint (the resource contains `://` and `:443`) and for any command, path or
  refspec containing those characters. Pending ask rows created before the upgrade stop matching
  and are re-asked (fails closed). Grants are unaffected: allow-once and host-door grants key on
  `matchingView`, not fingerprint text. The release SHALL carry a release note stating this.
- **REQ-007 (C4)**: The reviewer-facing sanitized projection (`ReviewSanitizer`) SHALL have a
  type distinct from the raw action/fingerprint, so hard policy cannot be evaluated on a
  redacted action by accident.
- **REQ-008 (C5)**: `RuntimeAdmissionDecision` SHALL store one outcome enum (`execute` /
  `answer` / `deferred`). `authorization` SHALL be derived from it. The placeholder
  `.executed(exitStatus: -1)` SHALL disappear. `RuntimeAdmissionEvent.result` SHALL be a typed
  enum that encodes byte-identically.
- **SEC-002 (B1)**: Every agent-influenced field that `rv egress` prints SHALL be escaped,
  covering both human and robot output, and so SHALL robot output of `rv secrets describe` and
  `rv audit verify`. Hostnames with C0/C1 controls or bidi overrides SHALL render escaped.
- **SEC-003 (B3)**: Self-protection SHALL classify `rv`, `rv-cli` and the shell names
  case-insensitively, plus after backslash-unescape, on every platform. Write the failing test
  first. If the test proves another layer already blocks the case, record that and add the
  regression test only.
- **REQ-009 (B4)**: `rv help login` and `rv login --help` SHALL render a login help page, and a
  test SHALL fail if any `RV.configuration.subcommands` name resolves to the root topic.
- **CON-001**: Persisted/wire bytes (robot JSON, secrets.json, audit JSONL, OCSF, XPC DTOs,
  judge verdict JSON, runtime-admission evidence JSONL, pending-approval and allow-once rows)
  SHALL stay byte-identical, except as REQ-006 allows.
- **CON-002**: No new generic type parameters SHALL cross a module boundary. All candidates
  use enums and newtypes.
- **CON-003**: No `default:` in any switch over an enum introduced or touched by this spec.
- **CON-004**: Do not edit files outside the ticket's `exclusive-writes`, except test files for
  those sources. If that is impossible, stop and report.
- **GUD-001**: TDD. Write a failing test that shows the defect or pins the bytes, then change
  the code.
- **GUD-002**: Match local style. Use Swift Testing where the target already does.
- **PAT-001**: Wire enums use synthesized `RawRepresentable` Codable. Add `unknown(String)` only
  if an existing reader is documented as lenient toward newer writers; say so in the PR.

## 4. Interfaces & Data Contracts

### 4a. C1 — typed resolved credential (T1)

```swift
enum ResolvedSecret: Sendable {           // package/internal; RVIsolation
    case token(SecretValue)
    case awsCredentials(AWSCredentialSet)
    case oauth(OAuthAccessToken)
    var lastingToken: SecretValue? { get } // nil for awsCredentials / oauth
}
extension SecretGateway.Entry {
    enum Credential: Sendable {
        case substituted(SecretValue)                       // surfaces/prefix stay on Entry
        case signed(AWSCredentialSet, AWSSigningBinding)
    }
}
```

Current sites: `SecretGateway.swift:93-125`, `SecretGatewayAWS.swift:22,24,113,179`,
`SecretLaunchBroker.swift:176,212,342,347`, `SecretGatewayRotation` (`SecretRefreshed.value`,
`previous`), `RVMCP/MCPGatewayRuntime.swift:151`, `RVCLI/Commands/AuditForward.swift:258`.
Open design question for the implementer: decide whether parsing lives in each provider or in
one adapter right after `SecretValueResolver.resolve`. Prefer the adapter if providers stay
format-agnostic. Record the decision in the PR body.

### 4b. C2 — MAC purpose (T2)

```swift
public enum MCPMACPurpose: String, Sendable, Codable, CaseIterable {
    case grant, code
    case argumentKeys = "argument-keys"
    case mcpJSON = "mcp.json"
}
public enum MCPMACVerdict: Sendable, Equatable { case valid, forged, noKey }
```

Sites: `RVMCP/CustodianWire.swift:8-9,78`, `MCPApprovals.swift:140,147,195,209,220,243,244`,
`MCPIntegrity.swift:38`, `MCPApprovalKey.swift:80-81`, `RVMCPCustodianCore` (the request
handler, and `ApprovalKeychain.swift:421` keeps `enrollment` internal).

### 4c. C3 — closed vocabularies (T3a–T3e)

| Ticket | Today | Target |
|---|---|---|
| T3a | `RVCLI/Commands/ManagedCommand.swift:9-50` `Status.state: String` + 8 optionals, `default:` → active; `ReportCommand.swift:103` `!= "invalid"` | `enum Status { none(directory), invalid(directory, reason), active(ActiveStatus) }`, custom `encode` with today's flat keys |
| T3b | `RVLaya/LayaJudge.swift:9-31,67-71,253,264`, `FineTunedJudge.swift:116,193-199`: `choice: String`, `probabilities: [String: Double]` | `choice: LayaVerdict.Action`, `probabilities: [Action: Double]` (`CodingKeyRepresentable`), labels parsed to `Action` at bundle load, unknown label → bundle error; consumers `rv-judge/main.swift:94,103`, `RVService/JudgeGate.swift:576,635` |
| T3c | `SecretSource.kind` (`RVIsolation/SecretsConfiguration.swift:35-49`), `RVPolicy/ManagedPolicy.swift:72-75` list, `allowsSecretSource(_: String)` at `SecretLaunchBroker.swift:458`, `RVMCP/MCPGatewayRuntime.swift:156`; VarlockSchema parallel lists `:254-256,270,381-389` | `public enum SecretSourceKind: String, CaseIterable, Codable` in RVPolicy; `allowedSources: [SecretSourceKind]?` (ordered array, not a Set: a Set would reorder robot output, CON-001); `kind` exhaustive; Varlock provider enum |
| T3d | `RVIsolation/SecretGatewayProtocol.swift:254` `code = "\(self)"`; `SecretUseRecord.refusal: String?` (`SecretGateway.swift:46-50`); `misuseEvent` nil path `SecretLaunchBroker.swift:422` | explicit `code` per case (raw-value enum or exhaustive switch returning literals), record stores the typed refusal, audit/OCSF bytes unchanged |
| T3e | `"named"/"custom"` in `RVIPC/IPCOperatorLaunch.swift:20-21`, `WorkspaceOperatorWire.swift:292-293,322-323`; switches in `RVIsolation/WorkspaceHostPrepareHandler.swift:33-44`, `RVService/WorkspaceOperatorCeremony.swift:474-479,624,735,860`, `RVCLI/Commands/OperatorCommand.swift:35,82,85`; `RuntimeAskReason` hand encode `RVService/WorkspaceHostBridgeClient.swift:162-165`, `ActionApprovalCeremony.swift:715-716`, decode `:622-627`; refusal codes `refuse("invalidRequest")` etc., `knownRedeemOutcomes` `WorkspaceOperatorCeremony.swift:523` | `WorkspaceLaunchKind`, `RuntimeAskReason: Codable`, `HostPrepareRefusal`, `HostRedeemOutcome` String-raw enums in RVIPC |

### 4d. C4 — fingerprints (T4a, T4b)

```swift
// RVDomain
public enum FingerprintComponent { /* escapes \ , : ; identity otherwise */ }
extension ActionFingerprint {
    /// The only producer API. Joins kind segments with ":" and list items with ",".
    static func make(_ kind: String, _ segments: [FingerprintSegment]) -> ActionFingerprint
}
```

Producers: `ProposedAction.swift:21,35`, `FilesystemAction.swift:266-278`,
`GitAction.swift:290-302`, `HTTPCanonical.swift:289`, `RVEngine/RuntimeAdmissionNormalize.swift:99`,
`RVPolicy/EgressProposal.swift:219` (and its `parse(fingerprint)` reader, which must use the
same decoder), `SecretRequestAction.swift:47`. T4b: `RVDomain/ReviewSanitizer.swift:21,63` returns
a distinct type, and `ActionPolicyEngine.evaluate(_ request: ReviewRequest)` (`:236`) can no
longer accept it.

### 4e. C5 — admission outcome (T5)

```swift
public enum RuntimeAdmissionOutcome: Sendable, Equatable {
    case execute(AllowedAction)
    case answer(RuntimeAdmissionResponse)
    case deferred(/* what responseDeferred carries today */)
}
public enum RuntimeAdmissionResult: Sendable, Equatable, Codable { // encodes today's strings
    case authorized, exit(Int32), http(Int), rule(String), rejected(...)
}
```

Sites: `RVDomain/RuntimeAdmission.swift:226-307,600-613,697-726`,
`RVIsolation/RuntimeAdmission.swift:657,658,694,695,757,1207`.

## 5. Acceptance Criteria

- **AC-001**: Given an awsProfile secret, when any code outside the resolver adapter tries to
  obtain plain text, then it gets `nil` (gateway-only). `grep -n 'AWSCredentialSet(' Sources`
  shows only the adapter and the type's own file.
- **AC-002**: Given `MCPCustodianRequest.mac(purpose: .grant, …)`, its JSON bytes equal today's
  `"purpose":"grant"` encoding, and decoding `"purpose":"enrollment"` fails.
- **AC-003**: Given a new `ManagedPolicyState` case, when building `rv`, then
  `ManagedCommand`/`ReportCommand` fail to compile until the case is handled.
- **AC-004**: Given a Laya bundle whose labels include an unknown spelling, when loading, then
  loading throws. Persisted verdict JSON from before the change decodes unchanged.
- **AC-005**: `mv /r/a /r/b,/r/c` and `mv /r/a,/r/b /r/c` produce different fingerprints, and
  every existing fingerprint fixture without `\ , :` in components is unchanged.
- **AC-006**: A `RuntimeAdmissionDecision` with both an answer and an execute is
  unrepresentable, and the evidence JSONL golden bytes are unchanged.
- **AC-007**: `rv egress denials` with a host containing `\u{1b}]52;` or `\u{202e}` prints the
  escaped form in human and robot modes.
- **AC-008**: A test runs `RV packs disable`, `rv-CLI …`, `BASH -c 'rv packs disable'` through the
  engine and observes the self-protection block, or the PR documents the existing layer that
  blocks them.
- **AC-009**: `rv help login` prints the login page, and a test enumerating
  `RV.configuration.subcommands` fails on any root fallback.

## 5b. Tickets (task graph)

Branch naming: `arch/32d41850/<ticket>`. Worktree: `<repo>/.worktrees/32d41850/<ticket>`.
Dependent tickets branch from their blocker's branch, and their PRs are stacked on it.

### B1 — Escape untrusted text in egress, secrets describe, audit verify
- depends-on: none
- exclusive-writes: `Sources/RVCLI/Commands/EgressCommand.swift`, `Sources/RVCLI/Commands/AuditCommand.swift`, the `describe` robot path of `Sources/RVCLI/Commands/SecretsCommand.swift`, matching tests under `Tests/RVCLITests` (or the target that tests RVCLI)
- acceptance: AC-007. Robot output of `secrets describe` and `audit verify` goes through `DisplayedText.escapeJSONScalars`. Robot bytes are unchanged for plain-ASCII inputs.
- review-hint: 101–1499 (SecretsCommand may be ≥1500 → adversarial)

### B3 — Case-insensitive self-protection program classification
- depends-on: none
- exclusive-writes: `Sources/RVEngine/SelfProtectionGuard.swift`, `Sources/RVEngine/LaunchedCommands.swift`, `Tests/RVEngineTests/*SelfProtection*`, new test file if needed
- acceptance: AC-008. Existing corpus and preflight checks pass.
- review-hint: ≤100–1499

### B4 — Login help topic plus a no-root-fallback test
- depends-on: none
- exclusive-writes: `Sources/RVCLI/Help/*`, help tests
- acceptance: AC-009
- review-hint: 101–1499

### T2 — `MCPMACPurpose` + `MCPMACVerdict` (C2)
- depends-on: none
- exclusive-writes: `Sources/RVMCP/CustodianWire.swift`, `MCPApprovals.swift`, `MCPIntegrity.swift`, `MCPApprovalKey.swift`, `Sources/RVMCPCustodianCore/*` (purpose handling only), `Sources/rv-mcp-custodian/*` if needed, matching tests
- acceptance: SEC-001, REQ-004, AC-002
- review-hint: 101–1499

### T3a — `ManagedRun.Status` enum (C3)
- depends-on: none
- exclusive-writes: `Sources/RVCLI/Commands/ManagedCommand.swift`, `Sources/RVCLI/Commands/ReportCommand.swift`, matching tests
- acceptance: AC-003. Robot bytes for none/invalid/active are pinned by a golden test.
- review-hint: 101–1499

### T3b — Typed Laya verdict labels (C3)
- depends-on: none
- exclusive-writes: `Sources/RVLaya/*`, `Sources/rv-judge/main.swift`, `Sources/RVService/JudgeGate.swift` (verdict consumption only), matching tests
- acceptance: AC-004
- review-hint: 101–1499

### T3c — `SecretSourceKind` (C3)
- depends-on: none
- exclusive-writes: `Sources/RVPolicy/ManagedPolicy.swift`, `Sources/RVIsolation/SecretsConfiguration.swift`, `Sources/RVIsolation/SecretLaunchBroker.swift` (allowsSecretSource call only), `Sources/RVMCP/MCPGatewayRuntime.swift` (allowsSecretSource call only), `Sources/RVIsolation/VarlockSchema.swift`, `Sources/RVIsolation/SecretStore.swift` (encoder keys only), matching tests
- acceptance: REQ-005 for source kinds. secrets.json and managed policy bytes unchanged.
- review-hint: 101–1499

### T3d — Explicit gateway refusal codes (C3)
- depends-on: T3c (shares `SecretLaunchBroker.swift`)
- exclusive-writes: `Sources/RVIsolation/SecretGatewayProtocol.swift`, `Sources/RVIsolation/SecretGateway.swift` (`SecretUseRecord` only), `Sources/RVIsolation/SecretLaunchBroker.swift` (misuse/audit detail only), `Sources/RVHistory/AuditOCSF.swift` if it reads the code, matching tests
- acceptance: codes for every existing case are byte-identical and pinned by a test. A case with an associated value cannot silently change the code.
- review-hint: ≥1500 likely (SecretGateway.swift)

### T3e — Typed operator launch / ask / host refusal vocabularies (C3)
- depends-on: none
- exclusive-writes: `Sources/RVIPC/IPCOperatorLaunch.swift`, `Sources/RVIPC/WorkspaceOperatorWire.swift`, `Sources/RVIsolation/WorkspaceHostPrepareHandler.swift`, `Sources/RVService/WorkspaceHostBridgeClient.swift`, `Sources/RVService/WorkspaceOperatorCeremony.swift`, `Sources/RVService/ActionApprovalCeremony.swift` (ask-reason coding only), `Sources/RVCLI/Commands/OperatorCommand.swift`, matching tests
- acceptance: REQ-005. XPC DTO bytes unchanged and pinned. No `default:` remains over these values.
- review-hint: ≥1500 likely

### T1 — Typed resolved credential (C1, TOP)
- depends-on: T3d (shares `SecretLaunchBroker.swift`, `SecretGateway.swift`), B1 (shares `SecretsCommand.swift` if touched)
- exclusive-writes: `Sources/RVIsolation/Secret*.swift` (gateway, broker, providers, rotation, AWS, OAuth), `Sources/RVMCP/MCPGatewayRuntime.swift`, `Sources/RVCLI/Commands/AuditForward.swift`, `Sources/RVCLI/Commands/SecretsCommand.swift` (only if required), matching tests
- acceptance: REQ-001..003, AC-001. Gateway behaviour tests unchanged in intent.
- review-hint: ≥1500

### T4a — Injective `ActionFingerprint` encoder (C4)
- depends-on: none
- exclusive-writes: `Sources/RVDomain/ActionFingerprint*.swift` (or wherever the type lives), `ProposedAction.swift`, `FilesystemAction.swift`, `GitAction.swift`, `HTTPCanonical.swift`, `SecretRequestAction.swift`, `Sources/RVEngine/RuntimeAdmissionNormalize.swift`, `Sources/RVPolicy/EgressProposal.swift`, matching tests
- acceptance: REQ-006, AC-005
- review-hint: 101–1499

### T4b — Distinct redacted review type (C4)
- depends-on: T4a
- exclusive-writes: `Sources/RVDomain/ReviewSanitizer.swift`, `Sources/RVDomain/ActionReviewer.swift` and the `ActionPolicyEngine` evaluate entry point, their consumers in `RVService` / `RVPolicy` for the reviewer path only, matching tests
- acceptance: REQ-007. Evaluating hard policy on the sanitized type fails to compile.
- review-hint: 101–1499

### T5 — `RuntimeAdmissionDecision` outcome enum (C5)
- depends-on: none
- exclusive-writes: `Sources/RVDomain/RuntimeAdmission.swift`, `Sources/RVIsolation/RuntimeAdmission.swift`, matching tests
- acceptance: REQ-008, AC-006
- review-hint: ≥1500 likely

### In-flight overlap (rechecked 2026-11-04)

- #478, #479 and #488 are merged. B3 and T3b no longer need to coordinate with them, but
  should still keep diffs in `LaunchedCommands.swift` and `JudgeGate.swift` minimal.
- Exclusive-writes are not guaranteed disjoint across tickets: T3c touched files also listed
  under T3a and B1. Re-diff against open PRs and sibling `arch/*` branches before starting.

## 6. Test Automation Strategy

- Levels: unit (Swift Testing / XCTest as already used per target), plus golden-byte tests for
  every wire/persisted type touched.
- Local gate per ticket: `swift build --build-tests`, then
  `swift test --skip-build --test-product <Target>Tests` for each touched target. Use
  `--filter` for RVIsolationTests, which is large. Then `Scripts/preflight.sh --quiet`.
- CI: `.github/workflows/pr.yml` runs an unfiltered Linux `swift test` plus macOS jobs. Known
  flakes: "macos hook grade" (HookDeadline) and "macos isolation (A-E)"
  `ExecutorLifecycleRegressionTests`. The macOS N-Z job also fails environmentally on
  `proxiedPublicHTTPSStillSucceeds` (curl exit 60). Rerun them, don't debug them.
- No coverage tooling exists. Each ticket adds tests for its new invariant.

## 7. Rationale & Context

Every candidate removes a convention the compiler cannot see. C1's failure mode is credential
disclosure, C2's is MAC domain confusion, and C3's is fail-open on a new case. C4's is an
approval-identity collision, and C5's is answering an agent with a fake exit status. Enums and
newtypes were chosen over generics or phantom types because heterogeneity is not real at any
of these sites and the state is runtime-selected. The CON-001 byte constraint keeps these as
refactors, not migrations. The one exception (REQ-006) changes fingerprint text for every runtime HTTP
fingerprint and for any component containing `\`, `,` or `:`, plus empty lists. Pending asks
re-ask once after upgrade (fail closed); grants key on `matchingView` and are unaffected.

## 8. Dependencies & External Integrations

- **EXT-001**: Custodian XPC peer (`rv-mcp-custodian`): purpose strings on the wire.
- **EXT-002**: SIEM consumers of OCSF/audit JSONL: refusal codes.
- **DAT-001**: Persisted pending-approval and allow-once rows: fingerprint spellings.
- **PLT-001**: Swift 6.4 toolchain, `swiftLanguageModes: [.v6]`, Linux and macOS.

## 9. Examples & Edge Cases

```text
FilesystemAction .move targets ["/r/a", "/r/b,/r/c"]  → shell:fs.move:/r/a,/r/b\,/r/c
FilesystemAction .move targets ["/r/a,/r/b", "/r/c"]  → shell:fs.move:/r/a\,/r/b,/r/c
FilesystemAction .move targets ["/r/a", "/r/b"]       → shell:fs.move:/r/a,/r/b   (unchanged)
```

- A Laya verdict persisted as `{"choice":"review","probabilities":{"allow":0.1,...}}` decodes.
- `GatewayRefusal` cases with associated values keep a stable code without the payload.
- `ManagedRun.Status` none-state robot JSON omits every optional key, as today.

## 10. Validation Criteria

Each ticket's acceptance bullets pass. The local gate is green. The fresh-context review and
the final pass are clean. The PR body states byte-identity evidence.

## 11. Related Specifications / Further Reading

- `spec/spec-architecture-type-system-enums.md` (prior type-system run: ShellAction, ResourceScope, JSONValue)
