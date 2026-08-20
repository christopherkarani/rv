# Parity

Pinned 0.11.0 engine source is the scoreboard. T1 implements in-process `evaluate`.

| Field | Value |
|---|---|
| Upstream | `https://github.com/Dicklesworthstone/destructive_command_guard` |
| Version | **0.11.0** |
| Git tag | `v0.11.0` |
| Tag object | `6d4fcaef45d6b207a291158dc4077e54e6be685c` |
| Commit | `2ed7eeef1ae63d204495f02312c657dd6d9bf73d` |
| v1 scoreboard | Same `Decision` + `rule_id` as the pinned **0.11.0 engine source** (not marketing tables). Critical/high deny; medium/low allow + match. Not line-for-line Rust. Not an alias of the upstream binary. |
| Day-one deny | `git reset --hard` → `deny` `core.git:reset-hard` |
| Not a v1 gate | Agree-rate against an upstream CLI on PATH. |

Machine-readable pin: `vendor/parity/PIN`.

Evaluation order: normalize → quick-reject → safe patterns first → destructive → default allow.

## Catalog (T9)

Bundled pack documents: **99** IDs / **27** categories from the pin. Default-on remains `{core.filesystem, core.git}` only. Upstream 0.11.0 also default-on `system.disk` (and Windows packs on Windows); **rv v1 keeps those off** until the operator enables them. Enabling the rest of the catalog by default is Phase 4+, not v1.

`rv packs` lists / enable / disable under `$HOME/.config/rv/config.toml` `[packs]`. Agree-rate vs an upstream CLI is still **not** a gate.

## SKILL.md drift (rv follows 0.11.0 source)

| Claim in the skill table | 0.11.0 actual | rv |
|---|---|---|
| `rm -rf ${TMPDIR}/build` is a safe temp delete | deny `core.filesystem:rm-rf-general` | deny |
| `git stash drop` is blocked | match `core.git:stash-drop`, severity medium | allow + match |
| “34 safe / 16 destructive” | full core packs are larger | ignore counts; extract full packs |
| `rm -rf /var/log` as `rm-rf-general` | extracted `rm-rf-root-home` regex matches any `/` prefix | source-first: `rm-rf-root-home` |
| `git restore --worktree` / `-W` as `restore-worktree-explicit` | first blocking match is `restore-worktree` (listed first; only excludes staged flags) | `restore-worktree`. Explicit name is `git restore -S -W` |

Never quarantine `core.git:reset-hard` or `core.filesystem:fork-bomb`.
