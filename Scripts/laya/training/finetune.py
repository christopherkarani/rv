#!/usr/bin/env python3
"""Ticket 4b -- FULL fine-tune of the Laya encoder on dataset v2.

Three arms, one script, one run:

  ARM A (the point): end-to-end fine-tune. Encoder (all layers trainable)
      + mean-pool + linear 3-class head. Input = v2 row "text" tokenized
      with the checkpoint tokenizer (max 512). Cross-entropy with
      inverse-frequency class weights. AdamW param groups: encoder 1e-5,
      head 5e-4. Batch 16, 3 epochs, validation each epoch, keep the
      best-validation checkpoint. Seeds torch+numpy+random = 13.
  ARM B (control): frozen-encoder head, Ticket 2 pipeline (LR balanced +
      MLP candidate with the >5pt switch rule) retrained on v2 data, with
      new embeddings over the context-bearing texts. Extends (never
      overwrites) the /tmp/laya-train/embeddings/ cache.
  ARM C (measuring stick, NOT a ship candidate): TF-IDF
      char_wb(3,5)+word(1,2) + LogReg(C=4) on v2 "text".

Eval (argmax everywhere; no threshold tuning): v2 validation, shell,
incidents, ko, adversarial, ss11test (v1.1 test POSIX rows serialized with
the SAME format as prepare_data_v2.serialize; labels ask->review,
deny->block). Exams without context get command-only input (the runtime
no-context case). Metrics = train_head.split_metrics: exact
(review-expected also accepts block; "any" accepts everything), held, kept.

Plus: ARM A context ablation (validation + ss11test with context vs
command-only), ONNX export of ARM A + onnxruntime verification, leakage
gate (L4), winner rule (L6).

Run: cd Scripts/laya/training && PYTHONPATH=/tmp/laya-pylibs:/tmp/laya-torchlibs \
     HF_HUB_DISABLE_XET=1 /tmp/laya-venv/bin/python finetune.py
Exit 0 on success. Re-runs reuse /tmp/laya-train/ft/ artifacts + the
embedding cache (fast); pass --retrain to force full retraining.

Saves under /tmp/laya-train/ft/: best_model.pt (full state_dict), config.json
(architecture + hyperparams + training stats), tokenizer files (copied),
model.onnx (+ .data), arm_b/arm_c models, metrics.json (every printed number).
"""

import argparse
import hashlib
import json
import os
import random
import shutil
import sys
import time
from pathlib import Path

os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

import numpy as np

# Sibling reuse: prepare_data_v2 normalization + serializer (exact fallback).
try:
    from prepare_data_v2 import normalize as normalize  # noqa: F401
    from prepare_data_v2 import serialize as serialize  # noqa: F401
    HAVE_V2LIB = True
except ImportError:
    HAVE_V2LIB = False

    def normalize(text):
        """Canonical key (fallback copy of prepare_data_v2.normalize)."""
        s = " ".join(text.split())
        if len(s) >= 2 and s[0] == s[-1] and s[0] in ("'", '"'):
            s = s[1:-1]
        return s.lower()

    def serialize(command, sc):
        """Fallback copy of prepare_data_v2.serialize (exact format)."""
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

# Encoder loading + metric definitions reused verbatim from Ticket 2.
import train_head

HERE = Path(__file__).resolve().parent
TRAIN_PATH = Path("/tmp/laya-train/v2/train.jsonl")
VAL_PATH = Path("/tmp/laya-train/v2/validation.jsonl")
SS11_TEST = Path("/tmp/ss11-test.jsonl")
EXAM_PATHS = {
    "shell": (HERE / "../testset_shell.jsonl").resolve(),
    "incidents": (HERE / "../testset_incidents.jsonl").resolve(),
    "ko": (HERE / "../testset_ko_30.jsonl").resolve(),
    "adversarial": (HERE / "../adversarial-suffixes.jsonl").resolve(),
}
EMB_DIR = Path("/tmp/laya-train/embeddings")
OUT_DIR = Path("/tmp/laya-train/ft")
EXPECTED_HASH = {"train": "d8e153ea", "validation": "5cd0c2b0"}

LABELS = ("allow", "review", "block")
LAB2ID = {lab: i for i, lab in enumerate(LABELS)}
SS11_MAP = {"allow": "allow", "ask": "review", "deny": "block"}

SEED = 13
MAX_LEN = 512
BATCH_A = 16
EPOCHS_A = 3
LR_ENCODER = 1e-5
LR_HEAD = 5e-4
ONNX_DIFF_GATE = 1e-3
ONNX_ROWS = 20

split_metrics = train_head.split_metrics
fmt = train_head.fmt


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


def seed_all(seed=SEED):
    random.seed(seed)
    np.random.seed(seed)
    import torch

    torch.manual_seed(seed)
    try:
        if torch.backends.mps.is_available():
            torch.mps.manual_seed(seed)
    except Exception:
        pass


