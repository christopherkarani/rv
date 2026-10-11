# Secrets broker + executor-style MCP: security acceptance

Date (UTC): 2026-10-11. Spec: `spec/spec-architecture-secrets-executor-mcp.md` v1.1.
Scope: T1–T11 plus plan amendment T6b. Method: every verdict below links to the
exact evidence log proving it; residual risks are stated without mitigation claims.

## Evidence files

All paths relative to `docs/security/`.

| File | Content |
|---|---|
| [evidence-index.md](evidence/secrets-mcp/evidence-index.md) | Prior gatherer index for logs 1–3 (plus addendum for logs 4–6) |
| [rvisolation-full.log](evidence/secrets-mcp/rvisolation-full.log) | Full RVIsolation suite: 990 tests (945 passed, 3 baselined failures, 42 pre-existing TRANSITIONAL-PEER-AUTH `.disabled` skips unrelated to secrets/MCP), 58 suites, 222.3 s, exit 1 with only the 3 baselined environmental failures (line 2181) |
| [redaction-adversarial.log](evidence/secrets-mcp/redaction-adversarial.log) | Redaction + audit + adversarial suites: 222 passed, 0 failed, exit 0 (lines 88, 320, 554) |
| [token-in-log-grep.log](evidence/secrets-mcp/token-in-log-grep.log) + [token-patterns.txt](evidence/secrets-mcp/token-patterns.txt) | 97 fixture literals grepped over all three test-output logs: 37 + 81 hits, all explained as runner echoes, 0 unexplained (coverage triage in the log addendum) |
| [coverage-secrets.log](evidence/secrets-mcp/coverage-secrets.log) | Secrets-filtered run with coverage: 748 tests, 26 suites, exit 0 (lines 176, 1048, 1280, 1712) |
| [coverage-report.txt](evidence/secrets-mcp/coverage-report.txt) | Per-binary llvm-cov reports (nonzero rows) backing the coverage appendix |
| [static-checks.log](evidence/secrets-mcp/static-checks.log) | Structural-check transcript (imports, caps, permissions, zero-hit greps) |
| [full-tree.log](evidence/secrets-mcp/full-tree.log) | Fully unfiltered `swift test`: all targets green except exactly the 4 baselined failures (3 RVIsolation environmental + 1 out-of-scope RVCLI probe) |

Toolchain: Apple Swift 6.4, swift-driver 1.168.6, arm64 macOS
([static-checks.log](evidence/secrets-mcp/static-checks.log)).

## 1. Threat-model checklist

One row per spec requirement ID. Verdicts: PASS, PARTIAL (qualified), OPEN (still
unresolved), UNVERIFIED (no evidence in this set).

### Functional requirements

