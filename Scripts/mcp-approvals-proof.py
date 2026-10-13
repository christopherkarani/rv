#!/usr/bin/env python3
"""Real-binary proof that MCP signing stays fail-closed without a person (PLAN 6.1).

Usage: Scripts/mcp-approvals-proof.py <path-to-rv>

Runs rv under a throwaway HOME in a temp dir, never the real ~/.config/rv.
Import and trust must refuse on a pseudo-terminal (device-owner authentication
is the gate). An untrusted mcp.json must not launch its command. Grant binding,
elicitation booleans, and forged grants are locked in the Swift tests.
Linux keeps the approvals key in a file. On macOS the key is in the
data-protection keychain and a read prompts, so the script refuses there
unless RV_LIVE_KEYCHAIN=1.
Exit 0 when every step passes.
"""
import json, os, pty, re, select, shutil, subprocess, sys, tempfile, time

if len(sys.argv) != 2:
    sys.exit(__doc__)
if sys.platform == "darwin" and os.environ.get("RV_LIVE_KEYCHAIN") != "1":
    sys.exit("refusing on macOS: rv would write the login Keychain (set RV_LIVE_KEYCHAIN=1 to accept)")
RV = os.path.abspath(sys.argv[1])
ROOT = tempfile.mkdtemp(prefix="rv-mcp-approvals-", dir="/tmp")
HOME = f"{ROOT}/home"
CONFIG = f"{HOME}/.config/rv"
os.makedirs(f"{HOME}/.cursor", exist_ok=True)
ENV = {"HOME": HOME, "PATH": "/usr/bin:/bin", "USER": os.environ.get("USER", "ubuntu"), "LANG": "C.UTF-8"}
FIXTURE = f"{ROOT}/fixture.py"
STEPS = []


def step(name, ok, detail=""):
    STEPS.append((name, ok))
    print(("PASS " if ok else "FAIL ") + name + (f"  [{detail}]" if detail else ""), flush=True)


def rv(*args, stdin=subprocess.DEVNULL, setsid=False):
    cmd = (["setsid", "-w"] if setsid else []) + [RV, *args]
    return subprocess.run(cmd, env=ENV, stdin=stdin, capture_output=True, text=True, timeout=60)


def pty_run(args, answer):
    """Runs rv on a fresh pseudo-terminal; `answer(output_so_far)` returns the line to type, or None to wait."""
    pid, fd = pty.fork()
    if pid == 0:
        os.execve(RV, [RV, *args], ENV)
    out, sent = b"", False
    deadline = time.time() + 30
    while time.time() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.2)
        if ready:
            try:
                chunk = os.read(fd, 4096)
            except OSError:
                break
            if not chunk:
                break
            out += chunk
        if not sent:
            line = answer(out.decode(errors="replace"))
            if line is not None:
                os.write(fd, (line + "\n").encode())
                sent = True
    _, status = os.waitpid(pid, 0)
    return os.waitstatus_to_exitcode(status), out.decode(errors="replace")


with open(FIXTURE, "w") as f:
    f.write('''import json, sys
TOOLS = [{"name": "echo", "inputSchema": {"type": "object"}}, {"name": "write_note", "inputSchema": {"type": "object"}}]
for line in sys.stdin:
    msg = json.loads(line)
    if "id" not in msg:
        continue
    m, i = msg.get("method"), msg["id"]
    if m == "initialize":
        r = {"protocolVersion": msg["params"]["protocolVersion"], "capabilities": {"tools": {}}, "serverInfo": {"name": "fx", "version": "1"}}
    elif m == "tools/list":
        r = {"tools": TOOLS}
    elif m == "tools/call":
        r = {"content": [{"type": "text", "text": "ran " + msg["params"]["name"] + " " + json.dumps(msg["params"].get("arguments", {}), sort_keys=True)}]}
    else:
        print(json.dumps({"jsonrpc": "2.0", "id": i, "error": {"code": -32601, "message": "nope"}}), flush=True); continue
    print(json.dumps({"jsonrpc": "2.0", "id": i, "result": r}), flush=True)
''')

MARKER = f"{ROOT}/launched"
with open(f"{HOME}/.cursor/mcp.json", "w") as f:
    json.dump({"mcpServers": {"fx": {"command": "/usr/bin/touch", "args": [MARKER]}}}, f)


class Gateway:
    def __init__(self, elicitation):
        self.p = subprocess.Popen([RV, "mcp", "serve"], env=ENV, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=open(f"{ROOT}/serve-{time.time_ns()}.err", "w+"), text=True, bufsize=1)
        caps = {"elicitation": {}} if elicitation else {}
        self.send({"jsonrpc": "2.0", "id": 0, "method": "initialize",
                   "params": {"protocolVersion": "2025-06-18", "capabilities": caps, "clientInfo": {"name": "e2e", "version": "1"}}})
        self.recv()
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        self.send({"jsonrpc": "2.0", "id": "list", "method": "tools/list"})
        self.tools = [t["name"] for t in self.recv()["result"]["tools"]]

    def send(self, msg):
        self.p.stdin.write(json.dumps(msg) + "\n")
        self.p.stdin.flush()

    def recv(self):
        return json.loads(self.p.stdout.readline())

    def call(self, cid, name, args):
        self.send({"jsonrpc": "2.0", "id": cid, "method": "tools/call", "params": {"name": name, "arguments": args}})
        return self.recv()

    def close(self):
        self.p.stdin.close()
        self.p.wait(timeout=10)


