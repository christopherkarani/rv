#!/usr/bin/env python3
"""The MCP gateway with the approvals custodian on Linux, end to end.

Usage: RV_E2E_PASSWORD=... Scripts/linux-custodian-e2e.py <path-to-rv>

Run by Scripts/linux-custodian-e2e.sh as a throwaway account whose login
password is RV_E2E_PASSWORD, with the custodian installed. Everything rv
writes goes under that account's home, never a real ~/.config/rv.

It plays two parts. The owner sits at a terminal (a pty this script
drives) and can type the password. The agent is every other process of
the same account: it has no terminal and does not know the password.
Each step prints PASS or FAIL; exit 0 when every step passes.
"""
import json, os, pty, re, select, shutil, socket, struct, subprocess, sys, time

if len(sys.argv) != 2 or "RV_E2E_PASSWORD" not in os.environ:
    sys.exit(__doc__)
RV = os.path.abspath(sys.argv[1])
PASSWORD = os.environ.pop("RV_E2E_PASSWORD")
HOME = os.environ["HOME"]
CONFIG = f"{HOME}/.config/rv"
WORK = f"{HOME}/e2e"
ENV = {"HOME": HOME, "PATH": "/usr/bin:/bin", "USER": os.environ.get("USER", "owner"), "LANG": "C.UTF-8"}
FIXTURE = f"{WORK}/fixture.py"
STEPS = []
os.makedirs(WORK, exist_ok=True)
os.makedirs(CONFIG, mode=0o700, exist_ok=True)


def step(name, ok, detail=""):
    STEPS.append((name, bool(ok)))
    print(("PASS " if ok else "FAIL ") + name + (f"  [{detail}]" if detail and not ok else ""), flush=True)


def last(text):
    lines = [line for line in text.strip().splitlines() if line.strip()]
    return lines[-1] if lines else "no output"


def rv(*args):
    """rv with no terminal at all: what an agent's shell gets."""
    return subprocess.run(["setsid", "-w", RV, *args], env=ENV, stdin=subprocess.DEVNULL, capture_output=True,
                          text=True, timeout=120)


def owner(args, answers):
    """rv on a terminal. `answers` is a list of (text to wait for, line to type), used in order."""
    pid, fd = pty.fork()
    if pid == 0:
        os.execve(RV, [RV, *args], ENV)
    out, pending, seen = b"", list(answers), 0
    deadline = time.time() + 120
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
        text = out.decode(errors="replace")
        if pending and pending[0][0] in text[seen:]:
            seen = len(text)
            os.write(fd, (pending.pop(0)[1] + "\n").encode())
    else:
        os.kill(pid, 9)
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


def write_config(extra_allow=()):
    cfg = {"version": 1, "servers": [{
        "name": "fx", "command": "/usr/bin/python3", "args": [FIXTURE],
        "tools": {"allow": ["echo", *extra_allow], "ask": ["write_note"]}}]}
    with open(f"{CONFIG}/mcp.json", "w") as f:
        json.dump(cfg, f, indent=2)
    os.chmod(f"{CONFIG}/mcp.json", 0o600)


