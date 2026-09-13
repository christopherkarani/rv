# Program: Guard maturity overlay

**Date:** 2026-09-13  
**Status:** ready_for_implementor  
**Handoff (new session):** paste `planning/2026-09-13-guard-maturity/PROMPT.md`  
**Source plans:** this conversation’s takeaways; `docs/architecture/02.md` § Order; `docs/dev/PARITY.md`; `.grok/skills/swift-evaluate-parity/references/landmines.md`; `planning/2026-09-12-file-tool-secrets-implementable-program.md` (do not reopen)  
**Repo / branch assumptions:** `/Users/chriskarani/CodingProjects/rv` from current tip. Branch `feat/guard-maturity`. Apple Silicon, Swift 6.3.3 via `tools/swift-6.3.3`, warm `.build`.  
**Stop line:** This program writes **law + fixtures + one isolated-HOME oracle** so the existing 0.2 queue (OPE-156 → analyzers → hard policy → Host Ask) cannot “mature” by adding regex. It does **not** implement OPE-156, Host Ask, Auto-review, MCP, a third safety level, Windows, or a second evaluate engine.

---

## For humans

A mature guard is quiet on real agent work and hard on a short never-slip list. Chasing every crafted bypass in `normal` never ships.

Do four things:

1. Write down what must never run, even wrapped.
2. Write down holes we will not chase in `normal`.
3. Treat a blocked safe command as a merge blocker.
4. Prove the hook still denies on a real host, in an isolated HOME.

The engine work for “one parsed command” is already ticketed (OPE-156, then 254–256). This program makes those tickets fail if they ship the naive shape: packs on the raw line, secrets on a different string, semantics on a third.

---

## 0. One-line goal

`normal` stays usable. Never-slip still denies when wrapped. Known holes are named instead of patched forever. A false block of a landmine row cannot merge.

---

## 1. Tree-truth ledger

| ID | Slice / finding | Status | Evidence | Residual if partial |
|----|-----------------|--------|----------|---------------------|
| F-queue | 0.2 execute queue starts at OPE-156 | landed (law) | `docs/architecture/02.md` § Order | this program does not jump the queue |
| F-door | `evaluateWithSemantics` = packs then unwrap → analyze → apply | landed | `Sources/RVEngine/EvaluateWithSemantics.swift` | packs + secrets still see `matchingView`, not a single IR |
| F-unwrap | `bash -c` / `python -c` executing sinks peel; limits deny | landed | `Unwrap.swift`; `GatedEvaluateWrapperSemanticsTests` | ANSI-C `$''`, `$CMD`, mystery python → `unwrapLimited` |
| F-fp-pin | Pin landmines must allow | landed | `landmines.md`; `near-miss.json` | missing wrapper/prose/jq/`2>/dev/null` rows |
| F-python-print | `python -c "print('git reset --hard')"` allows | landed | `pythonPrintReset_isAllowed` | keep; do not scan print guts as shell |
| F-python-exec | `os.system('git reset --hard')` denies | landed | wrapper semantics tests | do not reconstruct a Python interpreter |
| F-safety | `normal` / `strict` only | landed | `SafetyLevel.swift`; file-tool W2 | no `paranoid` |
| F-overlay-degrade | bad `policy.toml` ignored | partial | `SafetyStore.loadDocumentLevel` `catch { nil }` | no oracle that `git status` still allows |
| F-core-missing | missing core packs → indeterminate → hook deny | landed | evaluate-parity skill; `HookMapper` | **keep**; this is not optional-config degrade |
| F-secrets | secrets scan `matchingView` tokens | partial | `SecretPathGuard.swift` | wrapped / print-string FPs and FNs not named as law |
| F-ir | `ProposedAction.shell` empty-effect on codecs | partial | `ProposedAction.swift`; 02.md item 1 | OPE-156, not this program |
| F-e2e | no isolated-HOME host oracle | open | no `tools/host-oracle*` | W3 |
| F-residual-doc | no adjudicated hole registry | open | — | W1 |
| F-never-slip-doc | never-slip is scattered (pin, unlockable deny, tests) | open | `PARITY.md`; `CONTEXT.md` Unlockable deny | W1 |
| F-file-tools | Claude/Cursor/Grok Read/Edit/Write secrets | in progress elsewhere | file-tool-secrets program | do not touch that exclusive set |
| F-ask | Host Ask | deferred | 02.md item 6 | not this program |