| ID | Ticket | Claim | Verdict | Evidence |
|---|---|---|---|---|
| REQ-001 | T1 | Provider trait is types-only, `Sendable`, no IO | PASS | [static-checks.log](evidence/secrets-mcp/static-checks.log) (zero imports); [coverage-secrets.log](evidence/secrets-mcp/coverage-secrets.log) `SecretsProviderTests` passed; [coverage-report.txt](evidence/secrets-mcp/coverage-report.txt) 100% lines |
| REQ-002 | T4 | File provider resolves from the 0600 store, default, offline | PASS | [rvisolation-full.log:1180](evidence/secrets-mcp/rvisolation-full.log) `FileSecretsProvider` passed; [static-checks.log](evidence/secrets-mcp/static-checks.log) 0o600 + 65_536 |
| REQ-003 | T4 | Keychain via broker-backed reader; Linux returns nil fail-closed | PARTIAL | macOS live path: [coverage-secrets.log](evidence/secrets-mcp/coverage-secrets.log) `KeychainSecretsProvider` passed. Linux nil path is pinned by `linuxHasNoKeychain`, which is `#if os(macOS)`-gated out on macOS and did not execute; no Linux log in this set ([static-checks.log](evidence/secrets-mcp/static-checks.log)) |
| REQ-004 | T6 | Vault KV-v2 over HTTPS: token + AppRole, lease honor, renewal, wrap-TTL | PASS | [rvisolation-full.log:1662](evidence/secrets-mcp/rvisolation-full.log) `VaultHTTPClient` passed; unwrap-exactly-once asserted (`VaultHTTPClientTests`, PUT unwrap count == 1) |
| REQ-005 | T4, T5 | Broker resolves only inside `submitIdentityRequired` with a fresh context; no cached-context reuse | PASS | [rvisolation-full.log:1202](evidence/secrets-mcp/rvisolation-full.log) `Broker admission credential gate` passed; [rvisolation-full.log:1251](evidence/secrets-mcp/rvisolation-full.log) `ScopedInvokerGateTests` passed |
| REQ-006 | T3 | Provider-selection field covered by `canonicalProjection` + digest, store-validated | PASS | [coverage-secrets.log:176](evidence/secrets-mcp/coverage-secrets.log) `Secrets provider store` 55 passed; [coverage-report.txt](evidence/secrets-mcp/coverage-report.txt) `AgentDefinition` 92.82% lines |
| REQ-007 | T3 | Broker-bound entry type beside `keychain`, validated by the resource policy store | PASS | [coverage-secrets.log:176](evidence/secrets-mcp/coverage-secrets.log) store suite passed; [coverage-report.txt](evidence/secrets-mcp/coverage-report.txt) `RuntimeResourcePolicyStore` 87.29% lines |
| REQ-008 | T5 | Broker entries admitted only on the identity-required path; legacy door stays credential-free | PASS | [rvisolation-full.log:1324](evidence/secrets-mcp/rvisolation-full.log) `Broker admission identity door` passed; [rvisolation-full.log:1202](evidence/secrets-mcp/rvisolation-full.log) credential gate passed |
| REQ-009 | T5 | Staging into a 0700 private home, at most 8KB per value, fail-closed per variable | PASS | [rvisolation-full.log:1203](evidence/secrets-mcp/rvisolation-full.log) `Broker admission staging` passed (`oversizedDropKeepsBatch`); [static-checks.log](evidence/secrets-mcp/static-checks.log) 0o700 + 8_192 |
| REQ-010 | T2 | Address grammar `tools.<integration>.<owner>.<connection>.<tool>`, dot-tolerant tool, static-fqid tier, closed enum | PASS | [rvisolation-full.log:1212](evidence/secrets-mcp/rvisolation-full.log) `MCPPolicy` passed; [coverage-report.txt](evidence/secrets-mcp/coverage-report.txt) `MCPToolPolicy` 99.35% lines |
| REQ-011 | T7 | First-match-per-owner ranking, most-restrictive-wins, fractional placement, plugin-default fallback | PASS | [rvisolation-full.log:1212](evidence/secrets-mcp/rvisolation-full.log) `MCPPolicy` passed; [coverage-report.txt](evidence/secrets-mcp/coverage-report.txt) `MCPPolicyStore` 100% lines |
| REQ-012 | T8 | Fixed ordering: policy, validation, elicitation, credential resolution, invoke; decline raises without refresh | PASS | [rvisolation-full.log:1300](evidence/secrets-mcp/rvisolation-full.log) `ScopedInvokerOrderingTests` passed (`declineTouchesZeroCredentials`, `approvePathPhaseOrderIsExact`) |
| REQ-013 | T8 | stdio + loopback per-session binding; 403 cross-resource; SSE elicitation | PASS | [rvisolation-full.log:1196](evidence/secrets-mcp/rvisolation-full.log) transport suites passed (`httpCrossResourceIs403`, `ssePromptRoundtrip`); caller-auth status is a residual risk (see section 2) |
| REQ-014 | T9 | Redaction at URL, header, analytics, log seams; auth always redacted | PASS | [redaction-adversarial.log:554](evidence/secrets-mcp/redaction-adversarial.log) 113 passed; [token-in-log-grep.log](evidence/secrets-mcp/token-in-log-grep.log) 0 unexplained hits |
| REQ-015 | T8 | Opaque caller errors (`Internal tool error [correlationId]`); cause server-side only | PASS | [rvisolation-full.log:1327](evidence/secrets-mcp/rvisolation-full.log) `ScopedInvokerOpacityAuditTests` passed |
| REQ-016 | T10 | Every dispatch, approval, resolution appended to a durable ledger keyed by execution id, labels only | PASS | [redaction-adversarial.log:320](evidence/secrets-mcp/redaction-adversarial.log) 89 passed (`append_survivesRestart`, `recordsIncludingRotated_survivesRestart`); [coverage-report.txt](evidence/secrets-mcp/coverage-report.txt) `SecretsAuditRecords` 99.06% lines; the four record kinds are present ([static-checks.log](evidence/secrets-mcp/static-checks.log)); spec §4.5/T10 v1.1 names the as-built files |

