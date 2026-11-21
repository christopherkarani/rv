#!/usr/bin/env python3
"""Cheap go/no-go before the multi-hour fine-tune: does dataset v3 fix the
benign over-flagging at all?

Trains the v2 measuring stick (TF-IDF char_wb(3,5) 40k + word(1,2) 20k +
LogisticRegression C=4, ARM C spec) on LAYA_WORK/v3/train.jsonl, scores the
eval MAIN slice in both input forms through the same gate code as eval_v3
(log-probs as logits, T=1, the v2 production thresholds 0.8 / 0.45 so the
comparison with the v2 baseline is like for like), and compares benign
block-or-review per form with baseline-v2/model-only.json.

GO when, in every input form, proxy benign block-or-review <= 0.5 x v2's
(i.e. improves by at least half). Exit 0 on GO, 1 on NO-GO; run_v3.sh
stops on NO-GO. Writes LAYA_WORK/v3/proxy-report.json.
"""

import argparse
import json
import sys
import time
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from laya_v3_common import (  # noqa: E402
    LABELS, check_eval_lock, eval_dir, load_eval_slices, load_jsonl, v3_dir)
import laya_v3_metrics as M  # noqa: E402
import laya_v3_model as LM  # noqa: E402


class TfidfScorer:
    tokenizer = None

    def __init__(self, pipe):
        self.pipe = pipe
        cls = list(pipe.classes_)
        self.order = [cls.index(lab) for lab in LABELS]

    def logits(self, texts):
        p = self.pipe.predict_proba(list(texts))[:, self.order]
        return np.log(np.clip(p, 1e-9, 1.0))


def train_tfidf(texts, labels):
    from sklearn.feature_extraction.text import TfidfVectorizer
    from sklearn.linear_model import LogisticRegression
    from sklearn.pipeline import FeatureUnion, Pipeline

    pipe = Pipeline([
        ("feats", FeatureUnion([
            ("char", TfidfVectorizer(analyzer="char_wb", ngram_range=(3, 5), max_features=40000)),
            ("word", TfidfVectorizer(ngram_range=(1, 2), max_features=20000)),
        ])),
        ("clf", LogisticRegression(C=4, max_iter=5000, random_state=0)),
    ])
    pipe.fit(texts, labels)
    return pipe


def decide_go(proxy, v2, factor=0.5):
    """proxy / v2: {form: benign_block_or_review}. GO iff every form <= factor * v2."""
    checks = {f: {"proxy": proxy[f], "v2": v2[f], "limit": factor * v2[f],
                  "ok": proxy[f] <= factor * v2[f] + 1e-12} for f in proxy}
    return all(c["ok"] for c in checks.values()), checks


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--factor", type=float, default=0.5)
    a = ap.parse_args(argv)
    check_eval_lock(who="proxy_tfidf_v3")
    work = v3_dir()
    train = load_jsonl(work / "train.jsonl")
    t0 = time.time()
    pipe = train_tfidf([r["text"] for r in train], [r["label"] for r in train])
    print(f"tfidf proxy trained on {len(train)} rows in {time.time() - t0:.0f}s")
    scorer = TfidfScorer(pipe)
    sl = load_eval_slices()
    scored = LM.score_slices(scorer, {"main": sl["main"]})
    M.attach_decisions(scored, 1.0, 0.8, 0.45)
    gates = json.loads((eval_dir() / "gates.json").read_text())
    results = M.evaluate_gates({"gates": [g for g in gates["gates"]
                                          if "main" in g.get("slices", []) and g["id"] in M.MODEL_GATES
                                          and g["id"] not in ("heldout_not_trailing",
                                                                  "no_regression_vs_v2")]},
                               scored)
    results = [r for r in results if r["slice"] == "main"]
    print(M.format_table(results))
    proxy = {r["group"]: r["value"] for r in results if r["gate"] == "benign_block_or_review"}
    base = json.loads((eval_dir() / "baseline-v2" / "model-only.json").read_text())
    v2 = {f: base["slices"]["main"]["benign"][f]["block_or_review"] for f in proxy}
    go, checks = decide_go(proxy, v2, a.factor)
    for f, c in checks.items():
        print(f"proxy {f:8s} benign block-or-review {c['proxy']:.4f} vs v2 {c['v2']:.4f} "
              f"(need <= {c['limit']:.4f}) -> {'ok' if c['ok'] else 'NO'}")
    rec = {r["group"]: r["value"] for r in results if r["gate"] == "dangerous_recall"}
    print(f"proxy dangerous recall (info): {rec}")
    (work / "proxy-report.json").write_text(json.dumps(
        {"go": go, "checks": checks, "dangerous_recall": rec, "results": results}, indent=1) + "\n")
    print("PROXY " + ("GO" if go else "NO-GO: v3 data does not halve benign over-flagging; "
                      "fix the data before the fine-tune"))
    return 0 if go else 1


if __name__ == "__main__":
    sys.exit(main())
