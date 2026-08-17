# Phase 2 — Catalog (T9)

Locked law: [`docs/factory/PLAN.md`](../PLAN.md). If this spec and PLAN disagree, PLAN wins. Implement only in `~/CodingProjects/rv`. Never implement inside ryk.

Parity source: [Dicklesworthstone/destructive_command_guard](https://github.com/Dicklesworthstone/destructive_command_guard) **0.11.0** (tag `v0.11.0`, commit `2ed7eeef1ae63d204495f02312c657dd6d9bf73d`, pin file `vendor/parity/PIN` from T0). Not a Rust port. Not a `dcg` binary alias.

T9 is L2: remaining pack JSON is **in the binary as data**, default-off except `core.git` + `core.filesystem`, and `rv packs` can list / enable / disable. The day-one win does not change. Enabling the rest of the catalog by default is Phase 4+, not this ticket.

## Goal

Import the rest of the DCG 0.11.0 pack catalog into `RVPacks` as JSON, keep it off until the operator turns a pack on, and ship `rv packs`.

A fresh agent finishing T9 must leave behind:

1. **99** bundled pack documents (T1’s two core files plus the remaining 97), one generic decoder, **zero** per-pack Swift types.
2. Default enablement = `{core.git, core.filesystem}` only. `system.disk`, `windows.*`, `database.*`, `containers.*`, and every other ID stay off until enabled.
3. Category IDs and the `careful_company_running_windows` preset expand the same way DCG 0.11.0 does. `disabled` applies after expansion.
4. `rv packs` lists the catalog; `rv packs enable` / `disable` persist to rv-owned config under a **temp HOME** in tests.
5. T1 SKILL.md / core-pack corpus still green. One opt-in catalog fixture proves a disabled pack cannot deny, and the same command denies after enable.
6. `dcg test` vs `rv test` agree-rate is **not** a gate.

## Non-goals

- Enabling all 99 packs in v1. That policy flip is Phase 4+ (`phase-4-later.md`).
- Writing 99 Swift files, 99 regex engines, or one type per pack.
- Replacing T1’s `evaluate` order, ICU `PatternEngine`, or core corpus.
- Making `system.disk` default-on (DCG 0.11.0 does; rv v1 does not).
- Claiming Linux, Windows, Intel, or macOS 14/15 because Windows / Linux *patterns* exist as data.
- External / custom pack YAML, network install of packs, `rv pack validate`.
- Heredoc / AST, scan, SARIF, MCP, Mac app.
- Host codecs, `install.sh`, doctor probes, allow-once (T4–T8).
- `RV_BYPASS`, `RV_PACKS`, or any env the hook child honors to change evaluate or skip it.
- Shipping `dcg` as a dependency or vendoring the DCG Rust tree into this repo.
- Line-for-line Rust. Pack-specific DCG helpers (`kubernetes.kubectl` dry-run, deferred SCP matchers, and so on) are **quarantine**, not 99 special-case Swift files.

## Depends on

| Dependency | Why T9 needs it |
|---|---|
| **T0** | Module graph, `Sources/RVPacks/Resources/packs/`, `tools/extract-packs/`, `vendor/parity/PIN`. |
| **T1** | Domain newtypes, `evaluate`, ICU `PatternEngine`, pack JSON **schema**, `core.git` + `core.filesystem` documents, SKILL.md corpus. T9 extends that schema; it does not fork a second format. |
| **T2** (if already merged) | `PacksViewModel` / pretty renderer. T9 owns the `rv packs` command and feeds the full catalog into T2’s builder. T2’s day-one snapshot (`core.*` on, extras off) must stay true. |
| **T3** (if already merged) | `listPacks` / `setPackEnabled` on `rv.ipc.v1`. T9 fills the registry side. Do not rename IPC verbs. |
| **T7** (if already merged) | Doctor may read enabled/total counts. T9 does not reimplement doctor. |

T9 does **not** depend on T8. T4–T7 are not required to start T9.

If T1’s JSON schema is already on disk, follow it and add only missing catalog fields (`category`, `executables`, `suggestions`, index/preset/tier metadata). If T1 is green but the extractor is core-only, T9 generalizes that same extractor — it does not add a second parser.

## Parallel / worktree

After T1’s corpus is green, **T8 and T9 may run in parallel worktrees** from the **same base SHA**:

| Ticket | Branch | Owns | Must not |
|---|---|---|---|
| T8 | `feat/t8-allow-once` | TTY allow-once, allowlist store | Invent `RV_BYPASS`; enable extra packs |
| T9 | `feat/t9-catalog` | Catalog JSON, registry, packs config section, `rv packs` | Enable extra packs by default; rewrite T8 files |

Do not share a working tree. Do not both edit `Package.swift` module graph. T9 must not add modules or executable products; `Resources/packs` is already reserved.

T9 file split vs T8 inside `RVPolicy`: T9 adds only packs enable/disable types and merge. T8 adds only allow-once / allowlist. Additive files, not one shared god-file rewrite.

T9 may land before or after T2/T3/T4–T7. Feature-detect: if Presentation’s `packsViewModel` exists, use it; if IPC verbs exist, implement them; otherwise in-process registry + CLI is enough for this ticket’s gate.

## Pack registry and enable/disable

`RVPacks` owns the bundled catalog, decode, registry, and enablement expansion. `RVPolicy` owns config merge (what the operator persisted). `RVEngine` evaluates **only the effective enabled set**, in DCG tier order. `RVCLI` is a thin command. The engine must not parse JSON or read `FileManager`.

### Default enablement (rv v1, not DCG)

| Set | Pack IDs |
|---|---|
| Default-on | `core.filesystem`, `core.git` |
| Default-off | The other 97 IDs, including `system.disk` and all `windows.*` |

DCG 0.11.0 no-config defaults are `core.*` (always on, cannot disable) plus `system.disk` (opt-out) and, on Windows, `windows.filesystem` + `windows.system`. **rv does not copy those extras.** Document the delta in `docs/dev/PARITY.md` when T9 lands. Phase 4+ may revisit `system.disk`.

Core packs **may** be explicitly disabled (uniform algebra; doctor warns). They stay default-on when the operator has no packs config.

### Effective set

```
defaults = {core.filesystem, core.git}
effective = (defaults ∪ expand(config.enabled)) − expand(config.disabled)
```

`expand`:

1. A **pack ID** adds itself.
2. A **category ID** (first path segment, or the whole ID when there is no `.`) adds every pack in that category.
3. The **preset** ID `careful_company_running_windows` adds its six sub-packs **and** the pinned member list below. This is a hand-maintained table, not “every `database.*` forever.” New DCG packs must not join the preset silently.
4. `disabled` runs after expansion. `disabled = ["database.redis"]` can drop one child of `enabled = ["database"]`.
5. Unknown IDs and DCG graduation names (`paranoid` is **not** a pack) do not expand. CLI `enable`/`disable` fail with a typed error. Config load skips unknown IDs and surfaces them to doctor — evaluate must not crash.

No repository `.rv.toml` / `.dcg.toml` trust in T9. No `RV_PACKS` / `DCG_PACKS` env. Tests inject `PacksConfig` or write a temp-HOME config file.

### Config (rv-owned)

Path: `$HOME/.config/rv/config.toml` (T6 may already create the directory; T9 writes only the packs section). Tests **must** use a temp HOME.

```toml
[packs]
enabled = [
  # extras only; core.* stay on unless listed under disabled
  # "database",
  # "containers.docker",
]
disabled = [
  # "core.git",            # allowed; doctor warns
  # "database.redis",
]
```

Do not generate DCG’s starter that turns on `database.postgresql` + `containers.docker`. A missing file or missing `[packs]` table means defaults only.

### Evaluation order when several packs are on

Same as DCG 0.11.0 `expand_enabled_ordered`: sort by **tier**, then lexicographic ID inside the tier. A pack’s safe patterns suppress only **that** pack’s destructive patterns.

| Tier | Categories |
|---|---|
| 0 | `safe` (no `safe.*` packs in 0.11.0; keep the slot, do not invent packs) |
| 1 | `core`, `storage`, `remote` |
| 2 | `system` |
| 3 | `infrastructure` |
| 4 | `apigateway`, `cdn`, `cloud`, `dns`, `loadbalancer`, `platform` |
| 5 | `kubernetes` |
| 6 | `containers` |
| 7 | `backup`, `database`, `messaging`, `search` |
| 8 | `package_managers` |
| 9 | `strict_git` |
| 10 | `cicd`, `email`, `featureflags`, `secrets`, `monitoring`, `payment` |
| 11 | `windows` |
| 12 | `careful_company_running_windows` |
| 13 | unknown |

`strict_git` and `package_managers` are both a pack ID and a category ID (no `.` child).

### Confirmed DCG 0.11.0 catalog

Confirmed from tag `v0.11.0` [`docs/packs/README.md`](https://github.com/Dicklesworthstone/destructive_command_guard/blob/v0.11.0/docs/packs/README.md) and `src/packs/mod.rs` `PACK_ENTRIES: [PackEntry; 99]`. **27 categories, 99 pack IDs.** If an extractor run at the pinned commit disagrees with this table, **stop and re-diff this spec against 0.11.0**. The pin + DCG files win.

Categories (pack counts):

| Category | Count | Packs |
|---|---|---|
| `apigateway` | 3 | `apigateway.apigee`, `apigateway.aws`, `apigateway.kong` |
| `backup` | 4 | `backup.borg`, `backup.rclone`, `backup.restic`, `backup.velero` |
| `careful_company_running_windows` | 6 | `careful_company_running_windows.chat`, `.email`, `.guardrails`, `.transfer`, `.tunnel`, `.upload` |
| `cdn` | 3 | `cdn.cloudflare_workers`, `cdn.cloudfront`, `cdn.fastly` |
| `cicd` | 4 | `cicd.circleci`, `cicd.github_actions`, `cicd.gitlab_ci`, `cicd.jenkins` |
| `cloud` | 3 | `cloud.aws`, `cloud.azure`, `cloud.gcp` |
| `containers` | 3 | `containers.compose`, `containers.docker`, `containers.podman` |
| `core` | 2 | `core.filesystem`, `core.git` |
| `database` | 8 | `database.bigquery`, `database.mongodb`, `database.mysql`, `database.postgresql`, `database.redis`, `database.snowflake`, `database.sqlite`, `database.supabase` |
| `dns` | 3 | `dns.cloudflare`, `dns.generic`, `dns.route53` |
| `email` | 4 | `email.mailgun`, `email.postmark`, `email.sendgrid`, `email.ses` |
| `featureflags` | 4 | `featureflags.flipt`, `featureflags.launchdarkly`, `featureflags.split`, `featureflags.unleash` |
| `infrastructure` | 4 | `infrastructure.ansible`, `infrastructure.atmos`, `infrastructure.pulumi`, `infrastructure.terraform` |
| `kubernetes` | 3 | `kubernetes.helm`, `kubernetes.kubectl`, `kubernetes.kustomize` |
| `loadbalancer` | 4 | `loadbalancer.elb`, `loadbalancer.haproxy`, `loadbalancer.nginx`, `loadbalancer.traefik` |
| `messaging` | 4 | `messaging.kafka`, `messaging.nats`, `messaging.rabbitmq`, `messaging.sqs_sns` |
| `monitoring` | 5 | `monitoring.datadog`, `monitoring.newrelic`, `monitoring.pagerduty`, `monitoring.prometheus`, `monitoring.splunk` |
| `package_managers` | 1 | `package_managers` |
| `payment` | 3 | `payment.braintree`, `payment.square`, `payment.stripe` |
| `platform` | 5 | `platform.github`, `platform.gitlab`, `platform.kamal`, `platform.modal`, `platform.railway` |
| `remote` | 3 | `remote.rsync`, `remote.scp`, `remote.ssh` |
| `search` | 4 | `search.algolia`, `search.elasticsearch`, `search.meilisearch`, `search.opensearch` |
| `secrets` | 4 | `secrets.aws_secrets`, `secrets.doppler`, `secrets.onepassword`, `secrets.vault` |
| `storage` | 4 | `storage.azure_blob`, `storage.gcs`, `storage.minio`, `storage.s3` |
| `strict_git` | 1 | `strict_git` |
| `system` | 3 | `system.disk`, `system.permissions`, `system.services` |
| `windows` | 4 | `windows.filesystem`, `windows.misc`, `windows.powershell`, `windows.system` |

Frozen pack ID list (lexicographic; extractor must emit exactly these 99):

```
apigateway.apigee
apigateway.aws
apigateway.kong
backup.borg
backup.rclone
backup.restic
backup.velero
careful_company_running_windows.chat
careful_company_running_windows.email
careful_company_running_windows.guardrails
careful_company_running_windows.transfer
careful_company_running_windows.tunnel
careful_company_running_windows.upload
cdn.cloudflare_workers
cdn.cloudfront
cdn.fastly
cicd.circleci
cicd.github_actions
cicd.gitlab_ci
cicd.jenkins
cloud.aws
cloud.azure
cloud.gcp
containers.compose
containers.docker
containers.podman
core.filesystem
core.git
database.bigquery
database.mongodb
database.mysql
database.postgresql
database.redis
database.snowflake
database.sqlite
database.supabase
dns.cloudflare
dns.generic
dns.route53
email.mailgun
email.postmark
email.sendgrid
email.ses
featureflags.flipt
featureflags.launchdarkly
featureflags.split
featureflags.unleash
infrastructure.ansible
infrastructure.atmos
infrastructure.pulumi
infrastructure.terraform
kubernetes.helm
kubernetes.kubectl
kubernetes.kustomize
loadbalancer.elb
loadbalancer.haproxy
loadbalancer.nginx
loadbalancer.traefik
messaging.kafka
messaging.nats
messaging.rabbitmq
messaging.sqs_sns
monitoring.datadog
monitoring.newrelic
monitoring.pagerduty
monitoring.prometheus
monitoring.splunk
package_managers
payment.braintree
payment.square
payment.stripe
platform.github
platform.gitlab
platform.kamal
platform.modal
platform.railway
remote.rsync
remote.scp
remote.ssh
search.algolia
search.elasticsearch
search.meilisearch
search.opensearch
secrets.aws_secrets
secrets.doppler
secrets.onepassword
secrets.vault
storage.azure_blob
storage.gcs
storage.minio
storage.s3
strict_git
system.disk
system.permissions
system.services
windows.filesystem
windows.misc
windows.powershell
windows.system
```

Preset members for `careful_company_running_windows` (DCG 0.11.0 `CAREFUL_COMPANY_PRESET_MEMBERS`, 30 IDs, pinned):

```
backup.borg
backup.rclone
backup.restic
backup.velero
cloud.aws
cloud.azure
cloud.gcp
database.bigquery
database.mongodb
database.mysql
database.postgresql
database.redis
database.snowflake
database.sqlite
database.supabase
remote.rsync
remote.scp
remote.ssh
secrets.aws_secrets
secrets.doppler
secrets.onepassword
secrets.vault
storage.azure_blob
storage.gcs
storage.minio
storage.s3
windows.filesystem
windows.misc
windows.powershell
windows.system
```

Enabling the preset therefore turns on those 30 plus the six `careful_company_running_windows.*` leaves (36 packs), minus any `disabled` entries. It does **not** turn on `core.*` via the preset; core stays on through defaults.

`src/packs/safe/` exists upstream and is **not** in `PACK_ENTRIES`. Do not invent `safe.*` catalog IDs. Heredoc is `[heredoc]` config in DCG, not a pack — out of T9.

## Extractor contract

DCG 0.11.0 packs are **Rust sources** (`safe_pattern!` / `destructive_pattern!` / `Pack { ... }`), not JSON. Runtime rv never talks to GitHub and never downloads packs.

### Inputs

- `--source-root` = a **local** checkout of DCG at the T0 pin (`version=0.11.0`, tag `v0.11.0`, commit `2ed7eeef1ae63d204495f02312c657dd6d9bf73d`).
- Refuse to write output if `Cargo.toml` `package.version` is not `0.11.0` or `git rev-parse HEAD` is not the pinned commit (or a tree whose `src/packs` matches that commit).
- Do not clone DCG into `~/CodingProjects/rv`. Do not copy `*.rs` packs into rv.

### How the extractor produces the catalog

Prefer **one** method, the same one T1 used for core:

1. **Best:** a small Rust helper under `tools/extract-packs/` that depends on the local DCG crate, walks `PackRegistry::all_pack_ids()`, instantiates each pack, and serializes data fields (not Aho-Corasick / RegexSet caches).
2. **Acceptable:** T1’s existing Rust-source parser, generalized to every `create_pack` under `src/packs/*/`.
3. **Forbidden:** hand-transcribing 99 packs into Swift; scraping `dcg packs --verbose` (counts only, no regexes); fetching JSON from the network; checking `dcg` on PATH as a build step.

`dcg packs` / `dcg packs --verbose` are **verification aids** (IDs, names, pattern counts) when `dcg` 0.11.0 happens to be installed. They are not the extractor and not a v1 gate.

### Output

One JSON file per pack, plus an index:

```
Sources/RVPacks/Resources/packs/index.json
Sources/RVPacks/Resources/packs/core.git.json
Sources/RVPacks/Resources/packs/core.filesystem.json
Sources/RVPacks/Resources/packs/database.sqlite.json
… (99 pack files, filename == "{id}.json")
```

`index.json` (normative keys; pretty-printed, stable key order):

```json
{
  "schema_version": 1,
  "dcg_version": "0.11.0",
  "dcg_tag": "v0.11.0",
  "dcg_commit": "2ed7eeef1ae63d204495f02312c657dd6d9bf73d",
  "pack_count": 99,
  "default_enabled": ["core.filesystem", "core.git"],
  "categories": {
    "core": ["core.filesystem", "core.git"]
  },
  "presets": {
    "careful_company_running_windows": ["backup.borg"]
  },
  "tiers": {
    "core": 1,
    "strict_git": 9
  }
}
```

`categories` must list all 27 keys. `default_enabled` must be exactly the two core IDs. `presets.careful_company_running_windows` must be the 30-member list (sub-packs come from the category, not this array).

Pack document (shared with T1; additive fields allowed, no second schema):

```json
{
  "schema_version": 1,
  "dcg_version": "0.11.0",
  "id": "database.sqlite",
  "name": "SQLite",
  "description": "Protects against destructive SQLite operations…",
  "category": "database",
  "keywords": ["sqlite", "sqlite3", "DROP", "TRUNCATE", "DELETE"],
  "safe_patterns": [
    { "name": "select-query", "pattern": "(?i)^\\s*SELECT\\s+" }
  ],
  "destructive_patterns": [
    {
      "name": "drop-table",
      "pattern": "(?i)\\bDROP\\s+TABLE\\b",
      "description": "DROP TABLE permanently deletes the table (even with IF EXISTS). Verify it is intended.",
      "severity": "critical",
      "explanation": "DROP TABLE permanently removes a table…",
      "suggestions": [],
      "executables": null
    }
  ]
}
```

| Field | Rule |
|---|---|
| `id` | Exact DCG pack ID. Filename must match. |
| `category` | `id.split(".").first` (or the whole id when there is no `.`). |
| `keywords` | Exact DCG keyword list (quick-reject). Empty list = always consider the pack. |
| `safe_patterns[].name` / `pattern` | Required. |
| `destructive_patterns[].name` | Required for `rule_id` = `pack_id` + `:` + `name` (T1 spelling). If DCG `name` is `None`, extractor **fails** and lists the pattern — do not invent slugs. |
| `description` | T1 key for the short deny sentence (DCG `reason`). Do not rewrite. Decode `reason` as an alias only — not a second schema. |
| `severity` | `critical` / `high` / `medium` / `low`. DCG default is `high`. |
| `explanation` / `suggestions` / `executables` | Preserve when present. `executables` are lowercase basenames, no path/extension. `suggestions[].platform` is `all` / `linux` / `macos` / `windows` / `bsd`. |
| Runtime-only DCG fields | Drop: `keyword_matcher`, `safe_regex_set`, `safe_regex_set_is_complete`. |

Regex dialect stays DCG’s (fancy-regex / lookaround). T1’s ICU engine + corpus quarantine still apply. A catalog pattern that ICU cannot compile is recorded. **critical/high** compile-fail → do not enable that pack (typed error), do not skip-and-serve. medium/low may quarantine-by-name. Do not change a decision to paper over a dialect miss. Do not block T9 on full-catalog ICU parity for medium/low.

### Extractor verification (must fail the extract, not silently ship)

1. `pack_count == 99`.
2. ID set equals the frozen list above.
3. Every `PACK_ENTRIES` id has a JSON file; every JSON `id` is in `PACK_ENTRIES`.
4. `default_enabled` is only `core.filesystem` and `core.git`.
5. Category map has 27 keys; each category’s members match `id.split(".").first`.
6. Preset array equals the 30-member list.
7. T1 core files are updated in place if the extractor re-emits them; core corpus must still pass.
8. If any check fails: no partial commit. Re-diff this spec against 0.11.0 `docs/packs/README.md` + `src/packs/mod.rs` at the pin.

Update `vendor/parity/EXTRACT.md` with the real command line. Runtime rv does not run the extractor.

## rv packs CLI

T9 adds the `packs` subcommand. T2 already reserved pretty packs rendering and forbade shipping this command.

```
rv packs
rv packs --enabled
rv packs --json
rv packs --robot
rv packs enable <id> [<id>...]
rv packs disable <id> [<id>...]
rv packs info <id>
```

| Command | Behavior |
|---|---|
| `rv packs` | List all 99, IDs sorted. Show enabled flag, category, short description. Pretty on TTY human CLI via T2 `PacksViewModel` when present; otherwise plain lines. |
| `--enabled` | Only effective-on packs. Fresh install → exactly two rows. |
| `--json` / `--robot` | One JSON object on stdout (below). No pretty panel. |
| `enable` / `disable` | Expand, persist `[packs]` in `$HOME/.config/rv/config.toml`, print one line: what changed + new enabled count. Unknown ID → typed error, exit non-zero, no write. |
| `info` | One pack: id, name, category, enabled, keyword count, safe/destructive counts. `--json` supported. Do not dump every regex in pretty mode (too loud). `--json` may include pattern **names** (not a second essay). |

Robot / JSON list shape (align with DCG `PacksOutput` so later agree-rate is cheap, without being a gate):

```json
{
  "schema": "rv.packs.v1",
  "packs": [
    {
      "id": "core.git",
      "name": "Core Git",
      "category": "core",
      "description": "…",
      "enabled": true,
      "safe_pattern_count": 0,
      "destructive_pattern_count": 0
    }
  ],
  "enabled_count": 2,
  "total_count": 99
}
```

Voice: one fact, one next action. Allow stays silent on hooks. `rv packs` is a human/robot catalog command, not a hook.

Browse: if T2’s browse kit exists, `rv packs` **may** enter browse when stdin+stdout are TTYs and no `--json`/`--robot`/`--plain`/`CI`/`NO_COLOR`. Not an L2 gate. Do not open a TTY from tests.

IPC (when T3 is present):

- `listPacks` → same rows as `rv packs --json` (enabled flags from effective set).
- `setPackEnabled` → same persist path as CLI enable/disable. Unix socket remains tests-only.

`RVCLI` must not parse pack JSON. It asks `RVPacks` / `RVPolicy` (in-process or via IPC + in-process fallback if T3 exists). Down/skew `rvd` still evaluates in-process with the same catalog.

## Files to create

Do not change `Package.swift` dependencies or products. Do not add a module. Do not write 99 `*Pack.swift` files.

```
tools/extract-packs/          # real extractor (README + implementation). No DCG Rust tree copied in.
vendor/parity/EXTRACT.md       # update: command, pin check, output paths (T0 placeholder → real)

Sources/RVPacks/Resources/packs/index.json
Sources/RVPacks/Resources/packs/<id>.json          # 99 files; T1 core files reused

Sources/RVPacks/PackDocument.swift                 # Codable value type for one pack JSON
Sources/RVPacks/PackIndex.swift                    # Codable index
Sources/RVPacks/PackRegistry.swift                 # load bundle, lookup, expand, ordered IDs
Sources/RVPacks/PackEnablement.swift               # defaults ∪ expand(enabled) − expand(disabled)

Sources/RVPolicy/PacksConfig.swift                 # [packs] enabled/disabled merge only

Sources/RVCLI/PacksCommand.swift                   # ArgumentParser subcommand; thin

Tests/RVPacksTests/CatalogLoadTests.swift          # 99 IDs, 27 categories, decode all JSON
Tests/RVPacksTests/EnablementTests.swift           # defaults, category, preset, disable-after-expand
Tests/RVEngineTests/Fixtures/catalog/              # small opt-in fixtures (not 99 corpora)
Tests/RVEngineTests/CatalogEnablementCorpusTests.swift
Tests/RVCLITests/PacksCommandTests.swift           # temp HOME; --json counts
```

If T2/T3 files already exist, **call** them. Do not duplicate `PacksViewModel` or invent `listPacks2`.

Presentation: T2’s `packsViewModel(enabled:catalog:)` must accept the full 99-row catalog. Day-one pretty snapshot still shows only two enabled.

Quarantine files (only if ICU cannot compile a specific catalog rule):

```
Tests/RVEngineTests/Fixtures/corpus/quarantine/<pack_id>--<rule_name>.md
```

One file per mismatch. Do not silently drop the rule from JSON.

## Acceptance

T9 passes when all of the following are true:

1. Bundled catalog decodes **99** packs. ID set equals the frozen list. Index has **27** categories.
2. No-config / empty `[packs]`: effective set is exactly `{core.filesystem, core.git}`. `system.disk` is off. `windows.*` are off. `database.postgresql` and `containers.docker` are off.
3. T1 L2 corpus (SKILL.md + core fixtures) is still green. `git reset --hard` still denies with T1’s `rule_id`.
4. Catalog fixture: a command that only a non-core pack denies (e.g. `DROP TABLE users` / `database.sqlite:drop-table`) **allows** with defaults and **denies** after that pack is enabled. Same `rule_id` as DCG 0.11.0 when the pattern name exists.
5. `rv packs --json` (temp HOME): `total_count == 99`, `enabled_count == 2`.
6. `rv packs enable database` enables all eight `database.*` packs; `disable database.redis` leaves the other seven on.
7. `rv packs enable careful_company_running_windows` enables the six leaves plus the 30 pinned members; a listed `disabled` member stays off.
8. `rv packs enable paranoid` (or any unknown ID) fails; config is unchanged.
9. There are not 99 pack Swift sources. One decoder loads all documents.
10. Extractor, if re-run at the pin, is a no-diff (or a documented bless) against committed JSON.
11. `dcg` agree-rate was **not** used as a pass/fail gate.
12. No ryk edits. No live HOME writes. No `RV_BYPASS`. PLAN unchanged.

Gate: **L2** (catalog completeness + default-off + one enablement fixture + core corpus). Not a 99-pack golden table.

## Test plan

Run on the operator’s Apple Silicon Mac from `~/CodingProjects/rv`. Temp HOME for every CLI persist test. Do not write `~/.config/rv` on the human account. Do not install or invoke ryk. Invoking `dcg` is optional and never a gate.

1. `swift test` — T1 corpus + new `RVPacks` / catalog / CLI tests green.
2. `CatalogLoadTests`: load index + every JSON; `Set` of IDs == frozen 99; 27 category keys; `default_enabled` == two core IDs.
3. `EnablementTests` (pure): defaults; `enabled=["kubernetes"]` → three k8s packs + core; `enabled=["database"], disabled=["database.redis"]`; preset membership; unknown ID rejected at CLI / skipped in config; `strict_git` and `package_managers` enable as single IDs.
4. `CatalogEnablementCorpusTests`: in-process `evaluate` with injected `PacksConfig` — disabled catalog pack does not deny; enabled pack denies with expected `pack_id`/`rule_id`. Keep the fixture set **small** (sqlite + one category + one preset member is enough). Quarantine ICU misses; do not flip the expected decision.
5. `PacksCommandTests`: temp HOME; `rv packs --json` counts; enable/disable rewrite only `[packs]`; second enable is idempotent; disable of an already-off extra pack is a no-op success.
6. Grep guard: `Sources/**/*.swift` has no `struct DatabasePostgresqlPack` (or 99 siblings). `Resources/packs` has `index.json` + 99 `*.json`.
7. Grep guard: no `RV_BYPASS`, no `RV_PACKS`, no network URL used to fetch packs at runtime.
8. Optional, not a gate: if `dcg` 0.11.0 is on PATH, an operator may compare `dcg packs --format json` IDs to `rv packs --json` IDs. Do not fail CI on agree-rate.

No L3 hook or L4 setup tests in T9. No live Grok/Pi/OpenCode.

## Forbidden

From PLAN, and T9-specific:

- Enabling the remaining 97 packs by default, or copying DCG’s `system.disk` / Windows default-on policy.
- Writing 99 Swift pack files or a per-pack regex engine.
- `RV_BYPASS`, `RV_PACKS`, or any hook-child env that skips or widens evaluate.
- Network install of packs. Runtime fetch. Vendoring DCG Rust into this repo.
- Treating `dcg test` agree-rate as a v1 / T9 gate.
- Claiming Linux/Windows/macOS 14/15/Intel support, OS-enforced, or Seatbelt.
- Custom Pi renderer, OpenCode toast, host Allow button.
- Writing foreign hook files or the human’s real HOME.
- Persisting command text to `os_log` or turning history on.
- Telemetry, SaaS.
- Implementing inside ryk. Installing or rebinding ryk.
- Editing `docs/factory/PLAN.md`.
- Starting T9 before T1 is green, or sharing a tree with T8.

## Open questions

Resolved for T9 (do not re-litigate):

- Catalog is data. Default-off except `core.git` + `core.filesystem`.
- 99 IDs / 27 categories are confirmed for 0.11.0; extractor must still verify the pin and force a spec re-diff on mismatch.
- `system.disk` stays default-off in rv v1.
- Agree-rate vs `dcg` is later scoreboard, not a gate.
- No external YAML packs in v1.
- No `RV_PACKS` env.
- Destructive short-deny key is T1 `description`; `reason` is a decode alias only.

Still open (do not block T9):

- Whether T7 doctor copy should mention “97 packs available, off” (T7 owns wording; T9 only exposes counts).
- Whether browse-on-`rv packs` is wired in this ticket or waits for a polish pass (not a gate).
- Phase 4+ default-on for `system.disk` or the full catalog.

## Definition of done

T9 is done when the 0.11.0 catalog is bundled as JSON (99 IDs, 27 categories), only `core.git` and `core.filesystem` evaluate by default, `rv packs` can list and persist enable/disable under a temp HOME, one non-core fixture proves off→on, the T1 corpus is still green, there are not 99 Swift pack files, and agree-rate vs `dcg` was not used as a gate.

Gate: **L2**. Parallel sibling: **T8** (`feat/t8-allow-once`). Next product work after T0–T9: v1 is complete; Phase 4+ stays spec-only until the human kicks it off.
