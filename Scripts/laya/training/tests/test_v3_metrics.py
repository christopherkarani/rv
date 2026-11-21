"""Gate / calibration math on synthetic scored rows (numpy only)."""

import json
import math
import random
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import laya_v3_metrics as M  # noqa: E402
from laya_v3_common import LAYA_ROOT  # noqa: E402

GATES = json.loads((LAYA_ROOT / "eval" / "gates.json").read_text())


def test_decide_matches_swift_rule():
    assert M.decide([0.1, 0.1, 0.8], 0.8, 0.45) == "block"
    assert M.decide([0.2, 0.7, 0.1], 0.8, 0.45) == "review"      # argmax review
    assert M.decide([0.5, 0.2, 0.3], 0.8, 0.45) == "allow"       # risk 0.4
    assert M.decide([0.4, 0.2, 0.4], 0.8, 0.45) == "review"      # risk 0.5
    assert M.decide([0.9, 0.05, 0.05], 0.8, 0.45, truncated=True) == "review"


def test_threshold_helpers():
    neg = [i / 1000 for i in range(1000)]
    t = M.lowest_threshold_max_rate(neg, 0.005)
    assert M.rate_at(neg, t) <= 0.005 and M.rate_at(neg, t - 0.0011) > 0.005
    pos = [0.2, 0.5, 0.9, 0.95, 0.99]
    t = M.highest_threshold_min_recall(pos, 0.8)
    assert t == 0.5 and M.rate_at(pos, t) >= 0.8
    rate, _ = M.selection_metric([0.1, 0.3, 0.6], pos, 0.8)
    assert math.isclose(rate, 1 / 3)


def test_fit_temperature_recovers_scale():
    rng = np.random.default_rng(0)
    n = 4000
    y = rng.integers(0, 3, n)
    true = rng.normal(0, 1, (n, 3))
    true[np.arange(n), y] += 2.0
    # sample labels from the true distribution, then present overconfident logits (x3)
    p = M.softmax(true)
    ys = np.array([rng.choice(3, p=row) for row in p])
    t = M.fit_temperature(true * 3.0, ys)
    assert 2.4 < t < 3.6, t
    assert M.nll_of(true * 3, ys, t) < M.nll_of(true * 3, ys, 1.0)


def test_derive_thresholds_hits_targets():
    rng = random.Random(3)
    probs = []
    for _ in range(2000):
        b = rng.random() ** 4
        r = (1 - b) * rng.random() * 0.4
        probs.append([1 - b - r, r, b])
    th = M.derive_thresholds(probs, 0.005, 0.03)
    assert th["benign_block"] <= 0.005 and th["benign_block_or_review"] <= 0.03
    assert th["review_threshold"] <= th["block_threshold"]
    # lowest: any lower block threshold breaks the target
    acts = [M.decide(p, th["block_threshold"] - 1e-3, th["review_threshold"]) for p in probs]
    assert np.mean([x == "block" for x in acts]) > 0.005


def test_derive_thresholds_infeasible_review():
    probs = [[0.2, 0.7, 0.1]] * 10 + [[0.9, 0.05, 0.05]] * 90   # 10% argmax review
    th = M.derive_thresholds(probs, 0.005, 0.03)
    assert th["notes"] and th["review_threshold"] == th["block_threshold"]


def test_ece():
    assert M.ece([0.0, 1.0], [0, 1]) == 0.0
    assert math.isclose(M.ece([0.9] * 10, [0] * 10), 0.9)


def _row(i, s, cat, bare, inrepo, slice_="main", expect=None):
    return {"id": f"{slice_}{i}", "set": s, "category": cat, "command": f"c{i}", "slice": slice_,
            "expect": expect, "form": None,
            "logits": {"bare": bare, "in-repo": inrepo}, "truncated": {"bare": False, "in-repo": False}}


def _scored(good=True):
    """main/heldout/critical/redteam/smoke with clearly separated logits."""
    B = [6.0, 0.0, -6.0]   # allow
    D = [-6.0, 0.0, 6.0]   # block
    sc = {}
    for sl in ("main", "heldout", "fresh/round-1"):
        rows = [_row(i, "benign", f"cat{i % 3}", B, B, sl) for i in range(300)]
        rows += [_row(300 + i, "dangerous", f"d{i % 2}", D, D, sl) for i in range(100)]
        sc[sl] = rows
    sc["critical"] = [_row(i, "dangerous", "destruction", D, D, "critical") for i in range(60)]
    sc["redteam"] = [_row(i, "dangerous", "quoting", D, D, "redteam") for i in range(80)] + \
        [_row(80 + i, "benign", "scary", B, B, "redteam") for i in range(30)]
    sc["smoke"] = [_row(0, "benign", "x", B, B, "smoke", expect="allow"),
                   _row(1, "dangerous", "x", D, D, "smoke", expect="block")]
    if not good:
        # in-repo shortcut: dangerous allowed inside a repo in main
        for r in sc["main"][300:320]:
            r["logits"]["in-repo"] = B
        sc["critical"][0]["logits"]["bare"] = B
    return M.attach_decisions(sc, 1.0, 0.8, 0.45)


BASE = {"slices": {s: {"dangerous": {f: {"by_category": {"d0": {"recall": 0.9}, "d1": {"recall": 0.9}}}
                                     for f in M.FORMS}} for s in ("main", "heldout")}}
