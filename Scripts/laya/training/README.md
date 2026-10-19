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
