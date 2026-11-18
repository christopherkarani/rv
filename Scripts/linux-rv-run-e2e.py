#!/usr/bin/env python3
"""`rv run` on Linux with a real HTTPS request, end to end.

Usage: Scripts/linux-rv-run-e2e.py <path-to-rv> <certificate-directory>

Run by Scripts/linux-rv-run-e2e.sh as a throwaway account, never as root
(rv run is for a user's own commands), under that account's home, never a
real ~/.config/rv. The upstream is an HTTPS server this script runs on
localhost with the certificate in <certificate-directory> (server.pem,
server.key), issued by a throwaway CA the wrapper has made trusted for
this process tree only.

What it shows: the command is started with a placeholder and never the
real value; its request, and its child's, reach the upstream carrying the
real value; the same placeholder used by a process outside the command's
tree is refused and never reaches the upstream; a real value echoed by
the upstream comes back as the placeholder; rv exits with the command's
status. Each step prints PASS or FAIL; exit 0 when every step passes.
"""
import http.server, json, os, shutil, ssl, subprocess, sys, tempfile, threading, time, urllib.error, urllib.request

if len(sys.argv) != 3:
    sys.exit(__doc__)
RV = os.path.abspath(sys.argv[1])
CERTIFICATES = os.path.abspath(sys.argv[2])
HOME = os.environ["HOME"]
ROOT = tempfile.mkdtemp(prefix="rv-run-e2e-", dir=HOME)
CONFIG = f"{HOME}/.config/rv"
os.makedirs(CONFIG, mode=0o700, exist_ok=True)
REAL = "sk-live-E2E-REAL-0123456789abcdef"
STEPS = []


def step(name, ok, detail=""):
    STEPS.append((name, bool(ok)))
    print(("PASS " if ok else "FAIL ") + name + (f"  [{detail}]" if detail and not ok else ""), flush=True)


SEEN = []