---

## 2. Locked design decisions

| Decision | Choice | Rationale | Units affected |
|----------|--------|-----------|----------------|
| Relation to 0.2 | **Overlay.** Next code ticket stays OPE-156. This program does not start IR, Ask, or Auto-review | One execute queue | all |
| One command view | Innermost **executing** command after a **complete** unwrap. Packs, secrets, Git/FS, hard policy all read that. `matchingView` stays the grant key until 158 | Dual scanners disagree; grants must not churn | w1-law, w2-acceptance |
| What “executing” means | Same sink rules as today’s unwrap: `bash -c` / `sh -c` payload, `python -c os.system` / equivalent executing sinks. `echo`, `print`, `git commit -m`, `rg` are data | Already proven; do not invent an AST | w1-never-slip, W2 corpus |
| Safety levels | `normal` (default) and `strict` only. Residual holes may deny in `strict`. Never add `paranoid` | People already have one knob | all |
| False block | A deny of a `near-miss.json` / landmine row is a **merge blocker**. Do not delete the row to go green | Quiet guard, or people uninstall | w1-review, w2-fp |
| Crafted bypass | If it is not on the never-slip list, it is **residual** or `strict` — not a new `normal` regex | Stops parser hill-climb | w1-residual |
| Never-slip (must deny, wrapped or not) | (1) `git reset --hard` and other day-one **critical/high** executing git/fs hits (`rm -rf /`, fork-bomb). (2) `SecretPathCatalog` hits on executing operands. (3) `unwrapLimited` / unparseable executing wrapper. (4) Pinned unlockable denies (`core.secrets`, `builtin.action`, protected-path). Recursion/parse limits → deny, never allow | Product promise | w1-never-slip, w2-ns |
| Residual in `normal` (do not chase) | Encoded / reconstructed secret names; interpreter bodies that are not executing sinks; Grok fail-open when the hook is not invoked; host-specific stdin/write gaps named in STATUS; anything that needs a partial language interpreter | Honest product | w1-residual |
| Broken config | Malformed **optional** overlay (`safety.level`, `secret.allow_paths`, extra `policy.toml` rules) → ignore, keep day-one. Missing **core packs** stays indeterminate → hook deny. Unreadable hook JSON stays deny | Optional overlay must not freeze `git status`. Core missing is “product not installed” | w2-degrade |
| Live proof | Isolated HOME only. No live-HOME. Not a substitute for 02.md Manual on steps 6–9 | AGENTS.md | W3 |
| Corpus vs `evaluateWithSemantics` | Pin `deny.json` / `near-miss.json` stay on **pack `evaluate`** (0.11.0 scoreboard). New wrapper/prose rows that need unwrap live in `Tests/RVEngineTests/` or Service door tests, not by changing the pin scoreboard | Pin must not absorb semantics | w2-fp, w2-ns |
| Foreign names | Do not write other product names into this tree | AGENTS.md | all |
| Platform | macOS 26 Apple Silicon + Linux aarch64/x86_64. No Windows path program | PLAN.md | all |

Unresolved forks: **none**.

---

## 3. Global reject list

- `RV_BYPASS` or any hook-honored skip-evaluate env
- Allow because XPC missed
- Allow because unwrap/parse limited
- Third safety level / `paranoid`
- Starting OPE-156 / Host Ask / Auto-review / `ProposedAction.file` / `.mcp` from this name
- Grep / Glob / MCP / `apply_patch` matchers
- Live-HOME tests; writing the operator’s real host dotfiles
- `swift package clean` / wiping `.build` to prove compile
- Command text in `os_log`
- OS-enforced / Seatbelt claim
- Windows / Intel Mac / macOS 14–15 claim
- Changing pin `Decision` + `rule_id` to make a new row green
- Deleting a landmine / near-miss row to go green
- Copying a foreign parser or residual-risk numbering scheme as a product
- Reopening file-tool-secrets exclusive files (`SafetyStore.swift`, host file-tool codecs, `blocks.jsonl` shape)
- English-compile / companion app / Homebrew

---

## 4. Program e2e oracle pack

