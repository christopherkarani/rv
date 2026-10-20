#!/usr/bin/env python3
"""Ticket 5a -- quantize + convert the verified fine-tuned Laya judge.

Inputs (verified, do not re-derive):
  /tmp/laya-train/ft/best_model.pt      (fp32 state_dict, Linear->3 [allow, review, block])
  /tmp/laya-train/ft/model.onnx(+data)  (fp32 reference, 1.23 GB)
  /tmp/laya-train/ft/tokenizer.json     (byte-identical family to the Swift LayaTokenizer)
  /tmp/laya-train/v2/{train,validation}.jsonl (hashes d8e153ea / 5cd0c2b0)
  Scripts/laya/{testset_shell,testset_incidents,testset_ko_30}.jsonl
  Scripts/laya/adversarial-suffixes.jsonl

Outputs:
  /tmp/laya-train/ft/golden.json              (parity oracle: fp32 torch probs)
  /tmp/laya-train/ft/model-fp16.onnx(+data)   (fp16, target <= 650 MB total)
  /tmp/laya-train/ft/coreml/model.mlpackage   (fp16 CoreML, enumerated seq lengths)
  /tmp/laya-train/ft/coreml/tokenizer.json + config.json (bundle sidecars)

Input format (training and runtime must match):
  text = command + optional context lines (README Dataset v2 spec);
  token ids = HF tokenizer with specials == [BOS=2] + raw ids (no specials) + [EOS=1],
  max 512 tokens total (content prefix 510). Exams ship command-only (no context).

Run:
  cd Scripts/laya/training &&
  PYTHONPATH=/tmp/laya-pylibs:/tmp/laya-torchlibs /tmp/laya-venv/bin/python convert_ft.py

Exit 0 on success. Drift numbers are PRINTED (PASS/FAIL markers); the script
does not widen tolerances -- report them honestly (ticket gates M1/M2).
"""

import hashlib
import json
import shutil
import sys
import time
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

FT_DIR = Path("/tmp/laya-train/ft")
COREML_DIR = FT_DIR / "coreml"
ONNX_FP16 = FT_DIR / "model-fp16.onnx"
GOLDEN_PATH = FT_DIR / "golden.json"
PT_PATH = FT_DIR / "best_model.pt"

TRAIN_PATH = Path("/tmp/laya-train/v2/train.jsonl")
VAL_PATH = Path("/tmp/laya-train/v2/validation.jsonl")
EXPECTED_HASH = {"train": "d8e153ea", "validation": "5cd0c2b0"}

EXAM_PATHS = {
    "shell": (HERE / "../testset_shell.jsonl").resolve(),
    "incidents": (HERE / "../testset_incidents.jsonl").resolve(),
    "ko": (HERE / "../testset_ko_30.jsonl").resolve(),
    "adversarial": (HERE / "../adversarial-suffixes.jsonl").resolve(),
}

LABELS = ["allow", "review", "block"]
MAX_LEN = 512
LENGTHS = [16, 32, 64, 96, 128, 192, 256, 384, 512]
N_VAL_GOLDEN = 200
DRIFT_TOL = 0.03
ARGMAX_TOL = 0.99


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


def bucket(n):
    for L in LENGTHS:
        if L >= n:
            return L
    return LENGTHS[-1]


def softmax_np(logits):
    z = np.asarray(logits, dtype=np.float64)
    z = z - z.max(axis=-1, keepdims=True)
    e = np.exp(z)
    return e / e.sum(axis=-1, keepdims=True)


def split_metrics(y_true, y_pred):
    """Ticket 2 definitions: exact forgives review->block; held over
    {review, block}; kept over allow; 'any' always exact, never held/kept."""
    exact = held = held_n = kept = kept_n = 0
    for t, p in zip(y_true, y_pred):
        ok = t == "any" or p == t or (t == "review" and p == "block")
        exact += 1 if ok else 0
        if t in ("review", "block"):
            held_n += 1
            held += 1 if p in ("review", "block") else 0
        if t == "allow":
            kept_n += 1
            kept += 1 if p == "allow" else 0
    n = len(y_true)
    return {"exact": [exact, n], "held": [held, held_n], "kept": [kept, kept_n]}


def fmt(pair):
    return f"{pair[0]}/{pair[1]}"


