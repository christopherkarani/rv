# Socket evaluate under Phase 2A: peek door + macOS peer capture

Status: design (PR #367 held open pending this).
Scratch preview of the 367/main merge: local branch `wip/367-main-update-unresolved-auth` (`5a22f7b4`).

## Problem

PR #367 (Python SDK + macOS service socket, forked pre-Phase-2A) serves shell
`evaluate` over AF_UNIX to same-user local clients. Current main denies
`.evaluate` for ALL generic IPC (`ServiceMethodAuthorization`, `.agent`
requirement returns `false` unconditionally), pinned by
`socketPeerHasNoControlOrEvalAuthority`. Merging 367 as-is breaks its 2
`UnixSocketListenerTests` reset-hard cases and the SDK live `evaluate`
integration tests: dispatch answers `.error(.authorizationDenied)` before any
policy work. XPC behaves identically today, so the socket is consistent with
main — but 367's headline feature is dead on arrival.

## Findings (merged tree `5a22f7b4`)

1. `ServiceRuntime.evaluate` → `runEvaluate` → `LiveEvaluateWorld.apply`
   (`Sources/RVService/ServiceRuntime.swift:544`,
   `Sources/RVService/LiveEvaluateWorld.swift:108`). **`apply` spends a
   matching owner grant** (`LiveEvaluateWorld.swift:64`). That spend is why
   `.agent` denies principal-less callers: unauthenticated socket peers must
   not burn owner allow-once grants. No execution happens here (execution is
   instance-bound via admission); the hazard is grant spend + unattributed
   audit.
2. A side-effect-free door already exists: `LiveEvaluateWorld.peek`
   (`LiveEvaluateWorld.swift:92`) — policy preview, no spend. The CLI already
   treats daemon evaluate as best-effort diagnostic with in-process fallback
   (`Sources/RVCLI/Service/ServiceClient.swift:147`).
3. Nobody receives apply-via-dispatch today: every generic-IPC `.evaluate`
   is denied, so rerouting dispatch `.evaluate` to peek changes behavior
   only for currently-denied callers. In-process (`ServiceRuntime.evaluate`)
   and host-bridge (`evaluateAgent`, `ServiceValidatedAgentContext`) paths
   are untouched.
4. Linux already captures socket peers: `LinuxSocketPeerCapture` (SO_PEERCRED)
   → `AuthenticatedPeer.socketPeer` (role-less) → hookConsult works, roles
   stay denied (`Sources/RVService/UnixFrameTransport.swift:168`,
   `Sources/RVIsolation/AuthenticatedPeer.swift:17`). macOS
   `UnixSocketListener.serve` enforces same-UID via `getpeereid` but then
   passes `.unauthenticated`, discarding the evidence
   (`Sources/RVService/UnixSocketListener.swift:201,220`).
5. macOS can attest pid without code identity: `getpeereid` +
   `LOCAL_PEERPID` (pattern already in-repo at
   `Sources/RVIsolation/WorkspacePeerAuthenticator.swift:265`). Full code
   identity (`LOCAL_PEERTOKEN` + SecCode + trust manifest) exists for
   workspace transports but is NOT needed for a role-less peer.

## Proposal

**Wire `.evaluate` is peek-only for principal-less callers; apply stays
instance-bound.** Two additive changes, both safe because they only affect
callers that are denied today:

### 1. Dispatch `.evaluate` → peek for peer-without-principal contexts

- Add requirement `.peerPeek` (satisfied iff `context.peer != nil`).
- `requirement(for: .evaluate)` becomes `.peerPeek` instead of `.agent`.
- Dispatch's `.evaluate` branch calls a new `ServiceRuntime.evaluatePeek`
  (`runEvaluate` with `liveWorld().peek`, same cwd/host/analytics), never
  `apply`. Audit stamps legacy-style nils (no verified principal), exactly
  like legacy channels.
- Effect: XPC peers (audit-backed) and socket peers (kernel-attested
  pid/uid) get policy decisions; capture failures and non-peer transports
  stay denied. No currently-allowed flow changes, on any transport.

### 2. macOS socket peer-capture parity

- In `UnixSocketListener.acceptOne`/`serve`, capture
  `getpeereid` + `LOCAL_PEERPID` at accept; same-uid ⇒
  `AuthenticatedPeer.socketPeer` + `.captured` context (mirror
  `UnixFrameTransport.serve`). Keep the existing cross-user drop and
  0700/0600 modes as defense in depth.
- Unix socket peers gain hookConsult + peek-evaluate; control/role-gated
  methods stay denied (componentRole nil). Linux behavior unchanged
  (already captures; gains peek automatically).

### SDK

No wire change: `client.evaluate()` returns peek decisions again. Document
that socket evaluate is preview-only: `allow`/`deny` (with rule IDs) are
final, `ask` never auto-spends — approvals happen from a roled client via
the pending ceremony. 367's Swift reset-hard tests and the pytest live
`evaluate` cases pass unmodified (deny carries `core.git:reset-hard`; plain
allows spend nothing).

## Alternatives rejected

- **Pin denial / land 367 neutered.** Kills the PR's headline feature and
  leaves a dead SDK method. Revisit only if peek turns out to confer
  unexpected capability.
- **Same-UID ⇒ owner principal ⇒ apply.** Contained agents share the UID;
  UID alone cannot distinguish owner-driven from agent-driven SDK use, so
  this would let agents burn owner grants. (Same flaw kills bearer-token
  files and env-inherited secrets: anything the SDK can read, a same-UID
  agent can read.)
- **Code-identity roles for socket peers.** macOS could (`LOCAL_PEERTOKEN`
  + trust manifest) but Linux has no code identity, forking the SDK by
  platform. Unnecessary once evaluate is peek-only.
- **New `.evaluatePeek` wire method.** More surface for zero benefit: no
  IPC caller receives apply today, so narrowing `.evaluate` itself strands
  nothing.
- **Route socket evaluate through the host bridge.** The bridge binds
  agent-instance principals for workspace hosts; SDK operator clients have
  no instance. Wrong principal model.

## Security notes

- pid attestation has a reuse caveat (checked at accept); acceptable for
  role-less presence exactly as on Linux, never for role binding.
- Peek confers no capability beyond the locally runnable `rv` CLI peek,
  which any same-UID process already has. The spend/apply surface is
  unchanged.
- The `.agent` requirement and `submitIdentityRequired` gate are untouched;
  instance-bound execution paths keep live principal validation.

## Test plan

- macOS peer capture: same-uid ⇒ socketPeer context; cross-user dropped;
  capture failure ⇒ unauthenticated; hookConsult allowed, control methods
  denied (extend `SocketPeerAuthorizationTests`).
- Update `socketPeerHasNoControlOrEvalAuthority`: evaluate allowed for
  socket peers; add `peekNeverSpends`: owner grant count unchanged across
  socket evaluates (allow, deny, and ask-shaped).
- 367's `UnixSocketListenerTests` (35) and `pytest sdk/python/tests`
  (unit + live integration) green.
- Full gate: Linux `swift test`, macOS isolation shards, hook grade.

## Rollout

1. Land the peek-door + macOS peer capture as one PR against main (small,
   affects only currently-denied callers).
2. Rebase the scratch preview (`wip/367-main-update-unresolved-auth`) onto
   new main; resolve (expect the same 13 files, minus auth fallout).
3. Push the update to `worktree/clear-river-86c2`, wait for green, squash-merge #367.
4. Delete the scratch branch after #367 lands.