def build_ft_model():
    """Load the Laya multilingual checkpoint EXACTLY as train_head does,
    then wrap the encoder with mean-pool + linear 3-class head.

    Returns (model, tokenizer, device, ckpt, enc_desc). The caller decides
    train()/eval() and device placement.
    """
    import torch
    import torch.nn as nn

    class LayaFTClassifier(nn.Module):
        def __init__(self, encoder, hidden=768, n_labels=3):
            super().__init__()
            self.encoder = encoder
            self.classifier = nn.Linear(hidden, n_labels)

        def forward(self, input_ids, attention_mask):
            hs = self.encoder(
                input_ids=input_ids, attention_mask=attention_mask
            ).last_hidden_state
            w = attention_mask.unsqueeze(-1).to(hs.dtype)
            pooled = (hs * w).sum(1) / w.sum(1).clamp_min(1e-9)
            return self.classifier(pooled)

    ckpt = train_head.find_ckpt_dir()
    print(f"checkpoint: {ckpt}")
    encoder, tokenizer, device, desc = train_head.load_encoder(ckpt)
    print(f"encoder: {desc}")
    print(f"device: {device}")
    model = LayaFTClassifier(encoder)
    n_enc = sum(p.numel() for p in encoder.parameters())
    n_head = sum(p.numel() for p in model.classifier.parameters())
    print(f"params: encoder={n_enc} (all trainable) head={n_head} "
          f"(Linear 768->3, default init)")
    return model, tokenizer, device, ckpt, desc


def get_v2_embeddings(splits):
    """Embed v2-era splits, EXTENDING the shared embedding cache.

    splits: {name: {"texts": [...], "source": str}}. Rows already present
    in any cached texts_*.json/*.npy pair are reused; only new texts are
    encoded with the frozen encoder. New .npy files are written ONLY for
    names without an identical cache entry; existing files are never
    overwritten, and meta.json entries are merged (old keys preserved).
    Returns ({name: ndarray}, n_reused, n_encoded, enc_info).
    """
    EMB_DIR.mkdir(parents=True, exist_ok=True)
    pool = {}
    for tp in sorted(EMB_DIR.glob("texts_*.json")):
        name = tp.name[len("texts_"):-len(".json")]
        npy = EMB_DIR / f"{name}.npy"
        if not npy.exists():
            continue
        try:
            texts = json.loads(tp.read_text())
            e = np.load(npy)
        except Exception:
            continue
        if len(texts) != e.shape[0]:
            continue
        for t, row in zip(texts, e):
            pool.setdefault(t, row)
    print(f"embedding pool: {len(pool)} rows from existing cache")
    meta_path = EMB_DIR / "meta.json"
    meta = json.loads(meta_path.read_text()) if meta_path.exists() else {}
    old_splits = meta.get("splits", {})

    model = tokenizer = device = desc = None

    def ensure_encoder():
        nonlocal model, tokenizer, device, desc
        if model is None:
            ckpt = train_head.find_ckpt_dir()
            model, tokenizer, device, desc = train_head.load_encoder(ckpt)
            print(f"ARM B encoder: {desc} | device={device}")
        return model, tokenizer, device

    out, n_reused, n_encoded = {}, 0, 0
    t0 = time.time()
    for n, v in splits.items():
        texts = v["texts"]
        missing = [(i, t) for i, t in enumerate(texts) if t not in pool]
        if missing:
            m, tok, device = ensure_encoder()
            new_embs, device = train_head.encode_texts(
                [t for _, t in missing], m, tok, device)
            for (_, t), row in zip(missing, new_embs):
                pool.setdefault(t, row)
        e = np.stack([pool[t] for t in texts])
        assert e.shape[0] == len(texts), (n, e.shape)
        out[n] = e
        n_reused += len(texts) - len(missing)
        n_encoded += len(missing)
        want = {"n": len(texts), "sha": train_head.texts_sha(texts),
                "source": str(v["source"])}
        npy = EMB_DIR / f"{n}.npy"
        if old_splits.get(n) == want and npy.exists():
            print(f"split {n}: cache HIT ({len(texts)} rows)")
        else:
            np.save(npy, e)
            (EMB_DIR / f"texts_{n}.json").write_text(json.dumps(texts))
            old_splits[n] = want
            print(f"split {n}: reused {len(texts) - len(missing)}/"
                  f"{len(texts)} cached rows, encoded {len(missing)} new "
                  f"({time.time() - t0:.1f}s elapsed)")
    if model is not None:
        meta = {"splits": old_splits, "encoder": desc, "device": device}
        meta_path.write_text(json.dumps(meta, indent=1))
    info = (f"{meta.get('encoder', desc or '?')} | "
            f"device={meta.get('device', device or '?')}")
    return out, n_reused, n_encoded, info


def train_arm_b(Xtr, tr_y, Xva, va_y):
    """Ticket 2 head pipeline verbatim: LR(class_weight=balanced) plus a
    1-hidden-layer MLP candidate kept only if it beats LR on validation
    exact by >5 points. Returns (head, head_name, lr_va, mlp_va, seconds).
    """
    from sklearn.linear_model import LogisticRegression
    from sklearn.neural_network import MLPClassifier
    from sklearn.pipeline import Pipeline
    from sklearn.preprocessing import StandardScaler

    n_review = sum(1 for y in tr_y if y == "review")
    print(
        f"ARM B imbalance: review is {n_review}/{len(tr_y)} "
        f"({100 * n_review / len(tr_y):.2f}%) of train; head LR uses "
        "class_weight='balanced'"
    )
    t0 = time.time()
    lr = LogisticRegression(class_weight="balanced", max_iter=5000,
                            random_state=0)
    lr.fit(Xtr, tr_y)
    lr_va = split_metrics(va_y, list(lr.predict(Xva)))
    mlp = Pipeline(
        [
            ("sc", StandardScaler()),
            ("clf", MLPClassifier(hidden_layer_sizes=(256,), max_iter=500,
                                  random_state=0)),
        ]
    )
    mlp.fit(Xtr, tr_y)
    mlp_va = split_metrics(va_y, list(mlp.predict(Xva)))
    secs = time.time() - t0
    lr_acc = lr_va["exact"][0] / lr_va["exact"][1]
    mlp_acc = mlp_va["exact"][0] / mlp_va["exact"][1]
    print(f"ARM B head LR  validation exact: {fmt(lr_va['exact'])}")
    print(f"ARM B head MLP validation exact: {fmt(mlp_va['exact'])}")
    if mlp_acc > lr_acc + 0.05:
        head, head_name = mlp, "mlp-1x256"
        print("ARM B head choice: MLP (beats LR on validation by >5pts)")
    else:
        head, head_name = lr, "logreg-balanced"
        print("ARM B head choice: LogisticRegression (MLP did not beat it by >5pts)")
    return head, head_name, lr_va, mlp_va, secs


