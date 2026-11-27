#!/usr/bin/env python3
"""Scripts/hook-replay.py — replay the command corpus through a live rvd.

Starts a throwaway rvd (its own HOME and XDG_RUNTIME_DIR), sends every corpus
command as a Claude Code PreToolUse Bash payload, cycling until --calls is
reached, and reports per-call latency, decisions, harness failures, agreement
with the corpus's expected verdicts, and rvd's memory and descriptor use.

Two clients:
  --client rv      (default) spawn `rv hook --host claude` per call: the real
                   hook path an agent pays for, process start included.
  --client socket  talk rv.ipc.v1 to the socket directly through the Python
                   SDK (sdk/python): rvd's own cost, no process start.

The `rv` used must sit next to the `rvd` it talks to: the client refuses an
rvd whose /proc/<pid>/exe is not its own sibling, and that refusal is a deny.

Usage:
  swift build -c release --product rvd && swift build -c release --product rv
  Scripts/hook-replay.py --bin-dir .build/release --calls 10000 --concurrency 8

Exit status: 0 when every call got an allow or deny from rvd and the optional
--max-p99-ms holds; 1 otherwise. Disagreement with the corpus is reported but
does not fail the run: the corpus pins day-one pack verdicts (some cases need
catalog packs or the door), while a live rvd runs the default config.

Wire facts this relies on (see sdk/WIRE.md, Sources/RVHooks):
  allow          -> empty stdout, exit 0
  deny / ask     -> {"hookSpecificOutput": {"permissionDecision": "deny", ...}}
  rvd unreachable-> permissionDecision "ask" (RV_HOOK_WHEN_DOWN default), which
                    this harness counts as a failure, never a verdict.
"""
from __future__ import annotations

import argparse
import collections
import concurrent.futures as cf
import glob
import json
import os
import random
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from dataclasses import dataclass, field

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CORPUS_GLOBS = [
    "Tests/RVEngineTests/Fixtures/corpus/*.json",
    "Tests/RVCorpusTests/disk-rule-coverage.json",
]


# ---------------------------------------------------------------- corpus

@dataclass(frozen=True)
class Case:
    source: str
    case_id: str
    command: str
    expected: str | None  # "allow" | "deny" | None (no wire expectation)


def wire_expectation(expected: object) -> str | None:
    """Map a corpus `expected` to what the Claude hook wire can show."""
    if expected == "allow":
        return "allow"
    if expected in ("deny", "self-protection", "indeterminate"):
        return "deny"  # indeterminate and self-protection both deny on the wire
    return None


def load_corpus(root: str) -> list[Case]:
    cases: list[Case] = []
    for pattern in CORPUS_GLOBS:
        for path in sorted(glob.glob(os.path.join(root, pattern))):
            with open(path, encoding="utf-8") as fh:
                doc = json.load(fh)
            entries = doc.get("cases", doc) if isinstance(doc, dict) else doc
            if not isinstance(entries, list):
                continue
            name = os.path.basename(path)
            for i, entry in enumerate(entries):
                if not isinstance(entry, dict):
                    continue
                command = entry.get("command")
                if not isinstance(command, str) or not command or "\0" in command:
                    continue
                cases.append(Case(name, str(entry.get("id", i)), command, wire_expectation(entry.get("expected"))))
    return cases


# ---------------------------------------------------------------- rvd

