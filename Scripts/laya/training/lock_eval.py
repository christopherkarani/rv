#!/usr/bin/env python3
"""Write (or verify) Scripts/laya/eval/LOCK.json: the sha256 of every file
under the eval dir (gates.json "lock" rule).

  python3 lock_eval.py            write LOCK.json (only in a commit that adds
                                  a new fresh round, BEFORE that round trains)
  python3 lock_eval.py --check    exit 1 and list problems if the lock fails

Every v3 data / training / eval script calls
laya_v3_common.check_eval_lock() at startup and refuses to run on a missing
or changed file. LAYA_EVAL_DIR overrides the eval dir.
"""

import argparse
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from laya_v3_common import LOCK_NAME, compute_lock, eval_dir, lock_problems  # noqa: E402


def write_lock(root):
    root = Path(root)
    files = compute_lock(root)
    doc = {"rule": "sha256 of every file under this directory; data, training "
                   "and eval scripts refuse to run when a file is missing from "
                   "this list or its hash differs. Regenerate only in a commit "
                   "that adds a new fresh round, before that round trains.",
           "files": files}
    (root / LOCK_NAME).write_text(json.dumps(doc, indent=1, sort_keys=True) + "\n",
                                  encoding="utf-8")
    return files


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--dir", default=None, help="eval dir (default LAYA_EVAL_DIR "
                    "or Scripts/laya/eval)")
    a = ap.parse_args()
    root = Path(a.dir) if a.dir else eval_dir()
    if a.check:
        probs = lock_problems(root)
        for p in probs:
            print(p)
        print("LOCK " + ("FAIL" if probs else "OK") + f" ({root})")
        return 1 if probs else 0
    files = write_lock(root)
    for rel, h in files.items():
        print(f"{h[:16]}  {rel}")
    print(f"wrote {root / LOCK_NAME} ({len(files)} files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
