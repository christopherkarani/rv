# Program: File-tool secrets + operable policy

**Date:** 2026-09-12  
**Status:** ready_for_implementor  
**Handoff (new session):** paste `planning/2026-09-12-file-tool-secrets/PROMPT.md`  
**Source plans:** this conversation’s product lock; `docs/factory/STATUS.md` `CL-later-secrets`; `docs/factory/specs/claude-host.md` fence; `docs/architecture/02.md` (do not start OPE-156 / Host Ask from this name)  
**Repo / branch assumptions:** `/Users/chriskarani/CodingProjects/rv` from current tip. Branch `feat/file-tool-secrets`. Apple Silicon, Swift 6.3.3 via `tools/swift-6.3.3`, warm `.build`.  
**Stop line:** This program ships **Read / Edit / Write secret-path guards** on **Claude, Cursor, and Grok**, plus **normal/strict**, **repo-shareable allow paths**, and a **denial-only block ledger**. It does **not** hook Grep / Glob / MCP, does **not** start Host Ask (OPE-264), does **not** add `ProposedAction.file` / `.mcp`, does **not** turn `RVHistory` into allow-logging, does **not** invent a GUI or Homebrew.

---

## 0. One-line goal

If an agent Reads `.env`, `~/.ssh`, cloud creds, or a host auth file, rv denies it. `rv setup` is still the only install step. People get a normal/strict knob, a repo file they can share, and `rv blocks` so a deny is visible.

---

## 1. Tree-truth ledger

| ID | Slice / finding | Status | Evidence | Residual if partial |
|----|-----------------|--------|----------|---------------------|
| F-law-v1 | AGENTS / PLAN forbid Read/Edit/MCP in v1 | landed (forbid) | `AGENTS.md`; `docs/factory/PLAN.md` | W1 amends a **named exception** |
| F-fence | `CL-later-secrets` named, not started | open | `docs/factory/STATUS.md`; `docs/factory/specs/claude-host.md` §1 | this program |
| F-catalog | `SecretPathCatalog.dayOne` exists; shell operands only | partial | `Sources/RVDomain/SecretPathCatalog.swift`; `Sources/RVEngine/SecretPathGuard.swift` | missing Claude/Cursor/Codex/Hermes/OpenClaw auth rows |
| F-pin | Secret / protected-path denies are not unlockable | landed | `CONTEXT.md` Unlockable deny | file-tool hits stay pinned |
| F-claude | Bash matcher only; Read is foreign allow | landed | `ClaudeSettingsMerge.matcher = "Bash"`; fixture `allow-non-shell-edit.json`; AC-004 | W1 |
| F-cursor | `beforeShellExecution` only; preToolUse Read is foreign | landed | `CursorHooksMerge.swift`; `CursorHostCodec.swift` | W1 |
| F-grok | Template `matcher: Bash`; codec shell-tool set only | landed | `Sources/RVHooks/Resources/hosts/rv.json.tmpl`; `GrokHostCodec.swift`; fixture `allow-non-shell-read.json` | W1 |
| F-hook-req | `HookRequest` is shell-only | landed | `Sources/RVHooks/HostCodec.swift` | W1 adds optional file payload |
| F-ir | `ProposedAction.shell`; fs reserved unused | landed | `docs/architecture/02.md` | do **not** add `.file` / `.mcp` |
| F-policy | `.rv/policy.toml` typed rules, restrict-only | partial | `docs/architecture/english-compile.md`; `PolicyDocument` is rules-only | W2 adds safety + allow_paths |
| F-install | `install.sh` → binaries → `exec rv setup` | landed | `install.sh`; README | file-tool matchers must ride along; no second command |
| F-history | `RVHistory` stub; history off | landed | `Sources/RVHistory/RVHistory.swift` | W2 fills **denial ledger only** |
| F-ask | Host Ask Pi/OpenCode/Claude | deferred | `docs/architecture/02.md` § Order 6 | not this program |
| F-mcp | CL-later-mcp | deferred | STATUS | own program |
| F-pi-oc-hermes | In-process / plugin hosts still shell-only | deferred | MODULES RVHooks | W3 program |
| F-codex | Bash matcher; `write_stdin` host gap | deferred | `CodexHooksMerge.swift` | own program |

---

## 2. Locked design decisions