### Security requirements

| ID | Ticket | Claim | Verdict | Evidence |
|---|---|---|---|---|
| SEC-001 | T5, T8 | Resolution or invocation without a principal is rejected with `.principalRequired`; no provider touched | PASS | [rvisolation-full.log:1251](evidence/secrets-mcp/rvisolation-full.log) gate tests passed (`principalLessRejectedBeforeAnything`); [rvisolation-full.log:1324](evidence/secrets-mcp/rvisolation-full.log) identity door passed |
| SEC-002 | T5 | `project()` keeps blocking secret, loader, proxy names; the broker injects only admitted names | PASS | Full suite green baselined-only ([rvisolation-full.log:2181](evidence/secrets-mcp/rvisolation-full.log)) exercises the filter across containment suites; direct pins: [rvisolation-full.log:745](evidence/secrets-mcp/rvisolation-full.log) `unselectedRuntimeStripsSecretsButProjectsNonSecretVars` passed, [rvisolation-full.log:1040](evidence/secrets-mcp/rvisolation-full.log) `fileBlockingSecretsDirDrops` passed; staging drops pinned by [rvisolation-full.log:1203](evidence/secrets-mcp/rvisolation-full.log) |
| SEC-003 | T4, T6 | Short Vault TTLs with accessor indirection and wrapping; the broker never logs secret values | PASS | Zero `print`/`Logger`/`log.` calls in broker + client ([static-checks.log](evidence/secrets-mcp/static-checks.log)); [token-in-log-grep.log](evidence/secrets-mcp/token-in-log-grep.log) 0 unexplained hits; wrap-TTL tests in [rvisolation-full.log:1662](evidence/secrets-mcp/rvisolation-full.log) run |
| SEC-004 | T6 | Expired leases fail closed; renewal timer refreshes renewable leases; unrenewable expiry is `.leaseExpired` | PASS | [rvisolation-full.log:1662](evidence/secrets-mcp/rvisolation-full.log) `VaultHTTPClient` passed; [coverage-report.txt](evidence/secrets-mcp/coverage-report.txt) `VaultHTTPClient` 96.23% lines |
| SEC-005 | T8 | Policy is evaluated on every invocation before any credential is touched | PASS | [rvisolation-full.log:1300](evidence/secrets-mcp/rvisolation-full.log) ordering tests passed (`blockTouchesNothingDownstream`, `validationFailureTouchesNothingDownstream`) |
| SEC-006 | T8 | Elicitation shows address, matched pattern, argument preview; decline raises `ElicitationDeclinedError` with no credential refresh | PASS | [rvisolation-full.log:1231](evidence/secrets-mcp/rvisolation-full.log) elicitation tests passed (`promptShowsAddressPatternAndPreview`, `declineTouchesZeroCredentials`) |
| SEC-007 | T10 | Append-only ledger; pending-approval records keyed by execution id survive restarts | PASS | [redaction-adversarial.log:320](evidence/secrets-mcp/redaction-adversarial.log) 89 passed, restart-durability tests included |
| SEC-008 | T6 | Sealed or unreachable Vault surfaces as provider-down; no bypass path | PASS | [rvisolation-full.log:1662](evidence/secrets-mcp/rvisolation-full.log) `VaultHTTPClient` passed (sealed-as-down covered per T6 acceptance) |