def train_arm_c(tr_texts, tr_y):
    """TF-IDF measuring stick (Ticket 2 spec verbatim)."""
    from sklearn.feature_extraction.text import TfidfVectorizer
    from sklearn.linear_model import LogisticRegression
    from sklearn.pipeline import FeatureUnion, Pipeline

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
    secs = time.time() - t0
    print(f"ARM C TF-IDF(LogReg C=4) trained in {secs:.1f}s "
          f"(NOT a ship candidate)")
    return tfidf, secs


def eval_arm_a(model, tokenizer, device, texts, batch=64):
    """Argmax predictions + chosen-class probs + logits for ARM A."""
    import torch

    model.eval()
    preds, probs, logits_all = [], [], []
    with torch.inference_mode():
        for i in range(0, len(texts), batch):
            chunk = texts[i:i + batch]
            enc = tokenizer(chunk, padding=True, truncation=True,
                            max_length=MAX_LEN, return_tensors="pt")
            logits = model(enc["input_ids"].to(device),
                           enc["attention_mask"].to(device))
            pr = torch.softmax(logits.float(), dim=-1)
            chosen = logits.argmax(dim=-1)
            preds.extend(LABELS[j] for j in chosen.tolist())
            probs.extend(pr[range(len(chunk)), chosen].tolist())
            logits_all.append(logits.float().cpu().numpy())
    logits_all = np.concatenate(logits_all, axis=0) if logits_all else np.zeros((0, 3))
    return preds, probs, logits_all


def train_arm_a(model, tokenizer, device, tr_texts, tr_y, va_texts, va_y):
    """End-to-end fine-tune: all encoder layers + head. 3 epochs, batch 16,
    CE with inverse-frequency weights, AdamW (encoder 1e-5, head 5e-4),
    validation each epoch, keep best (exact, tie-break lower val loss).
    Returns (best_state_cpu, stats). Model weights are restored to best.
    """
    import torch

    n = len(tr_y)
    counts = {lab: sum(1 for y in tr_y if y == lab) for lab in LABELS}
    weights = torch.tensor([n / (len(LABELS) * counts[lab]) for lab in LABELS],
                           dtype=torch.float32)
    print(f"ARM A class counts: {counts} -> inverse-frequency weights "
          f"(N/(C*n_c)): {[round(float(w), 4) for w in weights]}")
    print(f"ARM A optimizer: AdamW param groups encoder lr={LR_ENCODER}, "
          f"head lr={LR_HEAD}, weight_decay=0.01, no scheduler; "
          f"batch={BATCH_A}, epochs={EPOCHS_A}, max_len={MAX_LEN}, seed={SEED}")
    tr_ids = [LAB2ID[y] for y in tr_y]
    va_ids = [LAB2ID[y] for y in va_y]
    opt = torch.optim.AdamW([
        {"params": model.encoder.parameters(), "lr": LR_ENCODER},
        {"params": model.classifier.parameters(), "lr": LR_HEAD},
    ], weight_decay=0.01)
    loss_fn = torch.nn.CrossEntropyLoss(weight=weights.to(device))
    gen = torch.Generator().manual_seed(SEED)
    model.train()
    try:
        model.to(device)
    except Exception:
        device = "cpu"
        model.to(device)
        loss_fn = torch.nn.CrossEntropyLoss(weight=weights.to(device))
        print("ARM A device error, falling back to cpu")

    def sample_mem():
        try:
            if device == "mps":
                return torch.mps.current_allocated_memory() / 1e6
        except Exception:
            pass
        return 0.0

    t0 = time.time()
    peak_mem = 0.0
    train_losses, val_losses, val_exact = [], [], []
    best_state, best_exact, best_vloss = None, -1, float("inf")
    best_epoch = 0
    n_steps = 0
    for epoch in range(1, EPOCHS_A + 1):
        perm = torch.randperm(n, generator=gen).tolist()
        run_loss, run_n = 0.0, 0
        for i in range(0, n, BATCH_A):
            idx = perm[i:i + BATCH_A]
            batch = tokenizer([tr_texts[j] for j in idx], padding=True,
                              truncation=True, max_length=MAX_LEN,
                              return_tensors="pt")
            y = torch.tensor([tr_ids[j] for j in idx],
                             dtype=torch.long).to(device)
            opt.zero_grad()
            logits = model(batch["input_ids"].to(device),
                           batch["attention_mask"].to(device))
            loss = loss_fn(logits, y)
            loss.backward()
            opt.step()
            run_loss += float(loss.item()) * len(idx)
            run_n += len(idx)
            n_steps += 1
            if n_steps % 200 == 0:
                peak_mem = max(peak_mem, sample_mem())
        peak_mem = max(peak_mem, sample_mem())
        train_losses.append(run_loss / run_n)
        # Validation: loss + metrics.
        model.eval()
        v_loss, v_n = 0.0, 0
        v_preds = []
        with torch.inference_mode():
            for i in range(0, len(va_texts), 64):
                chunk = va_texts[i:i + 64]
                enc = tokenizer(chunk, padding=True, truncation=True,
                                max_length=MAX_LEN, return_tensors="pt")
                logits = model(enc["input_ids"].to(device),
                               enc["attention_mask"].to(device))
                y = torch.tensor(va_ids[i:i + 64],
                                 dtype=torch.long).to(device)
                v_loss += float(loss_fn(logits, y).item()) * len(chunk)
                v_n += len(chunk)
                v_preds.extend(LABELS[j] for j in logits.argmax(-1).tolist())
        model.train()
        v_loss /= v_n
        val_losses.append(v_loss)
        m = split_metrics(va_y, v_preds)
        val_exact.append(m["exact"])
        print(f"ARM A epoch {epoch}/{EPOCHS_A}: train_loss={train_losses[-1]:.4f} "
              f"val_loss={v_loss:.4f} val_exact={fmt(m['exact'])} "
              f"held={fmt(m['held'])} kept={fmt(m['kept'])} "
              f"({time.time() - t0:.0f}s elapsed)")
        if (m["exact"][0], -v_loss) > (best_exact, -best_vloss):
            best_exact, best_vloss = m["exact"][0], v_loss
            best_epoch = epoch
            best_state = {k: v.detach().cpu().clone()
                          for k, v in model.state_dict().items()}
    wall = time.time() - t0
    model.load_state_dict(best_state)
    stats = {
        "epochs_run": EPOCHS_A,
        "best_epoch": best_epoch,
        "wall_s": wall,
        "peak_mps_mb": round(peak_mem, 1),
        "train_loss_per_epoch": [round(x, 4) for x in train_losses],
        "val_loss_per_epoch": [round(x, 4) for x in val_losses],
        "val_exact_per_epoch": val_exact,
        "final_train_loss": round(train_losses[-1], 4),
        "final_val_loss": round(val_losses[-1], 4),
        "best_val_exact": val_exact[best_epoch - 1],
        "cached": False,
    }
    print(f"ARM A done: best epoch {best_epoch}/{EPOCHS_A} "
          f"(val exact {fmt(val_exact[best_epoch - 1])}), "
          f"wall {wall:.0f}s, peak MPS {peak_mem:.0f} MB")
    return best_state, stats