| Decision | Choice | Rationale | Units affected |
|----------|--------|-----------|----------------|
| What file tools | **Read, Edit, Write** and host aliases only (`read_file`, `write_file`, `edit_file`). Not Grep, Glob, search, MCP, `apply_patch` | Tight secret gate, not a file firewall | all W1 |
| How a file tool is decided | **Catalog match on the extracted path.** Same `SecretPathCatalog`. No fake `cat <path>`. Packs never see file tools | Keeps evaluate() shell-shaped; reuses OPE-160 matcher | w1-file, w1-eval |
| IR | **Do not** add `ProposedAction.file` | 02.md queue owns IR; this program must not block on OPE-156 | all |
| Unlock | Catalog hits stay **pinned**. No Ask. No allow-once spend | Already unlockable-deny law | w1-eval |
| Claude wire | Keep Bash entry. **Add** PreToolUse entries matcher `Read`, `Edit`, `Write`. Same wrapper. Do **not** omit matcher (MCP stays off the hook) | Hook must see file tools; MCP stays CL-later-mcp | w1-claude |
| Cursor wire | Keep `beforeShellExecution` + `failClosed`. **Add** `preToolUse` rv entry, `failClosed: true`, no matcher; codec evaluates only Read/Edit/Write, other tools foreign allow | Official shell honor path stays; file tools get a second official event | w1-cursor |
| Grok wire | **Omit `matcher`** on `~/.grok/hooks/rv.json`. Codec: shell tools as today **or** file aliases. Everything else foreign allow | Grok Bash matcher is the leak. Host is fail-open if the hook emits nothing — residual | w1-grok |
| Path fields | First non-empty of `file_path`, `path`, `target_file`, `target` | Hosts disagree; one extractor | w1-file, codecs |
| Missing / empty path | **Deny** (malformed), same voice as missing shell command on that host | Fail-closed on the file door | w1-eval, codecs |
| Host auth rows | Add catalog rules: Claude `~/.claude/.credentials.json`; Cursor `~/.cursor/auth.json` + `~/.config/cursor/auth.json`; Codex `~/.codex/auth.json`; Hermes `~/.hermes` auth if present; OpenClaw credentials under `~/.openclaw` | User asked for the agent’s own auth files | w1-file |
| Install | **No new command.** `curl \| sh` → `rv setup` writes the new matchers. Doctor says file-tool wired | “One command, then it’s on” | w1-setup |
| Safety knob | `normal` (default) and `strict` only | People must not learn pack IDs to change posture | W2 |
| Normal | File-tool catalog deny + today’s shell evaluate | Current product plus the new door | w2-safety |
| Strict | Normal **plus** shell metadata discovery of catalog paths (`ls` / `test` / `stat` / `find` whose operands match the catalog). Does **not** change Grok fail-open | Matches “stricter” without unparseable-shell rewrite | w2-strict |
| Turn a path off | `secret.allow_paths` literal file or directory in machine config and/or `.rv/policy.toml`. **Host-auth catalog rows are never exempted** | Simple off switch; cannot allow `~/.claude/.credentials.json` | w2-allow |
| Merge | invariants ⊳ machine ⊳ repo, **restrict-only**. Repo may raise `normal` → `strict`. Repo cannot lower machine `strict`. Repo cannot disable the catalog | Same overlay law as typed rules | W2 |
| Share | `.rv/policy.toml` keys `safety.level` and `secret.allow_paths` | Already the shareable file | w2-allow, w2-cli |
| Block list | **Denial-only ledger**, default **on**. Not allow history. Not `os_log` command text | History-off stays true for allows; denials are the operable surface | W2 |
| Ledger fields | timestamp, host, tool (`Read` / `Bash` / …), `rule_id`, category, path with `$HOME` → `~`. No raw secret values | Enough to answer “what just blocked” | w2-blocks |
| Ledger off | `blocks.enabled: false` in `~/.config/rv/config.json` | Explicit, not silent | w2-blocks |
| Retention | 200 rows or 7 days, whichever first; drop oldest | Bounded disk | w2-blocks |
| CLI | `rv safety` (show/set), `rv blocks` | No GUI this program | w2-cli, w2-blocks-cli |
| Other hosts | Pi / OpenCode / Hermes / Codex / OpenClaw file tools are **W3**, not this program | User named Claude, Cursor, Grok | deferred |
| New SPM module | **no** | Hexagon stays | all |

Unresolved forks: **none**.

---

## 3. Global reject list

- `RV_BYPASS` or any hook-honored skip-evaluate env
- Allow because XPC missed
- Fake `cat <path>` / pack evaluate on file tools
- `ProposedAction.file` or `.mcp`
- Grep / Glob / MCP / `apply_patch` matchers
- Official Claude `permissionDecision: "ask"`
- Allow-once spend on catalog / host-auth hits
- `secret.allow_paths` exempting host-auth rows
- Default-on allow history or command text in `os_log`
- Live-HOME tests
- Foreign hook overwrite; `*.bak` of Claude `settings.json`
- GUI, Homebrew, Linux/Windows claim
- Host Ask / OPE-156 / live Auto-review from this name
- Competitor product names in tree files (existing PLAN parity mention stays)

---

## 4. Program e2e oracle pack

