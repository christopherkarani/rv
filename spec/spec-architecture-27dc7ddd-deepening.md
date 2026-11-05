---
title: Deepen seven shallow modules — control codec, writer union, compile-set, deny dispatch, rollback, endpoint, robot JSON
version: 1.0
date_created: 2026-11-04
owner: rv architecture pipeline (run 27dc7ddd)
tags: architecture, deep-module, RVIsolation, RVEngine, RVService, RVHooks, RVPolicy, RVMCP, RVCLI
---

# Introduction

Seven shallow fan-outs sit on hot paths: a four-shape control-frame wire
format, per-verb redirect strip/union, caller-choreographed compile-set
freshness, evaluated-deny dispatch split between two modules, a rollback
decision split across a seam, a twice-assembled endpoint classification,
and five robot-JSON encoder recipes. Each fix today must land in multiple
places with no single seam of leverage. This spec deepens each behind one
small interface. All seven are behavior-preserving refactors except where
a ticket explicitly names a divergence fix (T6 loopback spelling, T7
escaping of currently-unescaped output); those two name the exact output
change allowed and no other.

Report: `architecture-review-20261104-021231.html` in the OS temp
directory (run 27dc7ddd). Base commit: `6413ac7f` (`origin/main` at run
start). Each implementer re-verifies line numbers on their ticket branch.

## 1. Purpose & Scope

Purpose: concentrate each duplicated decision behind one deep module so
fixes land once, with tests at the new seam (the interface is the test
surface).

In scope: tickets T1–T7 (§5b), each with exclusive write paths.

Out of scope (do not touch, do not relitigate):

- Chain semantics in analysis (report C8): needs a fingerprint/replay and
  `ProposedAction` wire decision first; separate spec after grilling.
- ActionPolicyEngine world doors, ceremony lifecycle module, JSON parser
  unification, MCP review grammar, ScanRun deletion, cancel-clock seam
  (report "Worth exploring" / "Speculative").
- Every landed deepening: `SecretRelease`, `JSONLAppendLog`,
  `SpawnPrimitives`, `RedirectOperatorLexer`, `FlagScan`/`FlagToken`,
  `HostHooksMergeEngine` + `SettingsMergePolicy`, `ShellAction` enum,
  RVDomain `JSONValue`, single `HomeDirectory` resolver.
- Toolchain, deployment target, `Package.swift` target graph. New files
  inside an existing target directory need no manifest edit.

Audience: T1–T7 implementers, fresh-context reviewers, future
maintainers. Assumes Swift 6.4, `swiftLanguageModes: [.v6]`, macOS 15
floor, Swift Testing.

## 2. Definitions

Vocabulary (codebase-design): **module**, **interface**, **depth**,
**deep**, **shallow**, **seam**, **adapter**, **leverage**, **locality**.
Do not substitute component/service/API/boundary in code comments or PR
text for these concepts.

- **control frame**: one workspace-host RPC message on the wire
  (`WorkspaceControlProtocol`).
- **per-op payload**: typed in-process shape for one control op
  (piloted in `WorkspaceControlLaunchPayloads`).
- **writer verb**: filesystem verb that writes destinations
  (cp/tee/install/ln/rsync/sed/zip/rm/mv/…).
- **redirect union**: adding shell redirect destinations to a verb's
  destinations, including on verb-parse failure/help.
- **compile set**: the packs compiled into the live `GatedEvaluate`
  door, plus the snapshots they were compiled from.
- **deny presentation**: the composed deny content (reason, rule, next,
  matched rule match, Cursor agent text) before per-host wire rendering.
- **replacement decision**: the rollback/relaxation finding set for
  replacing one policy document with another.
- **endpoint classification**: accept/refuse decision for a secret-free
  URL endpoint, as a typed problem kind.
- **robot JSON**: `--robot` machine JSON output, including
  `DisplayedText.escapeJSONScalars` scalar escaping.

## 3. Requirements, Constraints & Guidelines

Global (all tickets):

- **CON-001**: Behavior-preserving. Existing tests pass unmodified
  except tests that pin the deleted shallow shape itself (door-spy,
  mirror-agreement, forwarding-copy tests); a ticket's requirements name
  which those are. Never edit a test to fit a changed behavior the
  ticket did not name.
