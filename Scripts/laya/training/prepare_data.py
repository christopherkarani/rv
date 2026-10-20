"""Ticket 1 + Ticket 2b: build labelled {text, label} training data.

Reads the medium split of tomngdev/shell-safety from /tmp/shelldata/,
keeps POSIX rows, maps safe/category/reason -> allow/review/block, dedupes
by exact text (strictest label wins), drops any row matching the held-out
exam sets, merges synthetic augment rows into TRAIN ONLY, and writes
sorted JSONL to /tmp/laya-train/.

Ticket 2b changes (data gap: benign-head/dangerous-suffix smuggling):
1. Normalized-key leakage + cross-split: normalize() = lowercase,
   collapse whitespace, strip one layer of surrounding quotes. Any
   train/val row whose normalized text collides with an exam text is
   dropped; validation drops any row whose normalized text is already
   in (merged) train. Within-split exact dedupe (strictest wins) stays.
2. Review relabel guard: an unsafe row becomes review ONLY if its
   category is in REVIEW_CATEGORIES and neither its reason nor its
   command matches the deny substrings (exfil/credential/destruction
   signals and concrete exfil.sh/evil-host/upload-endpoint markers).
   Everything else unsafe is block.
3. Merges /tmp/laya-train/augment.jsonl (from augment.py -- run that
   FIRST) into train only. On exact text collision base wins.

Run: cd Scripts/laya/training && PYTHONPATH=/tmp/laya-pylibs /tmp/laya-venv/bin/python prepare_data.py
"""

import hashlib
import json
import os
import sys

# Unsafe rows in these shell-safety categories become "review" (human should
# confirm), unless the relabel guard below fires. Chosen from the categories
# actually present in the medium split. Deliberately EXCLUDES complex
# (attack chains), privilege, network_curl/network_wget (pipe_to_shell),
# network_scp/network_rsync/network_ssh (exfil), fileops (deletion), and
# docker/cloud/system/agent/network_git/network_gh.
REVIEW_CATEGORIES = {"build", "pkgman", "testing"}

# Ticket 2b relabel guard. An unsafe row may become review ONLY if its
# reason contains none of REVIEW_DENY_REASON and its command contains none
# of REVIEW_DENY_COMMAND (all matched lowercased, substring). Observed
# matches in the medium split: data_exfil, secret_to_stdout,
# sudo_destructive, tree_wide_discard (reasons); registry repoints to
# *.evil.com, evil-named packages, exfil.sh fixtures/uploads (commands).
# NOTE: the command backstop uses "/upload" (endpoint path), not bare
# "upload", so legitimate `twine upload` registry publishes (the canonical
# review case) are NOT flipped to block.
REVIEW_DENY_REASON = ("exfil", "secret", "credential", "destruct", "discard")
REVIEW_DENY_COMMAND = ("exfil.sh", "evil", "/upload")

STRICTNESS = {"allow": 0, "review": 1, "block": 2}
LABELS = ("allow", "review", "block")
HERE = os.path.dirname(os.path.abspath(__file__))
SHELLDATA = "/tmp/shelldata"
OUTDIR = "/tmp/laya-train"
AUGMENT_PATH = os.path.join(OUTDIR, "augment.jsonl")
HELDOUT_FILES = [
    os.path.join(HERE, "..", "testset_shell.jsonl"),
    os.path.join(HERE, "..", "testset_incidents.jsonl"),
    os.path.join(HERE, "..", "testset_ko_30.jsonl"),
    # Adversarial suffixes are an exam set too; omitting them let
    # near-duplicates of exam rows train in the v1 pipeline.
    os.path.join(HERE, "..", "adversarial-suffixes.jsonl"),
]
SPLITS = ("train", "validation")
MAX_LEN = 2000


def normalize(text):
    """Canonical key: collapse whitespace, strip one layer of surrounding
    quotes, lowercase. (Same semantics as augment.normalize.)"""
    s = " ".join(text.split())
    if len(s) >= 2 and s[0] == s[-1] and s[0] in ("'", '"'):
        s = s[1:-1]
    return s.lower()


def sha_prefix(path, n=8):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()[:n]


def load_heldout():
    held = set()
    for path in HELDOUT_FILES:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                t = (json.loads(line).get("tool_call") or "").strip()
                if t:
                    held.add(t)
    return held


def label_row(safe, category, reason, command):
    if safe:
        return "allow"
    if category in REVIEW_CATEGORIES:
        r = (reason or "").lower()
        c = (command or "").lower()
        if (not any(s in r for s in REVIEW_DENY_REASON)
                and not any(s in c for s in REVIEW_DENY_COMMAND)):
            return "review"
    return "block"


