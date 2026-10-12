# Agent Governance Plan: sandbox → secrets → MCP → enterprise

Living plan. Every agent working on this effort reads **Resume here** first,
works the next unchecked box, and appends to **Progress log** before stopping.

- Owner: Chris Karani
- Started: 2026-10-12
- Worktree: `/Users/chriskarani/CodingProjects/rv-governance`
  (the main checkout `/Users/chriskarani/CodingProjects/rv` holds the owner's
  uncommitted `impro-ref` work: **never edit, stash, reset, or commit there**)
- Supersedes: [PR #393](https://github.com/christopherkarani/rv/pull/393)
  (closed, branch `worktree/clear-stone-fd72` kept as a harvest source)

---

## Resume here

| Phase | Branch | PR | Status |
|---|---|---|---|
| 0 Plan + reset | `plan/agent-governance` | [#394](https://github.com/christopherkarani/rv/pull/394) | in progress |
| 1 Trustworthy sandbox | `governance/phase-1-sandbox` | [#395](https://github.com/christopherkarani/rv/pull/395) | agent items done; PR open |
| 2 Secrets the agent can't leak | `governance/phase-2-secrets` | [#413](https://github.com/christopherkarani/rv/pull/413) | agent items done (PR open); L3 demo needs owner trust |
| 3 MCP governance | `governance/phase-3-mcp` | _not opened_ | not started |
| 4 Enterprise client features | `governance/phase-4-enterprise` | _not opened_ | not started |
| 5 Launch readiness | human-owned | n/a | not started |

**Next action:** check the Linux CI job on #413 (the gateway was never compiled on Linux locally: Docker was down). Then Phase 3.1: branch `governance/phase-3-mcp` from `governance/phase-2-secrets`, start `rv mcp list`.

Gotcha: never run the `rv` binary with a fake `HOME` on a path that writes to
the Keychain (`rv secrets set`). macOS opens a SecurityAgent "keychain not
found" dialog and the process hangs. In-process tests use an injected
`SecretKeychainWriter`; the real Keychain is covered by `RV_LIVE_KEYCHAIN=1`.

Branching rule: each phase branch starts from the previous phase branch (or
`origin/main` if the previous phase merged). Each phase PR targets the previous
phase branch until that merges, so every PR shows only its own diff. Rebase
forward after merges.

---

## Handoff protocol (read before touching code)

1. `cd /Users/chriskarani/CodingProjects/rv-governance && git status && git log --oneline -5`.
2. Read **Resume here**, then the checklist of the active phase. The first
   unchecked box is your task. Boxes are checked only when code is committed
   and its tests pass locally.
3. Build: `Scripts/swift-6.4 build` (debug, ~2 min cold). Test a slice:
   `Scripts/swift-6.4 test --filter <Suite>`. Full gate: `Scripts/gate.sh`.
   Preflight alone: `Scripts/preflight.sh`.
4. Before committing: preflight must pass. Rules it enforces (abridged):
   no `NSHomeDirectory`, no `try!`/force unwrap/`as!`/`fatalError`/IUO/
   `@_exported`; value types only outside Service/Policy/Analytics/Isolation/
   TUI/OperatorUI; RVEngine purity; test-target dependency limits
   (`RVIsolationTests` → RVIsolation + rv-isolation-exec + rv-pty-claim only;
   `RVCLITests`/`RVServiceTests` → 2 deps); a single CLI surface named `rv`.
5. New CLI subcommands must update **all** of: `Sources/RVCLI/RV.swift`
   subcommand list, `Sources/RVCLI/Help/HelpCatalog.swift`,
   `HelpDispatch.swift`, `Resources/Completions/rv.{zsh,bash,fish}`
   (enforced by `CompletionsCatalogTests`). Copy structure from
   `SafetyCommand` / `BlocksCommand` (`FormatFlags`, `CommandContext`,
   `RobotDocument`).
6. Append a dated entry to **Progress log**: what landed, test evidence
   (command + pass count), what is next, anything surprising.
7. Commit plan updates together with the code they describe.

### Testing levels (what "tested end to end" means here)

| Level | What | Needs |
|---|---|---|
| L1 unit | Swift Testing suites | nothing |
| L2 real cage | Spawn a real Seatbelt-contained child via the supervisor/admission APIs (pattern: `Tests/RVIsolationTests/ContainedRuntimeEnvironmentTests.swift`, `RuntimeAdmissionTests.swift`) and observe from inside the sandbox | macOS |
| L3 product | `rv opencode` / `rv workspace run` through the persistent `rv-workspace-host` | **admin-installed peer trust** (below) |
| L4 live network | Real public HTTPS upstream (e.g. `https://postman-echo.com`, `https://httpbin.org/anything`) | internet |

**L3 requires the owner.** The workspace host only admits peers whose code
identity matches `/Library/Application Support/RV/peer-trust.json`
(root-owned; `ProtectedPeerTrustConfiguration`, `WorkspacePeerAuthenticator.swift`).
This Mac has a development install from 2026-10-03 pinning old CDHashes, so a
fresh build is refused (`unauthorizedClient`). To L3-test a new build the owner
runs, from the worktree after `Scripts/swift-6.4 build`:

```bash
sudo Scripts/phase2a-development-trust.sh uninstall
sudo Scripts/phase2a-development-trust.sh install \
  --host .build/debug/rv-workspace-host --service .build/debug/rvd \
  --cli .build/debug/rv --ui .build/debug/rv-operator-ui
# then use the pinned CLI:
"/Library/Application Support/RV/phase2a-development/rv" opencode -- /bin/sh
```

Agents never run sudo. When L3 evidence is needed, stop and ask the owner;
meanwhile prove the same behavior at L2.

---

## Vision (what we are selling)

> rv is the security layer every AI coding agent runs inside. Agents work
> freely, but they can't touch what they shouldn't, can't see real secrets,
> and can only use approved tools. Every action is recorded.

Three pillars, one product:

1. **Contain** (Phase 1): deny-by-default sandbox with crash safety and a
   tamper-resistant record of what happened.
2. **Secrets** (Phase 2): the agent receives placeholders; rv swaps in the
   real value only at the network boundary, only toward the host the secret
   is bound to. Values come from where enterprises already keep them
   (Keychain, 1Password, Vault, AWS); rv is not a vault.
3. **Tools** (Phase 3): one MCP gateway; every MCP server inventoried,
   approved or blocked; every tool call allowed / asked / denied and audited;
   upstream servers get credentials from Phase 2, never from config files.

Enterprise layer (Phase 4): admin-managed policy that users can't loosen,
exportable audit, fleet reporting. The hosted control plane (SSO, SCIM,
dashboard, approvals routing) is a separate product spec'd here, not built.

What we borrow: Varlock's schema-first secrets UX and placeholder idea,
Executor's MCP catalog + per-tool approval model, Vault's provider model,
leases-as-TTL thinking and audit rigor (HMAC'd values, never plaintext).

---

## Architecture (target)

```
operator ── rv CLI ──► rv-workspace-host (per workspace, persistent)
                          │
                          ├─ Seatbelt cage (agent process group)
                          │     env: HTTPS_PROXY=127.0.0.1:P1
                          │          STRIPE_API_BASE=http://127.0.0.1:P2/s/<binding>
                          │          STRIPE_SECRET_KEY=rvph_<random>   ◄ placeholder only
                          │
                          ├─ EgressProxy :P1   (opaque CONNECT, public-HTTPS policy)
                          ├─ SecretGateway :P2 (Phase 2: swap placeholder → real value,
                          │                     only to the bound upstream, scrub responses,
                          │                     HMAC fingerprint audit)
                          └─ admission broker (fd3/4/5)

agent host (Cursor, Claude Code, Codex…) ── stdio ──► rv mcp serve  (Phase 3)
                                                        ├─ policy: allow / ask / deny per tool
                                                        ├─ upstream MCP servers (sandboxed, Phase 3.5)
                                                        └─ audit → unified event stream

~/.config/rv/                       user files (0600, owner-only)
/Library/Application Support/RV/    admin-managed files (root-owned, Phase 4)
```

---

## Ground truth at start (origin/main 04b4740c, 2026-10-12)

Verified by reading code; refresh if main moves far.

**Network.** `Sources/RVIsolation/EgressProxy.swift` binds `127.0.0.1:0` per
workspace host; CONNECT is an opaque TLS relay, absolute-URI `http://` is
forwarded; policy `EgressHostPolicy.publicHTTPS` (ports 80/443, public-unicast,
loopback allowed). No TLS termination, no local CA. Cage env gets
`HTTPS_PROXY/HTTP_PROXY=http://127.0.0.1:<port>`, `NO_PROXY=localhost,127.0.0.1,::1`.
Seatbelt outbound connect is loopback TCP only. The loopback listen rule
(`allowingLoopbackBind`) also permits LAN bind, listen, and accept.

**Admission.** fd3 handshake, fd4 requests, fd5 responses; 4-byte BE length +
JSON. HTTP admission is GET + https only, no headers/body, executed host-side by
`HTTPDirectExecutor` (Network.framework, TLS, no auth/cookies/redirects). No
in-sandbox client shim.

**Secrets today.** `RuntimeResourceProfile.keychain` (service/account/field/env/
agents, max 8) read host-side by `KeychainReader`, injected as **real** env
values at spawn (`addingKeychainEnvironment`). `credentials` = file copies;
`environment` = hostVariable/literalValue. `ContainedEnvironmentPolicy.project`
strips secret-like host env. Compat path re-injects `ANTHROPIC_API_KEY`/
`META_API_KEY`; placeholder `rv-cage-gateway-placeholder` and
`ANTHROPIC_BASE_URL` passthrough (`SeatbeltProfile.swift` ~L629–648). The
identity/prepared launch path forbids credentials and keychain.

**Crypto.** Pure-Swift SHA-256 `RVDigest` (`HTTPAddress.swift`); CryptoKit
used in places on Darwin. swift-crypto is a Linux-only dependency. No NIO,
no swift-certificates.

**Ledgers** (`~/.config/rv/`). No unified event type. `blocks.jsonl`,
`allow-once.jsonl`, and `pending-approvals.jsonl` are `FileLockedJSONLStore`.
`runtime-admission.jsonl` is `appendAdmissionEvent` (flock + `O_APPEND`).
`workspace-sessions.jsonl`, `runtime-sessions.jsonl`, and
`agent-instances.jsonl` go through `RuntimeSessionLog.appendExclusiveLine`.
`egress-denials.jsonl` is an unlocked `FileHandle` append in
`EgressProxy.writeDenial` (no flock).

**Launch.** Contained: `rv opencode`, `rv workspace run`, TUI launchers
(claude/codex/opencode/muse, `RuntimeAgentEntries.known`); legacy path, no
AgentInstance. Named identity launch blocked ("operator permits not yet
available"). Linux refuses contained launch.

**Peer trust.** Host `adopt()` requires same uid + `componentRole != nil`
from the root-owned trust manifest; roles need hardened runtime and either
a team signature or a pinned development CDHash at a protected path. Release
script does not codesign/notarize, so a stock install cannot use contained
mode without the dev trust script.

**Test debt.** 55 tests disabled with `TRANSITIONAL-PEER-AUTH` (WorkspaceHost,
RuntimeTerminal, OpenCodeCommand frontend, WorkspaceTUIIntegration) because
test binaries have no component role. 3 `knownGap…` tests remain, two with
stale names. `docs/security/runtime-acceptance.md` is dated 2026-09-21 and
stale.

**MCP.** Nothing reads any MCP config anywhere. `rv setup` hosts: grok, pi,
opencode, claude, openclaw, hermes, codex, cursor, antigravity.

**PR #393 lessons** (why we restarted): it didn't build
(`SecretsLedger.swift:927`), failed preflight, the broker never received an
identity (`WorkspaceHostPrepareHandler.swift:79`), MCP was unreachable, config
files were rewritten on load, it hand-rolled AES-GCM/scrypt, spawned MCP
servers unsandboxed, digested secrets into an environment hash, and let a
sanitizer hide command text from approvers. Harvest list (port with tests,
keep MIT notices if code is copied from Executor/Varlock):
`SecretsRedaction`/labels, trimmed `SecretsLedger` (+HMAC values),
`OwnerOnlyFile` (+fsync), Vault HTTP client (minus leases), MCP tool policy
grammar, durable MCP approvals idea, JSON-RPC depth bound.

---

## Decisions log

| # | Decision | Why |
|---|---|---|
| D1 | Build on `main`, not PR #393 | #393 didn't build and its secrets path was unreachable; cherry-pick small pieces with tests |
| D2 | rv is not a vault | Enterprises already own Vault/1Password/AWS; we broker, never store (except opt-in Keychain via `rv secrets set`) |
| D3 | Boundary injection via a loopback **gateway** (base-URL rewrite) first; transparent TLS termination later | Proxy is opaque CONNECT with no CA; base-URL pattern already exists for Anthropic; no trust-store changes inside the cage |
| D4 | Placeholder = per-runtime random capability `rvph_<32 hex>` (optional vendor prefix) | A leaked placeholder is worthless outside that runtime and that upstream host |
| D5 | Gateway forwards only to the binding's configured upstream origin, refuses redirects, scrubs real values from responses | Stops the agent from exfiltrating the swapped value to another host |
| D6 | Audit never stores values; stores `HMAC-SHA256(install key, value)` prefix | Lets responders correlate leaks without a plaintext ledger (Vault model) |
| D7 | Secrets bind to launches through runtime-resource **profiles** (`secrets: [names]`), defined in `~/.config/rv/secrets.json` | Matches rv's explicit-profile model; no implicit selection by command name |
| D8 | MCP gateway is an stdio MCP server (`rv mcp serve`) that the agent host launches | Works with every host today; no host plugin needed |
| D9 | Linux contained launch deferred (backlog) | XL effort; enterprise pilots are macOS developer fleets first |
| D10 | Avoid editing files the owner has in flight on `impro-ref` unless required; keep such edits minimal seams and note them in the phase PR | Avoid merge pain; see Coordination |
| D11 | One PR per phase; split a phase into a stacked series if it exceeds ~5k changed lines | Reviewable units |
| D12 | Unified audit starts read-side (`rv audit` joins existing ledgers into one schema) before any writer changes | Delivers value without touching hot writers; Phase 2/3 writers emit the same schema natively |
| D13 | _Open, owner decides:_ how to restore the 55 disabled host E2E tests (CI with dev trust vs owner-run L3) | No safe in-code test seam exists |

### Coordination with `impro-ref` (owner's uncommitted work)

Files modified there (avoid or keep edits tiny): `PolicyCommand`, `HelpCatalog`,
`HelpDispatch`, `RV.swift`, `SetupUninstall`, `EgressPolicy`, `HTTPExchange`,
`ContainedEnvironmentPolicy`, `EgressProxy`, `HTTPDirectConnector`,
`IsolationApply`, `LandlockRuleset`, `RuntimeAdmission`, `RuntimeAdmissionSpawn`,
`SeatbeltProfile`, `SessionSupervisor`, `WorkspaceSessionSupervisor`,
`landlock_apply.c/h`, `PendingApprovalStore`, `PolicyWorkspace`, `RVPolicyPaths`,
`SecretAllowPaths`, `TypedRuleStore`, `GatedEvaluate`. New there: `rv egress`
command, `NetworkReviewQueue`, `EgressProposal`, `PolicyDiffRisk`.
`RV.swift`/`HelpCatalog`/`HelpDispatch`/completions edits are unavoidable for
new commands: they are append-only one-liners and resolve trivially.

---

## Phase 0: Plan and reset

Exit: this plan merged-or-open as a PR; PR #393 closed with a pointer.

- [x] Map secrets/network, CLI/launch, and sandbox gaps (three exploration passes)
- [x] Write this plan
- [x] Commit + push `plan/agent-governance`, open PR ([#394](https://github.com/christopherkarani/rv/pull/394))
- [x] Comment on and close PR #393 linking the plan PR (keep branch)

---

## Phase 1: Trustworthy sandbox (macOS)

Goal: an enterprise security reviewer can see what the cage blocked, trust it
cleans up after crashes, and read an accurate acceptance matrix.

### 1.1 Unified audit, read side: `rv audit`
- [x] `AuditEvent` (schema `rv.audit.v1`) in `Sources/RVHistory/AuditEvent.swift`:
      `time`, open `kind` vocabulary (prefix filters), `decision`, `subject`,
      `reason`, `workspace`, `runtime`, `agent`, `source`, `detail`
- [x] `AuditLedger` (`Sources/RVHistory/AuditLedger.swift`) maps blocks,
      egress-denials, runtime-admission, workspace-sessions, runtime-sessions,
      agent-instances, plus native `audit.jsonl`; skips unreadable lines; reads
      at most the newest 16 MiB per file. (`allow-once.jsonl` and
      `pending-approvals.jsonl` are rewritten tables, not event logs: skipped)
- [x] `AuditLog.append` native writer (0600, O_APPEND + flock) for Phase 2/3
- [x] Admission lines now carry `recordedAt` (stamped on the file copy only)
- [x] `rv audit [tail] [-n N] [--since 30m|24h|7d] [--kind K]... [--json]`
- [x] `rv audit export [--since] [--kind]` → JSON Lines
- [x] Tests: `AuditLedgerTests` (12), `AuditCommandTests` (13)
- [x] Real-binary evidence: `rv audit` on this Mac shows today's real hook
      denials (`core.git:reset-hard`) and lifecycle events; export emitted
      13,508 events for 7 days
- [ ] L3 evidence of an `egress.denied` line from a real cage (needs owner trust install)

### 1.2 Crash safety: no leftovers after host death
- [x] `WorkspaceHosts.leftovers()`: unclosed sessions across all projects
      with no live host (`Sources/RVIsolation/WorkspaceLeftovers.swift`)
- [x] `WorkspaceHosts.diskLeftovers()`: attached `rv-inode-*.sparseimage`
      images with no live host (hdiutil plist + kernel mount table, 15 s
      timeout), and image files nothing has attached
- [x] `rv workspace leftovers` report with safe next steps (never auto-deletes:
      stranded volumes can hold unpublished work)
- [x] Tests: `WorkspaceLeftoversTests` (6). Real run on this Mac found 1
      orphaned session, 133 stranded images (100 mounted), 484 unattached
      image files (~15 GB), all from test runs
- [ ] `rv doctor` line summarizing leftovers
- [ ] Test hygiene: RVIsolation tests write lifecycle/runtime records to the
      developer's real `~/.config/rv` (32 `WorkspaceSessionSupervisor.open`
      call sites use `.production`) and leak volumes. Touches
      `WorkspaceSessionSupervisor` (owner's in-flight file): do after
      `impro-ref` lands

### 1.3 Re-enable disabled end-to-end coverage
- [x] Investigated. The disabled tests spawn the real `rv-workspace-host`
      binary and connect from the test runner, which isn't hardened and so can
      never hold a component role. There's no safe in-code seam: anything a
      test can flip, an attacker can flip. **Owner decision needed (D13).**
- [ ] D13 option A: rewrite them to drive the pinned `rv` CLI as a subprocess,
      in a macOS CI job that installs dev peer trust with sudo (runners
      have passwordless sudo)
- [ ] D13 option B: keep them as an owner-run L3 checklist
- [x] Renamed stale `knownGap…` tests:
      `syntheticCredentialsOutsideTheWorkspaceCanBeNeitherReadNorOverwritten`,
      `cannotSignalAnUnrelatedProcess` (both pass on a real cage); updated
      `docs/security/adversarial-inventory.md`

### 1.4 Accurate security docs
- [x] Added a dated "Current status: 2026-10-12" table at the top of
      `docs/security/runtime-acceptance.md`; historical audit kept below

### 1.5 Protected control-plane paths (coordinate: touches `SeatbeltProfile`)
- [ ] Deny cage writes to workspace `.git/hooks`, `.rv/**`, and rv config;
      flip `knownGapWorkspaceGitHooksAndRVConfigurationRemainWritable`
      into an enforcing test

### 1.6 Human-owned
- [ ] Apple Developer ID + notarization in `release.sh` (needs certificate)
- [ ] Identity on the default launch door (after `impro-ref` lands; touches
      `WorkspaceSessionSupervisor`)
- [ ] Linux enforcement (backlog, XL)

Exit criteria: `rv audit tail` shows real denials (met with hook denials;
cage egress denial pending L3); leftover scan proven by test and real run
(met); docs match code (met); CI green (check on the PR).

---

## Phase 2: Secrets the agent can't leak

Goal: the agent never holds a real secret value, yet its SDKs work.

### Config: `~/.config/rv/secrets.json` (owner-only, strict decode, never rewritten on load)

```json
{
  "version": 1,
  "secrets": [
    {
      "name": "STRIPE_SECRET_KEY",
      "description": "Stripe test key",
      "source": { "keychain": { "service": "rv.secrets", "account": "STRIPE_SECRET_KEY" } },
      "delivery": {
        "gateway": {
          "upstream": "https://api.stripe.com",
          "baseURLEnv": "STRIPE_API_BASE",
          "placeholderPrefix": "sk_test_"
        }
      }
    },
    { "name": "GITHUB_TOKEN",
      "source": { "onePassword": { "reference": "op://Dev/GitHub/token" } },
      "delivery": { "gateway": { "upstream": "https://api.github.com", "baseURLEnv": "GITHUB_API_URL" } } },
    { "name": "DB_PASSWORD",
      "source": { "vault": { "path": "secret/data/app", "field": "db_password" } },
      "delivery": { "environment": {} } }
  ]
}
```

Sources: `keychain`, `hostEnvironment`, `onePassword` (`op read`),
`vault` (KV v2 over HTTPS, token from `VAULT_TOKEN`/`~/.vault-token`),
`awsSecretsManager` (`aws secretsmanager get-secret-value`). Delivery:
`gateway` (placeholder in cage; default and recommended) or `environment`
(real value in cage, explicit opt-in, flagged as weaker in `rv secrets list`).
Profiles in `runtime-resources.json` gain `"secrets": ["STRIPE_SECRET_KEY"]`.

### 2.1 Schema, providers, CLI
- [x] `SecretsConfiguration` model + strict loader (owner-only file checks,
      duplicate names, env-name grammar, https upstream only, ≤64 secrets,
      no two secrets exporting the same variable): `Sources/RVIsolation/SecretsConfiguration.swift`
- [x] Providers as one `SecretResolver` closure struct (`.live` dispatches by
      source kind; tests inject fakes), 30 s timeout and 1 MiB cap on CLI
      providers, typed `SecretResolutionError`; `SecretValue` prints
      `<redacted>`: `Sources/RVIsolation/SecretProviders.swift`
- [x] `rv secrets list` (name, source locator, delivery, agents, profiles
      using it; warns on profile refs to undefined secrets; never values),
      `rv secrets check` (resolve each, show fingerprint, exit 1 on failure),
      `rv secrets set NAME` (TTY no-echo prompt or stdin; stores in Keychain
      service `rv.secrets`; `--gateway URL --base-url-env VAR
      [--placeholder-prefix P]` or `--environment`; `--agent`, `--description`),
      `rv secrets remove NAME` (drops definition + Keychain item). JSON via
      `--json`. Code: `Sources/RVCLI/Commands/SecretsCommand.swift`; store
      helpers (atomic 0600 write, Keychain writer, locators, leak scanner):
      `Sources/RVIsolation/SecretStore.swift`. Registered in RV.swift,
      HelpDispatch, HelpCatalog, bash/zsh/fish completions.
- [x] Install key `~/.config/rv/audit.key` (32 random bytes, 0600, created
      lazily on first lease) and `SecretFingerprinter` = first 16 hex of
      HMAC-SHA256: `Sources/RVIsolation/SecretFingerprint.swift`
- [x] Tests: decode/validation matrix (`SecretsConfigurationTests`), real
      Keychain read via the live resolver (`SecretKeychainLiveTests`,
      `RV_LIVE_KEYCHAIN=1`)
- [x] Tests: `SecretsCommandTests` (list/check/set/remove/scan with an
      injected Keychain writer + resolver, dangling profile warning, bad
      flags), `SecretsCommandLiveKeychainTests` (`RV_LIVE_KEYCHAIN=1`: real
      Keychain set → check → remove). Real `rv` binary run against a temp
      HOME with a host-variable secret: list, check, scan, set errors,
      remove, unsafe file mode refused.
- [x] Linux portability: fingerprints are HMAC-SHA256 over the project's
      pure-Swift `RVDigest.sha256` (RFC 4231 vectors in
      `SecretLaunchBrokerTests`), not CryptoKit; `FoundationNetworking`
      import; Glibc socket constants; `send` + `MSG_NOSIGNAL`. Verified only
      by CI (no local Linux toolchain).

### 2.2 Placeholder gateway (boundary injection)
- [x] `SecretGateway` loopback HTTP/1.1 listener per workspace host, started
      lazily on the first gateway lease; routes `/s/<NAME>/<path>` to the
      secret's upstream origin: `Sources/RVIsolation/SecretGateway.swift`,
      pure logic in `SecretGatewayProtocol.swift`
- [x] Per-launch placeholder minting (`<prefix>rvph_<32 hex>`); substitution
      only of placeholders live for that secret, in target and header values
      (body untouched); no placeholder → 401, unknown/revoked → 403, other
      secret's placeholder → 403 (no open relay)
- [x] Upstream via URLSession (ephemeral, no cookies/cache, redirects returned
      to the client, not followed); streaming chunked responses; client
      `Accept-Encoding` stripped so scrubbing sees plaintext
- [x] Response scrubbing of the real value across chunk boundaries (body and
      header values)
- [x] Audit each request as `secret.use` into the unified `audit.jsonl`
      (`AuditLog.append`, so `rv audit tail --kind secret.use` shows it):
      secret, runtime, upstream host, method, path (no query), status, bytes,
      fingerprint. Leases also record a `staged` event with delivery + provider.
- [x] Wire into launch: `SecretLaunchBroker` (per workspace supervisor)
      leases profile `secrets` in `WorkspaceSessionSupervisor.spawn` before
      the state lock, binds the lease to the runtime ID inside the lock,
      revokes in `noteRuntimeEnded` and on spawn failure; entries ride the
      existing keychain env list. Identity path (`KeychainReader.denied`,
      `allowsSecrets=false`) refuses profiles that list secrets.
- [x] Fix found while wiring: profile credentials now replace an ambient host
      variable of the same name in the cage env (`addingKeychainEnvironment`);
      before, a host `OPENAI_BASE_URL`/passthrough key silently won.
      Runtime-owned and `*_PROXY` names are never replaced.
- [x] Tests: L1 `SecretGatewayProtocolTests` (parser, routing, substitution
      refusals, scrub at every split), `SecretGatewayTests` (real sockets +
      recording upstream: swap, scrub, chunked, Expect, HEAD, 413, revoked),
      `SecretLaunchBrokerTests`; L2 `SecretGatewayCageTests` (real Seatbelt
      cage `curl`s the gateway; upstream sees the real key; cage env, reply
      and audit never do; lease revoked at runtime end; undefined secret and
      denied path fail before spawn); L4 `SecretGatewayLiveTests`
      (`RV_LIVE_NETWORK=1`, postman-echo: wire carries real value, echo comes
      back scrubbed, 302 not followed)

### 2.3 Leak checks
- [x] `rv secrets scan [PATH]`: exact-match scan of a tree for any value rv
      can resolve (reports file + line + secret name, never the value; skips
      `.git`, `.build`, `node_modules`, `DerivedData`; ≤8 MiB per file,
      ≤100k files; values under 8 bytes skipped; exit 1 on findings)

### 2.4 Later (not this phase)
- Transparent mode (local CA + CONNECT termination) for SDKs without base-URL
  support; Varlock `.env.schema` import; Vault dynamic secrets with leases.

Exit criteria: demo where an agent inside the cage calls a real API with a
placeholder, the call succeeds, `env` inside the cage shows no real value,
the response never contains it, and `rv audit tail --kind secret.use` shows
the call with a fingerprint.

Exit evidence: L2 `SecretGatewayCageTests` covers cage → gateway → upstream
with the real key only on the wire and the `secret.use` record written via
`AuditLog.append`; `AuditCommandTests` covers `rv audit tail` rendering a
`secret.use` line from that schema. A live L3 demo through `rv workspace`
still needs the owner's trust install.

---

## Phase 3: MCP governance

### Config: `~/.config/rv/mcp.json`

```json
{
  "version": 1,
  "defaultDecision": "ask",
  "servers": [
    { "name": "github", "command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"],
      "secrets": { "GITHUB_PERSONAL_ACCESS_TOKEN": "GITHUB_TOKEN" },
      "tools": { "default": "allow", "deny": ["delete_*"], "ask": ["create_pull_request"] } }
  ],
  "blocked": ["filesystem"]
}
```

### 3.1 Inventory: `rv mcp list`
- [ ] Readers for Claude Code (`~/.claude.json` user + per-project, `.mcp.json`),
      Claude Desktop, Cursor (`~/.cursor/mcp.json`, `.cursor/mcp.json`),
      Codex (`~/.codex/config.toml` `[mcp_servers.*]`), OpenCode
      (`opencode.json` `mcp`), Gemini/Antigravity (`~/.gemini/settings.json`),
      VS Code (`mcp.json` `servers`), Windsurf
- [ ] Redact args/URLs/env (names only) before display
- [ ] Status against `mcp.json`: approved / blocked / unreviewed;
      `rv mcp check` exits non-zero when unreviewed or blocked servers exist
- [ ] Tests: fixture configs per host, redaction, status

### 3.2 Gateway: `rv mcp serve`
- [ ] stdio JSON-RPC 2.0 server (initialize, tools/list, tools/call,
      notifications), depth/size bounds
- [ ] Spawn approved stdio upstreams with Phase 2 secrets in their env;
      aggregate `tools/list` as `<server>__<tool>`
- [ ] Per-tool allow / ask / deny (glob); `ask` → denied with an instructive
      error plus a pending approval, `rv mcp approve <id>` grants once or
      always
- [ ] Audit every call as `mcp.call` (server, tool, decision, duration,
      argument keys only)
- [ ] Tests: L1 protocol + policy; L2 real upstream (a tiny stdio MCP server
      fixture) through the gateway

### 3.3 `rv mcp setup` / `--undo`
- [ ] Rewrite a host's MCP config to route approved servers through
      `rv mcp serve --server <name>`, with backup and exact undo

### 3.4 Sandboxed upstreams
- [ ] Run stdio upstreams in a Seatbelt cage (scratch dir, egress via proxy)

Exit criteria: Cursor or Claude Code on this Mac lists tools through
`rv mcp serve`; a denied tool is blocked; every call shows in `rv audit`.

---

## Phase 4: Enterprise client features

- [ ] Managed policy: root-owned `/Library/Application Support/RV/managed/`
      (`secrets.json`, `mcp.json`, egress additions) merged restrict-only over
      user files: org blocks win, users can't approve what org blocks
- [ ] Optional signed bundles: org public key pinned in managed dir;
      unsigned or bad-signature bundles refused
- [ ] `rv audit export --format ocsf` and `rv audit forward --to URL`
      (batched HTTPS POST, at-least-once with a cursor file)
- [ ] `rv report --json`: version, policy hashes, MCP inventory status,
      secret binding names, sandbox health; suitable for MDM collection
- [ ] Control plane (SSO/SCIM/dashboard/approval routing): spec doc only

---

## Phase 5: Launch readiness (human-owned)

- [ ] External pentest of cage + gateway + MCP gateway
- [ ] SOC 2 Type I readiness; security whitepaper
- [ ] 3–5 design partners; pricing (per-seat + enterprise tier)
- [ ] Legal review of MIT attributions for any harvested code
- [ ] Windows strategy decision

---

## Risks

| Risk | Mitigation |
|---|---|
| SDK ignores base-URL env | Document per-SDK var; transparent mode later (2.4) |
| Owner's `impro-ref` conflicts | D10; small seams; rebase notes in PR body |
| L3 tests need sudo | L2 proofs + owner-run checklist |
| Streaming/HTTP2 edge cases in gateway | URLSession upstream; SSE tests; size/time limits |
| MCP spec churn | Keep gateway to core methods; pass-through unknown notifications |

---

## Progress log (append-only, newest last)

- 2026-10-12: Worktree created at origin/main 04b4740c; baseline debug build
  OK (~127 s). Three exploration passes done (findings in Ground truth).
  Found 55 `TRANSITIONAL-PEER-AUTH` disabled tests and confirmed L3 needs
  the owner to reinstall dev peer trust with sudo. Plan written.
- 2026-10-12: Phase 1 agent items landed on `governance/phase-1-sandbox`:
  `rv audit` (tail/export, 7 sources), admission `recordedAt`,
  `rv workspace leftovers` (sessions + disk images), stale knownGap renames,
  acceptance doc status table. Tests: AuditLedgerTests 12, AuditCommandTests
  13, WorkspaceLeftoversTests 6, the 3 adversarial cage tests, help and
  completions suites: all pass. Found: tests leak volumes and write to the
  real `~/.config/rv` (logged as a 1.2 item). D13 opened for the disabled
  E2E tests.
- 2026-10-12: Phase 2 engine landed on `governance/phase-2-secrets`: config,
  providers, fingerprints, gateway, broker, launch seam, credential-override
  fix. 28 secrets tests + live (network, keychain) pass. RVIsolation now
  depends on RVHistory (for `AuditLog`). Next: `rv secrets` CLI.
- 2026-10-12: Phase 2 CLI + leak scan landed: `rv secrets
  list|check|set|remove|scan`, Linux-portable HMAC fingerprints. Suites:
  secrets 33 + CLI/Policy/Domain/isolation neighbors 1885, preflight 0
  failures. A fake-HOME binary run of `rv secrets set` hung on a macOS
  Keychain dialog (killed; login keychain untouched); see the gotcha under
  Resume here.
- 2026-10-13: Rereview of PR #394. Named each ledger writer (only `blocks`,
  `allow-once`, and `pending-approvals` are `FileLockedJSONLStore`). Seatbelt
  ground truth now says outbound connect is loopback TCP and the listen rule
  also permits LAN bind/listen/accept. Phase 2.2 matches D5: the gateway
  refuses upstream redirects. Phase 0 open-PR and close-#393 boxes checked.
  Docs only. Next: merge #394, then start Phase 1.
- 2026-10-13: Merged that rereview into `governance/phase-1-sandbox`. Phase 0
  stays in progress until #394 merges. Phase 1 agent items stay on this
  branch (#395).
