#!/usr/bin/env python3
"""Build training dataset v3: LAYA_WORK/v3/{train,validation,dev}.jsonl + stats.json.

Labels follow Scripts/laya/training/LABEL_POLICY.md (source precedence,
v1 category relabel, family table). This script is the implementation.

Inputs (all under LAYA_WORK, default ~/CodingProjects/laya-train-work):
  v2/{train,validation}.jsonl     rows {text, command, label}  (prepare_data_v2)
  v3/agent_v3.jsonl               rows {command, label, kind, category}  (gen_agent_v3)
  provenance sidecars (label policy; required unless --heuristic-provenance):
    $SS11_DIR/ss11-{train,validation}.jsonl   (SS11_DIR default LAYA_WORK)
    v1/{train,validation,augment}.jsonl       (prepare_data / augment)
  optional external pools, rows {command, label, source, license}:
    pools/benign.jsonl, pools/dangerous.jsonl   extra rows
    pools/relabel.jsonl                         label overrides for v1 rows
Never read: LAYA_WORK/blind/.

v3 input format spec (training and runtime must match)
-----------------------------------------------------
Input text = command, then only these context lines, each on its own line,
in this order (identical order to v2 and Swift JudgeContext.serialize):

    <command>
    cwd-inside-repo: yes
    agent-touched: <comma-joined agentTouchedFiles, max 8, sorted>
    git: untracked <n>, modified <n>, staged <n>

- `cwd-inside-repo: no` does not exist in v3. The runtime sends the `yes`
  line inside a repo and nothing otherwise. Training assigns the `yes` line
  to exactly P_CWD = 0.5 of each label's base rows (stratified random, so
  INDEPENDENT of label by construction), regardless of source: v1.1's
  gitRemote was a label shortcut (empty gitRemote rows were 97.9% deny).
- `git:` counts are random plausible counts (each 0 w.p. 0.45) on exactly
  P_GIT = 0.35 of each label's base rows, independent of label. Source
  gitStatus counts are discarded: every v1.1 POSIX row has gitStatus and
  all-empty lists were 83% deny, so source counts were a shortcut too.
- `agent-touched:` is kept only from true source context (v1.1
  agentTouchedFiles as serialized by v2); it is never synthesized.
- Context dropout: every base row is emitted bare, plus one context variant
  when its drawn context is non-empty (so 1-2 variants with the SAME
  label). Exception: an `allow` row whose command targets an agent-touched
  path (prepare_data_v2.target_touched) is emitted ONLY with context, since
  its allow depends on it.

Label policy (LABEL_POLICY.md)
------------------------------
- Source precedence per normalized command: agent_v3 / relabel pool >
  v1.1 native > external pools > v1 / augment. The highest tier present
  wins; strictest label only within one tier.
- v1 rows labelled review (category build/pkgman/testing) become allow
  unless keeps_review(command).

Splits
------
- v2 rows keep their split; agent / pool rows follow a v2 split when their
  norm already lives there, else a stable 90/10 hash split.
- dev = 10% of validation base rows, stratified by label, seeded; used by
  calibrate_v3.py for temperature. Dev never overlaps validation or train.
- Block downsampling (train only): block rows from --downsample-sources
  (default v1,v11) are dropped at one shared keep rate until block is
  --block-target (default 0.18) of the final train rows.

Leakage: zero normalized-command overlap with every eval slice (corpus main
+ heldout, fresh/*, critical, redteam, smoke), the four exam sets and the
v1.1 test split; colliding input rows are dropped and the result asserted.

Run: python3 prepare_data_v3.py   (LAYA_WORK / LAYA_EVAL_DIR / SS11_DIR)
"""

import argparse
import hashlib
import json
import math
import os
import random
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from laya_v3_common import (  # noqa: E402
    LABELS, STRICTNESS, assert_no_overlap, check_eval_lock, forbidden_norms,
    laya_work, load_jsonl, normalize, serialize_v3, sha256_file, v3_dir,
    write_jsonl)
from prepare_data_v2 import target_touched  # noqa: E402