- **CON-002**: TDD: add/repoint tests at the new seam first where the
  ticket creates one; keep golden fixtures byte-identical.
- **CON-003**: No new public seam with a single adapter unless the
  ticket names two existing adapters.
- **CON-004**: Verify with the project gate: build plus the ticket's
  test target(s) via `Scripts/gate.sh --filter <Target>Tests` (check
  `Scripts/gate.sh --help` on the branch) or `swift test --filter
  <Target>Tests`; report the exact command and result.
- **CON-005**: Exclusive writes (§5b) are a hard limit. If a needed
  file is outside the set, stop and report; do not widen silently.
  New files inside the ticket's listed target directories are allowed.
- **GUD-001**: Match surrounding style. No drive-by cleanup, no
  TODO/FIXME left behind.

Per-ticket requirements are in §5b (each ticket's acceptance) plus:

- **REQ-T1**: Wire bytes identical (golden fixtures). Unknown-op
  failure echo and body-cap-only-on-wire distinction preserved in the
  single decode path. Dead `runtimeKeys` and the drift-guard comment
  delete with the mirrors.
- **REQ-T2**: Per-verb failure semantics preserved: redirect-only is
  overwrite, `rm` is delete, `install -D` survives main-scan failure.
  tar/curl keep bespoke grammar only where it truly differs.
- **REQ-T3**: Construction order preserved (hook ceremony built in
  `init` before `self` is capturable) and rebuild-before-evaluate
  ordering preserved. `setPackEnabled` becomes the single mutation
  entry. No caller may observe a stale door after the change.
- **REQ-T4**: Preserve allow-vs-incomplete asymmetry (file allow stays
  allow; evaluated allow becomes incomplete deny), Claude rich deny
  only when a matched `RuleMatch` is present, Cursor ask agent text vs
  deny stop line.
- **REQ-T5**: CLI `evaluate()` keeps secret-exemption advisory;
  rollback keeps it blocking — one explicit parameter, not two copies.
  Finding detail keeps naming the strictest row.
- **REQ-T6**: Accept/refuse outcomes must not change except: audit
  forwarding gains the parsed loopback + non-canonical-spelling
  refusal MCP endpoints already enforce (named divergence fix).
  First-problem wording for multi-fault URLs may change; the sentence
  per adapter stays that adapter's.
- **REQ-T7**: Output bytes preserved per surface except surfaces that
  currently drop escaping gain it (named: `secrets describe --robot`,
  egress robot outputs, Blocks slash-escaping). Pretty vs compact per
  surface preserved. One failure policy, chosen as: encode failure is
  a thrown/command failure, never a swallowed `{}`/`[]` — unless an
  existing golden test pins the swallow for that surface, in which
  case keep it and name it in the PR.

## 4. Interfaces & Data Contracts

No new external wire formats. T1 keeps the control wire bytes; T4
keeps every host wire byte; T7 keeps robot bytes per REQ-T7. New
in-process interfaces (codec payload entry, dispatcher-owned union,
compile-set ready-door entry, deny presentation value, replacement
entry, endpoint classification, robot-JSON entry) are designed by the
implementer to the ticket acceptance, minimal in surface: prefer one
entry function over a protocol unless two adapters exist today.

## 5. Acceptance Criteria

- **AC-001**: Given the base tree, when each ticket lands alone, then
  its named test targets pass and `swift build` succeeds.
- **AC-002**: Given any wire/golden fixture named by a ticket, when
  the deepened module encodes/decodes it, then bytes are identical.
- **AC-003**: Given a deleted shallow shape, when searching the tree,
  then no caller references the deleted interface symbols.

## 5b. Tickets (task graph)

All tickets are independent (disjoint exclusive writes) and may run in
parallel. Branches: `arch/27dc7ddd/T<n>` off base `6413ac7f`. One PR
per ticket.

### T1 — One wire codec + per-op payloads for control frames

- depends-on: none
- exclusive-writes: `Sources/RVIsolation/WorkspaceControlProtocol.swift`,
  `Sources/RVIsolation/WorkspaceControlLaunchPayloads.swift`,
  `Sources/RVIsolation/WorkspaceHostClient.swift`,
  `Sources/RVIsolation/WorkspaceHostServer.swift`, new files under
  `Sources/RVIsolation/` prefixed `WorkspaceControl`, tests under
  `Tests/RVIsolationTests/` for control RPC/payloads
- acceptance:
  - `WorkspaceControlMessage` and both mirror wrappers
    (`WorkspaceControlRequest`/`Response` field bags) are deleted;
    Envelope decode validates once and yields a typed per-op payload
    for every op (launch family pattern extended); encode takes the
    same payload; unknown-op echo stays an explicit case.
  - Golden wire-byte fixtures and limit battery pass; mirror-agreement
    tests (`WorkspaceControlRPCTests` byte-identity/limit pairs)
    collapse to one-path tests; `RVIsolationTests` passes.
  - Client/server no longer assemble 31-field optional bags per op.
- review-hint: ≥1500 (WorkspaceHostClient 1542 / protocol 1464)

### T2 — Dispatcher owns writer strip + redirect union

- depends-on: none
- exclusive-writes: `Sources/RVEngine/ParseFilesystemCommand.swift`,
  `Sources/RVEngine/ParseFilesystemWriters.swift`,
  `Sources/RVEngine/ParseFilesystemMutations.swift`,
  `Sources/RVEngine/ParseFilesystemCreateRead.swift`, new files under
  `Sources/RVEngine/` for the shared fold, tests under
  `Tests/RVEngineTests/` for writers
- acceptance:
  - Redirect stripping before scan and redirect union after (success,
    help, failure) happen exactly once in the dispatcher; per-verb
    strip/union pairs and private duplications of that rule are gone;
    cat's third shape folds into the same rule or is named an
    exemption with a test.
  - Per-verb destination outcomes unchanged: existing writer tests
    pass unmodified in outcome; one parametrized matrix (verb ×
    help/fail/success × outside redirect) exists at the dispatcher
    seam; `RVEngineTests` passes.
  - REQ-T2 failure semantics pinned by tests (redirect-only
    overwrite, rm delete, install -D survival).
- review-hint: ≥1500 (ParseFilesystemWriters 1984)

### T3 — Live compile-set module owns gated-door freshness

- depends-on: none
- exclusive-writes: `Sources/RVService/ServiceRuntime.swift`,
  `Sources/RVService/ApprovalRuntime.swift`,
  `Sources/RVService/HookReviewCeremony.swift`,
  `Sources/RVService/LiveEvaluateWorld.swift`,
  `Sources/RVService/EvaluateWorld.swift`,
  `Sources/RVService/EvaluateSession.swift`, new files under
  `Sources/RVService/` for the compile-set module, tests under
  `Tests/RVServiceTests/`
- acceptance:
  - One module owns catalog/snapshots/compiled set/1s throttle/
    rebuild; callers request a ready door/world for a wanted set and
    cannot evaluate against a stale snapshot; hand-placed
    `rebuildWhenUncovered` choreography and gated peek closures are
    deleted from callers (the init-order lock box goes away or is
    internal to the new module).
  - explain/classify get the same coverage rule as evaluate, or the
    PR names why they must not with a pinning test.
  - Throttle/uncovered-rebuild/post-`setPackEnabled` visibility
    tested at the new seam; existing `RVServiceTests` (incl.
    EnabledCompile/PackEnableCompileGate) pass.
- review-hint: 101–1499

### T4 — Evaluated-deny dispatch into HookMapper

- depends-on: none
- exclusive-writes: `Sources/RVHooks/HostCodec.swift`,
  `Sources/RVHooks/HookMapper.swift`,
  `Sources/RVHooks/ClaudeHostCodec.swift`,
  `Sources/RVHooks/CursorHostCodec.swift`,
  `Sources/RVHooks/ClaudeRichDeny.swift`,
  `Sources/RVHooks/HookDispatch.swift`, every `*HostCodec.swift`
  adapter (amended 2026-11-04 after implementer STOP: migrating all
  adapters to the single deny entry is the ticket, non-overriders
  included), tests under `Tests/RVHooksTests/`, plus
  `Tests/RVCLITests/HookCommandTests.swift` (its
  `encodeEvaluatedDeny` caller must repoint so AC-003 holds)
- acceptance:
  - `encodeEvaluatedDeny`/`encodeEvaluatedAskDeny`/`encodeFileDeny`
    deleted from protocol, defaults, and overrides; `HostCodec`
    shrinks to decode + proposedAction + encodeAllow +
    encodeDeny(presentation) (exact deny spelling at implementer's
    design, one rendering entry; the presentation value carries
    composed reason, rule, next, optional matched `RuleMatch`, and
    ask-vs-user agent text so Claude rich and Cursor ask variance
    cross the seam as data — amended 2026-11-04); HookMapper
    composes the deny presentation once. Every adapter's wire output
    stays byte-identical (incl. Codex native block JSON, Muse
    permission-deny JSON).
  - Every host's wire output byte-identical across the existing
    parametric wire tables; door-spy tests deleted, wire assertions
    kept; `RVHooksTests` passes.
  - REQ-T4 asymmetries pinned by tests.
- review-hint: 101–1499

### T5 — Rollback replacement decision in PolicyDiffRisk

- depends-on: none
- exclusive-writes: `Sources/RVPolicy/PolicyDiffRisk.swift`,
  `Sources/RVPolicy/TypedRuleStore.swift`,
  `Sources/RVPolicy/PolicyDocumentTOML.swift` (rank dedup only),
  callers of `removedRuleFindings`/`evaluateShare` inside
  `Sources/RVPolicy/` and `Sources/RVCLI/` only if the interface
  change requires it (name them in the PR), tests under
  `Tests/RVPolicyTests/`
- acceptance:
  - `refuseRelaxingRollback(existing:incoming:)` assembly and
    `strictestRules` deleted from the store; one replacement entry
    on PolicyDiffRisk owns strictest dedup + share + removed +
    safety + exemption findings with an explicit severity parameter;
    `restrictionRank` defined once.
  - Dual-baseline orchestration (live + head) stays in the store.
  - Gate cases (duplicate allow-then-deny, exemption widening) pass
    as pure PolicyDiffRisk table tests; `RollbackRiskGateTests`
    passes unmodified in outcome; `RVPolicyTests` passes.
- review-hint: ≥1500 (TypedRuleStore 1580)

### T6 — One secret-free endpoint classification

- depends-on: none
- exclusive-writes: `Sources/RVMCP/MCPRedaction.swift`,
  `Sources/RVMCP/MCPConfiguration.swift`,
  `Sources/RVCLI/Commands/AuditForward.swift`, new files under
  `Sources/RVMCP/` for the classification, tests under
  `Tests/RVMCPTests/` and `Tests/RVCLITests/` (audit-forward and MCP
  endpoint tables only)
- acceptance:
  - One classification entry returns a typed problem kind
    (host/path/query/userinfo/fragment/credentials/non-canonical/
    scheme); `endpointProblem` and audit `destination` are thin
    adapters mapping kind → their existing sentences; duplicated
    7-predicate composition deleted from both.
  - MCPOAuth path through `endpointProblem` unchanged.
  - One spelling table at the classification seam covers both
    adapters (incl. loopback aliases, non-canonical spellings,
    percent-encoded host); named divergence fix (REQ-T6) covered by
    a test; `RVMCPTests` + relevant `RVCLITests` pass.
- review-hint: 101–1499 (MCPRedaction 1096)

### T7 — One robot-JSON module

- depends-on: none
- exclusive-writes: `Sources/RVCLI/Robot/RobotDocument.swift`,
  `Sources/RVCLI/Robot/ScanRobot.swift`, new files under
  `Sources/RVCLI/Robot/`, and only the robot-JSON helper call sites
  in `Sources/RVCLI/Commands/SecretsCommand.swift`,
  `ManagedCommand.swift`, `MCPCommand.swift`, `EgressCommand.swift`,
  `PolicyCommand.swift`, `BlocksCommand.swift`,
  `ReportCommand.swift`, `AuditCommand.swift`,
  `PolicyDraftCommand.swift`, tests under `Tests/RVCLITests/`
- acceptance:
  - One module owns encode + `escapeJSONScalars` + date/pretty
    options + failure policy (REQ-T7); per-command encoder recipes
    (`SecretsRun.json`/`robotJSON`, `ManagedRun.robotJSON`,
    `MCPRun.robotJSON` cross-module delegation, egress/policy/blocks
    copies) deleted or reduced to one-line calls.
  - Surfaces that dropped escaping gain it (REQ-T7 named list);
    all other surfaces byte-identical against existing golden robot
    tests; hostile-scalar (bidi/NEL/ESC) test exists once at the new
    seam; relevant `RVCLITests` pass.
  - No command's non-robot output changes.
- review-hint: 101–1499 (MCPCommand 1624 if touched beyond helper →
  re-measure at review)

### T8 — ActionPolicyEngine: one door, both worlds (added: user directed all items)

- depends-on: none
- exclusive-writes: `Sources/RVDomain/ActionPolicyEngine.swift`,
  `Sources/RVDomain/SemanticAnalysis.swift`,
  `Sources/RVDomain/FilesystemAction.swift`,
  `Sources/RVEngine/ApplyFilesystemSemantics.swift`, callers of the
  convenience overload (name each in PR), tests under
  `Tests/RVDomainTests/` + `Tests/RVEngineTests/`
- acceptance:
  - Convenience `evaluate(action:context:policy:)` that silently
    forces `gitWorld=.probed` deleted; single evaluate states
    `gitWorld` and new `filesystemWorld` explicitly. Every migrated
    caller states the world it effectively had before (bind/
    ReviewRequest keep `.probed`) — no outcome flips.
  - `catalogOrBoundaryDeny` ranking in Apply deleted; engine owns
    unprobed-filesystem ranking; existing outcome tables pass
    unmodified; probed/unprobed pairs pinned per world in
    `ActionPolicyEngineTests`.
- review-hint: 101–1499

### T9 — Legacy frames through LiveSeatbeltChild's own state

- depends-on: none
- exclusive-writes: `Sources/RVIsolation/SessionSupervisor.swift`,
  `Sources/RVIsolation/WorkspaceSessionSupervisor.swift`, tests
  under `Tests/RVIsolationTests/`
- acceptance:
  - `LiveSeatbeltChild` owns the finished flag beside its pending
    slot (set by the watch path, happens-after last drain); one
    `submitLegacy` decides pending-vs-direct atomically; supervisor
    branch on `watchFinished` deleted.
  - `drainPending` watch-thread-only execution and post-finish
    caller-thread behavior preserved; routing tests (before/during/
    after finish, racing finish) at the child seam;
    `RVIsolationTests` passes.
- review-hint: ≥1500 (both supervisors)

### T10 — Delete ScanRun forwarding copy

- depends-on: none
- exclusive-writes: `Sources/RVCLI/Commands/ScanCommand.swift`,
  tests under `Tests/RVCLITests/` (scan only). `Sources/RVScan/`
  read-only unless a `.fixture` convenience must move there (name it).
- acceptance:
  - `ScanRun.Request`/`Error`/`mapped()` deleted; caller and tests
    use `SessionScanRequest`/`SessionScanError` directly; `ScanRun`
    keeps only rendering + fail-on-findings exit code.
  - User-visible messages and exit codes unchanged; scan tests pass
    (repointed at the RVScan seam where they tested forwarding).
- review-hint: ≤100–1499 (re-measure)

### T11 — One spelling-preserving JSON parser in RVPolicy

- depends-on: none. T5 also touches RVPolicy but different files;
  serialize only if a shared file appears (stop and report).
- exclusive-writes: `Sources/RVPolicy/JSONLiteral.swift`,
  `Sources/RVMCP/JSONValue.swift`, `Sources/RVMCP/JSONValueBridge.swift`,
  new parser file under `Sources/RVPolicy/`, tests under
  `Tests/RVMCPTests/` + `Tests/RVPolicyTests/`
- acceptance:
  - One parser (ordered entries, typed errors, explicit lenient
    flag) in RVPolicy; RVMCP `JSONValue` keeps enum/writer, loses
    its parser; `JSONLiteral` loses parser + duplicate
    `domainValue()`. Both `JSONValue` enums remain.
  - `ManagedPolicy` stays strict + fail-closed on duplicate keys;
    host-config lenience unchanged; depth behavior pinned by table
    tests (any depth off-by-one change = abort and report, do not
    adjust fixtures to fit); malformed/depth/duplicate table at the
    parser seam; `RVMCPTests` + `RVPolicyTests` pass.
- review-hint: 101–1499

### T12 — Cancel-clock composition dedup (proven gain only)

- depends-on: none. T9 also touches `SessionSupervisor.swift` —
  T12's SessionSupervisor call sites are the cancel compositions
  only; if hunks collide at merge time, parent serializes merges.
- exclusive-writes: `Sources/RVIsolation/WorkspaceDiskHelperProcess.swift`,
  `Sources/RVIsolation/WorkspaceDiskTeardown.swift`,
  `Sources/RVIsolation/DiskImageClockedSyscalls.swift`,
  cancel-composition call sites in
  `Sources/RVIsolation/SessionSupervisor.swift`, tests under
  `Tests/RVIsolationTests/` (DiskImageCancellation)
- acceptance:
  - The triple fallback chain and note/spent/adopt compositions
    collapse behind the existing clock owner's interface (no new
    public module with one adapter); pure `DiskImageCancelBudget`
    math and its tests untouched.
  - 8s return bound and first-arm-wins semantics unchanged, pinned
    by existing tests passing unmodified. If the interface does not
    shrink, abort the ticket and report instead of shipping a facade.
