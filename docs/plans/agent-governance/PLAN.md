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
| 3 MCP governance | `governance/phase-3-mcp` | _opening_ | agent items done |
| 4 Enterprise client features | `governance/phase-4-enterprise` | _not opened_ | not started |
| 5 Launch readiness | human-owned | n/a | not started |

**Next action:** Phase 4 on `governance/phase-4-enterprise` (branch from `governance/phase-3-mcp`): start with `rv report --json`, then managed restrict-only policy. Check the Phase 3 PR's Linux CI first.

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

Branch `governance/phase-3-mcp` (from `governance/phase-2-secrets`). Code
lives in a new target `Sources/RVMCP` (deps: RVDomain, RVHistory,
RVIsolation for the Phase 2 secrets engine); tests in `Tests/RVMCPTests`
(portable, run by the Linux CI job). CLI: `Sources/RVCLI/Commands/MCPCommand.swift`.

### Config: `~/.config/rv/mcp.json` (owner-only 0600, strict decode, atomic writes)

```json
{
  "version": 1,
  "defaultDecision": "ask",
  "servers": [
    { "name": "github", "command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": { "LOG_LEVEL": "info" },
      "secrets": { "GITHUB_PERSONAL_ACCESS_TOKEN": "GITHUB_TOKEN" },
      "tools": { "default": "allow", "deny": ["delete_*"], "ask": ["create_pull_request"] },
      "sandbox": { "network": true, "writable": ["~/.npm"] } }
  ],
  "direct": ["stripe"],
  "blocked": ["filesystem"]
}
```

- `servers`: definitions rv runs behind its gateway. `secrets` maps an
  upstream env var to an rv secret name (Phase 2 `secrets.json`); values are
  resolved at spawn, never stored here.
- `direct`: servers the owner accepts running outside the gateway (e.g.
  remote OAuth servers). `blocked`: names that must not appear anywhere.
- Tool decision: deny glob > ask glob > allow glob > server `default` >
  top-level `defaultDecision` (default `ask`). Globs: `*` and `?`.

### Inventory statuses (`rv mcp list` / `rv mcp check`)
| status | meaning | check |
|---|---|---|
| governed | host entry runs `rv mcp serve --server <name>` | pass |
| direct | name is in `direct` | pass |
| bypass | rv has a definition, but the host runs the server itself | fail |
| unreviewed | rv has never seen it | fail |
| blocked | name is in `blocked` | fail |

Redaction: env and header values never shown (names only); URLs shown as
scheme://host; args redacted after secret-named flags (`--api-key X`,
`--token=X`) and when they look like tokens (known prefixes or long mixed
alphanumerics). Each entry also reports `plaintextCredentials` (names of
env vars / flags that hold literal secret-looking values) so the owner can
move them into rv secrets with `rv mcp import`.

### Gateway behavior (`rv mcp serve [--server NAME]...`)
- stdio, newline-delimited JSON-RPC 2.0. Lines ≤ 64 MiB, JSON depth ≤ 64.
- Gateway answers `initialize` itself (capabilities: `tools.listChanged`),
  initializes each upstream with its own ids, consumes
  `notifications/initialized`, answers `ping`.
- `tools/list`: fans out to every upstream (following `nextCursor`),
  hides denied tools, names them `<server>__<tool>` when more than one
  server is served (one server keeps its native names).
- `tools/call`: allow → forwarded with a gateway id, response mapped back;
  deny → result `isError: true` with the reason; ask → a pending approval
  (`~/.config/rv/mcp-approvals.json`, bound to server + tool + SHA-256 of
  canonical arguments) and `isError: true` telling the user to run
  `rv mcp approve <id>` (once) or `--always` (adds the tool to the server's
  allow list), then retry.
- Upstream responses are scrubbed of every secret value the upstream was
  given (raw and JSON-escaped forms) before reaching the agent.
- Other methods → -32601. Upstream server→client requests → -32601 back to
  the upstream (gateway declares no client capabilities). Client
  `notifications/cancelled` is mapped to the upstream id. Upstream
  `notifications/tools/list_changed` is forwarded.