SEED = 13
P_CWD = 0.5
P_GIT = 0.35
DEV_FRAC = 0.10
VAL_FRAC = 0.10
SS11_MAP = {"allow": "allow", "ask": "review", "deny": "block"}
TIER = {"agent_v3": 0, "relabel": 0, "v11": 1, "pool": 2, "v1": 3, "augment": 3}

# ------------------------------------------------------------ v1 relabel rule

TRUSTED_HOSTS = (
    "registry.npmjs.org", "registry.yarnpkg.com", "npm.pkg.github.com", "pypi.org",
    "files.pythonhosted.org", "pypi.python.org", "crates.io", "static.crates.io",
    "index.crates.io", "proxy.golang.org", "sum.golang.org", "go.dev", "golang.org",
    "github.com", "api.github.com", "raw.githubusercontent.com",
    "objects.githubusercontent.com", "codeload.github.com", "gitlab.com", "bitbucket.org",
    "rubygems.org", "repo1.maven.org", "repo.maven.apache.org", "plugins.gradle.org",
    "services.gradle.org", "dl.google.com", "maven.google.com", "registry-1.docker.io",
    "docker.io", "ghcr.io", "quay.io", "formulae.brew.sh", "nodejs.org", "deno.land",
    "jsr.io", "sh.rustup.rs", "static.rust-lang.org", "swift.org", "download.swift.org",
    "cocoapods.org", "cdn.cocoapods.org", "packagist.org", "hex.pm", "pub.dev",
    "nuget.org", "api.nuget.org", "localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]",
)
URL_RE = re.compile(r"([a-zA-Z][a-zA-Z0-9+.-]*)://([^/\s'\"`)]+)")
PIPE_SHELL_RE = re.compile(
    r"\|\s*(sudo\s+)?(env\s+\S+=\S+\s+)*((/usr)?/bin/)?"
    r"((ba|z|da|k|fi|c|tc)?sh|python[0-9.]*|perl|ruby|node|php|deno|bun|osascript)\b")
SUBST_FETCH_RE = re.compile(r"(<\(|\$\(|`)\s*(curl|wget|fetch|http)\b")
RISK_MARKERS = (
    "--registry", "--index-url", "--extra-index-url", "--trusted-host", "goproxy=",
    "goinsecure", "gonosumdb", "gonosumcheck", "gosumdb=off", "--insecure",
    "strict-ssl", "sslverify", "node_tls_reject_unauthorized", "--allow-insecure",
    "git+http://", "exfil", "evil", "/upload", "--no-verify-ssl", "eval ",
    "registry=", "index-url=",
)
REDIRECT_OUT_RE = re.compile(r">>?\s*(/etc/|/usr/|/library/|/system/|~/\.|\$home/\.)")


def _host_trusted(host):
    h = host.lower().rsplit("@", 1)[-1]
    if h.startswith("["):
        h = h.split("]")[0] + "]"
    else:
        h = h.split(":")[0]
    return any(h == t or h.endswith("." + t) for t in TRUSTED_HOSTS)


def keeps_review(command):
    """True when a v1 build/pkgman/testing review row must stay review:
    untrusted host, registry/TLS repoint, sudo, sensitive redirect, or
    pipe / substitution into a shell or interpreter (LABEL_POLICY.md)."""
    c = command.lower()
    for scheme, host in URL_RE.findall(command):
        if not _host_trusted(host):
            return True
        local = host.lower().split(":")[0] in ("localhost", "127.0.0.1", "0.0.0.0", "[")
        if scheme.lower() == "http" and not local:
            return True  # plaintext fetch from a registry is still a repoint risk
    if re.search(r"\bcurl\b[^|;&]*\s(-k|--insecure)\b", c):
        return True
    if re.search(r"\bcargo\b[^|;&]*--config\b", c):
        return True
    if re.search(r"(\s-exec\b|--exec\b|\b(ba|z|da)?sh\s+-c\b)", c):
        return True  # exec-smuggling flags (go test -exec, sh -c ...)
    if PIPE_SHELL_RE.search(c) or SUBST_FETCH_RE.search(c):
        return True
    if re.search(r"(^|[\s;&|(])sudo\s", c):
        return True
    if REDIRECT_OUT_RE.search(c):
        return True
    return any(m in c for m in RISK_MARKERS)


# ------------------------------------------------------------ loading

