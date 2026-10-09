# rv.ipc.v1 wire contract

Normative contract for out-of-process clients of `rvd` (notably the Python SDK).
Swift `Codable` in `Sources/RVIPC/` and `Sources/RVDomain/` is canonical: where this
document and the Swift bodies disagree, Swift wins and this document must be fixed
in the same change. Every section cites its source of truth.

Protocol identity: `Sources/RVIPC/ProtocolVersion.swift`
(`name = "rv.ipc.v1"`, `serviceSemver = "1.0.0"`).

## 0. Authority and scope

- This contract covers the `rvd` service boundary only: handshake, the 12 methods in
  `Sources/RVIPC/IPCMethods.swift`, framing, versioning, errors, transports.
- It does NOT cover `rv.workspace.v1` (`Sources/RVIsolation/WorkspaceControlProtocol.swift`),
  a separate macOS-only terminal-attach plane with its own versioning and auth.
- SDKs implement exactly this contract. Anything not specified here is not on the wire:
  do not send it, do not depend on receiving it.

## 1. Transports

### 1.1 Linux: AF_UNIX pathname socket

- Path: `$XDG_RUNTIME_DIR/rv/evaluate.sock` (`Sources/RVService/UnixSocketPath.swift`).
- Resolution (`UnixSocketPath.resolve`): trim ASCII whitespace/newlines; unset or empty
  after trim fails closed (`runtimeDirectoryMissing`) — there is **no `/tmp` fallback**.
- Length: `utf8.count + 1 <= 108` or `pathTooLong` (room for NUL in `sockaddr_un`).
- Modes: the `rv` dir `0700` (create, chmod, verify), socket `0600`
  (chmod, verify). The base dir is created `0700` when missing; a pre-existing
  base is never chmodded — it only has to exist owned by this uid and not
  group/world-writable. A stale socket/symlink at the path is unlinked;
  anything else fails closed. A client must **check** these modes and refuse
  to connect on mismatch; it must never repair permissions itself.
- Server I/O: `Sources/RVService/UnixFrameTransport.swift` (`UnixEvaluateListener`,
  `UnixFrameIO`, `UnixReplyGate`). `SOCK_STREAM` + `SOCK_CLOEXEC`, `MSG_NOSIGNAL`,
  `EINTR`-retrying exact reads, one `ServiceRuntime` dispatch per frame.

### 1.2 macOS: AF_UNIX pathname socket (SDK path)

- Path: `$HOME/.config/rv/evaluate.sock`, resolved from a live `getenv("HOME")`
  (never a cached snapshot). Unset or empty `HOME` fails closed
  (`runtimeDirectoryMissing`). `$HOME/.config/rv` is RV's config home
  (`Sources/RVPolicy/HomeDirectory.swift`); it is deterministic under launchd agents
  and login shells alike, unlike per-session `TMPDIR`.
- Length: `utf8.count + 1 <= 104` (Darwin `sockaddr_un`) or `pathTooLong`, mirroring
  `WorkspaceControlSocket.maxPathBytes = 103` (`Sources/RVIsolation/WorkspaceControlTransport.swift`).
- Modes: same discipline as Linux: the `rv` dir `0700` (create, chmod,
  verify), socket `0600` (chmod, verify); a pre-existing `$HOME/.config` keeps
  its mode and only has to exist owned by this uid and not
  group/world-writable.
- Server I/O: `Sources/RVService/UnixSocketListener.swift` (Darwin). Same
  `ServiceRuntime.handleIncoming` seam as XPC and the Linux listener; `FD_CLOEXEC`
  + `SO_NOSIGPIPE`; `EINTR`-retrying exact reads.
- The listener enforces same-UID peers via `getpeereid` and drops anything else.
  (The pre-existing Linux listener does not peer-check; filesystem modes are its
  boundary. That asymmetry is intentional in v1 and tracked as hardening work.)

### 1.3 macOS: XPC Mach service (Swift/C only)

- Service `dev.rv.evaluate` (`RVService.machServiceName`), `xpc_data` under key
  `rv.ipc`, optional stdin-overlay bytes under `rv.stdin`
  (`Sources/RVService/XPCListener.swift`). This is the hook hot path for the C front
  door and `ServiceClient`. Non-Swift SDKs never speak XPC; the same methods are
  available over §1.2 with identical JSON bodies.
- There is no TCP listener, no HTTP server, no TLS, and no bearer/token auth
  anywhere in `rvd`. Local security is socket modes + same-UID + handshake + skew
  checks. Do not add network transports to reach this contract.

