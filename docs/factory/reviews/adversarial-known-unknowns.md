# Adversarial review — known unknowns

Read: `docs/factory/PLAN.md` (wins), `HANDOFF.md`, `references/dcg-0.11.0-notes.md`, `references/host-contracts-v1.md`, and every file under `docs/factory/specs/` including `phase-1d-hosts.md` and `phase-2-packs.md`. Implementer prompts under `docs/factory/prompts/` were used only as evidence of what a T0/T1 agent will actually be told. No product code. No ryk edits.

Checked against DCG **0.11.0** (`src/packs/mod.rs`, `src/packs/core/git.rs`, pinned `SKILL.md`) where a spec treats an upstream fact as settled.

## Verdict (Fix required)

Do not kick off T0. PLAN, the notes, T1, T1’s implement prompt, host-contracts, and the host/allow/service specs already encode **opposite products** for Decision, stash-drop, miss policy, PackID, allow-once IPC, and who installs `rvd`. Two faithful implementers can ship different day-one behavior without violating “PLAN wins,” because PLAN is silent or double-voiced on each of those. Lock the paste blocks in **Recommended locks** into PLAN (and the named spec) before Go Ready.

## Unknowns that must be locked before T0 (block kickoff)

These are product-law forks. T0 copies the style contract and the PARITY scoreboard verbatim and then forbids editing PLAN. Starting T0 freezes the wrong sentence.

### K0. Decision shape — “closed enum” vs `deny(Deny)` vs flat `String`

PLAN’s style contract says only “Closed `Decision` enum. No boolean `isDenied`.” It does **not** define cases or payloads. T1 (`phase-1-engine.md`) ships a flat `String` enum: `allow` / `deny` / `indeterminate`, with the deny payload on `EvaluationResult.matched`. The T1 implement prompt (`docs/factory/prompts/T1.md`) orders the opposite: “a deny always carries ruleID + reason (**PLAN’s associated-value shape**).” T2 robot JSON and T3 `rv.ipc.v1` already assume a string discriminator (`"decision":"deny"`).

Two T1 agents: one ships `enum Decision { case deny(Deny) }` (illegal states unrepresentable; not `String`; breaks T3 “encode as in T1” and medium-allow-with-match); one ships T1’s flat enum (deny-without-`matched` is representable). T0 will copy the vague PLAN bullet into `AGENTS.md` and cannot fix it later.

### K1. “Same decision as DCG” — SKILL.md block vs engine warn vs notes deny

PLAN’s v1 scoreboard: “same decision + `rule_id` as DCG on the **SKILL.md table** and the **core-pack corpus**.” Those two sources disagree at the pin.

- Pinned `SKILL.md` “What It Blocks” lists `git stash drop`. Its pipeline diagram is match-destructive → deny. No severity.
- DCG 0.11.0 `Severity::Medium.default_mode()` is `Warn`, and `Warn.blocks() == false`. `stash-drop` is the documented medium pattern (`git.rs`, `mod.rs` `medium_patterns`). Engine decision is **not a block**.
- `dcg-0.11.0-notes.md`: “DCG Medium severity (`stash-drop`) is still a **deny** in rv (no warn wire).”
- T1 + T1 prompt: medium/low → **allow + `matched`**. Quarantine `skill.stale.stash-drop-block`. Acceptance requires allow.

“No warn-as-permit wire” is used to mean both “therefore deny” (notes) and “therefore allow” (T1). T0’s `PARITY.md` is required to repeat PLAN’s scoreboard sentence. Until PLAN says which source wins, T1’s corpus and PLAN’s scoreboard are different products.

### K2. Miss policy — XPC / missing `rv` / indeterminate

PLAN forbids only: “Allowing because `rvd` is down.” Three miss classes are treated as settled and are not the same.

| Miss | PLAN / T3 | T1 | host-contracts | T4 / T5 / T8 |
|---|---|---|---|---|
| `rvd` down or skew | in-process evaluate; never allow *because* XPC missed | n/a | same | same |
| `rv` binary missing / adapter spawn fail | silent | silent | **Pi: block** with a short reason. “Do not copy DCG fail-open-on-error for Pi.” | **allow** (catch and return nothing). T5 open Q7 calls fail-closed “a product change.” |
| `Decision.indeterminate` (oversize 65_536 or budget) | T1: “**never** treated as allow by later hook/XPC tickets” | T4.3: Allow row **includes indeterminate** → empty stdout, exit 0. T8: “allow (or T1 indeterminate-as-allow)” |