class Gateway:
    """`rv mcp serve` as an agent host starts it: pipes, no terminal."""

    def __init__(self):
        self.err = f"{WORK}/serve-{time.time_ns()}.err"
        self.p = subprocess.Popen(["setsid", "-w", RV, "mcp", "serve"], env=ENV, stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=open(self.err, "w"), text=True, bufsize=1)
        self.send({"jsonrpc": "2.0", "id": 0, "method": "initialize",
                   "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "e2e", "version": "1"}}})
        self.ok = self.recv() is not None
        if self.ok:
            self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
            self.send({"jsonrpc": "2.0", "id": "list", "method": "tools/list"})
            self.tools = [t["name"] for t in (self.recv() or {}).get("result", {}).get("tools", [])]

    def send(self, msg):
        try:
            self.p.stdin.write(json.dumps(msg) + "\n")
            self.p.stdin.flush()
        except BrokenPipeError:
            pass

    def recv(self):
        ready, _, _ = select.select([self.p.stdout], [], [], 60)
        line = self.p.stdout.readline() if ready else ""
        return json.loads(line) if line.strip() else None

    def call(self, cid, name, args):
        self.send({"jsonrpc": "2.0", "id": cid, "method": "tools/call", "params": {"name": name, "arguments": args}})
        return self.recv() or {}

    def stderr(self):
        return open(self.err).read()

    def close(self):
        try:
            self.p.stdin.close()
            self.p.wait(timeout=20)
        except Exception:
            self.p.kill()
        return self.stderr()


def text_of(reply):
    return "".join(c.get("text", "") for c in reply.get("result", {}).get("content", []))


class Custodian:
    """A raw client of the key daemon: what a process of this account can say to it without rv."""

    def __init__(self):
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.settimeout(10)
        self.s.connect("/run/rv-mcp-custodian/custodian.sock")

    def ask(self, message):
        body = json.dumps(message).encode()
        self.s.sendall(struct.pack(">I", len(body)) + body)
        header = self.s.recv(4, socket.MSG_WAITALL)
        if len(header) < 4:
            return None
        return json.loads(self.s.recv(struct.unpack(">I", header)[0], socket.MSG_WAITALL))


def key(request):
    return {"key": {"scope": os.path.realpath(CONFIG), "request": request}}


# 0. the custodian is there, and the account has no key yet
r = rv("mcp", "custodian", "status")
step("custodian status: installed, no key yet", r.returncode == 0 and "no approvals key yet" in r.stdout, last(r.stdout + r.stderr))

# 1. a hand-written mcp.json is untrusted and launches nothing
write_config()
r = rv("mcp", "check")
step("hand-written mcp.json is untrusted", r.returncode == 1 and "edited outside rv" in r.stdout, last(r.stdout + r.stderr))
r = rv("mcp", "serve")
step("untrusted: serve launches nothing", r.returncode != 0 and "not launching MCP servers" in r.stderr, last(r.stderr))

# 2. trusting it needs the owner: not an agent's shell, not a wrong password
r = rv("mcp", "trust")
step("trust without a terminal is refused", r.returncode != 0 and "no terminal" in r.stderr, last(r.stderr))
code, out = owner(["mcp", "trust"], [("assword", "not-the-password")])
step("trust with a wrong password is refused", code != 0 and "authentication failed" in out, last(out))
step("nothing was signed", not os.path.exists(f"{CONFIG}/mcp-integrity.json"))

# 3. the owner trusts it, typing the password once
code, out = owner(["mcp", "trust"], [("assword", PASSWORD)])
step("trust with the owner's password signs mcp.json", code == 0 and "trusted mcp.json" in out, last(out))
step("the review was shown before the password was asked",
     'fx: "/usr/bin/python3"' in out and out.find('fx: "/usr/bin/python3"') < out.lower().find("password"), repr(out[:600]))
step("the password was asked once", out.lower().count("password") == 1, out.lower().count("password"))
r = rv("mcp", "check")
step("mcp.json is trusted", "edited outside rv" not in r.stdout and "untrusted" not in r.stdout.lower(), last(r.stdout))
integrity = json.load(open(f"{CONFIG}/mcp-integrity.json"))["mcpJSON"]
step("the signature carries the custodian's counter", re.fullmatch(r"v1\.[1-9][0-9]*\.[0-9a-f]{64}", integrity) is not None, integrity)
r = rv("mcp", "custodian", "status")
step("custodian status: the account has a key", "has an approvals key" in r.stdout, last(r.stdout))

# 4. the gateway serves, unattended; an unpinned tool asks
g = Gateway()
step("serve starts with a trusted mcp.json and no terminal", g.ok and sorted(g.tools) == ["echo", "write_note"],
     last(g.stderr()) if not g.ok else g.tools)
reply = g.call(1, "echo", {"text": "hi"})
step("an allowed tool whose definition is not pinned asks", "rv mcp approve" in text_of(reply) or "rv mcp trust" in text_of(reply),
     text_of(reply) or reply)
g.close()

# 5. the owner reviews and pins the tool definitions
code, out = owner(["mcp", "trust"], [("assword", PASSWORD)])
step("trust pins the tool definitions", code == 0 and "pinned" in out.lower(), last(out))
g = Gateway()
reply = g.call(2, "echo", {"text": "hi"})
step("a pinned, allowed tool runs", text_of(reply).startswith("ran echo"), text_of(reply) or reply)

# 6. a tool that asks: the gateway records the call and prints a code
reply = g.call(3, "write_note", {"note": "x"})
asked = text_of(reply)
found = re.search(r"rv mcp approve (\S+?)`", asked)
step("a tool that asks is not run and names its approval", found is not None and "ran write_note" not in asked, asked or reply)
approval = found.group(1) if found else "missing"
code_line = re.search(r"confirmation code ([A-Z0-9]{5}-[A-Z0-9]{5})", g.stderr())
step("the gateway printed a confirmation code", code_line is not None, last(g.stderr()))
typed = code_line.group(1) if code_line else "AAAAA-AAAAA"
r = rv("mcp", "pending")
step("pending lists the call", approval in r.stdout and "write_note" in r.stdout, last(r.stdout + r.stderr))

# 7. the agent cannot approve it: no terminal, and no password
r = rv("mcp", "approve", approval)
step("approve without a terminal is refused", r.returncode != 0 and "not approved" in r.stderr, last(r.stderr))
code, out = owner(["mcp", "approve", approval], [("confirmation code", typed), ("assword", "not-the-password")])
step("approve with a wrong password is refused", code != 0 and "authentication failed" in out, last(out))
reply = g.call(4, "write_note", {"note": "x"})
step("the call still asks", "ran write_note" not in text_of(reply), text_of(reply) or reply)
code_line = re.findall(r"confirmation code ([A-Z0-9]{5}-[A-Z0-9]{5})", g.stderr())
typed = code_line[-1] if code_line else typed

# 8. the agent talks to the key daemon itself
agent = Custodian()
hello = agent.ask({"hello": {"protocolVersion": "rv.mcp-custodian.socket.v1"}})
step("the key daemon greets this account", hello == {"hello": {"ok": True, "protocolVersion": "rv.mcp-custodian.socket.v1"}}, hello)
grant = agent.ask(key({"mac": {"purpose": "grant", "fields": ["forged"], "createIfMissing": True}}))
step("a grant asked of the key daemon directly needs presence", grant == {"presenceRequired": {}}, grant)
signed = agent.ask(key({"mac": {"purpose": "mcp.json", "fields": ["forged"], "createIfMissing": True}}))
step("so does an mcp.json signature", signed == {"presenceRequired": {}}, signed)
challenge = agent.ask({"challenge": {}})
value = (challenge or {}).get("challenge", {}).get("_0", "")
attested = agent.ask({"attest": {"challenge": value, "uid": os.getuid()}})
step("the account cannot attest its own presence", attested == {"error": {"_0": "unauthorized"}}, attested)
grant = agent.ask(key({"mac": {"purpose": "grant", "fields": ["forged"], "createIfMissing": True}}))
step("and is still not unlocked", grant == {"presenceRequired": {}}, grant)
other = Custodian()
other.ask({"hello": {"protocolVersion": "rv.mcp-custodian.socket.v1"}})
verdict = other.ask(key({"verify": {"candidate": "v1.1." + "0" * 64, "purpose": "grant", "fields": ["forged"]}}))
step("a made-up grant does not verify", verdict == {"key": {"_0": {"verify": {"_0": False}}}}, verdict)
early = Custodian()
silent = early.ask(key({"status": {}}))
step("nothing is answered before a hello", silent is None, silent)

# 9. the owner approves: the code, then the password
code, out = owner(["mcp", "approve", approval], [("confirmation code", typed), ("assword", PASSWORD)])
step("approve with the code and the owner's password grants the call", code == 0 and "approved" in out, last(out))
granted = open(f"{CONFIG}/mcp-approvals.json").read()
reply = g.call(5, "write_note", {"note": "x"})
step("the approved call runs", text_of(reply).startswith("ran write_note"), text_of(reply) or reply)
reply = g.call(6, "write_note", {"note": "x"})
step("the same call again asks again: a grant is used once", "ran write_note" not in text_of(reply), text_of(reply) or reply)

# 10. the granted row, copied aside before it was used, put back
with open(f"{CONFIG}/mcp-approvals.json", "w") as f:
    f.write(granted)
reply = g.call(7, "write_note", {"note": "x"})
step("a replayed grant does not run the call", "ran write_note" not in text_of(reply), text_of(reply) or reply)
serve_log = g.close()

# 11. an older signed mcp.json, put back with its signature
old_config = open(f"{CONFIG}/mcp.json").read()
old_integrity = open(f"{CONFIG}/mcp-integrity.json").read()
write_config(extra_allow=["write_note"])
r = rv("mcp", "check")
step("an edit outside rv is untrusted again", r.returncode == 1 and "edited outside rv" in r.stdout, last(r.stdout))
code, out = owner(["mcp", "trust"], [("assword", PASSWORD)])
step("the owner trusts the new mcp.json", code == 0 and "trusted mcp.json" in out, last(out))
with open(f"{CONFIG}/mcp.json", "w") as f:
    f.write(old_config)
with open(f"{CONFIG}/mcp-integrity.json", "w") as f:
    f.write(old_integrity)
r = rv("mcp", "check")
step("the old file with its old signature is untrusted", r.returncode == 1 and "edited outside rv" in r.stdout, last(r.stdout))
r = rv("mcp", "serve")
step("and serve launches nothing from it", r.returncode != 0 and "not launching MCP servers" in r.stderr, last(r.stderr))

# 12. the audit log holds the approvals and the forwarded calls, and its chain verifies
r = rv("audit", "verify")
step("the audit chain verifies", r.returncode == 0, last(r.stdout + r.stderr))
log = ""
for name in os.listdir(CONFIG):
    if name.startswith("audit") and os.path.isfile(f"{CONFIG}/{name}"):
        log += open(f"{CONFIG}/{name}", errors="replace").read()
step("the audit log records the trust, the approval and the forwarded calls",
     "mcp.json trusted" in log and "write_note" in log and "login password (checked by the approvals custodian)" in log
     and "echo" in log, f"{len(log)} bytes")
step("no secret reached the logs", PASSWORD not in log and PASSWORD not in serve_log)

failed = [n for n, ok in STEPS if not ok]
print(f"\n{len(STEPS) - len(failed)}/{len(STEPS)} passed")
shutil.rmtree(WORK, ignore_errors=True)
sys.exit(1 if failed else 0)