## 2. Framing

`Sources/RVIPC/FrameCodec.swift`. Every message on a socket connection is one frame:

```text
+--------+-------- ... --------+
| len BE |   JSON body        |
| 4 bytes|   len bytes        |
+--------+-------- ... --------+
```

- `len` is the body length as an unsigned 32-bit big-endian integer.
- `maxBodyBytes = 1_048_576`. Encode rejects larger bodies (`oversized`).
- Decode a complete frame (`decode(_:)`): header short → `truncated`; declared
  length over cap → `oversized`; fewer bytes than declared → `truncated`; more
  bytes than declared → `lengthMismatch`; declared length zero → `empty`.
- Split decode (`bodyCount(fromHeader:)` then `decode(header:body:)`): short
  header → `truncated`; over cap → `oversized`; header not exactly 4 bytes →
  `lengthMismatch`; zero length → `empty`. Body short → `truncated`; body
  long → `lengthMismatch`.
- Error order is normative: **truncated → oversized → lengthMismatch → empty**
  (header stage), then truncated → lengthMismatch (body stage).
- Note the deliberate asymmetry: encoding an empty body is allowed, decoding one
  is `empty`. EOF mid-frame is a transport error (`eof`), not a frame error.
- Bodies are UTF-8 JSON objects with sorted keys (`Sources/RVIPC/IPCJSON.swift`:
  sorted-keys encoder, stock decoder). Key order is cosmetic: parsers must not
  depend on it, but byte goldens use sorted order.

## 3. Envelope

`Sources/RVIPC/IPCEnvelope.swift`, `Sources/RVIPC/SkewReason.swift`.

### 3.1 Hello / HelloAck

Client opens every connection with exactly one `Hello`:

```json
{"clientSemver": "1.0.0", "protocol": "rv.ipc.v1"}
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `protocol` | string | yes | Must equal `rv.ipc.v1`. |
| `clientSemver` | string | yes | The IPC major the client implements (NOT the SDK release version). Must be nonempty. |

Service replies with exactly one `HelloAck`:

```json
{"ok": true, "protocol": "rv.ipc.v1", "serviceSemver": "1.0.0"}
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `protocol` | string | yes | Echo of the protocol name. |
| `serviceSemver` | string | yes | Service IPC semver. Major-gated by the client. |
| `ok` | bool | yes | Handshake verdict. |
| `skewReason` | string | iff `ok` is false | One of §3.2. Present-with-`ok:true` or absent-with-`ok:false` is a decode error. |

`ServiceRuntime.acknowledge` checks, in order: protocol-name match → major skew →
core-packs readiness. First failure wins.

### 3.2 Skew reason strings (wire-stable)

`HelloSkewReason`: `"protocol"`, `"major version"`, `"core packs unavailable"`.
`SkewReason` (method-frame errors, `IPCError.protocolSkew`): the same three plus
`"handshake required"`. Changing a string breaks shipped clients.

### 3.3 Request / response

```json
{"id": "E621E1F8-C36C-495A-93FC-0C247A3E6E5F", "method": {"listPacks": {}}, "protocol": "rv.ipc.v1"}
{"id": "E621E1F8-C36C-495A-93FC-0C247A3E6E5F", "protocol": "rv.ipc.v1", "result": {"listPacks": {...}}}
```

- `IPCRequest`: `id` (UUID, fresh per call, client-generated), `protocol`, `method`
  (single-key object; key = method name; §4).
- `IPCResponse`: `id`, `protocol`, `result` (single-key object; key = method name
  or `error`).
- Clients must verify `response.id == request.id` and `response.protocol ==
  "rv.ipc.v1"` on every call (mirror of `ServiceClient.send`,
  `Sources/RVCLI/Service/ServiceClient.swift:191-215`), and must major-gate every
  `serviceSemver` a reply carries (mirror of the per-frame guard,
  `Sources/RVService/ServiceRuntime.swift:368-380`).
- UUIDs are RFC 4122 strings. Swift emits uppercase; parsers must accept any case
  and compare as UUID values, not strings.
- Methods without parameters encode the value as `{}` (`EmptyPayload`).

### 3.4 Implicit hello and handshake state

- `evaluate` and `hookEvaluate` accept an additive `clientSemver` param. On a
  connection with no accepted handshake, a nonempty value synthesizes a hello
  (`ServiceRuntime.handleUnreadyIncoming`): ack-ok dispatches the call and accepts
  the handshake; skew returns `protocolSkew` with the call's id and leaves the
  connection unready.
