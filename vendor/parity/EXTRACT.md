# Extract map

T1 filled day-one JSON from a local `--source-root` already at tag `v0.11.0` / commit `2ed7eeef1ae63d204495f02312c657dd6d9bf73d`. No extractor in T0; T9 fills catalog. Do not vendor the Rust tree.

| Field | Value |
|---|---|
| Upstream | `https://github.com/Dicklesworthstone/destructive_command_guard` |
| Version | 0.11.0 |
| Git tag | `v0.11.0` |
| Tag object | `6d4fcaef45d6b207a291158dc4077e54e6be685c` |
| Commit | `2ed7eeef1ae63d204495f02312c657dd6d9bf73d` |

## Upstream → dest

| Path at tag `v0.11.0` | Dest / owner |
|---|---|
| `src/packs/core/git.rs` | `Sources/RVPacks/Resources/packs/core.git.json` |
| `src/packs/core/filesystem.rs` | `Sources/RVPacks/Resources/packs/core.filesystem.json` |
| `SKILL.md` | L2 corpus decisions in `Tests/RVEngineTests/Fixtures/corpus/` (not a vendored copy) |
| `src/packs/*/` | Remaining catalog JSON, default-off (T9) |

## Name sets (source wins)

`core.git`: 6 safe, 14 destructive. Matches the T1 checklist, including semantic-only `(?!)` rows `git-alias-semantic-unverified` and `branch-dynamic-token`.

`core.filesystem`: 33 safe, 28 destructive. Matches the T1 checklist, including semantic-only `(?!)` row `sed-exec-unverified`.

Regenerate:

```sh
python3 tools/extract-packs/extract_core_packs.py --source-root /path/to/checkout-at-v0.11.0
```

Reason / explanation strings are name-hygiene sanitized on extract. Pattern strings are the 0.11.0 regexes unchanged.

## Source-wins notes

- `git push -uf` matches extracted `push-force-short` (`-[a-zA-Z]*f[a-zA-Z]*\b`). Do not rewrite the regex.
- `git restore --worktree file.txt` and `git restore -W file.txt` first-match `restore-worktree` (that pattern only excludes `--staged`/`-S` and is listed first). `restore-worktree-explicit` fires when a staged flag is also present, e.g. `git restore -S -W file.txt`. Do not reorder the extracted rules.
- `rm -rf /var/log` matches extracted `rm-rf-root-home` because that regex treats a `/` prefix as root/home. `rm -rf ./src` remains `rm-rf-general`. Do not rewrite the regex.
- `$TMPDIR` / `${TMPDIR}` are not safe `rm -rf` prefixes.
- Medium `stash-drop` is allow + match.
