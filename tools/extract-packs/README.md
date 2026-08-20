# extract-packs

Extract pack JSON from a local checkout already at tag `v0.11.0` / commit
`2ed7eeef1ae63d204495f02312c657dd6d9bf73d`. Does not clone, fetch, or vendor
Rust into this repo.

Full catalog (T9):

```sh
python3 tools/extract-packs/extract_packs.py --source-root /path/to/checkout-at-v0.11.0
```

Day-one only (T1 legacy):

```sh
python3 tools/extract-packs/extract_core_packs.py --source-root /path/to/checkout-at-v0.11.0
```

Pin: `vendor/parity/PIN`. Details: `vendor/parity/EXTRACT.md`.