| # | Command | Expect | Notes |
|---|---------|--------|-------|
| 1 | `printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/tmp/rv-oracle/.env"}}' \| rv hook --host claude` | exit 0; stdout `permissionDecision` deny; reason names `core.secrets` | temp HOME / no live HOME |
| 2 | `printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/tmp/rv-oracle/src/main.swift"}}' \| rv hook --host claude` | empty stdout, exit 0 | ordinary file |
| 3 | `printf '%s' '{"hook_event_name":"preToolUse","tool_name":"Read","tool_input":{"path":"/tmp/rv-oracle/.ssh/id_ed25519"}}' \| rv hook --host cursor` | `permission: deny`, exit 0 | Cursor file door |
| 4 | `printf '%s' '{"hookEventName":"pre_tool_use","toolName":"read_file","toolInput":{"path":"/tmp/rv-oracle/.aws/credentials"}}' \| rv hook --host grok` | deny JSON, exit 0 | Grok file door |
| 5 | `printf '%s' '{"hookEventName":"pre_tool_use","toolName":"run_terminal_command","toolInput":{"command":"git reset --hard"}}' \| rv hook --host grok` | still deny `core.git:reset-hard` | shell must not regress |
| 6 | `RV_HOME=/tmp/rv-oracle-home rv setup` (fixture hosts pre-created) | Claude settings have Read/Edit/Write matchers; Cursor has `preToolUse`; Grok `rv.json` has no `matcher` | doctor: file-tool wired |
| 7 | `rv safety` | prints `normal` on a fresh home | |
| 8 | `rv safety strict && rv test 'test -f ~/.ssh/id_rsa'` | deny under strict; allow under normal | shell metadata |
| 9 | `rv blocks` after oracle 1 | one redacted row, `rule_id` present, path uses `~` if home-shaped | |
| 10 | `tools/gate.sh RVDomainTests && tools/gate.sh RVEngineTests && tools/gate.sh RVHooksTests && tools/gate.sh RVCLITests && tools/gate.sh RVHistoryTests && tools/gate.sh RVPolicyTests` | all green | warm `.build` |

---

## 5. Ownership matrix (program)

| Path / glob | Exclusive unit id | Wave |
|-------------|-------------------|------|
| `AGENTS.md`, `CONTEXT.md`, `docs/factory/PLAN.md`, `docs/factory/STATUS.md`, `docs/architecture/MODULES.md` | w1-law-core | W1 |
| `docs/factory/references/host-contracts-v1.md`, `docs/factory/specs/claude-host.md`, `docs/factory/specs/phase-1d-hosts.md` | w1-law-hosts | W1 |
| `Sources/RVDomain/FileToolAction.swift` (new), `Sources/RVDomain/SecretPathCatalog.swift` | w1-file | W1 |
| `Sources/RVEngine/FileToolEvaluate.swift` (new), `Tests/RVEngineTests/FileToolEvaluateTests.swift` (new) | w1-eval | W1 |
| `Sources/RVHooks/HostCodec.swift`, `Sources/RVHooks/HookDispatch.swift` (or current hookWire file), `Sources/RVService/GatedEvaluate.swift` | w1-dispatch | W1 |
| `Sources/RVHooks/ClaudeHostCodec.swift`, `Sources/RVCLI/Setup/ClaudeSettingsMerge.swift`, `Tests/RVHooksTests/Fixtures/claude/*` | w1-claude | W1 |
| `Sources/RVHooks/CursorHostCodec.swift`, `Sources/RVCLI/Setup/CursorHooksMerge.swift`, `Tests/RVHooksTests/Fixtures/cursor/*` | w1-cursor | W1 |
| `Sources/RVHooks/GrokHostCodec.swift`, `Sources/RVHooks/Resources/hosts/rv.json.tmpl`, `Tests/RVHooksTests/Fixtures/grok/*` | w1-grok | W1 |
| `Sources/RVCLI/Doctor/*` (file-tool row only), `Tests/RVCLITests/ClaudeSettingsMergeTests.swift` / `CursorHooksMergeTests.swift` / grok setup tests as needed | w1-setup | W1 |
| `Sources/RVDomain/SafetyLevel.swift` (new), `Sources/RVPolicy/SafetyStore.swift` (new) | w2-safety | W2 |
| `Sources/RVPolicy/SecretAllowPaths.swift` (new), `Sources/RVDomain/PolicyDocument.swift` (additive keys only) | w2-allow | W2 |
| `Sources/RVEngine/SecretPathGuard.swift` (strict metadata only) | w2-strict | W2 |
| `Sources/RVCLI/Commands/SafetyCommand.swift` (new) | w2-cli-safety | W2 |
| `Sources/RVHistory/**` | w2-blocks-store | W2 |
| `Sources/RVCLI/Commands/BlocksCommand.swift` (new) | w2-blocks-cli | W2 |
| `Sources/RVService/GatedEvaluate.swift` (append-deny only; serialize after W1 dispatch) | w2-hook-record | W2 |
| `CONTEXT.md` (vocabulary: block ledger, safety, file tool) | w2-docs | W2 |

---

## 6. Waves

### Wave W1 — Law + file door + Claude / Cursor / Grok

- **Depends on waves:** none
- **mode:** full
- **max_units:** 9
- **max_parallel:** 3
- **agent_budget:** 1024
- **product_oracle_cmds:**
  - oracles 1–6 from §4
- **Wave done when:** named-host file-tool denials work in fixtures + `rv hook`; `git reset --hard` still denies; setup writes the new matchers; gate green on touched modules