| # | Command | Expect | Notes |
|---|---------|--------|-------|
| 1 | `tools/gate.sh --quiet RVEngineTests RVCorpusTests RVServiceTests` | exit 0 | warm `.build` |
| 2 | `{ rg -n 'paranoid' docs/architecture/never-slip.md docs/architecture/residual-risk.md CONTEXT.md docs/architecture/02.md && exit 1; }` | no `paranoid` (third safety level) | foreign product names also forbidden; do not put them in law files |
| 3 | Isolated HOME: `rv test 'git status'` | allow | W3 |
| 4 | Isolated HOME: `rv test 'git reset --hard'` | deny `core.git:reset-hard` | W3 |
| 5 | Isolated HOME: `rv test "bash -c 'git reset --hard'"` | deny, not allow | W3 |
| 6 | Isolated HOME: `rv test "echo 'git reset --hard'"` | allow | W3 |
| 7 | Isolated HOME: `rv test "python -c \"print('git reset --hard')\""` | allow | W3 |
| 8 | Isolated HOME + garbage `.rv/policy.toml` | `rv test 'git status'` still allow | W3 |
| 9 | `rg -n 'Never-slip' docs/architecture/02.md` | hit required | overlay pointer exists |

---

## 5. Ownership matrix (program)

| Path / glob | Exclusive unit id | Wave |
|-------------|-------------------|------|
| `docs/architecture/never-slip.md` | w1-never-slip | W1 |
| `docs/architecture/residual-risk.md` | w1-residual | W1 |
| `docs/architecture/02.md` (one new subsection only) | w1-queue | W1 |
| `docs/factory/STATUS.md` (one overlay row) | w1-queue | W1 |
| `CONTEXT.md` (Never-slip + Residual risk terms) | w1-queue | W1 |
| `.grok/skills/swift-evaluate-parity/SKILL.md` | w1-review | W1 |
| `.grok/skills/swift-evaluate-parity/references/landmines.md` | w1-review | W1 |
| `Tests/RVEngineTests/Fixtures/corpus/near-miss.json` | w2-fp | W2 |
| `Tests/RVEngineTests/Fixtures/corpus/deny.json` | w2-pin-deny | W2 |
| `Tests/RVEngineTests/MaturityCorpusTests.swift` (new) | w2-door | W2 |
| `Tests/RVPolicyTests/OptionalOverlayDegradeTests.swift` (new) | w2-degrade | W2 |
| `tools/host-oracle.sh` | w3-oracle | W3 |
| `planning/2026-09-13-guard-maturity/oracles.md` | w3-honesty | W3 |

W1: `w1-never-slip` ∥ `w1-residual`; then `w1-queue` ∥ `w1-review`. W2: `w2-fp` then `w2-pin-deny`; `w2-door` ∥ `w2-degrade` ∥ `w2-fp`.

---

## 6. Waves

### Wave W1 — Law

- **Depends on waves:** none
- **mode:** standard
- **max_units:** 4
- **max_parallel:** 3
- **agent_budget:** 512
- **product_oracle_cmds:**
  - `rg -n 'Never-slip' docs/architecture/02.md CONTEXT.md`
  - `rg -n 'Residual risk' CONTEXT.md docs/architecture/residual-risk.md`
  - `{ rg -n 'paranoid' docs/architecture/never-slip.md docs/architecture/residual-risk.md CONTEXT.md docs/architecture/02.md && exit 1; }`
- **Wave done when:** both law files exist, 02.md points at them, vocabulary is in `CONTEXT.md`, evaluate-parity skill points at them, no foreign product names

#### Unit: w1-never-slip

- **Title:** Never-slip list as architecture law
- **Mode:** implement
- **Goal:** One page that names what must deny even when wrapped
- **Acceptance:**
  1. `docs/architecture/never-slip.md` exists and lists the four families in §2 of this program (day-one critical/high executing; catalog secrets on executing operands; unwrap-limited; pinned unlockable)
  2. The page states wrappers do not weaken those families, and `unknown` syntax falls back to packs rather than a fake semantic hit
- **Composition acceptance:** N/A (docs)
- **Live smoke:** `test -f docs/architecture/never-slip.md` → exit 0
- **Depends on:** none
- **Parallel-safe with:** w1-residual
- **Code paths (exclusive):** `docs/architecture/never-slip.md`
- **Test paths (exclusive):** none
- **Gates:**
  - `test -f docs/architecture/never-slip.md`
  - `rg -n 'unwrapLimited|core.secrets|reset --hard' docs/architecture/never-slip.md`
  - `{ rg -n 'paranoid' docs/architecture/never-slip.md && exit 1; }`
