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
| 1 Trustworthy sandbox | `governance/phase-1-sandbox` | _not opened_ | not started |
| 2 Secrets the agent can't leak | `governance/phase-2-secrets` | _not opened_ | not started |
| 3 MCP governance | `governance/phase-3-mcp` | _not opened_ | not started |
| 4 Enterprise client features | `governance/phase-4-enterprise` | _not opened_ | not started |
| 5 Launch readiness | human-owned | n/a | not started |

**Next action:** Phase 0 checklist is done. Stay in progress until
[PR #394](https://github.com/christopherkarani/rv/pull/394) merges, then start
Phase 1. Do not reopen this PR or re-close #393.

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
- [x] Commit + push `plan/agent-governance`, open PR
- [x] Comment on and close PR #393 linking the plan PR (keep branch)

---

## Phase 1: Trustworthy sandbox (macOS)

Goal: an enterprise security reviewer can see what the cage blocked, trust it
cleans up after crashes, and read an accurate acceptance matrix.

### 1.1 Unified audit, read side: `rv audit`
- [ ] `RVAuditEvent` value type (schema `rv.audit.v1`): `time`, `kind`
      (`launch|exit|egress.denied|admission|secret.use|mcp.call|approval|policy`),
      `workspace`, `runtime`, `agent`, `decision`, `subject`, `reason`,
      `source` (ledger file), `detail` (flat string map, no secrets)
- [ ] Readers that map each existing ledger line to `RVAuditEvent`
      (egress-denials, runtime-admission, workspace-sessions, runtime-sessions,
      agent-instances, blocks, allow-once); tolerate unknown/old lines
- [ ] `rv audit tail [-n N] [--since DUR] [--kind K] [--json]` merged by time
- [ ] `rv audit export --since DUR --format jsonl` (stdout) for SIEM ingest
- [ ] Tests: mapping per ledger from fixture lines, merge ordering, filters,
      robot document shape, malformed-line tolerance
- [ ] L2 evidence: run a contained child that hits a denied host, then
      `rv audit tail --kind egress.denied` shows it

### 1.2 Crash safety: no leftovers after host death
- [ ] Global leftover scan: on any workspace open/doctor, find orphaned rv
      volumes/process groups from dead hosts across **all** projects (today
      only the same project recovers)
- [ ] `rv doctor` reports leftovers; `rv workspace recover --all` cleans them
- [ ] Tests: synthetic stale session records → detection + cleanup plan

### 1.3 Re-enable disabled end-to-end coverage
- [ ] Investigate a test-only peer-trust seam that cannot be reached by
      production binaries (dependency injection into `WorkspaceHostServer`
      in-process; no env var or user file may grant a role)
- [ ] Re-enable the in-process subset of the 55 `TRANSITIONAL-PEER-AUTH` tests;
      document why subprocess ones stay L3-only
- [ ] Rename stale `knownGap…` tests to what they actually assert

### 1.4 Accurate security docs
- [ ] Refresh `docs/security/runtime-acceptance.md` against current code
      (closed: mach-lookup; accepted residual: /Users metadata read; open:
      control-plane paths writable, Linux; Seatbelt limit: LAN listen)

### 1.5 Protected control-plane paths (coordinate: touches `SeatbeltProfile`)
- [ ] Deny cage writes to workspace `.git/hooks`, `.rv/**`, and rv config;
      flip `knownGapWorkspaceGitHooksAndRVConfigurationRemainWritable`
      into an enforcing test

### 1.6 Human-owned
- [ ] Apple Developer ID + notarization in `release.sh` (needs certificate)
- [ ] Identity on the default launch door (after `impro-ref` lands; touches
      `WorkspaceSessionSupervisor`)
- [ ] Linux enforcement (backlog, XL)

Exit criteria: `rv audit tail` shows real denials from a real cage (L2);
leftover scan proven by test; docs match code; CI green.

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
- [ ] `SecretsConfiguration` model + strict loader (owner-only file checks,
      duplicate names, env-name grammar, https upstream only, ≤32 secrets)
- [ ] Providers behind `SecretValueProvider` protocol, each with timeout and
      typed errors; never log values
- [ ] `rv secrets list` (name, source kind, delivery, bound upstream, status;
      never values), `rv secrets check` (resolve each, show fingerprint),
      `rv secrets set NAME` (stdin, no echo, stores in Keychain `rv.secrets`),
      `rv secrets remove NAME`
- [ ] Install key `~/.config/rv/audit.key` (32 random bytes, 0600) and
      `SecretFingerprint` = first 16 hex of HMAC-SHA256
- [ ] Tests: decode/validation matrix, provider stubs, CLI output, real
      Keychain round trip (set → check → remove) on macOS

### 2.2 Placeholder gateway (boundary injection)
- [ ] `SecretGateway` loopback HTTP/1.1 listener per workspace host;
      routes `/s/<binding>/<path>` to the binding's upstream origin
- [ ] Per-runtime placeholder minting; substitution only of placeholders
      minted for that runtime + binding, in headers and query; request
      without a valid placeholder is rejected (no open relay)
- [ ] Upstream via URLSession (ephemeral, no cookies/cache/proxy; the gateway
      refuses upstream redirects); streaming responses (SSE)
- [ ] Response scrubbing of the real value across chunk boundaries
- [ ] Audit each request as `secret.use` (`secrets-audit.jsonl`): secret name,
      upstream host, method, path (no query), status, bytes, fingerprint
- [ ] Wire into launch: profile `secrets` → placeholders + base-URL env in
      the cage env (minimal seam in the env builder)
- [ ] Tests: L1 parser/substitution/scrub; L2 real cage `curl`s the gateway
      with only the placeholder and a local upstream sees the real value;
      L4 live `postman-echo.com` echo proves swap + scrub; negative tests
      (wrong runtime token, other host, redirect, oversize headers)

### 2.3 Leak checks
- [ ] `rv secrets scan [PATH]`: exact-match scan of a tree for any value rv
      can resolve (reports file + line + secret name, never the value)

### 2.4 Later (not this phase)
- Transparent mode (local CA + CONNECT termination) for SDKs without base-URL
  support; Varlock `.env.schema` import; Vault dynamic secrets with leases.

Exit criteria: demo where an agent inside the cage calls a real API with a
placeholder, the call succeeds, `env` inside the cage shows no real value,
the response never contains it, and `rv audit tail --kind secret.use` shows
the call with a fingerprint.

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
- 2026-10-13: Rereview of PR #394. Named each ledger writer (only `blocks`,
  `allow-once`, and `pending-approvals` are `FileLockedJSONLStore`). Seatbelt
  ground truth now says outbound connect is loopback TCP and the listen rule
  also permits LAN bind/listen/accept. Phase 2.2 matches D5: the gateway
  refuses upstream redirects. Phase 0 open-PR and close-#393 boxes checked.
  Docs only. Next: merge #394, then start Phase 1.
