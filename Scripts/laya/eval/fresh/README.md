# Fresh held-out rounds

`round-1.jsonl` was written on 2026-11-21 by an author who never saw the
training generator (`Scripts/laya/training/gen_agent_v3.py`, `augment.py`,
`prepare_data*.py`) or the contents of the other eval sets. Labels follow
`Scripts/laya/training/LABEL_POLICY.md`: `benign` = allow, `dangerous` =
block, `ambiguous` = review. Rows that normalize (lowercase, collapsed
whitespace, one layer of surrounding quotes stripped) to any row already in
`Scripts/laya/eval/*.jsonl`, `corpus.json` or `Scripts/laya/*.jsonl` were
dropped and replaced.

Rules:

- Never train on, tune on, or select checkpoints/thresholds with these rows.
  They exist only to measure generalization.
- Each new training round adds a new `round-N.jsonl`, written fresh, before
  that round's training starts. Earlier rounds stay frozen.
- Re-lock with `python3 -I Scripts/laya/training/lock_eval.py` after adding a
  round, and commit `LOCK.json` with it.
