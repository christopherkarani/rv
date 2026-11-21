#!/usr/bin/env python3
"""Fine-tune the Laya encoder on dataset v3 (finetune.py ARM A, refactored).

Same model as v2: pinned base checkpoint via finetune.build_ft_model
(train_head.find_ckpt_dir/load_encoder: ModernBert encoder, all layers
trainable) + mean-pool + Linear(768->3) over [allow, review, block].
Training starts from the BASE Laya encoder, never from the v2 checkpoint.

Kept from v2 (unchanged): AdamW param groups encoder lr 1e-5 / head 5e-4,
weight_decay 0.01, no scheduler, batch 16, max_len 512, seeds 13
(torch + numpy + random + the shuffle generator).
Changed for v3 (diagnosis: strict labels, overconfidence):
  - class weights: none by default (--class-weights none|sqrt|inverse;
    v2 used inverse-frequency, up-weighting review 1.58x)
  - label smoothing 0.1 (--label-smoothing)
  - best-epoch selection on the eval corpus MAIN slice (heldout=false),
    scored model-only in both input forms (bare and cwd-inside-repo: yes),
    pooled: selection metric = benign rate with risk >= t at the highest t
    giving >= gates.json dangerous_recall.min (0.98) dangerous recall
    (lower is better); tie-break lower validation loss (plain CE).
    The heldout slice is never used for selection; it is reported at the end.
  - resume: per-epoch checkpoints + a rolling mid-epoch checkpoint every
    --save-every optimizer steps (runs take hours on MPS).

Outputs under LAYA_WORK/v3/ft/: best_model.pt, epoch-<n>.pt, ckpt/latest.pt,
config.json, tokenizer files, train-report.json.

Run: python3 finetune_v3.py [--resume] [--epochs 3]
"""

import argparse
import json
import math
import os
import random
import shutil
import sys
import time
from pathlib import Path

os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from laya_v3_common import (  # noqa: E402
    LAB2ID, LABELS, assert_no_overlap, check_eval_lock, eval_dir, forbidden_norms,
    load_eval_slices, load_jsonl, normalize, sha256_file, v3_dir)
import laya_v3_metrics as M  # noqa: E402

SEED = 13
MAX_LEN = 512


def class_weights(labels, mode):
    n = len(labels)
    counts = [sum(1 for y in labels if y == lab) for lab in LABELS]
    inv = [n / (len(LABELS) * max(1, c)) for c in counts]
    if mode == "none":
        return None, counts
    if mode == "sqrt":
        return [math.sqrt(w) for w in inv], counts
    if mode == "inverse":
        return inv, counts
    raise SystemExit(f"bad --class-weights {mode}")


def selection_score(scored_main, min_recall):
    """Pooled (both forms) benign flag rate at the min-recall threshold."""
    br, dr, per_form = [], [], {}
    for f in ("bare", "in-repo"):
        b = [float(M.risk_of(M.softmax(np.asarray(r["logits"][f])[None])[0]))
             for r in scored_main if r["set"] == "benign" and f in r["logits"]]
        d = [float(M.risk_of(M.softmax(np.asarray(r["logits"][f])[None])[0]))
             for r in scored_main if r["set"] == "dangerous" and f in r["logits"]]
        rate, t = M.selection_metric(b, d, min_recall)
        per_form[f] = {"benign_rate": rate, "threshold": t}
        br += b
        dr += d
    rate, t = M.selection_metric(br, dr, min_recall)
    return {"pooled_benign_rate": rate, "threshold": t, "per_form": per_form,
            "min_recall": min_recall}


def seed_all(seed):
    import torch

    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    try:
        if torch.backends.mps.is_available():
            torch.mps.manual_seed(seed)
    except Exception:
        pass


def atomic_save(obj, path):
    import torch

    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    torch.save(obj, tmp)
    os.replace(tmp, path)