### Constraints

| ID | Ticket | Claim | Verdict | Evidence |
|---|---|---|---|---|
| CON-001 | T6 | No Vault server source linked or vendored; HTTP client only | PASS | [static-checks.log](evidence/secrets-mcp/static-checks.log): no Vault entry in `Package.swift`, no `vendor/` tree; only the client, its tests, and a JSON pack descriptor carry the name |
| CON-002 | all | Swift 6.4, macOS 15 floor | PASS | [static-checks.log](evidence/secrets-mcp/static-checks.log): swift-driver 1.168.6 / Swift 6.4, `.macOS(.v15)` in `Package.swift` |
| CON-003 | T4 | Linux: no keychain provider; file + vault-http cover Linux | PARTIAL | Same basis as REQ-003: `currentPlatform()` returns nil off-macOS and `linuxHasNoKeychain` pins it, but that test is compiled out on macOS and no Linux run is in this set ([static-checks.log](evidence/secrets-mcp/static-checks.log)) |
| CON-004 | T3, T4 | 0600 store, 64KB cap, v1 schema discipline | PASS | [static-checks.log](evidence/secrets-mcp/static-checks.log) 0o600 + 65_536; [rvisolation-full.log:1180](evidence/secrets-mcp/rvisolation-full.log) file-provider suite passed |
| CON-005 | T5 | No staged environment value exceeds 8KB | PASS | [static-checks.log](evidence/secrets-mcp/static-checks.log) 8_192; [rvisolation-full.log:1203](evidence/secrets-mcp/rvisolation-full.log) staging suite passed |
| CON-006 | T6 | Single Vault cluster; no replication features | PASS | One endpoint per client instance; zero replication references in the client ([static-checks.log](evidence/secrets-mcp/static-checks.log)); [rvisolation-full.log:1662](evidence/secrets-mcp/rvisolation-full.log) client suite passed |

### Plan amendment

| ID | Claim | Verdict | Evidence |
|---|---|---|---|
| T6b | Dynamic leases, renewal, wrap-TTL (spec §5b v1.1) | PASS | [rvisolation-full.log:1662](evidence/secrets-mcp/rvisolation-full.log) `VaultHTTPClient` 128/128 passed (renewal, wrap, expiry-during-call, sealed-mid-run); [coverage-report.txt](evidence/secrets-mcp/coverage-report.txt) `VaultHTTPClient` 96.23% lines; AC-005/SEC-004 rows above |

Checklist totals: 31 rows — 29 PASS, 2 PARTIAL (REQ-003, CON-003: Linux branch
not executed on macOS).

## 2. Residual risks

1. MCP-server re-exfiltration over its own channel (plan risk). Policy,
   session binding, and redaction constrain the RV side of the transport
   ([rvisolation-full.log:1196](evidence/secrets-mcp/rvisolation-full.log),
   [redaction-adversarial.log:554](evidence/secrets-mcp/redaction-adversarial.log)).
   They do not constrain a tool server that legitimately receives data and then
   sends it out over its own network channel. No log proves that negative.
2. Loopback caller authentication as implemented in T8. Caller identity on
   loopback HTTP is a random bearer token (`MCPCallerToken`, two UUIDs) sent in
   the `Authorization` header and checked server-side with 401 on mismatch
   (`httpWrongCallerIs401AndUnknownSessionIs404` in the passing transport run,
   [rvisolation-full.log:1196](evidence/secrets-mcp/rvisolation-full.log)). There
   are no platform peer credentials (no `SO_PEERCRED` / peer-pid check): any
   local process that learns the token can call. Token theft scope is one
   session bound to one resource (403 cross-resource,
   [rvisolation-full.log:1196](evidence/secrets-mcp/rvisolation-full.log)).