#### Unit: w1-law-core

- **Title:** Amend living law for the named file-tool exception
- **Mode:** implement
- **Goal:** Agents stop treating Read/Edit as forbidden-in-v1
- **Acceptance:**
  1. `AGENTS.md` / `PLAN.md` say: shell stays the destructive-command door; **Read/Edit/Write secret-path only** is allowed; Grep/MCP still forbidden
  2. `STATUS.md` moves `CL-later-secrets` to this program (in progress), not “fenced later”
  3. `CONTEXT.md` defines **file tool** and **block ledger** (ledger ships W2; term reserved)
- **Live smoke:** `rg -n "Read / Edit / Write secret-path" AGENTS.md CONTEXT.md docs/factory/PLAN.md` hits all three; `rg -n "No Read/Edit/MCP hooks in v1" AGENTS.md` is empty (`rg … && exit 1` polarity)
- **Depends on:** none
- **Parallel-safe with:** w1-law-hosts, w1-file
- **Code paths (exclusive):** `AGENTS.md`, `CONTEXT.md`, `docs/factory/PLAN.md`, `docs/factory/STATUS.md`, `docs/architecture/MODULES.md`
- **Test paths (exclusive):** none
- **Gates:**
  - `rg -n "Read / Edit / Write secret-path" AGENTS.md`
  - `rg -n "No Read/Edit/MCP hooks in v1" AGENTS.md && exit 1`
- **Reject (local):** rewriting PLAN day-one win; adding competitor names
- **Residuals allowed:** host-contract files wait for w1-law-hosts
- **Fat?:** no
- **Skills to inject:** none (docs)

#### Unit: w1-law-hosts

- **Title:** Flip host-contract fixtures from “Read = allow” to “Read of catalog path = deny”
- **Mode:** implement
- **Goal:** Specs match the codecs W1 will write
- **Acceptance:**
  1. `claude-host.md` AC-004 replaced: Read/Edit/Write of a catalog path denies; ordinary project file allows; MCP still allow
  2. `host-contracts-v1.md` Claude / Grok / Cursor rows name file-tool aliases
  3. `phase-1d-hosts.md` no longer lists Read/Edit/Write as forbidden for those three hosts
- **Live smoke:** `rg -n "AC-004" docs/factory/specs/claude-host.md` shows catalog-path deny, not “empty allow”
- **Depends on:** none
- **Parallel-safe with:** w1-law-core, w1-file
- **Code paths (exclusive):** `docs/factory/references/host-contracts-v1.md`, `docs/factory/specs/claude-host.md`, `docs/factory/specs/phase-1d-hosts.md`
- **Test paths (exclusive):** none
- **Gates:**
  - `rg -n "catalog path" docs/factory/specs/claude-host.md`
  - `rg -n "No Read/Edit/Write/MCP matchers" docs/factory/references/host-contracts-v1.md && exit 1`
- **Reject (local):** authorizing Grep/MCP
- **Residuals allowed:** codec fixtures still old until host units
- **Fat?:** no
- **Skills to inject:** `.grok/skills/swift-hook-xpc`

#### Unit: w1-file

- **Title:** File-tool types + host-auth catalog rows
- **Mode:** implement
- **Goal:** One closed type for a file-tool event; catalog covers host auth files
- **Acceptance:**
  1. `FileToolKind` is `read` / `edit` / `write`; `FileToolAction` has kind + path newtype
  2. `SecretPathCatalog.dayOne` gains host-auth rules for Claude, Cursor, Codex, Hermes, OpenClaw (append-only; existing `rule_id`s unchanged)
  3. `firstMatch` of `~/.claude/.credentials.json` and `~/.cursor/auth.json` hits
- **Live smoke:** `tools/swift-6.3.3 test --filter SecretPathCatalogTests`
- **Depends on:** none
- **Parallel-safe with:** w1-law-core, w1-law-hosts
- **Code paths (exclusive):** `Sources/RVDomain/FileToolAction.swift`, `Sources/RVDomain/SecretPathCatalog.swift`
- **Test paths (exclusive):** `Tests/RVDomainTests/SecretPathCatalogTests.swift`, `Tests/RVDomainTests/FileToolActionTests.swift` (new)
- **Gates:**
  - `tools/gate.sh RVDomainTests`
- **Reject (local):** second scanner; renaming existing catalog patterns
- **Residuals allowed:** no evaluate yet
- **Fat?:** no
- **Skills to inject:** `.grok/skills/swift-hexagonal-spm`

#### Unit: w1-eval

- **Title:** Pure file-tool evaluate (catalog only)
- **Mode:** implement
- **Goal:** Path in → Decision out, no packs
- **Acceptance:**
  1. `evaluateFileTool` denies catalog hits with `core.secrets:<pattern>`; allows non-hits
  2. Empty path denies; does not call pack evaluate
  3. Result is pinned (not unlockable)
