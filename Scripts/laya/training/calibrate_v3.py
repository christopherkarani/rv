#!/usr/bin/env python3
"""Calibrate the v3 judge: one temperature + block/review thresholds.

1. Temperature T: single scalar minimizing NLL of softmax(logits / T) on the
   dev split (LAYA_WORK/v3/dev.jsonl, never trained on, never in eval).
2. Thresholds on the eval MAIN slice (heldout=false), both input forms
   (bare, cwd-inside-repo: yes) pooled, using the runtime rule
   (risk = P(block) + 0.5 P(review); block if risk >= tb; review if argmax is
   review or risk >= tr):
     block_threshold  = lowest t with benign block <= gates benign_block.max
     review_threshold = lowest t with benign block+review <=
                        gates benign_block_or_review.max
   (targets are read from gates.json: 0.5% and 3% as approved.)
3. Reports recall at those thresholds per form, and the heldout slice
   (report only; never used to fit anything).

Writes LAYA_WORK/v3/calibration.json
  {temperature, block_threshold, review_threshold, targets, metrics, ...}

Run: python3 calibrate_v3.py [--backend torch|onnx] [--model PATH]
"""

import argparse
import json
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from laya_v3_common import (  # noqa: E402
    FORMS, LAB2ID, check_eval_lock, eval_dir, load_eval_slices, load_jsonl, v3_dir)
import laya_v3_metrics as M  # noqa: E402


def form_rates(rows, tb, tr, temperature):
    out = {}
    for f in FORMS:
        acts = {"benign": [], "dangerous": []}
        for r in rows:
            if r["set"] in acts and f in r["logits"]:
                p = M.softmax(np.asarray(r["logits"][f])[None], temperature)[0]
                acts[r["set"]].append(M.decide(p, tb, tr, r["truncated"].get(f, False)))
        b, d = acts["benign"], acts["dangerous"]
        out[f] = {
            "n_benign": len(b), "n_dangerous": len(d),
            "benign_block": float(np.mean([a == "block" for a in b])) if b else None,
            "benign_block_or_review": float(np.mean([a != "allow" for a in b])) if b else None,
            "dangerous_block_recall": float(np.mean([a == "block" for a in d])) if d else None,
            "dangerous_recall": float(np.mean([a != "allow" for a in d])) if d else None,
        }
    return out


def calibrate(dev_logits, dev_labels, main_rows, held_rows, targets):
    """Pure core (testable without a model)."""
    t = M.fit_temperature(dev_logits, dev_labels)
    nll1 = M.nll_of(dev_logits, dev_labels, 1.0)
    nllt = M.nll_of(dev_logits, dev_labels, t)
    benign = [M.softmax(np.asarray(r["logits"][f])[None], t)[0]
              for r in main_rows if r["set"] == "benign" for f in r["logits"]]
    th = M.derive_thresholds(benign, targets["max_benign_block"],
                             targets["max_benign_block_or_review"])
    tb, tr = th["block_threshold"], th["review_threshold"]
    return {
        "temperature": t,
        "block_threshold": tb,
        "review_threshold": tr,
        "targets": targets,
        "metrics": {
            "dev": {"n": int(len(dev_labels)), "nll_T1": nll1, "nll_T": nllt},
            "main_pooled_fit": th,
            "main": form_rates(main_rows, tb, tr, t),
            "heldout_report_only": form_rates(held_rows, tb, tr, t),
        },
    }


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--backend", choices=("torch", "onnx"), default="torch")
    ap.add_argument("--model", default=None, help="default LAYA_WORK/v3/ft/best_model.pt")
    ap.add_argument("--tokenizer-dir", default=None)
    a = ap.parse_args(argv)
    check_eval_lock(who="calibrate_v3")
    import laya_v3_model as LM

    work = v3_dir()
    model = a.model or str(work / "ft" / "best_model.pt")
    gates = json.loads((eval_dir() / "gates.json").read_text())
    targets = M.gate_targets(gates)
    scorer = LM.make_scorer(a.backend, model, a.tokenizer_dir)
    dev = load_jsonl(work / "dev.jsonl")
    dev_logits = scorer.logits([r["text"] for r in dev])
    dev_labels = [LAB2ID[r["label"]] for r in dev]
    sl = load_eval_slices()
    scored = LM.score_slices(scorer, {"main": sl["main"], "heldout": sl["heldout"]})
    cal = calibrate(dev_logits, dev_labels, scored["main"], scored["heldout"], targets)
    cal["model"] = model
    cal["backend"] = a.backend
    out = work / "calibration.json"
    out.write_text(json.dumps(cal, indent=1) + "\n")
    m = cal["metrics"]
    print(f"temperature {cal['temperature']:.4f} (dev NLL {m['dev']['nll_T1']:.4f} -> "
          f"{m['dev']['nll_T']:.4f}, n={m['dev']['n']})")
    print(f"block_threshold {cal['block_threshold']:.6f}  review_threshold "
          f"{cal['review_threshold']:.6f}  targets {targets}")
    for note in m["main_pooled_fit"]["notes"]:
        print(f"NOTE: {note}")
    for sl_name in ("main", "heldout_report_only"):
        for f, v in m[sl_name].items():
            print(f"{sl_name:20s} {f:8s} benign block {v['benign_block']:.4f} "
                  f"block+review {v['benign_block_or_review']:.4f} | dangerous block "
                  f"{v['dangerous_block_recall']:.4f} caught {v['dangerous_recall']:.4f}")
    print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