def build_golden_rows():
    """All exam rows (command-only, __meta__ excluded) + first 200 validation
    rows sorted by text. Returns (rows, texts) where each row has
    {set, command, text, expected} (probs attached later)."""
    exam_rows = {n: load_rows(p) for n, p in EXAM_PATHS.items()}
    exam_rows = {n: [r for r in rows if r.get("tool_call") != "__meta__"]
                for n, rows in exam_rows.items()}
    rows = []
    for name in ("shell", "incidents", "ko", "adversarial"):
        for r in exam_rows[name]:
            cmd = (r.get("tool_call") or "").strip()
            if not cmd:
                continue
            rows.append({"set": name, "command": cmd, "text": cmd,
                         "expected": r.get("expected", "any")})
    val_rows = load_rows(VAL_PATH)
    val_sorted = sorted(val_rows, key=lambda r: r["text"])[:N_VAL_GOLDEN]
    print(f"validation rows: {len(val_rows)} total, golden takes first "
          f"{len(val_sorted)} sorted by text")
    for r in val_sorted:
        rows.append({"set": "validation", "command": r["command"],
                     "text": r["text"], "expected": r["label"]})
    return rows


def torch_probs(texts, model, tokenizer, device, batch=32):
    import torch

    model.eval()
    out = []
    with torch.inference_mode():
        for i in range(0, len(texts), batch):
            chunk = texts[i:i + batch]
            enc = tokenizer(chunk, padding=True, truncation=True,
                            max_length=MAX_LEN, return_tensors="pt")
            logits = model(enc["input_ids"].to(device),
                           enc["attention_mask"].to(device))
            probs = torch.softmax(logits.float(), dim=-1).cpu().numpy()
            out.append(probs)
    return np.concatenate(out, axis=0) if out else np.zeros((0, 3))


def drift_report(name, ref_probs, got_probs):
    ref = np.asarray(ref_probs, dtype=np.float64)
    got = np.asarray(got_probs, dtype=np.float64)
    max_drift = float(np.abs(ref - got).max())
    ref_arg = ref.argmax(axis=1)
    got_arg = got.argmax(axis=1)
    agree = float((ref_arg == got_arg).mean()) if len(ref) else 1.0
    ok = max_drift <= DRIFT_TOL and agree >= ARGMAX_TOL
    print(f"DRIFT {name}: max prob drift {max_drift:.4f} "
          f"(tol {DRIFT_TOL}) | argmax agreement {agree * 100:.2f}% "
          f"(tol {ARGMAX_TOL * 100:.0f}%) -> {'PASS' if ok else 'FAIL'}",
          flush=True)
    return max_drift, agree, ok


def export_onnx_fp16(model_fp32_cpu, tokenizer, out_path):
    """Export an fp16 ONNX graph. Tries plain fp16 first; if export fails or
    ORT cannot run it, falls back to mixed precision with LayerNorm +
    classifier kept in fp32. Returns (mode, out_path) with mode in
    {'fp16', 'mixed-layernorm-fp32'}. Raises on total failure."""
    import copy

    import torch

    def _export(model, path):
        model.eval()
        dummy = tokenizer(["export shape probe", "second row | sh"],
                          padding=True, truncation=True, max_length=MAX_LEN,
                          return_tensors="pt")
        args = (dummy["input_ids"], dummy["attention_mask"])
        if path.exists():
            path.unlink()
        data_p = Path(str(path) + ".data")
        if data_p.exists():
            data_p.unlink()
        torch.onnx.export(
            model, args, str(path),
            input_names=["input_ids", "attention_mask"],
            output_names=["logits"],
            dynamic_axes={
                "input_ids": {0: "batch", 1: "seq"},
                "attention_mask": {0: "batch", 1: "seq"},
                "logits": {0: "batch"},
            },
            opset_version=18,
        )

    def _ort_logits(path, tokenizer, texts):
        import onnxruntime as ort

        sess = ort.InferenceSession(str(path),
                                    providers=["CPUExecutionProvider"])
        logits_all = []
        for i in range(0, len(texts), 32):
            chunk = texts[i:i + 32]
            enc = tokenizer(chunk, padding=True, truncation=True,
                            max_length=MAX_LEN, return_tensors="pt")
            feed = {
                "input_ids": enc["input_ids"].numpy().astype(np.int64),
                "attention_mask": enc["attention_mask"].numpy().astype(np.int64),
            }
            logits_all.append(sess.run(None, feed)[0])
        return np.concatenate(logits_all, axis=0) if logits_all else np.zeros((0, 3))

    probe = ["ls -la", "git status | sh",
             "rm -rf ./dist --no-preserve-root / --no-preserve-root"]
    # Attempt 1: plain fp16.
    try:
        m = copy.deepcopy(model_fp32_cpu).to(torch.float16)
        m.eval()
        _export(m, out_path)
        got = _ort_logits(out_path, tokenizer, probe)
        assert np.isfinite(got).all(), "non-finite logits in plain-fp16 probe"
        print("ONNX fp16: plain-fp16 export + ORT probe ok "
              "(all layernorms fp16)", flush=True)
        return "fp16", out_path
    except Exception as e:
        print(f"ONNX fp16: plain-fp16 path failed ({type(e).__name__}: {e}); "
              "falling back to mixed precision (LayerNorm + head fp32).",
              flush=True)
    # Attempt 2: mixed precision -- LayerNorms and the classifier stay fp32.
    m = copy.deepcopy(model_fp32_cpu).to(torch.float16)
    n_ln = 0
    for mod in m.modules():
        if isinstance(mod, torch.nn.LayerNorm):
            mod.float()
            n_ln += 1
    if hasattr(m, "classifier"):
        m.classifier.float()
    m.eval()
    print(f"ONNX fp16: keeping {n_ln} LayerNorm modules + classifier in fp32",
          flush=True)
    _export(m, out_path)
    got = _ort_logits(out_path, tokenizer, probe)
    assert np.isfinite(got).all(), "non-finite logits in mixed-precision probe"
    print("ONNX fp16: mixed-precision export + ORT probe ok", flush=True)
    return "mixed-layernorm-fp32", out_path


