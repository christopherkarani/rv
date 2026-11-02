# Secrets Tier 3: design notes for deferred work

These items were deferred from the hardening stack described in
[`secrets-competitive-study.md`](secrets-competitive-study.md). Each one is
larger than one PR, needs a new subsystem, or changes the threat model. These
are design notes, not commitments. Citation conventions follow the study.

The current gateway is described here so the hook points below are
concrete:

- `SecretLaunchBroker.lease` resolves each definition, mints a placeholder,
  and registers a `SecretGateway.Entry` (`Sources/RVIsolation/SecretLaunchBroker.swift:86-153`,
  registration at `:129-140`).
- `SecretGateway.handle` parses the head, routes `/s/<NAME>`, runs
  `GatewaySubstitution.apply`, builds the upstream URL, reads the body,
  strips headers, sends, scrubs, and audits (`Sources/RVIsolation/SecretGateway.swift:374-437`).
- `Entry` holds a single `SecretValue` (`Sources/RVIsolation/SecretGateway.swift:59-66`).
- The definition types are `SecretSource`, `SecretGatewayBinding`, and
  `SecretDelivery` (`Sources/RVIsolation/SecretsConfiguration.swift:10-63`).
  The strict decoder lives at `SecretsDecoding.delivery` (`:349-372`).
- Teardown happens through `SecretLaunchBroker.revoke(runtime:)`, called at
  runtime end (`Sources/RVIsolation/WorkspaceSessionSupervisor.swift:2067`).

Several items below assume that Tier 1/2 PRs have landed:

- 06: value encoding.
- 09: substitution surfaces.
- 10: method and path scoping.
- 12: audit fails closed.
- 13: runtime binding.
- 14: expiry and re-resolve.

---

## (a) AWS SigV4 re-signing and an emulated container-credentials endpoint

**Problem.** AWS requests are signed, not bearer-authenticated. A placeholder
access key produces an invalid signature, so today the only way to give a
caged agent AWS access is `delivery: environment`, which puts real keys in
the cage.

**Competitor.**
- OpenShell strips the agent's `Authorization` and `X-Amz-*` headers and
  re-signs with real keys (`openshell:crates/openshell-supervisor-network/src/sigv4.rs:78-122`,
  `strip_aws_headers`, then `apply_sigv4_to_request` at `:262-305`).
- Streaming S3 uses UNSIGNED-PAYLOAD (`:307-345`).
- The region is inferred from the host (`:30`).
- STS assume-role refresh mints all three keys atomically
  (`openshell:crates/openshell-server/src/provider_refresh.rs:653-668`).

**Proposed rv design.**
- **Source.** Add `SecretSource.awsProfile(profile: String)`, resolved with
  `aws configure export-credentials --profile P --format process` through
  the existing `BoundedProcess` (`Sources/RVIsolation/SecretProviders.swift:333-409`).
  The output carries `AccessKeyId`, `SecretAccessKey`, `SessionToken`, and
  `Expiration`, which feeds PR 14's expiry.
- **Delivery.** Add `SecretDelivery.awsSigV4(AWSSigningBinding)`:
  ```swift
  public struct AWSSigningBinding: Sendable, Equatable {
      public var upstream: URL        // https://s3.us-east-1.amazonaws.com
      public var region: String
      public var service: String      // "s3", "bedrock", ...
      public var endpointEnv: String  // AWS_ENDPOINT_URL or AWS_ENDPOINT_URL_<SVC>
  }
  ```
- **Gateway entry.** *Corrected when built (t3-04):* `Entry.value` stays a
  single `SecretValue` holding the profile's raw JSON, and
  `Entry.signing: AWSSigningBinding?` marks an AWS entry. A `GatewayCredential`
  enum would have forked PR 14's rotation, history, and fingerprints, which
  compare and store one value. `AWSCredentialSet` parses the three keys and
  `Expiration` from that value when signing, refreshing, and scrubbing.
- **Pure signer.** A new `SecretGatewaySigV4.swift`. It builds the canonical
  request and string-to-sign, and derives the key with `RVDigest.hmacSHA256`,
  which works on both platforms. Signed bodies use the SHA-256 of the
  buffered body (the gateway already buffers up to 32 MiB). Chunked uploads
  use UNSIGNED-PAYLOAD.