Grok’s host is fail-open on crash/timeout. Pi’s host is fail-safe on `tool_call` errors (uncaught throw **blocks**). The adapter `catch` is the whole product. Two T5 agents: one follows host-contracts (missing `rv` wedges or blocks bash); one follows T5 (missing `rv` is a silent allow-all). Two T4 agents: one fail-closes oversize commands; one lets a 64KiB+ line through.

### K3. “XPC is in v1” with no installer

PLAN: `rvd` is an on-demand LaunchAgent. T3 ships a plist **template** and `rv service status`, not `rv service install`. T3 says T6 copies the plist into `~/Library/LaunchAgents/`. T6 path table has no LaunchAgent path. T6 setup: “Does not touch launchd unless T3 already shipped a `rv service install` and T6’s merge plan says to call it.” That command does not exist in any spec.

Two v1s: in-process-only hooks (XPC never loads), or setup that writes a LaunchAgent. Day-one copy says “XPC-backed hook.” Kickoff without an owner is a hollow PLAN sentence.

## Unknowns that must be locked before T1

T1 owns Domain types, PackID validation, ICU load rules, and the corpus. After T1, T2∥T3 and T8∥T9 fork from that SHA.

### K4. PackID regex vs `strict_git` / `package_managers`

T1: `PackID` must match `^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$` (dot required). T9 frozen catalog includes undotted IDs `strict_git` and `package_managers` (also category IDs). DCG `PackId` is a plain `String`. If T1 ships the regex as a newtype invariant, T9 cannot load 2 of 99 packs without a Domain break. `careful_company_running_windows` is a preset/category, not a PackID — `expand()` must accept strings that are not PackIDs.

### K5. ICU vs fancy-regex, and compile-fail vs quarantine

T1: ICU / `NSRegularExpression` only; no second regex SPM. DCG 0.11.0 patterns are fancy-regex with POSIX classes and lookaheads (`(?=…)`, `(?!…)`, `(?![-a-z])` on `push-force-long`, `(?!)` on semantic rules). Those constructs are ICU-legal; SKILL.md’s “destructive → deny” story assumes they fire. T1 also says (a) a pattern that fails to compile is a **load error for that JSON file** (silent skip would miss `reset-hard`) and (b) ICU-incompatible patterns are **quarantined by name**, pack still loads. Those cannot both be true. If `branch-force-delete`’s dense POSIX/optional `--delete` regex fails ICU, implementer A refuses to load `core.git` (day-one win dead); implementer B quarantines that one rule and still denies `reset-hard`.

T9 repeats “dialect stays fancy-regex” and “quarantine catalog ICU misses.” T1 must define the load rule before the newtype and the two JSON files exist.

### K6. `EvaluationResult` must be Codable for T3

T1 allows `matchedSafe: (PackID, String)?`. Swift tuples are not `Codable`. T3 maps IPC 1:1 onto T1 types. T1 must ship a named `SafeMatch` (T1 already permits this as optional). Do not leave it as implementer taste.

### K7. T8 after T1 vs T8 needs T2’s CLI

PLAN: after T1, **T8∥T9**. T8 spec: ArgumentParser `@main` `rv` is T2; “Do not add an ArgumentParser package dependency — that is T2’s merge.” T8 CLI without T2 cannot compile. Two T8 agents: one adds ArgumentParser (violates T8, follows PLAN “start after T1”); one ships Policy-only and waits (follows T8). PLAN’s parallel table does not say this.

T0 forbids executables and SPM deps. T2 says “`Package.swift` module graph unchanged” and never lists `main.swift` or an executable product, but acceptance is `rv test …`. T3 must add executable `rvd` (T0 said so) even though T0’s graph has **no** `rvd` target and T3’s Depends-on table pretends T0 already declared one. T2 never pins ArgumentParser (T0 open question: “T2 pins it”). Apple’s current getting-started pin is `from: "1.7.0"`. Three tickets will guess three graphs the day T1 goes green.

