#!/usr/bin/env python3
"""Run laya-guard's testsets against an installed/build rv.

Testsets copied from scs0209/laya-guard eval/ (MIT). Mapping: rv has
allow / deny at `rv test`; laya-guard expects allow / review / block.
We report (a) held = deny for review+block expectations, (b) exact =
deny counts as block, review expectations only match when denied
(Ask and pinned deny are not distinguishable at this door).

Usage: bench.py [--rv PATH] [--guard-mode enforce|observe] [--bundle DIR|none] [--sets shell,incidents,ko]
"""
import argparse, json, os, subprocess, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
SETS = {"shell": "testset_shell.jsonl", "incidents": "testset_incidents.jsonl", "ko": "testset_ko_30.jsonl"}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rv", default=".build/debug/rv")
    ap.add_argument("--guard-mode", default="enforce")
    ap.add_argument("--bundle", default=os.environ.get("RV_LAYA_BUNDLE", ""), help="bundle dir, or none for packs-only")
    ap.add_argument("--sets", default="shell,incidents,ko")
    ap.add_argument("--out", default=None)
    args = ap.parse_args()
    env = dict(os.environ, RV_GUARD_MODE=args.guard_mode, RV_LAYA_BUNDLE="/nonexistent-bundle" if args.bundle == "none" else args.bundle)
    results = []
    for name in args.sets.split(","):
        rows = [json.loads(l) for l in (HERE / SETS[name]).read_text(encoding="utf-8").splitlines() if l.strip()]
        held = exact = kept = 0
        lat = []
        for row in rows:
            t = time.time()
            proc = subprocess.run([args.rv, "test", row["tool_call"]], capture_output=True, text=True, env=env, timeout=120)
            lat.append((time.time() - t) * 1000)
            try:
                decision = json.loads(proc.stdout).get("decision", "?")
            except Exception:
                decision = "error"
            exp = row.get("expected", "any")
            is_held = decision == "deny"
            held += is_held if exp in ("review", "block") else 0
            exact += (exp == "any") or (exp == "allow" and decision == "allow") or (exp == "block" and is_held)
            kept += decision == "allow" if exp == "allow" else 0
            results.append({"set": name, "id": row["id"], "expected": exp, "decision": decision,
                            "tool_call": row["tool_call"][:80], "held": bool(is_held)})
        dangerous = sum(1 for r in rows if r.get("expected") in ("review", "block"))
        benign = sum(1 for r in rows if r.get("expected") == "allow")
        lat.sort()
        print(f"{name}: held {held}/{dangerous} dangerous, kept {kept}/{benign} benign, "
              f"exact {exact}/{len(rows)}, p50 {lat[len(lat)//2]:.0f}ms (guard={args.guard_mode}, bundle={args.bundle or "default"})")
    if args.out:
        Path(args.out).write_text(json.dumps(results, ensure_ascii=False, indent=1), encoding="utf-8")

if __name__ == "__main__":
    main()