- **Hook point in `handle`.** *As built:* a request whose `Authorization`
  starts with `AWS4-` takes `admitAWS` instead of `GatewaySubstitution`, and
  an AWS entry offers no substitution surface, so its placeholder spent as a
  bearer token is `surfaceNotAllowed`. Then:
  1. Parse the SigV4 `Credential=` access-key id.
  2. Require that it equals the placeholder.
  3. Drop `Authorization`, `X-Amz-Date`, `X-Amz-Security-Token`, and
     `X-Amz-Content-Sha256`.
  4. Sign for the upstream host.

  This replaces lines `:387-401` for that kind only.
- **Emulated container-credentials endpoint.** *Deferred (2026-11-02).*
  As built, the lease stages `AWS_ACCESS_KEY_ID` (the placeholder), a
  throwaway `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`, and `endpointEnv`. SDKs
  read environment keys before container credentials, so an endpoint staged
  beside them would never be called. Environment keys also work for
  non-SDK tools (`curl --aws-sigv4`). The original proposal follows. The gateway serves
  `GET /aws/creds/<NAME>`. The lease stages:
  - `AWS_CONTAINER_CREDENTIALS_FULL_URI=http://127.0.0.1:P/aws/creds/<NAME>`;
  - `AWS_CONTAINER_AUTHORIZATION_TOKEN=<placeholder>`;
  - the endpoint env.

  The route returns JSON with a placeholder `AccessKeyId`, a random
  throwaway `SecretAccessKey`, no `Token`, and a short `Expiration`, so SDKs
  re-poll. The handler requires the authorization token to equal a live
  placeholder for that secret. Real keys never enter the cage, and SDKs need
  no configuration beyond environment variables.

**Threat model.**
- The agent's signature is discarded, so the agent cannot choose what the
  gateway signs beyond the request it sends. PR 10's method and path
  scoping therefore matters most here. An S3 `DeleteObject` is just a
  `DELETE`.
- The gateway signs only for `binding.upstream`'s host, never for the
  request's `Host`.
- The credentials endpoint must not be reachable by a process outside the
  runtime (PR 13).
- Response scrubbing must cover the real access-key id, which S3 error
  bodies echo.

**Test plan.**
- Use the AWS SigV4 test suite vectors against the pure signer.
- A fake upstream recomputes the signature with the real secret and
  asserts that it matches.
- The placeholder key id must match the entry, or the request gets 403.
- Agent-supplied `X-Amz-Security-Token` is dropped.
- The credentials endpoint rejects a missing or foreign token.
- A cage test runs `aws s3 ls` against the fake upstream and asserts that no
  real key appears in the env or the reply.

**Size.** M. About 300 lines for the signer, 200 for the endpoint and wiring,
and 300 for tests.

**Open questions (decided 2026-11-02).**
- S3 addressing: path-style. `AWS_S3_FORCE_PATH_STYLE` is not an
  environment variable SDKs read; it is an endpoint-ruleset builtin. The S3
  ruleset already forces path-style for an IP endpoint, and the gateway is
  `127.0.0.1`, so nothing is staged.
- One `upstream` per secret (one region). A host pattern is deferred.
- Signed-chunk and event-stream payloads are refused (`awsSignedStreaming`,
  400). `UNSIGNED-PAYLOAD` and `STREAMING-UNSIGNED-PAYLOAD-TRAILER` pass.

---

## (b) Wiring TransparentHTTPS

**Problem.** SDKs that ignore `*_BASE_URL` send the placeholder straight to the
real host, and it fails with a 401. `TransparentHTTPS.decision`
(`Sources/RVIsolation/TransparentHTTPS.swift:13-17`) has no callers outside its
test. The plan defers termination into `EgressProxy`
(`docs/plans/agent-governance/transparent-https.md`).

**Competitors.**

