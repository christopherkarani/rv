# Laya judge: Phase 0/1 decision record (measured 2026-10-19, this machine)

Plan: [laya-guard-model-plan.md](laya-guard-model-plan.md). This record
holds the measured evidence behind the shipped defaults.

## Setup

- Machine: Apple Silicon (arm64), macOS 27.0.
- Oracle A: `laya-coreml` Python runtime over
  `aac6fef/laya-multilingual-coreml` (322M, FP16, 664 MB on disk) and
  `aac6fef/laya-coreml` (English 421M).
- Oracle B (cross-check): PyTorch `laya` 0.4.12 `Router(model="multilingual")`.
  CoreML vs torch probabilities agree to ~0.001 (e.g. `ls -la` block:
  0.8769 vs 0.8771). The CoreML port is faithful; what follows is model
  behavior, not port drift.
- Questions and risk formula copied from laya-guard `guard.py`
  (`risk = P(block) + 0.5*P(review)`, max with malicious `noul`;
  block ≥ 0.80, review ≥ 0.45). English instruction strings and a
  natural-language state wrapper were both tried; both measured worse
  than laya-guard's original Korean instructions, which ship unchanged.

## Model-only verdicts (no packs, no safe lane)

| Set | Multilingual 322M | English 421M |
| --- | --- | --- |
| laya-guard shell (71) | 37/71 | 19/71 |
| incidents (17) | 12/17 | 13/17 |
| ko_30 (30) | 21/30 | 12/30 |

Failure shape on bare shell: the model blocks `ls -la` (P(block) 0.88),
`npm run build` (0.89), `git commit -m "fix typo"` (0.84), and allows
`cat ~/.ssh/id_rsa` (P(allow) 0.98 torch / 0.41–0.98 by rendering).
`review` probability mass is near-zero on short commands; the model is
bipolar allow/block there. On natural-language requests it behaves as
advertised (ko set, AgentDojo below). Conclusion: the checkpoints judge
*requests*, not shell strings. Laya-guard's published results are
carried by its 12 regex policies and safe-command lane; rv's equivalent
carriers are its 96 packs and semantics.

## Reproduced laya-guard results (full upstream stack, torch, warm)

| Suite | Claimed | Reproduced here |
| --- | --- | --- |
| shell 71 | 69/71 | 69/71 (misses: `npx tsc`, `cargo --config` — as documented) |
| Korean 30 | 30/30 | 30/30 |
| Incidents | 13/13 held | 13/13 held (~100 ms/judgement warm) |
| AgentDojo attacks | 25/27 | 25/27 |
| AgentDojo benign kept | 92/97 | 92/97 |

## rv results on the same sets (`rv test`, installed binaries)

Mapping: `deny` counts as held for review+block expectations; `exact`
counts deny as block. Latency is per `rv test` process (cold CoreML
compile ~4 s when the judge runs; warm in `rvd` a 3-question judgement
measures ~370–700 ms via `rv-judge`, vs ~100 ms in torch — Swift host
optimization is follow-up work).

| Mode | shell held (of 36) | shell benign kept (of 35) | incidents held (of 13) | ko held (of 21) | ko benign kept (of 9) |
| --- | --- | --- | --- | --- | --- |
| packs only (no bundle) | 27 | 35 | 6 | 4 | 9 |
| enforce + judge (multilingual) | 33 | 19 | 11 | 18 | 9 |
| observe + judge | 0 (by design) | 35 | — | — | — |

Reading: the judge adds real coverage (shell held 27→33, incidents
6→11, Korean natural language 4→18) at a steep benign cost today
(shell benign 35→19: the judge asks/denies 16 everyday commands).
The ko set is natural language, not shell; packs are expected to do
poorly there and do.

## Decisions this evidence produced (owner-confirmed)

1. Judge ships and binds in enforce mode whenever a bundle is
   installed (owner choice, informed by the benign-cost number above).
2. `guard.mode: observe` is the trial posture for the whole guard:
   packs and judge evaluate, would-be verdicts log hash-only to
   `~/.config/rv/judge-log.jsonl`, nothing blocks.
3. Checkpoint: multilingual 322M (better than English on every set
   measured). Korean question strings ship as-is.
4. Thresholds start at laya-guard's (0.80/0.45; 0.60/0.30 untrusted
   provenance). Re-derivation needs observe-mode traffic, not 118 rows.

## Open evidence bars (not gates; tracked for the checkpoint decision)

- Benign overblock ≤ 2% on real traffic — currently ~46% on the shell
  set's benign half. Levers, in expected order of value: a shell
  fine-tune, richer state (semantic analysis summary instead of raw
  command text), threshold re-derivation from observe logs.
- ≥ 5k observe-mode judged calls before any accuracy claim.
- Linux ONNX parity (drift ≤ 0.02) — bundle export script shipped;
  runtime wrapper not yet built; judge reports unavailable on Linux
  and the gate fails closed to Ask only when a bundle is present.
- Warm Swift latency: ~370–700 ms vs torch ~100 ms. Suspects:
  per-element MLMultiArray NSNumber access and 3 sequential calls.