- All other methods before a handshake return `protocolSkew("handshake required")`
  (with the request id when the body decoded, else a fresh id).
- `ServiceRuntime` re-checks major skew per frame on `evaluate`/`hookEvaluate`
  even after a hello, so a skewed semver can never ride an open handshake.
  Absent or empty semver stays legacy-compatible (no check).
- SDKs must always send an explicit `Hello` first and must fail closed on any
  missing or unparseable version. There is no legacy path in a non-Swift client.

## 4. Methods

`Sources/RVIPC/IPCMethods.swift`. All 12 operations are unary request/response.
`cwd`/`host`/`session` inputs are untrusted metadata: they route and label, they
never confer authority (§7 of `sdk/README.md`, identity model).

| # | Method | Params | Reply | Notes |
|---|---|---|---|---|
| 1 | `evaluate` | `EvaluateParams` | `EvaluateReply` | Implicit-hello eligible. |
| 2 | `hookEvaluate` | `HookEvaluateParams` | `HookEvaluateReply` | Implicit-hello eligible. Non-Swift SDKs: raw-only; host adapters stay Swift/C. |
| 3 | `explain` | `ExplainParams` | `ExplainReply` | Requires prior Hello. |
| 4 | `classify` | `ClassifyParams` | `ClassifyReply` | Requires prior Hello. |
| 5 | `listPacks` | `{}` | `ListPacksReply` | Read-only; refreshes catalog from disk. |
| 6 | `setPackEnabled` | `SetPackEnabledParams` | `SetPackEnabledReply` | **Operator-only**: mutates config + rebuilds compile set. |
| 7 | `doctorSnapshot` | `{}` | `DoctorSnapshotReply` | Health + versions. No separate version RPC exists. |
| 8 | `pendingList` | `{}` | `PendingListReply` | Read-only projection + generation. |
| 9 | `pendingWatch` | `PendingWatchParams` | `PendingWatchReply` | **Unary poll**, not a stream: unchanged generation returns `{same generation, items: []}`. |
| 10 | `pendingResolve` | `PendingResolveParams` | `PendingResolveReply` | **Human-attended only.** Fingerprint+identity echo enforced. |
| 11 | `rulePreview` | `RulePreviewParams` | `RulePreviewReply` | Never writes. |
| 12 | `ruleSave` | `RuleSaveParams` | `RuleSaveReply` | **Operator-only.** Draft must echo the preview. |

### 4.1 Evaluate family

`Sources/RVIPC/IPCEvaluate.swift`, `IPCExplain.swift`, `IPCClassify.swift`.

- `EvaluateParams`: `request` (required), `cwd` (optional string; empty string
  decodes to absent, never an error), `clientSemver` (optional, additive).
- `EvaluateReply`: `result` (required), `via` (required, must be exactly `"xpc"` —
  frozen wire string on every transport; `"inProcess"` or anything else is a
  decode error), `serviceSemver` (optional; absent proves nothing — clients
  without an engine must reject, see `sdk/VERSIONING.md`).
- `ExplainParams` / `ClassifyParams`: `request` + optional `cwd`, same rules.
- `ExplainReply`: `result`, `normalized`, `ruleID?`, `packID?`, `suggestion?`,
  `stages[]`. Decoders **derive** `ruleID`/`packID` from `result.outcome` and
  ignore the siblings; encoders emit them.
- `ClassifyReply`: `decision`, `risk`, `ruleID?`, `packID?`, `reasons[]`
  (default `[]`), `suggestions[]` (default `[]`). Decode adopts sibling ids only
  for `allow` (`packID` must equal `ruleID.pack` or the frame is corrupt);
  `deny` takes ids from the deny payload; `indeterminate` clears both.
- `ExplainStage`: `name` ∈ `normalize|quick-reject|safe|destructive|default`
  (closed; unknown is a decode error), `elapsedMs` number (`0` encodes as `0`).
- `ClassifyRisk`: single string, `"safe"` or a `Severity` (`§5.4`); anything else
  is a decode error.

### 4.2 Packs

`Sources/RVIPC/IPCPacks.swift`. `PackRecord{id, enabled, bundled}`;
`ListPacksReply{packs[], enabledCount, totalCount}`;
`SetPackEnabledParams{id, enabled}` → `SetPackEnabledReply{pack}` or
`packNotFound(PackID)` / `packEnableFailed`.