*Infisical's CA plumbing checklist*:
1. **Six CA environment variables.** `SSL_CERT_FILE`, `NODE_EXTRA_CA_CERTS`,
   `REQUESTS_CA_BUNDLE`, `CURL_CA_BUNDLE`, `GIT_SSL_CAINFO`, and `DENO_CERT`
   (`infisical-cli:packages/cmd/agent_proxy.go:86-93`). Stale proxy
   variables are stripped as well as set, including `NODE_USE_ENV_PROXY`
   (`:95-105`).
2. **ECDSA P-256 root**, chosen so rustls clients accept it
   (`infisical-cli:packages/agentproxy/ca.go:64-66`).
3. **macOS trust** through `security add-trusted-cert -r trustRoot` under a
   30-second timeout (`infisical-cli:packages/cmd/agent_vault_run_trust_darwin.go:13-29`),
   because Go tools ignore the environment variables.
4. **File-locked, atomic CA persistence** under a directory the sandbox
   denies, with a mismatched cert and key pair self-healed
   (`infisical-cli:packages/agentproxy/local_ca_store.go:29-106`).
5. **Bounded leaf cache** of 8192 entries
   (`infisical-cli:packages/agentproxy/ca.go:29,270-283`).
6. **Authenticate before minting a leaf**
   (`infisical-cli:packages/agentproxy/proxy.go:370`).

*Varlock* also sets `NODE_USE_ENV_PROXY=1`
(`varlock:varlock/src/proxy/runtime-proxy.ts:2105`), so Node 24+'s built-in
`fetch` honors `HTTPS_PROXY`.

**Proposed rv design.**
- **Where to terminate.** In `EgressProxy.serveRequest`, after the existing
  policy, public-unicast, and SNI checks (`Sources/RVIsolation/EgressProxy.swift:478-510`)
  have admitted a CONNECT. Call `TransparentHTTPS.decision(host:secretUpstreams:)`
  with the hosts of the runtime's live gateway entries. `.tunnel` keeps
  today's relay. `.terminate` hands the client fd to a new
  `TransparentSession`, which:
  1. completes TLS with a leaf for the exact SNI;
  2. parses the HTTP/1.1 head with `GatewayRequestHead.parse`;
  3. runs the gateway's substitution, scoping, and scrubbing against an
     entry chosen by host instead of by `/s/<NAME>`.

  The gateway logic therefore needs a host-keyed lookup next to
  route-keyed `handle`. Refactor `handle` into
  `serve(head:entry:client:)` plus two front ends.
- **CA.**
  - One ECDSA P-256 root per install.
  - The key is a Keychain item (`rv.transparent-ca`) on macOS, as the plan
    says.
  - The cert is written atomically with `OwnerOnlyFile`
    (`Sources/RVIsolation/OwnerOnlyFile.swift:50-79`) under `~/.config/rv`,
    which is already outside the cage grant.
  - An `flock` serializes creation across workspace hosts.
  - Leaves are cached in an LRU bounded at 1024 entries. The terminate
    set is small.
- **Environment.**
  - The cage CA file is a copy in the runtime scratch directory.
  - Stage all six CA variables, plus `NODE_USE_ENV_PROXY=1` and
    `CARGO_HTTP_CAINFO`.
  - Only stage them when the runtime has at least one gateway secret.
- **Host trust store.** Not by default. The existing plan says the CA "is
  not added to the host trust store". `security add-trusted-cert` would make
  every host process trust an rv-held key. Offer it behind an explicit
  `rv secrets trust-ca` with a timeout and a removal command, and record that
  as a decision.

**Threat model.**
- A leaf key in the workspace host lets anyone with that process's memory
  impersonate the upstream to the cage. That is the same trust the gateway
  already holds.
- Termination must never widen egress. The decision runs only after the
  existing filters admit the CONNECT.
- Exact-host matching is already tested against suffix and prefix tricks.
- rv's cage denies `trustd` mach-lookup
  (`Sources/RVIsolation/SeatbeltProfile.swift:62-87`). Security.framework
  clients in the cage may be unable to evaluate any chain, including one
  anchored in a login-keychain trust setting. Measure this before promising
  Go or Swift coverage.

**Test plan.**
- Unit tests:
  - the leaf SAN equals the SNI;
  - the LRU bound holds;
  - concurrent CA creation yields one key pair;
  - a mismatched pair heals.
