"""Ticket 1: build labelled {text, label} training data from shell-safety.

Reads the medium split of tomngdev/shell-safety from /tmp/shelldata/,
keeps POSIX rows, maps safe/category -> allow/review/block, dedupes by
exact text (strictest label wins), drops any row matching the held-out
exam sets, and writes sorted JSONL to /tmp/laya-train/.

Run: cd Scripts/laya/training && PYTHONPATH=/tmp/laya-pylibs /tmp/laya-venv/bin/python prepare_data.py
"""

import json
import os
import sys

# Unsafe rows in these shell-safety categories become "review" (human should
# confirm). Chosen from the categories actually present in the medium split.
# Deliberately EXCLUDES complex (attack chains: iptables DNAT to evil.com,
# cat /etc/shadow, curl evil|sh), privilege (sudo_destructive,
# security_disarm, kernel_write), network_curl/network_wget (pipe_to_shell),
# network_scp/network_rsync/network_ssh (exfil), fileops (deletion),
# and docker/cloud/system/agent/network_git/network_gh (destructive/exfil).
REVIEW_CATEGORIES = {"build", "pkgman", "testing"}

STRICTNESS = {"allow": 0, "review": 1, "block": 2}
LABELS = ("allow", "review", "block")
HERE = os.path.dirname(os.path.abspath(__file__))
SHELLDATA = "/tmp/shelldata"
OUTDIR = "/tmp/laya-train"
HELDOUT_FILES = [
    os.path.join(HERE, "..", "testset_shell.jsonl"),
    os.path.join(HERE, "..", "testset_incidents.jsonl"),
    os.path.join(HERE, "..", "testset_ko_30.jsonl"),
]
SPLITS = ("train", "validation")
MAX_LEN = 2000


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


def process_split(split, heldout):
    raw = 0
    posix_rows = []  # (text, label, category)
    cat_counts = {}
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
            if r.get("safe"):
                label = "allow"
            elif r.get("category") in REVIEW_CATEGORIES:
                label = "review"
            else:
                label = "block"
            posix_rows.append((text, label, r.get("category")))
            cat_counts[r.get("category")] = cat_counts.get(r.get("category"), 0) + 1
    # Dedupe by exact text, strictest label wins; count label conflicts.
    best = {}
    seen_labels = {}
    for text, label, _ in posix_rows:
        seen_labels.setdefault(text, set()).add(label)
        if text not in best or STRICTNESS[label] > STRICTNESS[best[text]]:
            best[text] = label
    conflicts = sum(1 for labels in seen_labels.values() if len(labels) > 1)
    # Leakage filter: drop texts present in any held-out set.
    kept = {t: lab for t, lab in best.items() if t not in heldout}
    drops = len(best) - len(kept)
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
        "drops": drops,
        "cat_counts": cat_counts,
    }


def main():
    heldout = load_heldout()
    results = {s: process_split(s, heldout) for s in SPLITS}
    # Cross-split decontamination: validation keeps only texts absent from
    # train. Train wins; label mismatches across splits still drop.
    train_labels = dict(results["train"]["rows"])
    kept_val = []
    cross_drops = 0
    cross_mismatch = 0
    for text, label in results["validation"]["rows"]:
        if text in train_labels:
            cross_drops += 1
            if train_labels[text] != label:
                cross_mismatch += 1
        else:
            kept_val.append((text, label))
    results["validation"]["rows"] = kept_val
    label_counts = {lab: 0 for lab in LABELS}
    for _, lab in kept_val:
        label_counts[lab] += 1
    results["validation"]["label_counts"] = label_counts
    assert not (set(train_labels) & set(dict(kept_val))), "cross-split overlap remains"
    os.makedirs(OUTDIR, exist_ok=True)
    for split in SPLITS:
        with open(os.path.join(OUTDIR, split + ".jsonl"), "w", encoding="utf-8") as f:
            for text, label in results[split]["rows"]:
                f.write(json.dumps({"text": text, "label": label}, ensure_ascii=False) + "\n")
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
    # Leakage check: no output text may appear in any held-out set.
    leaked = set()
    for split in SPLITS:
        for text, _ in results[split]["rows"]:
            if text in heldout:
                leaked.add(text)
    assert not leaked, f"LEAKED: {sorted(leaked)[:5]}"

    for split in SPLITS:
        r = results[split]
        print(f"{split}: raw={r['raw']} posix={r['posix']}")
    for split in SPLITS:
        c = results[split]["label_counts"]
        total = sum(c.values())
        print(f"{split}: allow={c['allow']} review={c['review']} block={c['block']} total={total}")
    tot_conf = sum(results[s]["conflicts"] for s in SPLITS)
    print(f"conflicts resolved by stricter label: {tot_conf} "
          f"(train={results['train']['conflicts']} validation={results['validation']['conflicts']})")
    tot_drops = sum(results[s]["drops"] for s in SPLITS)
    status = "PASS" if not leaked else "FAIL"
    print(f"leakage drops: {tot_drops} "
          f"(train={results['train']['drops']} validation={results['validation']['drops']}); "
          f"leakage check: {status} (checked {checked} output texts against {len(heldout)} held-out texts)")
    print(f"cross-split drops: {cross_drops} (label_mismatch={cross_mismatch})")
    print(f"cross-split check: PASS "
          f"(checked {len(results['train']['rows'])} train texts against "
          f"{len(results['validation']['rows'])} validation texts)")
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