- **Reject (local):** do not change `evaluate` / packs JSON; do not edit `CONTEXT.md` (w1-queue)
- **Residuals allowed:** residual-risk file is the sibling unit
- **Fat?:** no
- **Skills to inject:** none (docs)

#### Unit: w1-residual

- **Title:** Residual-risk registry
- **Mode:** implement
- **Goal:** Named holes in `normal` we will not chase
- **Acceptance:**
  1. `docs/architecture/residual-risk.md` lists at least: **RV-RR-01** encoded secret names; **RV-RR-02** pack walk matching print/prose guts while the door allows; Grok fail-open if the hook never runs; host stdin/write gaps already named in STATUS
  2. Each row has: id (`RV-RR-NN`), `normal` outcome, `strict` outcome or `n/a`, why we stop
- **Live smoke:** `test -f docs/architecture/residual-risk.md` → exit 0
- **Depends on:** none
- **Parallel-safe with:** w1-never-slip, w1-review, w1-queue
- **Code paths (exclusive):** `docs/architecture/residual-risk.md`
- **Test paths (exclusive):** none
- **Gates:**
  - `rg -n 'RV-RR-01' docs/architecture/residual-risk.md`
  - `{ rg -n 'paranoid' docs/architecture/residual-risk.md && exit 1; }`
- **Reject (local):** do not put never-slip items here; `$CMD` / unwrap-limited is never-slip, not residual
- **Residuals allowed:** none
- **Fat?:** no
- **Skills to inject:** none

#### Unit: w1-queue

- **Title:** Point 0.2 queue + vocabulary at the overlay
- **Mode:** implement
- **Goal:** Implementors of OPE-156 see this law
- **Acceptance:**
  1. `docs/architecture/02.md` has a **Maturity overlay** subsection (after Strangler, before Types) that says: honor never-slip + residual-risk; false-block of landmines is merge-blocking; one executing view after complete unwrap; this file’s § Order still owns **when**
  2. `STATUS.md` has one board or specs row pointing at this program as overlay (not Next / In progress)
  3. `CONTEXT.md` defines **Never-slip** and **Residual risk**
- **Live smoke:** `rg -n 'Maturity overlay' docs/architecture/02.md` → hit
- **Depends on:** w1-never-slip, w1-residual
- **Parallel-safe with:** w1-review
- **Code paths (exclusive):** `docs/architecture/02.md`, `docs/factory/STATUS.md`, `CONTEXT.md`
- **Test paths (exclusive):** none
- **Gates:**
  - `rg -n 'Maturity overlay' docs/architecture/02.md`
  - `rg -n 'guard-maturity' docs/factory/STATUS.md`
  - `rg -n '^\*\*Never-slip\*\*' CONTEXT.md`
  - `rg -n '^\*\*Residual risk\*\*' CONTEXT.md`
  - `{ rg -n 'paranoid' docs/architecture/02.md CONTEXT.md docs/factory/STATUS.md && exit 1; }`
- **Reject (local):** do not reorder § Order; do not mark OPE-156 done; do not change file-tool-secrets In progress
- **Residuals allowed:** none
- **Fat?:** no
- **Skills to inject:** none

#### Unit: w1-review

- **Title:** False-block is a merge blocker in evaluate review
- **Mode:** implement
- **Goal:** Agents changing evaluate load the overlay
- **Acceptance:**
  1. `.grok/skills/swift-evaluate-parity/SKILL.md` Load-first list includes `docs/architecture/never-slip.md` and `docs/architecture/residual-risk.md`
  2. `references/landmines.md` gains a **Maturity** section that points at the door (`evaluateWithSemantics`) for python-print / `echo` quoted reset, and forbids deleting pin landmines to go green
- **Live smoke:** `rg -n 'never-slip.md' .grok/skills/swift-evaluate-parity/SKILL.md` → hit
- **Depends on:** w1-never-slip, w1-residual
- **Parallel-safe with:** w1-queue
- **Code paths (exclusive):** `.grok/skills/swift-evaluate-parity/SKILL.md`, `.grok/skills/swift-evaluate-parity/references/landmines.md`
- **Test paths (exclusive):** none
- **Gates:**
  - `rg -n 'never-slip.md' .grok/skills/swift-evaluate-parity/SKILL.md`
  - `rg -n 'residual-risk.md' .grok/skills/swift-evaluate-parity/SKILL.md`
  - `rg -n 'git push --force-with-lease' .grok/skills/swift-evaluate-parity/references/landmines.md`
  - `rg -n '## Maturity' .grok/skills/swift-evaluate-parity/references/landmines.md`