- Integration: curl and Node through the proxy with the CA variables. The
  upstream sees the real value, and the cage reply sees the placeholder.
- A non-secret host stays a byte-exact tunnel.
- A suffix host stays a tunnel.

**Size.** L. TLS server termination in Swift means Network.framework on
macOS, or swift-nio-ssl. Each is a new dependency or a significant platform
surface.

**Open questions.**
- Which TLS stack? Network.framework does not run on Linux, where the cage is
  refused anyway.
- Should HTTP/2 be refused through ALPN, or supported?
- Should termination be gated per secret with a `transparent: true` field?

---

## (c) OAuth and short-lived token minting with refresh

**Problem.** Every `secrets.json` value is long-lived. Providers that issue
short-lived tokens (OAuth client credentials, refresh-token grants) cannot be
used without putting a long-lived token in the gateway.

**Competitor.**
- OpenShell strategies cover `oauth2_refresh_token`,
  `oauth2_client_credentials`, and `aws_sts_assume_role`
  (`openshell:crates/openshell-server/src/provider_refresh.rs:653-668`).
- The refresh window is 300 s and the maximum lifetime 3600 s (`:30-35`).
- The failure taxonomy is `Retry` / `Investigate` / `Reauthorize` /
  `FixConfiguration` (`:517-565`).
- Before contacting the issuer, state is persisted as `refresh_in_progress`
  with recovery `Investigate` (`:1160-1164`).
- A non-connect failure on a user refresh-token exchange becomes
  `Reauthorize` ("uncertain outcome") and is never retried automatically
  (`:1934-1940`).

**Proposed rv design.**
- **Source.** Add a `SecretSource.oauth(OAuthGrant)` case:
  ```swift
  public enum OAuthGrant: Sendable, Equatable {
      case clientCredentials(tokenURL: URL, clientID: String, secret: SecretSource, scope: String?)
      case refreshToken(tokenURL: URL, clientID: String, keychainAccount: String)
  }
  ```
  The token URL is https only, validated like `httpsUpstream`.
- **Refresher.** A `SecretTokenRefresher` owned by `SecretLaunchBroker`.
  It mints at lease time, and PR 14's TTL re-resolve calls it before
  expiry. It reuses MCP OAuth's proven pieces:
  - the refresh grant (`Sources/RVMCP/MCPOAuth.swift:319-331`);
  - the cross-process `flock` around a rotating exchange (`:702-715`).
- **State.** A small record in the Keychain beside the refresh token:
  ```swift
  enum RefreshState: Sendable { case idle, inProgress(since: Date), failed(RefreshRecovery) }
  enum RefreshRecovery: Sendable { case retry, investigate, reauthorize, fixConfiguration }
  ```
  Write `inProgress` before the HTTP call. On startup, `inProgress`
  becomes `investigate`, never a silent retry.
- **Classification.**
  - A connect failure is `retry`.
  - `invalid_grant` is `reauthorize`.
  - `invalid_client` or HTTP 400 configuration errors are
    `fixConfiguration`.
  - Any other failure after the request was sent on a rotating refresh
    token is `reauthorize`.