3. Wrap-TTL trust assumptions. The client sends `X-Vault-Wrap-TTL`, receives a
   single-use wrapping token, and unwraps exactly once via
   `PUT /v1/sys/wrapping/unwrap` (asserted in the passing
   [rvisolation-full.log:1662](evidence/secrets-mcp/rvisolation-full.log) run).
   This trusts the server to honor the TTL and single-use property, and trusts
   the wrapping token itself as bearer material in transit: an endpoint without
   TLS or a misbehaving server weakens the guarantee. TTL format is validated
   client-side (`invalidWrapTTL`).
4. Swift String zeroization is best-effort (T0c). Secret material lives in
   Swift `String`/`Data`; there is no explicit memory zeroization in the
   broker, Vault client, redactor, or invoker (zero hits for
   zeroize/explicitZero/mlock/munlock,
   [static-checks.log](evidence/secrets-mcp/static-checks.log)). Copies can
   persist in freed heap until reuse. Nothing in the evidence set bounds that
   lifetime.
5. Audit-sink overlap (`SecretBrokerFileAudit` vs `SecretsAuditRecords`) —
   still open. Two append paths exist and both pass their suites
   ([rvisolation-full.log:1444](evidence/secrets-mcp/rvisolation-full.log),
   [redaction-adversarial.log:320](evidence/secrets-mcp/redaction-adversarial.log)).
   Overlap, dedup, and ordering across the two sinks are unresolved; this
   document states that as open, not as accepted.
6. rpc unstructured-worker cancellation — still open. The broker timeout path
   (`SecretBroker.rpc`, `Sources/RVIsolation/SecretBroker.swift`) races the
   provider operation against a sleeper task and discards the late result, so
   timeout/cancel does not stop provider work; no log in this set exercises
   that worker's cancellation semantics. Open per plan hardening backlog item
   (1); stated as open, not as accepted.

## 3. Coverage appendix

Measured under the secrets-filtered run only
([coverage-secrets.log](evidence/secrets-mcp/coverage-secrets.log): 748 tests,
26 suites, exit 0). Per-file line and region percentages from
[coverage-report.txt](evidence/secrets-mcp/coverage-report.txt). Branch
coverage is not reported by this toolchain (llvm-cov shows `-`).

| File | Lines | Regions |
|---|---|---|
| `Sources/RVDomain/SecretsProvider.swift` | 100.00% (15/15) | 100.00% (6/6) |
| `Sources/RVDomain/MCPToolPolicy.swift` | 99.35% (152/153) | 98.80% (82/83) |
| `Sources/RVDomain/SecretsRedaction.swift` | 100.00% (94/94) | 98.04% (50/51) |
| `Sources/RVDomain/ReviewSanitizer.swift` | 80.23% (495/617) | 81.85% (266/325) |
| `Sources/RVDomain/AgentDefinition.swift` | 92.82% (168/181) | 82.50% (33/40) |
| `Sources/RVDomain/RuntimeResourcePolicy.swift` | 76.42% (94/123) | 62.67% (47/75) |
| `Sources/RVDomain/RuntimeAdmission.swift` | 47.91% (206/430) | 56.73% (59/104) |
| `Sources/RVIsolation/SecretBroker.swift` | 97.91% (657/671) | 87.84% (260/296) |
| `Sources/RVIsolation/VaultHTTPClient.swift` | 96.23% (1021/1061) | 94.10% (526/559) |
| `Sources/RVIsolation/MCPRegistry.swift` | 100.00% (19/19) | 100.00% (6/6) |
| `Sources/RVIsolation/MCPPolicyStore.swift` | 100.00% (48/48) | 100.00% (18/18) |
| `Sources/RVIsolation/ScopedInvoker.swift` | 98.20% (929/946) | 90.82% (366/403) |
| `Sources/RVIsolation/MCPTransports.swift` | 99.14% (460/464) | 97.83% (180/184) |
| `Sources/RVIsolation/RuntimeAdmission.swift` | 19.63% (204/1039) | 14.77% (48/325) |
| `Sources/RVIsolation/RuntimeResourceManifest.swift` | 65.42% (157/240) | 57.14% (80/140) |
| `Sources/RVIsolation/PreparedWorkspaceLaunch.swift` | 9.01% (29/322) | 15.09% (16/106) |
| `Sources/RVIsolation/ContainedEnvironmentPolicy.swift` | 12.23% (45/368) | 16.90% (36/213) |
| `Sources/RVIsolation/KeychainReader.swift` | 7.14% (1/14) | 25.00% (1/4) |
| `Sources/RVHistory/SecretsAuditRecords.swift` | 99.06% (632/638) | 97.42% (264/271) |
| `Sources/RVPolicy/SecretsProviderStore.swift` | 94.96% (245/258) | 85.61% (119/139) |
| `Sources/RVPolicy/AgentDefinitionStore.swift` | 87.79% (374/426) | 79.49% (155/195) |
| `Sources/RVPolicy/RuntimeResourcePolicyStore.swift` | 87.29% (309/354) | 73.40% (138/188) |