### K8. `allowOnce.consume` — code vs grant

T3: `AllowOnceConsumeParams { code: String }` — spend a minted code. T8: consume is `{ command, cwd }` against a **grant**; spending the code is **redeem**, TTY-only. T8 still says “this is IPC `allowOnce.consume`.” T3 and T8 each tell the other to follow the other spec. T3 starts the moment T1 is green. If T3 ships `consume(code)`, T8’s hook path cannot honor a grant over `rv.ipc.v1` without a breaking change.

### K9. `rule_id` spelling (three forms before T2)

T1 canonical `RuleID.rawValue` is `core.git:reset-hard`. T2 pretty / `hostDenyText` snapshots use `core.git/reset-hard`. T2 robot JSON uses `"pack_id":"core.git","rule_id":"reset-hard"` (pattern only). T8 allowlist stores colon and accepts slash. T1d open Q9 notices slash vs colon and does not pick a robot form. T1 should define canonical + display so T2 does not invent a third.

### K10. Pack JSON key for the deny sentence

T1 destructive field is `description` (DCG `reason`). T9 example uses `reason` plus optional `description` on the pack. T9 says “follow T1 if landed.” T1 is the schema owner — lock the key name in T1 so T9 cannot fork a second document.

## Unknowns that can wait until the owning ticket

Still real. Do not block T0/T1 if the PLAN locks above land. Do not leave them for the implementer to taste.

### T2 — medium pretty, ArgumentParser add, `hostDenyText` code

- T1 left open whether `rv test` pretty-warns a medium match. T2 pretty allow is exactly `allow`. Lock: silent allow; `rv explain` may show the match; hooks stay empty.
- T2 must be **allowed** to add the ArgumentParser package, executable product `rv`, and `Sources/RVCLI/main.swift`. Today’s “graph unchanged” + missing `main.swift` in the file list will produce a library-only T2 that cannot run `rv test`.
- Pin (T2 owns the edit): `.package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.7.0")`. One pin. T3/T8/T9 do not add a second.

### T2 / T8 / host-contracts — allow-once code in deny text

PLAN unlock text is `rv allow-once <code>`. host-contracts: put `<code>` in `hostDenyText` “only if a code exists.” T2/T8: **never** put a redeemable code on host deny text, pretty, or hook JSON. At hook-deny time a code does not exist unless the human pre-minted. Two T8 agents: one starts printing codes on the hook (host-contracts + PLAN `<code>`); one leaves “or rv allow-once” (T2) and the operator does not know `rv allow-once mint -- <command>` exists. Lock at T2 (copy) and T8 (no code on the wire). Strike the host-contracts “if a code exists” clause.

### T3 — executable `rvd` when T0 forbade executables

Settled if both specs are read: T0 forbids executables **in T0**; “T3 adds executable `rvd`.” T3 may add `.executable(name: "rvd", targets: ["rvd"])` and `Sources/rvd`. T3 must not import ArgumentParser. Fix T3’s Depends-on sentence that claims T0 already declared an `rvd` target — it did not. Not a product fork if T3 follows this; it is a fork if T3 over-reads T0 and ships `rvd` as a library.

### T4 — Grok exit 0+JSON vs exit 2

T4.3 already locks deny = JSON `decision=deny` + **exit 0**. host-contracts: preferred 0+JSON; exit 2 also honored; other exits fail-open. Pinned DCG `SKILL.md` exit table is **2 = blocked**. An implementer who copies SKILL.md or DCG’s binary will emit 2. T4 open Q4 says do not switch speculatively. Residual: keep the lock in the T4 prompt in one sentence so SKILL.md does not win.

T4 must also stop listing `indeterminate` in the Allow row once K2 is locked.

### T5 — OpenCode `command.execute.before`

host-contracts: also hook `command.execute.before` “if the same shell payload exists.” T5: `tool.execute.before` only; do not invent a `shell` alias. Leave T5 as tool-only until a captured envelope exists (T5 open Q5). Do not let host-contracts widen the matcher.

