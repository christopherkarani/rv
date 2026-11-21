"""Shared plumbing for the v3 Laya judge pipeline (pure Python, no torch).

Paths
  LAYA_WORK      work root (default ~/CodingProjects/laya-train-work). Every
                 v3 artifact lives under LAYA_WORK/v3. Never /tmp.
  LAYA_EVAL_DIR  eval directory (default Scripts/laya/eval in this repo):
                 corpus.json, critical.jsonl, redteam.jsonl, smoke.jsonl,
                 fresh/round-N.jsonl, gates.json, baseline-v2/, LOCK.json.

Eval lock (gates.json "lock" rule)
  Every file under the eval dir is listed with its sha256 in LOCK.json
  (written by lock_eval.py). check_eval_lock() runs at the start of every
  v3 data/training/eval script and refuses to continue when a file is
  missing from LOCK.json, a locked file is missing, or a hash differs.

Overlap rule
  Training data must share zero normalized commands
  (prepare_data_v2.normalize) with every eval slice (main, heldout,
  fresh/*, critical, redteam, smoke) and the four exam sets.

v3 input format (training and runtime must match; see README "Dataset v3"):
  <command>
  cwd-inside-repo: yes                 (only ever "yes"; the "no" line is gone)
  agent-touched: <comma-joined, sorted, max 8>
  git: untracked <n>, modified <n>, staged <n>
  Same line order as v2 / Swift JudgeContext.serialize; a line is omitted
  when unknown. The bare command is a valid input.
"""

import hashlib
import json
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from prepare_data_v2 import normalize  # noqa: E402  (single source of truth)

LAYA_ROOT = HERE.parent  # Scripts/laya
LABELS = ("allow", "review", "block")
LAB2ID = {lab: i for i, lab in enumerate(LABELS)}
STRICTNESS = {"allow": 0, "review": 1, "block": 2}

# Input forms scored by the gates (gates.json "scoring.inputs").
FORMS = ("bare", "in-repo")
FORM_LINES = {"bare": [], "in-repo": ["cwd-inside-repo: yes"]}

EXAM_FILES = {
    "testset_shell": LAYA_ROOT / "testset_shell.jsonl",
    "testset_incidents": LAYA_ROOT / "testset_incidents.jsonl",
    "testset_ko_30": LAYA_ROOT / "testset_ko_30.jsonl",
    "adversarial": LAYA_ROOT / "adversarial-suffixes.jsonl",
}
LOCK_NAME = "LOCK.json"


def laya_work():
    return Path(os.path.expanduser(
        os.environ.get("LAYA_WORK", "~/CodingProjects/laya-train-work")))


def v3_dir():
    return laya_work() / "v3"


def eval_dir():
    return Path(os.path.expanduser(
        os.environ.get("LAYA_EVAL_DIR", str(LAYA_ROOT / "eval"))))


def form_text(command, form):
    return "\n".join([command] + FORM_LINES[form])


def serialize_v3(command, cwd_inside_repo=False, touched=None, git=None):
    """v3 serializer. cwd_inside_repo True -> 'yes' line, False -> no line
    (there is no 'no' line in v3). touched: list of paths. git: (u, m, s)
    tuple or None."""
    lines = [command]
    if cwd_inside_repo:
        lines.append("cwd-inside-repo: yes")
    t = sorted(touched or [])
    if t:
        lines.append("agent-touched: " + ",".join(t[:8]))
    if git is not None:
        u, m, s = git
        lines.append(f"git: untracked {u}, modified {m}, staged {s}")
    return "\n".join(lines)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def load_jsonl(path):
    rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def write_jsonl(path, rows):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    os.replace(tmp, path)


# ---------------------------------------------------------------- lock

def eval_files(root):
    """Relative posix paths of every regular file under root except
    LOCK.json itself (dotfiles like .DS_Store are ignored)."""
    root = Path(root)
    out = []
    for p in sorted(root.rglob("*")):
        if not p.is_file() or p.name == LOCK_NAME:
            continue
        rel = p.relative_to(root).as_posix()
        if any(part.startswith(".") for part in rel.split("/")):
            continue
        out.append(rel)
    return out


def compute_lock(root):
    root = Path(root)
    return {rel: sha256_file(root / rel) for rel in eval_files(root)}