- **Composition acceptance:** `rv test` is **not** this door yet; unit tests are the oracle until w1-dispatch
- **Live smoke:** `tools/swift-6.3.3 test --filter FileToolEvaluateTests`
- **Depends on:** w1-file
- **Parallel-safe with:** none
- **Code paths (exclusive):** `Sources/RVEngine/FileToolEvaluate.swift`
- **Test paths (exclusive):** `Tests/RVEngineTests/FileToolEvaluateTests.swift`
- **Gates:**
  - `tools/gate.sh RVEngineTests`
- **Reject (local):** wrapping path as `cat …` into `evaluate`
- **Residuals allowed:** hookWire still shell-only
- **Fat?:** no
- **Skills to inject:** `.grok/skills/swift-evaluate-parity`

#### Unit: w1-dispatch

- **Title:** HookWire branches file vs shell
- **Mode:** implement
- **Goal:** File payload never reaches pack evaluate
- **Acceptance:**
  1. `HookRequest` carries optional `file: FileToolAction?`; when set, dispatch calls `evaluateFileTool`
  2. Existing shell `git reset --hard` fixtures still deny
  3. Empty `file.path` denies without evaluate()
- **Live smoke:** `tools/swift-6.3.3 test --filter HookDispatch` (or the existing hookWire test type this unit extends)
- **Depends on:** w1-eval
- **Parallel-safe with:** none
- **Code paths (exclusive):** `Sources/RVHooks/HostCodec.swift`, hookWire/dispatch file under `Sources/RVHooks/`, `Sources/RVService/GatedEvaluate.swift` (branch only)
- **Test paths (exclusive):** existing dispatch tests the unit extends under `Tests/RVHooksTests/`
- **Gates:**
  - `tools/gate.sh RVHooksTests`
  - `tools/gate.sh RVServiceTests`
- **Reject (local):** changing Claude/Cursor/Grok matchers here
- **Residuals allowed:** codecs still mark Read as foreign
- **Fat?:** no
- **Skills to inject:** `.grok/skills/swift-hook-xpc`

#### Unit: w1-claude

- **Title:** Claude Read/Edit/Write matchers + codec
- **Mode:** implement
- **Goal:** Claude file tools reach the catalog
- **Acceptance:**
  1. Setup writes three extra PreToolUse entries (`Read`, `Edit`, `Write`) plus existing `Bash`
  2. Fixture: Read `.env` → Claude deny envelope; Read `src/main.swift` → empty allow; MCP still allow
  3. `allow-non-shell-edit.json` no longer means “always allow”
- **Live smoke:** oracle §4 row 1 and 2 against the built `rv`
- **Depends on:** w1-dispatch, w1-law-hosts
- **Parallel-safe with:** w1-cursor, w1-grok
- **Code paths (exclusive):** `Sources/RVHooks/ClaudeHostCodec.swift`, `Sources/RVCLI/Setup/ClaudeSettingsMerge.swift`
- **Test paths (exclusive):** `Tests/RVHooksTests/Fixtures/claude/**`, Claude hook tests, `Tests/RVCLITests` Claude merge tests this unit must update
- **Gates:**
  - `tools/gate.sh RVHooksTests`
  - `tools/gate.sh RVCLITests`
- **Reject (local):** omitting matcher; emitting `permissionDecision: ask`
- **Residuals allowed:** doctor copy waits for w1-setup
- **Fat?:** no
- **Skills to inject:** `.grok/skills/swift-hook-xpc`

#### Unit: w1-cursor

- **Title:** Cursor `preToolUse` file door
- **Mode:** implement
- **Goal:** Cursor Read/Edit/Write deny catalog paths
- **Acceptance:**
  1. `CursorHooksMerge` keeps `beforeShellExecution` and adds `preToolUse` with `failClosed: true`
  2. Codec: `preToolUse` + Read/Edit/Write → file payload; `Shell`/`Bash` still shell; other tools foreign
  3. Ordinary project Read allows; `.ssh` Read denies with official `permission: deny`
- **Live smoke:** oracle §4 row 3
- **Depends on:** w1-dispatch
- **Parallel-safe with:** w1-claude, w1-grok
- **Code paths (exclusive):** `Sources/RVHooks/CursorHostCodec.swift`, `Sources/RVCLI/Setup/CursorHooksMerge.swift`
- **Test paths (exclusive):** `Tests/RVHooksTests/Fixtures/cursor/**`, `Tests/RVCLITests/CursorHooksMergeTests.swift`
- **Gates:**
  - `tools/gate.sh RVHooksTests`
  - `tools/gate.sh RVCLITests`
- **Reject (local):** removing `beforeShellExecution`; using Claude permissionDecision
- **Residuals allowed:** doctor copy waits for w1-setup
- **Fat?:** no
- **Skills to inject:** `.grok/skills/swift-hook-xpc`

#### Unit: w1-grok

- **Title:** Grok omits matcher; codec accepts file tools
- **Mode:** implement
- **Goal:** Grok `read_file` of a catalog path denies
- **Acceptance:**
  1. `rv.json.tmpl` has **no** `matcher` key
  2. Codec treats `read_file` / `Read` / `write_file` / `Write` / `Edit` as file tools; shell set unchanged
  3. Fixture `allow-non-shell-read.json` allows `README.md`; new fixture denies `.env`