- **Surface.** `rv secrets check` prints the recovery action. A gateway
  request on a dead token gets 502 with the recovery hint (PR 07's shape),
  never the issuer's body.

**Threat model.**
- The refresh token is the crown jewel. It never leaves the host process,
  and the cage only sees placeholders for the access token.
- An ambiguous exchange may have rotated the token server-side. Retrying
  with the old one can trigger refresh-token-reuse detection and revoke
  the whole grant. Hence `reauthorize`.
- The issuer's error bodies are not echoed, because they can contain token
  fragments.

**Test plan.**
- A fake issuer covers each failure class, with the expected recovery.
- A crash between persisting `inProgress` and the response leaves state
  `investigate`.
- Two brokers refreshing concurrently make one exchange.
- An expired access token is re-minted before forwarding.

**Size.** M-L.

**Open questions.**
- Who runs the initial authorization-code flow? Reuse `rv mcp`'s browser
  flow, or require a pre-obtained refresh token?
- Should the refresher run when no runtime is live?

---

## (d) Request-bound approvals

**Problem.** Some secret uses deserve a human yes per request: a
`POST /repos/.../merges`, a payment, a production database. rv has
principal-bound action approvals for runtime admission, but nothing for
gateway requests.

**Competitor (Varlock).**
- An approval request binds method, verified host, path, body hash, a
  random nonce, and an expiry (`varlock:varlock/src/proxy/approval.ts:8-24,105-131`).
- The decision must echo the nonce (`:54-55`).
- Grant keys come in three scopes: `host`, `endpoint` (method + host + path,
  the default), and `request` (adds the body hash) (`:76-96`).
- Grant lifetime is clamped to the rule's `maxDuration`. `maxDuration=0`
  means always ask, and grants are never stored
  (`varlock:varlock/src/proxy/approval-grants.ts:101-131`).

**Proposed rv design.**
- **Config.** Add to the gateway binding (beside PR 10's rules):
  ```swift
  public struct GatewayApprovalRule: Sendable, Equatable {
      public var methods: Set<String>
      public var pathPrefix: String
      public var each: Scope            // .host | .endpoint | .request
      public var maxDuration: Duration  // 0 = always ask
  }
  ```
- **Hook point.** In `SecretGateway.handle`, after scoping and body read, and
  before `transport.send` (`Sources/RVIsolation/SecretGateway.swift:414-424`):
  1. Compute `bodyHash = SHA-256(body)` over the placeholder form, so the
     hash carries no secret.
  2. Compute the action digest over
     `method host path bodyHash nonce`.
- **Approval transport.** Reuse `ActionApprovalAsking`
  (`Sources/RVIsolation/ActionApprovalAsk.swift:32-60`). Its
  `consumeApproval(_:actionDigestHex:)` is already a single-use,
  digest-bound consume. Add a `ProposedAction` case for a secret request,
  so approvals show up in the same queue and UI.
- **Waiting.** The gateway connection thread blocks, bounded by
  `maxWait`, which is below the client socket timeout. On timeout or deny
  it returns 403 with a reason.
- **Grants.** Store grants in host memory per runtime, keyed by
  `ruleID + scope part`, with lifetime `min(chosen, maxDuration)`. They are
  dropped on `revoke(runtime:)`.

**Threat model.**
- The nonce stops replaying an old approval onto a new request.
- The body hash stops an approved endpoint grant at `request` scope from
  being reused with a different payload.
- The approver must see the method, host, path, and a body summary,
  never the real value.
- Blocking gateway threads consume the 64 connection slots
  (`:69`), so parked requests need their own cap.

**Test plan.**
- Approve, deny, and timeout paths.
- A nonce mismatch is refused.
- `request` scope does not cover a changed body.
- `maxDuration` clamps the grant, and `0` stores none.
- Grants die with the runtime.
- The parked-request cap returns 503.

**Size.** M.

**Open questions (decided).**
- Approvals ride rvd's action-approval service through the runtime's
  admission channel, so they are identity-bound.
- With no approver, deny (`approvalUnavailable`).

**As built (corrects the proposal above).**
- *No grants, scopes, or `maxDuration`.* Every matching request needs its
  own single-use approval: the proposal's `request` scope with
  `maxDuration = 0`. Config is `approve: [GatewayAllowance]`, the `allow`
  shape, not a new `GatewayApprovalRule`.
- *No separate nonce.* The approval service already binds each approval to
  a random approval and continuation id, the agent principal, and the action
  digest, and consumes it once (`consumeApproval(_:actionDigestHex:)`).
  `SecretRequestAction` binds SHA-256 of the full target (query included)
  and of the body.
- *Blocking was wrong.* Approvals take human time (they live 15 minutes);
  agent HTTP clients do not wait that long.
  The gateway holds a request up to 20 s, then refuses `approvalPending`
  with `Retry-After`; an identical retry after approval consumes it and is
  forwarded. Past 16 held requests, a request checks once instead of
  waiting, and gets 403 `approvalPending`, not 503.
- *Hook point.* After the body read and before substitution and the
  forward record (`SecretGateway.handle`), in
  `Sources/RVIsolation/SecretGatewayApproval.swift`. Policy maps
  `ProposedAction.secretRequest` to `mandatoryHuman`; `perform` and compile
  refuse it, since only the gateway executes it.
- Parked approvals are cancelled on `revoke` and `stop`, and dropped after
  the service's 15-minute lifetime.

---

## (e) Metadata-endpoint emulation (GCE, AWS ECS)

**Problem.** Cloud SDKs discover credentials from metadata services. Without
emulation, the only option is environment delivery of a key file or static
keys.

**Competitor.** OpenShell's GCE metadata emulator serves a placeholder access
token with `expires_in`. The proxy swaps in the real token on egress
(`openshell:crates/openshell-supervisor-network/src/google_cloud_metadata.rs:1-13,158-190`,
with the test `token_returns_placeholder_not_real_value` at `:618`).

**Proposed rv design.**
- **AWS ECS.** Covered by (a)'s `/aws/creds/<NAME>` route. ECS's
  `AWS_CONTAINER_CREDENTIALS_FULL_URI` is the only AWS discovery path that
  works without root and without binding `169.254.169.254`.
- **GCE.**
  - A `/gce/<NAME>/computeMetadata/v1/...` route family on the gateway.
  - The lease stages `GCE_METADATA_HOST=127.0.0.1:P` (the path prefix
    needs a per-secret port, or a host-header convention; see the open
    questions).
  - `/instance/service-accounts/default/token` returns
    `{access_token: <placeholder>, expires_in, token_type: "Bearer"}`.
  - The real token comes from (c) or from `gcloud auth print-access-token`.
  - The `Metadata-Flavor: Google` request header is required, and so is
    the same response header.
- **Egress.** Google SDKs call `*.googleapis.com` directly and honor no
  single base URL, so the placeholder reaches the real host. GCE emulation
  is therefore useful only together with (b).

**Threat model.**
- The placeholder token is the only thing served. Project id and email
  come from definition fields, not from the provider.
- Never bind link-local addresses, because the cage cannot reach them and
  rv must not create them.
- PR 13's binding applies.

**Test plan.**
- Each emulated path returns the documented shape.
- The token is a live placeholder.
- A missing `Metadata-Flavor` header gets 403.
- A cage test runs the Google auth library's metadata check against the
  emulator.

**Size.** S for AWS once (a) exists. M for GCE, plus (b).

**Open questions.**
- `GCE_METADATA_HOST` takes a host and port, not a path. Should rv run a
  second listener, or route by `Host`?
- Is Azure IMDS worth it? It needs `169.254.169.254` or MSAL's
  `IDENTITY_ENDPOINT`.

---

## (f) Dynamic-secret leases

**Depends on rv gaining dynamic sources.** rv has none today. Vault is KV only,
and "Vault dynamic secrets with leases" is listed under Later in
`docs/plans/agent-governance/PLAN.md`.

**Problem.** A dynamic credential (Vault database role, STS session) should
live only as long as the runtime, and be revoked when it ends.

**Competitor (Infisical CLI proxy).**
- The refresh buffer is `min(ttl/5, 1m)` before expiry
  (`infisical-cli:packages/agentproxy/leases.go:25-35`), with singleflight and
  backoff between 5 s and 60 s (`:20-22`).
- On shutdown, `revokeAll` revokes every lease in parallel under a context
  deadline, and falls back to server-side expiry
  (`infisical-cli:packages/agentproxy/leases.go:389-434`).
- Server-side, `maxTTL` is an absolute budget from creation
  (`infisical:ee/services/dynamic-secret-lease/dynamic-secret-lease-service.ts:153-158`).

**Proposed rv design.**
- **Provider protocol.**
  ```swift
  protocol DynamicSecretProvider: Sendable {
      func create(_ source: SecretSource) -> Result<(SecretValue, Lease), SecretResolutionError>
      func renew(_ lease: Lease) -> Result<Lease, SecretResolutionError>
      func revoke(_ lease: Lease, deadline: ContinuousClock.Instant) -> Bool
  }
  struct Lease: Sendable { var id: String; var expires: Date; var maxExpiry: Date }
  ```
  Start with Vault `sys/leases/renew` and `revoke` on the existing
  `BlockingHTTP` client.
- **Lease tracking.** `SecretLaunchBroker` keeps
  `[runtime: [Lease]]` beside `byRuntime`
  (`Sources/RVIsolation/SecretLaunchBroker.swift:47`).
- **Renewal.** A timer renews at `expires - min(ttl/5, 60 s)` until it
  reaches `maxExpiry`.
- **Revocation.** `revoke(runtime:)` (`:167-172`) revokes the runtime's
  leases in parallel with a 10 s deadline and audits any that failed.
  Server TTL is the backstop.

**Threat model.**
- A crashed workspace host leaks leases until TTL. Keep TTLs short.
- Revocation failures must be audited, not swallowed.
- Lease ids are not secrets, but should still stay out of the cage.

**Test plan.**
- A fake provider covers renew timing (ttl/5 capped at 1 m).
- `maxExpiry` stops renewal.
- Parallel revoke finishes under the deadline with one hung revoke.
- A failed revoke is audited.

**Size.** L, including the first dynamic provider.

**Open questions.**
- Should a renewal failure revoke the placeholder, or let the value expire
  naturally?
- Is per-lease, per-runtime state persisted, so a restarted host can revoke
  orphans?

---

## (g) Request-body placeholder substitution

**Deferred deliberately.**

**Problem.** Some APIs take credentials in a JSON or form body (OAuth
`client_secret`, some webhook signers). Today the body passes through
untouched (`Sources/RVIsolation/SecretGatewayProtocol.swift:207-208`).

**Competitors.**
- OpenShell does not rewrite bodies by default. Body rewriting is an
  explicit per-endpoint opt-in, `request_body_credential_rewrite`
  (`openshell:crates/openshell-core/src/secrets.rs:561-690`). With it off,
  the placeholder reaches the upstream unchanged, and an e2e test pins that
  (`openshell:e2e/rust/tests/credential_gating.rs`).
- rv's OpenShell study recommends against copying it while the gateway
  substitutes only headers and the target.
- Infisical caps body rewriting at 10 MB, skips encoded bodies, and bounds
  expansion (`infisical-cli:packages/agentproxy/rewrite.go:121-210`).

**Why not now.**
- A correct body rewrite needs per-content-type parsers: JSON string
  escaping, form encoding, and multipart boundaries.
- It also needs a policy for compressed bodies, and an answer for
  streaming or chunked uploads.
- Every one of those is attacker-shaped input in the host process.
- A raw byte replace corrupts JSON when the value needs escaping.

**Worth it when all of these hold:**
1. A concrete, common upstream requires a body credential, and no header
   alternative exists.
2. PR 09's surfaces exist, so `body` can be an explicit per-secret opt-in.
3. Only `application/json` and `application/x-www-form-urlencoded` are
   accepted. Values are encoded per format, and anything else is refused.
4. Bodies are capped well below 32 MiB, and encoded or chunked bodies are
   refused.

**Size if done.** M.

---

## (h) Binary and ancestor binding of secret use on macOS

**Problem.** After PR 13, only the bound runtime can reach its gateway
entries. Any process in that runtime that holds the placeholder can still
spend it: a `curl` the agent spawned, or a dependency's postinstall script.

**Competitor.**
- OpenShell resolves the peer pid, hashes the live executable, walks up to
  64 ancestors, and fails closed if anything changes during collection
  (`openshell:crates/openshell-binary-identity/src/lib.rs:96-157,252-311`).
- Policy matches the leaf or any ancestor, never argv
  (`openshell:crates/openshell-supervisor-network/data/sandbox-policy.rego:147-170`).

**Proposed rv design.**
- **Definition.** Add `binaries: [String]?` to `SecretDefinition`, holding
  canonical absolute paths, for example GH_TOKEN only for `git` and `gh`.
- **Peer to pid.** TCP loopback has no `LOCAL_PEERPID`, which is unix-socket
  only (`Sources/RVIsolation/WorkspacePeerAuthenticator.swift:293`). Map the
  accepted socket's peer port to a pid by walking the runtime's process
  group: `proc_listpgrppids`, then `proc_pidinfo(PROC_PIDLISTFDS)`, then
  `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)`, matching the local and remote
  ports.
- **Pid to identity.** `proc_pidpath`, plus a `stat` and hash checked against
  the TOFU pins that `EgressProxy` already keeps
  (`Sources/RVIsolation/EgressProxy.swift:608-640`). Walk ancestors with
  `proc_pidinfo(PROC_PIDTBSDINFO).pbi_ppid` up to the session leader, then
  re-check the start times.
- **Hook point.** At the start of `SecretGateway.handle`, before reading the
  head. On a mismatch, refuse with a new `GatewayRefusal.binaryMismatch` and
  PR 12's misuse event.

**Threat model.**
- Same-uid processes can race pid reuse. Collect, re-verify, then fail
  closed.
- An ancestor match is coarse. Any child of an allowed `git` is admitted,
  which is OpenShell's accepted trade-off.
- Interpreters (`node`, `python`) as allowed binaries admit any script they
  run.

**Test plan.**
- A cage test where `curl` with the placeholder is refused and `git` is
  admitted.
- An ancestor match is admitted.
- A pid that exits mid-collection is refused.
- A swapped binary at the same path is refused by the pin.

**Size.** M-L. The port-to-pid scan is the risky part. Measure its cost per
request.

**Open questions.**
- Could the per-runtime gateway listener from PR 13 move to a unix socket for
  SDKs that support one, giving `LOCAL_PEERPID` for free?
- Should a mismatch be cached per connection?

---

## (i) Remaining rv gaps outside the Tier 1/2 stack

Each line was re-verified against the current tree.

1. **MCP stdio servers ignore `allowEnvironmentDelivery`.**
   - The stdio launch path writes resolved real values into the server's
     environment and args, whatever the secret's `delivery` says
     (`Sources/RVMCP/MCPGatewayRuntime.swift:110-111`).
   - `resolve` checks only `allowsSecretSource` (`:140`). An organization
     that set `secrets.allowEnvironmentDelivery: false` still gets
     real-value delivery here.
   - **Fix:** in `resolve`, refuse when the policy forbids environment
     delivery and the target is a stdio server. Remote MCP headers stay
     gateway-side. **S.**
2. **`scan`, `hook run`, and `audit forward` skip managed-policy checks.**
   - Both `SecretsRun.scan` (`Sources/RVCLI/Commands/SecretsCommand.swift:303-315`)
     and `SecretsRun.hookRun` (`:409-422`) resolve every configured secret
     with no `SecretOrganizationRules` check.
   - `AuditForwardRun.resolveHeaders` (`Sources/RVCLI/Commands/AuditForward.swift:210-238`)
     resolves `${secret:NAME}` with no policy check.
   - An invalid policy is ignored entirely when `--to` is passed (`:305`).
   - **Fix:** route all three through `SecretOrganizationRules.violation`,
     and fail on an invalid policy. **S.**
3. **Keychain items lack access control.**
   - `rv secrets set` adds items with only
     `kSecAttrAccessibleWhenUnlocked` (`Sources/RVIsolation/SecretStore.swift:78`).
     There is no `kSecAttrAccessControl` and no access group.
   - The update path changes only the data (`:72`), so even a future ACL
     would not apply to existing items.
   - **Fix:** create items with `SecAccessControlCreateWithFlags`
     (`.userPresence` opt-in, `ThisDeviceOnly`). Re-create on update rather
     than calling `SecItemUpdate`. **S-M.** It interacts with launch-time
     prompts, so it needs a UX decision.
4. **The audit chain is unkeyed SHA-256.**
   - Each line's `prev` is a plain SHA-256 of the previous line
     (`Sources/RVHistory/AuditLog.swift:20,45`).
   - `AuditChain` documents this as intentional: the off-machine head anchors
     trust (`Sources/RVHistory/AuditChain.swift:40-43`). A same-uid process
     can still rewrite and re-chain the local file undetectably between
     forwards.
   - **Option:** HMAC the chain under a Keychain-held key. This only helps if
     that key has an ACL (item 3), because `audit.key` on disk is same-uid
     readable. **M.** Decide together with item 3.