- **Reject (local):** do not restyle extracted regex; do not edit corpus JSON in this unit
- **Residuals allowed:** corpus rows are W2
- **Fat?:** no
- **Skills to inject:** `.grok/skills/swift-evaluate-parity/SKILL.md`

### Wave W2 — Fixtures

- **Depends on waves:** W1
- **mode:** standard
- **max_units:** 4
- **max_parallel:** 2
- **agent_budget:** 512
- **product_oracle_cmds:**
  - `tools/gate.sh --quiet RVEngineTests RVCorpusTests RVPolicyTests`
- **Wave done when:** new allow rows cannot be deleted without failing tests; never-slip wrapped door tests deny; garbage policy overlay does not deny `git status`

#### Unit: w2-fp

- **Title:** Near-miss rows for quiet `normal` (pin walk only)
- **Mode:** implement
- **Goal:** Pin `evaluate` allow-rows stay green; do not fight 0.11.0
- **Acceptance:**
  1. Every existing `near-miss.json` id remains, including `near.echo-quoted-reset` and `near.git-commit-force-message`
  2. New pin rows are only commands that pack `evaluate` already allows; new ids use prefix `near.maturity-`
- **Composition acceptance:** N/A
- **Live smoke:** `tools/gate.sh --quiet RVCorpusTests` → exit 0
- **Depends on:** none in W2
- **Parallel-safe with:** w2-door, w2-degrade
- **Code paths (exclusive):** `Tests/RVEngineTests/Fixtures/corpus/near-miss.json`
- **Test paths (exclusive):** same
- **Gates:**
  - `tools/gate.sh --quiet RVCorpusTests`
  - `rg -n 'near.echo-quoted-reset' Tests/RVEngineTests/Fixtures/corpus/near-miss.json`
- **Reject (local):** do not shrink the file; do not change `expected` on existing rows; do not add `python -c "print('git reset --hard')"` here if pack `evaluate` denies it (that is w2-door + RV-RR-02)
- **Residuals allowed:** door-only FPs in w2-door
- **Fat?:** no
- **Skills to inject:** `.grok/skills/swift-evaluate-parity/SKILL.md`

Probe before adding a pin row: run pack `evaluate` (same as `CorpusTests`). If deny, skip the pin row.

#### Unit: w2-pin-deny

- **Title:** Pin deny companions that already match 0.11.0
- **Mode:** implement
- **Goal:** Do not lose true positives while adding maturity allows
- **Acceptance:**
  1. No existing `deny.json` id removed
  2. Add wrapped pin-deny **only** if pack `evaluate` already denies with the same `rule_id` (e.g. `echo hello && git reset --hard` if missing)
- **Live smoke:** `tools/gate.sh --quiet RVCorpusTests`
- **Depends on:** w2-fp
- **Parallel-safe with:** none (same corpus directory; serialize after w2-fp)
- **Code paths (exclusive):** `Tests/RVEngineTests/Fixtures/corpus/deny.json`
- **Test paths (exclusive):** same
- **Gates:** `tools/gate.sh --quiet RVCorpusTests`
- **Reject (local):** no `bash -c` rows in pin corpus (those are door/semantics)
- **Residuals allowed:** none
- **Fat?:** no
- **Skills to inject:** `.grok/skills/swift-evaluate-parity/SKILL.md`

#### Unit: w2-door

- **Title:** Door corpus for never-slip vs quiet
- **Mode:** implement
- **Goal:** `evaluateWithSemantics` keeps today’s wrapper contract and names the dual-view residual
- **Acceptance:**
  1. New `Tests/RVEngineTests/MaturityCorpusTests.swift` table:
     - deny: `git reset --hard`, `bash -c 'git reset --hard'`, `sudo env sh -c 'git reset --hard'`, `python -c "os.system('git reset --hard')"`, `bash -c $CMD` (unwrapLimited), `cat ~/.ssh/id_rsa`
     - allow: `echo 'git reset --hard'`, `python -c "print('git reset --hard')"`, `git push --force-with-lease origin feature`, `git checkout -b topic`
  2. A comment on the python-print row cites `RV-RR-02` if pack `evaluate` would deny the same string