def split_context(row):
    """v2 row -> (command, [context lines])."""
    cmd, text = row["command"], row["text"]
    assert text.startswith(cmd), row
    rest = text[len(cmd):]
    lines = [ln for ln in rest.split("\n") if ln] if rest else []
    return cmd, lines


def touched_of(lines):
    for ln in lines:
        if ln.startswith("agent-touched: "):
            return [t for t in ln[len("agent-touched: "):].split(",") if t]
    return []


def strictest(labels):
    return max(labels, key=lambda l: STRICTNESS[l])


def load_provenance(work, ss11_dir, heuristic):
    """-> dict with v11 {norm: set(labels)}, v1 {norm: set}, augment {norm: set},
    ss11_test norms, mode string."""
    prov = {"v11": defaultdict(set), "v1": defaultdict(set), "augment": defaultdict(set),
            "ss11_test": set(), "mode": "files"}
    need = [ss11_dir / "ss11-train.jsonl", ss11_dir / "ss11-validation.jsonl",
            work / "v1" / "train.jsonl", work / "v1" / "validation.jsonl",
            work / "v1" / "augment.jsonl"]
    missing = [str(p) for p in need if not p.exists()]
    if missing:
        if not heuristic:
            raise SystemExit("provenance files missing (needed by the label policy): "
                             + ", ".join(missing) + "\nRebuild v1 (augment.py, "
                             "prepare_data.py) or pass --heuristic-provenance.")
        prov["mode"] = "heuristic"
        print("WARNING: heuristic provenance (context lines => v1.1, bare => v1)")
    else:
        for split in ("train", "validation"):
            for r in load_jsonl(ss11_dir / f"ss11-{split}.jsonl"):
                if r.get("shell") != "posix":
                    continue
                cmd = (r.get("command") or "").strip()
                lab = SS11_MAP.get(r.get("label"))
                if cmd and lab:
                    prov["v11"][normalize(cmd)].add(lab)
        aug = {normalize(r["text"]): r["label"] for r in load_jsonl(work / "v1" / "augment.jsonl")}
        for k, v in aug.items():
            prov["augment"][k].add(v)
        for split in ("train", "validation"):
            for r in load_jsonl(work / "v1" / f"{split}.jsonl"):
                k = normalize(r["text"])
                if k not in aug:
                    prov["v1"][k].add(r["label"])
    test = ss11_dir / "ss11-test.jsonl"
    if test.exists():
        prov["ss11_test"] = {normalize((r.get("command") or "").strip())
                             for r in load_jsonl(test) if (r.get("command") or "").strip()}
    return prov


def load_pool(path, kind):
    rows = []
    if not path.exists():
        return rows
    for r in load_jsonl(path):
        cmd = (r.get("command") or "").strip()
        lab = r.get("label")
        if lab not in STRICTNESS or not cmd:
            raise SystemExit(f"bad pool row in {path}: {r}")
        rows.append({"command": cmd, "label": lab, "source": r.get("source") or "unknown",
                     "license": r.get("license") or "unknown", "pool": kind})
    return rows


def stable_split(norm, frac=VAL_FRAC):
    h = int(hashlib.sha256(norm.encode()).hexdigest()[:8], 16)
    return "validation" if h % 1000 < frac * 1000 else "train"


# ------------------------------------------------------------ core

