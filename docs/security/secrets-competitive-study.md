# rv secrets vs Infisical, OpenShell, and Varlock

A code-level comparison of rv's secrets subsystem with three projects that now
ship overlapping products. It drives the hardening stack (PRs 02-16) and the
deferred designs in [`secrets-tier3-design.md`](secrets-tier3-design.md).

Sources were read, not run. Citations use `project:path:line`:

- `infisical-cli:` is the Infisical Go CLI, and `infisical:` is the server (`backend/src`).
- `openshell:` is NVIDIA OpenShell (Rust).
- `varlock:` is `dmno-dev/varlock` (`packages/`).
- Bare `Sources/...` paths are rv.

## Landscape

Two of the three now sell rv's product shape: run a coding agent under macOS
Seatbelt, give it placeholder credentials, and swap in real values at a
loopback proxy.

- **Infisical**: `infisical secrets agent-proxy run -- claude`. A deny-default
  Seatbelt profile, placeholder env, and an ephemeral loopback MITM proxy with
  a local CA (`infisical-cli:packages/cmd/agent_proxy_run.go`,
  `infisical-cli:packages/sandbox/seatbelt_profile.go:11-153`,
  `infisical-cli:packages/agentproxy/`). Its Agent Vault mode adds per-service
  method and path policy (`infisical-cli:packages/agentvault/policy.go:18-41`).
- **Varlock**: about 7k lines of proxy code with format-preserving
  placeholders, per-surface substitution, response scrubbing, approvals,
  audit, and Seatbelt or Docker launchers (`varlock:varlock/src/proxy/*`). It
  runs in-process in JS, and its Seatbelt profile starts from `(allow default)`
  (`varlock:varlock/src/proxy/sandbox-seatbelt.ts:108-125`).
- **OpenShell**: no placeholder proxy on a Mac. It does have the best
  credential scoping model. Each credential is bound to an endpoint
  (host, port, path) and gated by network policy for the calling binary
  (`openshell:crates/openshell-core/src/provider_credentials.rs:347-425`).
  It offers `read-only`/`read-write` method presets
  (`openshell:crates/openshell-policy-schema/src/lib.rs:1148-1149`), explicit
  path rules (`openshell:providers/github.yaml:55-63`), context-safe value
  encoding, and a refresh engine with a failure taxonomy.

## Where rv leads

- **Random per-launch placeholders.** rv mints `<prefix>rvph_<32 hex>` with
  128 bits from the system RNG, registers it per runtime, and revokes it at
  runtime end (`Sources/RVIsolation/SecretGatewayProtocol.swift:3-24`,
  `Sources/RVIsolation/SecretLaunchBroker.swift:163-172`). OpenShell's
  default placeholders are names such as `openshell:resolve:env:KEY`
  (`openshell:crates/openshell-core/src/secrets.rs:13`). They are safe only
  because its proxy is the sole egress path. Infisical's server accepts
  user-chosen placeholders of length 1 or more
  (`infisical:ee/services/proxied-service/proxied-service-schemas.ts:101-107`).
- **Response scrubbing.** rv streams responses through a scrubber that turns
  the real value back into the placeholder, with a hold-back buffer for values
  split across chunks (`Sources/RVIsolation/SecretGateway.swift:419-423`,
  `Sources/RVIsolation/SecretGatewayProtocol.swift:266-316`). OpenShell does
  not rewrite responses at all.
- **A boundary outside the agent's runtime.** rv resolves and holds values in
  the workspace host process, and the agent sits in a separate Seatbelt cage.
  Varlock's leak prevention monkeypatches console, streams, and
  `ServerResponse` inside the process it protects
  (`varlock:varlock/src/runtime/patch-server-response.ts:192-275`), and it
  fails open on an unknown content encoding (`:404`). The agent controls that
  runtime, so it is not a boundary.
- **Deny-default Mach lookup.** rv's cage denies every `mach-lookup` except
  `com.apple.bsd.dirhelper`. That includes securityd, SecurityServer, and trustd
  (`Sources/RVIsolation/SeatbeltProfile.swift:28-87`). Varlock denies only
  securityd and `com.1password*` on top of `(allow default)`. Infisical omits
  securityd and mDNSResponder but allows trustd when its CA is trusted.
- **Strict config and fail-closed staging.** rv's `secrets.json` decoder refuses
  unknown keys, and the gateway upstream must be a plain https origin
  (`Sources/RVIsolation/SecretsConfiguration.swift:433-445`). Any resolution
  failure revokes the placeholders minted so far and stages nothing
  (`Sources/RVIsolation/SecretLaunchBroker.swift:111-119`).

## Where rv lags

- **No method or path scoping.** A gateway secret is bound to one https
  upstream (`Sources/RVIsolation/SecretGatewayProtocol.swift:169-175`), but any
  method and path on that host is forwarded. With `GITHUB_TOKEN`, a
  prompt-injected agent can push or delete.
