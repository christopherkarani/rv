# Evaluate landmines

Do not treat this file as the scoreboard. Drift table and pin live only in
`docs/dev/PARITY.md` + `vendor/parity/PIN`. These are the rows agents keep
getting wrong.

## Required allow (near-miss)

Keep these as allow rows. Copying an unbounded `(?:\S+\s+)*` walker onto
`push-force` or `--force` will deny them:

- `git push --force-with-lease`
- `git push --force-with-lease --force-if-includes`
- `git push origin feature--force`
- `git push origin feature-f`
- `git push origin main && echo done --force`
- `git commit -m "git push --force"`
- `git restore . --staged`
- `git restore file.txt --staged`
- `echo "git reset --hard"`
- `rg -n "rm -rf"`
- `git checkout -b`

Do not delete those ids to go green.

## Do not rewrite

- `git push -uf` already matches extracted `push-force-short`. Do not
  rewrite that regex to “make `-uf` clearer.”
- Extracted `reset-hard` / `stash-*` / `clean-force` walkers stay as pinned.
  The forbid is copying those walkers onto `push-force`.
- `git reset --'hard'` is still `reset-hard` (quote characters stripped on
  flags). Do not change the regex for adjacent quotes.

## Normalize

Role-aware quotes: strip quote **characters** on argv0 and flags so
`"git" reset --hard` and `git reset '--hard'` still deny. Mask only
**data-role** quoted arguments (`echo` / `printf` / `git commit -m`) so
those stay allow.

Do not mask `` `…` `` or `$(…)`. Do not expand `$TMPDIR`.

Redirect keywords (`>/`, `> /`, `>~`, …) must keep `core.filesystem` a
candidate. `>/etc/passwd` is not an argv0 path — do not strip it as one.

Quoted python/node/ruby `-c`/`-e` program text (the token after the flag)
is data. Do not mask interpreter heredocs — unwrap does not peel them, so
`os.system('git reset --hard')` inside `python3 <<'PY'` must stay visible.
Do not mask attached `node --eval=` / `--print=` (unwrap does not peel
those). Do not mask `bash`/`sh`/`zsh` heredocs. Do not mask a payload that
contains `$(` or backticks. Ruby attached `-e` is data because unwrap peels it.

## Quick-reject and per-pack safe

Keywords come from enabled snapshots. `core.filesystem` must still be a
candidate for an empty paren pair (`:(){ :|:& };:`) so `fork-bomb` can
fire. Quick-reject on keywords alone lets that command through.

A safe match skips **that pack’s** destructive list only. A filesystem
safe must not suppress a git deny.

## Empty packs

Missing or empty core packs → `indeterminate(.corePacksUnavailable)`.
Do not invent `deny(core.git:unavailable)`.

## Quarantine

Quarantine a pattern name when ICU cannot compile it. Do not retarget the
row’s expected `rule_id`. Never quarantine `reset-hard` or `fork-bomb`.
