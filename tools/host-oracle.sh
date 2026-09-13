#!/usr/bin/env bash
# Isolated-HOME oracle for `rv test --robot` (W3).
# Creates a temp HOME with mktemp, puts the built `rv` on PATH, and checks
# allow/deny JSON. Does not run `rv setup`. Does not use the login HOME as HOME.
# Compatible with macOS /bin/bash 3.2.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail() {
  printf 'host-oracle: %s\n' "$*" >&2
  exit 1
}

command -v python3 >/dev/null 2>&1 || fail "python3 required"
PYTHON3="$(command -v python3)"

LOGIN_HOME="$("$PYTHON3" -c 'import pwd, os; print(pwd.getpwuid(os.getuid()).pw_dir)')"
[[ -n "$LOGIN_HOME" ]] || fail "could not resolve login HOME via getpwuid"

ORACLE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rv-host-oracle.XXXXXX")"
ORACLE_HOME="$ORACLE_ROOT/home"
WORK="$ORACLE_ROOT/work"
mkdir -p "$ORACLE_HOME" "$WORK"

CLEANED=0
cleanup() {
  if [[ "$CLEANED" -eq 1 ]]; then
    return
  fi
  CLEANED=1
  rm -rf "$ORACLE_ROOT"
}
trap cleanup EXIT INT TERM

ORACLE_REAL="$("$PYTHON3" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$ORACLE_HOME")"
LOGIN_REAL="$("$PYTHON3" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$LOGIN_HOME")"
if [[ "$ORACLE_REAL" == "$LOGIN_REAL" ]]; then
  fail "temp HOME resolved to login HOME"
fi

"$PYTHON3" - "$LOGIN_HOME" "$ORACLE_ROOT/login-snapshot.json" <<'PY'
import hashlib
import json
import os
import sys

login, dest = sys.argv[1], sys.argv[2]
rels = [".claude", ".pi", ".grok", os.path.join(".config", "rv", "config.json")]


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

# Build with the login HOME so tools/swift-6.3.3 can find the pinned
# toolchain. Fixture processes use ORACLE_HOME later.
HOME="$LOGIN_HOME" "$ROOT/tools/swift-6.3.3" build --product rv

RV=""
if [[ -x "$ROOT/.build/debug/rv" ]]; then
  RV="$ROOT/.build/debug/rv"
else
  BIN="$(HOME="$LOGIN_HOME" "$ROOT/tools/swift-6.3.3" build --product rv --show-bin-path)"
  if [[ -x "$BIN/rv" ]]; then
    RV="$BIN/rv"
  fi
fi
[[ -n "$RV" && -x "$RV" ]] || fail "built rv not found under .build"

RV_DIR="$("$PYTHON3" -c 'import os,sys; print(os.path.dirname(os.path.realpath(sys.argv[1])))' "$RV")"
RV="$RV_DIR/rv"
[[ -x "$RV" ]] || fail "resolved rv missing: $RV"

export HOME="$ORACLE_HOME"
HOME_REAL="$("$PYTHON3" -c 'import os; print(os.path.realpath(os.environ["HOME"]))')"
if [[ "$HOME_REAL" == "$LOGIN_REAL" ]]; then
  fail "refusing to run rv with login HOME"
fi
unset XDG_CONFIG_HOME

export PATH="$RV_DIR:/usr/bin:/bin"
export TERM="${TERM:-dumb}"

RV_ON_PATH="$(command -v rv)" || fail "built rv not on PATH"
RV_ON_PATH_REAL="$("$PYTHON3" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$RV_ON_PATH")"
RV_REAL="$("$PYTHON3" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$RV")"
if [[ "$RV_ON_PATH_REAL" != "$RV_REAL" ]]; then
  fail "PATH rv is $RV_ON_PATH_REAL (want $RV_REAL)"
fi

