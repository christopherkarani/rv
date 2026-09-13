# W3 oracles — isolated HOME `rv test --robot`

Named 2026-09-13. Guard maturity overlay wave W3. Not the 0.2 execute queue.

**Execute overlay:** `planning/2026-09-13-guard-maturity-implementable-program.md`. Do not start IR (OPE-156), Host Ask, or live Auto-review from this name.

Human picture: one scripted transcript an implementor can run without touching login dotfiles. Decisions prove the product door (`evaluateWithSemantics`) against the maturity corpus rows — not a second engine.

**Script:** `tools/host-oracle.sh`. Creates `mktemp` HOME, builds `rv` with `tools/swift-6.3.3 build --product rv` (toolchain HOME = login home), puts `.build/.../rv` on `PATH`, runs the cases below, snapshots login `.claude` / `.pi` / `.grok` and login `config.json` so the run cannot create or rewrite them, then removes the temp tree on EXIT. Does not run `rv setup`. Does not use login HOME as `HOME`.

## Invocation shape

Each case is `rv test --robot <one argv command>`. Do **not** pass `rv test --robot -- <cmd>`: ArgumentParser `captureForPassthrough` keeps `--` in the evaluated command text (`Command: -- echo '…'`), which pack-matches `core.git:reset-hard` and breaks the data rows. The oracle passes each command as one argv after `--robot` (c-hook-proof style).

Stdout is one `rv.test.v1` JSON object. Allow → exit 0. Deny → exit 1. The reset-hard transcript row must carry `reset-hard` in reason, `rule_id`, or `pack_id` — a generic `core.git:*` deny is not enough.

## Transcript

| Command | Expect | Notes |
|---|---|---|
| `git status` | allow | baseline |
| `git reset --hard` | deny | `reset-hard` / `core.git` |
| `bash -c 'git reset --hard'` | deny | wrapped executing sink |
| `echo 'git reset --hard'` | allow | data, not executing (**RV-RR-02**) |
| `python -c "print('git reset --hard')"` | allow | data, not executing (**RV-RR-05**) |
| `git status` (after invalid config) | allow | machine `~/.config/rv/config.json` with `"safety": { "level": "nope" }`; invalid level degrades, does not brick evaluate |

After the invalid-config case, the script must not write machine `policy.toml`. Login snapshot must still match (no new host dirs, no rewritten login `config.json`).

## Gate

```bash
tools/host-oracle.sh
```

Exit 0 and `host-oracle: ok` on stderr.
