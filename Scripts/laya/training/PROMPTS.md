# Prompts for the shell-judge fine-tune (run each in a separate chat)

Context: PR #423 (branch `feat/laya-judge`, worktree
`.worktrees/laya-judge`) adds a Laya judge lane to rv. Measured problem:
the stock multilingual checkpoint is weak on bare shell (model-only
37/71 on laya-guard's shell set). Goal of these tickets: train a small
classifier head on labelled shell data and prove whether it beats the
stock judge. A TF-IDF/logistic baseline trained on shell-safety
already got 33/36 held, 32/35 benign kept on that set — that is the bar.

Environment (all tickets): Apple Silicon Mac, python at
`/tmp/laya-venv/bin/python` with `PYTHONPATH=/tmp/laya-pylibs`
(sklearn, polars, torch, laya-coreml present; torch in
`/tmp/laya-torchlibs` if needed). Work inside
`.worktrees/laya-judge/Scripts/laya/training/`. Do not commit; the
orchestrating session verifies and commits.

Held-out (NEVER train on): `Scripts/laya/testset_shell.jsonl`,
`testset_incidents.jsonl`, `testset_ko_30.jsonl`, ShelfRisk-Bench test
split (`kontext-security/ShellRisk-Bench`).

---

## Ticket 1 — Data prep

```
Read docs/plans/laya-judge-decision-record.md in the worktree
.worktrees/laya-judge first.

Build Scripts/laya/training/prepare_data.py and run it:

1. Load tomngdev/shell-safety medium split (already at
   /tmp/shelldata/{train,validation,test}.jsonl, else download from
   https://huggingface.co/datasets/tomngdev/shell-safety/resolve/main/md/).
   POSIX rows only.
2. Emit /tmp/laya-train/{train,validation}.jsonl with rows
   {"text": ..., "label": "allow"|"review"|"block"}.
   Mapping: safe->allow, unsafe->block. Derive "review" from unsafe
   rows whose category is mid-severity (you choose and DOCUMENT the
   category list in the script header: e.g. package installs, plain
   downloads, permission changes — things a human should confirm, not
   instant-block). Keep the rule simple and printed.
3. Dedupe exact texts; drop rows whose text appears in ANY held-out
   file listed in PROMPTS.md.
4. Print: counts per split per label, category distribution, 5 sample
   rows per label. Eyeball label quality and report problems.
5. Write Scripts/laya/training/README.md: run instructions (project
   venv style: cd Scripts/laya/training && /tmp/laya-venv/bin/python
   prepare_data.py), label rules, sources + licenses, quality caveats.

Return the printed summary verbatim + file paths. Do not commit.
```

## Ticket 2 — Train head + eval (needs Ticket 1 output)

```
Read /tmp/laya-train/ (from the data-prep ticket) and
docs/plans/laya-judge-decision-record.md in .worktrees/laya-judge.

Build Scripts/laya/training/train_head.py and run it:

1. Frozen-encoder classifier: load the multilingual Laya encoder
   (convaiinnovations/laya-multilingual; torch libs at
   /tmp/laya-torchlibs). Extract pooled embeddings for train and
   validation texts ONCE, cache them under /tmp/laya-train/.
   Use MPS if available, else CPU. Batch so memory stays sane.
2. Train a small head (logistic regression or 2-layer MLP) on the
   cached embeddings for labels allow/review/block. Also train the
   TF-IDF+logistic baseline (char_wb 3-5 + word 1-2) on raw text for
   comparison.
3. Evaluate BOTH models, printing held/kept/match on:
   - /tmp/laya-train/validation.jsonl
   - held-out Scripts/laya/testset_shell.jsonl (map allow->allow,
     review/block->held)
   - held-out Scripts/laya/testset_incidents.jsonl
   Baselines to beat (stock Laya model-only, shell): held 23/36,
   benign kept 19/35. TF-IDF baseline earlier: held 33/36, kept 32/35.
4. Save the better model + its label thresholds under
   /tmp/laya-train/best/ with a metrics.json containing every number
   printed. Save the TF-IDF model too if it wins.
5. Append results to Scripts/laya/training/README.md.

Return all printed metrics verbatim + which model won where.
Do not commit. Do not train on any held-out file.
```

## Ticket 3 — Review (fresh chat, after 1+2)

```
Review the training work in .worktrees/laya-judge/Scripts/laya/training/
and metrics in /tmp/laya-train/best/metrics.json. You did not write it.

Check: (a) no held-out rows leaked into training (verify prepare_data.py
drops them and confirm with a set intersection run), (b) label mapping
for review is sane on 30 random review rows (print them), (c) metrics
reproduce by re-running the eval portion, (d) the winning model's
worst errors on the shell set, listed with scores.

Return findings as a short list: what is wrong, severity, evidence.
Fix small bugs yourself; report design problems, don't redesign.
Do not commit.
```

## Verification by the orchestrating session (not a ticket)

- Re-run eval from metrics.json artifacts independently.
- Compare vs baselines: stock judge (held 23/36, kept 19/35 shell),
  TF-IDF (33/36, 32/35), full system today (33/36, 34/35).
- Only if the trained model beats stock judge on held-out sets
  without losing benign keeps: plan CoreML/ONNX export + judge swap
  as a follow-up commit on the PR branch.
