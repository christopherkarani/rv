#!/usr/bin/env python3
"""Real-binary proof of Phase 8 secrets UX.

Usage: Scripts/secrets-phase8-proof.py <path-to-rv>

Throwaway HOME under /tmp. Never the real ~/.config/rv, and no Keychain
writes: imported secrets point at providers, and the hook uses a host
variable. Exit 0 when every step passes.
"""
import json, os, shutil, subprocess, sys, tempfile

if len(sys.argv) != 2:
    sys.exit(__doc__)
RV = os.path.abspath(sys.argv[1])
ROOT = tempfile.mkdtemp(prefix="rv-secrets-phase8-", dir="/tmp")
HOME = f"{ROOT}/home"
CONFIG = f"{HOME}/.config/rv"
BIN = f"{ROOT}/bin"
os.makedirs(CONFIG, mode=0o700)
os.makedirs(BIN, mode=0o755)
ENV = {
    "HOME": HOME, "PATH": f"{BIN}:/usr/bin:/bin", "USER": os.environ.get("USER", "ubuntu"),
    "LANG": "C.UTF-8", "GH_TOKEN": "proof-hook-value-xyz",
}
SECRET = "proof-infisical-value-xyz"
LITERAL = "sk-live-abcdefghijklmnopqrstuvwxyz"
STEPS = []


def step(name, ok, detail=""):
    STEPS.append((name, ok))
    print(("PASS " if ok else "FAIL ") + name + (f"  [{detail}]" if detail else ""), flush=True)


def rv(*args):
    return subprocess.run([RV, *args], env=ENV, capture_output=True, text=True, timeout=60)


with open(f"{BIN}/infisical", "w") as f:
    f.write(f"#!/bin/sh\nprintf '%s' '{SECRET}'\n")
os.chmod(f"{BIN}/infisical", 0o755)

schema = f"{ROOT}/app.env.schema"
with open(schema, "w") as f:
    f.write(f"""# @defaultSensitive=false
# @initInfisical(projectId=proj, environment=dev)
# ---
# OpenAI
# @sensitive @type=string(startsWith=sk-)
OPENAI_API_KEY=op(op://Eng/OpenAI/credential)
# @sensitive
DATABASE_URL=infisical()
# @sensitive
LITERAL={LITERAL}
PORT=3000
""")

r = rv("secrets", "import", "--varlock", schema, "--dry-run")
step("8.1 dry run names the providers and copies no literal",
     r.returncode == 0 and "import OPENAI_API_KEY: onePassword" in r.stdout and "import DATABASE_URL: infisical" in r.stdout
     and "literal value not copied" in r.stdout and "nothing written" in r.stdout and LITERAL not in r.stdout + r.stderr
     and not os.path.exists(f"{CONFIG}/secrets.json"),
     r.stdout.strip().splitlines()[-1] if r.stdout else r.stderr.strip())
r = rv("secrets", "import", "--varlock", schema)
stored = open(f"{CONFIG}/secrets.json").read() if os.path.exists(f"{CONFIG}/secrets.json") else ""
step("8.1 import writes secrets.json without the literal",
     r.returncode == 0 and "wrote secrets.json" in r.stdout and LITERAL not in stored + r.stdout + r.stderr
     and "op://Eng/OpenAI/credential" in stored and '"infisical"' in stored,
     r.stdout.strip().splitlines()[-1] if r.stdout else r.stderr.strip())
r = rv("secrets", "describe")
step("8.1 describe shows type and delivery, never a reference or a value",
     r.returncode == 0 and "OPENAI_API_KEY  onePassword  environment" in r.stdout and "type: string(startsWith=sk-)" in r.stdout
     and "op://" not in r.stdout and LITERAL not in r.stdout and SECRET not in r.stdout, r.stdout.strip().splitlines()[0])
described = json.loads(rv("secrets", "describe", "--json").stdout)
step("8.1 describe --json",
     {row["name"] for row in described["secrets"]} == {"OPENAI_API_KEY", "DATABASE_URL"}
     and described["secrets"][0]["source"] == "onePassword" and "op://" not in json.dumps(described))

r = rv("secrets", "check", "DATABASE_URL")
step("8.2 check resolves infisical and prints a fingerprint, not the value",
     r.returncode == 0 and "ok" in r.stdout and "fingerprint" in r.stdout and SECRET not in r.stdout + r.stderr,
     r.stdout.strip())
r = rv("secrets", "check", "OPENAI_API_KEY")
step("8.2 a missing provider CLI is a typed failure and exits 1",
     r.returncode == 1 and "not installed" in r.stdout and LITERAL not in r.stdout, r.stdout.strip())

# The hook checks a host variable, which the schema import does not create.
doc = json.load(open(f"{CONFIG}/secrets.json"))
doc["secrets"].append({
    "name": "GH_TOKEN", "source": {"hostEnvironment": {"variable": "GH_TOKEN"}}, "delivery": {"environment": {}},
})
with open(f"{CONFIG}/secrets.json", "w") as f:
    json.dump(doc, f)
os.chmod(f"{CONFIG}/secrets.json", 0o600)

repo = f"{ROOT}/repo"
os.makedirs(repo)
subprocess.run(["git", "init", "-q"], cwd=repo, env=ENV, check=True)
with open(f"{repo}/.git/hooks/pre-commit", "w") as f:
    f.write("#!/bin/sh\necho foreign\n")
os.chmod(f"{repo}/.git/hooks/pre-commit", 0o755)
r = subprocess.run([RV, "secrets", "hook", "install"], cwd=repo, env=ENV, capture_output=True, text=True)
hook = open(f"{repo}/.git/hooks/pre-commit").read()
saved = open(f"{repo}/.git/hooks/pre-commit.rv-saved").read()
step("8.3 install keeps the existing hook and is idempotent",
     r.returncode == 0 and "# rv-secrets-hook" in hook and saved == "#!/bin/sh\necho foreign\n"
     and subprocess.run([RV, "secrets", "hook", "install"], cwd=repo, env=ENV, capture_output=True, text=True).returncode == 0
     and open(f"{repo}/.git/hooks/pre-commit.rv-saved").read() == saved,
     r.stdout.strip())
with open(f"{repo}/leak.txt", "w") as f:
    f.write(ENV["GH_TOKEN"] + "\n")
subprocess.run(["git", "add", "leak.txt"], cwd=repo, env=ENV, check=True)
r = subprocess.run([RV, "secrets", "hook", "run"], cwd=repo, env=ENV, capture_output=True, text=True)
step("8.3 hook run prints file:line:name and not the value",
     r.returncode == 1 and "leak.txt:1:GH_TOKEN" in r.stdout and ENV["GH_TOKEN"] not in r.stdout + r.stderr, r.stdout.strip())
r = subprocess.run([RV, "secrets", "hook", "uninstall"], cwd=repo, env=ENV, capture_output=True, text=True)
step("8.3 uninstall restores the previous hook",
     r.returncode == 0 and open(f"{repo}/.git/hooks/pre-commit").read() == saved, r.stdout.strip())

failed = [name for name, ok in STEPS if not ok]
print(f"\n{len(STEPS) - len(failed)}/{len(STEPS)} passed")
if failed:
    print(f"kept {ROOT}")
    sys.exit(1)
shutil.rmtree(ROOT, ignore_errors=True)