- Every `tools/call` is audited as `mcp.call` (server, tool, decision,
  duration ms, argument keys only, isError, approval id).

### 3.1 Inventory: `rv mcp list`, `rv mcp check`
- [x] `MCPConfiguration` (mcp.json model, strict decode, atomic 0600 write via the shared `OwnerOnlyFile` in RVIsolation): `Sources/RVMCP/MCPConfiguration.swift`; order-keeping `JSONValue` (strict + JSONC): `JSONValue.swift`
- [x] Readers (`Sources/RVMCP/MCPInventory.swift`, TOML in `MiniTOML.swift`): Claude Code (`~/.claude.json` `mcpServers` + `projects[dir].mcpServers`,
      project `.mcp.json`), Claude Desktop, Cursor (`~/.cursor/mcp.json`,
      project `.cursor/mcp.json`), Codex (`~/.codex/config.toml`
      `[mcp_servers.*]`, minimal TOML reader), OpenCode (`opencode.json` `mcp`),
      Gemini (`~/.gemini/settings.json`), Antigravity
      (`~/.gemini/antigravity/mcp_config.json`), VS Code (`mcp.json` `servers`),
      Windsurf (`~/.codeium/windsurf/mcp_config.json`)
- [x] Redaction + plaintext-credential detection: `MCPRedaction.swift`
- [x] Status per entry (+ `dangling`: routes through rv to an undefined server; `disabled`); `rv mcp list|check` in `Sources/RVCLI/Commands/MCPCommand.swift` (check also fails on unreadable host files)
- [x] Tests: `Tests/RVMCPTests` (JSONValue, MiniTOML, MCPConfiguration, MCPRedaction, MCPInventory: 23). Real binary on this Mac: 23 entries in 7 host files, Codex `--api-key` masked, 2 plaintext credentials flagged

### 3.2 Gateway: `rv mcp serve`, approvals
- [x] `JSONValue` + framing with bounds; pure gateway core (state machine:
      client/upstream messages in → messages + audit out): `Sources/RVMCP/MCPGatewayCore.swift`
- [x] Runtime: spawn upstreams (Foundation `Process`, pipes, stderr passthrough),
      Phase 2 secrets in env, line readers (64 MiB line cap), shutdown when the client
      closes stdin (close upstream stdin → SIGTERM after 2 s → SIGKILL): `MCPGatewayRuntime.swift`
      (the one class in RVMCP; preflight allows that file only)
- [x] Policy + approvals store (`~/.config/rv/mcp-approvals.json`, flock, 24 h, grant bound to the
      SHA-256 of canonical arguments, consumed once): `MCPApprovals.swift`; `rv mcp pending`,
      `rv mcp approve <id> [--always]` (`--always` moves the tool to the allow list), `rv mcp deny <id>`
- [x] Response scrubbing of secret values (`[redacted:NAME]`)
- [x] Audit `mcp.call` (source `mcp-gateway`; argument keys only)
- [x] Tests: L1 core (`MCPGatewayCoreTests`), L2 python3 fixture through the real runtime
      (`MCPGatewayRuntimeTests`, gated on python3). E2E on this Mac: MCP Inspector CLI +
      `@modelcontextprotocol/server-everything` (deny hid `get-env`, prefixed names), Claude Code
      `claude mcp list` → Connected, Codex exec (gpt-5.5) saw only allowed tools, `whoami` paused for
      approval, both calls in `rv audit tail --kind mcp.call`; the secret value never reached the
      audit or approvals file

### 3.3 `rv mcp import` / `rv mcp setup` / `--undo`
- [x] `import --host H [--server N] [--allow-tools] [--dry-run]`: copy host definitions into mcp.json
      (`MCPImport` in `Sources/RVMCP/MCPHostSetup.swift`). Literal credential env values become
      Keychain-backed rv secrets (keep the variable name; `<SERVER>_<VAR>` on collision);
      credential flag values and bare tokens in args become `${secret:<SERVER>_<FLAG>}` /
      `${secret:<SERVER>_ARG_<n>}`. Order: Keychain first (abort with nothing written on failure),
      then secrets.json, then mcp.json. Imported servers ask for every tool unless `--allow-tools`.
