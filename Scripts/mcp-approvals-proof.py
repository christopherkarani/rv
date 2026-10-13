#!/usr/bin/env python3
"""Real-binary proof of MCP approvals the agent can't forge (PLAN 6.1).

Usage: Scripts/mcp-approvals-proof.py <path-to-rv>

Runs rv under a throwaway HOME in a temp dir, never the real ~/.config/rv.
Covers mcp.json integrity and `rv mcp trust`, approvals that need a terminal
and the code `rv mcp serve` printed, forged grants, elicitation, and the audit
trail. Linux keeps the approvals key in a file; on macOS rv writes the login
Keychain, so the script refuses there unless RV_LIVE_KEYCHAIN=1.
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

with open(f"{HOME}/.cursor/mcp.json", "w") as f:
    json.dump({"mcpServers": {"fx": {"command": "/usr/bin/python3", "args": ["-u", FIXTURE]}}}, f)


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


# 1. import writes a signed mcp.json; check passes on integrity
r = rv("mcp", "import", "--host", "cursor")
step("import writes mcp.json", r.returncode == 0 and "wrote mcp.json" in r.stdout, r.stdout.strip().splitlines()[-1] if r.stdout else r.stderr)
step("import signs mcp.json", os.path.exists(f"{CONFIG}/mcp-integrity.json") and os.path.exists(f"{CONFIG}/approvals.key"))
mode = oct(os.stat(f"{CONFIG}/approvals.key").st_mode & 0o777)
step("approvals.key is 0600", mode == "0o600", mode)
r = rv("mcp", "list", "--json")
step("list reports integrity trusted", json.loads(r.stdout)["integrity"] == "trusted")

# 2. allow write_note always would need presence; instead edit by hand -> untrusted
cfg = json.load(open(f"{CONFIG}/mcp.json"))
cfg["servers"][0]["tools"] = {"allow": ["*"]}
with open(f"{CONFIG}/mcp.json", "w") as f:
    json.dump(cfg, f, indent=2)
r = rv("mcp", "check")
step("hand edit: check exits 1", r.returncode == 1, f"exit {r.returncode}")
step("hand edit: check says edited outside rv", "mcp.json was edited outside rv" in r.stdout, r.stdout.strip().splitlines()[0])
rep = json.loads(rv("report", "--json").stdout)
step("hand edit: report json mcp not ok", rep["mcp"]["ok"] is False and "edited outside rv" in (rep["mcp"]["error"] or ""))
r = rv("report", "--strict")
step("hand edit: report --strict exits 1, NOT compliant", r.returncode == 1 and "NOT compliant" in r.stdout, r.stdout.splitlines()[0])
with open(f"{HOME}/.cursor/mcp.json", "w") as f:
    json.dump({"mcpServers": {"fx": {"command": "/usr/bin/python3", "args": ["-u", FIXTURE]},
                              "fx2": {"command": "/usr/bin/python3", "args": ["-u", FIXTURE]}}}, f)
before = open(f"{CONFIG}/mcp.json").read()
r = rv("mcp", "import", "--host", "cursor", "--server", "fx2")
step("hand edit: import refuses", r.returncode != 0 and "edited outside rv" in r.stderr, r.stderr.strip())
step("hand edit: import left mcp.json alone", open(f"{CONFIG}/mcp.json").read() == before)

# 3. the untrusted allow-all acts as ask in a live gateway
g = Gateway(elicitation=False)
reply = g.call(1, "echo", {"text": "hi"})
step("untrusted allow:* still asks", "rv paused this call" in text_of(reply), text_of(reply)[:60])
g.close()

# 4. trust: refused without a terminal, accepted on a terminal with the echoed code
r = rv("mcp", "trust", setsid=True)
step("trust refused with no terminal (setsid)", r.returncode != 0 and "no terminal" in r.stderr, r.stderr.strip())


def echo_code(out):
    m = re.search(r"Type ([A-Z2-9]{6}) to confirm", out)
    return m.group(1) if m else None


code, out = pty_run(["mcp", "trust"], echo_code)
step("trust on a terminal with the shown code", code == 0 and "trusted mcp.json" in out, out.strip().splitlines()[-1])
step("trust showed the review", "fx: /usr/bin/python3" in out and "allow *" in out)
r = rv("mcp", "check")
step("check no longer reports untrusted after trust", "untrusted" not in r.stdout and "edited outside rv" not in r.stdout,
     r.stdout.strip().splitlines()[-1])

# 5. back to ask-by-default for write_note via a signed rv write: restore an ask rule through trust
cfg["servers"][0]["tools"] = {"allow": ["echo"], "ask": ["write_note"]}
with open(f"{CONFIG}/mcp.json", "w") as f:
    json.dump(cfg, f, indent=2)
code, out = pty_run(["mcp", "trust"], echo_code)
step("re-trust ask rules", code == 0, out.strip().splitlines()[-1])

# 6. out-of-band approval: code printed on serve stderr; no-TTY approve refused; wrong code refused; right code works
g = Gateway(elicitation=False)
reply = g.call(2, "write_note", {"note": "one"})
paused = text_of(reply)
m = re.search(r"rv mcp approve ([0-9a-f]{8})", paused)
step("ask call pauses with an approval id", m is not None, paused[:80])
approval = m.group(1)
time.sleep(0.3)
cm = re.search(rf"approval {approval} for fx tool write_note: confirmation code ([A-Z2-9]{{5}}-[A-Z2-9]{{5}})", serve_stderr())
step("serve printed the confirmation code on stderr", cm is not None)
printed = cm.group(1)
step("code is not stored in mcp-approvals.json", printed not in open(f"{CONFIG}/mcp-approvals.json").read())

r = rv("mcp", "approve", approval, setsid=True)
step("approve refused with no terminal (setsid)", r.returncode != 0 and "no terminal" in r.stderr, r.stderr.strip())
r = rv("mcp", "approve", approval, stdin=subprocess.PIPE)
step("approve refused from a pipe-only script", r.returncode != 0, r.stderr.strip())
code, out = pty_run(["mcp", "approve", approval], lambda o: "AAAAA-AAAAA" if "confirmation code" in o else None)
step("approve refused with a wrong code", code != 0 and "wrong confirmation code" in out, out.strip().splitlines()[-1])
reply = g.call(3, "write_note", {"note": "one"})
step("call still paused after refusals", "rv paused this call" in text_of(reply))
time.sleep(0.3)
printed = re.findall(rf"approval {approval} for fx tool write_note: confirmation code ([A-Z2-9]{{5}}-[A-Z2-9]{{5}})", serve_stderr())[-1]
code, out = pty_run(["mcp", "approve", approval], lambda o: printed.lower() if "confirmation code" in o else None)
step("approve on a terminal with the printed code", code == 0 and "approved fx write_note once" in out, out.strip().splitlines()[-1])
reply = g.call(4, "write_note", {"note": "two"})
step("grant is bound to the arguments", "rv paused this call" in text_of(reply))
reply = g.call(5, "write_note", {"note": "one"})
step("approved call runs once", text_of(reply) == 'ran write_note {"note": "one"}', text_of(reply))
reply = g.call(6, "write_note", {"note": "one"})
step("grant is single use", "rv paused this call" in text_of(reply))

# 7. forged grant: flip a pending entry to granted by editing the file
approvals = json.load(open(f"{CONFIG}/mcp-approvals.json"))
forged_id = None
for req in approvals["requests"]:
    if req["state"] == "pending" and req["tool"] == "write_note":
        req["state"] = "granted"
        forged_id = req["id"]
        break
with open(f"{CONFIG}/mcp-approvals.json", "w") as f:
    json.dump(approvals, f)
os.chmod(f"{CONFIG}/mcp-approvals.json", 0o600)
reply = g.call(7, "write_note", {"note": "two"})
step("forged grant does not run the call", "rv paused this call" in text_of(reply), text_of(reply)[:50])
time.sleep(0.3)
step("serve logged the forged grant", f"rejected approval {forged_id}" in serve_stderr())
g.close()
r = rv("audit", "--kind", "mcp.approval", "--json")
events = [json.loads(l) for l in r.stdout.splitlines() if l.strip().startswith("{")] if r.stdout.strip().startswith("{") else json.loads(r.stdout or "[]")
if isinstance(events, dict):
    events = events.get("events", [])
forged = [e for e in events if e.get("reason") == "forged grant rejected"]
step("audit: forged grant rejected (denied)", len(forged) == 1 and forged[0]["decision"] == "denied", f"{len(events)} mcp.approval events")
granted = [e for e in events if e.get("source") == "rv mcp approve" and e["decision"] == "allowed"]
step("audit: approve recorded with method", len(granted) == 1 and granted[0]["detail"]["method"] == "terminal confirmation code")
refusals = [e for e in events if e.get("source") == "rv mcp approve" and e["decision"] == "denied"]
step("audit: refused approvals recorded", len(refusals) >= 3, f"{len(refusals)}")
trusts = [e for e in events if e.get("source") == "rv mcp trust"]
step("audit: trust recorded", len(trusts) == 2)

# 8. elicitation: accept runs exactly the held call; decline refuses
g = Gateway(elicitation=True)
g.send({"jsonrpc": "2.0", "id": 10, "method": "tools/call", "params": {"name": "write_note", "arguments": {"note": "elicit"}}})
prompt = g.recv()
step("elicitation/create sent to the client", prompt.get("method") == "elicitation/create", prompt.get("method", ""))
step("prompt shows server, tool, and arguments", "fx" in prompt["params"]["message"] and '"note":"elicit"' in prompt["params"]["message"])
g.send({"jsonrpc": "2.0", "id": prompt["id"], "result": {"action": "accept", "content": {"approve": True}}})
reply = g.recv()
step("accepted elicitation runs the call", reply.get("id") == 10 and text_of(reply) == 'ran write_note {"note": "elicit"}', text_of(reply))
g.send({"jsonrpc": "2.0", "id": 11, "method": "tools/call", "params": {"name": "write_note", "arguments": {"note": "no"}}})
prompt = g.recv()
g.send({"jsonrpc": "2.0", "id": prompt["id"], "result": {"action": "decline"}})
reply = g.recv()
step("declined elicitation refuses", reply.get("id") == 11 and "declined" in text_of(reply) and reply["result"]["isError"])
g.close()
r = rv("audit", "--kind", "mcp.call", "--json")
calls = r.stdout
step("audit: elicitation approval recorded", '"approvedVia":"elicitation"' in calls.replace(" ", ""))

# 9. --always: presence + code, signed allow-list edit, then no more asking
g = Gateway(elicitation=False)
paused = text_of(g.call(20, "write_note", {"note": "always"}))
approval = re.search(r"rv mcp approve ([0-9a-f]{8})", paused).group(1)
time.sleep(0.3)
printed = re.findall(rf"approval {approval} for fx tool write_note: confirmation code ([A-Z2-9]{{5}}-[A-Z2-9]{{5}})", serve_stderr())[-1]
code, out = pty_run(["mcp", "approve", approval, "--always"], lambda o: printed if "confirmation code" in o else None)
step("approve --always on a terminal", code == 0 and "always" in out, out.strip().splitlines()[-1])
rules = json.load(open(f"{CONFIG}/mcp.json"))["servers"][0]["tools"]
step("--always moved write_note to allow", "write_note" in rules.get("allow", []) and "write_note" not in rules.get("ask", []), json.dumps(rules))
step("--always kept mcp.json trusted", json.loads(rv("mcp", "list", "--json").stdout)["integrity"] == "trusted")
g.close()
g = Gateway(elicitation=False)
step("allowed tool runs without asking", text_of(g.call(21, "write_note", {"note": "free"})) == 'ran write_note {"note": "free"}')
g.close()

failed = [n for n, ok in STEPS if not ok]
print(f"\n{len(STEPS) - len(failed)}/{len(STEPS)} passed")
if not failed:
    shutil.rmtree(ROOT, ignore_errors=True)
else:
    print(f"kept {ROOT} for inspection")
sys.exit(1 if failed else 0)