- **Live smoke:** oracle §4 rows 4–5
- **Depends on:** w1-dispatch
- **Parallel-safe with:** w1-claude, w1-cursor
- **Code paths (exclusive):** `Sources/RVHooks/GrokHostCodec.swift`, `Sources/RVHooks/Resources/hosts/rv.json.tmpl`
- **Test paths (exclusive):** `Tests/RVHooksTests/Fixtures/grok/**`, `Tests/RVHooksTests/GrokHookTests.swift`
- **Gates:**
  - `tools/gate.sh RVHooksTests`
- **Reject (local):** claiming Grok fail-closed when the hook emits nothing
- **Residuals allowed:** Grok host fail-open residual stays documented
- **Fat?:** no
- **Skills to inject:** `.grok/skills/swift-hook-xpc`

#### Unit: w1-setup

- **Title:** Setup/doctor: file tools are on after the same one command
- **Mode:** implement
- **Goal:** Detected Claude/Cursor/Grok come up with file-tool wiring; no extra flag
- **Acceptance:**
  1. `rv setup` in a temp HOME with those host dirs writes the W1 matchers
  2. Doctor reports file-tool wired vs shell-only
  3. `install.sh` still only execs `rv setup` (no new hero command)
- **Live smoke:** oracle §4 row 6
- **Depends on:** w1-claude, w1-cursor, w1-grok
- **Parallel-safe with:** none
- **Code paths (exclusive):** doctor view-model / doctor run files this unit must touch under `Sources/RVCLI/Doctor/` and `Sources/RVPresentation/DoctorViewModel.swift` if a new row is required
- **Test paths (exclusive):** setup/doctor tests this unit extends
- **Gates:**
  - `tools/gate.sh RVCLITests`
- **Reject (local):** second install command; Homebrew
- **Residuals allowed:** `rv safety` / `rv blocks` wait for W2
- **Fat?:** no
- **Skills to inject:** `.grok/skills/swift-hook-xpc`

---

### Wave W2 — Safety knob, shareable allow paths, block ledger

- **Depends on waves:** W1
- **mode:** full
- **max_units:** 8
- **max_parallel:** 3
- **agent_budget:** 1024
- **product_oracle_cmds:**
  - oracles 7–10 from §4
- **Wave done when:** `rv safety` / `rv blocks` work; strict changes metadata discovery; repo cannot lower machine strict; denials appear redacted

#### Unit: w2-safety

- **Title:** `SafetyLevel` normal | strict
- **Mode:** implement
- **Goal:** One closed enum, machine store, restrict-only overlay
- **Acceptance:**
  1. Missing config is `normal`
  2. Machine `strict` cannot be lowered by repo `normal`
  3. Repo may raise `normal` → `strict`
- **Live smoke:** `tools/swift-6.3.3 test --filter SafetyStore`
- **Depends on:** none (W2 start)
- **Parallel-safe with:** w2-blocks-store
- **Code paths (exclusive):** `Sources/RVDomain/SafetyLevel.swift`, `Sources/RVPolicy/SafetyStore.swift`
- **Test paths (exclusive):** `Tests/RVPolicyTests/SafetyStoreTests.swift`
- **Gates:**
  - `tools/gate.sh RVPolicyTests`
- **Reject (local):** third preset; enabling extra packs via this knob
- **Residuals allowed:** CLI not wired
- **Fat?:** no
- **Skills to inject:** `.grok/skills/swift-hexagonal-spm`

#### Unit: w2-allow

- **Title:** `secret.allow_paths` (literal), host-auth never exempt
- **Mode:** implement
- **Goal:** One way to turn a path off without learning rule IDs
- **Acceptance:**
  1. Literal allow path suppresses a non-host-auth catalog hit on the file door
  2. Host-auth rows still deny under an allow_paths that covers them
  3. Keys live in machine config and `.rv/policy.toml`; merge restrict-only
- **Live smoke:** `tools/swift-6.3.3 test --filter SecretAllowPaths`
- **Depends on:** w2-safety
- **Parallel-safe with:** w2-strict
- **Code paths (exclusive):** `Sources/RVPolicy/SecretAllowPaths.swift`, `Sources/RVDomain/PolicyDocument.swift` (additive)
- **Test paths (exclusive):** `Tests/RVPolicyTests/SecretAllowPathsTests.swift`
- **Gates:**
  - `tools/gate.sh RVPolicyTests`
  - `tools/gate.sh RVDomainTests`
- **Reject (local):** glob allow; exempting host-auth
- **Residuals allowed:** CLI `rv safety` may not yet print allow paths
- **Fat?:** no
- **Skills to inject:** `.grok/skills/swift-hexagonal-spm`

#### Unit: w2-strict

