# rv dotenv tier: implementation plan

Goal: two tiers, one tool.

- **Dev tier (Varlock parity):** `.env` becomes a first-class `SecretSource`;
  `rv init` ingests `.env` and drafts explicit definitions with visible review;
  `rv run -- CMD` resolves all sources including dotenv and injects; values
  stay in `.env` on day one.
- **Enterprise tier (upgrade, not entrance fee):** a harden flow migrates
  values dotenv -> Keychain and rebinds sources; strict org posture forbids
  dotenv sources with fail-closed checks; jail boundary preserved for
  delivery (host resolves, gateway delivers into cage; values, not the
  file handle, cross). Note 2.5a: in the dev tier the bound `.env` is a
  cage-editable project file — persistence is a stated residual, closed
  only by harden/strict posture.

Constraints: no silent bindings (user attests each origin decision); keep Unix
`--` for run; explicit stored config stays; Keychain/Touch ID/gateway
enterprise story untouched; TDD; repo checks pass.

Status: planned; adversarially reviewed twice (4 angles, then a second
fact-check/security/enterprise/impl/DX/tests pass whose findings R48-R59
are folded in below). Blocked on owner decisions D1/D2 for enterprise
shippability (section 9); all other decisions pre-Phase-2.

Sequence target: PR #424 (`feat/onboarding-fast-path`: `rv init`,
`rv secrets set --resource-profile`, `rv mcp onboard`). Phase 1 does NOT
start in parallel: #424 changes 17 files including `SecretsCommand.swift`,
`HelpCatalog.swift`, `RV.swift`, `HelpDispatch.swift`, `MCPCommand.swift`,
and the completions, and Phase 1/2 items touch several of the same
surfaces. All phases branch from the post-#424 tip and land after #424.
Branch: `feat/dotenv-source` from the post-#424 tip.

Line numbers below are base repo (`/Users/chriskarani/CodingProjects/rv`)
unless marked "worktree" (`/Users/chriskarani/CodingProjects/rv-onboard`).

---

## 1. Background: why dotenv-as-a-source

Varlock 1.23.0 (live-tested) keeps values in `.env` and works with them
there: `init --agent` ingests an existing `.env` and drafts `.env.schema`
with inferred decorators; `run -- CMD` injects real values; `scan` reports
leaks as file:line. rv's resolver reads Keychain, host environment,
1Password, Vault, AWS, Infisical, Bitwarden, GCP, and Azure — but cannot read
a value from a `.env` file. rv's Varlock schema importer (`VarlockSchema`)
explicitly skips literal values ("literal value not copied"). So rv modeled
Varlock's vault-reference half and refused the `.env`-values half that
developers use on day one.

The fix is one architectural addition: `.env` as a first-class
`SecretSource`. Day-one friction then approaches Varlock's because it is
the same binding model — with two rv-only costs stated honestly, not
hidden: `rv run` requires an explicit `--resource-profile` (D6), and the
lease-time file-trust checks (3.3) refuse some files Varlock would read.
The enterprise path (Keychain/gateway/cage/posture) becomes an upgrade
via `harden`, not the entrance fee. Enterprise security is untouched for
orgs that forbid dotenv sources: they fail closed on the same manifests
and binary (subject to the default-allow visibility work in 3.7).

---

## 2. Verified codebase facts

### 2.1 `SecretSource` definition and Codable shape

- Definition: `Sources/RVIsolation/SecretsConfiguration.swift:10-42`. Nine
  cases today: `keychain`, `hostEnvironment`, `onePassword`, `vault`,
  `awsSecretsManager`, `infisical`, `bitwarden`, `gcp`, `azure`. No
  dotenv/file case. `kind` string at `:29-41`.
- No `Codable` conformance. Decode is hand-rolled:
  `SecretsDecoding.source` at `SecretsConfiguration.swift:262-347`, one
  kind per object (`{"dotenv": {...}}` shape follows for free). Unknown kind
  fails closed at `:344-345`.
- Encode is hand-rolled: `SecretsConfiguration.encoded()` in
  `Sources/RVIsolation/SecretStore.swift:104-161`, source switch at
  `:112-144`. `write()` at `:164-171` re-decodes before persisting, so any
  new case must round-trip.
- Human-readable locator (safe to print, never the value):
  `SecretSource.locator` in `SecretStore.swift:12-33`.

### 2.2 Every switch/match site over `SecretSource`

Exhaustive `switch` sites (all must gain a `dotenv` arm; the compiler
enforces it). Verified complete: the only other `keychain` match in the
tree is the unrelated `ResourceStagingError.keychain` enum
(`RuntimeResourceManifest.swift:228`).

| # | File:line | What |
|---|-----------|------|
| 1 | `SecretsConfiguration.swift:29-41` | `kind` string |
| 2 | `SecretsConfiguration.swift:265-346` | decode by kind string (add `"dotenv"` arm; unknown-kind error stays) |
| 3 | `SecretProviders.swift:71-100` | `SecretResolver.live` resolution switch |
| 4 | `SecretStore.swift:15-31` | `locator` display string |
| 5 | `SecretStore.swift:112-144` | `encoded()` JSON writer |

Non-exhaustive uses (no new arm needed; behavior flows through them):

- `SecretLaunchBroker.swift:232` — org rule check via `source.kind`.
- `MCPGatewayRuntime.swift:142` — MCP-side org rule check via
  `source.kind` (kind axis only; see R3).
- `SecretsCommand.swift:85` (`list` provider column), `:322` (`describe`
  source kind), `:359` (import echo line) — all render `source.kind`.
- `SecretsCommand.swift:185,247` — `rv secrets set|remove` hardcode the
  `rv.secrets` keychain source; `set` refuses non-keychain sources at
  `:188-192`.
- `MCPCommand.swift:944` — `SecretOrganizationRules.violation` gate on MCP
  import (flow-through via `kind`).
- `ReportCommand.swift:179-181` — renders `source.kind` and calls
  `violation` (flow-through; Phase 4.3 reporting must stay aligned).
- `VarlockSchema.swift` — helper constructors at `:278-307` cover
  `onePassword`/`gcp`/`azure`; `infisical`/`bitwarden`/`vault`/
  `awsSecretsManager` are built inline in `source()` (`:194-260`). Dotenv
  ingestion does NOT go through the schema importer either way.

Test fakes: `Tests/RVCLITests/SecretsCommandTests.swift:30-44` switches with
a `default:` arm (compiles unchanged; extend deliberately).
`Tests/RVIsolationTests/SecretLaunchBrokerTests.swift:53` matches one case
with early return (unchanged).

### 2.3 CLI secrets paths (`Sources/RVCLI/Commands/SecretsCommand.swift`)

- `list` (`SecretsRun.list`, `:73-119`): renders `locator` + `kind`; dotenv
  rows appear with zero logic change once `kind`/`locator` exist.
- `check` (`SecretsRun.check`, `:121-157`): resolves via
  `environment.resolver`, fingerprints, honors org policy at `:139-145`.
- `set` (`:173-239`): Keychain-only writer. Refuses `--dotenv`-bound names
  with the existing "reads from …" error shape (`:188-192`), never
  silently rebinds. Gains a one-line harden cross-link (Phase 1.6).
- `describe` (`:317-334`): names/descriptions/types/delivery, `source.kind`
  only, no locators, no masked values (no `load` equivalent; help maps
  `load`->`check`).
- `scan` (`:278-302`, failure scope `:584-612`): resolves every secret and
  exact-matches values in a tree. Bound `.env` paths move to an "origin
  files" section that does not fail the gate (Phase 4.4); copies elsewhere
  still flag.
- `import --varlock` (`SecretsRun.importVarlock`, `:336-382`; struct
  `SecretsImport`, `:634-651`): Varlock-schema only, `--varlock` required.
  Adding `--dotenv` changes the no-flag error, `--help`, and completions
  (decision D4).
- Help rows: `Sources/RVCLI/Help/HelpCatalog.swift:411-451`; sources
  enumeration row at `:440`. `HelpDispatch` `rv help <cmd>` switch at
  `Sources/RVCLI/Help/HelpDispatch.swift:101-160` (top-level `run` needs a
  new case or help falls to nil).

### 2.4 Varlock importer (`Sources/RVIsolation/VarlockSchema.swift`)

- `definition()` at `:173-191` SKIPS literal values: empty value ->
  `"no provider reference"` (`:181`); non-`op://`, non-function value ->
  `"literal value not copied"` (`:182-184`). Imported delivery is hard
  `.environment` (`:189`). Duplicates: first wins (`:30-33`).
- This contract is FROZEN. Do not loosen the schema importer. A new
  `DotenvFile` parser lives next to it and reuses its strictness style
  (size caps, NUL rejection, `DisplayedText` escaping).

### 2.5 Delivery path into launch/cage (jail boundary)

- `SecretLaunchBroker.lease(names:agent:)` at
  `Sources/RVIsolation/SecretLaunchBroker.swift:86-153`: loads
  `secrets.json`, loads managed policy (invalid policy fails closed at
  `:95`), checks per-definition org rules (`:103-105`), resolves each
  source host-side (`:118-121`), then stages environment text (`:124-128`,
  UTF-8 + 8 KiB cap) or gateway placeholder + base URL (`:129-140`). Audit
  event per secret records provider `kind` (`:141-149`).
