# Adversarial review — false negatives

Hunt: a destructive command would be allowed, a fail-open hole exists, XPC-down becomes allow, a host hook would miss shell tools, setup would skip wiring without saying so, tests would use live HOME, `RV_BYPASS`-shaped escapes, missing corpus rows for day-one denies, or DCG 0.11.0 critical/high rules omitted from T1 JSON.

Checked: `docs/factory/PLAN.md` (wins), `HANDOFF.md`, `references/dcg-0.11.0-notes.md`, `references/host-contracts-v1.md`, every file in `docs/factory/specs/` including `phase-1d-hosts.md` and `phase-2-packs.md`. Verified T1 name checklists against DCG **0.11.0** `src/packs/core/git.rs` and `src/packs/core/filesystem.rs` at tag `v0.11.0`.

## Verdict (Fix required)

The day-one line `git reset --hard` is specified correctly in T1 (path prefix, wrappers, `$(…)` / backticks, multi-segment). XPC down/skew is specified as in-process evaluate, not allow. Several other critical/high core.filesystem rules, the hook treatment of `indeterminate`, and the Pi/OpenCode adapter error matrix still let a destructive command through on a green ticket.

## Findings

### FN-01 — hook treats `indeterminate` as allow

- **ID:** FN-01
- **Spec path:** `docs/factory/specs/phase-1d-hosts.md` T4.3; `docs/factory/specs/phase-3-allow.md` PolicyGate rule 1
- **Hole:** T1 says `indeterminate` (budget exhausted or command > 65_536 bytes) is **never** treated as allow by later hook/XPC tickets. T4.3’s allow row explicitly includes `indeterminate` (empty stdout, exit 0). T8 PolicyGate says “allow (or T1 indeterminate-as-allow)” and returns `.none` without consuming — i.e. the hook encodes it as a quiet allow.
- **How an agent command slips through:** `python3 -c 'print("x"*70000 + " && git reset --hard")'` (or any padding past the T1 byte cap), or a command that burns `maxPatternAttempts` before `reset-hard` is tried. Engine returns `indeterminate`. `rv hook` emits empty stdout / exit 0. Grok fail-opens. Pi/OpenCode adapters treat exit 0 as allow. The reset runs.
- **Severity:** Critical
- **Required fix:** Lock hook/XPC/PolicyGate: `indeterminate` → native deny (or `{ block: true }` / throw) with a short `hostDenyText` that names incomplete evaluation, **not** empty allow. Delete “indeterminate-as-allow” from T8. Add L3 fixtures: oversize `git reset --hard` and budget-exhausted deny.

### FN-02 — `fork-bomb` is in T1 JSON but cannot fire

- **ID:** FN-02
- **Spec path:** `docs/factory/specs/phase-1-engine.md` (Quick-reject + corpus)
- **Hole:** DCG 0.11.0 `core.filesystem:fork-bomb` is Critical and is on the T1 destructive name checklist. Reachability in 0.11.0 is **not** the pack keyword list: `filesystem.rs` tests say an empty paren pair forces the pack (`filesystem_semantic_scan_required`). T1 quick-reject is keyword-only (`rm`, `find`, `unlink`, …, redirect tokens). `:(){ :|:& };:` has none of those tokens → `allow` + `quickRejected == true`. The regex never runs. The rule also uses backreferences (`\1`); T1 allows quarantining “non-day-one-critical” ICU misses and does **not** put `fork-bomb` on the never-quarantine list, so a compile miss can drop it twice.
- **How an agent command slips through:** Agent runs `:(){ :|:& };:` (or a word-named variant). Quick-reject allow. Host allow.
- **Severity:** High
- **Required fix:** Copy DCG’s empty-paren (and documented force-scan) into T1 quick-reject so `core.filesystem` is always a candidate for that shape. Never quarantine `fork-bomb`. Add corpus rows for the canonical bomb and a non-bomb function that must stay allow.

### FN-03 — blanket quote-mask vs quoted argv0 / quoted flags

