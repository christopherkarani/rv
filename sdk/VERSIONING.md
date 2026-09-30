# SDK versioning policy

Normative for every RV SDK (Python first). Builds on the wire rules in
`sdk/WIRE.md` §§3–4 and the Swift bodies `Sources/RVIPC/ProtocolVersion.swift`,
`Sources/RVIPC/EvaluationRoute.swift`, `Sources/RVService/ServiceRuntime.swift`.

## 1. The four version lines

| Line | Example today | Authority | Meaning |
|---|---|---|---|
| `sdk_version` | `0.1.0` (new) | SDK release | The client library. PEP 440 / SemVer per ecosystem. |
| `product_version` | `0.1.5` | `ProductVersion.semver` | RV runtime marketing/install line. Informational + minimum-floor enforcement. |
| `protocol_name` | `rv.ipc.v1` | `ProtocolVersion.name` | Exact-match wire identity. |
| `service_semver` | `1.0.0` | `ProtocolVersion.serviceSemver` | **Major-equality** compatibility. |

Plus `capabilities: [string]` — additive, optional, sorted lowercase kebab tokens
(e.g. `pending-watch`, `rule-save`, `classify`) advertised by the runtime in
`HelloAck` and `DoctorSnapshotReply` as new optional fields. Old binaries ignore
unknown keys; old SDKs ignore the new fields. This is the same additive pattern
as `clientSemver`/`serviceSemver` in `IPCEvaluate.swift`/`IPCHookEvaluate.swift`.

Each SDK pins one `SDK_IPC_SEMVER` (starts at `"1.0.0"`): the IPC major the SDK
implements. It is sent as `Hello.clientSemver` and in implicit-hello params. It
is NOT the SDK release version; the two move independently.

## 2. Handshake flow (normative)

Mirrors `ServiceRuntime.acknowledge` + `EvaluationRoute.path`, with one deliberate
divergence (§4):

1. SDK sends `Hello{protocol="rv.ipc.v1", clientSemver=SDK_IPC_SEMVER}` first on
   every connection.
2. Runtime replies `HelloAck{protocol, serviceSemver, ok|skewReason}`. The SDK
   applies, in order: protocol-name exact match → major equality via the
   `major()` port (1–15 ASCII digits, `INT_MAX` cap, nil-on-garbage —
   `ProtocolVersion.major`) → `ok` true → `serviceSemver` nonempty and parseable.
   Any failure raises the SDK's protocol-mismatch error with structured
   `{expected, got, reason}` fields and remediation text.
3. Per-call belt-and-braces: verify `response.id == request.id` and
   `response.protocol == "rv.ipc.v1"` (mirror of `ServiceClient.send`), and
   major-gate `reply.serviceSemver` on every reply carrying it (mirror of the
   per-frame guard in `ServiceRuntime.dispatch`). A reply without `serviceSemver`
   proves nothing and must be rejected by clients without an engine.
4. Minimum runtime floor: `RV_SDK_MIN_PRODUCT = "0.1.5"`, `RV_SDK_MIN_IPC_MAJOR
   = 1`. The SDK probes `rvd --version` (product) at connect time and Hello
   (service) per connection; below floor raises `RuntimeTooOld(min, got,
   upgrade_cmd)`. Floors move only in a minor SDK release with a changelog entry.

## 3. Evolution rules

- **Additive** (no version bump): new optional JSON fields (`decodeIfPresent` on
  Swift, `.get()` with defaults elsewhere), new `IPCMethod` cases, new
  `capabilities` tokens, new `DoctorCheckID` values. Old readers ignore; new
  readers default. SDKs must ignore unknown JSON object keys everywhere.
- **Deprecated**: keep decoding for ≥2 minor releases, stop encoding immediately,
  mark in `sdk/WIRE.md` + changelog. Removal only on a major protocol bump.
- **Incompatible**: any wire-shape break, required-field addition, enum-meaning
  change, or `via`/`ok` semantics change → new `protocol_name` (`rv.ipc.v2`) AND
  a service-major bump. An SDK pins one protocol per release; dual-protocol
  support is a non-goal for v1.
- **Feature negotiation**: SDKs check `capabilities` before calling newer methods;
  an absent token raises `UnsupportedByRuntime(method, min_runtime)` with upgrade
  text. Never probe by calling and parsing `unknownMethod` as control flow in
  normal paths (tests may assert the error exists).

## 4. The one deliberate divergence: skew is a hard error

`ServiceClient` falls back to in-process evaluation on transport miss or skew
(`Sources/RVCLI/Service/ServiceClient.swift`). A non-Swift SDK has no engine, so
it must NOT emulate that fallback: skew, unreachable service, or missing version
proof is a hard typed error, never a local verdict. A verdict computed outside
the Swift engine would be a second policy implementation and a security lie. This
must be documented in every SDK README.

## 5. SDK release discipline

- SDK minors must not require daemon upgrades (additive only).
- Daemon wire-majors ship with a migration note and require an SDK major.
- `HelloSkewReason` strings are the only handshake vocabulary; never invent
  client-side skew reasons on the wire.