- **Live smoke:** `tools/gate.sh --quiet RVEngineTests` → filter `MaturityCorpus` pass
- **Depends on:** none
- **Parallel-safe with:** w2-fp, w2-degrade
- **Code paths (exclusive):** `Tests/RVEngineTests/MaturityCorpusTests.swift`
- **Test paths (exclusive):** same
- **Gates:**
  - `tools/gate.sh --quiet RVEngineTests`
- **Reject (local):** do not change `Evaluate.swift` / `Unwrap.swift` / `SecretPathGuard.swift` in this unit; if a never-slip row fails, **stop and file it as a bug unit** — do not weaken the row. (No engine fix in W2 unless a never-slip row is red; then a follow-up unit `w2-fix-ns` with exclusive engine path, still no OPE-156.)
- **Residuals allowed:** encoded secret names not in the table
- **Fat?:** no
- **Skills to inject:** `.grok/skills/swift-evaluate-parity/SKILL.md`

#### Unit: w2-degrade

- **Title:** Optional overlay must not freeze ordinary work
- **Mode:** implement
- **Goal:** Garbage `policy.toml` does not deny `git status`
- **Acceptance:**
  1. `Tests/RVPolicyTests/OptionalOverlayDegradeTests.swift`: unreadable / invalid `safety.level` / broken TOML → `SafetyStore.loadEffective` stays `normal` (or machine value), `TypedRuleStore.loadEffective` does not throw into the hook
  2. A Service-level test **or** the same policy test plus `EvaluateSession` with that workspace: `git status` is **allow** (not indeterminate, not deny)
- **Live smoke:** `tools/gate.sh --quiet RVPolicyTests RVServiceTests` (only if a Service test is added; else Policy only)
- **Depends on:** none
- **Parallel-safe with:** w2-door, w2-fp
- **Code paths (exclusive):** `Tests/RVPolicyTests/OptionalOverlayDegradeTests.swift`; if a hook-door test is required, `Tests/RVServiceTests/OptionalOverlayDegradeTests.swift` only
- **Test paths (exclusive):** those files
- **Gates:** `tools/gate.sh --quiet RVPolicyTests`
- **Reject (local):** do not map missing core packs to allow; do not change `HookMapper` indeterminate → allow
- **Residuals allowed:** doctor copy for broken overlay (W3)
- **Fat?:** no
- **Skills to inject:** `.grok/skills/swift-hexagonal-spm/SKILL.md`

### Wave W3 — Isolated host oracle

- **Depends on waves:** W1, W2
- **mode:** standard
- **max_units:** 2
- **max_parallel:** 1
- **agent_budget:** 512
- **product_oracle_cmds:** see program e2e oracles 3–8
- **Wave done when:** `tools/host-oracle.sh` passes on Darwin with isolated HOME; docs say this is not 02.md Manual for Ask

#### Unit: w3-oracle

- **Title:** Isolated HOME `rv test` oracle
- **Mode:** implement
- **Goal:** One script an implementor runs without touching live host dotfiles
- **Acceptance:**
  1. `tools/host-oracle.sh` creates a temp HOME, `PATH` includes the built `rv`, runs oracles 3–8 from §4
  2. Does not write `~/.claude`, `~/.pi`, `~/.grok`, or any real host path
- **Live smoke:** `tools/host-oracle.sh` → exit 0
- **Depends on:** none in W3
- **Parallel-safe with:** none
- **Code paths (exclusive):** `tools/host-oracle.sh`
- **Test paths (exclusive):** none
- **Gates:**
  - `tools/host-oracle.sh`
  - `{ rg -n 'HOME=/' tools/host-oracle.sh | rg -n 'HOME=\\$HOME' && exit 1; }` — script must set `HOME` to a temp dir
  - `rg -n 'TMPDIR\|mktemp' tools/host-oracle.sh`
- **Reject (local):** no `rv setup` against the operator’s HOME; no network
- **Residuals allowed:** does not spawn Pi/Claude; 02.md step 6 Manual remains later
- **Fat?:** no
- **Skills to inject:** none

#### Unit: w3-honesty

- **Title:** Doctor / docs honesty for residual + overlay
- **Mode:** implement
- **Goal:** Operator can find the two lists
- **Acceptance:**
  1. `planning/2026-09-13-guard-maturity/oracles.md` records the W3 transcript shape (command → expect)
  2. `docs/architecture/residual-risk.md` links to `rv safety` / `rv test` as the operator surface (no new CLI)