def lock_problems(root):
    """List of human-readable problems; empty means the lock holds."""
    root = Path(root)
    lock_p = root / LOCK_NAME
    if not root.is_dir():
        return [f"eval dir {root} does not exist"]
    if not lock_p.exists():
        return [f"{lock_p} missing (run lock_eval.py in a lock commit)"]
    locked = json.loads(lock_p.read_text(encoding="utf-8")).get("files", {})
    actual = compute_lock(root)
    probs = []
    for rel in sorted(set(actual) - set(locked)):
        probs.append(f"not in LOCK.json: {rel}")
    for rel in sorted(set(locked) - set(actual)):
        probs.append(f"locked file missing: {rel}")
    for rel in sorted(set(actual) & set(locked)):
        if actual[rel] != locked[rel]:
            probs.append(f"hash changed: {rel}")
    return probs


def check_eval_lock(root=None, who="script"):
    """Refuse to run unless every eval file is locked and unchanged.
    LAYA_SKIP_EVAL_LOCK=1 is honored ONLY for unit tests (prints loudly)."""
    root = Path(root) if root else eval_dir()
    if os.environ.get("LAYA_SKIP_EVAL_LOCK") == "1":
        print(f"[{who}] WARNING: eval lock check SKIPPED (test mode)",
              file=sys.stderr)
        return
    probs = lock_problems(root)
    if probs:
        msg = "\n  ".join(probs[:20])
        raise SystemExit(f"[{who}] eval lock FAILED for {root}:\n  {msg}\n"
                         "Refusing to run (gates.json lock rule).")
    print(f"[{who}] eval lock OK ({len(compute_lock(root))} files, {root})")


# ---------------------------------------------------------------- slices

def _row(r, slice_name, i):
    cmd = (r.get("command") or r.get("tool_call") or "").strip()
    return {
        "id": r.get("id") or f"{slice_name}-{i:04d}",
        "set": r.get("set") or "dangerous",
        "category": r.get("category") or "uncategorized",
        "command": cmd,
        "expect": r.get("expect") or r.get("expected"),
        "form": r.get("form"),
        "slice": slice_name,
    }


def load_eval_slices(root=None, require_corpus=True):
    """{slice: [row]} for main, heldout, fresh/<stem>, critical, redteam,
    smoke. Rows: {id, set, category, command, expect, form, slice}.
    Missing optional files are simply absent from the dict."""
    root = Path(root) if root else eval_dir()
    out = {}
    corpus = root / "corpus.json"
    if corpus.exists():
        rows = json.loads(corpus.read_text(encoding="utf-8"))
        out["main"] = [_row(r, "main", i) for i, r in enumerate(rows)
                       if not r.get("heldout")]
        out["heldout"] = [_row(r, "heldout", i) for i, r in enumerate(rows)
                          if r.get("heldout")]
    elif require_corpus:
        raise SystemExit(f"{corpus} missing: the eval corpus is required")
    fresh = root / "fresh"
    if fresh.is_dir():
        for p in sorted(fresh.glob("*.jsonl")):
            name = f"fresh/{p.stem}"
            out[name] = [_row(r, name, i) for i, r in enumerate(load_jsonl(p))]
    for name in ("critical", "redteam", "smoke"):
        p = root / f"{name}.jsonl"
        if p.exists():
            out[name] = [_row(r, name, i) for i, r in enumerate(load_jsonl(p))]
    for name, rows in out.items():
        for r in rows:
            if not r["command"]:
                raise SystemExit(f"empty command in eval slice {name}: {r}")
    return out


def exam_norms():
    out = {}
    for name, path in EXAM_FILES.items():
        keys = set()
        for r in load_jsonl(path):
            t = (r.get("tool_call") or "").strip()
            if t and t != "__meta__":
                keys.add(normalize(t))
        out[name] = keys
    return out


def forbidden_norms(root=None, extra=None):
    """{source_name: set(norm)} for every eval slice + the four exam sets
    (+ extra dict, e.g. the ss11 test split)."""
    sets = {f"eval:{k}": {normalize(r["command"]) for r in v}
            for k, v in load_eval_slices(root).items()}
    sets.update({f"exam:{k}": v for k, v in exam_norms().items()})
    if extra:
        sets.update(extra)
    return sets


def overlap_report(norms, forbidden):
    """{source: sorted hits} for every forbidden source (all keys present)."""
    norms = set(norms)
    return {k: sorted(norms & v) for k, v in forbidden.items()}


def assert_no_overlap(norms, forbidden, what):
    rep = overlap_report(norms, forbidden)
    bad = {k: v for k, v in rep.items() if v}
    if bad:
        detail = "; ".join(f"{k}: {len(v)} e.g. {v[:3]}" for k, v in bad.items())
        raise AssertionError(f"OVERLAP {what} vs eval/exams: {detail}")
    return {k: 0 for k in rep}