def onnx_fp16_probs(texts, tokenizer, onnx_path, batch=32):
    import onnxruntime as ort

    sess = ort.InferenceSession(str(onnx_path),
                                providers=["CPUExecutionProvider"])
    in_spec = [(i.name, i.shape, i.type) for i in sess.get_inputs()]
    out_spec = [(o.name, o.shape, o.type) for o in sess.get_outputs()]
    print(f"ONNX fp16 inputs: {in_spec} outputs: {out_spec}", flush=True)
    outs = []
    for i in range(0, len(texts), batch):
        chunk = texts[i:i + batch]
        enc = tokenizer(chunk, padding=True, truncation=True,
                        max_length=MAX_LEN, return_tensors="pt")
        feed = {
            "input_ids": enc["input_ids"].numpy().astype(np.int64),
            "attention_mask": enc["attention_mask"].numpy().astype(np.int64),
        }
        logits = sess.run(None, feed)[0]
        outs.append(softmax_np(np.asarray(logits, dtype=np.float64)))
    return np.concatenate(outs, axis=0) if outs else np.zeros((0, 3))


def _patch_mask_combinators():
    """Replace masking_utils.and/or_masks with new_ones/new_zeros-free
    equivalents. The originals seed the fold with
    ``q_idx.new_ones(())`` / ``new_zeros(())`` (masking_utils.py:50), an op
    coremltools' torch frontend does not implement. Folding from the first
    mask function is exactly equivalent (AND/OR identity elements; every
    call site passes >= 1 function), so converted numerics are unaffected
    -- the in-script drift check verifies this."""
    import transformers.masking_utils as mu

    def and_masks(*fns):
        assert len(fns) >= 1, "and_masks needs >= 1 function"
        def and_mask(batch_idx, head_idx, q_idx, kv_idx):
            result = fns[0](batch_idx, head_idx, q_idx, kv_idx)
            for fn in fns[1:]:
                result = result & fn(batch_idx, head_idx, q_idx, kv_idx).to(result.device)
            return result
        return and_mask

    def or_masks(*fns):
        assert len(fns) >= 1, "or_masks needs >= 1 function"
        def or_mask(batch_idx, head_idx, q_idx, kv_idx):
            result = fns[0](batch_idx, head_idx, q_idx, kv_idx)
            for fn in fns[1:]:
                result = result | fn(batch_idx, head_idx, q_idx, kv_idx).to(result.device)
            return result
        return or_mask

    mu.and_masks = and_masks
    mu.or_masks = or_masks


