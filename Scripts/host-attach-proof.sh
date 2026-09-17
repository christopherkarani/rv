#!/usr/bin/env bash
# Isolated-HOME proof that `rv setup` writes adapters, then those files
# honor git reset --hard the way Grok / OpenClaw / Codex would.
# Does not install real hosts. Does not use the login HOME as HOME.
# Compatible with macOS /bin/bash 3.2.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

STAGE="${RV_RELEASE_STAGE:-$ROOT/.build/release-stage}"
FIXTURES="$ROOT/Tests/RVHooksTests/Fixtures"
C_SRC="$ROOT/Sources/rv-c"

fail() {
  printf 'host-attach-proof: %s\n' "$*" >&2
  exit 1
}

command -v python3 >/dev/null 2>&1 || fail "python3 required"
command -v node >/dev/null 2>&1 || fail "node required to play OpenClaw"
PYTHON3="$(command -v python3)"
NODE="$(command -v node)"

LOGIN_HOME="$("$PYTHON3" -c 'import pwd, os; print(pwd.getpwuid(os.getuid()).pw_dir)')"
[[ -n "$LOGIN_HOME" ]] || fail "could not resolve login HOME via getpwuid"

PROOF_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rv-host-attach.XXXXXX")"
PROOF_HOME="$PROOF_ROOT/home"
WORK="$PROOF_ROOT/work"
mkdir -p "$PROOF_HOME" "$WORK"

LABEL="dev.rv.evaluate"
UID_NUM="$(id -u)"
DOMAIN="gui/${UID_NUM}"
LIVE_PLIST="$LOGIN_HOME/Library/LaunchAgents/dev.rv.evaluate.plist"
ASIDE_PLIST="${LIVE_PLIST}.rv-host-attach-aside"
HAD_LIVE=0
LOCKDIR="/tmp/swift-arch-host-attach.lockdir"

bootout_label() {
  /bin/launchctl bootout "${DOMAIN}/${LABEL}" >/dev/null 2>&1 || true
}

wait_unloaded() {
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if ! /bin/launchctl print "${DOMAIN}/${LABEL}" >/dev/null 2>&1; then
      return 0
    fi
    bootout_label
    sleep 0.2
  done
}

CLEANED=0
cleanup() {
  if [[ "$CLEANED" -eq 1 ]]; then
    return
  fi
  CLEANED=1
  if [[ "$(uname -s)" == "Darwin" ]]; then
    bootout_label
    wait_unloaded
    if [[ "$HAD_LIVE" -eq 1 ]]; then
      if [[ ! -f "$LIVE_PLIST" && -f "$ASIDE_PLIST" ]]; then
        mv "$ASIDE_PLIST" "$LIVE_PLIST" || true
      fi
      if [[ -f "$LIVE_PLIST" ]]; then
        /bin/launchctl bootstrap "$DOMAIN" "$LIVE_PLIST" >/dev/null 2>&1 || true
      fi
    fi
    rm -f "$ASIDE_PLIST"
    rmdir "$LOCKDIR" >/dev/null 2>&1 || true
  fi
  rm -rf "$PROOF_ROOT"
}
trap cleanup EXIT INT TERM

if [[ "$(uname -s)" == "Darwin" ]]; then
  mkdir -p /tmp/swift-arch-host-attach
  for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if mkdir "$LOCKDIR" 2>/dev/null; then
      break
    fi
    sleep 1
    if [[ "$_i" -eq 15 ]]; then
      fail "could not acquire attach-proof lock"
    fi
  done
  if /bin/launchctl print "${DOMAIN}/${LABEL}" >/dev/null 2>&1; then
    HAD_LIVE=1
  fi
  if [[ -f "$LIVE_PLIST" ]]; then
    cp "$LIVE_PLIST" "$ASIDE_PLIST" || fail "could not park live LaunchAgent"
  fi
  bootout_label
  wait_unloaded
fi

LOGIN_REAL="$("$PYTHON3" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$LOGIN_HOME")"
"$PYTHON3" - "$LOGIN_HOME" "$PROOF_ROOT/login-snapshot.json" <<'PY'
import hashlib
import json
import os
import sys

login, dest = sys.argv[1], sys.argv[2]
rels = [
    ".grok",
    ".openclaw",
    ".codex",
    ".claude",
    os.path.join(".config", "rv", "config.json"),
]


