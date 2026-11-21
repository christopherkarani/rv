"""Model scoring backends for the v3 scripts (torch checkpoint or ONNX).

Both return raw logits [N, 3] in LABELS order plus a per-row `truncated`
flag (token count with specials > MAX_LEN), which the decision rule turns
into review-instead-of-allow exactly like the Swift JudgeGate.
"""

import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from laya_v3_common import FORMS, form_text  # noqa: E402

MAX_LEN = 512


def truncated_flags(tokenizer, texts):
    enc = tokenizer(list(texts), truncation=False, add_special_tokens=True)
    return [len(ids) > MAX_LEN for ids in enc["input_ids"]]


class TorchScorer:
    """Fine-tuned checkpoint (state_dict from finetune_v3) on the pinned
    base architecture (finetune.build_ft_model)."""

    def __init__(self, state_path=None, model=None, tokenizer=None, device=None):
        import torch

        if model is None:
            import finetune

            model, tokenizer, device, _, _ = finetune.build_ft_model()
            model.load_state_dict(torch.load(state_path, map_location="cpu", weights_only=True))
            try:
                model.to(device)
            except Exception:
                device = "cpu"
                model.to(device)
        self.model, self.tokenizer, self.device = model, tokenizer, device

    def logits(self, texts, batch=64):
        import torch

        self.model.eval()
        out = []
        with torch.inference_mode():
            for i in range(0, len(texts), batch):
                chunk = list(texts[i:i + batch])
                enc = self.tokenizer(chunk, padding=True, truncation=True, max_length=MAX_LEN,
                                     return_tensors="pt")
                lg = self.model(enc["input_ids"].to(self.device),
                                enc["attention_mask"].to(self.device))
                out.append(lg.float().cpu().numpy())
        return np.concatenate(out, 0) if out else np.zeros((0, 3))


class OnnxScorer:
    def __init__(self, onnx_path, tokenizer_dir):
        import onnxruntime as ort
        from transformers import AutoTokenizer

        self.sess = ort.InferenceSession(str(onnx_path), providers=["CPUExecutionProvider"])
        self.tokenizer = AutoTokenizer.from_pretrained(str(tokenizer_dir))

    def logits(self, texts, batch=32):
        out = []
        for i in range(0, len(texts), batch):
            chunk = list(texts[i:i + batch])
            enc = self.tokenizer(chunk, padding=True, truncation=True, max_length=MAX_LEN,
                                 return_tensors="np")
            feed = {"input_ids": enc["input_ids"].astype(np.int64),
                    "attention_mask": enc["attention_mask"].astype(np.int64)}
            out.append(np.asarray(self.sess.run(None, feed)[0], dtype=np.float64))
        return np.concatenate(out, 0) if out else np.zeros((0, 3))


def make_scorer(backend, model_path, tokenizer_dir=None):
    if backend == "torch":
        return TorchScorer(state_path=model_path)
    if backend == "onnx":
        return OnnxScorer(model_path, tokenizer_dir or Path(model_path).parent)
    raise SystemExit(f"unknown backend {backend}")


def score_slices(scorer, slices, forms=FORMS):
    """slices: {name: [row]} -> same rows with row["logits"][form] and
    row["truncated"][form] filled (one batched pass over all texts)."""
    texts, where = [], []
    for name, rows in slices.items():
        for i, r in enumerate(rows):
            for f in forms:
                if r.get("form") and r["form"] in forms and r["form"] != f:
                    continue  # rows pinned to one input form
                texts.append(form_text(r["command"], f))
                where.append((name, i, f))
    lg = scorer.logits(texts)
    tok = getattr(scorer, "tokenizer", None)
    tr = truncated_flags(tok, texts) if tok is not None else [False] * len(texts)
    out = {name: [dict(r, logits={}, truncated={}) for r in rows] for name, rows in slices.items()}
    for (name, i, f), z, t in zip(where, lg, tr):
        out[name][i]["logits"][f] = [float(x) for x in z]
        out[name][i]["truncated"][f] = bool(t)
    return out
