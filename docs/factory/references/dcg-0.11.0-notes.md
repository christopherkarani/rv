# DCG 0.11.0 notes for factory review

Pin: [Dicklesworthstone/destructive_command_guard](https://github.com/Dicklesworthstone/destructive_command_guard) tag/version **0.11.0**.
rv parity is **decision + rule_id**, not Rust line-for-line.

## Pack catalog (99 IDs, 27 categories)

Confirmed from `docs/packs/README.md` at v0.11.0. Categories: apigateway (3), backup (4), careful_company_running_windows (6), cdn (3), cicd (4), cloud (3), containers (3), core (2), database (8), dns (3), email (4), featureflags (4), infrastructure (4), kubernetes (3), loadbalancer (4), messaging (4), monitoring (5), package_managers (1), payment (3), platform (5), remote (3), search (4), secrets (4), storage (4), strict_git (1), system (3), windows (4).

Full ID list lives in that README. T9 imports them as JSON data, default-off except `core.git` and `core.filesystem`.

## DCG vs rv (do not copy blindly)

| DCG 0.11.0 | rv v1 |
|---|---|
| Claude Code PreToolUse hero | Pi / Grok / OpenCode shell only |
| `DCG_BYPASS=1` | **Forbidden.** No `RV_BYPASS`. |
| `~/.config/dcg/` | `~/.config/rv/` |
| `dcg` binary | `rv` + `rvd` |
| core packs cannot be disabled | Day-one: only core.git + core.filesystem on. Other DCG default-on packs (`system.disk`, Windows packs) stay **off** in rv v1. |
| Warn / Bypass outcomes exist in some fixtures | rv `Decision` is allow / deny / indeterminate. No warn-as-permit wire. |
| Default-allow unknown commands | Same (not fail-closed like ryk) |
| SKILL.md table is a subset (34 safe / 16 destructive in the skill text) | T1 corpus is that table **plus** core-pack fixtures extracted from 0.11.0 source |
| Pattern counts in SKILL.md are marketing-scale | Real packs are much larger; extractor must re-diff 0.11.0 |

## Rule ID shape

DCG uses `pack:pattern`. Confirm from 0.11.0 pack source. Do not treat ryk IDs as the spec.

### core.git (0.11.0 `src/packs/core/git.rs`)

Safe: `checkout-new-branch`, `checkout-orphan`, `restore-staged-long`, `restore-staged-short`, `clean-dry-run-short`, `clean-dry-run-long`.

Destructive (regex): `checkout-discard`, `checkout-ref-discard`, `restore-worktree`, `restore-worktree-explicit`, `reset-hard`, `reset-merge`, `clean-force`, `push-force-long`, `push-force-short`, `branch-force-delete`, `stash-drop`, `stash-clear`.

Semantic-only (regex is `(?!)` — ICU text match cannot fire these): `git-alias-semantic-unverified`, `branch-dynamic-token` (names from T1 spec / 0.11.0 source). T1 must leave them in JSON; ICU will not fire them.

Day-one deny example: `git reset --hard` → deny `core.git:reset-hard`.

Day-one allow examples: `git checkout -b feature`, `git restore --staged file`, `git clean -n`, `git push --force-with-lease`.

### core.filesystem (0.11.0 `src/packs/core/filesystem.rs`)

Safe temp forms include `rm-rf-tmp`, `rm-fr-tmp`, `rm-rf-var-tmp`, and long-flag temp variants.

Destructive includes `rm-rf-general`, `rm-rf-root-home`, `rm-recursive-force-long`, `find-delete-general`, `unlink-general`, `shred-general`, `dd-overwrite-general`, plus root-home variants. Exact T1 corpus rows must be extracted, not guessed from ryk.

### Engine behaviors T1 may miss (FN/FP landmines)

- Role-aware sanitization: `git commit -m "git push --force"` must not deny as `push-force-long`.
- Token walkers exclude shell metacharacters so chained commands do not false-positive.
- `--force-with-lease` must not match `--force`.
- Branch name `feature--force` must not match `push-force-long`.
- `git restore . --staged` is safe (flag in any position).
- DCG `rebase-recover` is not rv v1 (unlock is TTY `allow-once`).
- DCG Medium (`stash-drop`) is **allow + match** in rv (no warn wire). `stash-clear` is deny.

## Evaluation order (copy)

normalize → quick-reject → safe patterns first → destructive → default allow.

## What SKILL.md does not decide for rv

- Hosts, install, XPC, deny UX, unlock path, privacy, platform matrix.
- `DCG_BYPASS` and Claude-only hook docs.