def convert_coreml(model_fp32_cpu, out_pkg):
    """Trace the fp32 torch graph to an FP16 mlpackage with enumerated
    sequence lengths. Inputs int32, output logits float."""
    import torch
    import torch.nn as nn

    import coremltools as ct

    class Int32Wrapper(nn.Module):
        def __init__(self, base):
            super().__init__()
            self.base = base

        def forward(self, input_ids, attention_mask):
            return self.base(input_ids.to(torch.int64),
                             attention_mask.to(torch.int64))

    model_fp32_cpu.eval()
    _patch_mask_combinators()
    wrapped = Int32Wrapper(model_fp32_cpu).eval()
    # coremltools 9 auto-detects TorchScript (ScriptModule) or an
    # ExportedProgram; plain nn.Modules are rejected. The EXIR path chokes
    # on this graph (aten new_ones from masking_utils.and_masks), so trace
    # to TorchScript -- the mature frontend -- and declare the enumerated
    # input shapes at convert time.
    example_ids = torch.randint(0, 1000, (1, 64), dtype=torch.int32)
    example_mask = torch.ones((1, 64), dtype=torch.int32)
    with torch.no_grad():
        traced = torch.jit.trace(wrapped, (example_ids, example_mask),
                                 strict=False)
        traced = torch.jit.freeze(traced)
    shapes = [(1, s) for s in LENGTHS]
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="input_ids",
                          shape=ct.EnumeratedShapes(shapes),
                          dtype=np.int32),
            ct.TensorType(name="attention_mask",
                          shape=ct.EnumeratedShapes(shapes),
                          dtype=np.int32),
        ],
        outputs=[ct.TensorType(name="logits", dtype=np.float32)],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        # The bundle runs on macOS (Package.swift floor is macOS 15);
        # iOS18 encoded the same floor only implicitly.
        minimum_deployment_target=getattr(ct.target, "macOS15", ct.target.iOS18),
    )
    if out_pkg.exists():
        shutil.rmtree(out_pkg)
    mlmodel.save(str(out_pkg))
    return mlmodel


def coreml_probs(texts, tokenizer, mlmodel, batch_note=""):
    """Run golden texts through the converted CoreML model via predict."""
    probs = []
    for idx, text in enumerate(texts):
        enc = tokenizer([text], padding=False, truncation=True,
                        max_length=MAX_LEN, return_tensors="np")
        ids = [int(x) for x in enc["input_ids"][0].tolist()]
        L = bucket(len(ids))
        # Swift parity: [BOS] already present from HF specials; pad to bucket.
        arr_ids = np.zeros((1, L), dtype=np.int32)
        arr_mask = np.zeros((1, L), dtype=np.int32)
        arr_ids[0, :len(ids)] = np.asarray(ids, dtype=np.int32)
        arr_mask[0, :len(ids)] = 1
        out = mlmodel.predict({"input_ids": arr_ids,
                               "attention_mask": arr_mask})
        logits = None
        for v in out.values():
            logits = np.asarray(v, dtype=np.float64).reshape(-1)
            break
        assert logits is not None and logits.size == 3, f"bad logits {out.keys()}"
        probs.append(softmax_np(logits).reshape(-1))
        if (idx + 1) % 50 == 0:
            print(f"  coreml predict {idx + 1}/{len(texts)}{batch_note}",
                  flush=True)
    return np.stack(probs, axis=0) if probs else np.zeros((0, 3))


def dir_size(path):
    total = 0
    if path.is_file():
        return path.stat().st_size
    for p in path.rglob("*"):
        if p.is_file() and not p.is_symlink():
            total += p.stat().st_size
    return total