### 4.3 Doctor

`Sources/RVIPC/IPCDoctor.swift`. `DoctorSnapshotReply{protocol, serviceSemver,
label, state, keepAlive, idleExitSeconds, packsEnabled[], lastError?, checks[]}`.
`state` ∈ `running|idleExitArmed|down|skew` (closed). `DoctorCheck{id, status,
message}`: `status` ∈ `ok|warning|error|skipped` (closed); `id` is an open
extension point — decoders must tolerate unknown check ids (preserve raw,
degrade gracefully), because new checks are additive.

### 4.4 Pending and rules

`Sources/RVIPC/IPCPending.swift`, `Sources/RVIPC/IPCRules.swift`.

- `PendingListReply{generation: uint64, items[]}`; `PendingWatchReply` is the same
  shape. `PendingListItem{id, host, folder, actionKind, fingerprint,
  sessionSuffix?, identity}` — a read-only projection, never the full
  `ProposedAction`.
- `PendingWatchParams{afterGeneration: uint64}`.
- `PendingResolveParams{id, decision: "allowOnce"|"deny" (closed), fingerprint,
  identity}` → `PendingResolveReply{id, terminal: bool}`. The service binds
  id+fingerprint+identity at the ledger and resolves terminal-once; `allowOnce`
  plants a grant then consumes it exactly once.
- `RulePreviewParams{id, polarity: "allow"|"block" (closed)}` →
  `RulePreviewReply{sentence, draft, allowedToSave}` (allow + hard-stop ⇒
  `allowedToSave: false`).
- `RuleSaveParams{id, polarity, draft}` → `RuleSaveReply{ruleID, waitResolved}`.
  Draft must byte-echo the preview or `ruleDraftMismatch`; allow-side hard-stop
  is `ruleHardStop`; deny-polarity resolves the wait as deny.

### 4.5 Hook evaluate (raw-only for non-Swift SDKs)

`Sources/RVIPC/IPCHookEvaluate.swift`. `HookEvaluateParams{host (closed
`HookHost`), stdin (default `""`), clientSemver?}` →
`HookEvaluateReply{stdout, exitCode: int32, stderr (omitted when empty), via:
"xpc", serviceSemver?}`. Non-UTF-8 stdin-overlay bytes are `decodeFailed`.

## 5. Domain value shapes

Sources in `Sources/RVDomain/`. SDK decoders must implement the strictness below;
encoders must emit only valid values.

### 5.1 EvaluationRequest

`EvaluationRequest.swift`: `{command: string, enabledPacks: [PackID], budget?:
{maxPatternAttempts: int}}`. Day-one walk set is exactly
`["core.filesystem", "core.git", "system.disk"]` (`RVDomain.swift`), in order.
`ShellCommand` is an unconstrained string newtype; `WorkingDirectory` is a
nonempty string (`""` is unrepresentable — decoders reject it, except the
`cwd` param slot which maps `""` to absent per §4.1).

### 5.2 EvaluationResult and the outcome algebra

`EvaluationResult.swift`. Wire keys: `decision` (required), `matched?`,
`matchedSafe?`, `quickRejected?` (default `false`), `matchingView?` (default
`""`), `analysis?` (default unknown / omitted). `boundReview` is **never** on
the wire. Decoders must run the `composing` algebra exactly and reject
impossible combinations (the Swift side throws `EvaluationResultDecodingError`):

| decision | matched | matchedSafe | quickRejected | outcome |
|---|---|---|---|---|
| allow | — | — | true | `quickRejected` |
| allow | yes | any | false | `hit(match, safe)` |
| allow | no | yes | false | `safeOnly(safe)` |
| allow | no | no | false | `plain` |
| deny | any | no | false | `deny(deny, matched)` |
| indeterminate | no | no | false | `indeterminate(reason)` |
| anything else | | | | **reject the frame** |

- `RuleMatch{ruleID, packID, patternName, severity, reason, explanation?, regex?,
  span?, matchedText?, searchText?}`. Encoders emit the `packID`/`patternName`
  echo fields; decoders verify them against `ruleID` when present
  (`packID == ruleID.pack`, `patternName == ruleID.pattern`) and reject on
  mismatch. `MatchSpan{start, end}` ints.
- `SafeMatch{packID, patternName}`. `MatchingView` is a string newtype
  (T1-normalized command text, distinct from the raw command).