- **Title:** Strict metadata discovery on the shell door
- **Mode:** implement
- **Goal:** `test -f ~/.ssh/id_rsa` denies only when strict
- **Acceptance:**
  1. Normal: `test -f` / `ls` / `stat` of a catalog path allow (today’s floor)
  2. Strict: those commands deny `core.secrets:<pattern>`
  3. `git reset --hard` still denies in both levels
- **Live smoke:** oracle §4 row 8
- **Depends on:** w2-safety
- **Parallel-safe with:** w2-allow
- **Code paths (exclusive):** `Sources/RVEngine/SecretPathGuard.swift` (and a small evaluate-site call if required in `Sources/RVEngine/Evaluate.swift`)
- **Test paths (exclusive):** `Tests/RVEngineTests/SecretPathGuardTests.swift` (extend)
- **Gates:**
  - `tools/gate.sh RVEngineTests`
- **Reject (local):** changing default normal behavior for `rm` / git
- **Residuals allowed:** Grok fail-open unchanged
- **Fat?:** no
- **Skills to inject:** `.grok/skills/swift-evaluate-parity`

#### Unit: w2-cli-safety

- **Title:** `rv safety` show / set
- **Mode:** implement
- **Goal:** The knob people actually type
- **Acceptance:**
  1. `rv safety` prints the effective level
  2. `rv safety strict` / `rv safety normal` writes machine config
  3. Help does not mention pack IDs
- **Live smoke:** oracle §4 row 7
- **Depends on:** w2-safety
- **Parallel-safe with:** w2-blocks-cli (after store)
- **Code paths (exclusive):** `Sources/RVCLI/Commands/SafetyCommand.swift`, help catalog entries this command requires
- **Test paths (exclusive):** `Tests/RVCLITests/SafetyCommandTests.swift`
- **Gates:**
  - `tools/gate.sh RVCLITests`
- **Reject (local):** GUI
- **Residuals allowed:** repo-file authoring is still “edit `.rv/policy.toml`”
- **Fat?:** no
- **Skills to inject:** none

#### Unit: w2-blocks-store

- **Title:** Denial-only ledger in RVHistory
- **Mode:** implement
- **Goal:** Persist redacted denials; default on; allows never stored
- **Acceptance:**
  1. `RVHistory` is no longer an empty enum; append/list/prune exist
  2. Allow path does not write
  3. Stored path redacts `$HOME` → `~`; no raw key material
- **Live smoke:** `tools/swift-6.3.3 test --filter DenialLedger`
- **Depends on:** none
- **Parallel-safe with:** w2-safety
- **Code paths (exclusive):** `Sources/RVHistory/**`
- **Test paths (exclusive):** `Tests/RVHistoryTests/**`
- **Gates:**
  - `tools/gate.sh RVHistoryTests`
- **Reject (local):** default-on allow history; command text in `os_log`
- **Residuals allowed:** CLI and hook append wait
- **Fat?:** no
- **Skills to inject:** `.grok/skills/swift-hexagonal-spm`

#### Unit: w2-blocks-cli

- **Title:** `rv blocks`
- **Mode:** implement
- **Goal:** Show what was denied
- **Acceptance:**
  1. `rv blocks` lists newest first
  2. `--json` works
  3. Empty ledger is a quiet empty list, not an error
- **Live smoke:** `rv blocks` on a fresh temp home exits 0
- **Depends on:** w2-blocks-store
- **Parallel-safe with:** w2-cli-safety
- **Code paths (exclusive):** `Sources/RVCLI/Commands/BlocksCommand.swift`
- **Test paths (exclusive):** `Tests/RVCLITests/BlocksCommandTests.swift`
- **Gates:**
  - `tools/gate.sh RVCLITests`
- **Reject (local):** printing full unredacted argv
- **Residuals allowed:** hook not appending yet
- **Fat?:** no
- **Skills to inject:** none

#### Unit: w2-hook-record

- **Title:** Record hook/TTY denials onto the ledger
- **Mode:** implement
- **Goal:** A live deny shows up in `rv blocks`
- **Acceptance:**
  1. File-tool deny and shell deny both append (service + miss path)
  2. `blocks.enabled: false` writes nothing
  3. Hook process still does not call analytics
- **Live smoke:** oracle §4 row 9
- **Depends on:** w2-blocks-store, w1-dispatch (already on tip)
- **Parallel-safe with:** none
- **Code paths (exclusive):** `Sources/RVService/GatedEvaluate.swift` (append only)
- **Test paths (exclusive):** `Tests/RVServiceTests` denial-ledger tests this unit adds
- **Gates:**
  - `tools/gate.sh RVServiceTests`
- **Reject (local):** logging allows; logging to `os_log`
- **Residuals allowed:** Pi/OpenCode file tools still missing (W3)
- **Fat?:** no
- **Skills to inject:** `.grok/skills/swift-hook-xpc`

#### Unit: w2-docs

- **Title:** Vocabulary + doctor copy for safety and blocks
- **Mode:** implement
- **Goal:** CONTEXT / help / doctor tell the truth
- **Acceptance:**
  1. `CONTEXT.md` defines **safety level**, **block ledger**, **file tool**
  2. Doctor mentions safety level and block ledger on/off
  3. No competitor names added