- **Live smoke:** `test -f planning/2026-09-13-guard-maturity/oracles.md`
- **Depends on:** w3-oracle
- **Parallel-safe with:** none
- **Code paths (exclusive):** `planning/2026-09-13-guard-maturity/oracles.md`, `docs/architecture/residual-risk.md` (one “Operator” paragraph)
- **Test paths (exclusive):** none
- **Gates:** `rg -n 'rv test' docs/architecture/residual-risk.md`
- **Reject (local):** no doctor rewrite of file-tool wiring; no `rv-cli` as a product
- **Residuals allowed:** none
- **Fat?:** no
- **Skills to inject:** none

---

## 7. Integration acceptance (program complete)

- [ ] Never-slip page + residual-risk page exist; 02.md Maturity overlay points at both
- [ ] `CONTEXT.md` terms exist; evaluate-parity skill loads both files
- [ ] Landmine rows still allow; python-print stays allow **on the door**
- [ ] Wrapped `git reset --hard` still denies on the door
- [ ] Garbage optional overlay does not deny `git status`
- [ ] Isolated HOME oracle green
- [ ] File-tool-secrets exclusive files untouched
- [ ] OPE-156 still the next **code** ticket in 02.md § Order
- [ ] Residuals registered (`RV-RR-*`) and operator-visible

---

## 8. Launch recipes

### Wave W1

```text
workflow name=implementor
agent_budget=512
args={
  task: "Guard maturity W1 law — planning/2026-09-13-guard-maturity-implementable-program.md §W1",
  plan: "/Users/chriskarani/CodingProjects/rv/planning/2026-09-13-guard-maturity-implementable-program.md",
  mode: "standard",
  max_units: 4,
  max_parallel: 3,
  only_units: ["w1-never-slip", "w1-residual", "w1-queue", "w1-review"],
  thrash_threshold: 2
}
```

PlanHarden: `workflow name=implementor` runs it inline. Host authority: `./scripts/plan-harden-gate.sh` if present; else human read of §2 forks (none open).

### Wave W2

```text
workflow name=implementor
agent_budget=512
args={
  task: "Guard maturity W2 fixtures",
  plan: "/Users/chriskarani/CodingProjects/rv/planning/2026-09-13-guard-maturity-implementable-program.md",
  mode: "standard",
  max_units: 4,
  max_parallel: 2,
  only_units: ["w2-fp", "w2-pin-deny", "w2-door", "w2-degrade"]
}
```

### Wave W3

```text
workflow name=implementor
agent_budget=512
args={
  task: "Guard maturity W3 isolated oracle",
  plan: "/Users/chriskarani/CodingProjects/rv/planning/2026-09-13-guard-maturity-implementable-program.md",
  mode: "standard",
  max_units: 2,
  max_parallel: 1,
  only_units: ["w3-oracle", "w3-honesty"],
  product_oracle_cmds: ["tools/host-oracle.sh"]
}
```

Do not use Zig implementor. Runner is a Swift gate (`tools/gate.sh`) plus the shell oracle. `agent_budget` 512 is enough: W1 is docs; W2 is tests; W3 is one script.

---

## 9. What OPE-156 / 254–256 must not break

Copy into the Maturity overlay (w1-queue). Implementors of those tickets treat these as extra Manual:

1. Complete unwrap: Git, filesystem, secrets, and hard policy see the **same** innermost executing command.
2. `matchingView` remains the outer normalized grant key until 158.
3. `python -c "print('git reset --hard')"` stays **allow** on the door.
4. `bash -c 'git reset --hard'` still denies.
5. Unknown syntax → `.unknown` → packs; never a fake Git/FS hit.
6. A new `normal` regex that denies a landmine / `near-miss` row is a failed ticket, not a win.
7. A crafted bypass that is not never-slip is a new `RV-RR-*` row or a `strict` deny — not a `normal` walker rewrite.

---

## 10. Suggested follow-ups (not this program)

- OPE-156 IR through every HostCodec (02.md item 1)
- 254–256 analyzers + 259 fixtures (item 2) — consume `MaturityCorpusTests`
- File-tool-secrets remaining hosts (their W3)
- Host Ask Manual on real Pi / OpenCode / Claude / Hermes (02.md item 6)
