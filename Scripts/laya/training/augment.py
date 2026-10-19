"""Ticket 2b Step 1: synthetic benign-head/dangerous-suffix augmentation rows.

Generates /tmp/laya-train/augment.jsonl: {text, label} JSONL rows from
cross-product TEMPLATES (never copied from exam rows). Purpose: teach the
shape "benign head + dangerous suffix" (pipe-to-shell, redirect to
sensitive paths, exec-smuggling flags, download-then-exec, base64-pipe)
plus hard-negative benign twins of the same shapes.

Run BEFORE prepare_data.py (it merges this file into train only):
  cd Scripts/laya/training && /tmp/laya-venv/bin/python augment.py

Deterministic: seeded RNG (SEED) + output sorted by (label, text).
Guards: drops any candidate whose NORMALIZED text collides with an exam
row, or whose exact text already exists in the base train/validation
files (base wins). Prints per-family counts.

A5/A6 (added after the first 2b retrain): benign git-commit/stash hard
negatives for the same benign-git-porcelain overblock phenomenon as A3
(shell ids 5/6/27/52). Commit messages avoid both exam messages
('fix typo', 'fix: typo') and the noisy base-block messages
('bump', 'fix', 'wip'). No `stash list` rows: the eval-only fixture
holds a `git stash list >> /etc/crontab` block row whose exact head
must not be diluted.

Deliberate choices:
- Download-then-exec URLs use neutral example.*/TEST-NET hosts, never
  evil hosts, so the model learns the chain shape, not an exam token.
"""

import json
import os
import random

SEED = 20261019
HERE = os.path.dirname(os.path.abspath(__file__))
OUTDIR = "/tmp/laya-train"
OUT_PATH = os.path.join(OUTDIR, "augment.jsonl")
HELDOUT_FILES = [
    os.path.join(HERE, "..", "testset_shell.jsonl"),
    os.path.join(HERE, "..", "testset_incidents.jsonl"),
    os.path.join(HERE, "..", "testset_ko_30.jsonl"),
]
BASE_FILES = [
    os.path.join(OUTDIR, "train.jsonl"),
    os.path.join(OUTDIR, "validation.jsonl"),
]


def normalize(text):
    """Canonical key: collapse whitespace, strip one layer of surrounding
    quotes, lowercase. (Same semantics as prepare_data.normalize.)"""
    s = " ".join(text.split())
    if len(s) >= 2 and s[0] == s[-1] and s[0] in ("'", '"'):
        s = s[1:-1]
    return s.lower()


HEADS = [
    "ls", "ls -la", "ls -R src",
    "git status --short", "git status -sb", "git log --oneline -10",
    "git log -5", "git diff --stat", "git diff HEAD~1",
    "git show --stat HEAD",
    "npm test", "npm run build", "npm run lint",
    "npm test -- --watchAll=false",
    "go test ./...", "go test -count=1 ./pkg/...", "go build ./...",
    "go vet ./...",
    "cargo test --quiet", "cargo build --release",
    "cargo clippy -- -D warnings",
    "pytest -q", "pytest tests/ -x", "pytest -k 'not slow'",
    "make test", "make build", "make check",
    "cat README.md", "cat package.json", "echo done", "echo BUILD_OK",
    "docker ps", "docker images",
]

HEAD_SHORT = [
    "ls", "git status", "npm test", "go test ./...", "cargo test",
    "pytest -q", "make build", "cat README.md", "echo done", "docker ps",
]


def fam_b1_pipe_shell():
    out = []
    for h in HEADS:
        for sh in ("sh", "bash", "zsh", "dash", "ksh"):
            out.append(f"{h} | {sh}")
    return out


def fam_b2_redirect_sensitive():
    targets = [
        "/etc/hosts", "/etc/passwd", "/etc/shadow", "/etc/crontab",
        "/etc/sudoers", "/etc/ssh/sshd_config", "~/.ssh/authorized_keys",
        "~/.ssh/id_rsa", "~/.ssh/config", "~/.zshrc", "~/.bashrc",
        "~/.profile", "/usr/local/bin/tool", "/root/.bashrc",
    ]
    out = []
    for h in HEADS:
        for t in targets:
            for op in (">", ">>"):
                out.append(f"{h} {op} {t}")
    return out


