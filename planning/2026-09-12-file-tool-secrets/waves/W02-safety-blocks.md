# Wave W2 extract — safety + block ledger

**Parent:** `/Users/chriskarani/CodingProjects/rv/planning/2026-09-12-file-tool-secrets-implementable-program.md`  
**Depends:** W1 merged and oracles 1–6 green  
**mode:** full · **max_units:** 8 · **max_parallel:** 3 · **agent_budget:** 1024

Units: `w2-safety`, `w2-allow`, `w2-strict`, `w2-cli-safety`, `w2-blocks-store`, `w2-blocks-cli`, `w2-hook-record`, `w2-docs`.

## Reject (copy)

- Default-on allow history
- Command text in `os_log`
- `secret.allow_paths` exempting host-auth rows
- Repo lowering machine `strict`
- Third preset; GUI
- Enabling extra packs via the safety knob

## Parallel

- `w2-safety` ∥ `w2-blocks-store`
- then `w2-allow` ∥ `w2-strict` ∥ `w2-cli-safety` ∥ `w2-blocks-cli`
- then `w2-hook-record`
- then `w2-docs`

## Oracles

Parent §4 rows 7–10.