Scope note: the filtered run exercises secrets paths only, so shared
pre-existing files (`RuntimeAdmission`, `PreparedWorkspaceLaunch`,
`ContainedEnvironmentPolicy`, `KeychainReader`) show partial coverage by
design; their remaining lines are exercised by the full suite, which is green
baselined-only ([rvisolation-full.log:2181](evidence/secrets-mcp/rvisolation-full.log)).

Exclusion record: the coverage exclusion record is the "Coverage exclusions"
bullets in the adoption plan
(`../../.agents/plans/2026-10-10-rv-secrets-mcp-adoption.md`), linked here, not
duplicated. The Tier-B grep rationale in
[token-in-log-grep.log](evidence/secrets-mcp/token-in-log-grep.log) (pattern
"TIER-B EXCLUSIONS") covers only token-pattern scope, not code coverage.

## 4. Repro commands

Run from the repository root unless noted. The `\|`-style filter recorded in
[evidence-index.md](evidence/secrets-mcp/evidence-index.md) for the redaction
run was verified to match nothing (`No matching test cases were run`); the
working repro below uses `|`.

- `rvisolation-full.log`:
  `swift test --filter 'RVIsolationTests'`
- `full-tree.log`:
  `swift test` (fully unfiltered, repo root; exit 1 with only the 4 baselined failures)
- `redaction-adversarial.log`:
  `swift test --filter 'SecretsRedactionTests|ReviewSanitizerTests|SecretsAuditRecordsTests|RuntimeAdversarialTests'`
- `token-in-log-grep.log` (from `docs/security/evidence/secrets-mcp/`):
  `grep -c -F -f token-patterns.txt rvisolation-full.log`,
  `grep -c -F -f token-patterns.txt redaction-adversarial.log`,
  `grep -c -F -f token-patterns.txt coverage-secrets.log`,
  `grep -n -F -f token-patterns.txt rvisolation-full.log`,
  `grep -n -F -f token-patterns.txt redaction-adversarial.log`,
  `grep -n -F -f token-patterns.txt coverage-secrets.log`;
  full transcript and per-hit verdicts are in the log itself (coverage
  triage in its addendum).
- `coverage-secrets.log`:
  `swift test --enable-code-coverage --filter 'SecretsProvider|MCPToolPolicy|SecretsRedaction|ReviewSanitizer|SecretBroker|FileSecretsProvider|VaultHTTPClient|ScopedInvoker|MCPPolicy|BrokerAdmission|SecretsAuditRecords'`
- `coverage-report.txt` (after the coverage run; `B=.build/out/Products/Debug`,
  `P=$B/codecov/default.profdata`):
  `xcrun llvm-cov report -instr-profile $P $B/<Target>Tests.xctest/Contents/MacOS/<Target>Tests`
  for `Target` in `RVDomain RVIsolation RVHistory RVPolicy` (nonzero rows kept).
- `static-checks.log`: transcript of the inline `$` commands; re-run each quoted
  command to reproduce its section.
