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

(copy also at /tmp/ticket1-prompt.txt on the orchestrator machine; expanded gates version below)

```
You are starting from a FRESH context with no memory of prior sessions. Everything you need is in this prompt. Do not ask clarifying questions; if something below is truly impossible, stop and report exactly why.

## Where you are
- Repo: rv (Swift macOS/Linux CLI guarding AI coding agents).
- Work in worktree: /Users/chriskarani/CodingProjects/rv/.worktrees/laya-judge (branch feat/laya-judge). cd there first.
- Read first (2 files, in order): docs/plans/laya-judge-decision-record.md, then Scripts/laya/training/PROMPTS.md (you are Ticket 1; ignore Tickets 2-3).
- Python: /tmp/laya-venv/bin/python with PYTHONPATH=/tmp/laya-pylibs. Do NOT install anything into system python or a new venv.

## Goal (one sentence)
Build a labelled training dataset {text, label in allow|review|block} from the shell-safety dataset, saved as JSONL, with zero rows from our held-out exam sets.

## Inputs
- Preferred: /tmp/shelldata/train.jsonl (20001 rows), validation.jsonl (2003), test.jsonl (ignore test). If missing, download medium split from https://huggingface.co/datasets/tomngdev/shell-safety/resolve/main/md/{train,validation}.jsonl
- Row shape: {"command": str, "session_context": {...}, "safe": bool, "category": str, "shell": "posix"|..., "reason": str}
- Held-out files (NEVER emit any row whose normalized command text appears in these): Scripts/laya/testset_shell.jsonl, Scripts/laya/testset_incidents.jsonl, Scripts/laya/testset_ko_30.jsonl (field is "tool_call" there).

## Deliverables (write files, do NOT commit, do NOT push)
1. `Scripts/laya/training/prepare_data.py` — runnable as: cd Scripts/laya/training && PYTHONPATH=/tmp/laya-pylibs /tmp/laya-venv/bin/python prepare_data.py
2. `/tmp/laya-train/train.jsonl` and `/tmp/laya-train/validation.jsonl` — one JSON object per line: {"text": <command>, "label": "allow"|"review"|"block"}
3. `Scripts/laya/training/README.md` — run instructions, label rules, sources + licenses, quality caveats.

## Processing rules (exact)
1. Keep only rows with shell == "posix".
2. text = command stripped of leading/trailing whitespace. Drop empty. Drop rows longer than 2000 chars.
3. Label mapping: safe=true -> "allow". safe=false -> "block", EXCEPT the review rule in step 4.
4. Review rule: unsafe rows whose `category` is in a mid-severity set become "review". You choose the set from the categories actually present. It must only cover "human should confirm" behavior (e.g. installs, plain downloads, permission changes, chained commands) and must NEVER include categories about deletion, exfiltration, credential access, or code execution from the network. Print the chosen set in the script header as a Python constant named REVIEW_CATEGORIES, and list it in your final report.
5. Dedupe by exact text (after strip). If the same text appears with different labels, keep the STRICTER label (block > review > allow) and count it as a conflict.
6. Leakage filter: drop any row whose stripped text appears in any held-out file's tool_call set. Count drops.
7. Deterministic: sort output rows by (label, text). No randomness.

## Acceptance gates (ALL must pass; report each explicitly)
G1. Script runs end-to-end with exit code 0 using the exact run command above.
G2. Both output files exist; every line parses as JSON with keys exactly {"text","label"} and label in {allow, review, block} (validate in the script, assert it).
G3. Train rows >= 10,000 and validation rows >= 1,000 (POSIX-filtered medium split should land near 16k/1.6k; if yours differ by >20%, explain why).
G4. Each of the 3 labels is >= 5% of train rows. If review < 5%, say so and what fraction it is — do NOT widen REVIEW_CATEGORIES to force the number.
G5. Leakage check inside the script: assert intersection between output texts and held-out tool_call set is EMPTY; print the count checked.
G6. Re-running the script produces byte-identical outputs (run twice, sha256sum both files, show they match).
G7. git status in the worktree shows ONLY your three new files as changes (prepare_data.py, README.md modified/created under Scripts/laya/training/). No commits made (git log -1 unchanged = "docs(training): fine-tune tickets as standalone prompts").

## What to print during the run (script stdout, in this order)
- input counts per split (raw, after POSIX filter)
- counts per split per label
- conflicts resolved by stricter label: N
- leakage drops: N; leakage check: PASS/FAIL
- categories table: category -> count (train, before relabel)
- 5 sample rows per label (text truncated to 100 chars)

## Your final reply (EXACTLY this shape, nothing else)
VERDICT: DONE or BLOCKED (+ one-line reason if BLOCKED)
FILES: <3 paths>
GATES: G1 PASS/FAIL ... G7 PASS/FAIL (one per line or semicolon-separated)
SUMMARY:
<paste the script's full stdout>
REVIEW_CATEGORIES: <the list>
CONCERNS: <label-quality problems you saw in samples, or "none">

Do not commit. Do not start Ticket 2. Do not modify any other files.
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