def val_loss(model, tokenizer, device, texts, ids, batch=64):
    import torch

    model.eval()
    tot, n = 0.0, 0
    ce = torch.nn.CrossEntropyLoss(reduction="sum")
    with torch.inference_mode():
        for i in range(0, len(texts), batch):
            enc = tokenizer(texts[i:i + batch], padding=True, truncation=True,
                            max_length=MAX_LEN, return_tensors="pt")
            lg = model(enc["input_ids"].to(device), enc["attention_mask"].to(device))
            y = torch.tensor(ids[i:i + batch], dtype=torch.long, device=device)
            tot += float(ce(lg.float(), y).item())
            n += len(y)
    model.train()
    return tot / max(1, n)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--epochs", type=int, default=3)
    ap.add_argument("--batch", type=int, default=16)
    ap.add_argument("--lr-encoder", type=float, default=1e-5)
    ap.add_argument("--lr-head", type=float, default=5e-4)
    ap.add_argument("--weight-decay", type=float, default=0.01)
    ap.add_argument("--label-smoothing", type=float, default=0.1)
    ap.add_argument("--class-weights", choices=("none", "sqrt", "inverse"), default="none")
    ap.add_argument("--seed", type=int, default=SEED)
    ap.add_argument("--save-every", type=int, default=500,
                    help="optimizer steps between rolling mid-epoch checkpoints (0 = off)")
    ap.add_argument("--resume", action="store_true", help="continue from ft/ckpt/latest.pt")
    ap.add_argument("--max-train-rows", type=int, default=0, help="debug: cap train rows")
    a = ap.parse_args(argv)

    check_eval_lock(who="finetune_v3")
    import torch

    import finetune  # build_ft_model: pinned base checkpoint + head

    work = v3_dir()
    ft = work / "ft"
    ck = ft / "ckpt"
    ft.mkdir(parents=True, exist_ok=True)
    stats = json.loads((work / "stats.json").read_text())
    for s in ("train", "validation"):
        got = sha256_file(work / f"{s}.jsonl")
        if got != stats["sha256"][s]:
            raise SystemExit(f"{s}.jsonl sha {got[:12]} != stats.json {stats['sha256'][s][:12]}")
    train = load_jsonl(work / "train.jsonl")
    val = load_jsonl(work / "validation.jsonl")
    if a.max_train_rows:
        train = train[:a.max_train_rows]
    forb = forbidden_norms()
    for name, rows in (("train", train), ("validation", val)):
        assert_no_overlap({normalize(r["command"]) for r in rows}, forb, name)
        assert_no_overlap({normalize(r["text"]) for r in rows}, forb, name + " text")
    print(f"data: train {len(train)} validation {len(val)} (sha verified, leakage 0)")
    gates = json.loads((eval_dir() / "gates.json").read_text())
    min_recall = M.gate_targets(gates)["min_dangerous_recall"]
    slices = load_eval_slices()
    main_rows = [r for r in slices["main"] if r["set"] in ("benign", "dangerous")]
    held_rows = [r for r in slices["heldout"] if r["set"] in ("benign", "dangerous")]

    tr_texts = [r["text"] for r in train]
    tr_ids = [LAB2ID[r["label"]] for r in train]
    va_texts = [r["text"] for r in val]
    va_ids = [LAB2ID[r["label"]] for r in val]
    w, counts = class_weights([r["label"] for r in train], a.class_weights)
    print(f"class counts {dict(zip(LABELS, counts))}; weights {a.class_weights}: {w}; "
          f"label smoothing {a.label_smoothing}")

    seed_all(a.seed)
    model, tok, device, ckpt_dir, desc = finetune.build_ft_model()
    try:
        model.to(device)
    except Exception:
        device = "cpu"
        model.to(device)
    model.train()
    opt = torch.optim.AdamW([
        {"params": model.encoder.parameters(), "lr": a.lr_encoder},
        {"params": model.classifier.parameters(), "lr": a.lr_head},
    ], weight_decay=a.weight_decay)
    loss_fn = torch.nn.CrossEntropyLoss(
        weight=torch.tensor(w, dtype=torch.float32, device=device) if w else None,
        label_smoothing=a.label_smoothing)
    gen = torch.Generator().manual_seed(a.seed)

    state = {"epoch": 0, "next_batch": 0, "gen_state": gen.get_state(), "history": [],
             "steps": 0, "run_loss": 0.0, "run_n": 0, "wall": 0.0}
    latest = ck / "latest.pt"
    if a.resume and latest.exists():
        blob = torch.load(latest, map_location="cpu", weights_only=False)
        if blob.get("args_sig") != _sig(a, stats["sha256"]["train"], len(train)):
            raise SystemExit("ckpt/latest.pt was written with different data/hyperparameters; "
                             "refusing to resume (delete it to start over)")
        model.load_state_dict(blob["model"])
        opt.load_state_dict(blob["opt"])
        for k in ("epoch", "next_batch", "gen_state", "history", "steps", "run_loss", "run_n", "wall"):
            state[k] = blob[k]
        random.setstate(blob["py_rng"])
        np.random.set_state(blob["np_rng"])
        torch.set_rng_state(blob["torch_rng"])
        print(f"resumed: epoch {state['epoch'] + 1} batch {state['next_batch']} "
              f"(steps {state['steps']})")
    elif a.resume:
        print("no ckpt/latest.pt: starting fresh")

    def save_latest():
        atomic_save({
            "model": {k: v.detach().cpu() for k, v in model.state_dict().items()},
            "opt": opt.state_dict(), "py_rng": random.getstate(), "np_rng": np.random.get_state(),
            "torch_rng": torch.get_rng_state(), "args_sig": _sig(a, stats["sha256"]["train"], len(train)),
            **{k: state[k] for k in ("epoch", "next_batch", "gen_state", "history", "steps",
                                     "run_loss", "run_n", "wall")}}, latest)

    import laya_v3_model as LM

    scorer = LM.TorchScorer(model=model, tokenizer=tok, device=device)
    n = len(train)
    t0 = time.time() - state["wall"]
    while state["epoch"] < a.epochs:
        e = state["epoch"]
        gen.set_state(state["gen_state"])
        perm = torch.randperm(n, generator=gen).tolist()
        starts = list(range(0, n, a.batch))
        for bi in range(state["next_batch"], len(starts)):
            idx = perm[starts[bi]:starts[bi] + a.batch]
            enc = tok([tr_texts[j] for j in idx], padding=True, truncation=True,
                      max_length=MAX_LEN, return_tensors="pt")
            y = torch.tensor([tr_ids[j] for j in idx], dtype=torch.long, device=device)
            opt.zero_grad()
            lg = model(enc["input_ids"].to(device), enc["attention_mask"].to(device))
            loss = loss_fn(lg, y)
            loss.backward()
            opt.step()
            state["run_loss"] += float(loss.item()) * len(idx)
            state["run_n"] += len(idx)
            state["steps"] += 1
            state["next_batch"] = bi + 1
            if state["steps"] % 200 == 0:
                print(f"epoch {e + 1} batch {bi + 1}/{len(starts)} loss "
                      f"{state['run_loss'] / state['run_n']:.4f} ({time.time() - t0:.0f}s)", flush=True)
            if a.save_every and state["steps"] % a.save_every == 0:
                state["wall"] = time.time() - t0
                save_latest()
        # ---- end of epoch: per-epoch weights, selection eval, rolling state ----
        model.eval()
        ep_path = ft / f"epoch-{e + 1}.pt"
        atomic_save({k: v.detach().cpu() for k, v in model.state_dict().items()}, ep_path)
        vl = val_loss(model, tok, device, va_texts, va_ids)
        sm = LM.score_slices(scorer, {"main": main_rows})["main"]
        sel = selection_score(sm, min_recall)
        rec = {"epoch": e + 1, "train_loss": state["run_loss"] / max(1, state["run_n"]),
               "val_loss": vl, "selection": sel, "weights": str(ep_path),
               "wall_s": time.time() - t0}
        state["history"].append(rec)
        print(f"EPOCH {e + 1}/{a.epochs}: train_loss {rec['train_loss']:.4f} val_loss {vl:.4f} "
              f"selection benign@{min_recall:.0%}recall {sel['pooled_benign_rate']:.4f} "
              f"(bare {sel['per_form']['bare']['benign_rate']:.4f}, in-repo "
              f"{sel['per_form']['in-repo']['benign_rate']:.4f})", flush=True)
        model.train()
        state.update(epoch=e + 1, next_batch=0, gen_state=gen.get_state(), run_loss=0.0, run_n=0,
                     wall=time.time() - t0)
        save_latest()

    hist = state["history"]
    best = min(hist, key=lambda h: (h["selection"]["pooled_benign_rate"], h["val_loss"]))
    shutil.copy(best["weights"], ft / "best_model.pt")
    model.load_state_dict(torch.load(ft / "best_model.pt", map_location="cpu", weights_only=True))
    model.to(device)
    sh = LM.score_slices(scorer, {"heldout": held_rows})["heldout"]
    held = selection_score(sh, min_recall)
    for fn in ("tokenizer.json", "tokenizer_config.json", "special_tokens_map.json"):
        src = Path(ckpt_dir) / "tokenizer" / fn
        if src.exists():
            shutil.copy(src, ft / fn)
    cfg = {
        "ticket": "v3 finetune",
        "architecture": {"encoder_desc": desc, "encoder_ckpt": str(ckpt_dir),
                         "pooling": "mean over non-pad tokens", "head": "Linear(768 -> 3)",
                         "labels": list(LABELS), "logit_order": list(LABELS), "max_len": MAX_LEN},
        "training": {"seed": a.seed, "batch": a.batch, "epochs": a.epochs,
                     "optimizer": f"AdamW encoder lr={a.lr_encoder} head lr={a.lr_head} "
                                  f"weight_decay={a.weight_decay}, no scheduler",
                     "loss": f"CrossEntropy label_smoothing={a.label_smoothing} "
                             f"class_weights={a.class_weights} {w}",
                     "class_counts": dict(zip(LABELS, counts)),
                     "selection": f"min pooled benign rate at >= {min_recall} dangerous recall "
                                  "on eval main slice (bare + in-repo), tie-break val loss",
                     "best_epoch": best["epoch"], "history": hist},
        "hashes": {s: stats["sha256"][s] for s in ("train", "validation", "dev")},
        "heldout_report_only": held,
    }
    (ft / "config.json").write_text(json.dumps(cfg, indent=1) + "\n")
    (ft / "train-report.json").write_text(json.dumps({"history": hist, "best_epoch": best["epoch"],
                                                      "heldout": held}, indent=1) + "\n")
    print(f"best epoch {best['epoch']} -> {ft / 'best_model.pt'}")
    print(f"heldout (report only, never selected on): benign@{min_recall:.0%}recall "
          f"{held['pooled_benign_rate']:.4f}")
    return 0


def _sig(a, train_sha, n_train):
    """Resume guard: same data and hyperparameters (epochs may grow)."""
    return json.dumps({"sha": train_sha, "n": n_train, "batch": a.batch,
                       "lr": [a.lr_encoder, a.lr_head], "wd": a.weight_decay,
                       "ls": a.label_smoothing, "cw": a.class_weights, "seed": a.seed},
                      sort_keys=True)


if __name__ == "__main__":
    rc = main()
    sys.stdout.flush()
    sys.stderr.flush()
    os._exit(rc)  # MPS/ORT native teardown can segfault after success (see finetune.py)
