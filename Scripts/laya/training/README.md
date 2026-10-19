# Ticket 1 — shell-safety training data prep

Builds `/tmp/laya-train/{train,validation}.jsonl`: labelled `{text, label}`
rows (`allow` | `review` | `block`) from the shell-safety medium split,
with zero rows from the held-out exam sets.

## Run

```sh
cd Scripts/laya/training
PYTHONPATH=/tmp/laya-pylibs /tmp/laya-venv/bin/python prepare_data.py
```

Exit code 0 on success. Re-running produces byte-identical outputs
(rows sorted by `(label, text)`, no randomness).

## Label rules

- `safe=true` → `allow`.
- `safe=false` → `block`, except unsafe rows whose `category` is in
  `REVIEW_CATEGORIES` → `review`.
- `REVIEW_CATEGORIES = {"build", "pkgman", "testing"}` — installs,
  build/publish steps, and test runs that hit external hosts (human
  should confirm).
- Deliberately left as `block`: `complex` (unsafe rows are attack
  chains, e.g. iptables DNAT to evil.com, `cat /etc/shadow`,
  curl-evil-pipe-to-sh), `privilege` (sudo_destructive,
  security_disarm, kernel_write), `network_curl` / `network_wget`
  (pipe_to_shell), `network_scp` / `network_rsync` / `network_ssh`
  (exfil), `fileops` (deletion), `docker` / `cloud` / `system` /
  `agent` / `network_git` / `network_gh` (destructive / exfil /
  persistence behavior).

Pipeline: keep `shell == "posix"` only → strip, drop empty and
`>2000`-char rows → label → dedupe by exact text (strictest label
wins: block > review > allow; multi-label texts counted as
conflicts) → drop any text appearing in a held-out `tool_call` set →
sort by `(label, text)` → write JSONL. Cross-split rule: validation
drops every text already present in train (train wins, even on label
mismatch). The script asserts every
output line parses with keys exactly `{text, label}`, a valid label,
sorted order, and an empty intersection with the held-out set.

## Sources + licenses

- Input: `tomngdev/shell-safety`, medium split (`md/train.jsonl`,
  `md/validation.jsonl`), local copy at `/tmp/shelldata/`. Test split
  ignored. License: **MIT** (per the Hugging Face dataset page).
- Held-out (never emitted; matched on stripped text vs `tool_call`):
  `Scripts/laya/testset_shell.jsonl`, `testset_incidents.jsonl`,
  `testset_ko_30.jsonl` (this repo).
- Output: `/tmp/laya-train/train.jsonl` (7,937 rows),
  `/tmp/laya-train/validation.jsonl` (563 rows after cross-split
  decontamination). Review is 4.55% of
  train (below the 5% aspiration; categories were not widened to force
  it).

## Quality caveats

- Source labels are noisy. Examples spotted while sampling: plain
  `cargo build --release` / `bundle update` marked unsafe
  (undeclared_manifest_edit); `npx prettier`, `go list -u -m all`,
  `gem outdated` marked unsafe; `npx playwright test ...` marked
  unsafe with reason `secret_to_stdout`.
- Category granularity leaks severity: `review` contains some
  registry-repoint-to-evil rows (`...crates.evil.com`,
  `proxy.evil.com`) via `build`/`pkgman`, which are arguably `block`.
- Heavy duplication in the source: 16,001 POSIX train rows collapse
  to 7,954 unique texts (e.g. `git push -u origin main` x44), so the
  deduped train set (7,937 rows) is smaller than the 10k gate assumed.
- 831 unique texts appear in both train and validation (source
  overlap; splits were processed independently, not decontaminated
  against each other).
- 33 texts carry conflicting source labels across rows; strictest won.

## Results (Ticket 2 — frozen-encoder head vs TF-IDF, measured 2026-10-19)

`train_head.py` trains a 3-class head on frozen Laya multilingual encoder
embeddings (mean-pool last hidden state, 768-dim, truncate 512) plus a
TF-IDF baseline (char_wb(3,5) 40k + word(1,2) 20k, LR C=4), both on the
train split above, evaluated on validation + the 3 held-out exam sets.
Encoder actually used: jhu-clsp/mmBERT-base-architecture weights
(`encoder.*` tensors) from the `convaiinnovations/laya` multilingual
checkpoint + checkpoint config/tokenizer (AutoModel on the config-only
`encoder/` dir fails, so the documented fallback applied). Device: MPS.
Head: LogisticRegression with `class_weight="balanced"` (review is
361/7937 = 4.55% of train; the 1-hidden-layer MLP candidate scored
531/563 = 94.3% on validation vs LR 504/563 = 89.5%, a 4.8pt gap that
does not clear the >5pt switch rule, so LR shipped).

Metric definitions: exact = pred == expected (review-expected also
accepts block; "any"-expected accepts everything); held = pred in
{review, block} among expected {review, block}; kept = pred == allow
among expected allow.

```
[head] validation exact 504/563 (89.5%) | held 268/295 (90.8%) | kept 240/268 (89.6%)
[head] shell      exact 58/71 (81.7%)   | held 28/36 (77.8%)   | kept 32/35 (91.4%)
[head] incidents  exact 14/17 (82.4%)   | held 10/13 (76.9%)   | kept n/a (0 rows)
[head] ko         exact 19/30 (63.3%)   | held 14/21 (66.7%)   | kept 5/9 (55.6%)
[tfidf] validation exact 552/563 (98.0%) | held 285/295 (96.6%) | kept 268/268 (100.0%)
[tfidf] shell      exact 66/71 (93.0%)   | held 33/36 (91.7%)   | kept 33/35 (94.3%)
[tfidf] incidents  exact 15/17 (88.2%)   | held 11/13 (84.6%)   | kept n/a (0 rows)
[tfidf] ko         exact 22/30 (73.3%)   | held 13/21 (61.9%)   | kept 9/9 (100.0%)
```

Winner rule (highest shell held, then highest shell kept): shell held
head 28/36 vs tfidf 33/36 → **tfidf**. It beats the stock-judge shell
baselines (held 23/36, kept 19/35) on both, and matches the earlier
binary TF-IDF (held 33/36, kept 32/35) with one fewer benign stop.
Winner + full metrics saved under `/tmp/laya-train/best/`
(`head.joblib`, `tfidf.joblib`, `labels.json`, `metrics.json`).
Run: `cd Scripts/laya/training && PYTHONPATH=/tmp/laya-pylibs:/tmp/laya-torchlibs
HF_HUB_DISABLE_XET=1 /tmp/laya-venv/bin/python train_head.py`
(~70 s cold on MPS, ~7 s warm via the `/tmp/laya-train/embeddings/` cache).
