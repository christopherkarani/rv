# Handoff: dotenv tier implementation

Status: implemented, tested, reviewed, PR open. Written for the next agent
reviewing or continuing this work.

## Where the work is

- PR: https://github.com/christopherkarani/rv/pull/425 (OPEN)
- Head branch: `feat/dotenv-source` @ `29b721f9`
- Base branch: `feat/onboarding-fast-path` @ `32f211f5` — this PR is STACKED on
  PR #424, which is still open and must land first (plan Phase 0).
- Spec: `docs/plans/dotenv-tier/PLAN.md` (implemented in full, Phases 1–4).
- Runbook shipped in the PR: `docs/security/dotenv-secrets.md`.
- The session worktree (`rv-dotenv`) was removed after push. Recreate with:
  `git worktree add -b <tmp> ../rv-dotenv feat/dotenv-source` or check out the
  branch directly.
- Size: 32 files, +2338/−46.

## Commits (oldest first)

| Commit | What |
|---|---|
| `45f59f1a` | Phase 1: dotenv source, parser, trust-checked reader, policy gates |
| `1e48cae3` | Phase 2: `secrets import --dotenv`, `rv init --dotenv` |
| `05b7b023` | Phase 3: top-level `rv run -- CMD` |
| `c80f1d7e` | Phase 4: `secrets harden`, managed status, scan origins, runbook |
| `10b83bcc` | Fresh-review fixes (4 medium, 7 low) |
| `29b721f9` | Final-review residuals (2 P3) |

## What the user got (behavior summary)

- `.env` is a first-class `SecretSource`: `{"dotenv":{"path":"/abs/.env","variable":"NAME"}}`.
  Values stay in the file; rv reads host-side at lease time only.
- Day one: `rv init --dotenv` (or `rv secrets import --dotenv .env`) binds by
  reference with a visible review; `rv run --resource-profile main -- CMD`
  injects. Without the flag, `rv init` only notes that `.env` exists.
- Upgrade: `rv secrets harden NAME|--all` moves values to the Keychain with
  read-back verification and an all-or-nothing rebind. rv never edits `.env`.
- Strict posture: `allowedSources` without `"dotenv"` fails closed at lease,
  check, import, init, MCP, scan, hook, and audit-forward. `rv managed status`
  names dotenv's effective status whenever bindings exist.

## Key implementation facts (where to look)

- Parser + reader + snapshot cache: `Sources/RVIsolation/DotenvFile.swift` (new).
  Strict grammar: BOM/CRLF ok, quotes literal, `#` comment only outside quotes
  and space-preceded, duplicate variable = fail-closed per variable, malformed
  line = per-file error, 256 KiB cap, NUL/non-UTF8 rejected, lint notes for
  `$`/backtick/`\` (read literally).
- Reader: realpath → `O_NOFOLLOW|O_NONBLOCK` → shared
  `OwnerOnlyFile.checkedRead` (`Sources/RVIsolation/OwnerOnlyFile.swift`):
  regular file, owner-owned, not group/world-writable, size checked before
  allocation. 0644 allowed. The same `O_NONBLOCK` fix closed a FIFO hang in
  `OwnerOnlyFile.read`.
- Storage: decode is lexical only (no FS access) in
  `SecretsConfiguration.swift`; encode/locator in `SecretStore.swift`.
- Resolver seam: `SecretResolver.live(environment:home:dotenvReader:)` in
  `SecretProviders.swift`; `SecretLaunchBroker` builds a fresh resolver per
  lease (`makeResolver`) so dotenv snapshots are lease-scoped. Identity =
  dev+inode+mtime+size; a mid-lease change fails that file's remaining secrets.
- CLI bulk: `Sources/RVCLI/Commands/SecretsCommand.swift` (+416) —
  `dotenvCandidates` shared by import and init, `importDotenv`, `harden`,
  scan origins, `[file-backed]`. Plus `InitCommand.swift` (`--dotenv`),
  `RunCommand.swift` + `RunPrepare.swift` (new), `ManagedCommand.swift`
  (`dotenvLine`), `AuditForward.swift` (required `managed` gate),
  `MCPGatewayRuntime.swift` (delivery-axis enforcement), help + completions.
- Harden semantics: resolve → store → read-back `SecretValue` equality → one
  config write. Any failure writes nothing; success wording is buffered so a
  blocked run never prints rotation checklists. D1 carve-out: works under a
  dotenv-deny policy, still requires `keychain` in `allowedSources`; emits a
  `secret.use` audit event (`source: secrets-harden`, locators only).
- Scan: invalid policy → `ScanReport.blocked` + exit 1. Origin exemption is
  per (canonical path, secret) — another secret's value inside a bound `.env`
  still flags; copies elsewhere flag.

## Decisions taken (plan §9) — all recommended options

D1 harden carve-out under dotenv-deny · D2 MCP enforces delivery axis ·
D3 new top-level `rv run` · D4 accept the `secrets import` break (`--varlock`
optional, exactly-one-of) · D5 opt-in `--dotenv` flag · D6 profile-less
`rv run` fails closed · D7 fail-closed duplicates · D8 `[file-backed]` instead
of `[weaker]` for dotenv.

**Open owner item:** plan marks D1/D2 as blocking enterprise shippability
pending owner sign-off. No in-repo sign-off record exists. D2 is breaking for
MCP deployments whose secrets use environment delivery (release-noted in the
PR body and runbook).

## Review history

1. Fresh-context review of `45f59f1a..c80f1d7e`: changes-needed, 0 high,
   4 medium (harden partial-write, scan/hook fail-open on invalid policy,
   fail-open audit-forward default, test gaps), 7 low (parser comment case,
   checklist variable name, unreadable-config warning, managed-status invalid
   silence, duplicated reader, non-redacting descriptions, raw path echoes).
2. All fixed in `10b83bcc` with regression tests (failing-first observed).
3. Final pass on `10b83bcc`: APPROVE, 2 P3 residuals (harden success wording
   on blocked runs; `rv run` unknown-HOME returning 0). Fixed in `29b721f9`.

## Verification evidence

- Focused suites (Dotenv*, Secrets, Init, Managed, Run, OpenCode, AuditForward,
  MCP policy, Completions): pass.
- Full `RVCLITests`: 1167 tests pass.
- `Scripts/preflight.sh`: 0 failed (1 pre-existing warning).
- Full `swift test` (19 targets): failures only in `RVMCPTests` and
  `RVIsolationTests`, each chased:
  - `MCPSandboxCreateTests`: pre-existing on base `feat/onboarding-fast-path`
    in this environment (reproduced there).
  - `WorkspaceSession` `closePublishesEditedReadOnlyFile` /
    `closeKeepsReadOnlyFilesReadable` (`workspaceInodeBoundaryFailed`):
    fail identically on base.
  - `cancellationTerminatesOwnedProcessesBeforeReturn`: timing flake; passes
    on base unloaded (4.5s vs 129s under two concurrent full-suite runs).
- Manual transcripts (built binary, temp `HOME` + temp project): init note,
  `--dotenv` dry-run and write, list, check (fingerprints, exit 0), idempotent
  re-import with locator skips, exactly-one-of error, scan origin section,
  managed status dotenv line, describe, `set` refusal + harden cross-link,
  profile-less `rv run` → stdout refusal, exit 1. Re-run after review fixes
  also proved `COMMENTED= # placeholder` → skipped as empty.

