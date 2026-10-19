#!/usr/bin/env python3
"""Ticket 2 -- 3-class shell-safety head on frozen Laya multilingual embeddings.

End-to-end pipeline:
  1. Verify sha256 prefixes of /tmp/laya-train/{train,validation}.jsonl.
  2. Encode train + validation + 3 held-out exam sets with the frozen Laya
     multilingual encoder (mean-pool last hidden state over non-pad tokens,
     truncate 512, batch 32). Cache per-split .npy + index.json under
     /tmp/laya-train/embeddings/; reused on re-run (torch never touched).
  3. Train a LogisticRegression head (class_weight=balanced) on train
     embeddings; also try a 1-hidden-layer MLP and keep it only if it beats
     LR on validation exact by >5 points.
  4. Train a TF-IDF baseline (char_wb(3,5) 40k + word(1,2) 20k, LR C=4).
  5. Evaluate BOTH on validation + shell/incidents/ko exam sets
     (exact-3class / held / kept), pick the winner by (shell held, then
     shell kept), save under /tmp/laya-train/best/.

Exam sets are NEVER trained on; a contamination assert (G3) enforces it.

Metric definitions (identical for validation and exam sets):
  exact: pred == expected, except review-expected rows also count a block
         prediction as correct; "any"-expected rows accept every prediction.
  held:  pred in {review, block} among expected {review, block}.
  kept:  pred == allow among expected allow ("any" rows excluded).
"""

import hashlib
import json
import os
import sys
import time
from pathlib import Path

os.environ.setdefault("HF_HUB_OFFLINE", "1")

import numpy as np

HERE = Path(__file__).resolve().parent
TRAIN_PATH = Path("/tmp/laya-train/train.jsonl")
VAL_PATH = Path("/tmp/laya-train/validation.jsonl")
EXAM_PATHS = {
    "shell": (HERE / "../testset_shell.jsonl").resolve(),
    "incidents": (HERE / "../testset_incidents.jsonl").resolve(),
    "ko": (HERE / "../testset_ko_30.jsonl").resolve(),
}
EMB_DIR = Path("/tmp/laya-train/embeddings")
BEST_DIR = Path("/tmp/laya-train/best")
EXPECTED_HASH = {"train": "7818ced5", "validation": "e28f6514"}
BATCH = 32
MAX_LEN = 512
HF_CACHE_CKPT = (
    Path.home()
    / ".cache/huggingface/hub/models--convaiinnovations--laya/snapshots"
)


def sha_prefix(path, n=8):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()[:n]


def load_rows(path):
    rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def texts_sha(texts):
    return hashlib.sha256(("\n".join(texts)).encode("utf-8")).hexdigest()[:16]


def find_ckpt_dir():
    cands = sorted(HF_CACHE_CKPT.glob("*/multilingual"))
    for c in cands:
        if (c / "model.safetensors").exists():
            return c
    raise FileNotFoundError(
        f"no laya multilingual checkpoint under {HF_CACHE_CKPT}"
    )


def load_encoder(ckpt):
    """Return (model, tokenizer, device, encoder_desc).

    Primary attempt: transformers AutoModel on the checkpoint's encoder/
    files. That dir ships config-only, so the working path loads the
    encoder.* tensors out of model.safetensors into a ModernBertModel built
    from the checkpoint config, with the checkpoint tokenizer.
    """
    import torch
    from transformers import AutoConfig, AutoModel, AutoTokenizer, ModernBertModel

    tok_dir = ckpt / "tokenizer"
    enc_cfg_dir = ckpt / "encoder"
    tokenizer = AutoTokenizer.from_pretrained(str(tok_dir))
    try:
        model = AutoModel.from_pretrained(str(enc_cfg_dir))
        desc = f"AutoModel on checkpoint encoder/ dir ({enc_cfg_dir})"
    except Exception as e:
        print(
            f"AutoModel on encoder/ dir failed ({type(e).__name__}: {e}); "
            "loading jhu-clsp/mmBERT-base-architecture weights from the "
            "checkpoint dir instead."
        )
        from safetensors import safe_open

        cfg = AutoConfig.from_pretrained(str(enc_cfg_dir))
        model = ModernBertModel(cfg)
        state = {}
        with safe_open(str(ckpt / "model.safetensors"), framework="pt") as f:
            for k in f.keys():
                if k.startswith("encoder."):
                    state[k[len("encoder.") :]] = f.get_slice(k)[:]
        missing, unexpected = model.load_state_dict(state, strict=False)
        if missing:
            raise RuntimeError(f"missing encoder keys after load: {missing[:8]}")
        if unexpected:
            print(f"note: {len(unexpected)} unexpected keys ignored")
        desc = (
            "jhu-clsp/mmBERT-base-architecture weights (encoder.* tensors) from "
            f"{ckpt}/model.safetensors + config from encoder/config.json + "
            "checkpoint tokenizer"
        )
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    model.eval()
    try:
        model.to(device)
    except Exception:
        device = "cpu"
        model.to(device)
    return model, tokenizer, device, desc


