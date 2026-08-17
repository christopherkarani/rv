# Extract map

No extractor in T0; T1 fills core JSON; T9 fills catalog.
Do not vendor the Rust tree.

| Field | Value |
|---|---|
| Upstream | `https://github.com/Dicklesworthstone/destructive_command_guard` |
| Version | 0.11.0 |
| Git tag | `v0.11.0` |
| Tag object | `6d4fcaef45d6b207a291158dc4077e54e6be685c` |
| Commit | `2ed7eeef1ae63d204495f02312c657dd6d9bf73d` |

## Upstream → dest

Do not clone or copy the upstream tree into this repo in T0.

| Path at tag `v0.11.0` | Dest / later owner |
|---|---|
| `SKILL.md` | `Tests/RVEngineTests/Fixtures/corpus/` (T1) |
| `src/packs/core/git.rs` | `Sources/RVPacks/Resources/packs/` as `core.git` JSON (T1) |
| `src/packs/core/filesystem.rs` | `Sources/RVPacks/Resources/packs/` as `core.filesystem` JSON (T1) |
| `src/packs/core/mod.rs` | Core pack module (T1) |
| `src/packs/mod.rs` | Pack registry (T1 / T9) |
| `src/packs/*/` | Remaining catalog JSON, default-off (T9). Includes `windows/` as data only — do not claim Windows support. |
| `docs/packs/README.md` | Pack ID index (T9) |

| rv path | Later owner |
|---|---|
| `vendor/parity/PIN` | T0 (this ticket) |
| `vendor/parity/EXTRACT.md` | This map |
| `Sources/RVPacks/Resources/packs/` | T1: `core.git` + `core.filesystem` JSON. T9: remaining JSON, default-off. |
| `Tests/RVEngineTests/Fixtures/corpus/` | T1 SKILL.md + core fixtures. |
| `tools/extract-packs/` | Future extractor entrypoint. |
