#!/usr/bin/env python3
"""Real-binary proof of the Phase 7 MCP gateway features (7.1, 7.2, 7.3, 7.6).

Usage: Scripts/mcp-phase7-proof.py <path-to-rv>

Runs rv under a throwaway HOME in a temp dir, never the real ~/.config/rv.
Each section writes mcp.json by hand, trusts it on a pseudo-terminal with the
code `rv mcp trust` shows, and drives `rv mcp serve` as an MCP client would.
On macOS rv keeps its approvals key in the login Keychain, so the script
refuses there unless RV_LIVE_KEYCHAIN=1. Exit 0 when every step passes.
"""
import atexit, json, os, pty, re, select, shutil, subprocess, sys, tempfile, time

if len(sys.argv) != 2:
    sys.exit(__doc__)
if sys.platform == "darwin" and os.environ.get("RV_LIVE_KEYCHAIN") != "1":
    sys.exit("refusing on macOS: rv would write the login Keychain (set RV_LIVE_KEYCHAIN=1 to accept)")
RV = os.path.abspath(sys.argv[1])
ROOT = tempfile.mkdtemp(prefix="rv-mcp-phase7-", dir="/tmp")
HOME = f"{ROOT}/home"
CONFIG = f"{HOME}/.config/rv"
os.makedirs(CONFIG, mode=0o700, exist_ok=True)
ENV = {"HOME": HOME, "PATH": "/usr/bin:/bin", "USER": os.environ.get("USER", "ubuntu"), "LANG": "C.UTF-8"}


def ephemeral_keychain():
    """macOS file-keychain lookup honors $HOME, so a throwaway HOME has no
    login keychain and SecItemAdd fails (or prompts). Create one inside
    the throwaway HOME and restore the user's search list verbatim."""
    def listed():
        out = subprocess.run(["security", "list-keychains", "-d", "user"],
                             capture_output=True, text=True).stdout
        return re.findall(r'"([^"]+)"', out)

    original = listed()
    keychains = f"{HOME}/Library/Keychains"
    os.makedirs(keychains, exist_ok=True)
    created = f"{keychains}/login.keychain-db"
    subprocess.run(["security", "create-keychain", "-p", "", created], check=True, capture_output=True)

    def restore():
        subprocess.run(["security", "delete-keychain", created], capture_output=True)
        if original:
            subprocess.run(["security", "list-keychains", "-d", "user", "-s", *original],
                           capture_output=True)

    atexit.register(restore)


if sys.platform == "darwin":
    ephemeral_keychain()
FIXTURE = f"{ROOT}/fixture.py"
STEPS = []


def step(name, ok, detail=""):
    STEPS.append((name, ok))
    print(("PASS " if ok else "FAIL ") + name + (f"  [{detail}]" if detail else ""), flush=True)


def rv(*args, stdin=subprocess.DEVNULL):
    return subprocess.run([RV, *args], env=ENV, stdin=stdin, capture_output=True, text=True, timeout=60)


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


def echo_code(out):
    m = re.search(r"Type ([A-Z2-9]{6}) to confirm", out)
    return m.group(1) if m else None


def write_and_trust(config, label):
    path = f"{CONFIG}/mcp.json"
    with open(path, "w") as f:
        json.dump(config, f, indent=2)
    os.chmod(path, 0o600)
    code, out = pty_run(["mcp", "trust"], echo_code)
    step(f"{label}: trusted on a terminal", code == 0 and "trusted mcp.json" in out, out.strip().splitlines()[-1] if out else "")
    return out