def serve_stderr():
    text = ""
    for name in sorted(os.listdir(ROOT)):
        if name.startswith("serve-"):
            text += open(f"{ROOT}/{name}").read()
    return text


def text_of(reply):
    return "".join(c.get("text", "") for c in reply.get("result", {}).get("content", []))


# 1. import does not sign a host command without device-owner presence
r = rv("mcp", "import", "--host", "cursor", "--dry-run")
step("dry run shows the host command and writes nothing",
     r.returncode == 0 and "touch" in r.stdout and "dry run" in r.stdout
     and not os.path.exists(f"{CONFIG}/mcp.json"), r.stdout.strip().splitlines()[-1] if r.stdout else r.stderr)
r = rv("mcp", "import", "--host", "cursor")
step("import refuses without device owner",
     r.returncode != 0 and "nothing imported" in r.stderr and "device owner" in r.stderr, r.stderr.strip())
step("import did not sign mcp.json", not os.path.exists(f"{CONFIG}/mcp.json") and not os.path.exists(f"{CONFIG}/mcp-integrity.json"))

# 2. a hand-written mcp.json is untrusted and does not launch
os.makedirs(CONFIG, exist_ok=True)
cfg = {"version": 1, "servers": [{"name": "fx", "command": "/usr/bin/touch", "args": [MARKER], "tools": {"allow": ["*"]}}]}
with open(f"{CONFIG}/mcp.json", "w") as f:
    json.dump(cfg, f, indent=2)
os.chmod(f"{CONFIG}/mcp.json", 0o600)
r = rv("mcp", "check")
step("hand edit: check exits 1", r.returncode == 1, f"exit {r.returncode}")
step("hand edit: check says edited outside rv", "mcp.json was edited outside rv" in r.stdout, r.stdout.strip().splitlines()[0])
rep = json.loads(rv("report", "--json").stdout)
step("hand edit: report json mcp not ok", rep["mcp"]["ok"] is False and "edited outside rv" in (rep["mcp"]["error"] or ""))
r = rv("report", "--strict")
step("hand edit: report --strict exits 1, NOT compliant", r.returncode == 1 and "NOT compliant" in r.stdout, r.stdout.splitlines()[0])
before = open(f"{CONFIG}/mcp.json").read()
with open(f"{HOME}/.cursor/mcp.json", "w") as f:
    json.dump({"mcpServers": {"fx": {"command": "/usr/bin/touch", "args": [MARKER]},
                              "fx2": {"command": "/bin/true", "args": []}}}, f)
r = rv("mcp", "import", "--host", "cursor", "--server", "fx2")
step("hand edit: import refuses", r.returncode != 0 and "edited outside rv" in r.stderr, r.stderr.strip())
step("hand edit: import left mcp.json alone", open(f"{CONFIG}/mcp.json").read() == before)

r = rv("mcp", "serve")
step("untrusted serve refuses to launch", r.returncode != 0 and "not launching MCP servers" in r.stderr, r.stderr.strip())
step("untrusted serve did not run the command", not os.path.exists(MARKER))

# 3. trust on a pty does not echo a code and does not sign
r = rv("mcp", "trust", setsid=True)
step("trust refused without device owner (setsid)",
     r.returncode != 0 and "device owner" in r.stderr and "trusted mcp.json" not in r.stdout, r.stderr.strip())
code, out = pty_run(["mcp", "trust"], lambda o: "AAAAAA" if "confirm" in o else None)
step("trust on a pseudo-terminal does not sign",
     code != 0 and "device owner" in out and "Type " not in out and not os.path.exists(f"{CONFIG}/mcp-integrity.json"),
     out.strip().splitlines()[-1] if out.strip() else "no output")
step("trust showed the review before refusing", "fx: /usr/bin/touch" in out and "sha256" in out)
r = rv("mcp", "check")
step("mcp.json stays untrusted", "edited outside rv" in r.stdout, r.stdout.strip().splitlines()[0] if r.stdout else r.stderr)
step("command still has not run", not os.path.exists(MARKER))

failed = [n for n, ok in STEPS if not ok]
print(f"\n{len(STEPS) - len(failed)}/{len(STEPS)} passed")
if not failed:
    shutil.rmtree(ROOT, ignore_errors=True)
else:
    print(f"kept {ROOT} for inspection")
sys.exit(1 if failed else 0)
