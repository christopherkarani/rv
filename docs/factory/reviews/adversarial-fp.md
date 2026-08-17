# Adversarial review — false positives

Hunt: a spec that would make rv block a safe command, invent a contract that is not DCG 0.11.0 / not locked PLAN, over-claim a host protocol, copy ryk leftover-ask-as-permit, treat SKILL.md marketing as law when 0.11.0 source disagrees, or add a deny that DCG would allow.

Checked: `docs/factory/PLAN.md` (wins), `HANDOFF.md`, `references/dcg-0.11.0-notes.md`, `references/host-contracts-v1.md`, every file in `docs/factory/specs/` including `phase-1d-hosts.md` and `phase-2-packs.md`. Contested claims verified against DCG **0.11.0** (`v0.11.0`, commit `2ed7eeef1ae63d204495f02312c657dd6d9bf73d`) `src/packs/core/git.rs`, `src/packs/mod.rs` (`Severity::default_mode` / `blocks_by_default`), `tests/corpus/canonical.toml`, and current Grok / Pi / OpenCode host docs. No product code. No ryk edits.

PLAN locked resolutions already closed two named landmines (associated-value `Decision`, `PackID` without a required dot). This review is against the **current** specs, not the pre-lock drafts.

## Verdict (Fix required)

T1’s engine law is mostly right: medium `git stash drop` is allow, `$TMPDIR` follows 0.11.0 deny, `--force-with-lease` and `git checkout -b` are allow, `strict_git` is a legal `PackID`. The factory can proceed on T0. It must not proceed to T1/T4 implement prompts until three holes are closed: the notes file still orders a stash-drop **deny**, T2/T4 can turn a medium **match** into a host block, and T1’s required near-miss table would accept a green L2 that still false-positives DCG’s own force-push / restore-staged landmines.

## Findings

### FP-01 — notes still order `git stash drop` as a deny

- **ID:** FP-01
- **Spec path:** `docs/factory/references/dcg-0.11.0-notes.md` (HANDOFF tells T1+ implementers to read this for “FN/FP landmines”)
- **Claim:** “DCG Medium severity (`stash-drop`) is still a deny in rv (no warn wire).”
- **Why it is a false positive:** DCG 0.11.0 `src/packs/mod.rs` maps `Severity::Medium` → `DecisionMode::Warn`, and `Warn` does **not** block (`blocks_by_default` is only critical/high). `git.rs` attributes `stash-drop` as `Medium`. SKILL.md’s “What It Blocks” row for `git stash drop` is marketing. PLAN locked resolution 2 and T1 both say medium → **allow + match**. An implementer who trusts the notes over T1 will deny a command DCG 0.11.0 would run.
- **Severity:** High
- **Required fix:** Rewrite that bullet to: medium/low never deny; `git stash drop` is allow + `core.git:stash-drop`. Point at PLAN resolution 2 / T1 quarantine `skill.stale.stash-drop-block`. Do not leave “no warn wire ⇒ deny” in any file HANDOFF lists.

### FP-02 — medium match can become a host deny

- **ID:** FP-02
- **Spec path:** `docs/factory/specs/phase-1b-ux.md` (`hostDenyText`); `docs/factory/specs/phase-1d-hosts.md` T4.3; fed by `docs/factory/specs/phase-1-engine.md` `EvaluationResult.matched`
- **Claim:** T1: `matched` is populated on “deny, or allow-from-medium/low”. T2: `hostDenyText(from: EvaluationResult, command:) -> String` (not optional) is “the native host reason” T4/T5 consume. T4.3 Allow row: “Allow (incl. non-shell, empty command, default-allow, indeterminate)” — **no** “medium/low match”.
- **Why it is a false positive:** `git stash drop` is `Decision.allow` plus a `RuleMatch`. T2’s voice table says hook allow is empty, but the function is a non-optional `String` and T4 never names allow-with-match as Allow. A T4/T2 implementer who keys off `matched != nil`, non-empty `hostDenyText`, or “any rule_id ⇒ deny JSON” will emit `{"decision":"deny",...}` / `{ block: true }` / `throw` for a command DCG warns and PLAN/T1 allow. That is a host block of a safe (non-blocking) command.
- **Severity:** High
- **Required fix:** `hostDenyText` returns `nil` / empty unless `Decision` is `deny(Deny)`. T4.3 Allow row must list “medium/low match (stash-drop)”. L3 fixture: `git stash drop` → empty stdout, exit 0, evaluate not encoded as deny. T2 L1: allow-with-match → `denyViewModel == nil` and `hostDenyText == nil`.