### T6 — hostless vs occupied, and what “occupied single slot” means

PLAN: “Occupied **single slot** → skip + one line.” “Hostless install: success.” That “single slot” language is Claude `settings.json` residue. v1 hosts are multi-file. T6 already defines the exclusive slot as the **owned filename**:

| Host | Detect | Owned slot | Occupied means | Foreign beside us |
|---|---|---|---|---|
| Grok | `$HOME/.grok/` dir or `grok` on `PATH` | `$HOME/.grok/hooks/rv.json` | that file exists and is not the current rv template (except a moved `rv` path, which we rewrite) | `dcg.json` / other `*.json` is **not** occupied; write `rv.json`; first deny wins |
| Pi | `$HOME/.pi/` dir or `pi` on `PATH` | `$HOME/.pi/agent/extensions/rv-guard.ts` | that file exists and is not our template | other `*.ts` untouched |
| OpenCode | `$HOME/.config/opencode/` dir or `opencode` on `PATH` | `$HOME/.config/opencode/plugins/rv-guard.js` | that file exists and is not our template | other plugins untouched |

Hostless = **no host detected** (none of the detect rows). Occupied = host detected, owned name present, not ours. Detected + no owned file = wire (or doctor `absent-file`). Do not treat “Grok already has any hook” as occupied. Do not treat all-hosts-occupied as hostless (different one-liner). Paste T6’s table into PLAN so “single slot” cannot be re-read as “any hook present.”

T6 still needs: LaunchAgent install (K3), `install.sh` artifact URL/checksum (open Q1; `RV_INSTALL_BIN` for L4 is enough to start), and whether setup may print more than one line (occupied + restart + hostless are three different lines).

### T8 — config root `$HOME` vs `XDG_CONFIG_HOME`

PLAN/T6: `$HOME/.config/rv/`, honor process `HOME` only (never `NSHomeDirectory()`). T8: `$XDG_CONFIG_HOME/rv` if set, else `~/.config/rv`. On a machine with `XDG_CONFIG_HOME` set, T6 uninstall and T8 stores split. Lock: production config dir is `$HOME/.config/rv` unless `XDG_CONFIG_HOME` is set **and** T6/T7/T8 all honor it. Prefer PLAN: `$HOME/.config/rv` only, tests inject `HOME`.

## Cross-spec contradictions (spec A vs spec B vs PLAN)