- **Live smoke:** `rg -n "block ledger" CONTEXT.md`
- **Depends on:** w2-cli-safety, w2-blocks-cli, w2-hook-record
- **Parallel-safe with:** none
- **Code paths (exclusive):** `CONTEXT.md` (if w1-law-core already reserved the terms, this unit only fills doctor/help), doctor strings under `Sources/RVPresentation/`
- **Test paths (exclusive):** presentation/doctor tests this unit extends
- **Gates:**
  - `rg -n "block ledger" CONTEXT.md`
  - `tools/gate.sh RVPresentationTests`
- **Reject (local):** claiming Grep coverage
- **Residuals allowed:** W3 hosts
- **Fat?:** no
- **Skills to inject:** none

---

## 7. Integration acceptance (program complete)

- [ ] Claude / Cursor / Grok Read of `.env` / SSH / cloud creds / host auth denies
- [ ] Ordinary project file Read allows
- [ ] Shell `git reset --hard` still denies on those hosts
- [ ] `rv setup` is the only enable step; doctor shows file-tool wired
- [ ] `rv safety` normal|strict; repo cannot lower machine strict
- [ ] `secret.allow_paths` turns off a project path; cannot turn off host auth
- [ ] `rv blocks` shows redacted denials; allows absent; history-of-allows still off
- [ ] Residuals registered: Grok fail-open; no Grep/MCP; Pi/OpenCode/Hermes/Codex/OpenClaw file tools; Codex `write_stdin`

---

## 8. Launch recipes

### Wave W1

```text
workflow name=implementor
agent_budget=1024
args={
  task: "W1 file-tool secrets. Follow /Users/chriskarani/CodingProjects/rv/planning/2026-09-12-file-tool-secrets-implementable-program.md §W1. Honor unit modes. Global reject list §3.",
  plan: "/Users/chriskarani/CodingProjects/rv/planning/2026-09-12-file-tool-secrets/waves/W01-file-tools.md",
  mode: "full",
  max_units: 9,
  max_parallel: 3,
  product_oracle_cmds: [
    "tools/gate.sh RVDomainTests",
    "tools/gate.sh RVEngineTests",
    "tools/gate.sh RVHooksTests"
  ],
  thrash_threshold: 2
}
```

### Wave W2

```text
workflow name=implementor
agent_budget=1024
args={
  task: "W2 safety + block ledger. Follow /Users/chriskarani/CodingProjects/rv/planning/2026-09-12-file-tool-secrets-implementable-program.md §W2. W1 must be merged first.",
  plan: "/Users/chriskarani/CodingProjects/rv/planning/2026-09-12-file-tool-secrets/waves/W02-safety-blocks.md",
  mode: "full",
  max_units: 8,
  max_parallel: 3,
  product_oracle_cmds: [
    "tools/gate.sh RVPolicyTests",
    "tools/gate.sh RVHistoryTests",
    "tools/gate.sh RVCLITests"
  ],
  thrash_threshold: 2
}
```

### Resume / only_units

Re-run a failed host unit with `only_units: ["w1-claude"]` and `resume_run_dir` from the implementor run. Do not start W2 until W1 oracles 1–6 pass.

PlanHarden: implementor runs it inline before units. Host authority `./scripts/plan-harden-gate.sh RUN_DIR --mode full` → `PLAN_READY.md` when that script exists in-tree; otherwise workflow PlanHarden is the gate.

---

## 9. PR / review plan

- Open PR after W1 (`feat/file-tool-secrets`). Adversarial review on hook honor paths.
- W2 can stack on the same branch or a follow-up PR.
- `/multi-agent-pr-review --plan planning/2026-09-12-file-tool-secrets-implementable-program.md --adversarial`
- Plan completeness lane uses the tree-truth ledger in §1
- Skills: `.grok/skills/swift-thermo-nuclear-review`, `.grok/skills/swift-hook-xpc` — do not load `thermo-nuclear-code-quality-review`

---

## 10. Deferred programs (explicit)

| Program | Why deferred | Entry criteria |
|---------|--------------|----------------|
| File tools on Pi / OpenCode / Hermes | User named Claude, Cursor, Grok first | W1 green; in-process path extract |
| Codex / OpenClaw file tools | Codex matcher + `write_stdin` host gap; OpenClaw exec-only | Own host-contract amendment |
| Grep / Glob / search | Not “tight” | After false-positive budget written |
| CL-later-mcp | Separate fence | After file-tool door is boring |
| Host Ask | 02.md § Order 6 | Not this program |
| GUI policy editor | Operable CLI is enough | After `rv safety` / `rv blocks` exist |
| Allow history | Privacy law | Never default-on |

---

## 11. Suggested workflow extensions (optional)

None. Use the existing Swift gate (`tools/gate.sh`), not Zig implementor. If the host runner is `.grok/workflows/english-compile-swift.rhai`-shaped, point it at this plan the same way; do not invent a second evaluate engine.