- **ID:** FN-03
- **Spec path:** `docs/factory/specs/phase-1-engine.md` Normalize step 2 vs deny companions
- **Hole:** T1 says mask `'…'` / `"…"` regions so `echo "git reset --hard"` cannot match, **and** that `"git" reset --hard` must deny `core.git:reset-hard`. Those cannot both be true if “mask” replaces quoted text. DCG 0.11.0 does **role-aware** sanitization (mask echo/printf/`-m` *data*, keep executable tokens and flags). T1 specifies a single mask-all-quotes pass. Same hole for `git reset '--hard'` / `git reset "--hard"`: after mask, `reset\s+--hard` cannot see the flag. Quick-reject also says masked quoted data must not enable a pack — so `"git" reset --hard` loses the `git` keyword and never reaches the regex.
- **How an agent command slips through:** `"git" reset --hard` or `git reset '--hard'` (POSIX-equivalent to the day-one command). Matching view has no `git` / no `--hard` → allow.
- **Severity:** Critical
- **Required fix:** Replace “mask quoted regions” with DCG-shaped role-aware sanitization: strip quote *characters* on argv0/flags; mask only data-role arguments (`echo`, `printf`, `git commit -m`, …). Keep the near-miss allows. Add corpus rows for quoted argv0, quoted `--hard`, and quoted `-f` / `-rf`.

### FN-04 — L2 corpus omits the day-one `rm -rf` bypasses that are already in the JSON checklist

- **ID:** FN-04
- **Spec path:** `docs/factory/specs/phase-1-engine.md` Corpus / Acceptance
- **Hole:** T1’s destructive **name** checklist matches 0.11.0 `filesystem.rs` (verified: all 28 names including `find-delete-*`, `unlink-*`, `redirect-truncate-*`, `rm-glob-home`, `fork-bomb`). The **executable** L2 tables do not. `skill-table.json` follows SKILL.md (git + `rm -rf` only). `deny.json` extras are git wrappers plus one mixed tmp/`/etc` rm. Acceptance never requires `find / -delete`, `find . -delete`, `unlink ~/.ssh/id_ed25519`, `> /etc/passwd`, `rm -rf ~`, `rm -rf $HOME`, or `git push -uf`. A green L2 can ship extracted JSON and never prove those rules fire. DCG itself documents `find -delete` as the common agent swap after `rm -rf` is blocked.
- **How an agent command slips through:** After `rm -rf ./src` is denied, the agent runs `find ./src -delete` or `find / -delete`. If the extractor dropped the rule, ICU failed it, or quick-reject/`find` token logic is wrong, the suite still passes. Same for `> /etc/passwd` (no `rm`/`git` token — depends on redirect keywords surviving normalize).
- **Severity:** High
- **Required fix:** Promote these to required `deny.json` / acceptance rows with locked `rule_id`s from 0.11.0 (`find-delete-root-home` / `find-delete-general`, `unlink-root-home`, `redirect-truncate-root-home`, `rm-rf-root-home` for `~` and `$HOME`, `push-force-short` for `git push -uf`). Fail T1 if any listed name is missing from JSON **or** has no true-positive row (except documented `(?!)` semantic rules).

### FN-05 — empty or failed pack load is default-allow

- **ID:** FN-05
- **Spec path:** `docs/factory/specs/phase-1-engine.md`; `docs/factory/specs/phase-1c-service.md`
- **Hole:** T1 compile-fail is a load error for that JSON file — good. Nothing says evaluate/`rvd` must refuse to serve if `core.git` / `core.filesystem` are missing, empty, or failed to load. Evaluation order step 5 is default-allow. T3 warms the registry once; handshake can still be `ok`. Client only falls back on down/skew, not on “XPC returned allow with no packs.”
- **How an agent command slips through:** Resource path wrong, JSON decode fail swallowed, or `rvd` started with zero snapshots. `evaluate("git reset --hard")` → no keywords / no rules → allow. Hook is silent. Doctor can still show service `running`.
- **Severity:** Critical
- **Required fix:** Day-one packs missing or unloadable → `indeterminate` or a hard load error that hooks encode as deny (see FN-01). T3 must not ack `ok` with an empty core registry. Test: delete/break `core.git.json` → `git reset --hard` must not allow.

### FN-06 — Pi/OpenCode adapter fail-open is wider than PLAN’s missing-binary residual