def digest(path):
    hasher = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


snap = {}
for rel in rels:
    path = os.path.join(login, rel)
    if os.path.lexists(path):
        entry = {"exists": True, "is_file": os.path.isfile(path)}
        if os.path.isfile(path) and not os.path.islink(path):
            entry["sha256"] = digest(path)
        snap[rel] = entry
    else:
        snap[rel] = {"exists": False}
json.dump(snap, open(dest, "w", encoding="utf-8"), sort_keys=True)
PY

stage_ok() {
  [[ -x "$STAGE/rv" && -x "$STAGE/rv-cli" && -x "$STAGE/rvd" ]] || return 1
  local b
  for b in "$STAGE"/*_RVPacks.bundle "$STAGE"/*_RVPacks.resources; do
    if [[ -d "$b" ]]; then
      return 0
    fi
  done
  return 1
}

find_debug_bin() {
  local name="$1"
  local cand
  for cand in \
    "$ROOT/.build/debug/$name" \
    "$ROOT/.build/release/$name" \
    "$ROOT/.build/x86_64-unknown-linux-gnu/debug/$name" \
    "$ROOT/.build/x86_64-unknown-linux-gnu/release/$name" \
    "$ROOT/.build/aarch64-unknown-linux-gnu/debug/$name" \
    "$ROOT/.build/aarch64-unknown-linux-gnu/release/$name" \
    "$ROOT/.build/arm64-apple-macosx/debug/$name" \
    "$ROOT/.build/arm64-apple-macosx/release/$name"
  do
    if [[ -x "$cand" ]]; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 1
}

stage_from_debug() {
  local rvcli rvd clang_flags=()
  rvcli="$(find_debug_bin rv)" || return 1
  rvd="$(find_debug_bin rvd)" || return 1
  mkdir -p "$STAGE"
  case "$(uname -s)" in
    Darwin) clang_flags=(-arch arm64 -mmacosx-version-min=26.0) ;;
  esac
  clang -Os "${clang_flags[@]}" -std=c11 -Wall \
    -I "$C_SRC" \
    -o "$STAGE/rv" \
    "$C_SRC/json_escape.c" \
    "$C_SRC/json_reply.c" \
    "$C_SRC/rv.c" || return 1
  chmod 755 "$STAGE/rv"
  cp "$rvcli" "$STAGE/rv-cli"
  cp "$rvd" "$STAGE/rvd"
  chmod 755 "$STAGE/rv-cli" "$STAGE/rvd"
  local srcdir copied=0 b name
  srcdir="$(dirname "$rvcli")"
  for b in "$srcdir"/*_RVPacks.bundle "$srcdir"/*_RVPacks.resources; do
    [[ -d "$b" ]] || continue
    name="$(basename "$b")"
    rm -rf "$STAGE/$name"
    cp -R "$b" "$STAGE/$name"
    copied=1
  done
  [[ "$copied" -eq 1 ]]
}

if [[ "${RV_C_HOOK_SKIP_RELEASE:-0}" == "1" ]] && stage_ok; then
  printf 'host-attach-proof: using existing stage %s\n' "$STAGE"
elif stage_from_debug; then
  printf 'host-attach-proof: staged C rv + existing operator from .build\n'
else
  HOME="$LOGIN_HOME" RV_RELEASE_STAGE="$STAGE" bash "$ROOT/Scripts/release.sh"
  stage_ok || fail "release stage incomplete: $STAGE"
fi

[[ -f "$FIXTURES/grok/deny-git-reset-hard.json" ]] || fail "missing Grok fixtures"

BIN="$PROOF_HOME/.local/bin"
mkdir -p "$BIN" \
  "$PROOF_HOME/.grok" \
  "$PROOF_HOME/.openclaw" \
  "$PROOF_HOME/.codex" \
  "$PROOF_HOME/.config/rv"
printf '%s\n' '{ "analytics.enabled": false }' >"$PROOF_HOME/.config/rv/config.json"

cp "$STAGE/rv" "$BIN/rv"
cp "$STAGE/rv-cli" "$BIN/rv-cli"
cp "$STAGE/rvd" "$BIN/rvd"
chmod 755 "$BIN/rv" "$BIN/rv-cli" "$BIN/rvd"
for b in "$STAGE"/*_RVPacks.bundle "$STAGE"/*_RVPacks.resources; do
  [[ -d "$b" ]] || continue
  rm -rf "$BIN/$(basename "$b")"
  cp -R "$b" "$BIN/$(basename "$b")"
done

export HOME="$PROOF_HOME"
HOME_REAL="$("$PYTHON3" -c 'import os; print(os.path.realpath(os.environ["HOME"]))')"
if [[ "$HOME_REAL" == "$LOGIN_REAL" ]]; then
  fail "refusing to run with login HOME"
fi
unset XDG_CONFIG_HOME
export PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin"
export TERM="${TERM:-dumb}"
export CI=1

RV_ON_PATH="$(command -v rv)" || fail "staged rv not on PATH"
RV_ON_PATH_REAL="$("$PYTHON3" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$RV_ON_PATH")"
BIN_RV_REAL="$("$PYTHON3" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$BIN/rv")"
if [[ "$RV_ON_PATH_REAL" != "$BIN_RV_REAL" ]]; then
  fail "PATH rv is $RV_ON_PATH_REAL (want $BIN_RV_REAL)"
fi

set +e
(
  cd "$WORK"
  HOME="$PROOF_HOME" PATH="$PATH" TERM="dumb" CI=1 \
    rv setup --robot
) >"$PROOF_ROOT/setup.out" 2>"$PROOF_ROOT/setup.err"
st=$?
set -e
[[ "$st" -eq 0 ]] || fail "rv setup failed (exit $st) stderr=$(cat "$PROOF_ROOT/setup.err")"
grep -q "Setup complete" "$PROOF_ROOT/setup.out" \
  || fail "setup robot did not complete: $(cat "$PROOF_ROOT/setup.out") $(cat "$PROOF_ROOT/setup.err")"

GROK_JSON="$PROOF_HOME/.grok/hooks/rv.json"
OPENCLAW_JS="$PROOF_HOME/.openclaw/extensions/rv-guard/index.js"
CODEX_PY="$PROOF_HOME/.codex/hooks/rv-guard.py"
[[ -f "$GROK_JSON" ]] || fail "setup did not write Grok adapter"
[[ -f "$OPENCLAW_JS" ]] || fail "setup did not write OpenClaw adapter"
[[ -f "$CODEX_PY" ]] || fail "setup did not write Codex adapter"

"$PYTHON3" - "$GROK_JSON" "$OPENCLAW_JS" "$CODEX_PY" "$BIN/rv" <<'PY' || fail "adapters did not bake sibling rv"
import sys

grok, openclaw, codex, rv = sys.argv[1:5]
g = open(grok, encoding="utf-8").read()
o = open(openclaw, encoding="utf-8").read()
c = open(codex, encoding="utf-8").read()
if rv not in g:
    raise SystemExit("Grok JSON missing baked rv")
if "hook --host grok" not in g:
    raise SystemExit("Grok JSON missing hook --host grok")
if "rv-cli" in g.split("command", 1)[-1][:200]:
    raise SystemExit("Grok command names rv-cli")
if rv not in o:
    raise SystemExit("OpenClaw adapter missing baked rv")
if "requireApproval" in o:
    raise SystemExit("OpenClaw adapter contains requireApproval")
if rv not in c:
    raise SystemExit("Codex adapter missing baked rv")
print("baked-ok")
PY
printf 'AC-ATTACH-SETUP ok\n'

set +e
(
  cd "$WORK"
  HOME="$PROOF_HOME" PATH="$PATH" TERM="dumb" CI=1 \
    rv-cli test --robot 'git reset --hard'
) >"$PROOF_ROOT/test_deny.out" 2>"$PROOF_ROOT/test_deny.err"
st=$?
set -e
printf '%s' "$st" >"$PROOF_ROOT/test_deny.exit"
"$PYTHON3" - "$PROOF_ROOT/test_deny.out" "$PROOF_ROOT/test_deny.err" "$PROOF_ROOT/test_deny.exit" <<'PY' || fail "operator test reset-hard $(cat "$PROOF_ROOT/test_deny.out") $(cat "$PROOF_ROOT/test_deny.err")"
import json, sys
out, err, exit_path = sys.argv[1], sys.argv[2], sys.argv[3]
st = int(open(exit_path, encoding="utf-8").read() or "0")
text = open(out, encoding="utf-8").read().strip()
if st != 1:
    raise SystemExit("exit %s want 1 stderr=%r stdout=%r" % (st, open(err, encoding="utf-8").read(), text))
obj = json.loads(text.splitlines()[-1])
if obj.get("decision") != "deny":
    raise SystemExit("decision=%r body=%s" % (obj.get("decision"), text))
PY


run_stdin() {
  local name="$1"
  local cmd="$2"
  local fixture="$3"
  local st
  set +e
  (
    cd "$WORK"
    HOME="$PROOF_HOME" PATH="$PATH" TERM="dumb" CI=1 \
      "$PYTHON3" - "$cmd" "$fixture" <<'PY'
import os, shlex, subprocess, sys
cmd, fixture = sys.argv[1], sys.argv[2]
args = shlex.split(cmd)
if not args:
    sys.stderr.write("empty command\n")
    sys.exit(2)
env = os.environ.copy()
with open(fixture, "rb") as stdin:
    completed = subprocess.run(args, stdin=stdin, env=env)
sys.exit(completed.returncode)
PY
  ) >"$PROOF_ROOT/${name}.out" 2>"$PROOF_ROOT/${name}.err"
  st=$?
  set -e
  printf '%s' "$st" >"$PROOF_ROOT/${name}.exit"
}

GROK_CMD="$("$PYTHON3" - "$GROK_JSON" <<'PY'
import json, sys
obj = json.load(open(sys.argv[1], encoding="utf-8"))
print(obj["hooks"]["PreToolUse"][0]["hooks"][0]["command"])
PY
)"
[[ -n "$GROK_CMD" ]] || fail "could not read Grok command"

run_stdin grok_deny "$GROK_CMD" "$FIXTURES/grok/deny-git-reset-hard.json"
"$PYTHON3" - "$PROOF_ROOT/grok_deny.out" "$PROOF_ROOT/grok_deny.err" "$PROOF_ROOT/grok_deny.exit" <<'PY' || fail "Grok reset-hard out=$(cat "$PROOF_ROOT/grok_deny.out") err=$(cat "$PROOF_ROOT/grok_deny.err") exit=$(cat "$PROOF_ROOT/grok_deny.exit")"
import json, sys
out, err, exit_path = sys.argv[1], sys.argv[2], sys.argv[3]
st = int(open(exit_path, encoding="utf-8").read() or "0")
text = open(out, encoding="utf-8").read().strip()
if st != 0:
    raise SystemExit("exit %s want 0 stderr=%r" % (st, open(err, encoding="utf-8").read()))
if not text:
    raise SystemExit("empty stdout stderr=%r" % (open(err, encoding="utf-8").read(),))
obj = json.loads(text.splitlines()[-1])
if obj.get("decision") != "deny":
    raise SystemExit("decision=%r" % (obj.get("decision"),))
reason = str(obj.get("reason") or "")
if "Destroys uncommitted changes" not in reason:
    raise SystemExit("reason=%r" % reason)
PY
printf 'AC-ATTACH-GROK-DENY ok\n'

run_stdin grok_allow "$GROK_CMD" "$FIXTURES/grok/allow-git-status.json"
"$PYTHON3" - "$PROOF_ROOT/grok_allow.out" "$PROOF_ROOT/grok_allow.exit" <<'PY' || fail "Grok git status $(cat "$PROOF_ROOT/grok_allow.out") $(cat "$PROOF_ROOT/grok_allow.err")"
import json, sys
out, exit_path = sys.argv[1], sys.argv[2]
st = int(open(exit_path, encoding="utf-8").read() or "0")
text = open(out, encoding="utf-8").read().strip()
if st != 0:
    raise SystemExit("exit %s want 0" % st)
if not text:
    raise SystemExit(0)
obj = json.loads(text.splitlines()[-1])
if obj.get("decision") in ("deny", "block", "ask"):
    raise SystemExit("decision=%r" % (obj.get("decision"),))
PY
printf 'AC-ATTACH-GROK-ALLOW ok\n'

run_stdin codex_deny "python3 \"$CODEX_PY\"" "$FIXTURES/codex/deny-git-reset-hard.json"
"$PYTHON3" - "$PROOF_ROOT/codex_deny.out" "$PROOF_ROOT/codex_deny.err" "$PROOF_ROOT/codex_deny.exit" <<'PY' || fail "Codex reset-hard $(cat "$PROOF_ROOT/codex_deny.out") $(cat "$PROOF_ROOT/codex_deny.err")"
import json, sys
out, err, exit_path = sys.argv[1], sys.argv[2], sys.argv[3]
st = int(open(exit_path, encoding="utf-8").read() or "0")
text = open(out, encoding="utf-8").read().strip()
stderr = open(err, encoding="utf-8").read()
if st != 2:
    raise SystemExit("exit %s want 2" % st)
obj = json.loads(text.splitlines()[-1])
if obj.get("decision") != "block":
    raise SystemExit("decision=%r" % (obj.get("decision"),))
if "Destroys uncommitted changes" not in str(obj.get("reason") or ""):
    raise SystemExit("reason=%r" % obj.get("reason"))
if "Destroys uncommitted changes" not in stderr:
    raise SystemExit("stderr missing reason")
if "permissionDecision" in text:
    raise SystemExit("Claude permission deny")
PY
printf 'AC-ATTACH-CODEX-DENY ok\n'

run_stdin codex_allow "python3 \"$CODEX_PY\"" "$FIXTURES/codex/allow-git-status.json"
"$PYTHON3" - "$PROOF_ROOT/codex_allow.out" "$PROOF_ROOT/codex_allow.exit" <<'PY' || fail "Codex git status $(cat "$PROOF_ROOT/codex_allow.out") $(cat "$PROOF_ROOT/codex_allow.err")"
import json, sys
out, exit_path = sys.argv[1], sys.argv[2]
st = int(open(exit_path, encoding="utf-8").read() or "0")
text = open(out, encoding="utf-8").read().strip()
if st != 0:
    raise SystemExit("exit %s want 0" % st)
if text:
    obj = json.loads(text.splitlines()[-1])
    if obj.get("decision") in ("block", "deny", "ask"):
        raise SystemExit("decision=%r" % (obj.get("decision"),))
PY
printf 'AC-ATTACH-CODEX-ALLOW ok\n'

run_stdin openclaw_hook "$BIN/rv hook --host openclaw" "$FIXTURES/openclaw/deny-git-reset-hard.json"
"$PYTHON3" - "$PROOF_ROOT/openclaw_hook.out" "$PROOF_ROOT/openclaw_hook.exit" <<'PY' || fail "OpenClaw hook reset-hard out=$(cat "$PROOF_ROOT/openclaw_hook.out") err=$(cat "$PROOF_ROOT/openclaw_hook.err") exit=$(cat "$PROOF_ROOT/openclaw_hook.exit")"
import json, sys
out, exit_path = sys.argv[1], sys.argv[2]
st = int(open(exit_path, encoding="utf-8").read() or "0")
text = open(out, encoding="utf-8").read().strip()
if not text:
    raise SystemExit("empty stdout exit=%s" % st)
obj = json.loads(text.splitlines()[-1])
if obj.get("decision") not in ("deny", "ask"):
    raise SystemExit("decision=%r" % (obj.get("decision"),))
PY

SDK="$OPENCLAW_JS"
SDK_DIR="$(dirname "$OPENCLAW_JS")"
mkdir -p "$SDK_DIR/node_modules/openclaw/plugin-sdk"
printf '%s\n' '{"name":"openclaw","type":"module","exports":{"./plugin-sdk/plugin-entry":"./plugin-sdk/plugin-entry.js"}}' \
  >"$SDK_DIR/node_modules/openclaw/package.json"
printf '%s\n' 'export function definePluginEntry(definition) { return definition; }' \
  >"$SDK_DIR/node_modules/openclaw/plugin-sdk/plugin-entry.js"

cat >"$PROOF_ROOT/openclaw-harness.mjs" <<'EOF'
import { pathToFileURL } from "node:url";
import { readFileSync } from "node:fs";

const adapterPath = process.argv[2];
const event = JSON.parse(readFileSync(process.argv[3], "utf8"));
const def = (await import(pathToFileURL(adapterPath).href)).default;
if (!def || typeof def.register !== "function") {
  process.stdout.write(JSON.stringify({ error: "missing register" }));
  process.exit(2);
}
const registered = [];
const api = {
  on(name, fn, opts) {
    registered.push({ name, fn, opts });
  },
  runtime: { gateway: { isAvailable: async () => false } },
};
def.register(api);
const ctx = { sessionId: event.sessionId, sessionKey: event.sessionKey };
const result = await registered[0].fn(event, ctx);
process.stdout.write(JSON.stringify({ result: result ?? null }));
process.exit(0);
EOF

run_openclaw() {
  local name="$1"
  local fixture="$2"
  set +e
  (
    cd "$SDK_DIR"
    HOME="$PROOF_HOME" PATH="$PATH" TERM="dumb" CI=1 \
      "$NODE" "$PROOF_ROOT/openclaw-harness.mjs" "$OPENCLAW_JS" "$fixture"
  ) >"$PROOF_ROOT/${name}.out" 2>"$PROOF_ROOT/${name}.err"
  st=$?
  set -e
  printf '%s' "$st" >"$PROOF_ROOT/${name}.exit"
  [[ "$(cat "$PROOF_ROOT/${name}.exit")" -eq 0 ]] \
    || fail "$name node exit $(cat "$PROOF_ROOT/${name}.exit") $(cat "$PROOF_ROOT/${name}.out") $(cat "$PROOF_ROOT/${name}.err")"
}

run_openclaw openclaw_deny "$FIXTURES/openclaw/deny-git-reset-hard.json"
"$PYTHON3" - "$PROOF_ROOT/openclaw_deny.out" <<'PY' || fail "OpenClaw reset-hard $(cat "$PROOF_ROOT/openclaw_deny.out") $(cat "$PROOF_ROOT/openclaw_deny.err")"
import json, sys
obj = json.loads(open(sys.argv[1], encoding="utf-8").read())
if obj.get("error"):
    raise SystemExit("harness error %r" % obj)
result = obj.get("result") or {}
if result.get("block") is not True:
    raise SystemExit("block=%r result=%r" % (result.get("block"), result))
reason = str(result.get("blockReason") or "")
if "requireApproval" in open(sys.argv[1], encoding="utf-8").read():
    raise SystemExit("requireApproval leaked")
if reason == "":
    raise SystemExit("empty blockReason")
PY
printf 'AC-ATTACH-OPENCLAW-DENY ok\n'

run_openclaw openclaw_allow "$FIXTURES/openclaw/allow-git-status.json"
"$PYTHON3" - "$PROOF_ROOT/openclaw_allow.out" <<'PY' || fail "OpenClaw git status $(cat "$PROOF_ROOT/openclaw_allow.out") $(cat "$PROOF_ROOT/openclaw_allow.err")"
import json, sys
obj = json.loads(open(sys.argv[1], encoding="utf-8").read())
if obj.get("error"):
    raise SystemExit("harness error %r" % obj)
result = obj.get("result")
if result is None:
    raise SystemExit(0)
if isinstance(result, dict) and result.get("block") is True:
    raise SystemExit("blocked git status %r" % result)
PY
printf 'AC-ATTACH-OPENCLAW-ALLOW ok\n'

"$PYTHON3" - "$LOGIN_HOME" "$PROOF_ROOT/login-snapshot.json" <<'PY' || fail "login HOME was written"
import hashlib
import json
import os
import sys

login, snap_path = sys.argv[1], sys.argv[2]
snap = json.load(open(snap_path, encoding="utf-8"))
rels = [
    ".grok",
    ".openclaw",
    ".codex",
    ".claude",
    os.path.join(".config", "rv", "config.json"),
]


def digest(path):
    hasher = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


for rel in rels:
    path = os.path.join(login, rel)
    old = snap[rel]
    if os.path.lexists(path):
        if not old.get("exists"):
            raise SystemExit("created %s" % rel)
        if os.path.isfile(path) and not os.path.islink(path):
            if old.get("sha256") != digest(path):
                raise SystemExit("mutated %s" % rel)
    else:
        if old.get("exists"):
            raise SystemExit("deleted %s" % rel)
PY

printf 'host-attach-proof: ok home=%s\n' "$PROOF_HOME"