def export_onnx(model, tokenizer, out_path):
    """Export ARM A to a single ONNX graph (opset 18): int64
    input_ids+attention_mask in, [B,3] logits out, dynamic batch+seq."""
    import torch

    model.eval()
    dummy = tokenizer(["export shape probe", "second row | sh"],
                      padding=True, truncation=True, max_length=MAX_LEN,
                      return_tensors="pt")
    args = (dummy["input_ids"], dummy["attention_mask"])
    t0 = time.time()
    torch.onnx.export(
        model, args, str(out_path),
        input_names=["input_ids", "attention_mask"],
        output_names=["logits"],
        dynamic_axes={
            "input_ids": {0: "batch", 1: "seq"},
            "attention_mask": {0: "batch", 1: "seq"},
            "logits": {0: "batch"},
        },
        opset_version=18,
    )
    print(f"ONNX export ok in {time.time() - t0:.1f}s -> {out_path}")
    return out_path


def verify_onnx(onnx_path, model, tokenizer, device, val_texts):
    """Max |logit diff| torch-vs-ORT on 20 validation rows (+ a 1-row
    dynamic-shape check). Returns (diff20, diff1)."""
    import torch

    import onnxruntime as ort

    rows = val_texts[:ONNX_ROWS]
    assert len(rows) == ONNX_ROWS, f"need {ONNX_ROWS} rows, have {len(rows)}"
    batch = tokenizer(rows, padding=True, truncation=True,
                      max_length=MAX_LEN, return_tensors="pt")
    model.eval()
    with torch.inference_mode():
        ref = model(batch["input_ids"].to(device),
                    batch["attention_mask"].to(device)).float().cpu().numpy()
    sess = ort.InferenceSession(str(onnx_path),
                                providers=["CPUExecutionProvider"])
    in_spec = [(i.name, i.shape, i.type) for i in sess.get_inputs()]
    out_spec = [(o.name, o.shape, o.type) for o in sess.get_outputs()]
    print(f"ONNX inputs: {in_spec} outputs: {out_spec}")
    feed = {
        "input_ids": batch["input_ids"].numpy().astype(np.int64),
        "attention_mask": batch["attention_mask"].numpy().astype(np.int64),
    }
    got = sess.run(None, feed)[0]
    diff20 = float(np.abs(got - ref).max())
    # Dynamic-shape check: batch 1 (also a different padded seq len).
    b1 = tokenizer(rows[:1], padding=True, truncation=True,
                   max_length=MAX_LEN, return_tensors="pt")
    with torch.inference_mode():
        ref1 = model(b1["input_ids"].to(device),
                     b1["attention_mask"].to(device)).float().cpu().numpy()
    got1 = sess.run(None, {
        "input_ids": b1["input_ids"].numpy().astype(np.int64),
        "attention_mask": b1["attention_mask"].numpy().astype(np.int64),
    })[0]
    diff1 = float(np.abs(got1 - ref1).max())
    print(f"ONNX verify: max |logit diff| on {ONNX_ROWS} val rows = {diff20:.3e} "
          f"(gate < {ONNX_DIFF_GATE}); batch-1 shape check diff = {diff1:.3e}")
    return diff20, diff1, in_spec, out_spec