def encode_texts(texts, model, tokenizer, device):
    import torch

    embs = []
    with torch.inference_mode():
        for i in range(0, len(texts), BATCH):
            batch = texts[i : i + BATCH]
            enc = tokenizer(
                batch,
                padding=True,
                truncation=True,
                max_length=MAX_LEN,
                return_tensors="pt",
            )
            input_ids = enc["input_ids"].to(device)
            mask = enc["attention_mask"].to(device)
            try:
                hs = model(
                    input_ids=input_ids, attention_mask=mask
                ).last_hidden_state
            except Exception:
                if device != "cpu":
                    print("device error, falling back to cpu")
                    model.to("cpu")
                    device = "cpu"
                    hs = model(
                        input_ids=input_ids.to("cpu"),
                        attention_mask=mask.to("cpu"),
                    ).last_hidden_state
                else:
                    raise
            w = mask.unsqueeze(-1).to(hs.dtype)
            pooled = (hs * w).sum(1) / w.sum(1).clamp_min(1e-9)
            embs.append(pooled.float().cpu().numpy())
    return np.concatenate(embs, axis=0), device


def get_embeddings(splits):
    """Encode every split once; cache .npy + index.json + meta.json.

    splits: {name: {"texts": [...], "source": Path}}. Returns
    ({name: ndarray}, index, cache_hit, encoder_info).
    """
    EMB_DIR.mkdir(parents=True, exist_ok=True)
    meta_path = EMB_DIR / "meta.json"
    index_path = EMB_DIR / "index.json"
    want = {
        n: {
            "n": len(v["texts"]),
            "sha": texts_sha(v["texts"]),
            "source": str(v["source"]),
        }
        for n, v in splits.items()
    }
    meta = json.loads(meta_path.read_text()) if meta_path.exists() else {}
    if (
        meta.get("splits") == want
        and index_path.exists()
        and all((EMB_DIR / f"{n}.npy").exists() for n in want)
    ):
        print("embedding cache HIT for all splits; reusing .npy (torch idle)")
        out = {n: np.load(EMB_DIR / f"{n}.npy") for n in want}
        for n, e in out.items():
            assert e.shape[0] == want[n]["n"], (n, e.shape)
        index = json.loads(index_path.read_text())
        info = f"{meta.get('encoder', '?')} | device={meta.get('device', '?')} (cached)"
        return out, index, True, info
    ckpt = find_ckpt_dir()
    print(f"checkpoint: {ckpt}")
    model, tokenizer, device, desc = load_encoder(ckpt)
    print(f"encoder: {desc}")
    print(f"device: {device}")
    out, index = {}, {}
    t0 = time.time()
    for n, v in splits.items():
        e, device = encode_texts(v["texts"], model, tokenizer, device)
        assert e.shape[0] == len(v["texts"]), (n, e.shape)
        np.save(EMB_DIR / f"{n}.npy", e)
        out[n] = e
        for i in range(len(v["texts"])):
            index[f"{n}:{i}"] = str(v["source"])
        print(f"encoded {n}: {e.shape} ({time.time() - t0:.1f}s elapsed)")
    meta = {"splits": want, "encoder": desc, "device": device}
    meta_path.write_text(json.dumps(meta, indent=1))
    index_path.write_text(json.dumps(index))
    return out, index, False, f"{desc} | device={device}"