| Topic | PLAN | Other A | Other B | Who wins today if you are literal |
|---|---|---|---|---|
| Decision payload | “Closed enum” only | T1 spec: flat `String` | T1 prompt: associated-value `deny(Deny)` | Unresolvable. Prompt claims PLAN has a shape PLAN does not have. |
| stash-drop | Same decision as DCG on SKILL.md **and** corpus | SKILL.md 0.11.0: blocks. Notes: rv **deny** | T1: **allow** + match (DCG `Warn`) | PLAN cites both sources. Notes vs T1 are opposite. |
| `git branch -d` | SKILL.md table | 0.11.0 SKILL.md **and** `git.rs` tests: deny `branch-force-delete` | Older/main SKILL.md FAQ (not the pin) allows `-d` | T1 deny table matches the **pin**. Do not “fix” from main. |
| `$TMPDIR` | (scoreboard = SKILL.md) | SKILL.md 0.11.0: allow | T1 + 0.11.0 corpus: deny `rm-rf-general` | T1 already quarantines. PLAN scoreboard still names SKILL.md. |
| Missing `rv` on Pi | never allow because **XPC** missed | host-contracts: **block** | T5 + T5 Q7: **allow** (DCG recipe) | Spec vs reference. PLAN does not mention the binary. |
| Indeterminate | (T1 is later) | T1: never allow on hooks | T4 Allow row; T8 “indeterminate-as-allow” | T1 vs T4/T8. PLAN silent. |
| Grok deny exit | (host JSON) | T4: exit **0** + JSON | DCG SKILL.md: exit **2**. host-contracts: both | T4 wins if T4 is the ticket. SKILL.md will still be read. |
| allow-once code on deny | `rv allow-once <code>` | host-contracts: print code if it exists | T2/T8: never print a code | PLAN wording vs T2/T8. |
| Occupied slot | “single slot” | host-contracts: skip, no overwrite | T6: owned **filename** only; `dcg.json` beside `rv.json` is fine | T6 is the only precise rule. PLAN language fights it. |
| Hostless | success, one line | T6: same | Occupied-all-hosts still exit 0, **different** line | Compatible if K6 table is PLAN. |
| T8 start | T8∥T9 after T1 | T8 spec: CLI waits for T2; no ArgumentParser add | T2: no pin, no `main.swift`, graph frozen | PLAN schedule vs T8 vs T2. |
| T3 `rvd` product | (module table) | T0: no executables **in T0**; T3 adds `rvd` | T3 Depends-on: “T0 already has `rvd` target” (false) | T0+T3 prose agree. T3 Depends-on is wrong. |
| LaunchAgent | XPC in v1 | T3: T6 copies plist | T6: do not touch launchd unless `rv service install` exists | Nobody installs. |
| `allowOnce.consume` | (T8 later) | T3: `{ code }` | T8: `{ command, cwd }` grant | Circular “follow the other spec.” |
| PackID | (newtype) | T1: dotted regex | T9: `strict_git`, `package_managers` | T1 invariant vs T9 catalog. |
| RuleID display | (identity) | T1: `pack:pattern` | T2 host/pretty: `pack/pattern`; T2 robot: pattern only | Three wires. |
| Config dir | `~/.config/rv/` | T6: `$HOME/.config/rv/` | T8: XDG then `~` | T8 vs PLAN/T6. |
| OpenCode events | shell only | host-contracts: + `command.execute.before` | T5: `tool.execute.before` only | T5 vs reference. |
| Notes rule IDs | use 0.11.0 | T1: “do not use stale names in the notes (`force-push`, `rm-rf`)” | Current notes already use `push-force-long` / `rm-rf-general` | T1 vs notes are out of date with each other, not with DCG. |

## Recommended locks (exact wording to paste into PLAN or the owning spec)

Paste **L0–L3** into PLAN **Decisions (locked)** before T0. Paste the others into the named spec and add a one-line pointer in PLAN.

### L0 — PLAN (Decision)

```
Decision is a closed three-case enum with no associated values and no RawRepresentable
requirement beyond String: allow, deny, indeterminate. Deny payload lives on
EvaluationResult.matched (RuleID + reason + severity), not inside Decision.
Invariant (tested in T1): deny ⇒ matched != nil && matched.severity.blocksByDefault;
medium/low ⇒ decision == allow && matched != nil; default/safe/quick-reject ⇒
allow && matched == nil. There is no Decision.deny(Deny) and no warn case.
The T1 implement prompt’s “associated-value shape” is withdrawn; T1 spec wins this API.
```

### L1 — PLAN (scoreboard / medium)

```
v1 scoreboard = DCG 0.11.0 engine decision + rule_id, not SKILL.md prose.
Critical/high → deny. Medium/low → allow + matched (DCG Warn/Log; no warn wire).
git stash drop → allow, matched core.git:stash-drop. git stash clear → deny
core.git:stash-clear. SKILL.md rows that disagree (stash-drop block, $TMPDIR allow)
are quarantine fixtures, not the scoreboard. Strike notes line
“Medium severity (stash-drop) is still a deny in rv.”
```

### L2 — PLAN (miss policy)

```
Never allow because evaluation did not finish.
1) rvd down or skew → in-process evaluate (already locked).
2) Decision.indeterminate (oversize or budget) → hook deny with a short hostDenyText
   that has no pack rule_id: “rv could not finish evaluating this command. Run it in Terminal.”
   Not empty-stdout allow. Strike T4.3 “Allow (incl. indeterminate)” and T8
   “indeterminate-as-allow.”
3) Missing rv / adapter spawn or parse failure → block with a short reason on Pi and
   OpenCode (return { block: true, reason } / throw). Grok: the host fail-opens if the
   process is missing; rv hook itself must still not empty-allow an evaluate it did not run.
   “Do not wedge the host” is not a silent allow-all. Strike T5 open Q7’s fail-open default
   and host-contracts/T5 contradiction by taking this paragraph.
```