- **Raw value splicing.** Values are spliced byte for byte into the request
  target and headers (`Sources/RVIsolation/SecretGatewayProtocol.swift:218-262`).
  A value containing `?`, `/`, or CR/LF can reshape the upstream request.
  OpenShell refuses CR/LF/NUL and percent-encodes values per location
  (`openshell:crates/openshell-core/src/secrets.rs:862-1000`).
- **Placeholders the gateway cannot see.** A placeholder inside base64 Basic auth
  or percent-encoded passes through unsubstituted. OpenShell decodes, resolves,
  and re-encodes Basic auth, and refuses any marker left over
  (`openshell:crates/openshell-core/src/secrets.rs:52-90`).
- **Raw-only scrubbing.** Only the exact bytes of the secret are scrubbed.
  Base64, percent-encoded, JSON-escaped, and hex echoes pass through. Varlock
  returns 502 when a value survives its scrub
  (`varlock:varlock/src/proxy/runtime-proxy.ts:949-1146`).
- **Proxy request hardening.** Infisical rejects TRACE/TRACK, pins Host, strips
  hop-by-hop headers before injection
  (`infisical-cli:packages/agentproxy/proxy.go:475,633,638`), and strips
  method-override headers (`infisical-cli:packages/agentvault/policy.go:44`).
  It turns an upstream 401 into a 502 without `WWW-Authenticate`, so the
  agent's MCP client does not start its own OAuth flow
  (`infisical-cli:packages/agentvault/upstream_auth.go:27-40`).
- **Audit fails open and records no misuse.** `AuditLog.append` results are
  discarded (`Sources/RVIsolation/SecretLaunchBroker.swift:62,151`). A foreign
  or unknown placeholder is an ordinary denial. OpenShell raises a separate
  High-severity finding (`openshell:crates/openshell-supervisor-network/src/l7/mod.rs:38-70`).
  Infisical records which credential was applied on which request surface
  (`infisical-cli:packages/agentproxy/rewrite.go:24-41`).
- **Any local process can spend a placeholder.** The gateway listens on
  `127.0.0.1` and checks only the token. OpenShell admits a credential only on
  a request that policy admitted for that binary or its ancestors
  (`openshell:crates/openshell-supervisor-network/data/sandbox-policy.rego:147-170`).
- **No expiry or rotation.** A value is fixed for the runtime's lifetime.
  OpenShell refuses expired values at resolve time
  (`openshell:crates/openshell-core/src/secrets.rs:690-697`) and keeps 8
  resolver generations for live rotation
  (`openshell:crates/openshell-core/src/provider_credentials.rs:16,44-61`).
- **Varlock import is weaker than Varlock.** Wrong provider signatures for
  `vaultSecret`, `awsSecret`, and positional `infisical()`. Header, post-comment,
  `export`, and multi-line grammar bugs. Commented-out `# KEY=value` lines copied
  into descriptions. Every import hard-coded to `delivery: .environment`
  (`Sources/RVIsolation/VarlockSchema.swift:189`).
- **Repo-controlled schema import.** `rv init` imports `<project>/.env.schema`
  without a flag (`Sources/RVCLI/Commands/InitCommand.swift:306,354`). A cloned
  repo can bind references into the user's own vaults. Infisical refuses to
  read security toggles from committed config
  (`infisical-cli:packages/cmd/agent_proxy_run.go:344-360`).
- **The pre-commit hook.** It matches exact values only. It writes staged
  plaintext to `$TMPDIR` before scanning
  (`Sources/RVIsolation/SecretGitHook.swift:102-110`) and truncates `git show`
  output at 1 MiB. Infisical vendors betterleaks, with 417 rules, confidence
  levels, and a managed-block hook
  (`infisical-cli:packages/cmd/pre-commit-script/pre-commit.sh`).
- **One `op` call per 1Password secret.** Varlock batches through `op inject`
  with random separators and retries partial failures
  (`varlock:plugins/1password/src/plugin.ts:25-238`).

## Roadmap

Tier 1 closes correctness and leak bugs in code that already ships. Tier 2
adds scoping and lifecycle features that the gateway's shape already
supports. Each row is one PR in the stack.

