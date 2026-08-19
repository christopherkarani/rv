# Phase 1c — Service (T3)

Implement ticket. Outcome: `rvd` + `rv.ipc.v1` + fail-closed fallback + `rv service status`.
Gate: **L1 + fake XPC**.

Parity source: DCG **0.11.0** for evaluate / explain / classify *meanings* (decision + `rule_id`, default-allow unknown commands). Not line-for-line Rust. Not a DCG daemon. DCG has no XPC; this ticket invents the Mac transport.

Repo: `~/CodingProjects/rv`. Never implement inside ryk. Do not edit ryk.

Source of truth: `docs/factory/PLAN.md`. This spec is the T3 implement prompt.

## Goal

Ship a warm, on-demand evaluate service so a later hook (T4) can be fast without being wrong when the service is missing.

1. **`rv.ipc.v1`** — versioned Codable contract with exactly these product methods: `evaluate`, `explain`, `classify`, `listPacks`, `setPackEnabled`, `allowOnce.consume`, `doctorSnapshot`. App-ready. No Mac app in this ticket.
2. **`rvd`** — XPC listener, warm pack registry, LaunchAgent `dev.rv.evaluate`. On-demand. Idle-exit ~5 minutes. **Not KeepAlive** by default. Not a system daemon.
3. **Thin client + fallback** — `RVCLI` talks XPC when the handshake matches; on **down** or **version skew** it evaluates **in-process**. It never allows because XPC missed.
4. **`rv service status`** — robot/plain status of the service (running / down / skew, protocol, label, last fallback). Not a pretty TUI.

Day-one win this ticket unlocks: the hook child can be a thin XPC client against a warm `rvd`. Correctness still holds if `rvd` is dead or skewed.

## Non-goals

- Pretty deny / explain / packs panels, TUI `reduce`/`render`, snapshot fixtures. **T2 owns those.**
- Host codecs, `rv hook`, Grok / Pi / OpenCode fixtures. **T4 / T5.**
- `install.sh`, live LaunchAgent install into the operator’s HOME, `rv setup` / `uninstall`. **T6.** T3 ships the plist *template* and the `rvd` binary.
- Full `rv doctor` UX (host wiring, fix-it). **T7.** T3 only returns `doctorSnapshot` data and `rv service status`.
- TTY `rv allow-once <code>` minting, host Allow button, leftover-ask-as-permit. **T8** mints; T3 only implements `allowOnce.consume` over IPC.
- Remaining pack catalog import / `rv packs` browse. **T9.**
- Mac app, SwiftUI, Intel, older macOS, Linux/Windows, scan, MCP, SARIF, history-on, KeepAlive daemon.
- `RV_BYPASS` or any env the hook child honors to skip evaluate.
- Evaluating *against* a skewed `rvd` (must drop the connection and go in-process).
- Unix-socket production transport.
- Implementing this product inside ryk. Installing or rebinding ryk.

## Depends on

| Ticket | Why T3 needs it |
|---|---|
| **T0** | `Package.swift` twelve-library graph, empty `RVIPC` / `RVService` / `RVCLI` targets, `swift test` green. Serial. T0 did **not** declare executable `rvd` — T3 adds it (PLAN locked resolution 4). |
| **T1** | Domain types + `evaluate` + `core.git` / `core.filesystem` + SKILL.md corpus. T3 does not reimplement the engine. |

Do not start T3 product code before T1 corpus is green. After T1, T3 may run in a worktree **in parallel with T2**.

T3 consumes, does not redefine:

- `Decision`, `PackID`, `RuleID`, `ShellCommand`, `EvaluationRequest`, `EvaluationResult`
- `PatternEngine` + `evaluate` (normalize → quick-reject → safe → destructive → default allow)
- Pack registry enable/disable (RVPacks / RVPolicy)

IPC payloads **map 1:1** onto those types. Do not invent a second `Decision` or a boolean `isDenied`.

## Parallel / worktree

After T1: **T2 and T3 may run in parallel** in **separate git worktrees** from the **same base SHA**.