- **ID:** FN-06
- **Spec path:** `docs/factory/specs/phase-1d-hosts.md` T5.1 / T5.3
- **Hole:** PLAN locked resolution 6: missing `rv` binary is hook-grade residual fail-open; `rvd` down is not. T5 goes further. Pi’s host is **fail-safe** (`tool_call` errors block). The adapter **must catch** spawn/parse errors and return nothing (allow). T5.3 then defines: exit `0` **or** empty stdout → allow; spawn error, timeout, non-JSON, exit `>= 2` → allow. Combined: (1) a present but hung/crashed `rv hook` allows; (2) deny JSON with Grok’s exit `0` allows on Pi/OpenCode because exit 0 wins over stdout; (3) any adapter JSON parse miss allows. That is not “missing binary.” It inverts Pi’s fail-safe for every adapter fault.
- **How an agent command slips through:** `git reset --hard` → adapter spawns `rv hook --host pi` → process times out, exits 2, or (if codecs are shared) prints Grok deny JSON with exit 0 → adapter returns nothing / does not throw → Pi/OpenCode run the reset.
- **Severity:** Critical
- **Required fix:** Keep PLAN’s missing-binary residual only. For a **spawned** `rv` that exits or times out: Pi should fail-safe (`{ block: true, reason }` short “rv failed”). Honor deny JSON **regardless of exit code** (same as Grok). Empty stdout + exit 0 remains allow. Add adapter fixtures: deny JSON + exit 0 must block; timeout/crash of a started `rv` must block on Pi.

### FN-07 — doctor `wired` does not prove the baked `rv` path exists

- **ID:** FN-07
- **Spec path:** `docs/factory/specs/phase-1d-hosts.md` T6.1 / T7.1
- **Hole:** T6 bakes an absolute `rv` path into `rv.json` / `rv-guard.ts` / `rv-guard.js`. T7 `wired` = owned file matches template. No `test -x` on that path. After a brew cellar move or a deleted `~/.local/bin/rv`, the file still “matches,” doctor is green, and T5/PLAN residual fail-open lets every deny through. Occupied/hostless paths do print a line; this stale-path case does not.
- **How an agent command slips through:** Hooks still installed. Binary gone or moved. Agent `git reset --hard` → adapter cannot exec `rv` → allow (FN-06 / PLAN residual). Operator runs `rv doctor` and sees `wired`.
- **Severity:** High
- **Required fix:** T7 `wired` requires the baked path to be an executable `rv`. Missing/non-exec → `broken` + one line (`rv setup`). L1 fixture: template-matching file pointing at `/nonexistent/rv` is not `wired`.

### FN-08 — T9 runtime-skips ICU-incompatible catalog rules

- **ID:** FN-08
- **Spec path:** `docs/factory/specs/phase-2-packs.md` Extractor / Quarantine
- **Hole:** T1: compile fail = load error, not a silent skip (explicitly so `reset-hard` cannot vanish). T9: a catalog pattern ICU cannot compile is **quarantined (skip that rule, record it)**. The JSON still contains the rule; evaluate does not run it. Enabling `database.sqlite` / `system.disk` then looks on while `DROP TABLE` / `dd of=/dev/sda` may allow. T9 says “do not silently drop the rule from JSON” — dropping it from the matcher is the FN.
- **How an agent command slips through:** Operator enables a pack. Agent runs a critical command whose regex is lookbehind/backref-ICU-incompatible. Rule skipped. Default-allow.
- **Severity:** High (catalog / T9; not the T1 core gate if T1 load-error holds)
- **Required fix:** Same as T1 for any **critical/high** rule: load error or fail the pack enable, not skip-and-continue. Quarantine file must fail the suite if a skipped rule is critical/high and has a corpus row. Do not enable a pack that dropped blocking rules.

### FN-09 — allow-once consume is not cross-process safe; T3 consume is a TTY-less redeem

- **ID:** FN-09
- **Spec path:** `docs/factory/specs/phase-3-allow.md` (actor consume, no file lock); `docs/factory/specs/phase-1c-service.md` `allowOnce.consume`
- **Hole:** T8 serializes consume inside one process actor and does not require atomic file replace / flock. T3 fallback is in-process when `rvd` is down — each `rv hook` is its own process and its own actor. Two concurrent hook children can both see one grant and both allow. Separately, T3 `AllowOnceConsumeParams` is `{ code: String }` and “records a grant”; T8 consume is `{ command, cwd }` after a **TTY** redeem. T3 consume is therefore a non-TTY redeem over XPC.
- **How an agent command slips through:** Human redeems once. Two parallel `git reset --hard` hooks while `rvd` is idle-exited both in-process-consume → both allow. Or an agent that saw a 6-hex code calls `allowOnce.consume` on `rvd` (no TTY) and a later evaluate honors the grant.
- **Severity:** High (unlock path; not the first deny)
- **Required fix:** One on-disk grant store with atomic compare-and-swap (or only consume inside `rvd`, and in-process fallback must use the same locked file). T3 `allowOnce.consume` must match T8 (fingerprint + cwd, not code). Code redeem stays TTY `rv allow-once`. Add a two-process consume test that expects exactly one allow.

