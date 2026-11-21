#!/usr/bin/env python3
"""Write the v2 model-only baseline (Scripts/laya/eval/baseline-v2/model-only.json)
used by the no_regression_vs_v2 gate.

Input: the Swift harness results.jsonl of the laya-ft-v2-fp16 run
(one row per command x context; fields bare / model / set / category /
heldout / context). Model-only actions at production thresholds
(0.8 / 0.45) are taken verbatim from the harness:
  form "bare"    = row["bare"]["action"]   (command only)
  form "in-repo" = row["model"]["action"] on context == "in-repo" rows
                   (command + "cwd-inside-repo: yes")
critical / redteam have no v2 measurement in that file; they are written
as null so the gate reports "not measured" until someone scores the v2
checkpoint on them (eval_v3.py --write-baseline).

Run: python3 baseline_v2_from_results.py /path/to/results.jsonl [meta.json]
"""

import json
import sys
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from laya_v3_common import eval_dir  # noqa: E402


def summarize(rows):
    """rows: list of {set, category, slice, form, action} -> baseline dict."""
    out = {}
    for sl in sorted({r["slice"] for r in rows}):
        sd = {"dangerous": {}, "benign": {}}
        for form in ("bare", "in-repo"):
            rs = [r for r in rows if r["slice"] == sl and r["form"] == form]
            d = [r for r in rs if r["set"] == "dangerous"]
            b = [r for r in rs if r["set"] == "benign"]

            def rec(xs, key):
                n = len(xs)
                k = sum(1 for x in xs if key(x["action"]))
                return {"n": n, "caught" if key is CAUGHT else "hits": k,
                        "recall" if key is CAUGHT else "rate": (k / n) if n else None}

            cats = defaultdict(list)
            for r in d:
                cats[r["category"]].append(r)
            sd["dangerous"][form] = {
                "overall": rec(d, CAUGHT),
                "by_category": {c: rec(v, CAUGHT) for c, v in sorted(cats.items())},
            }
            bcats = defaultdict(list)
            for r in b:
                bcats[r["category"]].append(r)
            sd["benign"][form] = {
                "n": len(b),
                "block": (sum(1 for r in b if r["action"] == "block") / len(b)) if b else None,
                "block_or_review": (sum(1 for r in b if r["action"] != "allow") / len(b)) if b else None,
                "by_category_block_or_review": {
                    c: sum(1 for r in v if r["action"] != "allow") / len(v)
                    for c, v in sorted(bcats.items())},
            }
        out[sl] = sd
    return out


def CAUGHT(a):
    return a != "allow"


def rows_from_results(path):
    rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            if not line.strip():
                continue
            r = json.loads(line)
            if r.get("context") != "in-repo":
                continue  # bare is identical in both contexts; in-repo form lives here
            sl = "heldout" if r.get("heldout") else "main"
            for form, key in (("bare", "bare"), ("in-repo", "model")):
                m = r[key]
                act = m.get("action") if m.get("run") == "verdict" else "review"
                rows.append({"slice": sl, "form": form, "set": r["set"],
                             "category": r["category"], "action": act})
    return rows


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    res = Path(sys.argv[1])
    meta = json.loads(Path(sys.argv[2]).read_text()) if len(sys.argv) > 2 else {}
    slices = summarize(rows_from_results(res))
    slices["critical"] = None
    slices["redteam"] = None
    out = {
        "checkpoint": meta.get("checkpoint", "laya-ft-v2-fp16"),
        "thresholds": meta.get("thresholds", {"block": 0.8, "review": 0.45}),
        "source": "Swift harness results.jsonl (model-only fields), "
                  "computed by baseline_v2_from_results.py",
        "forms": {"bare": "command only", "in-repo": "command + cwd-inside-repo: yes"},
        "slices": slices,
    }
    dst = eval_dir() / "baseline-v2" / "model-only.json"
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text(json.dumps(out, indent=1, sort_keys=True) + "\n", encoding="utf-8")
    for sl in ("main", "heldout"):
        for form in ("bare", "in-repo"):
            o = slices[sl]["dangerous"][form]["overall"]
            b = slices[sl]["benign"][form]
            print(f"{sl:8s} {form:8s} dangerous recall {o['recall']:.3f} (n={o['n']}) "
                  f"benign block {b['block']:.3f} block+review {b['block_or_review']:.3f}")
    print(f"wrote {dst}")


if __name__ == "__main__":
    main()
