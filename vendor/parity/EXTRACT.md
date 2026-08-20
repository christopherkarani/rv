# Extract map

T9 fills the remaining catalog from a local `--source-root` already at tag `v0.11.0` / commit `2ed7eeef1ae63d204495f02312c657dd6d9bf73d`. Runtime rv does not run the extractor. Do not vendor the Rust tree into this repo.

| Field | Value |
|---|---|
| Upstream | `https://github.com/Dicklesworthstone/destructive_command_guard` |
| Version | 0.11.0 |
| Git tag | `v0.11.0` |
| Tag object | `6d4fcaef45d6b207a291158dc4077e54e6be685c` |
| Commit | `2ed7eeef1ae63d204495f02312c657dd6d9bf73d` |

## Command

```sh
python3 tools/extract-packs/extract_packs.py \
  --source-root /path/to/checkout-at-v0.11.0
```

Pin checks: `Cargo.toml` `version = "0.11.0"` and `git rev-parse HEAD` must equal the commit above. If `pack_count != 99`, stop and re-diff against the pinned tree.

Day-one-only (legacy):

```sh
python3 tools/extract-packs/extract_core_packs.py --source-root /path/to/checkout-at-v0.11.0
```

## Outputs

| Path | Role |
|---|---|
| `Sources/RVPacks/Resources/packs/index.json` | 99 IDs, 27 categories, presets, tiers, default-on = core only |
| `Sources/RVPacks/Resources/packs/<id>.json` | One document per pack (filename == id) |

Index keys use `pin_version` / `pin_tag` / `pin_commit` (not upstream product tokens) so Sources stay clean of factory-forbidden names. Decoded pattern text still matches the pin.

## Source-wins notes (core)

- `git push -uf` matches extracted `push-force-short`.
- `git restore --worktree` first-match is `restore-worktree`.
- `rm -rf /var/log` matches `rm-rf-root-home`.
- Medium `stash-drop` is allow + match.