| | T2 | T3 |
|---|---|---|
| Branch | `feat/t2-ux` | `feat/t3-service` |
| Owns | RVPresentation, RVTheme, RVTUI, CLI pretty (`rv test` / `explain`), deny snapshots | RVIPC, RVService, `rvd`, launchd template, thin XPC client, in-process fallback, `rv service status` |
| Must not | Edit RVIPC / RVService / `rvd` / launchd / fallback | Own pretty TUI snapshots, edit TUI renderers, inject ANSI into IPC |

They must not share a working tree.

**`Package.swift` merge plan (exclusive lines — do not both edit the same keys).**

- **T2 only:** `apple/swift-argument-parser` `from: "1.7.0"`, executable product `rv`, `Sources/RVCLI/main.swift`.
- **T3 only:** executable target `rvd` (`Sources/rvd`, depends on `RVService`) and executable product `rvd`. T0 did **not** declare `rvd`.
- T3 must **not** add ArgumentParser, product `rv`, or `@main` on `RVCLI`.
- T0 already declared library `RVIPC` / `RVService` / `RVCLI`. Fill sources; do not reshape unrelated targets.
- Conflict rule: T3 touches only the `rvd` product/target lines; T2 touches only ArgumentParser + `rv`.

**`RVCLI` file partition** (both tickets touch this target):

- T3 may create `Sources/RVCLI/Service/**` (client, fallback, `ServiceStatusReport`).
- T2 may create test/explain/output-mode/pretty command files, `RootCommand.swift`, and `main.swift`.
- Neither ticket edits the other’s new files. T3 must **not** create `RootCommand.swift` or `main.swift`. Export `ServiceStatusReport` (robot/plain fields). T2 wraps it as `service` after merge. T3 proves status in-process; process `rv service status` waits for T2’s `rv` product.

T3 must not add `Tests/**/*Snapshot*` for deny/explain/packs panels. T3 tests are Codable round-trips, fake-XPC frames, fallback, and launchd-plist shape.

## IPC contract rv.ipc.v1

**One contract for CLI, hook (T4), doctor (T7), allow-once (T8), and a later Mac app.** Do not invent a second IPC, a SwiftUI-shaped request, or an app-only XPC protocol.

### Transport law

| Environment | Transport | Who owns the adapter |
|---|---|---|
| Production | **XPC** Mach service `dev.rv.evaluate` | `RVService` (listener), `RVCLI` (thin client) |
| Tests | **Unix domain socket** only | Test target / test helper. Not a production `rvd` bind |

Unix socket is **tests only**. Production `rvd` never listens on a UDS. Do not ship `RV_IPC_SOCKET` as a supported user config. A test helper may inject a `FrameTransport` that speaks the same length-prefixed Codable frames.

`RVIPC` owns Codable types and frame encode/decode. It must not import XPC, launchd, ArgumentParser, SwiftUI, or open a socket.

### Versioning and handshake

Protocol name is the string **`rv.ipc.v1`**. Bump the suffix only for a breaking change (`rv.ipc.v2`). Additive optional fields may appear inside v1 with `decodeIfPresent` defaults.

Every connection starts with a handshake **before** any product method:

```
Hello        { protocol: "rv.ipc.v1", clientSemver: String }
HelloAck     { protocol: "rv.ipc.v1", serviceSemver: String, ok: Bool, skewReason: String? }
```

**Skew** (client must drop the connection and fall back in-process):

- `HelloAck.ok == false`
- `HelloAck.protocol != "rv.ipc.v1"`
- Client protocol constant != server protocol constant
- Major semver mismatch between client and service (when both advertise a parseable `X.Y.Z`)

Minor/patch mismatch with the same protocol string is **not** skew. Still record both versions on `rv service status`.

Handshake is a first frame (or a dedicated `hello` method on the XPC edge that only exists to carry this envelope). Product methods must refuse to run on a connection that has not acked `ok: true`.