## Specs that are clean

- **`phase-0-repo.md`** — no evaluate/hook path; live HOME and `RV_BYPASS` forbidden.
- **`phase-1b-ux.md`** — render only; no hook pretty; `hostDenyText` has no code; no evaluate skip.
- **`phase-1c-service.md` (XPC law)** — down / skew / mid-call interrupt → in-process evaluate; `git reset --hard` must still deny; no `RV_*` skip. (Empty registry is FN-05, not an XPC-miss allow.)
- **`phase-4-later.md`** — fence only; does not authorize v1 fail-open.
- **T1 day-one `git reset --hard` rows that exist** — `/usr/bin/git reset --hard`, `sudo`/`env`/`command`/`\`, `&&` / `||` / `;` / `|`, `` `git reset --hard` ``, `$(git reset --hard)` are specified deny. `rm -fr` / `rm -r -f` / `rm --recursive --force` are on the SKILL.md flag-order table. `git push -f` is on the skill table. T1 JSON **names** for core.git + core.filesystem match 0.11.0 source (not omitted from JSON).
- **Grok shell-tool recognition (as specified)** — T4.2 + PLAN resolution 7 accept `run_terminal_command`, `run_terminal_cmd`, and `Bash`; non-shell does not evaluate.
- **Setup skip messaging** — hostless and occupied owned-name both require one line. T6 forbids `NSHomeDirectory()` so tests follow `$HOME`.
- **`RV_BYPASS`** — PLAN + T4 + T8 + T9 forbid skip-evaluate envs, including Grok `permissionMode: bypassPermissions`.

## What you chose not to flag (and why)

- **Missing `rv` binary → adapter allow.** PLAN locked resolution 6 and host-contracts now call this hook-grade residual. Still a real day-one gap if setup’s path is wrong; FN-06/FN-07 are the parts PLAN did **not** accept (crash/timeout of a started `rv`, doctor lying `wired`).
- **Medium `git stash drop` → allow.** PLAN resolution 2 + T1 follow DCG 0.11.0 `Severity::Medium` → warn → does not block. `dcg-0.11.0-notes.md` still says “medium is still a deny”; that note is stale against PLAN, not an implementer FN.
- **T1 `PackID(rawValue:)!`.** PLAN resolution 3 + current T1 forbid `!` and accept `strict_git` / `package_managers`. The old snippet is gone.
- **T4/T3 evaluate without PolicyGate.** Without the gate, allow-once/allowlist never apply → extra **deny**, not an allow. Unlock-doesn’t-work is a product hole, not a destructive FN. FN-09 is the consume race / TTY-less redeem that *does* allow.
- **Grok parse-failure / host timeout fail-open.** Grok’s documented host behavior. T4 matching it is honesty, not an rv XPC hole.
- **OpenCode `command.execute.before` not registered.** Official plugin API uses that hook for slash/custom commands (`input.command`), not the `bash` tool (`tool.execute.before` + `output.args.command`). T5’s official field pin is correct; community wrong-field gists are already forbidden.
- **`bash -c 'git reset --hard'` / heredoc / git-alias `(?!)` rules.** PLAN + T1 + phase-4 defer AST/alias. Semantic rows stay in JSON and correctly do not fire under ICU. Not a silent JSON drop.
- **Agent disables `core.git` or edits hook files.** PLAN threat model: grade is hook, not adversarial. T9 allowing explicit core disable + doctor warn is consistent.
- **Live HOME / `RV_BYPASS` in tests.** Specs already require temp `$HOME` / injected `baseDirectory` and grep-forbid bypass envs.
- **`run_terminal_cmd` deny fixture missing.** T4.2 already evaluates that name; only the allow fixture is listed. Test-gap, not a specified allow-hole.