- `analysis` is present only when the analyzer produced a non-unknown analysis,
  and is omitted otherwise (verified: `PendingActionTests` asserts the key
  absent). Its object shape is Swift-synthesized with a single case key; observed
  encodings: `{"git":{"_0":{...}}}`, `{"filesystem":{"_0":{...}}}`,
  `{"wrapper":{"_0":"bash","inner":{...}}}`, `{"unwrapLimited":{}}`,
  `{"unknown":{}}`. SDKs must preserve the value opaquely, key behavior off the
  case key only, and must not depend on inner shapes beyond what golden vectors
  pin.
- `Decision` (`Decision.swift`, `Coding.swift`): `{"decision":"allow"}` |
  `{"decision":"deny","ruleID":...,"reason":...}` |
  `{"decision":"indeterminate","indeterminateReason":"budgetExhausted|commandTooLarge|corePacksUnavailable"}`.
  `Decision` is never Ask: a leftover `"ask"` kind decodes to
  `deny{ruleID: "builtin.action:leftover-ask", reason: "Ask is not a permit."}`.
  Any other kind is a decode error.

### 5.3 Identifiers

- `RuleID`: single string `"pack:pattern"`, split on the FIRST colon; both parts
  nonempty; pack validated by the PackID grammar (`RuleID.swift`, `Coding.swift`).
  Patterns may contain further colons. `rawValue` is colon form (`core.git:reset-hard`).
- `PackID`: single string, grammar `^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)?$` — at most
  ONE dot, lowercase ASCII leading each segment (`PackID.isValid`). `"a.b.c"`,
  `"Core.git"`, `".git"`, `"core."`, `""` are all invalid. Decoders reject.
- `ApprovalID`, `ActionFingerprint`: opaque strings (round-trip; never construct
  authority from them). Fingerprint spellings (`ProposedAction.swift`): shell
  `"<host>:<session>:<cwd>:<command>"`, file `"file:<host>:<session>:<cwd>:<kind>:<path>"`;
  nil session/cwd occupy empty slots. Empty slots never collide with populated ones.
- `ApprovalIdentity{session: SessionID, agent: HookHost}`. `SessionID` is a
  nonempty string (`""` rejected) and is self-declared, never a credential.
- UUIDs: §3.3 (emit uppercase for byte parity, accept any case).

### 5.4 Closed string enums (unknown values are decode errors unless noted)

- `Severity`: `low|medium|high|critical`.
- `HookHost`: `grok|pi|opencode|claude|openclaw|hermes|codex|cursor|antigravity`.
- `PendingResolveDecision`: `allowOnce|deny`. `RulePolarity`: `allow|block`.
- `ServiceState`: `running|idleExitArmed|down|skew`. `DoctorCheckStatus`:
  `ok|warning|error|skipped`. `IndeterminateReason`:
  `budgetExhausted|commandTooLarge|corePacksUnavailable`.
- `EvaluationPath` (`via`): `"xpc"` only on replies; anything else corrupts.
- `DoctorCheckID` is the deliberate exception: open for additive checks; decoders
  stay lenient (§4.3).

### 5.5 Numbers and the absence of dates

- `exitCode` is int32; `generation`/`afterGeneration` are uint64;
  `idleExitSeconds`/counts are ints; `elapsedMs` is a JSON number.
- **No `Date` values cross `rv.ipc.v1`.** (The pending ledger has dates; the IPC
  projection does not.) SDKs need no date codec for this contract.

## 6. Timeouts and budgets

- One-shot evaluate budget: 700 ms total = 200 ms connect + 500 ms request
  (`ServiceTransport.oneShotEvaluateTimeoutMs`, `XPCServiceTransport` defaults in
  `Sources/RVCLI/Service/XPCClient.swift`). Hello uses the 200 ms connect budget.
- Unix-socket SDKs mirror this: 200 ms connect, 700 ms default per-call budget,
  both configurable. Timeouts are transport errors, never verdicts.
- Idle exit: `rvd` exits after 300 s without a ping (`IdleWatchdog.defaultSeconds`,
  `Sources/RVService/IdleExit.swift`); launchd/systemd supervise on demand.
  Short RPCs compose with this; clients hold no persistent connections.
- `rvd --version` prints the product semver line (`Sources/rvd/main.swift`,
  `RVDLaunch.versionLine`) and is the product-version probe.

## 7. Errors

`IPCError` (`Sources/RVIPC/IPCEnvelope.swift:134-278`) is a closed, wire-stable
enum. Wire JSON → meaning (decode order is normative: `unknownMethod`,
`decodeFailed`, `protocolSkew`, `engine`, `packNotFound`, `allowOnce*`,
`pending*`, `rule*`; anything else is `decodeFailed`):