- `Sources/RVIsolation/WorkspaceSessionSupervisor.swift:1566-1579` takes
  the lease BEFORE the state lock and appends `lease.environment` to the
  cage environment.
- MCP path: `MCPGatewayRuntime.resolve` at
  `Sources/RVMCP/MCPGatewayRuntime.swift:133-161` resolves the same
  `SecretSource`s with the same org-policy gate at `:142-146`.
- Consequence: a host-side dotenv resolver plugs into BOTH launch and MCP
  with no cage-side change. The cage never sees the `.env` file *as a
  file* — but note 2.5a below.
- 2.5a CRITICAL correction (R1, re-scoped by second review): the day-one
  flow binds `<project>/.env` and launches with that project as the
  cage-writable workspace, so a blanket lease-time refusal of
  cage-rooted paths would break the dev tier entirely. Cage processes
  can therefore edit the bound `.env`, and the next lease reads the
  edited values: cross-launch persistence is an inherent dev-tier
  residual (the same file is operator-edited between runs by design).
  Mitigations are visibility + enterprise exclusion, not refusal:
  per-lease snapshot consistency (3.3), per-secret audit fingerprints
  already emitted at `:141-149` (drift is visible in the audit trail),
  `rv secrets check` fingerprints, and strict posture forbidding dotenv
  outright (3.7). The resolver also has no workspace context
  (`SecretResolver.resolve` takes only a `SecretSource`), so a
  root-knowledge refusal would need supervisor/plumbing this plan does
  not otherwise require — not built (see section 10).

### 2.6 Posture/policy enforcement gates

- `ManagedPolicy.secretSourceKinds` at
  `Sources/RVPolicy/ManagedPolicy.swift:69-72` enumerates the nine kinds;
  `allowsSecretSource(_:)` at `:104-106` (nil `allowedSources` allows all —
  default-allow, see R21).
- Strict decode: unknown kind in `allowedSources` is an error at `:205-211`.
- Enforcement points: `SecretOrganizationRules.violation` in
  `SecretLaunchBroker.swift:228-239` (launch), `SecretsRun.check` at
  `SecretsCommand.swift:139-145`, `SecretsRun.set` at `:216-223`,
  `SecretsRun.importVarlock` at `:368-375`, `MCPGatewayRuntime.resolve` at
  `MCPGatewayRuntime.swift:142-146`, `MCPCommand.swift:944`,
  `ReportCommand.swift:181`.
- Correction (second review): invalid managed policy fails closed ONLY
  at lease/check/set/import. Scan (`SecretsCommand.swift:284`), hook
  (`:393`), and audit-forward (`AuditForward.swift:226` `resolveHeaders`;
  invalid policy ignored entirely when `--to` is passed, `:305`) resolve
  with NO policy gate — and audit-forward sends values off-host. Because
  Phase 1 ships the source, these three sites get their gate-or-defer
  disposition in Phase 1, not Phase 4 (Phase 1.10; R25/R50).

### 2.7 `rv run` today: there is NO top-level `run`

- `Sources/RVCLI/RV.swift:9-33` lists top-level commands: no `run`.
- Closest patterns, both keeping Unix `--` via `.captureForPassthrough`:
  `rv workspace run` (`WorkspaceCommand.swift:76-106`, strip at `:100`;
  absolute-only executable rule at `:470-472`) and `rv opencode`
  (`OpenCodeCommand.swift:48-100`, strip at `:68`, missing-profile warning
  at `:83-85`). `resolveExecutable` (`:19-45`) is internal, not private —
  callable from a same-module `RunCommand` today; the generalization work
  is parameterizing the hardcoded `appendingPathComponent("opencode")`
  at `:31`.
- Frontend rule: `IsolatedCommand.make` validation lives in Prepare files
  (`OpenCodePrepare.swift:5-8`); frontends must not import isolation
  types. Phase 3 therefore ships `RunCommand.swift` + `RunPrepare.swift`.

### 2.8 PR #424 worktree surfaces

- `InitCommand.swift` (new): `InitRun.plan` (`:59-121`), `--secret` wiring
  fails closed at launch when undefined (`:56-58`), `.env.schema`
  auto-imports flaglessly when present (`:275-320`), `planText`
  (`:205-241`) prints a `next:` line (`:232-234`) pointing at `rv opencode`.
- `rv secrets set --resource-profile`: validates the profile pre-write,
  then `InitRun.attachSecret` (`:153-178`) wires the name in.
- `KnownSecretDefaults` (new): curated gateways for five well-known names
  via `definitionForSet`; applies to `set` only, no interplay with dotenv
  import.
- Conventions to follow: `shellWord` quoting for spaced paths, fail-loud
  reads, documented known defaults.

### 2.9 Checks and suites

- Gate: `Scripts/preflight.sh` (structural) plus `swift test` via
  `Scripts/swift-6.4`. Preflight does NOT run tests.
- Suites touched: `RVCLITests`, `RVPolicyTests`, `RVMCPTests`,
  `RVIsolationTests` — but the gate is the FULL `swift test` run (19 test
  targets in the repo), not just these four. Completions have tests
  (`Tests/RVCLITests/CompletionsCatalogTests.swift`). Tests use Swift
  Testing (no XCTest), no `NSHomeDirectory`; fixture homes via temp dirs
  (`SecretsCLIFixture`).

---

## 3. Design

### 3.1 New source case

```swift
case dotenv(path: String, variable: String)
```

- `path`: ABSOLUTE path to the `.env` file, stored explicitly in
  `secrets.json`. Absolute, not project-relative: `secrets.json` is global
  (`~/.config/rv/secrets.json`), and BOTH resolution call sites
  (`SecretLaunchBroker.lease`, `MCPGatewayRuntime.resolve`) have no project
  context. Import absolutizes relative CLI paths and echoes the stored
  absolute path. Escape hatch (not v1): `$RV_PROJECT`/`~`-prefixed paths
  validated at decode; never silently expand bare relative paths.
- `variable`: the key inside the file. Usually equals the secret `name`
  but stored separately so renames stay explicit.
- `kind`: `"dotenv"`. JSON: `{"dotenv": {"path": "/abs/.env",
  "variable": "STRIPE_SECRET_KEY"}}`.
- Decode validation (new arm in `SecretsDecoding.source`): `path` absolute
  (`hasPrefix("/")`), <= 512 bytes, NUL/control rejected (reuse
  `SecretsDecoding.label`); reject `..` and empty (non-root) components.
  Decode stays PURE and lexical — NO filesystem access, NO `realpath`:
  `decode` is offline JSON today and `write()` re-decodes before
  persisting (`SecretStore.swift:164-171`), so an FS-touching decode
  would make config writes fail when a bound `.env` is temporarily
  missing. `variable` via existing `SecretsDecoding.variable`. Reuse
  `onlyKeys`.
- Canonical form for comparisons: computed at READ time, never stored.
  The reader canonicalizes the stored path (`realpath`-equivalent,
  resolving symlinks including parent components), then opens the
  canonical target (3.3). Scan's origin matching and snapshot keys use
  this same canonical form (Phases 1.4, 4.4). Storing the operator's
  path and canonicalizing on use means symlink re-targeting is followed
  deliberately — see the residual race note in 3.3.
- `locator`: `"dotenv \(DisplayedText.field(path))#\(DisplayedText.field(variable))"`.
  Never logs values.

### 3.2 Dotenv file grammar (strict subset, documented)

New `DotenvFile` parser in `RVIsolation` (next to `VarlockSchema.swift`):

- Encoding: UTF-8; a leading UTF-8 BOM is stripped (Windows-authored
  files must not silently lose their first binding); both LF and CRLF
  line endings accepted.
- Lines: `NAME=VALUE`, optional leading `export `, optional whitespace
  around `=`. `#` starts a comment only outside quotes AND preceded by
  a space (existing `stripTrailingComment` semantics,
  `VarlockSchema.swift:370-385` — `KEY=abc#def` keeps `#def` in the
  value). Blank lines skipped. `NAME` must satisfy `isVariableName`.
- Values: unquoted (trimmed of surrounding whitespace), single-quoted
  (literal), double-quoted (literal; NO interpolation, NO escapes except
  none — backslashes stay literal). No line continuation. No command
  substitution. No `include`. Empty values (`NAME=`) parse successfully
  as empty — the PARSER accepts them; binding/staging refuses them
  because `SecretValue` rejects empty (`SecretProviders.swift:19`), so
  import must skip them by name (Phase 2.1) instead of binding a secret
  that fails every lease.
- Limits: single 256 KiB cap shared by import and resolver; NUL and
  non-UTF-8 rejected.
- Parser result shape: entries PLUS per-line errors (not a throwing
  all-or-nothing parse). Error scopes, decided:
  - Duplicate variable: FAIL-CLOSED per-variable at lease; import stays
    advisory (names the duplicate, binds nothing for it). Adjudication:
    fail-closed beats last-wins for a secret loader — first-/last-wins
    both let a prepend/append silently choose the injected value under
    an unauthenticated writer.
  - Malformed line (not blank/comment/valid assignment): per-FILE error.
    All secrets sourced from that file fail that lease; secrets from
    other sources are unaffected. A file whose parse is ambiguous is
    not partially trusted.