def split_metrics(y_true, y_pred):
    total = len(y_true)
    exact_ok = sum(
        1
        for t, p in zip(y_true, y_pred)
        if t == "any" or p == t or (t == "review" and p == "block")
    )
    held_ok = sum(
        1
        for t, p in zip(y_true, y_pred)
        if t in ("review", "block") and p in ("review", "block")
    )
    held_den = sum(1 for t in y_true if t in ("review", "block"))
    kept_ok = sum(
        1 for t, p in zip(y_true, y_pred) if t == "allow" and p == "allow"
    )
    kept_den = sum(1 for t in y_true if t == "allow")
    return {
        "exact": [exact_ok, total],
        "held": [held_ok, held_den],
        "kept": [kept_ok, kept_den],
    }


def fmt(pair):
    ok, den = pair
    if den == 0:
        return "n/a (0 rows)"
    return f"{ok}/{den} ({100 * ok / den:.1f}%)"


def main():
    t_start = time.time()
    # G1: verify audited inputs before anything else.
    h_train = sha_prefix(TRAIN_PATH)
    h_val = sha_prefix(VAL_PATH)
    print(f"train.jsonl sha256 prefix: {h_train} (expect {EXPECTED_HASH['train']})")
    print(f"validation.jsonl sha256 prefix: {h_val} (expect {EXPECTED_HASH['validation']})")
    assert h_train == EXPECTED_HASH["train"], "train hash mismatch -- STOP"
    assert h_val == EXPECTED_HASH["validation"], "validation hash mismatch -- STOP"
    print("G1 input hashes: PASS")

    train_rows = load_rows(TRAIN_PATH)
    val_rows = load_rows(VAL_PATH)
    exam_rows = {n: load_rows(p) for n, p in EXAM_PATHS.items()}
    print(
        f"train rows: {len(train_rows)}, validation rows: {len(val_rows)}, "
        + ", ".join(f"{n} {len(r)}" for n, r in exam_rows.items())
    )

    tr_texts = [r["text"].strip() for r in train_rows]
    tr_y = [r["label"] for r in train_rows]
    va_texts = [r["text"].strip() for r in val_rows]
    va_y = [r["label"] for r in val_rows]
    ex_texts = {
        n: [r["tool_call"].strip() for r in rows] for n, rows in exam_rows.items()
    }
    ex_y = {n: [r["expected"] for r in rows] for n, rows in exam_rows.items()}

    splits = {
        "train": {"texts": tr_texts, "source": TRAIN_PATH},
        "validation": {"texts": va_texts, "source": VAL_PATH},
    }
    for n in exam_rows:
        splits[n] = {"texts": ex_texts[n], "source": EXAM_PATHS[n]}

    embs, index, cache_hit, enc_info = get_embeddings(splits)

    # G3: no exam-set text behind a train/validation index row (literal:
    # resolve every index row with source train/validation back to text).
    exam_set = set().union(*[set(v) for v in ex_texts.values()])
    leak = sorted(
        {
            splits[row.split(":")[0]]["texts"][int(row.split(":")[1])]
            for row, src in index.items()
            if Path(src).name in ("train.jsonl", "validation.jsonl")
        }
        & exam_set
    )
    assert not leak, f"CONTAMINATION: {leak[:5]}"
    assert not ((set(tr_texts) | set(va_texts)) & exam_set), "CONTAMINATION (sets)"
    print(
        f"G3 contamination check: PASS "
        f"(exam texts in train/val index rows: 0; index rows: {len(index)})"
    )

    # Step 2: head on frozen embeddings. review is 361/7937 (4.5%), so the
    # LR head uses class_weight="balanced" (review upweighted ~7.3x); the
    # MLP candidate sees standardized embeddings.
    from sklearn.linear_model import LogisticRegression
    from sklearn.neural_network import MLPClassifier
    from sklearn.pipeline import Pipeline
    from sklearn.preprocessing import StandardScaler

    Xtr, Xva = embs["train"], embs["validation"]
    n_review = sum(1 for y in tr_y if y == "review")
    print(
        f"imbalance: review is {n_review}/{len(tr_y)} "
        f"({100 * n_review / len(tr_y):.2f}%) of train; head LR uses "
        "class_weight='balanced'"
    )
    t0 = time.time()
    lr = LogisticRegression(class_weight="balanced", max_iter=5000, random_state=0)
    lr.fit(Xtr, tr_y)
    lr_va = split_metrics(va_y, list(lr.predict(Xva)))
    mlp = Pipeline(
        [
            ("sc", StandardScaler()),
            (
                "clf",
                MLPClassifier(
                    hidden_layer_sizes=(256,), max_iter=500,
                    random_state=0,
                ),
            ),
        ]
    )
    mlp.fit(Xtr, tr_y)
    mlp_va = split_metrics(va_y, list(mlp.predict(Xva)))
    head_train_s = time.time() - t0
    lr_acc = lr_va["exact"][0] / lr_va["exact"][1]
    mlp_acc = mlp_va["exact"][0] / mlp_va["exact"][1]
    print(f"head LR  validation exact: {fmt(lr_va['exact'])}")
    print(f"head MLP validation exact: {fmt(mlp_va['exact'])}")
    if mlp_acc > lr_acc + 0.05:
        head, head_name = mlp, "mlp-1x256"
        print("head choice: MLP (beats LR on validation by >5pts)")
    else:
        head, head_name = lr, "logreg-balanced"
        print("head choice: LogisticRegression (MLP did not beat it by >5pts)")

    # Step 3: TF-IDF baseline on raw texts, same splits/labels.
    from sklearn.feature_extraction.text import TfidfVectorizer
    from sklearn.pipeline import FeatureUnion

    t0 = time.time()
    tfidf = Pipeline(
        [
            (
                "feats",
                FeatureUnion(
                    [
                        (
                            "char",
                            TfidfVectorizer(
                                analyzer="char_wb",
                                ngram_range=(3, 5),
                                max_features=40000,
                            ),
                        ),
                        (
                            "word",
                            TfidfVectorizer(
                                ngram_range=(1, 2), max_features=20000
                            ),
                        ),
                    ]
                ),
            ),
            ("clf", LogisticRegression(C=4, max_iter=5000, random_state=0)),
        ]
    )
    tfidf.fit(tr_texts, tr_y)
    tfidf_train_s = time.time() - t0
    print(f"train seconds: head={head_train_s:.1f} tfidf={tfidf_train_s:.1f}")

    # Step 4: evaluate both on all four sets.
    sets = {
        "validation": (va_texts, va_y, Xva),
        "shell": (ex_texts["shell"], ex_y["shell"], embs["shell"]),
        "incidents": (ex_texts["incidents"], ex_y["incidents"], embs["incidents"]),
        "ko": (ex_texts["ko"], ex_y["ko"], embs["ko"]),
    }
    results = {}
    shell_errors = {}
    for mname, model, is_emb in (("head", head, True), ("tfidf", tfidf, False)):
        results[mname] = {}
        for sname, (texts, y, X) in sets.items():
            Xin = X if is_emb else texts
            pred = list(model.predict(Xin))
            results[mname][sname] = split_metrics(y, pred)
        # Winner-NOTES support: shell misclassifications with chosen-class prob.
        Xin = embs["shell"] if is_emb else ex_texts["shell"]
        pred = list(model.predict(Xin))
        proba = model.predict_proba(Xin)
        classes = list(model.classes_)
        errs = []
        for row, t, p, pr in zip(exam_rows["shell"], ex_y["shell"], pred, proba):
            ok = t == "any" or p == t or (t == "review" and p == "block")
            if not ok:
                errs.append(
                    {
                        "id": row.get("id"),
                        "tool_call": row["tool_call"],
                        "expected": t,
                        "pred": p,
                        "prob": round(float(pr[classes.index(p)]), 4),
                    }
                )
        errs.sort(key=lambda e: -e["prob"])
        shell_errors[mname] = errs

    print("TABLE-BEGIN")
    for mname in ("head", "tfidf"):
        for sname in ("validation", "shell", "incidents", "ko"):
            m = results[mname][sname]
            print(
                f"[{mname}] {sname:10s} exact {fmt(m['exact'])} | "
                f"held {fmt(m['held'])} | kept {fmt(m['kept'])}"
            )
    print("TABLE-END")

    # Step 5: winner by highest shell held, then highest shell kept
    # (ties keep head). Compare against stock-judge shell baselines.
    h_held = results["head"]["shell"]["held"][0]
    t_held = results["tfidf"]["shell"]["held"][0]
    h_kept = results["head"]["shell"]["kept"][0]
    t_kept = results["tfidf"]["shell"]["kept"][0]
    winner = "tfidf" if (t_held, t_kept) > (h_held, h_kept) else "head"
    print(
        f"winner rule: shell held head={h_held}/36 vs tfidf={t_held}/36, then "
        f"kept head={h_kept}/35 vs tfidf={t_kept}/35 -> {winner}"
    )
    w_held = results[winner]["shell"]["held"][0]
    w_kept = results[winner]["shell"]["kept"][0]
    beats_stock = bool(w_held > 23 and w_kept > 19)
    print(
        f"stock-judge shell baselines: held 23/36 kept 19/35; "
        f"winner {winner}: held {w_held}/36 kept {w_kept}/35; "
        f"beats stock on both: {beats_stock}"
    )

    import joblib

    BEST_DIR.mkdir(parents=True, exist_ok=True)
    joblib.dump(head, BEST_DIR / "head.joblib")
    joblib.dump(tfidf, BEST_DIR / "tfidf.joblib")
    classes = list(head.classes_)
    (BEST_DIR / "labels.json").write_text(
        json.dumps({"classes": classes}, indent=1) + "\n"
    )
    metrics = {
        "hashes": {
            "train": h_train,
            "validation": h_val,
            "expected": EXPECTED_HASH,
        },
        "encoder": enc_info,
        "embedding_cache_hit": cache_hit,
        "embedding_dim": int(Xtr.shape[1]),
        "head_model": head_name,
        "head_lr_validation_exact": lr_va["exact"],
        "head_mlp_validation_exact": mlp_va["exact"],
        "imbalance": {
            "train_review_rows": n_review,
            "train_rows": len(tr_y),
            "handling": "head LR class_weight=balanced; "
            "TF-IDF baseline LR(C=4) as specified (no class weights)",
        },
        "results": results,
        "winner": winner,
        "winner_rule": "highest shell held, then highest shell kept (ties: head)",
        "stock_shell_baseline": {"held": [23, 36], "kept": [19, 35]},
        "earlier_binary_tfidf_shell": {"held": [33, 36], "kept": [32, 35]},
        "winner_beats_stock": beats_stock,
        "train_seconds": {"head": head_train_s, "tfidf": tfidf_train_s},
        "total_seconds": time.time() - t_start,
        "shell_errors": shell_errors,
    }
    (BEST_DIR / "metrics.json").write_text(json.dumps(metrics, indent=1) + "\n")
    # G5 self-check: saved numbers equal the printed numbers.
    reloaded = json.loads((BEST_DIR / "metrics.json").read_text())
    assert reloaded["results"] == results, "metrics.json mismatch"
    assert reloaded["winner"] == winner, "metrics.json winner mismatch"
    print("G5 metrics.json self-check: PASS")

    print(f"winner ({winner}) worst shell errors (by predicted prob desc):")
    for e in shell_errors[winner][:5]:
        print(
            f"  id={e['id']} expected={e['expected']} pred={e['pred']} "
            f"p={e['prob']:.4f} :: {e['tool_call'][:110]}"
        )
    print(f"saved: {BEST_DIR}/head.joblib, tfidf.joblib, labels.json, metrics.json")
    print(f"total: {time.time() - t_start:.1f}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())

