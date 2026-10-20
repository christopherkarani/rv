"""Ticket 4a: build training dataset v2 WITH session context.

Merges tomngdev/shell-safety-v1.1 (POSIX rows, serialized session context)
with the v1 rows (/tmp/laya-train/train.jsonl + validation.jsonl) and the
synthetic augment rows (/tmp/laya-train/augment.jsonl, command-only), and
writes context-aware {text, command, label} JSONL to /tmp/laya-train/v2/.

Context serialization (EXACT - training and future runtime must match):
  Input text = command, then only the context lines that are known, each on
  its own line, in this order:
    <command>
    cwd-inside-repo: yes|no            (v1.1: yes if gitRemote non-empty)
    agent-touched: <comma-joined agentTouchedFiles, max 8, sorted>
    git: untracked <n>, modified <n>, staged <n>
  The agent-touched line is omitted when the list is empty; the git line is
  omitted when gitStatus is absent. Rows without context (v1/augment) are
  the bare command. No other fields, no JSON, deterministic.

Label map: allow->allow, ask->review, deny->block.

Dedup (normalized key = lowercase, collapse whitespace, strip one layer of
surrounding quotes, on the COMMAND part only):
  - within split: same norm + same label -> keep up to 2 text variants in
    train (distinct context), 1 in validation (sorted-text-first); same
    norm + conflicting labels -> keep the strictest single row (block >
    review > allow) and count it as a label disagreement.
  - cross-split: train wins (validation drops any norm present in train).
  - exam filter: any norm colliding with a held-out exam set or the v1.1
    test split drops the train/val row.

target_touched (analysis only, in stats.json, never in the text): true when
a whitespace token of the command that contains "/" (after stripping
quotes/parens/trailing shell punctuation, flag= prefixes, and URLs) equals
or falls under (entry + "/") an agentTouchedFiles entry, comparing with
leading "./" and trailing "/" stripped ("~/" prefix also tried bare).

Run: cd Scripts/laya/training && PYTHONPATH=/tmp/laya-pylibs /tmp/laya-venv/bin/python prepare_data_v2.py
"""

import hashlib
import json
import os

STRICTNESS = {"allow": 0, "review": 1, "block": 2}
LABELS = ("allow", "review", "block")
LABEL_MAP = {"allow": "allow", "ask": "review", "deny": "block"}
HERE = os.path.dirname(os.path.abspath(__file__))
V11_FILES = {
    "train": "/tmp/ss11-train.jsonl",
    "validation": "/tmp/ss11-validation.jsonl",
    "test": "/tmp/ss11-test.jsonl",
}
V1_TRAIN = "/tmp/laya-train/train.jsonl"
V1_VALIDATION = "/tmp/laya-train/validation.jsonl"
AUGMENT = "/tmp/laya-train/augment.jsonl"
OUTDIR = "/tmp/laya-train/v2"
HELDOUT_FILES = [
    ("testset_shell", os.path.join(HERE, "..", "testset_shell.jsonl")),
    ("testset_incidents", os.path.join(HERE, "..", "testset_incidents.jsonl")),
    ("testset_ko_30", os.path.join(HERE, "..", "testset_ko_30.jsonl")),
    ("adversarial", os.path.join(HERE, "..", "adversarial-suffixes.jsonl")),
]
SOURCE_ORDER = ("v11", "v1", "augment")


def normalize(text):
    """Canonical key: collapse whitespace, strip one layer of surrounding
    quotes, lowercase. (Same semantics as prepare_data.normalize.)"""
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


def serialize(command, sc):
    """Serialize command + session context (None -> command only)."""
    lines = [command]
    if sc is not None:
        if "gitRemote" in sc:
            lines.append(
                "cwd-inside-repo: " + ("yes" if sc.get("gitRemote") else "no"))
        touched = sorted(sc.get("agentTouchedFiles") or [])
        if touched:
            lines.append("agent-touched: " + ",".join(touched[:8]))
        gs = sc.get("gitStatus")
        if gs is not None:
            u = len(gs.get("untracked") or [])
            m = len(gs.get("modified") or [])
            s = len(gs.get("staged") or [])
            lines.append(f"git: untracked {u}, modified {m}, staged {s}")
    return "\n".join(lines)


def _norm_p(p):
    while p.startswith("./"):
        p = p[2:]
    return p.rstrip("/")