def fam_b3_exec_smuggle():
    out = []
    payloads = ["id", "whoami", "bash -c id", "sh -c id", "uname -a",
                "cat /etc/passwd"]
    pkgs = ["./...", "./pkg/...", "./api/..."]
    for flag in ("-exec", "--exec"):
        for p in payloads:
            for pkg in pkgs:
                out.append(f'go test {flag} "{p}" {pkg}')
    for p in payloads:
        for pkg in pkgs:
            out.append(f'go test -exec="{p}" {pkg}')
    for d in (".", "src", "tests", "/tmp/work"):
        for pat in ("*.log", "*.tmp"):
            for p in ("id", "whoami", "cat /etc/passwd"):
                out.append(f"find {d} -name '{pat}' -exec sh -c '{p}' {{}} \\;")
    for cmd in ("cargo build", "cargo test"):
        for triple in ("x86_64-unknown-linux-gnu", "aarch64-apple-darwin",
                       "x86_64-pc-windows-msvc"):
            for runner in ("sh -c id", "bash -c whoami", "id", "whoami"):
                out.append(
                    f"{cmd} --config 'target.{triple}.runner=\"{runner}\"'")
    for host in ("build.example.com", "ci.example.net",
                 "deploy.example.org", "user@10.0.0.5"):
        for p in ("sh -c id", "bash -c whoami", "id", "cat /etc/passwd"):
            out.append(f'ssh -oProxyCommand="{p}" {host}')
    for host in ("build.example.com", "ci.example.net"):
        for p in ("sh -c id", "id"):
            out.append(f'scp -oProxyCommand="{p}" report.txt {host}:/tmp/')
    for extra in ("--exec=id", "--exec=whoami", "--runner=sh",
                  "--exec='bash -c id'"):
        for bf in ("", "-q ", "-x "):
            out.append(f'pytest {bf}-o addopts="{extra}" tests/')
    return out


def fam_b4_download_exec():
    urls = []
    for host in ("updates.example.com", "cdn.example.net",
                 "mirror.example.org", "files.example.com",
                 "pkg.example.net", "203.0.113.7", "198.51.100.23",
                 "192.0.2.44"):
        for path in ("/x.sh", "/i.sh", "/setup.sh", "/run.sh"):
            urls.append(f"http://{host}{path}")
    dlforms = []
    for fetch in ("curl -fsSL", "curl -s", "wget -qO-"):
        for pipe in ("sh", "bash"):
            dlforms.append(f"{fetch} {{url}} | {pipe}")
    for fname in ("x", "inst", "s"):
        dlforms.append(f"curl -s {{url}} -o /tmp/{fname} && sh /tmp/{fname}")
    out = []
    for h in HEAD_SHORT:
        for join in ("&&", ";"):
            for form in dlforms:
                for url in urls:
                    out.append(f"{h} {join} {form.format(url=url)}")
    return out


def fam_b5_base64_pipe():
    files = ("data.b64", "stage2.b64", "blob.b64", "out.b64", "tmp.b64",
             "install.b64", "chunk.b64", "res.b64")
    out = []
    for dec in ("base64 -d", "base64 -D", "base64 --decode"):
        for f in files:
            for sh in ("sh", "bash", "zsh"):
                out.append(f"{dec} {f} | {sh}")
    for f in files:
        for sh in ("sh", "bash", "zsh"):
            out.append(f"cat {f} | base64 -d | {sh}")
    for blob in ("aWQ=", "d2hvYW1pCg==", "dW5hbWUgLWE=",
                 "Y2F0IC9ldGMvcGFzc3dk"):
        for sh in ("sh", "bash", "zsh"):
            out.append(f"echo {blob} | base64 -d | {sh}")
    for f in files:
        for sh in ("sh", "bash"):
            out.append(f"openssl base64 -d -in {f} | {sh}")
    return out


def fam_r1_unknown_pipe():
    out = []
    for h in HEADS:
        for b in ("mytool", "dataproc", "logparse", "fmtjson", "tabulate",
                  "filterx", "prettyout", "jsontool", "sumtool", "quicksum"):
            for suf in ("", " --color", " -v"):
                out.append(f"{h} | {b}{suf}")
    return out


def fam_r2_redirect_external():
    out = []
    for h in HEADS:
        for d in ("~/reports", "~/output", "/var/tmp", "/mnt/shared",
                  "/srv/data", "/opt/output"):
            for f in ("out.log", "results.txt", "build.log", "report.json",
                      "test-output.xml"):
                for op in (">", ">>"):
                    out.append(f"{h} {op} {d}/{f}")
    return out