| Wire JSON | Meaning | Retriable |
|---|---|---|
| `{"unknownMethod":true}` | No such method key. | No — version/capability issue. |
| `{"decodeFailed":true}` | Body is not a valid request, or an unknown result shape. | No. |
| `{"protocolSkew":"<§3.2>"}` | Version/handshake refusal. | No — fix versions, re-handshake. |
| `{"engine":"hook evaluate failed"}` | Hook door failed. | No. |
| `{"engine":"pack enable failed"}` | Pack mutation failed. | Operator action. |
| `{"engine":"rule pin requires a matching view"}` | Preview needs the matching view. | No. |
| `{"engine":"pending allowOnce is not unlockable"}` | No supporting command / grant-plant failure. | No. |
| `{"engine":"pending coordinator unavailable"}` | No store / lock / encode failure. | Operator action. |
| `{"engine":"<other>"}` | Leftover unknown engine sentence; preserved opaquely. | No. |
| `{"packNotFound":"<pack>"}` | Unknown pack id (carries the id). | No. |
| `{"allowOnceNotFound":true}` | No such grant. | No. |
| `{"allowOnceAlreadyConsumed":true}` | Grant spent. | No. |
| `{"allowOnceExpired":true}` | Grant expired. | No. |
| `{"pendingNotFound":true}` | No such approval. | No. |
| `{"pendingAlreadyTerminal":true}` | Resolved/consumed/expired/canceled/timed out. | No. |
| `{"pendingIdentityMismatch":true}` | Identity echo mismatch. | No — caller bug or attack. |
| `{"pendingFingerprintMismatch":true}` | Fingerprint echo mismatch. | No — caller bug or attack. |
| `{"ruleDraftMismatch":true}` | Draft does not echo the preview. | No — re-preview. |
| `{"ruleHardStop":true}` | Allow-side hard stop (secret/protected/shared-branch/…). | No. |

Result-level `protocolSkew` and handshake `HelloAck{ok:false}` both mean
"negotiate versions, do not retry the call". Transport errors (connect refused,
timeout, EOF, frame errors, mode/length violations) are client-local and disjoint
from `IPCError`. Error precedence on ambiguous input: transport → frame →
handshake/skew → decode → method semantics.

## 8. Golden vectors and conformance

- `Tests/RVIPCTests/SDKVectorTests.swift` pins byte-exact goldens for the
  handshake (Hello, HelloAck ok + 3 skews), one `IPCRequest` per method, one
  `IPCResponse` per result variant, and the error table. Any change to these
  bytes is a wire change and requires a version decision per `sdk/VERSIONING.md`.
  Existing coverage it builds on: `IPCErrorGoldenFrameTests` (all error bytes),
  `EnvelopeRoundTripTests` (`IPCMethod.allSamples` / `IPCResult.allSamples`
  round-trips), `HookEvaluateRoundTripTests`, `FrameCodecTests`.
- SDK test suites embed the same bytes and assert decode + semantic mapping.
  Regeneration procedure (mechanical step; pasting is the review): add a temporary
  test that `IPCJSON.encode`s the `allSamples` values and the handshake/error
  fixtures with `IPCJSON.encoder()` (sorted keys), run
  `swift test --filter <name>`, verify every line against the Codable sources
  cited above, then paste. Never paste unverified output.
- New-SDK conformance checklist: connect + Hello + skew matrix; id/protocol echo
  on every call; per-reply `serviceSemver` major gate; all 12 methods against a
  live `rvd`; all `IPCError` cases mapped 1:1; unknown `DoctorCheckID` tolerated;
  impossible `EvaluationResult` combos rejected; 1 MiB + frame-error order;
  socket mode checks; no permission repair; `pendingResolve`/`ruleSave` gated
  human-attended/operator-only in curated APIs.

## 9. Forward-compatibility rules for decoders

- Ignore unknown JSON object keys everywhere.
- Preserve unknown `engine` sentences and unknown `DoctorCheckID`s opaquely.
- Reject (fail closed): unknown closed-enum values (§5.4), `via != "xpc"`,
  `ok`/`skewReason` combo violations, `RuleMatch` echo mismatch, impossible
  `EvaluationResult` combos, `ClassifyReply` pack mismatch, id/protocol echo
  mismatch, missing/unparseable versions, over-cap frames.