run_robot() {
  local name="$1"
  local st
  shift
  set +e
  (
    cd "$WORK"
    # Pass the command as one argv after flags. `rv test --robot -- …`
    # keeps `--` in captureForPassthrough, so echo/print would be scored as
    # `-- echo …` and pack-match reset-hard guts.
    HOME="$ORACLE_HOME" PATH="$RV_DIR:/usr/bin:/bin" TERM="dumb" \
      rv test --robot "$@"
  ) >"$ORACLE_ROOT/${name}.out" 2>"$ORACLE_ROOT/${name}.err"
  st=$?
  set -e
  printf '%s' "$st" >"$ORACLE_ROOT/${name}.exit"
}

expect_robot() {
  local name="$1"
  local want="$2"
  local needle="${3:-}"
  local st
  st="$(cat "$ORACLE_ROOT/${name}.exit")"
  "$PYTHON3" - "$ORACLE_ROOT/${name}.out" "$want" "$needle" <<'PY' || fail "$name JSON (stderr=$(cat "$ORACLE_ROOT/${name}.err" 2>/dev/null || true))"
import json
import sys

path, want, needle = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path, encoding="utf-8").read().strip()
if not text:
    raise SystemExit("empty stdout")
obj = json.loads(text)
if obj.get("schema") != "rv.test.v1":
    raise SystemExit("schema=%r" % (obj.get("schema"),))
decision = obj.get("decision")
if decision != want:
    raise SystemExit("decision=%r want %s body=%s" % (decision, want, text))
if want == "deny" and needle:
    blob = " ".join(
        [
            str(obj.get("reason") or ""),
            str(obj.get("rule_id") or ""),
            str(obj.get("pack_id") or ""),
        ]
    )
    if needle not in blob:
        raise SystemExit("deny missing %r: %r" % (needle, obj))
PY
  if [[ "$want" == "allow" ]]; then
    [[ "$st" -eq 0 ]] || fail "$name exit $st (want 0) stderr=$(cat "$ORACLE_ROOT/${name}.err")"
  else
    [[ "$st" -eq 1 ]] || fail "$name exit $st (want 1) stderr=$(cat "$ORACLE_ROOT/${name}.err")"
  fi
}

run_robot git_status 'git status'
expect_robot git_status allow
printf 'git-status allow ok\n'

run_robot git_reset_hard 'git reset --hard'
expect_robot git_reset_hard deny reset-hard
printf 'git-reset-hard deny ok\n'

run_robot bash_c_reset "bash -c 'git reset --hard'"
expect_robot bash_c_reset deny
printf 'bash-c-reset deny ok\n'

run_robot echo_reset "echo 'git reset --hard'"
expect_robot echo_reset allow
printf 'echo-reset allow ok\n'

run_robot python_print_reset "python -c \"print('git reset --hard')\""
expect_robot python_print_reset allow
printf 'python-print-reset allow ok\n'

mkdir -p "$ORACLE_HOME/.config/rv"
printf '%s\n' '{ "safety": { "level": "nope" } }' >"$ORACLE_HOME/.config/rv/config.json"
if [[ -e "$ORACLE_HOME/.config/rv/policy.toml" ]]; then
  fail "must not write machine policy.toml"
fi

run_robot git_status_nope 'git status'
expect_robot git_status_nope allow
printf 'invalid-safety-level git-status allow ok\n'

"$PYTHON3" - "$LOGIN_HOME" "$ORACLE_ROOT/login-snapshot.json" <<'PY' || fail "login HOME was written"
import hashlib
import json
import os
import sys

login, snap_path = sys.argv[1], sys.argv[2]
snap = json.load(open(snap_path, encoding="utf-8"))
rels = [".claude", ".pi", ".grok", os.path.join(".config", "rv", "config.json")]


def digest(path):
    hasher = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


for rel in rels:
    path = os.path.join(login, rel)
    before = snap[rel]
    exists = os.path.lexists(path)
    if not before["exists"] and exists:
        raise SystemExit("created %s" % path)
    if rel.endswith("config.json") and before["exists"] and exists:
        if digest(path) != before.get("sha256"):
            raise SystemExit("rewrote %s" % path)
PY

printf 'host-oracle: ok home=%s rv=%s\n' "$ORACLE_HOME" "$RV"