- [x] `${secret:NAME}` in mcp.json args: validated on load, substituted by `MCPLaunchPlanner`,
      undefined names refuse to launch, values join the scrub list. Honest limit: an arg value
      is visible in `ps` to the same user; prefer `secrets` (env) when the server supports it.
- [x] `setup --host H [--server N] [--rv-path P]`: rewrite JSON host configs so mcp.json servers
      run `<rv> mcp serve --server <name>` (opencode `command` array shape, `type` kept). Undo
      manifest `~/.config/rv/mcp-setup.json` (owner-only) holds each original entry and is saved
      before the host file is rewritten; host files keep their mode; files with comments/trailing
      commas are refused untouched. `--undo` restores each entry only if it still equals what rv
      wrote. Codex TOML: prints `codex mcp remove/add` lines instead.
- [x] Tests: `MCPImportTests` (4), `MCPHostSetupTests` (4), `Tests/RVCLITests/MCPCommandTests` (4:
      import → setup takes check from failing to passing with the token only in the fake Keychain,
      dry run and Keychain failure write nothing, approve once/always, rv path). E2E with the real
      binary in a temp HOME: check fails (3 unreviewed) → import cursor → setup cursor → Cursor's
      rewritten entry launched by MCP Inspector ran `echo` through rv (audited) → `--undo` restored
      the original JSON → second undo is a no-op; Codex printed the manual line

### 3.4 Sandboxed upstreams
- [x] `sandbox` on a server definition (`Sources/RVMCP/MCPSandbox.swift`): spawn through
      `/usr/bin/sandbox-exec` with a generated profile: writes only to a per-server scratch dir
      (`~/Library/Caches/rv-mcp/<name>`, also the working directory), temp dirs, package caches
      and listed `writable` paths; reads denied for credential dirs, browser profiles, Keychains,
      other hosts' MCP configs and the rv config dir; `network: false` → `(deny network*)`.
      Linux fails closed (refuses to launch a server that asks for a sandbox).
      Honest limit: allow-default profile (not deny-default) so npx/uvx work;
      no per-host egress allowlist yet.
- [x] Tests: L2 `MCPSandboxLiveTests` (macOS): a caged shell cannot read a `~/.ssh` stand-in or
      the rv config, cannot write outside scratch, can write inside scratch

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
- 2026-10-12: Linux CI caught `WorkspaceLeftovers.swift` using macOS-only
  `WorkspaceAttachment`; gated on Phase 1, merged forward into Phase 2.
  Linux `swift test` then passed on both PRs (gateway included). Phase 3.1
  inventory landed: new `RVMCP` target, `rv mcp list|check`.
- 2026-10-12: Phase 3.2–3.4 landed: gateway core + runtime (`rv mcp serve`),
  approvals (`pending|approve [--always]|deny`), `mcp.call` audit, secret
  scrubbing, `${secret:NAME}` args, `rv mcp import|setup [--undo]`, Seatbelt
  cage for upstreams. Suites: RVMCPTests 49, RVCLITests 819, preflight 0
  failures (allowlisted `MCPGatewayRuntime.swift` as a process supervisor).
  E2E evidence under 3.2/3.3. Linux not compiled locally (no container
  running); relying on CI.
- 2026-10-13: Rereview of PR #394. Named each ledger writer (only `blocks`,
  `allow-once`, and `pending-approvals` are `FileLockedJSONLStore`). Seatbelt
  ground truth now says outbound connect is loopback TCP and the listen rule
  also permits LAN bind/listen/accept. Phase 2.2 matches D5: the gateway
  refuses upstream redirects. Phase 0 open-PR and close-#393 boxes checked.
  Docs only. Next: merge #394, then start Phase 1.
- 2026-10-13: Merged that rereview into `governance/phase-1-sandbox`. Phase 0
  stays in progress until #394 merges. Phase 1 agent items stay on this
  branch (#395).