def load_ss11_test():
    """v1.1 test split, POSIX rows only, serialized with the SAME format as
    prepare_data_v2.serialize. Labels mapped ask->review, deny->block."""
    if not SS11_TEST.exists():
        raise FileNotFoundError(
            f"{SS11_TEST} missing; ticket requires it present (download the "
            "shell-safety-v1.1 test split there and re-run)")
    texts, commands, labels = [], [], []
    n_in, n_nonposix, n_bad = 0, 0, 0
    for r in load_rows(SS11_TEST):
        n_in += 1
        if r.get("shell") != "posix":
            n_nonposix += 1
            continue
        command = (r.get("command") or "").strip()
        label = SS11_MAP.get(r.get("label"))
        if not command or label is None:
            n_bad += 1
            continue
        texts.append(serialize(command, r.get("session_context")))
        commands.append(command)
        labels.append(label)
    print(f"ss11test: {len(texts)} POSIX rows kept "
          f"(in={n_in} non_posix_dropped={n_nonposix} bad_dropped={n_bad})")
    return texts, commands, labels


def shell_error_rows(exam_shell_rows, y_true, y_pred, y_prob):
    errs = []
    for row, t, p, pr in zip(exam_shell_rows, y_true, y_pred, y_prob):
        ok = t == "any" or p == t or (t == "review" and p == "block")
        if not ok:
            errs.append({
                "id": row.get("id"),
                "tool_call": row["tool_call"],
                "expected": t,
                "pred": p,
                "prob": round(float(pr), 4),
            })
    errs.sort(key=lambda e: -e["prob"])
    return errs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--retrain", action="store_true",
                    help="ignore cached /tmp/laya-train/ft/ artifacts")
    args = ap.parse_args()
    t_start = time.time()
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    seed_all(SEED)

    # ---- L1: verify audited inputs before anything else ----
    h_train = sha_prefix(TRAIN_PATH)
    h_val = sha_prefix(VAL_PATH)
    print(f"train.jsonl sha256 prefix: {h_train} (expect {EXPECTED_HASH['train']})")
    print(f"validation.jsonl sha256 prefix: {h_val} (expect {EXPECTED_HASH['validation']})")
    assert h_train == EXPECTED_HASH["train"], "train hash mismatch -- STOP"
    assert h_val == EXPECTED_HASH["validation"], "validation hash mismatch -- STOP"
    print("L1 input hashes: PASS")
    print(f"serializer: {'imported from prepare_data_v2' if HAVE_V2LIB else 'exact local copy'}; "
          "encoder loading: train_head.find_ckpt_dir/load_encoder")

    train_rows = load_rows(TRAIN_PATH)
    val_rows = load_rows(VAL_PATH)
    exam_rows = {n: load_rows(p) for n, p in EXAM_PATHS.items()}
    exam_rows = {n: [r for r in rows if r.get("tool_call") != "__meta__"]
                for n, rows in exam_rows.items()}
    print(f"train rows: {len(train_rows)}, validation rows: {len(val_rows)}, " +
          ", ".join(f"{n} {len(r)}" for n, r in exam_rows.items()))
    tr_texts = [r["text"] for r in train_rows]
    tr_cmds = [r["command"] for r in train_rows]
    tr_y = [r["label"] for r in train_rows]
    va_texts = [r["text"] for r in val_rows]
    va_cmds = [r["command"] for r in val_rows]
    va_y = [r["label"] for r in val_rows]
    ex_texts = {n: [r["tool_call"].strip() for r in rows]
                for n, rows in exam_rows.items()}
    ex_y = {n: [r["expected"] for r in rows] for n, rows in exam_rows.items()}
    ss_texts, ss_cmds, ss_y = load_ss11_test()

    # ---- L4: no normalized exam command in training texts ----
    tr_cmd_norms = {normalize(c) for c in tr_cmds}
    tr_text_norms = {normalize(t) for t in tr_texts}
    va_cmd_norms = {normalize(c) for c in va_cmds}
    leak_info = {"n_train_cmd_norms": len(tr_cmd_norms),
                 "n_train_text_norms": len(tr_text_norms),
                 "n_val_cmd_norms": len(va_cmd_norms), "sets": {}}
    all_clear = True
    check_sets = dict(ex_texts)
    check_sets["ss11test"] = [c.strip() for c in ss_cmds]
    for n, cmds in check_sets.items():
        norms = {normalize(c) for c in cmds}
        hit_cmd = norms & tr_cmd_norms
        hit_text = norms & tr_text_norms
        hit_va = norms & va_cmd_norms
        leak_info["sets"][n] = {
            "n_exam_norms": len(norms),
            "hits_train_cmd": len(hit_cmd),
            "hits_train_text": len(hit_text),
            "hits_val_cmd": len(hit_va),
        }
        if hit_cmd or hit_text:
            all_clear = False
            print(f"L4 LEAK {n}: train_cmd={sorted(hit_cmd)[:3]} "
                  f"train_text={sorted(hit_text)[:3]}")
    assert all_clear, "LEAKAGE into training texts -- STOP"
    print(f"L4 leakage: PASS (train cmd norms={len(tr_cmd_norms)}, "
          f"train text norms={len(tr_text_norms)}; exam hits: " +
          ", ".join(f"{n}=0/{leak_info['sets'][n]['n_exam_norms']}"
                    for n in check_sets) + ")")

    # ---- ARM B embeddings (always via the shared cache) ----
    emb_splits = {
        "v2train": {"texts": tr_texts, "source": TRAIN_PATH},
        "v2val": {"texts": va_texts, "source": VAL_PATH},
        "shell": {"texts": ex_texts["shell"], "source": EXAM_PATHS["shell"]},
        "incidents": {"texts": ex_texts["incidents"],
                      "source": EXAM_PATHS["incidents"]},
        "ko": {"texts": ex_texts["ko"], "source": EXAM_PATHS["ko"]},
        "adversarial": {"texts": ex_texts["adversarial"],
                        "source": EXAM_PATHS["adversarial"]},
        "ss11test": {"texts": ss_texts, "source": SS11_TEST},
    }
    embs, n_reused, n_encoded, enc_info_b = get_v2_embeddings(emb_splits)
    Xtr, Xva = embs["v2train"], embs["v2val"]

    # ---- ARM B head (train or load cached) ----
    import joblib

    b_model_p, b_meta_p = OUT_DIR / "arm_b_head.joblib", OUT_DIR / "arm_b_meta.json"
    b_meta = json.loads(b_meta_p.read_text()) if b_meta_p.exists() else {}
    if (not args.retrain and b_model_p.exists() and
            b_meta.get("hashes", {}).get("train") == h_train and
            b_meta.get("hashes", {}).get("validation") == h_val):
        head_b, head_name_b = joblib.load(b_model_p), b_meta["head_model"]
        lr_va_b = {k: v for k, v in b_meta["lr_val_exact"].items()}
        mlp_va_b = {k: v for k, v in b_meta["mlp_val_exact"].items()}
        b_train_s = b_meta["train_s"]
        print(f"ARM B: loaded cached {b_model_p.name} ({head_name_b}, "
              f"val exact {fmt(b_meta['head_val_exact'])})")
    else:
        head_b, head_name_b, lr_va_b, mlp_va_b, b_train_s = train_arm_b(
            Xtr, tr_y, Xva, va_y)
        joblib.dump(head_b, b_model_p)
        b_meta = {
            "head_model": head_name_b,
            "hashes": {"train": h_train, "validation": h_val},
            "lr_val_exact": lr_va_b, "mlp_val_exact": mlp_va_b,
            "head_val_exact": (lr_va_b if head_name_b.startswith("logreg")
                               else mlp_va_b)["exact"],
            "train_s": b_train_s,
        }
        b_meta_p.write_text(json.dumps(b_meta, indent=1) + "\n")

    # ---- ARM C (train or load cached) ----
    c_model_p, c_meta_p = OUT_DIR / "arm_c_tfidf.joblib", OUT_DIR / "arm_c_meta.json"
    c_meta = json.loads(c_meta_p.read_text()) if c_meta_p.exists() else {}
    if (not args.retrain and c_model_p.exists() and
            c_meta.get("hashes", {}).get("train") == h_train and
            c_meta.get("hashes", {}).get("validation") == h_val):
        tfidf_c = joblib.load(c_model_p)
        c_train_s = c_meta["train_s"]
        print(f"ARM C: loaded cached {c_model_p.name} "
              f"(trained in {c_train_s:.1f}s)")
    else:
        tfidf_c, c_train_s = train_arm_c(tr_texts, tr_y)
        joblib.dump(tfidf_c, c_model_p)
        c_meta = {"hashes": {"train": h_train, "validation": h_val},
                  "train_s": c_train_s,
                  "spec": "char_wb(3,5)40k+word(1,2)20k LogReg(C=4)"}
        c_meta_p.write_text(json.dumps(c_meta, indent=1) + "\n")

    # ---- ARM A (train or load cached) ----
    pt_p, cfg_p = OUT_DIR / "best_model.pt", OUT_DIR / "config.json"
    cfg = json.loads(cfg_p.read_text()) if cfg_p.exists() else {}
    cached_a = (not args.retrain and pt_p.exists() and
                cfg.get("hashes", {}).get("train") == h_train and
                cfg.get("hashes", {}).get("validation") == h_val and
                cfg.get("seed") == SEED)
    model_a, tok_a, device_a, ckpt_a, enc_desc_a = build_ft_model()
    if cached_a:
        import torch

        model_a.load_state_dict(torch.load(pt_p, map_location="cpu",
                                           weights_only=True))
        stats_a = dict(cfg["training"])
        stats_a["cached"] = True
        print(f"ARM A: loaded cached {pt_p.name} (best epoch "
              f"{stats_a['best_epoch']}/{stats_a['epochs_run']}, orig wall "
              f"{stats_a['wall_s']:.0f}s); pass --retrain to force retraining")
    else:
        import torch

        best_state, stats_a = train_arm_a(model_a, tok_a, device_a,
                                          tr_texts, tr_y, va_texts, va_y)
        torch.save(best_state, pt_p)
        n_total = sum(v.numel() for v in best_state.values())
        counts = {lab: sum(1 for y in tr_y if y == lab) for lab in LABELS}
        cfg = {
            "ticket": "4b arm-a",
            "architecture": {
                "encoder": "laya-multilingual checkpoint via "
                           "train_head.load_encoder (mmBERT-base: "
                           "ModernBertModel, 22 layers, hidden 768)",
                "encoder_ckpt": str(ckpt_a),
                "encoder_desc": enc_desc_a,
                "pooling": "mean over non-pad tokens",
                "head": "Linear(768 -> 3), default init, all trainable",
                "labels": list(LABELS),
                "logit_order": list(LABELS),
                "max_len": MAX_LEN,
                "total_params": int(n_total),
            },
            "training": {
                "seed": SEED, "batch": BATCH_A, "epochs": EPOCHS_A,
                "optimizer": "AdamW param groups: encoder lr=1e-5, "
                             "head lr=5e-4, weight_decay=0.01, no scheduler",
                "loss": "CrossEntropy with inverse-frequency weights "
                        "w_c = N/(C*n_c)",
                "class_counts": counts,
                "class_weights": [round(len(tr_y) / (3 * counts[lab]), 6)
                                  for lab in LABELS],
                "best_selection": "best validation exact count, "
                                  "tie-break lower val loss",
            },
            "hashes": {"train": h_train, "validation": h_val},
            "seed": SEED,
        }
        cfg["training"].update(stats_a)
        cfg_p.write_text(json.dumps(cfg, indent=1) + "\n")
        for fn in ("tokenizer.json", "tokenizer_config.json"):
            src = ckpt_a / "tokenizer" / fn
            if src.exists():
                shutil.copy(src, OUT_DIR / fn)
        print(f"ARM A saved: {pt_p.name}, config.json, tokenizer files")
    try:
        model_a.to(device_a)
    except Exception:
        device_a = "cpu"
        model_a.to(device_a)

    # ---- Evaluate all three arms on all six sets (argmax) ----
    eval_sets = [
        ("validation", va_texts, va_y, Xva),
        ("shell", ex_texts["shell"], ex_y["shell"], embs["shell"]),
        ("incidents", ex_texts["incidents"], ex_y["incidents"],
         embs["incidents"]),
        ("ko", ex_texts["ko"], ex_y["ko"], embs["ko"]),
        ("adversarial", ex_texts["adversarial"], ex_y["adversarial"],
         embs["adversarial"]),
        ("ss11test", ss_texts, ss_y, embs["ss11test"]),
    ]
    results = {"arm_a": {}, "arm_b": {}, "arm_c": {}}
    a_probs = {}
    for sname, texts, y, X in eval_sets:
        pred_a, prob_a, _ = eval_arm_a(model_a, tok_a, device_a, texts)
        a_probs[sname] = prob_a
        results["arm_a"][sname] = split_metrics(y, pred_a)
        pred_b = list(head_b.predict(X))
        results["arm_b"][sname] = split_metrics(y, pred_b)
        pred_c = list(tfidf_c.predict(texts))
        results["arm_c"][sname] = split_metrics(y, pred_c)

    print("TABLE-BEGIN")
    for mname in ("arm_a", "arm_b", "arm_c"):
        for sname, _, _, _ in eval_sets:
            m = results[mname][sname]
            print(f"[{mname}] {sname:11s} exact {fmt(m['exact'])} | "
                  f"held {fmt(m['held'])} | kept {fmt(m['kept'])}")
    print("TABLE-END")

    # ---- Context ablation (ARM A only) ----
    pred_va_strip, _, _ = eval_arm_a(model_a, tok_a, device_a, va_cmds)
    pred_ss_strip, _, _ = eval_arm_a(model_a, tok_a, device_a, ss_cmds)
    abl = {
        "validation_with_context": results["arm_a"]["validation"],
        "validation_command_only": split_metrics(va_y, pred_va_strip),
        "ss11test_with_context": results["arm_a"]["ss11test"],
        "ss11test_command_only": split_metrics(ss_y, pred_ss_strip),
    }
    print("ABLATION-BEGIN")
    for pair, sname in (("validation", "validation"), ("ss11test", "ss11test")):
        full = abl[f"{pair}_with_context"]["exact"]
        strip = abl[f"{pair}_command_only"]["exact"]
        d = strip[0] - full[0]
        print(f"[ablation:arm-a] {sname:11s} command-only exact {fmt(strip)} "
              f"(with-context {fmt(full)}; delta {d:+d})")
    print("ABLATION-END")

    # ---- Shell errors (worst 5 ARM A with probs; all arms stored) ----
    shell_errors = {}
    pred_shell_a, _, _ = eval_arm_a(model_a, tok_a, device_a,
                                    ex_texts["shell"])
    shell_errors["arm_a"] = shell_error_rows(
        exam_rows["shell"], ex_y["shell"], pred_shell_a, a_probs["shell"])
    for mname, mpred, mproba, classes in (
        ("arm_b", list(head_b.predict(embs["shell"])),
         head_b.predict_proba(embs["shell"]), list(head_b.classes_)),
        ("arm_c", list(tfidf_c.predict(ex_texts["shell"])),
         tfidf_c.predict_proba(ex_texts["shell"]), list(tfidf_c.classes_)),
    ):
        probs = [float(pr[classes.index(p)]) for p, pr in zip(mpred, mproba)]
        shell_errors[mname] = shell_error_rows(
            exam_rows["shell"], ex_y["shell"], mpred, probs)
    print("ARM A worst shell errors (by predicted prob desc):")
    for e in shell_errors["arm_a"][:5]:
        print(f"  id={e['id']} expected={e['expected']} pred={e['pred']} "
              f"p={e['prob']:.4f} :: {e['tool_call'][:110]}")

    # ---- ONNX export + verification (L5) ----
    import torch

    onnx_p = OUT_DIR / "model.onnx"
    onnx_data_p = Path(str(onnx_p) + ".data")
    cpu_model, _, _, _, _ = build_ft_model()
    cpu_model.load_state_dict(torch.load(pt_p, map_location="cpu",
                                         weights_only=True))
    cpu_model.to("cpu")
    if (not args.retrain and onnx_p.exists()
            and onnx_p.stat().st_mtime > pt_p.stat().st_mtime):
        print(f"ONNX: reusing cached {onnx_p.name} "
              f"(newer than {pt_p.name})")
    else:
        if onnx_data_p.exists():
            onnx_data_p.unlink()
        export_onnx(cpu_model, tok_a, onnx_p)
    diff20, diff1, in_spec, out_spec = verify_onnx(
        onnx_p, cpu_model, tok_a, "cpu", va_texts)
    assert diff20 < ONNX_DIFF_GATE, f"ONNX drift {diff20} >= gate -- FAIL"
    print("L5 ONNX verified: PASS")
    in_spec = [[k, list(v) if isinstance(v, (list, tuple)) else v, t]
               for k, v, t in in_spec]
    out_spec = [[k, list(v) if isinstance(v, (list, tuple)) else v, t]
                for k, v, t in out_spec]

    # ---- L6: winner determination (literal rule, no tuning) ----
    a_shell_held = results["arm_a"]["shell"]["held"][0]
    a_shell_kept = results["arm_a"]["shell"]["kept"][0]
    a_adv_held = results["arm_a"]["adversarial"]["held"][0]
    a_val = results["arm_a"]["validation"]["exact"][0]
    b_val = results["arm_b"]["validation"]["exact"][0]
    cond_shell = (a_shell_held >= 33 and a_shell_kept >= 33)
    cond_adv = a_adv_held >= 17
    cond_val = a_val > b_val
    wins = bool(cond_shell and cond_adv and cond_val)
    verdict = "FT-WINS" if wins else "FT-LOSES"
    print(f"winner rule: shell held>={33}&&kept>={33}: "
          f"{a_shell_held}/36&&{a_shell_kept}/35 -> {cond_shell}; "
          f"adversarial held>=17/19: {a_adv_held}/19 -> {cond_adv}; "
          f"beats ARM B on validation exact: {a_val} vs {b_val} -> {cond_val}")
    print(f"VERDICT: {verdict} (thresholds stayed argmax; no exam-driven tuning)")

    baselines = {
        "stock_laya_shell": {"held": [23, 36], "kept": [19, 35]},
        "tfidf_v1data_round1_shell": {"held": [33, 36], "kept": [33, 35]},
        "tfidf_v1data_2b_shell": {"held": [36, 36], "kept": [33, 35]},
        "frozen_head_v1data_round1_shell": {"held": [28, 36], "kept": [32, 35]},
        "frozen_head_v1data_2b_shell": {"held": [34, 36], "kept": [33, 35]},
    }
    metrics = {
        "ticket": "4b",
        "hashes": {"train": h_train, "validation": h_val,
                   "expected": EXPECTED_HASH},
        "labels": list(LABELS),
        "ss11_label_map": SS11_MAP,
        "serializer_source": ("prepare_data_v2 import" if HAVE_V2LIB
                              else "exact local copy"),
        "encoder_arm_a": enc_desc_a,
        "encoder_arm_b": enc_info_b,
        "device": device_a,
        "seeds": {"arm_a_torch_numpy_random": SEED,
                  "arm_b_sklearn_random_state": 0,
                  "arm_c_sklearn_random_state": 0},
        "arm_a_training": stats_a,
        "arm_b": {"head_model": head_name_b, "lr_val_exact": lr_va_b,
                  "mlp_val_exact": mlp_va_b, "train_s": round(b_train_s, 1),
                  "emb_reused": n_reused, "emb_encoded": n_encoded},
        "arm_c": {"spec": "char_wb(3,5)40k+word(1,2)20k LogReg(C=4)",
                  "train_s": round(c_train_s, 1),
                  "ship_candidate": False},
        "set_sizes": {sname: len(y) for sname, _, y, _ in eval_sets},
        "results": results,
        "ablation_arm_a": abl,
        "shell_errors": shell_errors,
        "onnx": {
            "path": str(onnx_p),
            "size_bytes": onnx_p.stat().st_size,
            "data_size_bytes": (onnx_data_p.stat().st_size
                                if onnx_data_p.exists() else 0),
            "opset": 18,
            "inputs": in_spec,
            "outputs": out_spec,
            "max_logit_diff_20val": diff20,
            "max_logit_diff_batch1": diff1,
            "gate": ONNX_DIFF_GATE,
            "pass": bool(diff20 < ONNX_DIFF_GATE),
        },
        "leakage": dict(leak_info, **{"pass": True}),
        "baselines_quoted_from_readme": baselines,
        "winner_rule": "(shell held>=33 AND shell kept>=33) AND "
                       "(adversarial held>=17/19) AND "
                       "(ARM A beats ARM B on validation exact)",
        "winner_eval": {"cond_shell": bool(cond_shell),
                        "cond_adversarial": bool(cond_adv),
                        "cond_val_vs_armb": bool(cond_val)},
        "verdict": verdict,
        "total_seconds": round(time.time() - t_start, 1),
    }
    (OUT_DIR / "metrics.json").write_text(json.dumps(metrics, indent=1) + "\n")
    reloaded = json.loads((OUT_DIR / "metrics.json").read_text())
    assert reloaded["results"] == results, "metrics.json results mismatch"
    assert reloaded["ablation_arm_a"] == abl, "metrics.json ablation mismatch"
    assert reloaded["verdict"] == verdict, "metrics.json verdict mismatch"
    assert reloaded["onnx"]["max_logit_diff_20val"] == diff20, "onnx diff mismatch"
    print("L3 metrics.json self-check: PASS")
    print(f"saved: {OUT_DIR}/best_model.pt, config.json, model.onnx, "
          "arm_b_head.joblib, arm_c_tfidf.joblib, metrics.json")
    print(f"total: {time.time() - t_start:.1f}s")
    return 0


if __name__ == "__main__":
    rc = main()
    # Native teardown (onnxruntime/MPS on macOS) segfaults during
    # interpreter shutdown AFTER all work, saves, and verification complete.
    # Flush and exit explicitly so the command reports the real status.
    # (Errors inside main() still propagate with traceback + nonzero exit.)
    sys.stdout.flush()
    sys.stderr.flush()
    os._exit(rc)