def process_split(split, heldout, exam_norm):
    raw = 0
    posix_rows = []  # (text, label)
    cat_counts = {}
    moved = 0  # unsafe review-category rows the guard flipped to block
    with open(os.path.join(SHELLDATA, split + ".jsonl"), encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            raw += 1
            r = json.loads(line)
            if r.get("shell") != "posix":
                continue
            text = (r.get("command") or "").strip()
            if not text or len(text) > MAX_LEN:
                continue
            label = label_row(r.get("safe"), r.get("category"),
                              r.get("reason"), text)
            if (not r.get("safe") and r.get("category") in REVIEW_CATEGORIES
                    and label == "block"):
                moved += 1
            posix_rows.append((text, label))
            cat_counts[r.get("category")] = cat_counts.get(r.get("category"), 0) + 1
    # Dedupe by exact text, strictest label wins; count label conflicts.
    best = {}
    seen_labels = {}
    for text, label in posix_rows:
        seen_labels.setdefault(text, set()).add(label)
        if text not in best or STRICTNESS[label] > STRICTNESS[best[text]]:
            best[text] = label
    conflicts = sum(1 for labels in seen_labels.values() if len(labels) > 1)
    # Leakage filter on NORMALIZED keys (superset of the old exact filter).
    exact_drops = sum(1 for t in best if t in heldout)
    kept = {t: lab for t, lab in best.items()
            if normalize(t) not in exam_norm}
    norm_only_drops = len(best) - exact_drops - len(kept)
    rows = sorted(kept.items(), key=lambda kv: (kv[1], kv[0]))
    label_counts = {lab: 0 for lab in LABELS}
    for _, lab in rows:
        label_counts[lab] += 1
    return {
        "raw": raw,
        "posix": len(posix_rows),
        "rows": rows,
        "label_counts": label_counts,
        "conflicts": conflicts,
        "exact_drops": exact_drops,
        "norm_only_drops": norm_only_drops,
        "cat_counts": cat_counts,
        "moved": moved,
    }


def load_augment():
    if not os.path.exists(AUGMENT_PATH):
        sys.exit(f"FATAL: {AUGMENT_PATH} missing -- run augment.py first")
    rows = []
    with open(AUGMENT_PATH, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            obj = json.loads(line)
            assert set(obj.keys()) == {"text", "label"}, obj
            assert obj["label"] in STRICTNESS, obj
            text = obj["text"].strip()
            assert text and len(text) <= MAX_LEN, obj
            rows.append((text, obj["label"]))
    texts = [t for t, _ in rows]
    assert len(set(texts)) == len(texts), "augment has duplicate texts"
    return rows


def main():
    heldout = load_heldout()
    exam_norm = {normalize(t) for t in heldout}
    results = {s: process_split(s, heldout, exam_norm) for s in SPLITS}
    # Merge augment into TRAIN ONLY. Exact collision: base wins.
    aug_rows = load_augment()
    train_map = dict(results["train"]["rows"])
    aug_merged = 0
    aug_base_collision = 0
    for text, label in aug_rows:
        if text in train_map:
            aug_base_collision += 1
            continue
        train_map[text] = label
        aug_merged += 1
    # Leakage filter on merged train (augment was pre-filtered; expect 0).
    aug_leak = sorted(t for t, _ in aug_rows
                      if t in train_map and normalize(t) in exam_norm)
    assert not aug_leak, f"AUGMENT LEAKED INTO EXAMS: {aug_leak[:5]}"
    # Within-train normalized twins with conflicting labels (transparency).
    norm_labels = {}
    for t, lab in train_map.items():
        norm_labels.setdefault(normalize(t), set()).add(lab)
    twin_conflicts = sum(1 for s in norm_labels.values() if len(s) > 1)
    results["train"]["rows"] = sorted(train_map.items(),
                                      key=lambda kv: (kv[1], kv[0]))
    label_counts = {lab: 0 for lab in LABELS}
    for _, lab in results["train"]["rows"]:
        label_counts[lab] += 1
    results["train"]["label_counts"] = label_counts
    # Cross-split decontamination on NORMALIZED keys: validation keeps only
    # rows whose normalized text is absent from (merged) train. Train wins;
    # exact-twin label mismatches still counted.
    train_labels = dict(results["train"]["rows"])
    train_norms = {normalize(t) for t in train_labels}
    kept_val = []
    cross_exact = 0
    cross_norm_only = 0
    cross_mismatch = 0
    for text, label in results["validation"]["rows"]:
        if text in train_labels:
            cross_exact += 1
            if train_labels[text] != label:
                cross_mismatch += 1
        elif normalize(text) in train_norms:
            cross_norm_only += 1
        else:
            kept_val.append((text, label))
    results["validation"]["rows"] = kept_val
    label_counts = {lab: 0 for lab in LABELS}
    for _, lab in kept_val:
        label_counts[lab] += 1
    results["validation"]["label_counts"] = label_counts
    assert not (train_norms & {normalize(t) for t, _ in kept_val}), \
        "cross-split normalized overlap remains"
    os.makedirs(OUTDIR, exist_ok=True)
    for split in SPLITS:
        with open(os.path.join(OUTDIR, split + ".jsonl"), "w",
                  encoding="utf-8") as f:
            for text, label in results[split]["rows"]:
                f.write(json.dumps({"text": text, "label": label},
                                   ensure_ascii=False) + "\n")
    # Validate outputs: keys exactly {text, label}, label valid, sorted.
    checked = 0
    for split in SPLITS:
        prev = None
        with open(os.path.join(OUTDIR, split + ".jsonl"), encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                obj = json.loads(line)
                assert set(obj.keys()) == {"text", "label"}, obj
                assert obj["label"] in STRICTNESS, obj
                key = (obj["label"], obj["text"])
                assert prev is None or prev <= key, "output not sorted"
                prev = key
                checked += 1
    # Leakage checks: exact AND normalized intersections must be empty.
    leaked_exact = set()
    leaked_norm = set()
    for split in SPLITS:
        for text, _ in results[split]["rows"]:
            if text in heldout:
                leaked_exact.add(text)
            if normalize(text) in exam_norm:
                leaked_norm.add(text)
    assert not leaked_exact, f"LEAKED (exact): {sorted(leaked_exact)[:5]}"
    assert not leaked_norm, f"LEAKED (normalized): {sorted(leaked_norm)[:5]}"
    # H2: zero augmented rows in validation (construction + assert).
    aug_texts = {t for t, _ in aug_rows}
    val_texts = {t for t, _ in results["validation"]["rows"]}
    aug_in_val = aug_texts & val_texts
    assert not aug_in_val, f"AUGMENT IN VALIDATION: {sorted(aug_in_val)[:5]}"

    for split in SPLITS:
        r = results[split]
        print(f"{split}: raw={r['raw']} posix={r['posix']}")
    for split in SPLITS:
        c = results[split]["label_counts"]
        total = sum(c.values())
        print(f"{split}: allow={c['allow']} review={c['review']} "
              f"block={c['block']} total={total}")
    tot_conf = sum(results[s]["conflicts"] for s in SPLITS)
    print(f"conflicts resolved by stricter label: {tot_conf} "
          f"(train={results['train']['conflicts']} "
          f"validation={results['validation']['conflicts']})")
    tot_exact = sum(results[s]["exact_drops"] for s in SPLITS)
    tot_norm = sum(results[s]["norm_only_drops"] for s in SPLITS)
    print(f"leakage drops: exact={tot_exact} "
          f"(train={results['train']['exact_drops']} "
          f"validation={results['validation']['exact_drops']}) "
          f"normalized-only={tot_norm} "
          f"(train={results['train']['norm_only_drops']} "
          f"validation={results['validation']['norm_only_drops']}); "
          f"leakage check: PASS (checked {checked} output texts against "
          f"{len(heldout)} held-out texts, {len(exam_norm)} normalized)")
    print(f"cross-split drops: exact={cross_exact} "
          f"(label_mismatch={cross_mismatch}) normalized-only={cross_norm_only}")
    print(f"cross-split check: PASS "
          f"(checked {len(results['train']['rows'])} train texts against "
          f"{len(results['validation']['rows'])} validation texts, "
          f"normalized keys)")
    print(f"review relabel guard: REVIEW_DENY_REASON={list(REVIEW_DENY_REASON)} "
          f"REVIEW_DENY_COMMAND={list(REVIEW_DENY_COMMAND)}")
    tot_moved = sum(results[s]["moved"] for s in SPLITS)
    print(f"rows moved review->block by guard (raw, pre-dedupe): {tot_moved} "
          f"(train={results['train']['moved']} "
          f"validation={results['validation']['moved']})")
    print(f"augment: file={AUGMENT_PATH} rows={len(aug_rows)} "
          f"merged_into_train={aug_merged} "
          f"base_exact_collision={aug_base_collision} "
          f"exam_norm_leak=0 validation_rows_with_augment_text=0")
    print(f"within-train normalized twins with conflicting labels: "
          f"{twin_conflicts}")
    for split in SPLITS:
        print(f"{split}.jsonl sha256 prefix: "
              f"{sha_prefix(os.path.join(OUTDIR, split + '.jsonl'))}")
    print("categories (train, before relabel):")
    for cat in sorted(results["train"]["cat_counts"]):
        print(f"  {cat}: {results['train']['cat_counts'][cat]}")
    by_label = {lab: [] for lab in LABELS}
    for text, label in results["train"]["rows"]:
        by_label[label].append(text)
    for lab in LABELS:
        print(f"samples [{lab}] (train, truncated to 100 chars):")
        for i, text in enumerate(by_label[lab][:5], 1):
            print(f"  {i}. {text[:100]}")


if __name__ == "__main__":
    main()