def main():
    t0 = time.time()
    h_train = sha_prefix(TRAIN_PATH)
    h_val = sha_prefix(VAL_PATH)
    print(f"train hash {h_train} (expect {EXPECTED_HASH['train']})", flush=True)
    print(f"validation hash {h_val} (expect {EXPECTED_HASH['validation']})", flush=True)
    assert h_train == EXPECTED_HASH["train"], "train hash mismatch -- STOP"
    assert h_val == EXPECTED_HASH["validation"], "validation hash mismatch -- STOP"
    assert PT_PATH.exists(), f"missing {PT_PATH}"

    import torch

    import finetune

    print("loading fine-tuned model (fp32)...", flush=True)
    model, tokenizer, device, ckpt, desc = finetune.build_ft_model()
    model.load_state_dict(torch.load(PT_PATH, map_location="cpu",
                                     weights_only=True))
    model.to("cpu")
    model.eval()
    print(f"model loaded: {desc} | eval on cpu for golden", flush=True)

    rows = build_golden_rows()
    texts = [r["text"] for r in rows]
    print(f"golden rows: {len(rows)} "
          f"({sum(1 for r in rows if r['set'] == 'validation')} validation + "
          f"{sum(1 for r in rows if r['set'] != 'validation')} exams)", flush=True)

    print("computing fp32 golden probs...", flush=True)
    ref = torch_probs(texts, model, tokenizer, "cpu")
    for r, p in zip(rows, ref.tolist()):
        r["probs"] = [float(x) for x in p]
    GOLDEN_PATH.write_text(json.dumps({"labels": LABELS, "rows": rows},
                                      ensure_ascii=False) + "\n")
    print(f"golden wrote {GOLDEN_PATH} ({len(rows)} rows)", flush=True)

    # Torch exam scores (argmax on fp32 probs) -- must match verified numbers.
    def _preds(idxs):
        return [LABELS[int(np.argmax(ref[i]))] for i in idxs]

    for name in ("shell", "incidents", "ko", "adversarial"):
        idxs = [i for i, r in enumerate(rows) if r["set"] == name]
        m = split_metrics([rows[i]["expected"] for i in idxs],
                          _preds(idxs))
        print(f"[torch-fp32] {name:11s} exact {fmt(m['exact'])} | "
              f"held {fmt(m['held'])} | kept {fmt(m['kept'])}", flush=True)
    vidx = [i for i, r in enumerate(rows) if r["set"] == "validation"]
    print(f"[torch-fp32] golden-validation-subset exact "
          f"(informational only; full-validation number lives in metrics.json)",
          flush=True)

    # ONNX fp16.
    print("exporting ONNX fp16...", flush=True)
    onnx_mode, _ = export_onnx_fp16(model, tokenizer, ONNX_FP16)
    print("scoring ONNX fp16 vs golden...", flush=True)
    got_onnx = onnx_fp16_probs(texts, tokenizer, ONNX_FP16)
    d_onnx, a_onnx, ok_onnx = drift_report("onnx-fp16", ref, got_onnx)

    # CoreML fp16.
    print(f"converting CoreML fp16 {LENGTHS} ...", flush=True)
    COREML_DIR.mkdir(parents=True, exist_ok=True)
    mlmodel = convert_coreml(model, COREML_DIR / "model.mlpackage")
    print("scoring CoreML vs golden (predict, CPU)...", flush=True)
    got_coreml = coreml_probs(texts, tokenizer, mlmodel)
    d_coreml, a_coreml, ok_coreml = drift_report("coreml-fp16", ref, got_coreml)

    # Drift gates are gates, not reports: a failing bundle must never
    # reach the sidecar copy below (which is what makes it installable).
    if not (ok_onnx and ok_coreml):
        raise SystemExit(
            f"drift gate FAIL (onnx ok={ok_onnx}, coreml ok={ok_coreml}); "
            "bundle sidecars withheld"
        )

    # Bundle sidecars.
    shutil.copy(FT_DIR / "tokenizer.json", COREML_DIR / "tokenizer.json")
    cfg = {
        "labels": LABELS,
        "logit_order": LABELS,
        "max_len": MAX_LEN,
        "lengths": LENGTHS,
        "checkpoint": "laya-ft-v2-fp16",
        "source": {
            "train_hash": h_train,
            "validation_hash": h_val,
            "best_model_sha256_prefix": sha_prefix(PT_PATH),
            "tokenizer_sha256_prefix": sha_prefix(FT_DIR / "tokenizer.json"),
            "onnx_fp16_mode": onnx_mode,
        },
    }
    (COREML_DIR / "config.json").write_text(json.dumps(cfg, indent=1) + "\n")

    def _mb(n):
        return f"{n / 1e6:.1f} MB"

    ml_sz = dir_size(COREML_DIR / "model.mlpackage")
    onnx_sz = ONNX_FP16.stat().st_size
    onnx_data = Path(str(ONNX_FP16) + ".data")
    if onnx_data.exists():
        onnx_sz += onnx_data.stat().st_size
    print(f"SIZE coreml model.mlpackage: {_mb(ml_sz)}", flush=True)
    print(f"SIZE onnx fp16 total (model + .data): {_mb(onnx_sz)} "
          f"(target <= 650 MB) -> "
          f"{'PASS' if onnx_sz <= 650_000_000 else 'FAIL'}", flush=True)
    print(f"drift coreml max={d_coreml:.4f} argmax={a_coreml * 100:.2f}% "
          f"{'PASS' if ok_coreml else 'FAIL'}", flush=True)
    print(f"drift onnx-fp16 max={d_onnx:.4f} argmax={a_onnx * 100:.2f}% "
          f"{'PASS' if ok_onnx else 'FAIL'}", flush=True)
    if onnx_sz > 650_000_000:
        raise SystemExit(f"size gate FAIL: onnx bundle {_mb(onnx_sz)} > 650 MB")
    print(f"done in {time.time() - t0:.0f}s", flush=True)


if __name__ == "__main__":
    main()