- Strictness lint: surviving lines containing `\`, `$`, backtick, `$(`
  get a note (parser differentials vs shell/python-dotenv/docker are
  expected; surface them, don't silently match them).

### 3.3 Resolver threading

`SecretResolver.live(environment:home:)` gains a defaulted filesystem seam:

```swift
SecretResolver.live(environment:home:dotenvReader:)
dotenvReader: @Sendable (String) -> DotenvReadResult? // default: live file read
```

All 6 existing production `.live` call sites compile unchanged
(`SecretLaunchBroker:74`, `SecretsCommand:22`, `AuditForward:352`,
`MCPCommand:1278,1388`, `MCPOAuth:729`; test sites likewise via the
default). Tests inject canned contents; production reads host-side like
`~/.vault-token` (`SecretProviders.swift:252`).

The live reader implements `OwnerOnlyFile`-STYLE checks on the
CANONICAL target (3.1) — but does NOT reuse `OwnerOnlyFile.read`
verbatim, for two verified reasons:

1. FIFO hang: `OwnerOnlyFile.read` opens `O_RDONLY|O_NOFOLLOW|O_CLOEXEC`
   (`OwnerOnlyFile.swift:20`) with no `O_NONBLOCK`, so opening a FIFO
   blocks at `open()` before its `S_ISREG` check can run. The dotenv
   reader opens with `O_NONBLOCK`, `fstat`s, then clears `O_NONBLOCK`
   via `fcntl` for the bounded read. Phase 1 also fixes
   `OwnerOnlyFile.read` itself the same way (a FIFO at `secrets.json`
   hangs every command today) — one shared helper, both callers.
2. Symlinks: `O_NOFOLLOW` on the stored path would refuse every
   symlinked `.env` (dotfile managers, shared monorepo files). The
   reader instead canonicalizes first, then applies the checks to the
   target: `O_NOFOLLOW` open of the canonical path, `S_ISREG`,
   owner-owned, non-group/world-WRITABLE (0644 stays readable-allowed;
   `confidential` mode is NOT used — see runbook residual, R15),
   `st_size`-first bounded read (kills post-read memory DoS). Residual
   race, accepted + documented: the canonical path can be re-pointed
   between canonicalize and open by whoever can write its parent
   directory; the `fstat` identity (dev/inode) is recorded in the
   snapshot (below) so a mid-lease swap is detected, not silently
   mixed.
3. Group/world-readable (0644): allowed (dev-tier reality), flagged in
   the runbook and in `rv secrets list` via `[file-backed]`; strict
   orgs exclude dotenv entirely (3.7).

Per-lease snapshot (replaces "re-read per secret"): within ONE lease,
all secrets sourced from the same file must come from one file
generation. `SecretLaunchBroker.lease` constructs a FRESH resolver per
lease (small change to its resolver plumbing, Phase 1.4 — `lease`
therefore leaves the "untouched" list); the resolver caches each file's
parse keyed by canonical path, validated against the recorded
`fstat` identity (dev, inode) + (mtime, size). An identity change
mid-lease fails that file's remaining secrets — never a torn old/new
mix. No cache survives across leases (fresh resolver), so no stale
values across launches. Non-lease resolvers (check/scan/MCP) get the
same per-instance snapshot semantics for free.

No cage-root refusal: re-scoped per 2.5a. Errors name path+variable via
`DisplayedText.field`, never values, never file peeks.

### 3.4 No-silent-bindings attestation UX

Every dotenv binding is created by an explicit user action naming the file:

- `rv init --dotenv` (opt-in flag): ingests `<project>/.env` (fixed
  conventional path for v1), prints a review table, writes ONLY reviewed
  bindings. Bind-all with annotated review rows; the secret-name heuristic
  (`MCPRedaction.isSecretName`, already public) orders/annotates rows but
  NEVER skips. `--secret` remains explicit override. Documented asymmetry:
  `.env.schema` auto-imports flaglessly because it carries no values;
  `.env` carries values, so the flag IS the attestation.
- `rv secrets import --dotenv <file>`: same review output, `--dry-run`
  supported, honors org policy before writing (mirrors `importVarlock`
  at `SecretsCommand.swift:368-375`).
- Without the flag, `rv init` only NOTES that `.env` exists and names the
  flag. `--secret NAME` alone never binds dotenv.

### 3.5 Delivery default for dotenv bindings

Dev tier = Varlock `run --` parity = REAL values injected =
`.environment` delivery (same default the schema importer chose).
Gateway delivery stays available per secret. Strict orgs forbid
`.environment` via the EXISTING `allowEnvironmentDelivery` knob — with
one gap: MCP ignores the delivery axis today (R3, decision D2).

### 3.6 Harden flow (enterprise tier)

`rv secrets harden NAME [--all]`: for each dotenv-bound secret, resolve
the current value, store it with `SecretKeychainWriter` under
`rv.secrets`/`NAME`, READ BACK via the keychain resolver and compare
`SecretValue` EQUALITY directly (not fingerprints: `SecretFingerprinter`
is a truncated HMAC whose loader is nullable, `SecretFingerprint.swift:31`
— in-process byte equality is strictly stronger and has no nil path),
then rewrite the definition's source to `.keychain(service:
"rv.secrets", account: NAME)`, keeping delivery/agents/description/type.
Value first, config second (a Keychain failure leaves the definition
untouched). Mismatch leaves the dotenv binding and fails loud. If the
`.env` changes between resolve and rewrite, harden migrates the
resolved generation; the rotation checklist (below) already requires
rotating + removing the line, and `rv secrets check` fingerprint drift
makes a raced edit visible after the fact.

Refuse when: secret undefined; source is not dotenv (print where it reads
from); org policy forbids keychain sources or is invalid. Under a
dotenv-deny policy, behavior follows decision D1 (carve-out vs refusal).
`--all`: all keychain writes first, then ONE atomic `OwnerOnlyFile.write`;
orphaned keychain copies are benign and overwritten on retry. Success
note is a rotation checklist: names rotation explicitly, warns `scan`
will flag the unrotated `.env`, notes the Keychain-vs-`.env` drift gap.
Harden always fails on Linux (`SecretStore.swift:94` hardcoded false):
document it, gate e2e by platform. Own audit event: name, old locator,
new locator, value-equality-verified bool.

rv NEVER edits, chmods, deletes, or git-ignores the user's `.env`.

### 3.7 Posture (enterprise tier)

- Add `"dotenv"` to `ManagedPolicy.secretSourceKinds`. Strict orgs set
  `allowedSources` without `"dotenv"`; existing enforcement points fail
  closed with `"<name> uses a dotenv source, which is not allowed"`.
- `rv secrets check` reports the policy reason per row; import and init
  refuse to write dotenv bindings under a forbidding policy.
- `rv managed status` MUST name dotenv's effective status whenever any
  dotenv binding exists (default-allow visibility: no `allowedSources`
  today means dotenv allowed tomorrow — warn in the runbook).
- Fleet rule (runbook): binaries-before-policies. A policy mentioning
  dotenv bricks old clients via whole-policy invalid-state; unknown-kind
  rejection tests are kept, never weakened. Order: harden-while-permissive
  OR carve-out (D1), then tighten.

---

## 4. Phased implementation (TDD throughout)

### Phase 0 — Sequencing (no code)

1. Land PR #424 first. Phases 1-2 touch #424-owned surfaces
   (`SecretsCommand.swift`, `HelpCatalog.swift`, completions).
2. Branch `feat/dotenv-source` from post-#424 tip. No parallel start:
   the earlier zero-overlap claim was falsified by the #424 diff
   (17 files; see R49).

### Phase 1 — dotenv source (RVIsolation + RVPolicy + help row)

Goal: `{"dotenv": {...}}` decodes/encodes/resolves; policy can
allow/deny it; `check`/`list`/`describe`/`scan` work.

1. `Sources/RVIsolation/DotenvFile.swift` (NEW): strict parser per 3.2.
2. `SecretsConfiguration.swift`: `case dotenv(path:variable:)` (`:10-28`),
   `kind` arm (`:29-41`), decode arm (`:262-347`) with path/variable
   validation + `..` rejection. Lexical only; no FS access in decode
   (3.1).
3. `SecretStore.swift`: `locator` arm (`:12-33`), `encoded()` arm
   (`:112-144`).
4. `SecretProviders.swift`: resolver arm (`:71-100`) + `dotenvReader`
   seam per 3.3, incl. per-instance snapshot state (thread-safe box
   behind the `@Sendable` closure). New
   `DotenvResolver.read(path:variable:reader:)` with distinct errors
   (missing file vs missing variable vs oversize vs invalid-file vs
   duplicate vs untrusted-file vs identity-changed). Values flow
   through existing `SecretValue` trimming/caps. `SecretLaunchBroker`
   constructs a fresh resolver per lease so the snapshot is lease-scoped.
   `OwnerOnlyFile.read` gains the `O_NONBLOCK` open (3.3 item 1) via a
   shared open helper used by both readers.
5. `ManagedPolicy.swift`: add `"dotenv"` to `secretSourceKinds`
   (`:69-72`). Nothing else.
6. `rv secrets set` guard: verified generic refusal (`:188-192`); append
   a dotenv-specific cross-link: "use `rv secrets harden NAME` to move
   this value into the Keychain". One-line production change. (Moves
   to Phase 2 if it collides with #424's `SecretsCommand` edits on
   rebase — order, not scope.)
7. `HelpCatalog.swift:440` sources row: add dotenv (this is the
   user-facing enumeration; `PLAN.md:409` is stale).
8. `rv secrets list`: add `[file-backed]` source-strength marker for
   dotenv, distinct from `[weaker]`, carried into robot JSON; scope or
   suppress `[weaker]` noise per D8.
9. Runbook seed: "the bound `.env` is trusted input at every launch",
   machine-global bindings note, 0644 residual risk, cage-editable
   `.env` cross-launch persistence residual (2.5a) + audit-fingerprint
   drift visibility.
10. Ungated-resolver dispositions, SAME phase as the source ships
    (R25/R50): audit-forward `resolveHeaders` gains the org gate
    (kind axis + invalid-policy fail-closed regardless of `--to`) —
    non-deferrable, it sends values off-host. Scan/hook: policy-denied
    secrets land in `skipped` with the policy reason instead of being
    resolved (full origin-files UX still Phase 4.4).

Verification: round-trip + invalid decode cases (incl. decode with the
bound file missing — decode must not touch the FS); resolver tests with
injected reader; snapshot tests (one generation per lease; inode swap
mid-lease fails that file's secrets); `ManagedPolicyTests` dotenv
allow/deny; reader trust tests (symlink-to-good target succeeds,
symlink-to-unsafe target refused, FIFO/device refused WITHOUT hanging
— run under a test watchdog so a regression is a failure, not a stuck
suite; oversize-before-read; non-owner via a root-owned fixture path;
group-writable); duplicate fail-closed + malformed-line per-file scope
tests; cap-boundary both sides; audit-forward gate tests (deny +
invalid-with-`--to`). FULL `swift test` + preflight.

### Phase 2 — init ingestion + import (RVCLI on #424)

Goal: `.env` -> explicit definitions with visible review; no silent
bindings.

1. `SecretsRun.importDotenv(path:dryRun:environment:)` mirroring
   `importVarlock` (`:336-382`) with three deliberate deviations:
   (a) the file is read through the SAME trust-checked reader as the
   lease (3.3), never `Data(contentsOf:)` — import must not bind a file
   the lease will refuse (symlink-to-unsafe, group-writable, non-owner,
   FIFO), and the read is size-bounded before allocation;
   (b) org-policy checks run BEFORE the dry-run return (importVarlock
   checks after, `:365` vs `:368` — do not inherit that ordering: a
   dry run under a denying policy must report the denial);
   (c) pre-filters additionally skip EMPTY values and values >
   8 KiB by name with a note (`skip NAME: empty value cannot stage` /
   `skip NAME: value exceeds the 8 KiB environment limit`) — both
   parse fine but fail every lease if bound (`SecretProviders.swift:19`,
   `SecretLaunchBroker.swift:125`).
   Remaining mirror: 256 KiB cap; pre-filters skip each with a note —
   already-defined (WITH existing locator: `skip NAME: already
   bound to dotenv /A/.env#...`), invalid names, `reservedVariables`,
   current-exported collisions, 64-secret cap, duplicate-in-file;
   delivery `.environment`; no description. Absolutize relative CLI
   paths and echo the stored absolute path. Emit `git check-ignore`
   status line (informational; outside a git work tree print
   `git: not a work tree (skipped)`, never fail the import on it).
   NO import-time value-hash is recorded: `secrets.json` has no field
   for it (`onlyKeys` at `SecretsConfiguration.swift:224`) and adding
   one breaks old binaries harder (R7); drift visibility comes from
   the per-lease audit fingerprints + `rv secrets check` (2.5a, R53).
2. `SecretsImport`: `--dotenv <file>` alternative to `--varlock`. Shape
   per D4: (a) accept break — `--varlock` optional + exactly-one-of
   validation + updated tests [*recommended*], or (b) separate
   `import-dotenv` subcommand (non-breaking, uglier). Word help so the
   two modes are unambiguous (`--varlock` copies no literals; `--dotenv`
   binds by reference, values stay in the file).
3. `InitCommand.swift` (#424): `--dotenv` flag, fixed `<project>/.env`.
   Bind-all with annotated review rows; heuristic never skips (3.4).
   `--dry-run` reports `dotenv <path>: would bind N names` + per-name
   lines. No flag + `.env` present: note naming the flag. Needs:
   `dotenvFreshNames` dry-run helper, file-read seam on
   `InitEnvironment` (or direct read + temp fixtures), `planText`
   signature change + worktree test update.
4. `HelpCatalog` + `HelpDispatch`: `rv secrets import --dotenv`,
   `rv init --dotenv` rows; completions x3 updated.
5. Empty-state funnels reworded: `listText` empty hint, `set` new-name
   error, `Secrets` abstract name the dotenv path. `load`->`check`
   command map in help. `next:` line updated when dotenv bindings exist.
   Layering decision stated even if "v1 binds exactly one file".

Verification: dry-run output, defined/invalid/reserved/exported/cap/
empty/oversize-value skips, locator-bearing skip text, exactly-one-of
validation incl. no-flag error, absolutize-and-echo, `check-ignore`
line (incl. non-work-tree), policy-denial refusal IN DRY RUN TOO,
import-refuses-lease-unreadable-file (group-writable fixture),
idempotent re-import; init review text, dry-run writes nothing
(assert mtimes/bytes), profile wiring, no-flag note, missing-`.env`
error. FULL `swift test`; preflight.

### Phase 3 — `rv run -- CMD` (RVCLI)

Goal: one-command dev-tier launch resolving all sources incl. dotenv.

1. NEW `RunCommand.swift` + `RunPrepare.swift` (frontend must not import
   isolation types; `IsolatedCommand.make` validation lives in Prepare).
   Mirrors `OpenCodeCommand.swift:48-100`: `--workspace` default cwd,
   `--resource-profile`, minimal `WorkspaceRun` options, same `--` strip.
2. `resolveExecutable` generalization: parameterize the hardcoded
   `appendingPathComponent("opencode")` at `OpenCodeCommand.swift:31`
   (the function is internal; no access change needed), with
   byte-identical guarantees + existing-suite proof. Document deliberate
   divergence from `workspace run` absolute-only rule (`:470-472`).
3. Isolation notice + missing-profile warning reused BUT dotenv-framed;
   profile-less `rv run` with dotenv bindings FAILS CLOSED AND LOUD
   (stdout + nonzero exit), not stderr-warning-only.
4. Hook passes nil -> agent-tagged definitions do NOT stage (verified
   `SecretsConfiguration.swift:92-96`); state in help + test. No
   supervisor changes; stays a frontend over `lease()` (the Phase 1.4
   fresh-resolver-per-lease plumbing is the only broker change).
5. Help: top-level `run` rows + `HelpDispatch` `case "run"` + completions.

Verification: `--` splitting, default-cwd project, profile warning text,
executable resolution (absolute / PATH / missing), profile-less
fail-closed test, hook-nil tagged-skip test, opencode byte-identical
suite proof, dispatch tests, `CompletionsCatalogTests` updated.

### Phase 4 — harden + strict posture UX + runbook

Goal: enterprise tier complete; strict orgs fail closed with actionable
errors.

1. `SecretsRun.harden(names:all:)` + `SecretsHarden` per 3.6 (H1 behavior
   per D1; read-back verification; `--all` single-write + crash-recovery
   test; own audit event; rotation-checklist note; Linux documented;
   `type` preserved).
2. Refusal message shapes reuse `set`'s org-invalid / org-violation /
   Keychain-failure / non-dotenv-source shapes.
3. CUT the `ManagedCommand` allow-list edit (already renders generically,
   verified `:80-82`). REQUIRED instead: `rv managed status` names
   dotenv's effective status whenever any dotenv binding exists.
4. `rv secrets scan`: origin exemption is per (canonical path, secret)
   FINDING, never per file: a finding is moved to the "origin files"
   section only when the finding's canonical path equals the canonical
   path bound for THAT secret. A different secret's value inside a
   bound `.env` still fails the gate (a cage process pasting a
   keychain value into the project `.env` must not be laundered).
   Matching mechanics, specified: `SecretLeakScanner` reports
   symlink-resolved paths relative to the resolved scan root
   (`SecretStore.swift:195,215`); the CLI canonicalizes each dotenv
   binding with the same reader canonicalization (3.1) and compares
   absolute canonical paths. Copies elsewhere still flag.
   Policy-violated secrets already land in `skipped` from Phase 1.10;
   this item is the origin-files UX only.
5. Runbook (enterprise): strict sample policy; rollout order; binaries-
   before-policies fleet rule; default-allow warning; `.env`-is-trusted-
   input; 0644 residual risk; lease-time-only policy note; gateway-fetch
   no-recheck note.

Verification: harden matrix (success / undefined / non-dotenv /
policy-invalid / policy-forbids-keychain / keychain-fails-untouched /
read-back mismatch via composed fake whose read-back differs /
`--all` mixed + exit codes + recovery simulated by a fake keychain
writer failing after N stores: config untouched, retry completes);
scan origin tests (bound secret in bound file exempt; OTHER secret in
bound file flags; bound secret in copy flags; symlinked scan path);
M1/M2 skip tests (from Phase 1.10, re-verified); strict-posture e2e;
downgrade behavior: documented in runbook + proven at the decode layer
(unknown-kind fixture fails whole-config, existing test shape) — no
old-binary harness exists, do not claim an e2e downgrade test; `hook
run` flagging staged `.env` edit.

### File-by-file change list

| File | Change | Why |
|------|--------|-----|
| `Sources/RVIsolation/DotenvFile.swift` (NEW) | strict `.env` parser | 3.2; shared by resolver + import + init |
| `Sources/RVIsolation/SecretsConfiguration.swift` | `dotenv` case + `kind` + decode arm | 3.1; storage contract |
| `Sources/RVIsolation/SecretStore.swift` | `locator` + `encoded()` arms | display + round-trip |
| `Sources/RVIsolation/SecretProviders.swift` | resolver arm + `dotenvReader` seam + `DotenvResolver` + per-instance snapshot | host-side reads; jail boundary; one generation per lease |
| `Sources/RVIsolation/OwnerOnlyFile.swift` | `O_NONBLOCK` open via shared helper | FIFO hang fix (dotenv reader + `secrets.json`) |
| `Sources/RVIsolation/SecretLaunchBroker.swift` | fresh resolver per lease | lease-scoped snapshot (1.4); no lease-logic change |
| `Sources/RVCLI/Commands/AuditForward.swift` | org gate in `resolveHeaders` + invalid-policy fail-closed with `--to` | ungated off-host resolver (1.10) |
| `Sources/RVPolicy/ManagedPolicy.swift` | `"dotenv"` in `secretSourceKinds` | posture allow/deny |
| `Sources/RVCLI/Commands/SecretsCommand.swift` | `importDotenv`, `--dotenv` on import, `harden`, set cross-link, list marker, scan origin-files | Phases 1, 2, 4 |
| `Sources/RVCLI/Commands/InitCommand.swift` (#424) | `--dotenv` ingestion + review output | Phase 2; no silent bindings |
| `Sources/RVCLI/Commands/RunCommand.swift` (NEW) + `RunPrepare.swift` (NEW) | top-level `rv run` frontend | Phase 3; Varlock `run --` parity |
| `Sources/RVCLI/Commands/OpenCodeCommand.swift` | generalize `resolveExecutable` (or move to shared) | Phase 3; avoid a second PATH search |
| `Sources/RVCLI/RV.swift` | register `Run` (+ `Init` from #424) | CLI surface |
| `Sources/RVCLI/Help/HelpCatalog.swift` | `run`, `--dotenv`, `harden`, sources row, funnel rewords | discoverability |
| `Sources/RVCLI/Help/HelpDispatch.swift` | `case "run"` | `rv help run` must resolve |
| `Resources/Completions/rv.{bash,fish,zsh}` | new commands/flags | completions |
| `Tests/RVIsolationTests/DotenvFileTests.swift` (NEW) | parser tests | TDD Phase 1 |
| `Tests/RVIsolationTests/SecretsConfigurationTests.swift` | dotenv decode/round-trip/invalid cases | TDD Phase 1 |
| `Tests/RVIsolationTests/SecretProvidersTests.swift` (+NEW or extend) | resolver dotenv tests w/ injected reader | TDD Phase 1 |
| `Tests/RVIsolationTests/SecretLaunchBrokerTests.swift` | dotenv lease incl. policy denial | TDD Phase 1/4 |
| `Tests/RVPolicyTests/ManagedPolicyTests.swift` | dotenv allow/deny | TDD Phase 1 |
| `Tests/RVCLITests/SecretsCommandTests.swift` | import/harden/set-refusal tests | TDD Phases 2, 4 |
| `Tests/RVCLITests/InitCommandTests.swift` (#424) | `--dotenv` review/wiring tests | TDD Phase 2 |
| `Tests/RVCLITests/RunCommandTests.swift` (NEW) | arg splitting/resolution/warnings | TDD Phase 3 |
| `Tests/RVMCPTests/MCPGatewayRuntimeTests.swift` | dotenv `${secret:}` resolve + policy denial | TDD Phase 1/4 |
| docs (sources list + enterprise runbook) | dotenv row, strict sample policy | Phases 1, 4 |

Explicitly NOT touched: `VarlockSchema.swift` (schema contract frozen),
`SecretLaunchBroker.lease` staging/policy/audit logic (only resolver
construction becomes per-lease, 1.4), `WorkspaceSessionSupervisor`
launch path, `SecretGateway`, Keychain/Touch ID code,
`MCPGatewayRuntime.resolve` logic (unless D2-enforce),
`KnownSecretDefaults`, `ManagedCommand` allow-list rendering.

---

## 5. UX transcripts (exact commands + output sketches)

Conventions: `$` = shell, `...` = elided existing lines. All names/paths
escaped per `DisplayedText` rules. Values shown as `[REDACTED]` are never
printed by rv.

### 5.1 `rv init --dotenv` (dev tier, day one)

```
$ cd ~/proj && cat .env
STRIPE_SECRET_KEY=[REDACTED]
OPENAI_API_KEY=[REDACTED]
DEBUG=true
$ rv init --dotenv --dry-run
profile "main" for "/Users/ada/proj"
  link "codex" -> "/opt/homebrew/bin/codex"
dotenv /Users/ada/proj/.env: would bind 3 names (values stay in .env)
  bind STRIPE_SECRET_KEY (dotenv STRIPE_SECRET_KEY; delivery environment)
  bind OPENAI_API_KEY (dotenv OPENAI_API_KEY; delivery environment)
  bind DEBUG (dotenv DEBUG; delivery environment; not secret-looking)
dry run: nothing written
next: rv run --workspace /Users/ada/proj --resource-profile main -- python main.py
```

Bind-all with annotated review: the heuristic annotates/orders rows
(`not secret-looking`) but never skips. Without the flag, `.env` is
noticed but never bound:

```
$ rv init
profile "main" for "/Users/ada/proj"
...
note: /Users/ada/proj/.env exists with 3 entries; pass --dotenv to bind them (values stay in .env)
wrote runtime-resources.json
```

Write mode:

```
$ rv init --dotenv
profile "main" for "/Users/ada/proj"
  link "codex" -> "/opt/homebrew/bin/codex"
  secret "STRIPE_SECRET_KEY" (defined; staged at launch)
  secret "OPENAI_API_KEY" (defined; staged at launch)
  secret "DEBUG" (defined; staged at launch)
import STRIPE_SECRET_KEY: dotenv (delivery environment)
import OPENAI_API_KEY: dotenv (delivery environment)
import DEBUG: dotenv (delivery environment)
wrote secrets.json (3 secrets; delivery environment)
wrote runtime-resources.json
next: rv run --workspace /Users/ada/proj --resource-profile main -- python main.py
$ rv secrets list
STRIPE_SECRET_KEY  dotenv /Users/ada/proj/.env#STRIPE_SECRET_KEY  environment (real value in the cage)  profiles: main  [file-backed]
OPENAI_API_KEY     dotenv /Users/ada/proj/.env#OPENAI_API_KEY     environment (real value in the cage)  profiles: main  [file-backed]
DEBUG              dotenv /Users/ada/proj/.env#DEBUG              environment (real value in the cage)  profiles: main  [file-backed]
$ rv secrets check
ok    STRIPE_SECRET_KEY  fingerprint 9f2c…  dotenv /Users/ada/proj/.env#STRIPE_SECRET_KEY
ok    OPENAI_API_KEY     fingerprint 71ab…  dotenv /Users/ada/proj/.env#OPENAI_API_KEY
ok    DEBUG              fingerprint 33cd…  dotenv /Users/ada/proj/.env#DEBUG
```

### 5.2 `rv run -- CMD` (dev tier)

```
$ rv run --resource-profile main -- python main.py
rv run: runs on the persistent workspace host. Writes stay in the workspace. ... (isolation notice, mirrors opencode)
<program output; STRIPE_SECRET_KEY and OPENAI_API_KEY present in the cage environment>
$ rv run -- python -c 'import os; print("OPENAI_API_KEY" in os.environ)'
rv run: no --resource-profile selected; 3 dotenv-bound secrets would not stage. Pass --resource-profile <id> ... (stdout, exit 1)
```

Profile-less runs with dotenv bindings FAIL CLOSED AND LOUD (stdout +
nonzero exit). The draft's stderr-warning-only variant documented the
silent-non-injection trap and is rejected: the command above must never
print `True` or `False`.

### 5.3 `rv secrets import --dotenv` (explicit file)

```
$ rv secrets import --dotenv .env --dry-run
storing absolute path: /Users/ada/proj/.env
import STRIPE_SECRET_KEY: dotenv (delivery environment)
skip OPENAI_API_KEY: already bound to dotenv /Users/ada/other/.env#OPENAI_API_KEY
skip DEBUG: already defined in this project's environment
git: .env is ignored (check-ignore clean)
dry run: nothing written
$ rv secrets import --dotenv .env
storing absolute path: /Users/ada/proj/.env
import STRIPE_SECRET_KEY: dotenv (delivery environment)
skip OPENAI_API_KEY: already bound to dotenv /Users/ada/other/.env#OPENAI_API_KEY
wrote secrets.json (1 secret; delivery environment)
git: .env is ignored (check-ignore clean)
```

Skips name the existing locator (cross-project confusion is the
machine-global config's sharpest edge). `git check-ignore` line is
informational only.

### 5.4 `rv secrets harden` (enterprise tier)

```
$ printf %s 'new-rotated-value' | rv secrets set STRIPE_SECRET_KEY
rv secrets set: "STRIPE_SECRET_KEY" reads from dotenv /Users/ada/proj/.env#STRIPE_SECRET_KEY; rv secrets set only stores values it reads from rv.secrets
use `rv secrets harden STRIPE_SECRET_KEY` to move this value into the Keychain
$ rv secrets harden STRIPE_SECRET_KEY
hardened STRIPE_SECRET_KEY: dotenv /Users/ada/proj/.env#STRIPE_SECRET_KEY -> keychain rv.secrets/STRIPE_SECRET_KEY (delivery unchanged: environment; stored value verified)
rotation checklist for STRIPE_SECRET_KEY:
  - rotate the value at the provider (the old value is still live in .env)
  - remove the STRIPE_SECRET_KEY line from /Users/ada/proj/.env (rv never edits .env)
  - until removed, `rv secrets scan` will keep flagging the unrotated .env
$ rv secrets harden --all
hardened OPENAI_API_KEY: dotenv ... -> keychain rv.secrets/OPENAI_API_KEY (delivery unchanged: environment; stored value verified)
skip GH_TOKEN: reads from host $GH_TOKEN (not dotenv; nothing to harden)
```

Read-back value-equality verification runs before every rebind; a mismatch
leaves the dotenv binding and fails loud.

### 5.5 Strict posture (enterprise tier)

Org `policy.json`:
`{"version":1,"secrets":{"allowedSources":["keychain","vault"],"allowEnvironmentDelivery":false}}`

```
$ rv secrets check
FAIL  STRIPE_SECRET_KEY  organization policy: STRIPE_SECRET_KEY uses a dotenv source, which is not allowed  dotenv ...
$ rv secrets import --dotenv .env
organization policy: STRIPE_SECRET_KEY uses a dotenv source, which is not allowed; nothing imported
$ rv run --resource-profile main -- python main.py
... resourceStagingFailed: organization policy: STRIPE_SECRET_KEY uses a dotenv source, which is not allowed
$ rv managed status
...
secrets: allowed sources: keychain, vault (dotenv: forbidden; 2 dotenv-bound secrets will fail closed)
```

### 5.6 `rv secrets scan` with bound `.env`

```
$ rv secrets scan ~/proj
origin files (bound .env sources; not failures):
  /Users/ada/proj/.env (3 secrets bound)
FAIL  ./backup/.env-copy: STRIPE_SECRET_KEY value present (copy of a bound secret outside its origin file)
```

Exemption is per (file, secret): the values of the 3 bound secrets do
not fail the gate in their origin file. Any other secret's value found
in that same file still flags, and copies elsewhere still flag.

---

## 6. Test plan (TDD; failing test -> minimal fix -> refactor)

Per phase, new tests BEFORE production code. Swift Testing only;
fixture homes via temp dirs.

- Phase 1:
  - `DotenvFileTests`: grammar matrix (bare/quoted/export/comments/
    blank, whitespace around `=`, `#`-needs-space, CRLF, leading BOM,
    empty value parses), duplicate fail-closed + malformed-line
    per-file error scope, NUL/non-UTF8/oversize rejection, 256 KiB
    boundary both sides, `isVariableName` filtering, strictness-lint
    notes.
  - `SecretsConfigurationTests`: dotenv decode (happy + each invalid
    field), `encoded()` round-trip, unknown-key rejection, `..`
    rejection, decode succeeds with the bound file absent (no FS in
    decode).
  - Resolver tests: dotenv happy path via injected reader, missing file,
    missing variable, oversize, invalid content, value trimming/16 KiB/
    NUL via shared `SecretResolver.value`, error messages contain
    path+variable and never values (assert absence of the value string);
    snapshot identity-change test.
  - Reader trust tests: symlink to safe target resolves, to unsafe
    target refuses; FIFO/device refused under a watchdog (no hang);
    oversize-before-read; non-owner (root-owned fixture path);
    group-writable refused; 0644 allowed.
  - `SecretLaunchBrokerTests`: dotenv lease (environment + gateway
    deliveries), policy-denied dotenv row, dotenv + keychain mixed lease.
  - `ManagedPolicyTests`: `allowedSources` with/without `"dotenv"`,
    unknown-kind error still fires for typos.
  - `MCPGatewayRuntimeTests`: `${secret:NAME}` resolving a dotenv source;
    policy-denied dotenv server fails with the existing
    `secretUnavailable` shape.
  - `SecretsCommandTests`: `set` refusal on dotenv-bound names (+
    harden cross-link), `check`/`list`/`describe` rendering of dotenv
    rows incl. `[file-backed]`.
- Phase 2: import tests (dry-run, defined/invalid/reserved/exported/cap/
  empty/oversize-value skips, locator-bearing skips, exactly-one-of incl.
  no-flag error, absolutize-and-echo, `check-ignore` line + non-work-tree,
  policy refusal in dry run, lease-unreadable file refused at import,
  idempotent re-import); init tests (review text, dry-run writes nothing
  — assert mtimes/bytes, profile wiring, no-flag note, `--dotenv` with
  missing `.env` errors).
- Phase 3: `RunCommandTests` (`--` splitting, default-cwd project,
  profile-less fail-closed incl. exit code, executable resolution
  absolute/PATH/missing, hook-nil tagged-skip); opencode byte-identical
  suite proof.
- Phase 4: harden matrix (success / undefined / non-dotenv /
  policy-invalid / policy-forbids-keychain / keychain-fails-untouched /
  read-back mismatch via composed fake / `--all` mixed + exit codes +
  crash recovery simulated with a store-failing fake); scan origin
  granularity tests (other-secret-in-bound-file flags); M1/M2 skip tests
  (from Phase 1.10, re-verified); strict-posture e2e; downgrade proven
  at decode layer + runbook paragraph (no old-binary harness — do not
  claim an e2e downgrade test); `hook run` flagging staged `.env` edit.
- Gate every phase: `Scripts/swift-6.4` build, FULL `swift test` (all
  19 targets), `Scripts/preflight.sh`.

---

## 7. Rollout / sequencing vs #424

1. #424 merges first (or dotenv stacks on `feat/onboarding-fast-path`).
   Rationale: Phase 2 edits `InitCommand.swift`, `SecretsCommand.swift`
   (import struct + set-path helpers), `RV.swift`, `HelpCatalog.swift` —
   all #424-touched. #424's review commit (`32f211f5`) sets conventions
   dotenv follows (`shellWord` quoting, fail-loud reads).
2. `feat/dotenv-source` branches from the post-#424 tip; no parallel
   Phase 1 (R49: #424 edits `SecretsCommand.swift`/`HelpCatalog.swift`/
   completions that Phases 1-2 also touch).
3. Phases land in order 1 -> 2 -> 3 -> 4; each is independently
   shippable (1: source usable via hand-written secrets.json, with the
   ungated-resolver gates already in from 1.10; 2: ingestion; 3: run
   frontend; 4: harden+posture).
4. Flag/file conflicts to watch on rebase: `SecretsImport` options,
   `Secrets` subcommand list, `RV.swift` registration order,
   `HelpCatalog` rows, `secretSourceKinds`.
5. Fleet rollout (enterprise): binaries-before-policies. Ship binaries
   fleet-wide BEFORE pushing any policy that mentions dotenv; a new
   policy on an old binary fails the whole policy closed.

---

## 8. Risk register (adversarial review output)

Severity = max across the security, DX-parity, enterprise, and impl-risk
reviews. Owner-angle = who must accept or fix. All code citations were
inspected; Varlock-side claims are brief-only (varlock was not on PATH
for the reviewers). R48-R59 and RE-SCOPED/CORRECTED/SUPERSEDED markers
are from the second adversarial review (fact-checked against the
current tree + #424 worktree diff; see section 11).

| # | Risk | Sev | Owner-angle | Disposition in plan |
|---|------|-----|-------------|---------------------|
| R1 | Cage-writable `.env` = persistence channel into next lease | CRIT | RE-SCOPED (2nd review): blanket refusal breaks the dev-tier headline flow (`<project>/.env` is inside the writable workspace); accepted as dev-tier residual with snapshot + audit-fingerprint drift visibility; strict posture excludes dotenv | 2.5a + 3.3 + 3.7 |
| R2 | Harden-vs-lockdown deadlock unspecified (H1) | HIGH | enterprise owner DECISION: carve-out vs refusal | D1, blocks enterprise ship |
| R3 | MCP ignores delivery axis; "full lockdown" unenforced for MCP | HIGH | enterprise owner DECISION: enforce vs exempt | D2, blocks enterprise ship |
| R4 | No file-trust checks on dotenv read: symlink/owner/writability | HIGH | security: OwnerOnlyFile-STYLE checks on the canonical target (not verbatim reuse — R5/R52) | 3.3, must-fix |
| R5 | FIFO/device lease hang, no timeout | HIGH | security: S_ISREG gate. CORRECTED (2nd review): `OwnerOnlyFile.read` opens without `O_NONBLOCK` so a FIFO hangs at `open()` before `S_ISREG` — fix is `O_NONBLOCK` open + `fstat` + clear, applied to `OwnerOnlyFile` too | 3.3 item 1, must-fix |
| R6 | 256 KiB cap after full read = memory DoS | HIGH | security: st_size-first bounded read | 3.3, must-fix |
| R7 | Old binary + dotenv config/policy = whole-config or whole-policy failure | HIGH | impl+enterprise: runbook fleet rule + downgrade paragraph | 3.7 + 7.5, must-ship-with |
| R8 | `import` required-`--varlock` -> optional is breaking | HIGH | maintainer DECISION: accept break vs new subcommand | D4, decide pre-Phase-2 |
| R9 | `importDotenv` missing reserved/exported/cap pre-filters nukes whole write | HIGH | impl: pre-filter + note each skip | 4/Phase 2.1, must-fix |
| R10 | Per-call parse cache unimplementable in stateless closure | HIGH | SUPERSEDED (2nd review, R55): re-read-per-secret mixes generations within one lease; per-instance snapshot behind the closure + fresh resolver per lease | 3.3 |
| R11 | Phase 3 omits Prepare split / risks opencode behavior / hook-nil skips tagged | HIGH | impl: RunPrepare split, byte-identical proof, stated+tested hook semantics | 4/Phase 3, must-fix |
| R12 | Profile-less `rv run` silently stages zero secrets | HIGH | DX: fail-closed-loud, dotenv-framed | 4/Phase 3.3, must-fix |
| R13 | Scan always fails day-one on bound `.env` | HIGH | DX: origin-files section, no gate fail | 4/Phase 4.4, must-fix |
| R14 | `--dotenv` flag vs flagless schema auto-import contradiction | HIGH | owner DECISION (recommend keep flag + document) | D5, decide pre-Phase-2 |
| R15 | World-readable `.env` leaks via cat; warn-only | MED | security: sticky per-lease warning; runbook residual-risk | 4/Phase 1.9 + runbook |
| R16 | Committed `.env` forever; hook misses <8B values | MED | security: `git check-ignore` import line | 4/Phase 2.1 |
| R17 | Cross-project confusion via global config | MED | DX+enterprise: locator-bearing skips, machine-global docs | 4/Phase 2.1 + 1.9 |
| R18 | TOCTOU: attested names, unanchored values; drift silent | MED | CORRECTED (2nd review, R53): no import-time value-hash (no schema field; worse downgrade break); drift visible via per-lease audit fingerprints + `check` | 2.5a + 4/Phase 2.1 |
| R19 | First-wins duplicates attacker-preferred | MED | security: lease-time fail-closed per-variable (adjudicated) | 3.2 |
| R20 | Parser differentials vs shell/python-dotenv/docker | MED | security+DX: strictness lint; compat corpus | 3.2 |
| R21 | Default-allow: no-`allowedSources` orgs silently gain dotenv | MED | enterprise: managed-status must name dotenv; runbook warning | 4/Phase 4.3/4.5 |
| R22 | Import/resolver cap mismatch | MED | impl: single 256 KiB constant | 3.2 + 4/Phase 2.1 |
| R23 | Harden without read-back verification | MED | enterprise: read-back before rebind. CORRECTED: compare `SecretValue` equality, not truncated/nullable fingerprints | 3.6 |
| R24 | `--all` atomicity unspecified | MED | impl: single-write + crash semantics + test | 3.6 |
| R25 | Scan/hook/audit-forward resolve with no policy gate | MED->HIGH for audit-forward | enterprise: gates land in Phase 1.10, not 4 (2nd review: Phase 1 ships the source; audit-forward sends off-host and ignores invalid policy when `--to` given, `AuditForward.swift:305`) | 2.6 + 4/Phase 1.10 |
| R26 | Heuristic pre-filter inverts include-then-trim; `--secret` triple-loaded | MED | DX: bind-all annotated, heuristic never skips | 3.4 |
| R27 | Empty-state funnels teach enterprise flow first | MED | DX: reword hint/errors/abstract | 4/Phase 2.5 |
| R28 | `[weaker]` shames dev-tier default | MED | DX: scope/suppress for dotenv; add `[file-backed]` | D8 + 4/Phase 1.8 |
| R29 | No `load` equivalent | MED | DX: `load`->`check` map in help | 4/Phase 2.5 |
| R30 | Absolute bindings break on `mv`; relative-import contradiction | MED | DX: absolutize-and-echo | 4/Phase 2.1 |
| R31 | Run entrypoint sprawl; `next:` funnels past `rv run` | MED | DX: update `next:`, shared helper blocking | 4/Phase 2.5 + 3.2 |
| R32 | Harden keeps `.environment` under delivery-deny policy | MED | enterprise: warn; `--gateway` flag deferred | 3.6 |
| R33 | `set` refusal omits harden cross-link | LOW | DX: append cross-link for dotenv sources | 4/Phase 1.6 |
| R34 | Two ingestion doors, no layering story | LOW | DX: one front door + stated layering decision | 4/Phase 2.5 |
| R35 | Review table is receipt, not review | LOW | DX: receipt language; flag-is-attestation | 3.4 |
| R36 | Fingerprint equality oracle | LOW | security: awareness; no `--compare` | docs only |
| R37 | Path disclosure via errors | LOW | security: path+variable ok, no peeks | 3.3 |
| R38 | Harden-then-drift | LOW | enterprise: rotation checklist + scan warning | 3.6 |
| R39 | 8 KiB lease ceiling vs 16 KiB values (+ empty rejected by `SecretValue`) | LOW->HIGH | impl: import pre-filter skips empty + >8 KiB by name (2nd review, R51: otherwise whole lease fails) | 3.2 + 4/Phase 2.1 |
| R40 | Stale-`.env` scan cross-talk post-harden | LOW | enterprise: harden note warns | 3.6 |
| R41 | Missing surface files: HelpDispatch `run`, completions x3 | LOW | impl: add to Phases 2-4 | 4/Phases 2-4 |
| R42 | Init under-specification: fresh-names helper, read seam, planText tests | LOW | impl: specified subtasks | 4/Phase 2.3 |
| R43 | Harden test composition + Linux failure | LOW | impl: composed fake; platform-gated e2e | 3.6 |
| R44 | Symlink/TOCTOU live-read policy + cache key | LOW | security: allow+document or canonicalize | 3.1/3.3 |
| R45 | Locator path disclosure into robot JSON | INFO | enterprise: benign, consistent | none |
| R46 | Gateway fetch per-request no re-check | INFO | enterprise: by design, runbook note | runbook |
| R47 | No secrets.json backup before `--all` | INFO | enterprise: accepted, print pre-count | 3.6 |
| R48 | (2nd review) R1 refusal contradicts dev-tier flow + resolver has no workspace context | CRIT | security/DX: re-scope R1 to residual + visibility; no refusal plumbing | 2.5a, 3.3 |
| R49 | (2nd review) "Phase 1 zero overlap with #424" false: #424 changes 17 files incl. `SecretsCommand`/`HelpCatalog`/completions; Phase 1.6-1.8 edit same files | HIGH | impl: drop parallel start; all phases post-#424 | Status, 4/Phase 0, 7.2 |
| R50 | (2nd review) "Invalid policy fails closed everywhere" false; ledger missed `MCPCommand:944`, `ReportCommand:179-181`, `AuditForward --to` invalid-policy bypass | HIGH | enterprise: correct 2.2/2.6; gates in Phase 1.10 | 2.2, 2.6, 4/Phase 1.10 |
| R51 | (2nd review) Bind-all binds empty/>8 KiB values that fail the WHOLE lease (`SecretProviders:19`, `SecretLaunchBroker:118-125`) | HIGH | DX/impl: import pre-filter + named skips | 3.2, 4/Phase 2.1 |
| R52 | (2nd review) Import read unspecified: could bind lease-refused files (symlink/group-writable/FIFO); canonicalize-at-decode contradictions (pure decode; `write()` re-decode; parent-symlink swap) | HIGH | security/impl: same reader at import; lexical decode; canonicalize at read; symlinks allowed to checked target | 3.1, 3.3, 4/Phase 2.1 |
| R53 | (2nd review) Import-time value-hash has no schema home (`onlyKeys`224) and worsens downgrade break | HIGH | security: removed; use audit fingerprints | 4/Phase 2.1 |
| R54 | (2nd review) Scan origin exemption per-file would launder other secrets pasted into bound `.env`; matching basis unspecified (scanner yields resolved relative paths) | HIGH | security: per-(canonical path, secret) exemption | 4/Phase 4.4, 5.6 |
| R55 | (2nd review) Re-read-per-secret mixes file generations inside one lease (broker loop `SecretLaunchBroker:115-121`) | MED | impl: per-lease snapshot via fresh resolver | 3.3, 4/Phase 1.4 |
| R56 | (2nd review) Parser under-spec: malformed-line scope, spaces around `=`, CRLF, BOM losing first binding, `#`-needs-space | MED | impl/DX: specified in 3.2 + test matrix | 3.2, 6 |
| R57 | (2nd review) Mirror-import inherits dry-run-before-policy ordering (`SecretsCommand:365` vs `:368`) | MED | impl: policy check before dry-run return | 4/Phase 2.1 |
| R58 | (2nd review) Factual slips: `.live` sites 6 not 7; VarlockSchema builds 4 kinds inline; `resolveExecutable` internal with hardcoded `"opencode"` at `:31`; gate is full `swift test` (19 targets); completions tests exist | LOW | impl: corrected in place | 2.2, 2.7, 2.9, 3.3, 6 |
| R59 | (2nd review) Untestable-as-written: FIFO test hangs suite; downgrade e2e needs old binary; harden crash recovery unnamed | MED | tests: watchdog, decode-layer downgrade proof, fake-writer failure injection | 4/Phase 1 + 4 Verification, 6 |

Soundness confirmations (claims that survived BOTH attacks): the 5
exhaustive switch sites are complete; lease/check/import gates sit
pre-resolution and fail closed (scan/hook/audit-forward do NOT — R50);
the jail boundary (host-side lease only, cage gets
values/placeholders) holds; MCP kind-gate shape is correct as far as it
goes (see R3 for the axis it misses); §2.3-2.8 line citations other than
R58 items re-verified in the second review.

---

## 9. Open owner decisions

- **D1 (H1). Harden under dotenv-deny: carve-out or refusal?** Carve-out =
  harden reads dotenv despite deny, rewrites to allowed keychain, own audit
  event. Refusal = migrate-while-permissive rollout. [*Recommend carve-out:
  refusal strands locked-down orgs with no migration path.*] Blocks
  enterprise ship. Rider (2nd review): harden's resolution is not
  lease-gated today, so carve-out is also the ACCIDENTAL default if no
  gate is added — whichever way D1 lands, the plan mandates an explicit
  target-kind (`keychain` allowed) check + audit event so the behavior
  is a decision, not an omission.
- **D2 (H2). MCP delivery axis: enforce (H2a) or document exemption (H2b)?**
  Enforce = full `SecretOrganizationRules.violation` in
  `MCPGatewayRuntime.resolve`, existing `secretUnavailable` shape.
  [*Recommend enforce: one shared predicate, closes "full lockdown" lie.*]
  Blocks enterprise ship. Rider (2nd review): enforce is BREAKING for
  existing MCP deployments whose secrets use `.environment` delivery
  (MCP injects real values today, `MCPGatewayRuntime.swift:112`); it
  needs a release-note + `rv managed status` preview of affected
  servers, not just the predicate swap.
- **D3. Does `rv run` mean a new top-level Run command** (thin frontend
  over `runInteractive`, ~100 lines + tests + Prepare split) **or the
  existing launch paths generically** (delete Phase 3)? [*Recommend new
  top-level: the brief names `rv run -- CMD` and no top-level `run`
  exists.*]
- **D4. `SecretsImport` shape: accept the breaking change** (optional
  `--varlock` + exactly-one-of validation, updated tests) **or add a
  separate `import-dotenv` subcommand** (non-breaking, uglier)?
  [*Recommend accept break.*]
- **D5. `.env` ingestion: keep opt-in `--dotenv`** (flag IS the
  attestation; document schema asymmetry: schema carries no values) **or
  auto-detect like `.env.schema`** (flag/`--no-dotenv` as override)?
  [*Recommend keep opt-in: the no-silent-bindings constraint is
  explicit.*]
- **D6. Profile-less `rv run` with dotenv bindings: fail closed + loud**
  (stdout + nonzero exit) **or stage dotenv without a profile**?
  [*Recommend fail-closed-loud: silent non-injection is the exact
  forbidden silent behavior.*] Consequence stated in section 1: the
  mandatory `--resource-profile` is rv-only friction Varlock does not
  have; the parity claim is "approaches", not "matches".
- **D7. Adopt fail-closed-on-duplicates at lease** (per-variable error;
  import advisory) **or shell-convention last-wins**? [*Recommend
  fail-closed: first-/last-wins both let a prepend/append silently
  choose the injected value under an unauthenticated writer.*] Parser
  shape already decided in 3.2 (entries + per-line errors; malformed
  line = per-file scope) — D7 covers only the duplicate rule.
- **D8. `[weaker]` tag on dotenv rows: suppress/reword for dotenv**
  (source kind already communicates) **or keep every-row marking**?
  [*Recommend suppress for dotenv + `[file-backed]` marker instead.*]

---

## 10. Omitted scope (disclosed, not planned)

- Varlock `proxy run` (TLS-intercept injection): non-goal, gateway covers it.
- Varlock `load` worldview as a new command: covered by `check` + help map.
- `.env.schema` literal import: contract frozen.
- Project-relative dotenv paths (`$RV_PROJECT`/`~` escape hatch noted, not
  designed); multi-file layering (`.env.local` etc.) decided-only ("v1 binds
  exactly one file" to be stated, not built).
- Dotenv value interpolation/multiline/escapes: rejected, strict subset.
- Harden `--gateway` delivery-rewrite flag: deferred.
- `harden --verify-rotation` follow-up: noted, not planned.
- Future policy knob for owner-only-dotenv: docs-only, not built.
- `check --compare`: explicitly must NOT be built (fingerprint oracle).
- Any `.env` writes (edit/chmod/delete/git-ignore): forbidden, all phases.
- At-rest protection promises for dotenv sources: forbidden to promise.
- M1/M2 scan/hook/audit-forward gates: NOT omitted anymore — minimal
  gates land in Phase 1.10 (audit-forward full gate; scan/hook
  policy-aware skip). Only scan's origin-files UX waits for Phase 4.4.
- Cage-root-aware dotenv refusal (original R1 shape): not built; would
  need supervisor-to-resolver root plumbing and breaks the dev tier's
  `<project>/.env` flow (2.5a). Revisit only as an opt-in policy knob.
- Import-time value-hash / persistent drift baseline: not built (R53);
  drift surface is audit fingerprints + `check`.
- Linux harden e2e: platform-gated out (always fails).

## 11. Evidence index

- Working artifacts (scratch, not committed):
  `/tmp/rv-dotenv-plan/draft-plan.md` (773 lines),
  `review-security.md` (17 findings), `review-dx.md` (14 findings),
  `review-enterprise.md` (3 HIGH / 11 MED / 7 LOW + gate ledger),
  `review-impl.md` (9 SEV / 8 MED / 4 LOW), `final-plan.md` (merge source
  for this document).
- Re-inspected during synthesis: `MCPGatewayRuntime.swift:100-161`,
  `ReviewSanitizer.swift:259-304`, `MCPRedaction.swift:1-50`,
  `ManagedPolicy.swift:69-72,104-106`, `SecretProviders.swift:59-101`,
  `HelpCatalog.swift:438-441`, `SecretsCommand.swift:634-651`,
  `OwnerOnlyFile.swift:19-47`, `SecretsConfiguration.swift:155-190`.
- Second adversarial review (this revision): six angles — codebase
  fact-check, security/threat model, enterprise/policy/rollout,
  implementation feasibility, DX/parity, tests — plus falsification
  pass. Findings folded in as R48-R59 and the RE-SCOPED/CORRECTED/
  SUPERSEDED dispositions on R1/R5/R10/R18/R23/R25/R39. Re-inspected
  first-hand: `OwnerOnlyFile.swift:19-47`, `SecretProviders.swift:13-112`,
  `SecretLaunchBroker.swift:86-240`, `AuditForward.swift:209-356`,
  `SecretsConfiguration.swift:155-452`, `SecretStore.swift:104-242`,
  `MCPGatewayRuntime.swift:100-161`, `SecretsCommand.swift:278-407`,
  `VarlockSchema.swift:370-385`, `SecretFingerprint.swift:13-47`,
  `Scripts/preflight.sh`, `Scripts/swift-6.4`, #424 diff
  `2ae588bf..32f211f5` in the rv-onboard worktree.
- Carried open items (not decisions, need verification in implementation):
  whether the `runInteractive` legacy path stages dotenv leases
  unchanged (inferred from `WorkspaceCommand.swift:601-607`, not
  executed); exact `resolveExecutable` generalization shape preserving
  opencode byte-identical behavior (work item located:
  `OpenCodeCommand.swift:31`). RESOLVED since first draft: completions
  have tests (`CompletionsCatalogTests`); `<project>/.env`
  cage-writability no longer gates anything (R1 re-scoped, 2.5a) but
  per-launch-path writability remains unexecuted/inferred; GitHub PR
  number for #424 not verified via `gh` (branch + `32f211f5` verified
  locally); all Varlock behavior remains brief-only.