- review-hint: 101–1499

### Conditional tickets (pending user risk decisions — do not start)

- **T13 Chain semantics in analysis** (C8): fingerprint/replay +
  wire-shape + pend→deny tightening decision required.
- **T14 MCP review line grammar** : leaked-URL policy (suffix vs
  refuse) decision required.
- **T15 Retained-review lifecycle module**: generic-lifecycle over
  three differing authorities; risk acceptance required.

## 6. Test Automation Strategy

- **Test levels**: unit at each new seam + existing integration suites
  unmodified in outcome.
- **Frameworks**: Swift Testing (existing targets).
- **Per ticket**: `swift build` + ticket test target(s) via
  `Scripts/gate.sh --filter …` or `swift test --filter …`; full
  unfiltered `swift test` remains the CI gate (`.github/workflows/pr.yml`).
- **Golden data**: existing fixtures are the oracle; do not regenerate
  a fixture to match new output except REQ-T6/T7 named divergences,
  each called out in its PR.

## 7. Rationale & Context

Deletion test per ticket: deleting the shallow shape concentrates the
decision (one decode, one union, one freshness rule, one dispatch,
one finding set, one classification, one encoder) instead of moving
it to callers. Each surviving candidate passed an adversarial filter
that killed four sibling candidates on exactly that test. Depth here
is leverage at the interface, not line-count ratio: the win is that
callers and tests cross one seam.