BASE["slices"]["critical"] = None
EXTERNAL = [
    {"gate": "door_benign_judge_deny", "slice": "main", "group": "in-repo", "value": 0.01},
    {"gate": "door_benign_judge_deny", "slice": "heldout", "group": "in-repo", "value": 0.01},
    {"gate": "door_system_miss", "slice": "main", "group": "in-repo", "count": 0},
    {"gate": "door_system_miss", "slice": "heldout", "group": "in-repo", "count": 0},
    {"gate": "door_system_miss", "slice": "critical", "group": "in-repo", "count": 0},
    {"gate": "coreml_drift", "slice": "golden", "group": "coreml", "value": 0.01, "count": 0},
    {"gate": "latency_p95_ms", "slice": "main", "group": "pooled", "value": 120.0},
    {"gate": "bundle_size_mb", "slice": "-", "group": "mlpackage", "value": 614.0},
]


def test_all_gates_pass_on_separated_scores_except_missing_baselines():
    res = M.evaluate_gates(GATES, _scored(True), baseline=BASE, external=EXTERNAL)
    fails = [r for r in res if not r["passed"]]
    # only the v2 baselines that do not exist (critical, redteam) are not measured
    assert {(r["gate"], r["slice"]) for r in fails} == {
        ("no_regression_vs_v2", "critical"), ("no_regression_vs_v2", "redteam")}, fails
    ids = {r["gate"] for r in res}
    assert ids == {g["id"] for g in GATES["gates"]}


def test_gates_catch_failures_and_not_measured():
    res = M.evaluate_gates(GATES, _scored(False), baseline=BASE, external=[])
    failed = {(r["gate"], r["slice"], r["group"]) for r in res if not r["passed"]}
    assert ("dangerous_recall", "main", "in-repo") in failed
    assert ("context_flip", "main", "rows") in failed
    assert ("critical_zero_miss", "critical", "bare") in failed
    assert ("heldout_not_trailing", "heldout", "in-repo: dangerous_recall") not in failed
    for gid in ("door_benign_judge_deny", "door_system_miss", "coreml_drift",
                "latency_p95_ms", "bundle_size_mb"):
        assert any(g == gid for g, _, _ in failed), gid
    notes = [r["note"] for r in res if r["gate"] == "latency_p95_ms"]
    assert all("not measured" in n for n in notes)


def test_missing_fresh_slice_is_not_measured():
    sc = _scored(True)
    del sc["fresh/round-1"]
    res = M.evaluate_gates(GATES, sc, baseline=BASE, external=EXTERNAL)
    fresh = [r for r in res if r["slice"] == "fresh"]
    assert fresh and all(not r["passed"] for r in fresh)


def test_smoke_and_table():
    sc = _scored(True)
    sc["smoke"][0]["expect"] = "block"
    res = M.evaluate_gates({"gates": [g for g in GATES["gates"] if g["id"] == "smoke_exact"]}, sc)
    assert res[0]["count"] == 2 and not res[0]["passed"]
    txt = M.format_table(res)
    assert "smoke_exact" in txt and "FAIL" in txt


def test_calibrate_core():
    import calibrate_v3 as C
    rng = np.random.default_rng(1)
    dev_y = rng.integers(0, 3, 600)
    dev_l = rng.normal(0, 1, (600, 3))
    dev_l[np.arange(600), dev_y] += 4
    flip = rng.random(600) < 0.3          # 30% label noise -> logits x2 are overconfident
    dev_y = np.where(flip, rng.integers(0, 3, 600), dev_y)
    sc = _scored(True)
    cal = C.calibrate(dev_l * 2, dev_y, sc["main"], sc["heldout"], M.gate_targets(GATES))
    assert cal["temperature"] > 1.0
    m = cal["metrics"]["main"]
    for f in M.FORMS:
        assert m[f]["benign_block"] <= 0.005 and m[f]["benign_block_or_review"] <= 0.03
        assert m[f]["dangerous_recall"] == 1.0
    assert set(cal) >= {"temperature", "block_threshold", "review_threshold", "metrics"}


def test_proxy_go_rule():
    import proxy_tfidf_v3 as P
    go, _ = P.decide_go({"bare": 0.15, "in-repo": 0.2}, {"bare": 0.321, "in-repo": 0.418})
    assert go
    go, checks = P.decide_go({"bare": 0.17, "in-repo": 0.2}, {"bare": 0.321, "in-repo": 0.418})
    assert not go and not checks["bare"]["ok"]


def test_score_slices_with_fake_scorer():
    import laya_v3_model as LM

    class Fake:
        tokenizer = None

        def logits(self, texts):
            return np.array([[0.0, 0.0, 5.0] if "cwd-inside-repo: yes" in t else [5.0, 0.0, 0.0]
                             for t in texts])

    rows = [{"id": "a", "set": "benign", "category": "x", "command": "ls", "form": None},
            {"id": "b", "set": "benign", "category": "x", "command": "pwd", "form": "bare"}]
    sc = LM.score_slices(Fake(), {"s": rows})
    assert set(sc["s"][0]["logits"]) == {"bare", "in-repo"}
    assert set(sc["s"][1]["logits"]) == {"bare"}
    M.attach_decisions(sc, 1.0, 0.8, 0.45)
    assert sc["s"][0]["pred"]["bare"]["action"] == "allow"
    assert sc["s"][0]["pred"]["in-repo"]["action"] == "block"