## What is NOT verified

- Real cage launch via `rv run` from the debug binary. The workspace host
  process starts but the client hangs on peer auth between unsigned debug
  binaries — the same reason the repo's macOS launch tests are disabled
  (TRANSITIONAL-PEER-AUTH). Lease staging itself is covered by broker tests
  (environment + gateway delivery). Do not treat a debug-build launch hang as
  a dotenv regression without first reproducing with `rv opencode`.
- Real-Keychain harden. Manual runs used a temp HOME with no login keychain;
  Apple's `security` CLI fails identically there ("A default keychain could
  not be found"), and harden correctly failed loud with the binding untouched.
  Harden uses the shipped `SecretKeychainWriter.live` (same as `secrets set`)
  and is covered with fakes. Note: these probes triggered macOS "Keychain Not
  Found" dialogs for the owner — do not run keychain writes under a fake HOME
  on the owner's machine again.
- Linux execution. Code read, not run (`st_mtim` branch; harden always fails
  on Linux because the Keychain writer is `false` — documented). CI `pr.yml`
  is the Linux gate.
- MCP "preview of affected servers" for D2 (plan rider): not built. Only the
  managed-status dotenv line + release note exist.

## Known residuals (by design, documented in runbook)

- The bound `.env` is cage-editable (it lives in the workspace): cross-launch
  persistence is a dev-tier residual. Drift is visible via lease audit
  fingerprints and `rv secrets check`; closed only by harden or strict policy.
- 0644 `.env` resolves (marked `[file-backed]`). No at-rest protection promise.
- Symlink re-targeting of the stored path is followed deliberately; the
  canonicalize→open race is bounded by the recorded fstat identity.
- Dry-run `rv init --dotenv` profile rows still say "(not defined; run
  `rv secrets set …`)" for about-to-be-bound names (same behavior as the
  #424 varlock dry-run). Cosmetic; bind lines below disambiguate.

## Suggested next steps for the reviewing agent

1. Confirm owner sign-off on D1/D2 (or record the decision in-repo).
2. Land #424, then rebase/retarget #425 onto `main` and watch full CI
   (especially Linux `swift test` and the sharded `RVIsolationTests` gate).
3. Optional follow-ups already noted in plan §10 (out of scope here):
   MCP affected-servers preview, dry-run wording polish, tab-before-`#`
   comment handling (parser requires a space, per spec).