| PR | Tier | Item | Borrowed from |
|---|---|---|---|
| 02 | 1 | Varlock importer fixes: provider signatures, positional args, no commented-out items in descriptions, oversized `@type` | `varlock:plugins/*/src/plugin.ts`, `varlock:env-spec-parser/src/classes.ts:454-468` |
| 03 | 1 | Varlock grammar conformance: multi-block header, post-comment decorators, `export`, multi-line values, quoted decorator values | `varlock:env-spec-parser/grammar.peggy` |
| 04 | 1 | `rv init` no longer auto-imports a repo `.env.schema` | `infisical-cli:packages/cmd/agent_proxy_run.go:344-360` |
| 05 | 1 | `@proxy` / `@placeholder` import to gateway delivery | `varlock:varlock/src/env-graph/lib/decorators.ts:1063-1085`, `varlock:varlock/src/proxy/placeholder.ts:25-127` |
| 06 | 1 | Gateway value validation and per-location encoding | `openshell:crates/openshell-core/src/secrets.rs:862-1000` |
| 07 | 1 | Proxy hardening: reject TRACE/TRACK, strip method-override and hop-by-hop headers, pin Host, map upstream 401 to 502 without `WWW-Authenticate` | `infisical-cli:packages/agentproxy/proxy.go:475,633,638`, `infisical-cli:packages/agentvault/upstream_auth.go:27-40` |
| 08 | 1 | Placeholders inside Basic auth and percent-encoding | `openshell:crates/openshell-core/src/secrets.rs:52-90` |
| 09 | 2 | Per-placeholder substitution surfaces | `infisical-cli:packages/agentproxy/rewrite.go:121-210`, `varlock:varlock/src/proxy/runtime-proxy.ts:481-680` |
| 10 | 2 | Method and path scoping, plus presets | `openshell:crates/openshell-policy-schema/src/lib.rs:1148-1149`, `openshell:providers/github.yaml:55-63` |
| 11 | 1 | Scrub encoded variants, streaming hold-back, 502 when a value survives | `varlock:varlock/src/proxy/runtime-proxy.ts:949-1146` |
| 12 | 1 | Audit fails closed, activity records, misuse finding | `openshell:crates/openshell-supervisor-network/src/l7/mod.rs:38-70`, `infisical-cli:packages/agentproxy/rewrite.go:24-41` |
| 13 | 2 | Gateway reachable only by the bound runtime | `openshell:crates/openshell-supervisor-network/data/sandbox-policy.rego:147-170` (idea, not mechanism) |
| 14 | 2 | Secret expiry, TTL re-resolve, live rotation | `openshell:crates/openshell-core/src/secrets.rs:690-697`, `openshell:crates/openshell-core/src/provider_credentials.rs:16,44-61` |
| 15 | 2 | Git hook scanner: pattern and entropy rules, in-memory scan, managed hook block | `infisical-cli:detect/config/betterleaks.toml`, `infisical-cli:packages/cmd/pre-commit-script/pre-commit.sh` |
| 16 | 2 | 1Password `op inject` batching | `varlock:plugins/1password/src/plugin.ts:25-238` |

Tier 3 (SigV4, transparent HTTPS, OAuth minting, approvals, metadata
emulation, dynamic leases, body substitution, binary binding) is in
[`secrets-tier3-design.md`](secrets-tier3-design.md).

## Don't steal

- **OpenShell's name-based placeholders.** They are weaker than `rvph_` tokens
  and depend on a sole-egress proxy that rv's loopback gateway is not.
- **OpenShell's credential-driver gRPC, Kubernetes drivers, and DB credstore
  envelope.** These are multi-tenant cluster plumbing. rv keeps values in the
  login Keychain or the provider and never at rest in its own files.
- **OpenShell's operator `GetProviderCredentials` RPC.** It exports plaintext by
  design, which contradicts rv's model.
- **Provider-contributed network policy.** In OpenShell, adding a credential
  opens egress for its binaries. rv's known-secret defaults grant no network
  (`Sources/RVIsolation/KnownSecretDefaults.swift:6-7`), and policy merges are
  restrict-only.
- **Infisical's KMS hierarchy, HSM, CASL, approval policies, and secret syncs.**
  These need a server and multiple actors. A single Mac already has Keychain
  and the Secure Enclave.
- **Infisical's keyring fallback.** It silently writes the vault passphrase
  into a config file when the keyring fails
  (`infisical-cli:packages/util/keyringwrapper.go:21-47`). rv fails closed.
- **Infisical's default `unmatched-host=allow`.** It is an onboarding
  convenience. rv's cage defaults to block.
- **Varlock's in-process redaction and `load --agent` masking.** Masking keeps
  the first two characters, and the agent's own process holds the values
  (`varlock:varlock/src/runtime/lib/redaction.ts:40-48`). Agent-facing output
  must carry names and status only.
- **Varlock's `exec()`, `$(cmd)`, and expression language in a committed
  schema** (`varlock:varlock/src/env-graph/lib/resolver.ts:485-519`). These turn
  the schema into a code-execution vector. rv's importer never executes
  anything and skips them with a note.
- **Varlock's daemon peer check by binary name, which fails open when the pid
  lookup fails** (`varlock:encryption-binary-swift/swift/Sources/VarlockEnclave/PeerIdentity.swift:22-44`).
  rv should bind to an audit token and code-signing requirement, and fail
  closed.
- **Varlock's 3650-day persisted CA and plugin download without integrity
  checks** (`varlock:varlock/src/proxy/runtime-proxy.ts:1155-1193`,
  `varlock:varlock/src/env-graph/lib/plugins.ts:597-715`).
- **Full transparent MITM as the primary path.** On macOS, Go and
  Security.framework clients ignore CA environment variables. The base-URL
  gateway stays primary, and MITM is a fallback for exact upstream hosts only.