## 8. Dependencies & External Integrations

- **PLT-001**: Swift 6.4 toolchain (`Scripts/swift-6.4`), macOS 15
  floor, Linux CI graph unchanged.
- No external systems, services, or data dependencies. No new package
  dependencies.

## 9. Examples & Edge Cases

- T1: unknown op arrives → failure echo with raw op preserved; body
  over cap rejected on wire decode only, not in-process encode.
- T2: `cp --help > /outside` → redirect destination still unioned;
  `install -D` with failing main scan → destinations survive.
- T3: pack enabled, next evaluate within throttle window → ready door
  includes it or rebuild rule states exactly when it does.
- T4: evaluated result with decision allow → incomplete deny;
  file result allow → allow. Claude with no matched rule → plain deny.
- T5: duplicate predicate rows allow-then-deny → strictest row named
  in finding detail; CLI validate stays advisory on exemption.
- T6: `http://127.000.0.1/` and other loopback aliases → refused as
  non-canonical at both adapters after the change.
- T7: value containing U+202E / U+0085 / ESC → escaped on every robot
  surface, including `secrets describe` and egress.

## 10. Validation Criteria

Per ticket: build green, named test targets green, AC-002/AC-003
checks shown in PR, fresh-context review + final pass clean
(pipeline steps 6–7, review skill routed by largest changed Swift
file). Spec is satisfied when T1–T7 each have a PR meeting their
acceptance or an explicit blocked reason recorded against this spec.

## 11. Related Specifications / Further Reading

- `spec/spec-architecture-redirect-writer-merge.md` (landed; T2 is the
  remaining strip/union half, not a relitigation)
- `spec/spec-architecture-spawn-fd-hygiene.md` (landed)
- `spec/spec-architecture-type-system-enums.md` (landed)
- `CONTEXT.md` (domain glossary; Secret release / Lease terms used by
  T6's neighboring code)