def target_touched(command, touched):
    """True when a path-like command token falls under a touched entry."""
    entries = [_norm_p(t) for t in (touched or []) if _norm_p(t)]
    if not entries:
        return False
    for tok in command.split():
        t = tok.strip("'\"`()").rstrip(";,|&)").lstrip("(")
        if "=" in t and "/" in t.split("=", 1)[1]:
            t = t.split("=", 1)[1].strip("'\"`")
        if "/" not in t or "://" in t or t.startswith("-"):
            continue
        cands = {_norm_p(t)}
        if t.startswith("~/"):
            cands.add(_norm_p(t[2:]))
        for c in cands:
            if not c:
                continue
            for e in entries:
                if c == e or c.startswith(e + "/"):
                    return True
    return False


def load_exams():
    """{name: set of normalized tool_call} + combined set (fixed order)."""
    per, combined = {}, set()
    for name, path in HELDOUT_FILES:
        keys = set()
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                t = (json.loads(line).get("tool_call") or "").strip()
                if not t or t == "__meta__":
                    continue
                keys.add(normalize(t))
        per[name] = keys
        combined |= keys
    return per, combined


def load_v11_test_norms():
    keys = set()
    with open(V11_FILES["test"], encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            c = (json.loads(line).get("command") or "").strip()
            if c:
                keys.add(normalize(c))
    return keys


def load_v11(split):
    """Load v1.1 rows for a split -> (entries, in_rows, non_posix, bad)."""
    entries = []
    in_rows, non_posix, bad = 0, 0, 0
    with open(V11_FILES[split], encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            in_rows += 1
            r = json.loads(line)
            if r.get("shell") != "posix":
                non_posix += 1
                continue
            command = (r.get("command") or "").strip()
            label = LABEL_MAP.get(r.get("label"))
            if not command or label is None:
                bad += 1
                continue
            sc = r.get("session_context")
            text = serialize(command, sc)
            entries.append({
                "command": command,
                "text": text,
                "label": label,
                "source": "v11",
                "tt": target_touched(
                    command, (sc or {}).get("agentTouchedFiles")),
                "has_ctx": text != command,
            })
    return entries, in_rows, non_posix, bad


def load_plain(path, source):
    """Load a v1/augment {text, label} file -> (entries, in_rows, bad)."""
    entries = []
    in_rows, bad = 0, 0
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            in_rows += 1
            o = json.loads(line)
            assert set(o.keys()) == {"text", "label"}, o
            command = (o["text"] or "").strip()
            label = o["label"]
            if not command or label not in STRICTNESS:
                bad += 1
                continue
            entries.append({
                "command": command,
                "text": command,
                "label": label,
                "source": source,
                "tt": False,
                "has_ctx": False,
            })
    return entries, in_rows, bad


def dedupe(entries, max_variants):
    """Group by normalized command; return (rows, info).

    rows: kept dicts {command, text, label, source, tt, has_ctx, norm}.
    info: groups, multi_variant_groups, kept_extra_variants,
      extra_variants_dropped, exact_dupes_collapsed, disagreements (list of
      {norm, command, labels, variants: [{label, ctx}]} sorted by norm).
    """
    groups = {}
    for e in entries:
        groups.setdefault(normalize(e["command"]), []).append(e)
    rows = []
    multi_var = 0
    kept_extra = 0
    extra_dropped = 0
    dupes_collapsed = 0
    disagreements = []
    for norm in sorted(groups):
        es = groups[norm]
        labels = sorted({e["label"] for e in es},
                        key=lambda l: STRICTNESS[l])
        texts = sorted({e["text"] for e in es})
        dupes_collapsed += len(es) - len(texts)
        if len(texts) > 1:
            multi_var += 1
        if len(labels) > 1:
            extra_dropped += len(texts) - 1
            kept_label = labels[-1]
            kept_text = min(e["text"] for e in es
                            if e["label"] == kept_label)
            keep = [e for e in es
                    if e["text"] == kept_text and e["label"] == kept_label]
            src = min(SOURCE_ORDER.index(e["source"]) for e in keep)
            first = [e for e in keep
                     if SOURCE_ORDER.index(e["source"]) == src][0]
            rows.append({"command": first["command"], "text": kept_text,
                         "label": kept_label, "source": first["source"],
                         "tt": first["tt"], "has_ctx": first["has_ctx"],
                         "norm": norm})
            variants = []
            for lab in labels:
                rep = [e for e in es if e["label"] == lab]
                rep.sort(key=lambda e: (SOURCE_ORDER.index(e["source"]),
                                        e["text"]))
                ctx = rep[0]["text"].split("\n")[1:] or ["<no context>"]
                variants.append({"label": lab, "ctx": ctx})
            disagreements.append({"norm": norm,
                                  "command": first["command"],
                                  "labels": labels, "variants": variants})
        else:
            kept = texts[:max_variants]
            kept_extra += len(kept) - 1
            extra_dropped += len(texts) - len(kept)
            for t in kept:
                cands = [e for e in es if e["text"] == t]
                cands.sort(key=lambda e: SOURCE_ORDER.index(e["source"]))
                first = cands[0]
                rows.append({"command": first["command"], "text": t,
                             "label": labels[0], "source": first["source"],
                             "tt": first["tt"], "has_ctx": first["has_ctx"],
                             "norm": norm})
    return rows, {"groups": len(groups), "multi_variant_groups": multi_var,
                  "kept_extra_variants": kept_extra,
                  "extra_variants_dropped": extra_dropped,
                  "exact_dupes_collapsed": dupes_collapsed,
                  "disagreements": disagreements}


def main():
    exam_per, exam_combined = load_exams()
    v11_test = load_v11_test_norms()
    exam_all = exam_combined | v11_test
    exam_order = [n for n, _ in HELDOUT_FILES] + ["v11_test"]
    exam_sets = dict(exam_per)
    exam_sets["v11_test"] = v11_test

    # Load sources; v1.1 splits stay separate, v1/augment join by split.
    v11_tr, v11_tr_in, v11_tr_np, v11_tr_bad = load_v11("train")
    v11_va, v11_va_in, v11_va_np, v11_va_bad = load_v11("validation")
    v1_tr, v1_tr_in, v1_tr_bad = load_plain(V1_TRAIN, "v1")
    v1_va, v1_va_in, v1_va_bad = load_plain(V1_VALIDATION, "v1")
    aug, aug_in, aug_bad = load_plain(AUGMENT, "augment")

    train_entries = v11_tr + v1_tr + aug
    val_entries = v11_va + v1_va

    train_rows, train_info = dedupe(train_entries, 2)
    val_rows, val_info = dedupe(val_entries, 1)

    # Exam filter (first-match attribution in fixed order).
    exam_drops = {"train": 0, "validation": 0}
    exam_by = {n: 0 for n in exam_order}
    kept_tr = []
    for r in train_rows:
        hit = next((n for n in exam_order if r["norm"] in exam_sets[n]),
                   None)
        if hit is None:
            kept_tr.append(r)
        else:
            exam_drops["train"] += 1
            exam_by[hit] += 1
    kept_va = []
    for r in val_rows:
        hit = next((n for n in exam_order if r["norm"] in exam_sets[n]),
                   None)
        if hit is None:
            kept_va.append(r)
        else:
            exam_drops["validation"] += 1
            exam_by[hit] += 1

    # Cross-split: train wins (label mismatch counted for transparency).
    train_norms = {r["norm"]: r["label"] for r in kept_tr}
    final_va, cross_drops, cross_mismatch = [], 0, 0
    for r in kept_va:
        if r["norm"] in train_norms:
            cross_drops += 1
            if train_norms[r["norm"]] != r["label"]:
                cross_mismatch += 1
        else:
            final_va.append(r)
    final_tr = kept_tr
    assert not ({r["norm"] for r in final_va} & set(train_norms)), \
        "cross-split normalized overlap remains"

    # Leakage verification on final outputs, per exam set.
    leak = {}
    for split, rows in (("train", final_tr), ("validation", final_va)):
        leak[split] = {}
        for n in exam_order:
            hit = sorted({r["norm"] for r in rows} & exam_sets[n])
            leak[split][n] = len(hit)
            assert not hit, f"LEAKED into {n} ({split}): {hit[:5]}"

    final_tr.sort(key=lambda r: (r["label"], r["text"]))
    final_va.sort(key=lambda r: (r["label"], r["text"]))
    os.makedirs(OUTDIR, exist_ok=True)
    for split, rows in (("train", final_tr), ("validation", final_va)):
        with open(os.path.join(OUTDIR, split + ".jsonl"), "w",
                  encoding="utf-8") as f:
            for r in rows:
                f.write(json.dumps({"text": r["text"],
                                    "command": r["command"],
                                    "label": r["label"]},
                                   ensure_ascii=False) + "\n")

    # Validate outputs: keys, labels, text starts with command, sorted.
    checked = 0
    for split in ("train", "validation"):
        prev = None
        with open(os.path.join(OUTDIR, split + ".jsonl"),
                  encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                o = json.loads(line)
                assert set(o.keys()) == {"text", "command", "label"}, o
                assert o["label"] in STRICTNESS, o
                assert o["text"].startswith(o["command"]), o
                key = (o["label"], o["text"])
                assert prev is None or prev <= key, "output not sorted"
                prev = key
                checked += 1
    assert checked == len(final_tr) + len(final_va)

    def label_counts(rows):
        c = {lab: 0 for lab in LABELS}
        for r in rows:
            c[r["label"]] += 1
        return c

    def ctx_stats(rows):
        n = len(rows)
        with_ctx = sum(1 for r in rows if r["has_ctx"])
        tt_all = [r["tt"] for r in rows]
        by_lab = {}
        for lab in LABELS:
            sub = [r["tt"] for r in rows if r["label"] == lab]
            by_lab[lab] = {"n": len(sub),
                           "rate": (sum(sub) / len(sub)) if sub else 0.0}
        return {"total": n, "labels": label_counts(rows),
                "unique_normalized_commands": len({r["norm"] for r in rows}),
                "context_present": with_ctx,
                "context_pct": (100.0 * with_ctx / n) if n else 0.0,
                "target_touched_n": sum(tt_all),
                "target_touched_rate": (sum(tt_all) / n) if n else 0.0,
                "target_touched_by_label": by_lab}

    tr_stats, va_stats = ctx_stats(final_tr), ctx_stats(final_va)
    all_rows = final_tr + final_va
    tt_overall_by_lab = {}
    for lab in LABELS:
        sub = [r["tt"] for r in all_rows if r["label"] == lab]
        tt_overall_by_lab[lab] = {"n": len(sub),
                                  "rate": (sum(sub) / len(sub)) if sub else 0.0}

    def in_labels(entries):
        c = {lab: 0 for lab in LABELS}
        for e in entries:
            c[e["label"]] += 1
        return c

    out_attr = {s: {"train": 0, "validation": 0} for s in SOURCE_ORDER}
    for r in final_tr:
        out_attr[r["source"]]["train"] += 1
    for r in final_va:
        out_attr[r["source"]]["validation"] += 1

    stats = {
        "sources": {
            "v11_train": {"in_rows": v11_tr_in, "posix_kept": len(v11_tr),
                          "non_posix_dropped": v11_tr_np,
                          "empty_or_bad_dropped": v11_tr_bad,
                          "in_labels": in_labels(v11_tr),
                          "out_rows": out_attr["v11"]["train"]},
            "v11_validation": {"in_rows": v11_va_in,
                               "posix_kept": len(v11_va),
                               "non_posix_dropped": v11_va_np,
                               "empty_or_bad_dropped": v11_va_bad,
                               "in_labels": in_labels(v11_va),
                               "out_rows": out_attr["v11"]["validation"]},
            "v1_train": {"in_rows": v1_tr_in,
                         "empty_or_bad_dropped": v1_tr_bad,
                         "in_labels": in_labels(v1_tr),
                         "out_rows": out_attr["v1"]["train"]},
            "v1_validation": {"in_rows": v1_va_in,
                              "empty_or_bad_dropped": v1_va_bad,
                              "in_labels": in_labels(v1_va),
                              "out_rows": out_attr["v1"]["validation"]},
            "augment": {"in_rows": aug_in,
                        "empty_or_bad_dropped": aug_bad,
                        "in_labels": in_labels(aug),
                        "out_rows": out_attr["augment"]["train"]},
        },
        "splits": {"train": tr_stats, "validation": va_stats,
                   "target_touched_by_label_overall": tt_overall_by_lab},
        "dedupe": {"train": {k: v for k, v in train_info.items()
                             if k != "disagreements"},
                   "validation": {k: v for k, v in val_info.items()
                                  if k != "disagreements"},
                   "train_disagreements": len(train_info["disagreements"]),
                   "validation_disagreements": len(val_info["disagreements"])},
        "drops": {"exam": {"train": exam_drops["train"],
                           "validation": exam_drops["validation"],
                           "by_exam_first_match": exam_by},
                  "cross_split_validation": cross_drops,
                  "cross_split_label_mismatch": cross_mismatch},
        "leakage": leak,
        "disagreement_samples": train_info["disagreements"][:10],
        "sha256": {
            "train": sha_prefix(os.path.join(OUTDIR, "train.jsonl"), 64),
            "validation": sha_prefix(
                os.path.join(OUTDIR, "validation.jsonl"), 64),
        },
    }
    with open(os.path.join(OUTDIR, "stats.json"), "w",
              encoding="utf-8") as f:
        json.dump(stats, f, ensure_ascii=False, indent=2)
        f.write("\n")

    # ---- prints, in ticket order ----
    print("per-source in/out rows:")
    for name, src, split in (("v11_train", "v11", "train"),
                             ("v11_validation", "v11", "validation"),
                             ("v1_train", "v1", "train"),
                             ("v1_validation", "v1", "validation"),
                             ("augment", "augment", "train")):
        s = stats["sources"][name]
        print(f"  {name}: in={s['in_rows']} out={s['out_rows']} "
              f"(split={split})")
    print(f"posix filter (v1.1): train kept={len(v11_tr)} "
          f"dropped_non_posix={v11_tr_np}; validation kept={len(v11_va)} "
          f"dropped_non_posix={v11_va_np}")
    for split, st in (("train", tr_stats), ("validation", va_stats)):
        c = st["labels"]
        print(f"{split}: allow={c['allow']} review={c['review']} "
              f"block={c['block']} total={st['total']} "
              f"unique_normalized_commands={st['unique_normalized_commands']}")
    tot = tr_stats["total"] + va_stats["total"]
    tot_ctx = tr_stats["context_present"] + va_stats["context_present"]
    print(f"context: train={tr_stats['context_pct']:.1f}% "
          f"({tr_stats['context_present']}/{tr_stats['total']}) "
          f"validation={va_stats['context_pct']:.1f}% "
          f"({va_stats['context_present']}/{va_stats['total']}) "
          f"overall={100.0 * tot_ctx / tot:.1f}% ({tot_ctx}/{tot})")
    print(f"label disagreements (same normalized command, stricter kept): "
          f"train={len(train_info['disagreements'])} "
          f"validation={len(val_info['disagreements'])}")
    print("disagreement samples (train, up to 10):")
    for i, d in enumerate(train_info["disagreements"][:10], 1):
        cmd = d["command"]
        if len(cmd) > 120:
            cmd = cmd[:117] + "..."
        print(f"  {i}. cmd={cmd!r} labels={d['labels']}")
        for v in d["variants"]:
            print(f"     [{v['label']}] {' | '.join(v['ctx'])}")
    print(f"dedupe: train groups={train_info['groups']} "
          f"multi_variant={train_info['multi_variant_groups']} "
          f"kept_extra={train_info['kept_extra_variants']} "
          f"extra_dropped={train_info['extra_variants_dropped']} "
          f"exact_dupes_collapsed={train_info['exact_dupes_collapsed']}; "
          f"validation groups={val_info['groups']} "
          f"multi_variant={val_info['multi_variant_groups']} "
          f"exact_dupes_collapsed={val_info['exact_dupes_collapsed']}")
    print(f"exam drops: train={exam_drops['train']} "
          f"validation={exam_drops['validation']} "
          f"by_exam={exam_by}")
    print(f"cross-split: validation_dropped={cross_drops} "
          f"label_mismatch={cross_mismatch}")
    flat = [f"{s}/{n}={leak[s][n]}" for s in ("train", "validation")
            for n in exam_order]
    print(f"leakage check: PASS ({' '.join(flat)}; "
          f"checked {checked} rows against "
          f"{sum(len(v) for v in exam_sets.values())} exam keys)")
    for split in ("train", "validation"):
        print(f"{split}.jsonl sha256 prefix: "
              f"{sha_prefix(os.path.join(OUTDIR, split + '.jsonl'))}")
    print("target_touched rate by label (overall): " +
          " ".join(f"{lab}={tt_overall_by_lab[lab]['rate']:.3f}"
                   f"({sum(1 for r in all_rows if r['label'] == lab and r['tt'])}"
                   f"/{tt_overall_by_lab[lab]['n']})" for lab in LABELS))
    # J6 spot check: rm/rmdir + allow + agent-touched context, from train.
    import os as _os

    def is_rm(command):
        toks = command.split()
        return bool(toks) and _os.path.basename(toks[0]) in ("rm", "rmdir")

    rm_allow = [r for r in final_tr
                if r["label"] == "allow" and is_rm(r["command"])
                and "agent-touched:" in r["text"]]
    print(f"J6 spot check (rm/rmdir allow + agent-touched, train): "
          f"found {len(rm_allow)} (require >= 5)")
    for r in rm_allow[:5]:
        print("  ---")
        for ln in r["text"].split("\n"):
            print(f"  {ln[:160]}")


if __name__ == "__main__":
    main()