def build_entries(v2, agent, pools, relabel, prov):
    """-> (entries list, policy counters). Entry: {norm, command, label,
    source, tier, split, touched}."""
    ents = []
    pol = Counter()
    relabel_map = {}
    for r in relabel:
        relabel_map.setdefault(normalize(r["command"]), []).append(r["label"])
    v2_split = {}
    for split, rows in v2.items():
        for row in rows:
            cmd, lines = split_context(row)
            norm = normalize(cmd)
            v2_split[norm] = split
            touched = touched_of(lines)
            srcs = []
            if prov["mode"] == "files":
                if norm in prov["v11"]:
                    srcs.append(("v11", strictest(prov["v11"][norm])))
                if norm in prov["v1"]:
                    srcs.append(("v1", strictest(prov["v1"][norm])))
                if norm in prov["augment"]:
                    srcs.append(("augment", strictest(prov["augment"][norm])))
                if not srcs:
                    pol["v2_row_without_provenance"] += 1
                    srcs.append(("v11" if lines else "v1", row["label"]))
            else:
                srcs.append(("v11" if lines else "v1", row["label"]))
            for src, lab in srcs:
                if src == "v1" and lab == "review" and not keeps_review(cmd):
                    lab = "allow"
                    pol["v1_category_review_to_allow"] += 1
                elif src == "v1" and lab == "review":
                    pol["v1_category_review_kept"] += 1
                if src in ("v1", "augment") and norm in relabel_map:
                    new = strictest(relabel_map[norm])
                    if new != lab:
                        pol["relabel_pool_override"] += 1
                    lab = new
                ents.append({"norm": norm, "command": cmd, "label": lab, "source": src,
                             "tier": TIER[src], "split": split, "touched": touched})
            if prov["mode"] == "files" and srcs:
                labs = {l for _, l in srcs}
                if len(labs) > 1:
                    pol["v2_cross_source_label_disagreement"] += 1
    for r in agent:
        norm = normalize(r["command"])
        ents.append({"norm": norm, "command": r["command"], "label": r["label"],
                     "source": "agent_v3", "tier": TIER["agent_v3"],
                     "split": v2_split.get(norm) or stable_split(norm), "touched": []})
    for r in pools:
        norm = normalize(r["command"])
        ents.append({"norm": norm, "command": r["command"], "label": r["label"],
                     "source": f"pool:{r['source']}", "tier": TIER["pool"],
                     "split": v2_split.get(norm) or stable_split(norm), "touched": [],
                     "license": r["license"]})
    return ents, pol


def resolve(ents):
    """One base row per norm. -> (base rows, conflict stats, samples)."""
    by = defaultdict(list)
    for e in ents:
        by[e["norm"]].append(e)
    base, conf, samples = [], Counter(), []
    for norm in sorted(by):
        es = by[norm]
        top = min(e["tier"] for e in es)
        win = [e for e in es if e["tier"] == top]
        label = strictest([e["label"] for e in win])
        labs_all = {e["label"] for e in es}
        if len(labs_all) > 1:
            lost = sorted({e["source"].split(":")[0] for e in es if e["tier"] != top})
            conf["cross_source" if lost else "within_source_strictest"] += 1
            if lost:
                conf[f"won_by_{win[0]['source'].split(':')[0]}"] += 1
            if len(samples) < 12:
                samples.append({"norm": norm, "kept": label,
                                "by_source": sorted({(e["source"], e["label"]) for e in es})})
        rep = sorted(win, key=lambda e: (e["label"] != label, e["source"]))[0]
        touched = next((e["touched"] for e in es if e["touched"]), [])
        splits = {e["split"] for e in es}
        split = "train" if "train" in splits else rep["split"]
        base.append({"norm": norm, "command": rep["command"], "label": label,
                     "source": rep["source"], "split": split, "touched": touched,
                     "license": rep.get("license")})
    return base, conf, samples


def stratified_dev(val_rows, rng, frac=DEV_FRAC):
    by = defaultdict(list)
    for r in val_rows:
        by[r["label"]].append(r)
    dev = set()
    for lab in LABELS:
        rs = sorted(by[lab], key=lambda r: r["norm"])
        rng.shuffle(rs)
        dev |= {r["norm"] for r in rs[:int(round(frac * len(rs)))]}
    return dev


def downsample_block(train, target, sources, rng):
    """Drop block rows from `sources` at one keep rate so block share of the
    train BASE rows is <= target. Returns (kept rows, info)."""
    n = len(train)
    blocks = [r for r in train if r["label"] == "block"]
    eligible = [r for r in blocks if r["source"].split(":")[0] in sources]
    b, others = len(blocks), n - len(blocks)
    info = {"target": target, "sources": sorted(sources), "before_block_share": b / n if n else 0}
    # want (b - d) / (n - d) = target  ->  d = (b - target*n) / (1 - target)
    need = max(0, math.ceil((b - target * n) / (1 - target))) if target < 1 else 0
    if need > len(eligible):
        info["warning"] = (f"cannot reach target: need to drop {need}, only "
                           f"{len(eligible)} eligible block rows")
        need = len(eligible)
    elig = sorted(eligible, key=lambda r: r["norm"])
    rng.shuffle(elig)
    drop = {r["norm"] for r in elig[:need]}
    kept = [r for r in train if r["norm"] not in drop]
    by_src = Counter(r["source"].split(":")[0] for r in elig[:need])
    info.update({"dropped": need, "dropped_by_source": dict(sorted(by_src.items())),
                 "keep_rate_eligible": 1 - need / len(eligible) if eligible else 1.0,
                 "after_block_share": (b - need) / (n - need) if n - need else 0,
                 "others": others})
    return kept, info