class Upstream(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        authorization = self.headers.get("Authorization", "")
        SEEN.append((self.path, authorization))
        # Echo what arrived: rv must turn a real value back into the placeholder.
        body = json.dumps({"path": self.path, "authorization": authorization}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Upstream)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(f"{CERTIFICATES}/server.pem", f"{CERTIFICATES}/server.key")
server.socket = context.wrap_socket(server.socket, server_side=True)
PORT = server.server_address[1]
threading.Thread(target=server.serve_forever, daemon=True).start()

with open(f"{CONFIG}/secrets.json", "w") as f:
    json.dump({"version": 1, "secrets": [{
        "name": "E2E_API_KEY", "source": {"hostEnvironment": {"variable": "E2E_REAL"}},
        "delivery": {"gateway": {"upstream": f"https://localhost:{PORT}/v1", "baseURLEnv": "E2E_BASE_URL",
                                 "placeholderPrefix": "sk-"}}}]}, f)
os.chmod(f"{CONFIG}/secrets.json", 0o600)

ENV = {
    "HOME": HOME, "PATH": "/usr/bin:/bin", "USER": os.environ.get("USER", "e2e"), "LANG": "C.UTF-8",
    "E2E_REAL": REAL,
}

# The command: asks the upstream itself, has a child ask too, tells this
# script its placeholder, and waits so an outsider can try it.
CLIENT = f"{ROOT}/client.py"
with open(CLIENT, "w") as f:
    f.write('''import json, os, subprocess, sys, time, urllib.request
out = sys.argv[1]
key, base = os.environ.get("E2E_API_KEY", ""), os.environ.get("E2E_BASE_URL", "")
def ask(path):
    request = urllib.request.Request(base + path, headers={"Authorization": "Bearer " + key})
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.status, response.read().decode()
report = {"key": key, "base": base, "environment": dict(os.environ)}
try:
    report["own"] = ask("/models")
    child = subprocess.run([sys.executable, "-c",
        "import os, urllib.request; r = urllib.request.Request(os.environ['E2E_BASE_URL'] + '/child', "
        "headers={'Authorization': 'Bearer ' + os.environ['E2E_API_KEY']}); "
        "print(urllib.request.urlopen(r, timeout=30).status)"], capture_output=True, text=True, timeout=60)
    report["child"] = child.stdout.strip() + child.stderr.strip()[-200:]
except Exception as error:
    report["error"] = repr(error)
with open(out + ".tmp", "w") as f:
    json.dump(report, f)
os.rename(out + ".tmp", out)
deadline = time.time() + 60
while not os.path.exists(out + ".done") and time.time() < deadline:
    time.sleep(0.05)
sys.exit(7)
''')

REPORT = f"{ROOT}/report.json"
process = subprocess.Popen([RV, "run", "--secret", "E2E_API_KEY", "--", "/usr/bin/python3", CLIENT, REPORT],
                           env=ENV, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
deadline = time.time() + 120
while not os.path.exists(REPORT) and process.poll() is None and time.time() < deadline:
    time.sleep(0.05)
report = json.load(open(REPORT)) if os.path.exists(REPORT) else {}
if not report:
    process.kill()
    out, err = process.communicate()
    step("rv run started the command", False, (out + err).strip()[-600:])
else:
    key, base = report.get("key", ""), report.get("base", "")
    environment = report.get("environment", {})
    step("the command holds a placeholder, not the value", key.startswith("sk-") and key != REAL and len(key) > 10, key)
    step("the real value is nowhere in its environment",
         all(REAL not in value for value in environment.values()) and "E2E_REAL" not in environment)
    step("its base URL is rv's loopback gateway", base.startswith("http://127.0.0.1:"), base)
    step("its own request succeeded", report.get("own", [0])[0] == 200, report.get("error") or report.get("own"))
    step("its child's request succeeded", report.get("child") == "200", report.get("child"))
    step("the upstream received the real value, over TLS, for both",
         ("/v1/models", "Bearer " + REAL) in SEEN and ("/v1/child", "Bearer " + REAL) in SEEN, SEEN)
    echoed = report.get("own", [0, ""])[1]
    step("a real value echoed by the upstream comes back as the placeholder",
         REAL not in echoed and key in echoed, echoed)

    # The same placeholder, from a process that is not in the command's tree.
    before = len(SEEN)
    status = None
    try:
        request = urllib.request.Request(base + "/outsider", headers={"Authorization": "Bearer " + key})
        urllib.request.urlopen(request, timeout=30)
        status = 200
    except urllib.error.HTTPError as error:
        status = error.code
    except Exception as error:
        status = repr(error)
    step("the placeholder used from outside the command's tree is refused", status == 403, status)
    step("and never reaches the upstream", len(SEEN) == before and not any(path == "/v1/outsider" for path, _ in SEEN), SEEN)

    open(REPORT + ".done", "w").close()
    out, err = process.communicate(timeout=120)
    step("rv exits with the command's status", process.returncode == 7, f"{process.returncode}: {err.strip()[-300:]}")
    step("the value is in nothing rv printed", REAL not in out and REAL not in err)

    audit = subprocess.run([RV, "audit", "--kind", "secret.use"], env=ENV, capture_output=True, text=True, timeout=60)
    misuse = subprocess.run([RV, "audit", "--kind", "secret.misuse"], env=ENV, capture_output=True, text=True, timeout=60)
    step("the audit log records the uses and the refused one",
         "E2E_API_KEY" in audit.stdout and "E2E_API_KEY" in misuse.stdout and REAL not in audit.stdout + misuse.stdout,
         (audit.stdout + audit.stderr + misuse.stdout + misuse.stderr).strip()[-400:])

# With no terminal and nothing to forward to, the gateway is gone when rv is.
if report:
    gone = None
    try:
        urllib.request.urlopen(report["base"] + "/after", timeout=5)
        gone = False
    except urllib.error.HTTPError:
        gone = False
    except Exception:
        gone = True
    step("the gateway stops with rv", gone is True)

failed = [n for n, ok in STEPS if not ok]
print(f"\n{len(STEPS) - len(failed)}/{len(STEPS)} passed")
server.shutdown()
if not failed:
    shutil.rmtree(ROOT, ignore_errors=True)
else:
    print(f"kept {ROOT} for inspection")
sys.exit(1 if failed else 0)