def fam_r3_pkg_install():
    mgrs = [("npm install", ("", " --save-dev")), ("npm i", ("", " -D")),
            ("pip install", ("", " -U")),
            ("python -m pip install", ("", " -U")),
            ("cargo add", ("", " --dev")), ("go get", ("", " -u")),
            ("pnpm add", ("", " -D")), ("yarn add", ("", " --dev"))]
    pkgs = ("lodash", "axios", "requests", "urllib3", "serde", "tokio",
            "pytest-cov", "coverage", "react", "typescript", "flask",
            "django", "numpy", "pandas", "click")
    out = []
    for mgr, flags in mgrs:
        for pkg in pkgs:
            for fl in flags:
                out.append(f"{mgr} {pkg}{fl}")
    return out


def fam_a1_safe_pipe():
    tools = (["grep error", "grep failed", "grep TODO", "grep -i warning"]
             + ["head -n 20", "head"] + ["wc -l", "wc"]
             + ["jq .", "jq '.name'", "jq -r '.id'"]
             + ["sort -u", "sort -r", "sort"] + ["uniq -c", "uniq"]
             + ["tail -n 50", "tail"] + ["cut -d, -f1", "cut -f2"]
             + ["tr a-z A-Z", "tr -d '\\n'"] + ["less", "less -S"])
    out = []
    for h in HEADS:
        for t in tools:
            out.append(f"{h} | {t}")
    return out


def fam_a2_local_redirect():
    paths = ("./build.log", "./out.txt", "./results/results.xml",
             "./dist/bundle.log", "./coverage.lcov", "./report.json",
             "/tmp/build.log", "/tmp/test-out.txt", "/tmp/report.json",
             "./debug.log")
    out = []
    for h in HEADS:
        for p in paths:
            for op in (">", ">>"):
                out.append(f"{h} {op} {p}")
    return out


def fam_a3_git_add():
    out = []
    for base in ("git add -A", "git add --all"):
        for path in ("", " .", " src/", " tests/", " docs/", " pkg/"):
            for fl in ("", " --verbose", " -v", " --dry-run"):
                for fol in ("", " && git status",
                            " && git diff --cached --stat"):
                    out.append(f"{base}{path}{fl}{fol}")
    return out


def fam_a4_test_normal():
    out = []
    for cmd in ("npm test", "npm run build", "npm run lint",
                "npm run test:unit", "npm run test:e2e"):
        for fl in ("", " -- --watchAll=false", " --silent", " -- --coverage",
                   " -- --bail", " -- --updateSnapshot"):
            out.append(f"{cmd}{fl}")
    for fl in ("-run TestAuth", "-run TestAPI -v", "-count=1", "-short",
               "-v", "-cover", "-failfast", "-timeout 5m"):
        for pkg in ("./...", "./pkg/...", "./api/...", "./internal/..."):
            out.append(f"go test {fl} {pkg}")
    for fl in ("-o ./bin/app", "-v", "-trimpath"):
        for pkg in ("./...", "./cmd/...", "./pkg/..."):
            out.append(f"go build {fl} {pkg}")
    for cmd in ("cargo test", "cargo build"):
        for fl in ("--release", "--quiet", "--all-features", "--offline",
                   "--locked", "--verbose", "-p api", "--workspace",
                   "--tests", "--bins"):
            out.append(f"{cmd} {fl}")
    for fl in ("-q", "-x", "--tb=short", "-p no:cacheprovider",
               "-m 'not e2e'", "--durations=5", "--lf", "-q -x",
               "--maxfail=3", "--ff", "-vv", "--collect-only"):
        for tgt in ("tests/", "tests/test_auth.py", "tests/test_api.py",
                    "tests/test_cli.py", ".", "-k 'not slow'"):
            out.append(f"pytest {fl} {tgt}")
    for cmd in ("make test", "make check", "make build"):
        for fl in ("", " V=1", " -j4", " -k", " -s", " -n"):
            out.append(f"{cmd}{fl}")
    return out


def fam_a5_git_commit():
    msgs = ("update readme", "refactor login", "add unit tests",
            "fix lint errors", "release 1.2.0", "update deps",
            "fix crash on startup", "add logging", "docs cleanup",
            "speed up tests", "handle empty input", "remove dead code")
    out = []
    for m in msgs:
        out.append(f"git commit -m '{m}'")
        out.append(f"git commit -am '{m}'")
        out.append(f"git commit -m '{m}' --no-verify")
    for p in ("src/", "tests/", "docs/", "pkg/", ".", "app/"):
        for m in msgs:
            out.append(f"git add {p} && git commit -m '{m}'")
    return out