def draw_git(rng):
    def one(hi):
        return 0 if rng.random() < 0.45 else rng.randint(1, hi)
    return (one(14), one(22), one(9))


def stratified_flags(base, rate, rng):
    """Exactly round(rate * n_label) rows per label get True (order-free):
    the flag is independent of label by construction, not just in expectation."""
    by = defaultdict(list)
    for i, r in enumerate(base):
        by[r["label"]].append(i)
    flags = [False] * len(base)
    for lab in sorted(by):
        idx = by[lab][:]
        rng.shuffle(idx)
        for i in idx[:int(round(rate * len(idx)))]:
            flags[i] = True
    return flags


def expand(base, rng):
    """Context dropout: bare + one context variant (same label)."""
    out = []
    cwd_f = stratified_flags(base, P_CWD, rng)
    git_f = stratified_flags(base, P_GIT, rng)
    for r, cwd, has_git in zip(base, cwd_f, git_f):
        git = draw_git(rng) if has_git else None
        touched = r["touched"]
        ctx_text = serialize_v3(r["command"], cwd, touched, git)
        has_ctx = ctx_text != r["command"]
        ctx_only = bool(touched) and r["label"] == "allow" and target_touched(r["command"], touched)
        shape = {"cwd": cwd, "git": git is not None, "git_zero": git == (0, 0, 0),
                 "touched": bool(touched)}
        if not ctx_only:
            out.append({"text": r["command"], "command": r["command"], "label": r["label"],
                        "shape": {"bare": True, "cwd": False, "git": False, "git_zero": False,
                                  "touched": False}, "src": r["source"]})
        if has_ctx:
            out.append({"text": ctx_text, "command": r["command"], "label": r["label"],
                        "shape": dict(shape, bare=False), "src": r["source"]})
    return out


def shape_table(rows):
    tab = {}
    for lab in LABELS:
        rs = [r for r in rows if r["label"] == lab]
        n = len(rs)
        tab[lab] = {"n": n, **{k: (100.0 * sum(r["shape"][k] for r in rs) / n if n else 0.0)
                               for k in ("bare", "cwd", "git", "git_zero", "touched")}}
    return tab