### L3 — PLAN (LaunchAgent owner)

```
T6 rv setup installs the T3 plist template to
$HOME/Library/LaunchAgents/dev.rv.evaluate.plist with the resolved rvd path,
launchctl bootstrap if needed, KeepAlive false. T6 uninstall removes only that plist.
T3 does not load a live agent. Hooks still work in-process if launchd is down.
```

### L4 — T1 (PackID)

```
PackID.rawValue matches ^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)?$
(dotted child optional). strict_git and package_managers are valid PackIDs.
Category IDs and the preset careful_company_running_windows are ConfigRef strings,
not PackIDs; expand() accepts ConfigRef.
```

### L5 — T1 (ICU load)

```
ICU / NSRegularExpression is the only PatternEngine. Do not add fancy-regex or a
second regex package. Keep 0.11.0 pattern strings. If a pattern fails to compile:
quarantine that pattern name and every corpus row that needs it; still load the pack.
Never quarantine core.git:reset-hard — that compile failure fails T1.
Semantic (?!) rows stay in JSON and never match. Do not rewrite a pattern to pass ICU.
```

### L6 — T1 (Codable result + JSON key + RuleID)

```
Use struct SafeMatch { pack: PackID, name: String } for matchedSafe. No tuples on
EvaluationResult. Destructive JSON field for the short deny sentence is "description"
(DCG reason). T9 may add "reason" as a decode alias, not a second schema.
RuleID.rawValue is pack:pattern (colon). displayID for pretty/hostDenyText is
pack/pattern (slash). Robot JSON uses pack_id plus rule_id = rawValue (colon form),
not the pattern fragment alone.
```

### L7 — PLAN parallel table (T2/T3/T8)

```
After T1: T2∥T3 in separate worktrees. T2 may add apple/swift-argument-parser
(from: "1.7.0"), executable product rv, and Sources/RVCLI/main.swift.
T3 may add executable product rvd and target rvd; it must not add ArgumentParser.
T8 policy (RVPolicy actor + PolicyGate) may start after T1 in parallel with T9.
T8 CLI (allow-once / allowlist commands) rebases onto T2; T8 must not add
ArgumentParser or @main. T9 must not add executables.
```

### L8 — T3 + T8 (consume)

```
IPC allowOnce.consume spends a grant, not a code:
params { command: String, cwd: String } → { consumed: Bool }.
Redeem of a plaintext code is TTY CLI only (AllowOnceStore.redeem) and is not an
IPC method in v1. T3 consume-twice tests use a preloaded grant, not a code string.
evaluate never consumes implicitly.
```

### L9 — T2 + host-contracts (deny copy)

```
hostDenyText never includes a redeemable code, before or after T8.
Canonical: “Blocked git reset --hard (core.git/reset-hard). Run it in Terminal, or rv allow-once.”
Mint is `rv allow-once mint -- <command>` on a TTY; it is not printed on the hook.
Strike host-contracts “or rv allow-once <code> only if a code exists.”
```

### L10 — PLAN + T6 (occupied / hostless)

```
“Occupied single slot” means the owned filename is present and is not the current
rv template. It does not mean “this host already has any hook.”
Grok slot: ~/.grok/hooks/rv.json. Pi slot: ~/.pi/agent/extensions/rv-guard.ts.
OpenCode slot: ~/.config/opencode/plugins/rv-guard.js.
Foreign siblings (dcg.json, other extensions/plugins) are not occupied.
Hostless = no v1 host detected → setup succeeds, one line to run rv setup later.
Occupied = skip that host, one line, continue other hosts. Not hostless.
```

### L11 — T4 (Grok exit)

```
Grok deny is {"decision":"deny","reason":"<hostDenyText>"} + exit 0.
Do not emit exit 2. DCG SKILL.md’s exit-2 table is not the Grok contract.
```

### L12 — T6 + T8 (config dir)

```
All rv file I/O honors process HOME (and only HOME) for the operator tree:
$HOME/.config/rv/. Do not use NSHomeDirectory() or homeDirectoryForCurrentUser.
Do not read XDG_CONFIG_HOME in v1. Tests set HOME to a temp dir.
```
