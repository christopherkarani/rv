# extract-packs

One-shot extract of day-one pack JSON from a local checkout already at tag `v0.11.0`.

Committed JSON under `Sources/RVPacks/Resources/packs/` is what `swift test` loads. This script does not clone, fetch, or vendor Rust into this repo.

```sh
python3 tools/extract-packs/extract_core_packs.py --source-root /path/to/checkout-at-v0.11.0
```

Required source files at that root:

- `src/packs/core/git.rs`
- `src/packs/core/filesystem.rs`

Pin: `vendor/parity/PIN` (`version=0.11.0`, commit `2ed7eeef1ae63d204495f02312c657dd6d9bf73d`).