with open(FIXTURE, "w") as f:
    f.write('''import json, sys
TOOLS = [{"name": "query", "description": "Run SQL", "inputSchema": {"type": "object"}},
         {"name": "tables", "inputSchema": {"type": "object"}}]
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


class Gateway:
    def __init__(self, elicitation=False, env=None, args=None):
        self.p = subprocess.Popen([RV, "mcp", "serve", *(args or [])], env=env or ENV, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=open(f"{ROOT}/serve-{time.time_ns()}.err", "w+"), text=True, bufsize=1)
        caps = {"elicitation": {}} if elicitation else {}
        self.send({"jsonrpc": "2.0", "id": 0, "method": "initialize",
                   "params": {"protocolVersion": "2025-06-18", "capabilities": caps, "clientInfo": {"name": "e2e", "version": "1"}}})
        self.recv()
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        self.send({"jsonrpc": "2.0", "id": "list", "method": "tools/list"})
        self.tools = self.recv()["result"]["tools"]

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


def text_of(reply):
    return "".join(c.get("text", "") for c in reply.get("result", {}).get("content", []))


def server(**extra):
    return {"name": "db", "command": "/usr/bin/python3", "args": ["-u", FIXTURE], **extra}


# 7.2 argument-aware rules
out = write_and_trust({"version": 1, "servers": [server(tools={
    "default": "allow",
    "ask": [{"tool": "query", "when": {"/database": {"in": ["prod", "billing"]}}}],
    "deny": [{"tool": "query", "when": {"/sql": {"glob": "DROP *"}}}, {"tool": "query", "when": {"/limit": {">": 1000}}}],
})]}, "7.2 rules")
step("7.2 trust review lists the rules", 'ask query when /database in ["prod","billing"]' in out and "deny query when /sql glob" in out)
g = Gateway()
query = next(t for t in g.tools if t["name"] == "query")
step("7.2 listing marks the ruled tool", query["description"].startswith("[rv: some arguments need"), query["description"])
reply = g.call(1, "query", {"database": "test", "sql": "SELECT 1", "limit": 10})
step("7.2 test database runs", text_of(reply).startswith("ran query"), text_of(reply))
reply = g.call(2, "query", {"database": "prod", "sql": "SELECT 1"})
step("7.2 prod database asks", "rv paused this call" in text_of(reply), text_of(reply)[:60])
reply = g.call(3, "query", {"database": "test", "sql": "DROP TABLE users"})
step("7.2 DROP is denied", "rv policy denies db tool query" in text_of(reply) and reply["result"]["isError"], text_of(reply)[:60])
reply = g.call(4, "query", {"database": "test", "sql": "SELECT 1", "limit": 5000})
step("7.2 limit over 1000 is denied", "rv policy denies" in text_of(reply))
reply = g.call(5, "query", {"sql": "SELECT 1"})
step("7.2 missing database falls through to allow", text_of(reply).startswith("ran query"))
g.close()
pending = rv("mcp", "pending").stdout
approval = re.search(r"([0-9a-f]{8})", pending).group(1) if re.search(r"([0-9a-f]{8})", pending) else ""
code, out = pty_run(["mcp", "approve", approval, "--always"], lambda o: "AAAAA-AAAAA" if "confirmation code" in o else None)
step("7.2 approve --always refuses a ruled tool", code != 0 and "has argument rules" in out, out.strip().splitlines()[-1] if out else "")
calls = rv("audit", "--kind", "mcp.call", "--json").stdout.replace(" ", "")
step("7.2 audit records the denial", '"policy":"deny"' in calls)

# 7.6 tamper-evident audit (the 7.2 run above wrote real audit.jsonl lines)
import hashlib, http.server, threading
AUDIT = f"{CONFIG}/audit.jsonl"
lines = open(AUDIT, "rb").read().split(b"\n")[:-1]
prevs = [json.loads(l).get("prev") for l in lines]
linked = prevs[0] == "0" * 64 and all(prevs[i] == hashlib.sha256(lines[i - 1]).hexdigest() for i in range(1, len(lines)))
step("7.6 every line carries prev = sha256 of the line before", len(lines) > 3 and linked, f"{len(lines)} lines")
head = hashlib.sha256(lines[-1]).hexdigest()
v = rv("audit", "verify")
step("7.6 verify: intact", v.returncode == 0 and v.stdout.startswith(f"audit chain intact: {len(lines)} lines, head {head}"), v.stdout.strip())
vj = json.loads(rv("audit", "verify", "--json").stdout)
step("7.6 verify --json", vj["lines"] == len(lines) and vj["head"] == head and "firstBreak" not in vj)

received = []


class Receiver(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        received.extend(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
        self.send_response(200)
        self.end_headers()

    def log_message(self, *a):
        pass


httpd = http.server.HTTPServer(("127.0.0.1", 0), Receiver)
threading.Thread(target=httpd.serve_forever, daemon=True).start()
f = rv("audit", "forward", "--to", f"http://127.0.0.1:{httpd.server_port}/siem")
chained = [e["unmapped"] for e in received if "rv_chain_head" in e.get("unmapped", {})]
step("7.6 forward: OCSF events carry rv_prev and rv_chain_head", f.returncode == 0 and len(chained) == len(lines)
     and chained[-1]["rv_chain_head"] == head and all(chained[i]["rv_prev"] == chained[i - 1]["rv_chain_head"] for i in range(1, len(chained))),
     f.stdout.strip())
httpd.shutdown()

original = open(AUDIT, "rb").read()
edited = original.replace(b'"policy":"deny"', b'"policy":"allow"', 1)
open(AUDIT, "wb").write(edited)
v = rv("audit", "verify")
step("7.6 verify: an edited line breaks the chain", v.returncode == 1 and "BROKEN at line" in v.stdout and "prev does not match" in v.stdout,
     v.stdout.strip().splitlines()[0])
open(AUDIT, "wb").write(b"\n".join(l for i, l in enumerate(original.split(b"\n")) if i != 1))
v = rv("audit", "verify")
step("7.6 verify: a deleted line breaks the chain", v.returncode == 1 and "BROKEN at line 2" in v.stdout, v.stdout.strip().splitlines()[0])
open(AUDIT, "wb").write(original)
step("7.6 verify: restored file is intact again", rv("audit", "verify").returncode == 0)

i = rv("audit", "forward", "--install", "--to", "https://siem.example.com/rv", "--header", "Authorization=Bearer ${secret:SIEM}")
if sys.platform == "darwin":
    plist = f"{HOME}/Library/LaunchAgents/dev.rv.audit-forward.plist"
    step("7.6 --install writes the LaunchAgent", i.returncode == 0 and os.path.exists(plist) and "StartInterval" in open(plist).read(), i.stdout.splitlines()[0])
else:
    step("7.6 --install on Linux prints a cron line", i.returncode == 1 and "*/5 * * * *" in i.stderr and "'audit' 'forward' '--to'" in i.stderr,
         i.stderr.strip().splitlines()[-1][:70])
i = rv("audit", "forward", "--install", "--to", "https://siem.example.com/rv", "--header", "Authorization=Bearer plain-token-value")
step("7.6 --install refuses a literal header", i.returncode == 1 and "${secret:NAME}" in i.stderr and "plain-token-value" not in i.stderr + i.stdout)

# 7.3 search tool mode (two servers, so names carry the server prefix)
out = write_and_trust({"version": 1, "toolMode": "search", "servers": [
    server(tools={"default": "allow", "deny": ["tables"]}),
    {**server(tools={"default": "allow", "ask": ["query"]}), "name": "wh"},
]}, "7.3 search")
step("7.3 trust review names the mode", "tool mode search" in out)
g = Gateway()
step("7.3 listing holds only the two rv tools", [t["name"] for t in g.tools] == ["rv_search_tools", "rv_call_tool"])
reply = g.call(10, "rv_search_tools", {"query": "sql"})
found = sorted(t["name"] for t in reply["result"]["structuredContent"]["tools"])
step("7.3 search finds tools on both servers", found == ["db__query", "wh__query"], ", ".join(found))
reply = g.call(11, "rv_search_tools", {})
found = [t["name"] for t in reply["result"]["structuredContent"]["tools"]]
step("7.3 a denied tool is not searchable", "db__tables" not in found and "wh__tables" in found, ", ".join(found))
reply = g.call(12, "rv_call_tool", {"name": "db__query", "arguments": {"sql": "SELECT 2"}})
step("7.3 rv_call_tool runs an allowed tool", text_of(reply) == 'ran query {"sql": "SELECT 2"}', text_of(reply))
reply = g.call(13, "rv_call_tool", {"name": "wh__query", "arguments": {"sql": "SELECT 3"}})
step("7.3 rv_call_tool still asks", "rv paused this call: wh tool query" in text_of(reply), text_of(reply)[:50])
reply = g.call(14, "rv_call_tool", {"name": "db__tables"})
step("7.3 rv_call_tool still denies", "rv policy denies db tool tables" in text_of(reply))
g.close()
calls = [json.loads(l) for l in open(AUDIT)][-3:]
step("7.3 audit names the real tools", [(c["subject"], c["detail"].get("policy")) for c in calls]
     == [("db/query", "allow"), ("wh/query", "ask"), ("db/tables", "deny")], str([c["subject"] for c in calls]))

# 7.1 remote servers: streamable HTTP, legacy SSE, header secrets, import, setup, OAuth
import atexit, secrets as pysecrets, urllib.request
REMOTE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "mcp-remote-fixture.py")


def remote_fixture(*args):
    log = open(f"{ROOT}/remote-{time.time_ns()}.log", "w+")
    p = subprocess.Popen(["/usr/bin/python3", "-u", REMOTE, *args], stdout=subprocess.PIPE, stderr=log, text=True)
    atexit.register(p.kill)
    return p, int(p.stdout.readline().split()[1]), log


TOKEN = "fx" + pysecrets.token_hex(16)
fx, port, fx_log = remote_fixture("--token", TOKEN)
base = f"http://127.0.0.1:{port}"
with open(f"{CONFIG}/secrets.json", "w") as f:
    json.dump({"version": 1, "secrets": [{"name": "FIXTURE_TOKEN", "source": {"hostEnvironment": {"variable": "RV_PROOF_TOKEN"}},
                                          "delivery": {"environment": {}}}]}, f)
os.chmod(f"{CONFIG}/secrets.json", 0o600)
ENV_T = {**ENV, "RV_PROOF_TOKEN": TOKEN}
auth = {"Authorization": "Bearer ${secret:FIXTURE_TOKEN}"}
out = write_and_trust({"version": 1, "servers": [
    {"name": "web", "url": f"{base}/mcp", "headers": {**auth, "X-Team": "eng"}, "tools": {"default": "allow", "deny": ["delete_all"]}},
    {"name": "old", "url": f"{base}/sse", "transport": "sse", "headers": auth, "tools": {"default": "allow", "ask": ["delete_all"]}},
]}, "7.1 remote")
step("7.1 trust review shows URL, transport and header names, never the token",
     f"web: {base}/mcp (remote, streamable HTTP)" in out and "old: " in out and "legacy SSE" in out
     and "Authorization (secret FIXTURE_TOKEN)" in out and TOKEN not in out)
g = Gateway(env=ENV_T)
names = sorted(t["name"] for t in g.tools)
step("7.1 tools from both transports; deny hides web delete_all",
     {"web__echo", "web__whoami", "old__echo", "old__delete_all"} <= set(names) and "web__delete_all" not in names, ", ".join(names))
reply = g.call(20, "web__whoami", {})
step("7.1 streamable HTTP: header secret sent, scrubbed from the reply",
     text_of(reply) == "authorization=Bearer [redacted:FIXTURE_TOKEN] team=eng", text_of(reply))
reply = g.call(21, "old__echo", {"text": "over sse"})
step("7.1 legacy SSE: call answered", "over sse" in text_of(reply), text_of(reply))
reply = g.call(22, "old__whoami", {})
step("7.1 legacy SSE: token scrubbed", "[redacted:FIXTURE_TOKEN]" in text_of(reply) and TOKEN not in json.dumps(reply), text_of(reply))
reply = g.call(23, "old__delete_all", {})
step("7.1 remote tools keep rv policy (ask)", "rv paused this call: old tool delete_all" in text_of(reply), text_of(reply)[:50])
g.close()
time.sleep(0.3)
fx_log.seek(0)
requests = fx_log.read()
step("7.1 gateway ends the HTTP session on exit (DELETE)", re.search(r"^DELETE sess-\S+ ok$", requests, re.M) is not None, requests.strip().splitlines()[-1] if requests else "")
calls = [json.loads(l) for l in open(AUDIT)][-4:]
step("7.1 audit records remote calls by server/tool", [c["subject"] for c in calls] == ["web/whoami", "old/echo", "old/whoami", "old/delete_all"],
     str([c["subject"] for c in calls]))
step("7.1 audit holds no token", TOKEN not in open(AUDIT).read())

broken = dict(ENV_T, RV_PROOF_TOKEN="wrong-token")
g = Gateway(env=broken)
step("7.1 a rejected credential lists no tools from that server", not any(t["name"].startswith(("web__", "old__")) for t in g.tools),
     ", ".join(t["name"] for t in g.tools))
g.close()

os.makedirs(f"{HOME}/.cursor", exist_ok=True)
with open(f"{HOME}/.cursor/mcp.json", "w") as f:
    json.dump({"mcpServers": {
        "hosted": {"url": f"{base}/mcp", "headers": {"X-Team": "eng"}},
        "keyed": {"url": f"{base}/mcp", "headers": {"Authorization": "Bearer " + TOKEN}},
        "legacy": {"url": f"{base}/sse", "type": "sse"},
        "plain": {"url": "http://example.com/mcp"},
    }}, f)
r = rv("mcp", "import", "--host", "cursor", "--dry-run")
step("7.1 import dry run: url entries, header credential becomes a secret, plain http refused",
     f"import hosted: {base}/… (http)" in r.stdout and "import keyed:" in r.stdout and "(credentials → rv secrets KEYED_AUTHORIZATION)" in r.stdout
     and "import legacy:" in r.stdout and "(sse)" in r.stdout and "skip plain: url must be https" in r.stdout and TOKEN not in r.stdout + r.stderr,
     r.stdout.strip().replace("\n", " | ")[:160])
if sys.platform != "darwin":
    r = rv("mcp", "import", "--host", "cursor", "--server", "keyed")
    step("7.1 import keyed on Linux: no Keychain, nothing imported, nothing leaked",
         r.returncode != 0 and "could not store KEYED_AUTHORIZATION in the Keychain; nothing imported" in r.stderr
         and TOKEN not in r.stdout + r.stderr + open(f"{CONFIG}/mcp.json").read(), r.stderr.strip())
r = rv("mcp", "import", "--host", "cursor", "--server", "hosted", "--server", "legacy", "--allow-tools")
step("7.1 import hosted and legacy", r.returncode == 0 and "wrote mcp.json" in r.stdout, r.stdout.strip().splitlines()[-1] if r.stdout else r.stderr)
imported = {s["name"]: s for s in json.load(open(f"{CONFIG}/mcp.json"))["servers"]}
step("7.1 imported definitions", imported["hosted"].get("url") == f"{base}/mcp" and imported["hosted"].get("headers") == {"X-Team": "eng"}
     and imported["legacy"].get("transport") == "sse" and "command" not in imported["hosted"], json.dumps(imported.get("legacy")))
r = rv("mcp", "setup", "--host", "cursor", "--server", "hosted")
host = json.load(open(f"{HOME}/.cursor/mcp.json"))["mcpServers"]["hosted"]
step("7.1 setup routes the remote host entry through rv", r.returncode == 0 and host == {"command": RV, "args": ["mcp", "serve", "--server", "hosted"]},
     json.dumps(host))
rows = {row["name"]: row["status"] for row in json.loads(rv("mcp", "list", "--json").stdout)["rows"]}
step("7.1 list: hosted governed, keyed unreviewed", rows.get("hosted") == "governed" and rows.get("keyed") == "unreviewed", json.dumps(rows))
fx.kill()

ofx, oport, ofx_log = remote_fixture("--oauth")
obase = f"http://127.0.0.1:{oport}"
write_and_trust({"version": 1, "servers": [{"name": "acme", "url": f"{obase}/mcp", "tools": {"default": "allow"}}]}, "7.1 oauth")
connect = subprocess.Popen([RV, "mcp", "connect", "acme", "--no-browser"], env=ENV, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
prompt = connect.stderr.readline() + connect.stderr.readline()
sign_in = prompt.strip().splitlines()[-1].strip() if prompt.strip() else ""
step("7.1 connect prints the sign-in URL (PKCE S256, resource)", sign_in.startswith(f"{obase}/auth/authorize?") and "code_challenge_method=S256" in sign_in
     and "resource=" in sign_in, prompt.strip().splitlines()[0] if prompt.strip() else "")
try:
    urllib.request.urlopen(sign_in, timeout=10).read()
except Exception as error:
    print("  browser leg:", error)
stdout, stderr = connect.communicate(timeout=30)
step("7.1 connect stores the tokens", connect.returncode == 0 and stdout.startswith("connected acme; tokens stored in "), (stdout + stderr).strip()[:120])
store = f"{CONFIG}/mcp-oauth/acme.json"
if sys.platform != "darwin":
    step("7.1 Linux token file is 0600", os.path.exists(store) and oct(os.stat(store).st_mode & 0o777) == "0o600")
    first = json.load(open(store))
    step("7.1 connect output holds no token", first["accessToken"] not in stdout + stderr and first["refreshToken"] not in stdout + stderr)
g = Gateway()
reply = g.call(30, "whoami", {})
step("7.1 serve sends the OAuth token, scrubbed", text_of(reply) == "authorization=Bearer [redacted:OAUTH_ACCESS_TOKEN] team=none", text_of(reply))
urllib.request.urlopen(urllib.request.Request(f"{obase}/auth/expire", method="POST"), timeout=5).read()
reply = g.call(31, "whoami", {})
step("7.1 after the server revokes the token, serve refreshes and retries", text_of(reply) == "authorization=Bearer [redacted:OAUTH_ACCESS_TOKEN] team=none",
     text_of(reply))
g.close()
if sys.platform != "darwin":
    second = json.load(open(store))
    step("7.1 refreshed (rotated) tokens saved", second["accessToken"] != first["accessToken"] and second["refreshToken"] != first["refreshToken"])
    step("7.1 audit holds no OAuth token", all(t not in open(AUDIT).read() for t in
                                              (first["accessToken"], first["refreshToken"], second["accessToken"], second["refreshToken"])))
events = [json.loads(l) for l in open(AUDIT) if '"rv mcp connect"' in l]
step("7.1 audit records the sign-in", any(e["reason"] == "OAuth connected" and e["subject"] == "acme" for e in events))
r = rv("mcp", "connect", "acme", "--forget")
step("7.1 --forget deletes the tokens", r.returncode == 0 and "deleted the OAuth tokens rv stored for acme" in r.stdout
     and (sys.platform == "darwin" or not os.path.exists(store)), r.stdout.strip())
r = rv("mcp", "connect", "nope")
step("7.1 connect refuses an unknown server", r.returncode != 0 and "mcp.json has no server named nope" in r.stderr, r.stderr.strip())
ofx.kill()

# 7.4 strict profile: unlisted tools deny; local servers need a sandbox; open network is refused
fx4, port4, _ = remote_fixture()
base4 = f"http://127.0.0.1:{port4}"
out = write_and_trust({"version": 1, "profile": "strict", "defaultDecision": "allow", "servers": [
    {"name": "web", "url": f"{base4}/mcp", "tools": {"allow": ["echo"], "ask": ["whoami"]}},
    {"name": "open", "command": "/usr/bin/python3", "args": ["-u", FIXTURE], "sandbox": {"network": True}},
    {"name": "proxied", "command": "/usr/bin/python3", "args": ["-u", FIXTURE], "sandbox": {"hosts": ["api.example.com"]}},
    {"name": "bare", "command": "/usr/bin/python3", "args": ["-u", FIXTURE]},
]}, "7.4 strict")
step("7.4 trust review names the profile, the denials and the allowlist",
     out.startswith("mcp.json: default deny") and "profile strict: unlisted tools deny" in out
     and "network only to api.example.com" in out and "no network" not in out.split("proxied")[0])
g = Gateway(args=["--server", "web"])
step("7.4 strict hides tools no list names", sorted(t["name"] for t in g.tools) == ["echo", "whoami"],
     ", ".join(t["name"] for t in g.tools))
reply = g.call(40, "echo", {"text": "strict-ok"})
step("7.4 an allowed tool runs", text_of(reply) == "strict-ok", text_of(reply))
reply = g.call(41, "whoami", {})
step("7.4 an ask tool still asks", "rv paused this call: web tool whoami" in text_of(reply), text_of(reply)[:60])
reply = g.call(42, "delete_all", {})
step("7.4 an unlisted tool is denied", "rv policy denies web tool delete_all" in text_of(reply), text_of(reply)[:70])
g.close()
r = rv("mcp", "serve", "--server", "bare")
step("7.4 a local server without a sandbox is refused", r.returncode != 0 and "profile strict requires a sandbox for bare" in r.stderr,
     r.stderr.strip()[:140])
r = rv("mcp", "serve", "--server", "open")
step("7.4 open network is refused", r.returncode != 0 and "keeps open off the network" in r.stderr, r.stderr.strip()[:140])
if sys.platform == "darwin":
    g = Gateway(args=["--server", "proxied"])
    reply = g.call(43, "echo", {"text": "caged"})
    step("7.4 a hosts sandbox launches on macOS", text_of(reply) == "caged", text_of(reply))
    g.close()
else:
    r = rv("mcp", "serve", "--server", "proxied")
    step("7.4 sandbox.hosts is refused on Linux (the cage is macOS)", r.returncode != 0 and "only on macOS" in r.stderr,
         r.stderr.strip()[:140])
fx4.kill()

failed = [n for n, ok in STEPS if not ok]
print(f"\n{len(STEPS) - len(failed)}/{len(STEPS)} passed")
if not failed:
    shutil.rmtree(ROOT, ignore_errors=True)
else:
    print(f"kept {ROOT} for inspection")
sys.exit(1 if failed else 0)