def chi2_label_independence(rows, key):
    """Pearson chi-square of shape[key] x label, df=2, p = exp(-x/2)."""
    obs = {lab: [0, 0] for lab in LABELS}
    for r in rows:
        obs[r["label"]][1 if r["shape"][key] else 0] += 1
    n = sum(sum(v) for v in obs.values())
    if n == 0:
        return 0.0, 1.0
    col = [sum(obs[l][j] for l in LABELS) for j in (0, 1)]
    x = 0.0
    for l in LABELS:
        rt = sum(obs[l])
        for j in (0, 1):
            e = rt * col[j] / n
            if e > 0:
                x += (obs[l][j] - e) ** 2 / e
    return x, math.exp(-x / 2)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--heuristic-provenance", action="store_true",
                    help="allow missing ss11/v1 sidecars (context lines => v1.1)")
    ap.add_argument("--block-target", type=float, default=0.18,
                    help="block share of final train rows (policy range 0.15-0.20; "
                         "<=0 disables downsampling)")
    ap.add_argument("--downsample-sources", default="v1,v11")
    ap.add_argument("--max-shape-spread", type=float, default=2.0,
                    help="max points between labels for cwd/git/git-zero rates (train)")
    a = ap.parse_args(argv)
    check_eval_lock(who="prepare_data_v3")
    work = laya_work()
    out_dir = v3_dir()
    ss11_dir = Path(os.path.expanduser(os.environ.get("SS11_DIR", str(work))))
    rng = random.Random(SEED)

    v2 = {s: load_jsonl(work / "v2" / f"{s}.jsonl") for s in ("train", "validation")}
    agent_p = out_dir / "agent_v3.jsonl"
    if not agent_p.exists():
        raise SystemExit(f"{agent_p} missing: run gen_agent_v3.py first")
    agent = load_jsonl(agent_p)
    pools_dir = work / "pools"
    pools = load_pool(pools_dir / "benign.jsonl", "benign") + \
        load_pool(pools_dir / "dangerous.jsonl", "dangerous")
    relabel = load_pool(pools_dir / "relabel.jsonl", "relabel")
    prov = load_provenance(work, ss11_dir, a.heuristic_provenance)

    extra = {"ss11_test": prov["ss11_test"]} if prov["ss11_test"] else None
    forbidden = forbidden_norms(extra=extra)
    bad = set().union(*forbidden.values())

    ents, pol = build_entries(v2, agent, pools, relabel, prov)
    drop_leak = Counter(e["source"].split(":")[0] for e in ents if e["norm"] in bad)
    ents = [e for e in ents if e["norm"] not in bad]
    base, conf, samples = resolve(ents)

    train = [r for r in base if r["split"] == "train"]
    val_all = [r for r in base if r["split"] == "validation"]
    dev_norms = stratified_dev(val_all, rng)
    val = [r for r in val_all if r["norm"] not in dev_norms]
    dev = [r for r in val_all if r["norm"] in dev_norms]
    ds_info = {"disabled": True}
    if a.block_target > 0:
        train, ds_info = downsample_block(
            train, a.block_target, {s.strip() for s in a.downsample_sources.split(",")}, rng)

    norms = {k: {r["norm"] for r in v} for k, v in (("train", train), ("validation", val), ("dev", dev))}
    assert not (norms["train"] & norms["validation"]), "train/validation overlap"
    assert not (norms["train"] & norms["dev"]), "train/dev overlap"
    assert not (norms["validation"] & norms["dev"]), "validation/dev overlap"
    leak = {s: assert_no_overlap(n, forbidden, f"v3 {s}") for s, n in norms.items()}

    splits = {"train": expand(train, rng), "validation": expand(val, rng), "dev": expand(dev, rng)}
    for s, rows in splits.items():
        for r in rows:
            assert r["text"].startswith(r["command"])
            ctx = r["text"][len(r["command"]):].split("\n")
            assert "cwd-inside-repo: no" not in ctx, r
        rows.sort(key=lambda r: (r["label"], r["text"]))
        write_jsonl(out_dir / f"{s}.jsonl",
                    [{"text": r["text"], "command": r["command"], "label": r["label"]} for r in rows])
    # Text-level leakage too (a text equal to an eval command).
    for s, rows in splits.items():
        assert_no_overlap({normalize(r["text"]) for r in rows}, forbidden, f"v3 {s} text")

    # ---- stats ----
    def balance(rows):
        c = Counter(r["label"] for r in rows)
        n = len(rows)
        return {lab: {"n": c[lab], "pct": 100.0 * c[lab] / n if n else 0.0} for lab in LABELS} | {"total": n}

    shapes = {s: shape_table(rows) for s, rows in splits.items()}
    chi = {s: {k: dict(zip(("chi2", "p"), chi2_label_independence(rows, k)))
               for k in ("cwd", "git", "git_zero", "bare", "touched")}
           for s, rows in splits.items()}
    spread = {k: max(shapes["train"][l][k] for l in LABELS) - min(shapes["train"][l][k] for l in LABELS)
              for k in ("bare", "cwd", "git", "git_zero", "touched")}
    src_counts = {s: dict(sorted(Counter(r["src"].split(":")[0] if not r["src"].startswith("pool:")
                                         else r["src"] for r in rows).items()))
                  for s, rows in splits.items()}
    pool_info = defaultdict(lambda: {"rows_in": 0, "licenses": set(), "kind": set()})
    for r in pools + relabel:
        pi = pool_info[r["source"]]
        pi["rows_in"] += 1
        pi["licenses"].add(r["license"])
        pi["kind"].add(r["pool"])
    pool_info = {k: {"rows_in": v["rows_in"], "licenses": sorted(v["licenses"]),
                     "kind": sorted(v["kind"])} for k, v in sorted(pool_info.items())}
    stats = {
        "spec": "v3 (see prepare_data_v3 docstring / README Dataset v3)",
        "label_policy": "Scripts/laya/training/LABEL_POLICY.md",
        "params": {"seed": SEED, "p_cwd": P_CWD, "p_git": P_GIT, "dev_frac": DEV_FRAC,
                   "val_frac_new_rows": VAL_FRAC, "block_target": a.block_target,
                   "downsample_sources": a.downsample_sources},
        "provenance_mode": prov["mode"],
        "inputs": {"v2_train": len(v2["train"]), "v2_validation": len(v2["validation"]),
                   "agent_v3": len(agent), "pools": len(pools), "relabel": len(relabel),
                   "v11_norms": len(prov["v11"]), "v1_norms": len(prov["v1"]),
                   "augment_norms": len(prov["augment"])},
        "pools": pool_info,
        "policy": dict(sorted(pol.items())),
        "conflicts": dict(sorted(conf.items())),
        "conflict_samples": samples,
        "dropped_eval_exam_collisions_by_source": dict(sorted(drop_leak.items())),
        "block_downsample": ds_info,
        "base_rows": {"train": len(train), "validation": len(val), "dev": len(dev)},
        "class_balance": {s: balance(rows) for s, rows in splits.items()},
        "context_shape_by_label_pct": shapes,
        "context_shape_spread_train_pts": spread,
        "chi2_shape_x_label": chi,
        "rows_by_source": src_counts,
        "leakage": leak,
        "sha256": {s: sha256_file(out_dir / f"{s}.jsonl") for s in splits},
    }
    (out_dir / "stats.json").write_text(json.dumps(stats, indent=1) + "\n", encoding="utf-8")

    # ---- prints ----
    print(f"provenance: {prov['mode']}; policy: {dict(pol)}")
    print(f"conflicts: {dict(conf)}; eval/exam collisions dropped: {dict(drop_leak)}")
    print(f"block downsample: {ds_info}")
    print("class balance:")
    for s, b in stats["class_balance"].items():
        print(f"  {s:10s} total={b['total']:6d} " + " ".join(
            f"{lab}={b[lab]['n']} ({b[lab]['pct']:.1f}%)" for lab in LABELS))
    print("context shape by label (% of rows; train / validation / dev):")
    print(f"  {'split':10s} {'label':7s} {'n':>6s} {'bare':>6s} {'cwd-yes':>8s} {'git':>6s} "
          f"{'git000':>7s} {'touched':>8s}")
    for s, tab in shapes.items():
        for lab in LABELS:
            t = tab[lab]
            print(f"  {s:10s} {lab:7s} {t['n']:6d} {t['bare']:6.1f} {t['cwd']:8.1f} {t['git']:6.1f} "
                  f"{t['git_zero']:7.1f} {t['touched']:8.1f}")
    print("train spread across labels (pts): " + " ".join(f"{k}={v:.2f}" for k, v in spread.items()))
    print("chi2 (train, df=2): " + " ".join(
        f"{k}={v['chi2']:.2f}(p={v['p']:.3f})" for k, v in chi["train"].items()))
    for s in splits:
        print(f"leakage {s}: PASS (" + " ".join(f"{k}=0" for k in leak[s]) + ")")
    for k in ("cwd", "git", "git_zero"):
        p = chi["train"][k]["p"]
        if spread[k] > a.max_shape_spread and p < 0.01:
            raise SystemExit(f"context shape '{k}' differs by {spread[k]:.2f} pts across labels "
                             f"(> {a.max_shape_spread}, chi2 p={p:.4f}): context is not "
                             "label-independent")
    if a.block_target > 0:
        got = stats["class_balance"]["train"]["block"]["pct"] / 100
        if abs(got - a.block_target) > 0.01:
            raise SystemExit(f"train block share {got:.3f} misses target {a.block_target} by > 1pt "
                             f"({ds_info.get('warning', '')})")
    print(f"wrote {out_dir}/{{train,validation,dev}}.jsonl + stats.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