class Daemon:
    def __init__(self, rvd: str, workdir: str, extra_env: dict[str, str] | None = None):
        self.home = os.path.join(workdir, "home")
        self.runtime = os.path.join(workdir, "run")
        self.cwd = os.path.join(workdir, "project")
        for d in (self.home, self.runtime, self.cwd):
            os.makedirs(d, mode=0o700, exist_ok=True)
            os.chmod(d, 0o700)
        self.socket = os.path.join(self.runtime, "rv", "evaluate.sock")
        if len(self.socket.encode()) + 1 > 108:
            raise SystemExit(f"socket path too long for AF_UNIX: {self.socket}")
        self.stderr_path = os.path.join(workdir, "rvd.stderr")
        self.env = {
            "HOME": self.home,
            "XDG_RUNTIME_DIR": self.runtime,
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "LANG": "C.UTF-8",
        }
        self._init_project()
        rvd_env = dict(self.env, **(extra_env or {}))
        self._stderr = open(self.stderr_path, "wb")
        try:
            self.proc = subprocess.Popen(
                [rvd, "--idle-exit-seconds", "3600"],
                stdin=subprocess.DEVNULL, stdout=self._stderr, stderr=self._stderr,
                env=rvd_env, start_new_session=True,
            )
        except BaseException:
            self._stderr.close()
            raise
        try:
            deadline = time.monotonic() + 20
            while not os.path.exists(self.socket):
                if self.proc.poll() is not None:
                    raise SystemExit(f"rvd exited during startup (status {self.proc.returncode}); see {self.stderr_path}")
                if time.monotonic() > deadline:
                    raise SystemExit("rvd did not bind its socket within 20 s")
                time.sleep(0.05)
        except BaseException:
            # No Daemon comes back to stop, so never leave this rvd running.
            self.kill()
            raise

    def _init_project(self) -> None:
        """Make the agent's cwd a real repository, as it is for a coding agent.

        rv fails closed on a path it cannot place in a repository ("An
        unresolved repository or path cannot be treated as in-repo"), so an
        empty directory would turn ordinary reads into denies.
        """
        files = {
            "README.md": "# replay fixture\n",
            "package.json": '{"name": "replay-fixture", "scripts": {"test": "echo ok"}}\n',
            "src/main.py": "print('hello')\n",
            "tools/gate.sh": "#!/bin/sh\necho gate\n",
        }
        for rel, text in files.items():
            path = os.path.join(self.cwd, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(text)
        git_env = dict(self.env, GIT_AUTHOR_NAME="replay", GIT_AUTHOR_EMAIL="replay@localhost",
                       GIT_COMMITTER_NAME="replay", GIT_COMMITTER_EMAIL="replay@localhost")
        for argv in (["git", "init", "-q", "-b", "main"], ["git", "add", "-A"],
                     ["git", "commit", "-q", "-m", "fixture"], ["git", "checkout", "-q", "-b", "feature"]):
            subprocess.run(argv, cwd=self.cwd, env=git_env, check=True, capture_output=True)

    def stats(self) -> dict:
        out: dict = {"alive": self.proc.poll() is None}
        try:
            with open(f"/proc/{self.proc.pid}/status") as fh:
                for line in fh:
                    key, _, value = line.partition(":")
                    if key in ("VmRSS", "VmHWM", "Threads"):
                        out[key] = value.strip()
            out["fds"] = len(os.listdir(f"/proc/{self.proc.pid}/fd"))
        except OSError:
            pass
        return out

    def stop(self) -> None:
        if self.proc.poll() is None:
            self.proc.send_signal(signal.SIGTERM)
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        self._stderr.close()

    def kill(self) -> None:
        if self.proc.poll() is None:
            self.proc.kill()
        self.proc.wait()
        self._stderr.close()


# ---------------------------------------------------------------- clients

def payload(command: str, cwd: str, session: str) -> bytes:
    return json.dumps({
        "hook_event_name": "PreToolUse",
        "tool_name": "Bash",
        "tool_input": {"command": command},
        "cwd": cwd,
        "session_id": session,
    }).encode()


STOP_LABELS = ("why     ", "safer   ", "who     ")


def stop_shape_ok(reason: object) -> bool:
    """B1: every stop is `✕ Stopped` + command + (rule id), one why of at
    most nine words, at most one safer line, then exactly one who line that
    asks a person; no line before `who` names an unlock."""
    if not isinstance(reason, str) or "\x1b" in reason:
        return False
    lines = reason.split("\n")
    if len(lines) not in (3, 4) or not lines[0].startswith("\u2715 Stopped   ") or not lines[0].endswith(")"):
        return False
    body = lines[1:]
    if not body[0].startswith("why     ") or len(body[0][8:].split()) > 9:
        return False
    if len(body) == 3 and not body[1].startswith("safer   "):
        return False
    if not body[-1].startswith("who     ask "):
        return False
    return not any("allow-once" in line or "rv unlock" in line for line in lines[1:-1])


def classify(stdout: str, exit_code: int) -> str:
    """allow | deny | down (rvd unreachable/timed out) | badshape (a deny
    whose text is not the one stop shape) | error."""
    if exit_code != 0:
        return "error"
    text = stdout.strip()
    if not text:
        return "allow"
    try:
        parsed = json.loads(text)
        decision = parsed["hookSpecificOutput"]["permissionDecision"]
    except (ValueError, KeyError, TypeError):
        return "error"
    if decision == "deny":
        reason = parsed["hookSpecificOutput"].get("permissionDecisionReason")
        return "deny" if stop_shape_ok(reason) else "badshape"
    if decision == "ask":
        return "down"
    return "error"


class RvClient:
    def __init__(self, rv: str, daemon: Daemon, timeout: float):
        self.rv, self.daemon, self.timeout = rv, daemon, timeout

    def __call__(self, body: bytes) -> tuple[str, str]:
        try:
            done = subprocess.run(
                [self.rv, "hook", "--host", "claude"], input=body, capture_output=True,
                env=self.daemon.env, cwd=self.daemon.cwd, timeout=self.timeout,
            )
        except subprocess.TimeoutExpired:
            return "timeout", ""
        out = done.stdout.decode("utf-8", "replace")
        return classify(out, done.returncode), (done.stderr.decode("utf-8", "replace") + out)[-300:]


class SocketClient:
    def __init__(self, daemon: Daemon, timeout: float, rvd: str):
        # The SDK checks rvd's version through the binary named by RV_RVD.
        os.environ["RV_RVD"] = rvd
        sys.path.insert(0, os.path.join(ROOT, "sdk", "python", "src"))
        from rv.client import Client  # noqa: PLC0415  (SDK lives in the repo)
        self._Client = Client
        self.daemon, self.timeout = daemon, timeout
        self._local = threading.local()

    def _client(self):
        client = getattr(self._local, "client", None)
        if client is None:
            client = self._Client(socket_path=self.daemon.socket, timeout=self.timeout)
            client.connect()
            self._local.client = client
        return client

    def __call__(self, body: bytes) -> tuple[str, str]:
        try:
            reply = self._client().raw.call("hookEvaluate", {"host": "claude", "stdin": body.decode()})
        except Exception as exc:  # noqa: BLE001  (any transport failure is a harness failure)
            failed, self._local.client = getattr(self._local, "client", None), None
            if failed is not None:
                try:
                    failed.close()  # its socket, before the next call reconnects
                except Exception:  # noqa: BLE001, S110
                    pass
            kind = "timeout" if "timed out" in str(exc).lower() or isinstance(exc, TimeoutError) else "error"
            return kind, f"{type(exc).__name__}: {exc}"[:300]
        return classify(reply.get("stdout", ""), int(reply.get("exitCode", -1))), reply.get("stdout", "")[:300]


# ---------------------------------------------------------------- run

@dataclass
class Result:
    case: Case
    outcome: str
    ms: float
    detail: str


@dataclass
class Report:
    results: list[Result] = field(default_factory=list)


def pct(sorted_ms: list[float], p: float) -> float:
    if not sorted_ms:
        return 0.0
    k = min(len(sorted_ms) - 1, max(0, round(p / 100 * (len(sorted_ms) - 1))))
    return sorted_ms[k]


def find_bins(bin_dir: str | None) -> tuple[str, str]:
    candidates = [bin_dir] if bin_dir else [
        os.path.join(ROOT, ".build", "release"),
        os.path.join(ROOT, ".build", "debug"),
        os.path.expanduser("~/.cache/rv-build/release"),
        os.path.expanduser("~/.cache/rv-build/debug"),
    ]
    for d in candidates:
        if d and os.access(os.path.join(d, "rvd"), os.X_OK) and os.access(os.path.join(d, "rv"), os.X_OK):
            return os.path.realpath(os.path.join(d, "rv")), os.path.realpath(os.path.join(d, "rvd"))
    raise SystemExit("no directory with both rv and rvd; build them or pass --bin-dir")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--bin-dir", help="directory holding rv and rvd (default: .build/release, then debug)")
    ap.add_argument("--client", choices=("rv", "socket"), default="rv")
    ap.add_argument("--calls", type=int, default=0, help="total calls (default: one pass over the corpus)")
    ap.add_argument("--concurrency", type=int, default=4)
    ap.add_argument("--warmup", type=int, default=20, help="calls sent first and left out of the numbers")
    ap.add_argument("--timeout", type=float, default=15.0, help="per-call client timeout, seconds")
    ap.add_argument("--shuffle", action="store_true", help="randomize order (seeded by --seed)")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--filter", help="only corpus files whose name contains this")
    ap.add_argument("--max-p99-ms", type=float, help="fail when p99 latency exceeds this")
    ap.add_argument("--json", help="write the full summary here")
    ap.add_argument("--rvd-env", action="append", default=[], metavar="KEY=VALUE",
                    help="extra environment for rvd only (repeatable)")
    ap.add_argument("--keep", action="store_true", help="keep the throwaway HOME and rvd stderr")
    args = ap.parse_args()

    cases = load_corpus(ROOT)
    if args.filter:
        cases = [c for c in cases if args.filter in c.source]
    if not cases:
        raise SystemExit("corpus is empty (check --filter)")
    if args.shuffle:
        random.Random(args.seed).shuffle(cases)
    total = args.calls or len(cases)
    rv, rvd = find_bins(args.bin_dir)

    extra_env = {}
    for item in args.rvd_env:
        key, sep, value = item.partition("=")
        if not sep or not key:
            raise SystemExit(f"--rvd-env needs KEY=VALUE, got {item!r}")
        extra_env[key] = value
    workdir = tempfile.mkdtemp(prefix="rvr-", dir="/tmp")
    daemon: Daemon | None = None
    try:
        daemon = Daemon(rvd, workdir, extra_env)
        return run(args, cases, total, rv, rvd, daemon)
    finally:
        if daemon is not None:
            daemon.stop()  # idempotent: run() stops it before reading its stderr
        if args.keep:
            print(f"  kept        {workdir}")
        else:
            shutil.rmtree(workdir, ignore_errors=True)


def run(args: argparse.Namespace, cases: list[Case], total: int, rv: str, rvd: str, daemon: Daemon) -> int:
    try:
        client = RvClient(rv, daemon, args.timeout) if args.client == "rv" else SocketClient(daemon, args.timeout, rvd)
        session = str(uuid.uuid4())

        def one(case: Case) -> Result:
            t0 = time.perf_counter()
            outcome, detail = client(payload(case.command, daemon.cwd, session))
            return Result(case, outcome, (time.perf_counter() - t0) * 1000, detail)

        for case in cases[: args.warmup]:
            one(case)
        before = daemon.stats()

        work = (cases[i % len(cases)] for i in range(total))
        results: list[Result] = []

        def take(res: Result) -> None:
            results.append(res)
            if len(results) % 1000 == 0:
                print(f"  {len(results)}/{total}", file=sys.stderr, flush=True)

        # Submitted a few per worker at a time, in order, not all up front
        # (pool.map queues every call): Ctrl-C then cancels what is queued
        # and waits only for the calls in flight, each bounded by --timeout.
        started = time.perf_counter()
        pool = cf.ThreadPoolExecutor(max_workers=args.concurrency)
        pending: collections.deque[cf.Future[Result]] = collections.deque()
        try:
            for case in work:
                pending.append(pool.submit(one, case))
                if len(pending) >= args.concurrency * 4:
                    take(pending.popleft().result())
            while pending:
                take(pending.popleft().result())
        except BaseException:
            pool.shutdown(wait=False, cancel_futures=True)
            raise
        pool.shutdown(wait=True)
        elapsed = time.perf_counter() - started
        after = daemon.stats()
    finally:
        daemon.stop()

    with open(daemon.stderr_path, encoding="utf-8", errors="replace") as fh:
        stderr_lines = fh.read().splitlines()
    budget_lines = [l for l in stderr_lines if "budget_ms=" in l]

    ms = sorted(r.ms for r in results)
    outcomes: dict[str, int] = {}
    for r in results:
        outcomes[r.outcome] = outcomes.get(r.outcome, 0) + 1
    failures = [r for r in results if r.outcome not in ("allow", "deny")]
    judged = [r for r in results if r.case.expected and r.outcome in ("allow", "deny")]
    mismatched = [r for r in judged if r.outcome != r.case.expected]
    seen_mismatch: dict[tuple[str, str], Result] = {}
    for r in mismatched:
        seen_mismatch.setdefault((r.case.source, r.case.case_id), r)
    examples: list[Result] = []
    per_file: dict[str, int] = {}
    for r in seen_mismatch.values():  # at most 5 per corpus file
        if per_file.get(r.case.source, 0) < 5:
            per_file[r.case.source] = per_file.get(r.case.source, 0) + 1
            examples.append(r)
    by_file: dict[str, list[int]] = {}
    for r in judged:
        agg = by_file.setdefault(r.case.source, [0, 0])
        agg[0] += 1
        agg[1] += r.outcome != r.case.expected

    # Where the time goes: latency per corpus file and the slowest commands
    # (by median over their repeats, so one unlucky call does not rank).
    lat_by_file: dict[str, list[float]] = {}
    lat_by_case: dict[tuple[str, str], list[float]] = {}
    for r in results:
        lat_by_file.setdefault(r.case.source, []).append(r.ms)
        lat_by_case.setdefault((r.case.source, r.case.case_id), []).append(r.ms)
    case_index = {(c.source, c.case_id): c for c in cases}
    lat_by_outcome: dict[str, list[float]] = {}
    for r in results:
        lat_by_outcome.setdefault(r.outcome, []).append(r.ms)
    latency_by_outcome = {
        k: {"calls": len(v), "p50": round(statistics.median(v), 2), "p99": round(pct(sorted(v), 99), 2)}
        for k, v in sorted(lat_by_outcome.items())
    }
    latency_by_file = {
        name: {"calls": len(v), "p50": round(statistics.median(v), 2), "p99": round(pct(sorted(v), 99), 2)}
        for name, v in sorted(lat_by_file.items(), key=lambda kv: -statistics.median(kv[1]))
    }
    slowest = sorted(lat_by_case.items(), key=lambda kv: -statistics.median(kv[1]))[:15]
    slowest_cases = [
        {"source": k[0], "id": k[1], "median_ms": round(statistics.median(v), 2), "calls": len(v),
         "command": case_index[k].command[:160]}
        for k, v in slowest
    ]

    summary = {
        "client": args.client,
        "bin": rv,
        "calls": len(results),
        "corpus_cases": len(cases),
        "concurrency": args.concurrency,
        "seconds": round(elapsed, 3),
        "calls_per_second": round(len(results) / elapsed, 1) if elapsed else None,
        "latency_ms": {
            "p50": round(pct(ms, 50), 2), "p90": round(pct(ms, 90), 2), "p99": round(pct(ms, 99), 2),
            "max": round(ms[-1], 2) if ms else 0, "mean": round(statistics.fmean(ms), 2) if ms else 0,
        },
        "latency_by_outcome": latency_by_outcome,
        "latency_by_file": latency_by_file,
        "slowest_cases": slowest_cases,
        "outcomes": outcomes,
        "failures": len(failures),
        "failure_examples": [
            {"source": r.case.source, "id": r.case.case_id, "outcome": r.outcome, "detail": r.detail} for r in failures[:10]
        ],
        "corpus_agreement": {
            "checked": len(judged), "disagreed": len(mismatched),
            "distinct_cases_disagreeing": len(seen_mismatch),
            "by_file": {k: {"checked": v[0], "disagreed": v[1]} for k, v in sorted(by_file.items())},
            "examples": [
                {"source": r.case.source, "id": r.case.case_id, "command": r.case.command[:160],
                 "expected": r.case.expected, "got": r.outcome}
                for r in examples
            ],
        },
        "rvd": {"before": before, "after": after, "budget_overrun_lines": budget_lines[:20]},
    }

    lat = summary["latency_ms"]
    print(f"\nrv hook replay · client={args.client} · {len(results)} calls · concurrency {args.concurrency}")
    print(f"  {summary['calls_per_second']} calls/s over {summary['seconds']} s")
    print(f"  latency ms  p50 {lat['p50']}  p90 {lat['p90']}  p99 {lat['p99']}  max {lat['max']}  mean {lat['mean']}")
    print("  by verdict  " + "  ".join(f"{k} p50 {v['p50']} p99 {v['p99']}" for k, v in latency_by_outcome.items()))
    print("  slowest files by p50:  " + "  ".join(
        f"{n} {v['p50']}" for n, v in list(latency_by_file.items())[:4]))
    print(f"  outcomes    {outcomes}")
    print(f"  failures    {len(failures)}" + (f"  e.g. {failures[0].outcome}: {failures[0].detail[:160]!r}" if failures else ""))
    ca = summary["corpus_agreement"]
    print(f"  corpus      {ca['checked']} checked, {ca['disagreed']} disagreed ({ca['distinct_cases_disagreeing']} distinct cases)")
    for name, v in ca["by_file"].items():
        if v["disagreed"]:
            print(f"    {name}: {v['disagreed']}/{v['checked']}")
    print(f"  rvd         before {before}  after {after}")
    if budget_lines:
        print(f"  rvd logged {len(budget_lines)} hook-budget overrun line(s); first: {budget_lines[0][:200]}")

    if args.json:
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump(summary, fh, indent=2)
        print(f"  summary     {args.json}")
    ok = not failures and after.get("alive", False)
    if args.max_p99_ms is not None and lat["p99"] > args.max_p99_ms:
        print(f"  p99 {lat['p99']} ms exceeds --max-p99-ms {args.max_p99_ms}", file=sys.stderr)
        ok = False
    return 0 if ok else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("hook-replay: interrupted", file=sys.stderr)
        sys.exit(130)