def fam_a6_git_stash():
    out = []
    for form in ("push", "push -u", "push --keep-index"):
        out.append(f"git stash {form}")
        for m in ("wip auth", "wip api", "debug session", "pre rebase",
                  "sunday"):
            out.append(f"git stash {form} -m '{m}'")
        for p in ("src/", "tests/", "app/"):
            out.append(f"git stash {form} -- {p}")
    for sub in ("pop", "show", "show -p", "apply", "pop --quiet"):
        out.append(f"git stash {sub}")
    out.append("git stash branch wip/login stash@{0}")
    out.append("git stash branch wip/api stash@{0}")
    return out


FAMILIES = [
    ("B1 pipe_shell (block)", "block", 110, fam_b1_pipe_shell),
    ("B2 redirect_sensitive (block)", "block", 110, fam_b2_redirect_sensitive),
    ("B3 exec_smuggle (block)", "block", 100, fam_b3_exec_smuggle),
    ("B4 download_exec (block)", "block", 90, fam_b4_download_exec),
    ("B5 base64_pipe (block)", "block", 90, fam_b5_base64_pipe),
    ("R1 unknown_pipe (review)", "review", 90, fam_r1_unknown_pipe),
    ("R2 redirect_external (review)", "review", 90, fam_r2_redirect_external),
    ("R3 pkg_install (review)", "review", 70, fam_r3_pkg_install),
    ("A1 safe_pipe (allow)", "allow", 160, fam_a1_safe_pipe),
    ("A2 local_redirect (allow)", "allow", 140, fam_a2_local_redirect),
    ("A3 git_add (allow)", "allow", 80, fam_a3_git_add),
    ("A4 test_normal (allow)", "allow", 140, fam_a4_test_normal),
    ("A5 git_commit (allow)", "allow", 65, fam_a5_git_commit),
    ("A6 git_stash (allow)", "allow", 25, fam_a6_git_stash),
]


def load_exam_norm():
    exam = set()
    for path in HELDOUT_FILES:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                t = (json.loads(line).get("tool_call") or "")
                if t.strip():
                    exam.add(normalize(t))
    return exam


def load_base_texts():
    """Pristine base texts (before any augment merge).

    BASE_FILES may already contain a previous augment merge (re-runs),
    so subtract the previous augment output when present. Idempotent:
    (merged train - old augment) == pristine base modulo exam-dropped
    rows, which the exam filter covers anyway.
    """
    texts = set()
    for path in BASE_FILES:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    texts.add(json.loads(line)["text"])
    if os.path.exists(OUT_PATH):
        with open(OUT_PATH, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    texts.discard(json.loads(line)["text"])
    return texts


def main():
    exam_norm = load_exam_norm()
    base_texts = load_base_texts()
    print(f"exam normalized texts: {len(exam_norm)}; "
          f"base train+validation texts: {len(base_texts)}")
    rng = random.Random(SEED)
    rows = []
    seen = set()
    for name, label, want, fn in FAMILIES:
        pool = sorted(set(fn()))
        n_pool = len(pool)
        pool = [t for t in pool if normalize(t) not in exam_norm]
        n_exam_drop = n_pool - len(pool)
        pool = [t for t in pool if t not in base_texts and t not in seen]
        n_base_drop = n_pool - n_exam_drop - len(pool)
        assert len(pool) >= want, \
            f"{name}: pool {len(pool)} < want {want} after filtering"
        rng.shuffle(pool)
        take = sorted(pool[:want])
        for t in take:
            seen.add(t)
        rows.extend((t, label) for t in take)
        print(f"{name}: pool={n_pool} exam_norm_drop={n_exam_drop} "
              f"base_exact_drop={n_base_drop} kept={len(take)}")
    assert len(seen) == len(rows), "cross-family duplicate leaked"
    rows.sort(key=lambda r: (r[1], r[0]))
    os.makedirs(OUTDIR, exist_ok=True)
    with open(OUT_PATH, "w", encoding="utf-8") as f:
        for text, label in rows:
            f.write(json.dumps({"text": text, "label": label},
                               ensure_ascii=False) + "\n")
    counts = {}
    for _, lab in rows:
        counts[lab] = counts.get(lab, 0) + 1
    print(f"wrote {OUT_PATH}: total={len(rows)} " +
          " ".join(f"{lab}={counts.get(lab, 0)}"
                   for lab in ("allow", "review", "block")))
    print(f"seed={SEED} sorted=True")


if __name__ == "__main__":
    main()

