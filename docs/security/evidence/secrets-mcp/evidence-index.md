# T11 secrets-mcp evidence index

Date (UTC): 2026-10-11. Directory: `docs/security/evidence/secrets-mcp/`.
Toolchain: Apple Swift 6.4 (`swift-driver 1.168.6`, arm64 macOS).

| # | File | Command | Exit | Suites | Tests |
|---|------|---------|------|--------|-------|
| 1 | `rvisolation-full.log` (2183 lines, 158785 bytes) | `swift test --filter 'RVIsolationTests'` (full unfiltered RVIsolation suite) | 1 (3 baselined failures only) | 58: 56 passed, 2 failed (baselined suites) | 990: 945 passed, 3 failed (all baselined), 42 skipped |
| 2 | `token-in-log-grep.log` (412 lines) + `token-patterns.txt` (97 patterns) | `grep -F -f token-patterns.txt` over logs 1, 3, and 4 (log-4 triage in the Wave F addendum) | 0 | n/a | 37 + 81 hits, all explained, 0 unexplained |
| 3 | `redaction-adversarial.log` (554 lines, 40982 bytes) | `swift test --filter 'SecretsRedactionTests\|ReviewSanitizerTests\|SecretsAuditRecordsTests\|RuntimeAdversarialTests'` (superseded — see addendum below) | 0 | 4 passed, 0 failed | 222 passed, 0 failed, 0 skipped |

## Step 1 — full RVIsolation suite: GREEN (baselined-only)

Runner summary: `Test run with 990 tests in 58 suites failed after 222.293 seconds with 3 issues.`
The only failures are the 3 baselined environmental ones, confirmed by cause:

- `IdentityAmbientCredentialTests.customLaunchCannotReadAmbientCodexAuthentication` — `swiftpm-testing-helper` absent (`NSCocoaErrorDomain Code=260`, `NSFilePath=/usr/libexec/swift/pm/swiftpm-testing-helper`).
- `IdentityAmbientCredentialTests.customPreparationDoesNotGrantAmbientCodexAuthentication` — same missing-helper cause.
- `SeatbeltCapabilityTests.containedProcessReachesLoopbackOnly` (`SeatbeltCapabilityTests.swift:38`) — `unsandboxed.output.contains("public ok")` false (no public-network route).

42 skips are all `TRANSITIONAL-PEER-AUTH` skips (code-identity roles reject test binaries), not failures.

## Step 2 — token-in-log grep: GREEN (0 unexplained hits)

97 distinctive fixture secret/token/password/lease-id literals from
`Tests/RVIsolationTests/{SecretBrokerTests,VaultHTTPClientTests,ScopedInvokerTests,BrokerAdmissionTests,MCPPolicyTests}.swift`
(see `token-patterns.txt`; Tier-B generic exclusions documented in the grep log)
were fixed-string grepped over the full outputs of steps 1 and 3.
Result: 36 hits in `rvisolation-full.log`, 1 hit in `redaction-adversarial.log` —
every hit a Swift Testing runner status line echoing a test name or test argument:

- `unknown` x18, `static` x14, `rogue` x2, `once` x2 — substrings of test function
  names (`unknown*`, `staticPin*`, `rogueLeaseDurations…`, `…Nonce…`) plus one
  `.unknown` enum-case echo; no value printed.
- `ghp_` x1 (`redaction-adversarial.log:186`) — runner's `Test case passing
  1 argument … started.` echo of the hardcoded fixture at
  `Tests/RVHistoryTests/SecretsAuditRecordsTests.swift:340`, proven byte-identical
  (20 chars, sha256 `b1d3f303…e53`); the test asserts redaction and passed.

Per-hit transcript and verdicts: `token-in-log-grep.log`. Real leaks: 0.
Log 4 (`coverage-secrets.log`) is triaged in that log's Wave F addendum —
see Addendum 2 below.

## Step 3 — redaction + adversarial suites: GREEN

Runner summaries: 20 tests (`RuntimeAdversarial`) + 89 tests (`SecretsAuditRecordsTests`)
+ 113 tests (`Secrets redaction` + `ReviewSanitizer hardening`) = 222 passed,
0 failed, 0 skipped, exit 0.
Ledger restart-durability confirmed: `append_survivesRestart` and
`recordsIncludingRotated_survivesRestart` both passed.

## Addendum (acceptance author, 2026-10-11)

| # | File | Command | Exit | Suites | Tests |
|---|------|---------|------|--------|-------|
| 4 | `coverage-secrets.log` (1712 lines) | `swift test --enable-code-coverage` + secrets filter (exact command in acceptance doc section 4; uses plain `|` alternation) | 0 | 26 passed (RVPolicy 1, RVIsolation 19, RVHistory 1, RVDomain 5) | 748 passed (55+412+89+192), 0 failed |
| 5 | `coverage-report.txt` (171 lines) | `xcrun llvm-cov report` per test binary, nonzero rows | 0 | n/a | per-file line/region table for 22 secrets files |
| 6 | `static-checks.log` (139 lines, Rev 2) | inline `$` greps with exit codes (imports, caps, permissions, zero-hit greps) | 0 | n/a | verbatim structural transcript |

Note: the `\|`-style filter recorded above for log 3 was verified to match
nothing on this toolchain (`No matching test cases were run`); the working
repro in `docs/security/secrets-mcp-acceptance.md` section 4 uses `|`.

## Addendum 2 (Wave F fix, 2026-10-11)

- `token-in-log-grep.log` grew 259 → 412 lines with a `coverage-secrets.log`
  triage: 81/81 hits verified runner status-line echoes (unknown x63,
  static x14, rogue x2, hunter2 x1, ghp_ x1), 0 unexplained. Combined
  token-in-log result: 118/118 explained, 0 unexplained.
- `static-checks.log` rewritten 63 → 139 lines (Rev 2) as a verbatim command
  transcript with exit codes; every `$` line re-runs to its recorded output.
  No cited claim changed — the underlying facts were re-verified true.

## Addendum 3 (parent, 2026-10-11)

| # | File | Command | Exit | Suites | Tests |
|---|------|---------|------|--------|-------|
| 7 | `full-tree.log` | `swift test` (fully unfiltered, repo root) | 1 (4 baselined failures only) | 19 target summaries; only `RVIsolationTests` (990 tests, 3 issues) and `RVCLITests` (802 tests, 1 issue) report failures | Failures are exactly the 4 baselined items: `customLaunchCannotReadAmbientCodexAuthentication`, `customPreparationDoesNotGrantAmbientCodexAuthentication`, `containedProcessReachesLoopbackOnly` (RVIsolation env baseline) + `companionPresence_linuxFilesystemProbe` at `ResidualLinuxCoverageTests.swift:122` (RVCLI out-of-scope baseline). All other targets green — no regressions from the secrets/MCP changes.