Do **not** set `HelloAck.ok = true` if `core.git` or `core.filesystem` is missing, empty, or failed to load (PLAN #15). The client then falls back in-process. If the client also has no core packs, `evaluate` returns `indeterminate(.corePacksUnavailable)` and hooks deny per PLAN #6.

### Envelope

One request/response envelope. Prefer a single XPC selector that carries `Data` (or `[UInt8]`) so the `@objc` surface stays tiny. Seven `@objc` methods that immediately decode into these types are acceptable; a fat NSObject API that *is* the domain model is not.

```
IPCRequest {
  id: UUID
  protocol: "rv.ipc.v1"
  method: IPCMethod
}

IPCResponse {
  id: UUID          // echo request id
  protocol: "rv.ipc.v1"
  result: IPCResult
}

enum IPCMethod {
  evaluate(EvaluateParams)
  explain(ExplainParams)
  classify(ClassifyParams)
  listPacks
  setPackEnabled(SetPackEnabledParams)
  allowOnceConsume(AllowOnceConsumeParams)
  doctorSnapshot
}

enum IPCResult {
  evaluate(EvaluateReply)
  explain(ExplainReply)
  classify(ClassifyReply)
  listPacks(ListPacksReply)
  setPackEnabled(SetPackEnabledReply)
  allowOnceConsume(AllowOnceConsumeReply)
  doctorSnapshot(DoctorSnapshotReply)
  error(IPCError)
}

enum IPCError: Codable {
  case unknownMethod
  case decodeFailed
  case protocolSkew(String)
  case engine(String)          // typed engine error, no command text
  case packNotFound(PackID)
  case allowOnceNotFound
  case allowOnceAlreadyConsumed
  case allowOnceExpired
}
```

JSON keys: `camelCase`. `PackID` / `RuleID` / `ShellCommand` encode as T1 string newtypes. `Decision` encodes as a string discriminator (`allow` / `deny` / `indeterminate`) plus optional deny payload (`ruleID` + `reason`). Not a boolean `isDenied`. Not a flat domain enum that drops the deny payload.

Frame on the test UDS: 4-byte big-endian length + UTF-8 JSON body. Production XPC may pass the same JSON `Data` as one message. Do not invent a second schema for XPC vs UDS.

### Methods

All seven are required in T3, even if a later ticket owns the human UX. That is what “app-ready” means.

#### `evaluate`

Hot path. Same meaning as T1 `evaluate`. Same decision + `rule_id` as DCG 0.11.0 **engine source** (PLAN #2), not SKILL.md marketing.

```
EvaluateParams {
  request: EvaluationRequest    // T1 type; includes ShellCommand
}

EvaluateReply {
  result: EvaluationResult      // T1 type: Decision + optional RuleID / PackID / reason
  via: "xpc"                    // server always "xpc"; client fallback stamps "inProcess"
}
```

Default-allow unknown commands (DCG). Do not fail-closed on unknown. Do not allow because the method was not reached — if the client cannot complete this call, it must run in-process evaluate (see Fallback).

`allowOnce.consume` is **not** implicit inside `evaluate`. The client (later T4/T8) may consume first, then evaluate. T3 `evaluate` does not skip the engine because a code exists.

#### `explain`

Structured trace for TTY `rv explain` (T2 renders) and a later app. No ANSI in the reply.

```
ExplainParams {
  request: EvaluationRequest
}

ExplainReply {
  result: EvaluationResult
  normalized: String            // how the engine saw the command (T1 normalize)
  ruleID: RuleID?
  packID: PackID?
  suggestion: String?           // one next action; Vercel-quiet
  stages: [ExplainStage]        // name + elapsed ms; no command text required
}

ExplainStage { name: String, elapsedMs: Double }
```

Stage names stay stable: `normalize`, `quickReject`, `safe`, `destructive`, `default`. Omit unused stages rather than inventing extra ones.

#### `classify`

Risk classification without host-hook side effects. App-ready / later Claude-shaped clients. v1 hosts (Pi / Grok / OpenCode) still use `evaluate` + native deny text, not classify.

```
ClassifyParams {
  request: EvaluationRequest
}

ClassifyReply {
  decision: Decision            // same closed enum as evaluate
  risk: ClassifyRisk            // safe | low | medium | high | critical
  ruleID: RuleID?
  packID: PackID?
  reasons: [ClassifyReason]
  suggestions: [String]
}

ClassifyReason { ruleID: RuleID, explanation: String }
```

Map from evaluate: `allow` + no rule → `safe`; deny on `core.git` / `core.filesystem` → `high` or `critical` per T1 severity if present, else `high`. Do not invent a parallel matcher. Classify calls the same `evaluate`.

Do not wire Claude/Codex hooks here.

#### `listPacks`

```
ListPacksReply {
  packs: [PackRecord]
  enabledCount: Int
  totalCount: Int
}

PackRecord {
  id: PackID
  enabled: Bool
  bundled: Bool
}
```

Day-one: `core.git` and `core.filesystem` present and enabled. Other catalog IDs may appear only if T1/T9 already imported them; T3 must not enable extra packs by default.

#### `setPackEnabled`

```
SetPackEnabledParams { id: PackID, enabled: Bool }
SetPackEnabledReply { pack: PackRecord }
```

Unknown `PackID` → `IPCError.packNotFound`. Persistence goes through RVPolicy / RVPacks (config under `~/.config/rv/` in production; temp HOME in tests). T3 does not invent a second enable store.

#### `allowOnce.consume`

Spend a **grant**, not a plaintext code. T8 TTY `rv allow-once <code>` redeems a code into a grant. IPC consume matches `{ command, cwd }`.

```
AllowOnceConsumeParams { command: String, cwd: String }
AllowOnceConsumeReply {
  consumed: Bool
  tokenID: String?              // opaque; not the raw command
}
```

Rules:

- Unknown / expired / already-consumed → `consumed: false` plus the matching `IPCError` **or** a reply with `consumed: false` (prefer typed `IPCError`).
- Success consumes **once**. A second consume of the same grant fails. Use atomic file compare-and-swap so two in-process hook children cannot both consume.
- Consume does **not** skip evaluate and does **not** allow a command by itself. T8 PolicyGate honors a consumed grant on the next evaluate.
- Redeem of a plaintext code is TTY CLI only and is **not** an IPC method in v1.
- No `RV_BYPASS`. No env that skip-evaluates. No host Allow button.

T3 may expose `AllowOnceConsuming` as a small protocol in RVPolicy (or a T3-local store if T1 has no policy hook yet). T8 owns mint, TTY, and “honor on evaluate.”

#### `doctorSnapshot`

Structured health for T7 `rv doctor` and a later app. No pretty panel.

```
DoctorSnapshotReply {
  protocol: "rv.ipc.v1"
  serviceSemver: String
  label: "dev.rv.evaluate"
  state: ServiceState           // running | idleExitArmed | (server-side always running)
  keepAlive: false
  idleExitSeconds: Int          // ~300
  packsEnabled: [PackID]
  lastError: String?            // no command text
  checks: [DoctorCheck]
}

DoctorCheck {
  id: String                    // stable: "xpc", "protocol", "packs", "launchd"
  status: ok | warning | error | skipped
  message: String               // no command text
}
```

T3 fills service/protocol/packs/launchd-template checks. Host-wired checks (`pi`, `grok`, `opencode`) are `skipped` with message “T7” — do not fake them green.

### Privacy on the wire and in logs

- **No command text in `os_log`.** Log method name, `Decision`, `RuleID`, elapsed ms, request id. Never `ShellCommand` raw text.
- History stays **off**. T3 does not persist evaluations.
- Full command exists only inside the Codable payload and in TTY `explain`/`test` (T2). The service must not write it to disk or the unified log.

### Dependency law

```
RVCLI  -->  RVIPC  (types + encode/decode)
RVCLI  -->  RVEngine / RVPacks / RVPolicy   (in-process fallback only)
RVService --> RVIPC + engine/packs/policy
rvd --> RVService
RVEngine  -x->  XPC, RVIPC transport, RVCLI, RVTUI
```

**Engine never imports XPC.** A test that needs XPC to prove a **decision** is in the wrong module.

**`class` / `NSObject` only at the XPC edge in `RVService`.** Domain, engine, packs, presentation, and `RVIPC` stay value types.

## rvd launchd (on-demand, idle-exit ~5m, not KeepAlive)

`rvd` is a **user LaunchAgent**, not a LaunchDaemon, not a system daemon.

| Key | Value |
|---|---|
| Label | `dev.rv.evaluate` |
| MachServices | `{ "dev.rv.evaluate": true }` (same name as the XPC service) |
| Program / ProgramArguments | installed `rvd` absolute path (T6 writes the real path; T3 template uses a placeholder or build-dir path) |
| RunAtLoad | `false` |
| KeepAlive | **absent or `false`**. Not KeepAlive by default |
| EnableTransactions | `true` if using XPC transactions; optional |

On-demand: launchd starts `rvd` when the first Mach / XPC client connects. Do not `RunAtLoad` to keep it warm. Warmth is “already running from a recent hook,” not “always running.”

**Idle-exit ~5 minutes.** After ~300 seconds with no in-flight request and no active connection, `rvd` exits 0. launchd relaunches on the next XPC demand. Tests may inject a 1-second idle for the timer. Do not implement idle-exit by setting KeepAlive.

Not KeepAlive means: a crash or idle-exit does **not** immediately respawn. The next client demand respawns. `rv service status` must describe this honestly (`down` after idle-exit is valid, not a failure of the product).

`rvd` process:

1. Start NSXPCListener (or equivalent) for `dev.rv.evaluate`.
2. Load / warm the pack registry once (T1 packs).
3. Serve `rv.ipc.v1` frames.
4. Arm idle-exit on idle.
5. Log without command text.

`rvd` must not import ArgumentParser or SwiftUI. CLI flags on `rvd` are limited to `--idle-exit-seconds` (tests / debug) and `--version`. No `--socket` in production builds.

Plist template lives in-repo (see Files). T6 copies it into `~/Library/LaunchAgents/dev.rv.evaluate.plist` (or the current LaunchAgent path) with the real binary path. T3 tests validate **plist keys**, not a live load on the operator’s machine.

## Fallback rules (down / version skew)

Product law: **down or skew → in-process evaluate. Never allow because XPC missed.**

| Client observation | Action | `via` | `rv service status` |
|---|---|---|---|
| Handshake `ok`, protocol `rv.ipc.v1` | Use XPC for the method | `xpc` | `state: running`, `fallback: inactive` |
| Connect fails, timeout, listener absent, idle-exited | In-process `evaluate` (and in-process for explain/classify/listPacks as needed) | `inProcess` | `state: down`, `fallback: down` |
| Connected but skew (see handshake) | Drop connection. In-process. Do **not** send product methods to the skewed peer | `inProcess` | `state: skew`, `fallback: skew` |
| XPC errors mid-call (decode, interrupted) | In-process for **that** request. Do not return Allow as a substitute | `inProcess` | lastError set (no command text) |

**Never:**

- Return `Decision.allow` because `rvd` was down, slow, or skewed.
- Coerce `Decision.indeterminate` to `allow`. Pass it through; T4/T5 encode it as hook deny.
- Skip evaluate on any `RV_*` env.
- Call a skewed service “good enough” for evaluate.
- Fail the hook closed on unknown commands (that is engine default-allow, not transport).
- Treat “service down” as permit in a future app — same law.

Fallback is **evaluate-equivalent**, not “deny everything” and not “allow everything.” Same T1 engine, same packs, same default-allow.

Non-evaluate methods when down/skew:

- `explain` / `classify` / `listPacks` / `doctorSnapshot` — in-process equivalents so CLI still works.
- `setPackEnabled` / `allowOnce.consume` — in-process policy store. If the store is unavailable, return a typed error; do not pretend success.

`rv service status` itself may on-demand-launch `rvd` by connecting, or it may query launchd without a long-lived process. Either is fine. It must not set KeepAlive. After a status connect, idle-exit still applies.

Timeouts: client connect/request budget must be short enough that a dead Mach service fails into in-process before a hook feels hung. Concrete default: connect 200ms, request 500ms, then fallback. Do not block the hook on a spinning `rvd`.

## Files to create

Fill T0 empty targets. Do not create a parallel module tree.

```
Sources/RVIPC/ProtocolVersion.swift          // rv.ipc.v1 constant
Sources/RVIPC/IPCEnvelope.swift             // IPCRequest / IPCResponse / IPCError
Sources/RVIPC/IPCMethods.swift              // seven methods + param/reply types
Sources/RVIPC/FrameCodec.swift              // length-prefix + JSON; no I/O

Sources/RVService/XPCListener.swift         // class / NSObject edge only
Sources/RVService/ServiceRuntime.swift      // warm registry, dispatch methods
Sources/RVService/IdleExit.swift            // ~300s timer
Sources/RVService/DoctorSnapshotBuilder.swift

Sources/rvd/main.swift                      // start runtime; no ArgumentParser app

Sources/RVCLI/Service/XPCClient.swift       // thin client; handshake
Sources/RVService/EvaluateSession.swift     // compiled day-one packs + evaluate; CLI constructs on miss
Sources/RVCLI/Service/ServiceStatusCommand.swift

Resources/launchd/dev.rv.evaluate.plist     // template; KeepAlive false; MachServices

Tests/RVIPCTests/EnvelopeRoundTripTests.swift
Tests/RVIPCTests/FrameCodecTests.swift
Tests/RVServiceTests/FakeXPCUnixSocketTests.swift   // all seven methods
Tests/RVServiceTests/IdleExitTests.swift
Tests/RVServiceTests/LaunchdPlistTests.swift
Tests/RVCLITests/FallbackDownTests.swift
Tests/RVCLITests/FallbackSkewTests.swift
Tests/RVCLITests/ServiceStatusTests.swift
```

Names may flex to T0’s layout. The **ownership** must not: IPC types in `RVIPC`, XPC class in `RVService`, fallback in `RVCLI`, plist tests in T3.

Do **not** create:

- `Tests/**/DenySnapshot*` / pretty TUI fixtures (T2)
- `Sources/RVHooks/**` (T4/T5)
- `install.sh` / setup writers (T6)
- SwiftUI app target
- Anything under ryk

## Acceptance

L1 + fake XPC:

1. `swift test` green for RVIPC, RVService, and T3’s RVCLI service tests.
2. Fake XPC (Unix socket in the test target) round-trips **all seven** methods with stable Codable keys.
3. Production code path is XPC (`dev.rv.evaluate`). Tests do not require a live LaunchAgent on the operator’s machine.
4. Down: client with no listener → in-process `evaluate` of `git reset --hard` is **deny** with the T1 `rule_id`. Not allow.
5. Skew: listener that acks a different protocol (e.g. `rv.ipc.v0`) → client does not send `evaluate` to it → in-process deny for the same command. Status reports `skew`.
6. Engine / RVIPC / Domain targets contain **zero** `import XPC` (or `import Network` used as a production UDS server).
7. `class` / `NSObject` appears only in `RVService` XPC-edge files.
8. LaunchAgent template label `dev.rv.evaluate`, MachServices `dev.rv.evaluate`, no KeepAlive true, idle-exit documented as ~300s and implemented on `rvd`.
9. `ServiceStatusReport` (in-process) prints robot/plain fields: `state`, `protocol`, `label`, `fallback`, `keepAlive=false`. No pretty panel. Process `rv service status` is not required until T2’s `rv` product exists. Do not add that product in T3.
10. `os_log` / test spies never receive raw command text.
11. No pretty TUI snapshots in the T3 diff.
12. IPC types are enough for a later app: all seven methods exist; no SwiftUI types leak into `RVIPC`.

## Test plan

| # | Test | Proves |
|---|---|---|
| 1 | Encode/decode each `IPCMethod` / `IPCResult` | Contract stability |
| 2 | Frame codec: length-prefix, empty, oversized | UDS helper is boring |
| 3 | Fake XPC server (UDS) + client: all seven methods | L1 + fake XPC gate |
| 4 | `evaluate` via fake XPC: `git reset --hard` deny + T1 `rule_id`; `git status` allow | Engine not reimplemented; service is a shell |
| 5 | `listPacks` includes `core.git`, `core.filesystem`, enabled | Day-one packs |
| 6 | `setPackEnabled` unknown id → `packNotFound` | Typed error |
| 7 | `allowOnce.consume` twice → second fails; evaluate still runs | No skip-evaluate |
| 8 | `doctorSnapshot` has xpc/protocol/packs checks; host checks skipped | T7 can extend |
| 9 | No listener → fallback in-process deny (not allow) | Down law |
| 10 | Skew hello → no product method on that socket + in-process deny | Skew law |
| 11 | Mid-call interrupt → in-process, not Allow | Never allow on miss |
| 12 | Plist fixture: label, MachServices, KeepAlive ≠ true, RunAtLoad ≠ true | launchd law |
| 13 | Idle-exit: injected 1s idle → process/runtime signals exit; KeepAlive still false | ~5m behavior, testable |
| 14 | `rv service status` robot lines; no ANSI required | T3 does not own pretty |
| 15 | Log spy: evaluate `rm -rf /Users/me` → log has method + decision, not the path | Privacy |

Do not write TTY-gated pretty tests. Do not load the LaunchAgent into the human’s real HOME. Use temp HOME / in-memory stores.

## Forbidden

- `RV_BYPASS` or any hook-child env that skips evaluate.
- Allowing because `rvd` is down, busy, timed out, or skewed.
- Sending `evaluate` to a version-skewed `rvd`.
- KeepAlive true by default. System daemon. Always-on service.
- Production Unix-socket transport.
- Engine importing XPC. `class` in Domain / Engine / Packs / IPC types.
- Pretty TUI snapshots, ANSI in IPC replies, host deny renderers.
- Mac app target. Second IPC for the app.
- Hooking Read / Edit / MCP. Custom Pi renderer. OpenCode toast. Host Allow button.
- Writing foreign hook files. Writing the operator’s real HOME from tests.
- Persisting raw command text to `os_log` or a default history store.
- Claiming OS-enforced / Seatbelt. Claiming Linux / Windows / macOS 14/15.
- Telemetry, SaaS, network install of packs.
- Implementing inside ryk. Installing or rebinding ryk.
- Enabling extra packs by default. Inventing `RV_BYPASS` as “just for tests.”

## Open questions

1. **Exact XPC API** — `NSXPCConnection` + a one-`Data`-in/`Data`-out `@objc` protocol vs lower-level `xpc_connection`. Either is fine if the Codable envelope is the product API and the engine stays XPC-free. Prefer the smallest `@objc` surface.
2. **Semver source** — handshake `clientSemver` / `serviceSemver` from `CFBundleShortVersionString`, a Swift constant, or git describe. Pick one in T3 and document it on `doctorSnapshot`.
3. **Allow-once honor** — T3 consume store vs T8 evaluate-honor. If T1 has no policy hook, T3 ships consume-only and T8 connects honor. Do not let consume return Allow by itself.
4. **Status without launching** — `launchctl print gui/$UID/dev.rv.evaluate` vs a real XPC hello. Prefer a path that does not force KeepAlive; on-demand hello is acceptable.
5. **Idle-exit vs XPC transactions** — whether `EnableTransactions` + ending the transaction is enough, or a GCD timer is required. Behavior is what is specified (~5m idle, then exit); mechanism is implementer choice.
6. **Classify risk granularity** — T1 may only have deny/allow. Mapping deny → `high` (or T1 `Severity` if it exists) is enough for v1. Do not block T3 on DCG’s numeric `risk_score`.

If an open question blocks compile, pick the conservative answer (smaller API, consume-only, timer-based idle-exit) and leave a one-line comment. Do not stall the ticket.

## Definition of done

T3 is done when:

- `feat/t3-service` (or the T3 worktree) contains the files above and **no** pretty TUI snapshots.
- L1 tests + fake-XPC UDS tests are green without a live LaunchAgent on the operator’s machine.
- Production transport is XPC; UDS exists only in tests.
- Down and skew fixtures prove in-process evaluate, and prove **not-allow** on `git reset --hard`.
- LaunchAgent template is `dev.rv.evaluate`, on-demand, idle-exit ~5m, not KeepAlive.
- Engine never imports XPC; `class`/`NSObject` only at the `RVService` XPC edge.
- All seven `rv.ipc.v1` methods exist and are app-ready; no Mac app was created.
- `rv service status` works in robot/plain form.
- No ryk edits. No `RV_BYPASS`. No command text in logs.

T4 may then make the hook a thin client of this path. T3 does not wire hosts.