### FP-03 — L2 near-miss table omits DCG’s own force-push / restore FPs

- **ID:** FP-03
- **Spec path:** `docs/factory/specs/phase-1-engine.md` (Pack data example + Near-miss table + multi-segment full-string pass)
- **Claim:** Illustrative destructive regex uses the unbounded walker `(?:^|[^[:alnum:]_-])git\\s+(?:\\S+\\s+)*reset\\s+--hard`. Evaluation: “If every segment allows, also evaluate the full string once”. Required near-miss table is only `echo "git reset --hard"`, `rg -n "rm -rf"`, `git commit -m "fix rm -rf detection"`, `"git" status`, `ls -la`. Allow table has `git push --force-with-lease` and `git restore --staged file.txt`, not the 0.11.0 landmines.
- **Why it is a false positive:** DCG 0.11.0 `push-force-long` is `git\s+(?:[^\s&;|`()<>]+\s+)*push\s+(?:[^\s&;|`()<>]+\s+)*--force(?![-a-z])` — bounded walker + `(?![-a-z])` — specifically so `.*--force` / `(?:\S+\s+)*` cannot hit `feature--force` or span `&&` into a later `--force` (`git.rs` comments + tests at `feature--force`, `--force-with-lease`, `git push origin main && echo done --force`). Role-aware sanitization is required so `git commit -m "git push --force"` does not match. `restore-staged-long` is `(?=.*\s--staged\b)` so `git restore . --staged` is safe. T1 says “extract 0.11.0 regexes”, but the only concrete pattern in the spec is the unbounded walker, and a green `near-miss.json` need not contain those rows. An implementer who copies the example walker onto `push-force-long` (or “simplifies” `--force`) still passes L2 and then blocks DCG-allowed commands. Full-string re-eval after all segments allow is exactly the pass that made the old unbounded walker false-positive `git push origin main && echo --force`.
- **Severity:** High
- **Required fix:** Promote these to required `near-miss.json` / acceptance rows (must allow, same as 0.11.0 pack tests): `git push --force-with-lease`, `git push --force-with-lease --force-if-includes`, `git push origin feature--force`, `git push origin feature-f`, `git push origin main && echo done --force`, `git commit -m "git push --force"`, `git restore . --staged`, `git restore file.txt --staged`. Replace the example `push-force` / walker snippet with the 0.11.0 bounded pattern, or label the example “schema only — do not copy the walker”. Fail T1 if those rows deny.

### FP-04 — host-contracts fail-closed on missing `rv` would block every bash

- **ID:** FP-04
- **Spec path:** `docs/factory/references/host-contracts-v1.md` (Pi); conflicts with PLAN locked resolution 6 and `phase-1d-hosts.md` T5.1
- **Claim:** “DCG’s published recipe **fails open** if `dcg` is missing. **rv must not.** Missing `rv` / evaluate error → block with a short reason.”
- **Why it is a false positive:** That is fail-closed on a missing binary. Every Pi/OpenCode `bash` — including `git status`, `git checkout -b`, `ls` — would return `{ block: true }` / throw. PLAN resolution 6 and T5.1 lock missing-binary as residual **fail-open** (do not wedge the host). XPC-down is a different hole (in-process evaluate). Following the reference as written invents a deny DCG’s Pi recipe does not apply and PLAN forbids.
- **Severity:** Medium
- **Required fix:** Strike “missing rv → block” from `host-contracts-v1.md`. Align with PLAN: missing binary → adapter allow; `rvd` down/skew → in-process evaluate (still deny `git reset --hard`). Leave T5.1 as the implement law.

## Specs that are clean

- `docs/factory/PLAN.md` — locked resolutions 1–3 close Decision / medium / PackID. No leftover-ask. Default-allow unknown commands.
- `docs/factory/specs/phase-0-repo.md` — no evaluate contract; no invented deny.
- `docs/factory/specs/phase-1-engine.md` **decision table** — medium/low → allow; `$TMPDIR` follows 0.11.0 deny; `git checkout -b`, `--force-with-lease`, `rm -rf /tmp/build` are allow; `PackID` accepts `strict_git` / `package_managers`; `git branch -d` deny matches 0.11.0 source (not a FP). Corpus/example walker is FP-03, not the severity map.
- `docs/factory/specs/phase-1c-service.md` — evaluate meaning is T1; default-allow unknown; never allow because XPC missed. `classify` is unused by v1 hosts.
- `docs/factory/specs/phase-2-packs.md` — 97 extras default-off; `strict_git` / `package_managers` are first-class IDs; no `RV_PACKS` skip-evaluate.
- `docs/factory/specs/phase-3-allow.md` — no host Allow, no leftover-ask-as-permit, no `RV_BYPASS`, no redeemable code on `hostDenyText`. `PolicyGate` returns engine allow (including medium) with `.none`.
- `docs/factory/specs/phase-4-later.md` — fence only; no v1 deny invention.
- `docs/factory/specs/phase-1d-hosts.md` **wire shapes** — Grok `{decision: deny, reason}` + `Bash` matcher + `run_terminal_command`/`run_terminal_cmd` match current xAI docs. Pi `{ block: true, reason }` matches Pi `extensions.md`. OpenCode `throw new Error` on `tool.execute.before` matches official plugins docs. No leftover-ask, no `permission.ask`, no toast, no `registerMessageRenderer`. (T4.3 medium-match omission is FP-02.)

## What you chose not to flag (and why)

- **`git branch -d feature` as deny** (`phase-1-engine.md` skill table). Feels like a human FP; DCG 0.11.0 `git.rs` tests `assert_blocks_with_pattern(..., "git branch -d feature", "branch-force-delete")` and SKILL.md FAQ says both `-d` and `-D` require approval. Source wins. Not a factory invention.
- **`Decision` flattened vs PLAN `deny(Deny)`.** PLAN resolution 1 and current T1 ship `deny(Deny)` / `indeterminate(IndeterminateReason)`. Already closed. T2 robot JSON `"decision":"deny"` is a wire encoding, not a flat domain enum.
- **`PackID` regex rejecting `strict_git`.** PLAN resolution 3 and current T1 accept IDs with or without a dot. Already closed. T9’s frozen list is consistent.
- **SKILL.md `$TMPDIR` is safe / “blocks stash drop” / “34 safe / 16 destructive”.** T1 quarantines these and follows 0.11.0 (`rm.safe.tmpdir-brace` is deny; stash-drop is medium allow). That is anti-FP, not FP.
- **T4.3 treating `indeterminate` as allow.** That lets a padded `git reset --hard` through (FN-01). Opposite of this hunt.
- **T5 adapter fail-open when `rv` is missing.** PLAN resolution 6. Residual FN, not a safe-command block.
- **Grok deny JSON + exit 0.** PLAN resolution 7; xAI docs show `{ "decision": "deny", "reason": "..." }` and “only an explicit deny blocks.” Not an over-claim. Exit-2-only would be a later capture, not a v1 FP.
- **OpenCode `command.execute.before`.** `host-contracts-v1.md` hedges; T5 does not invent the hook. Official docs use `tool.execute.before` + `throw`. Clean.
- **T2 `core.git/reset-hard` slash vs DCG `core.git:reset-hard`.** Display dialect. T8 accepts both. Does not change allow/deny.
- **T2 robot `"rule_id":"reset-hard"` without pack.** Identity slop, not a command block.
- **ryk leftover-ask-as-permit.** T4/T5/T8/PLAN forbid host Allow, `permission.ask`, `ctx.ui.confirm`, and leftover-ask rewrite. No copy found.
- **`git stash` on the SKILL.md “always safe” list.** T1 means default-allow for `git stash` / `pop` / `list`, not a prefix safe pattern that would suppress `stash-clear`. Wording is “default allow.” Not flagged.
- **T9 `DROP TABLE` deny after enable.** Opt-in catalog. Default-off. Not a day-one FP.
