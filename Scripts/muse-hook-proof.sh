#!/usr/bin/env bash
# Isolated-HOME proof for the Muse (`muse`) hook adapter.
# Stages a temp HOME with a fake ~/.config/muse/settings.json, runs the built
# `rv setup`, and checks the owned rv-hooks.json plus the managed_hooks_path
# merge, the `rv hook --host muse` wire shapes, and the adversarial cases
# (foreign key, malformed settings, missing settings, occupied file).
# Verdict evaluation needs a live rvd, so this script pins wire SHAPES
# (permissionDecision JSON, exit codes), not allow/deny verdicts.
# Never touches the login HOME (snapshot-guarded). macOS /bin/bash 3.2 safe.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail() {
  printf 'muse-hook-proof: %s\n' "$*" >&2
  exit 1
}

command -v python3 >/dev/null 2>&1 || fail "python3 required"
PYTHON3="$(command -v python3)"

LOGIN_HOME="$("$PYTHON3" -c 'import pwd, os; print(pwd.getpwuid(os.getuid()).pw_dir)')"
[[ -n "$LOGIN_HOME" ]] || fail "could not resolve login HOME via getpwuid"

RV_BIN="$ROOT/.build/out/Products/Debug/rv"
[[ -x "$RV_BIN" ]] || fail "build first: swift build (missing $RV_BIN)"

ORACLE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rv-muse-proof.XXXXXX")"
ORACLE_HOME="$ORACLE_ROOT/home"
mkdir -p "$ORACLE_HOME"

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

SNAPSHOT="$ORACLE_ROOT/login-snapshot.json"
"$PYTHON3" - "$LOGIN_HOME" "$SNAPSHOT" <<'PY'
import hashlib, json, os, sys
login, dest = sys.argv[1], sys.argv[2]
rels = [".config/muse/settings.json", ".config/muse/rv-hooks.json",
        ".config/rv/config.json"]
snap = {}
for rel in rels:
    path = os.path.join(login, rel)
    if os.path.exists(path):
        h = hashlib.sha256()
        with open(path, "rb") as handle:
            for chunk in iter(lambda: handle.read(65536), b""):
                h.update(chunk)
        snap[rel] = h.hexdigest()
    else:
        snap[rel] = None
json.dump(snap, open(dest, "w"), sort_keys=True)
PY

verify_login_untouched() {
  "$PYTHON3" - "$LOGIN_HOME" "$SNAPSHOT" <<'PY'
import hashlib, json, os, sys
login, dest = sys.argv[1], sys.argv[2]
snap = json.load(open(dest))
for rel, digest in snap.items():
    path = os.path.join(login, rel)
    if digest is None:
        assert not os.path.exists(path), "login file appeared: %s" % rel
    else:
        h = hashlib.sha256()
        with open(path, "rb") as handle:
            for chunk in iter(lambda: handle.read(65536), b""):
                h.update(chunk)
        assert h.hexdigest() == digest, "login file changed: %s" % rel
PY
}

# Oracle-local rv (symlinked so resource bundles resolve) + stub rv-cli
# (inspect requires the sibling for .wired).
mkdir -p "$ORACLE_HOME/.local/bin"
ln -s "$RV_BIN" "$ORACLE_HOME/.local/bin/rv"
printf '#!/bin/sh\nexit 0\n' > "$ORACLE_HOME/.local/bin/rv-cli"
chmod +x "$ORACLE_HOME/.local/bin/rv-cli"
ORACLE_RV="$ORACLE_HOME/.local/bin/rv"

MUSE_DIR="$ORACLE_HOME/.config/muse"
HOOKS_FILE="$MUSE_DIR/rv-hooks.json"
SETTINGS_FILE="$MUSE_DIR/settings.json"

# --- Case 1: fresh setup writes the pair, preserves foreign keys ---
mkdir -p "$MUSE_DIR"
printf '{"schema_version":1,"provider":"meta"}' > "$SETTINGS_FILE"
HOME="$ORACLE_HOME" "$ORACLE_RV" setup --robot >/dev/null || fail "setup exit != 0"
[[ -f "$HOOKS_FILE" ]] || fail "rv-hooks.json not written"
"$PYTHON3" - "$HOOKS_FILE" "$ORACLE_RV" <<'PY'
import json, sys
hooks, rv = sys.argv[1], sys.argv[2]
doc = json.load(open(hooks))
assert doc["schema_version"] == 1, "hooks file needs schema_version 1"
cmd = doc["hooks"]["PreToolUse"][0]["hooks"][0]["command"]
assert cmd == rv + " hook --host muse", "unexpected hook command: %r" % cmd
PY
printf 'ok: setup writes owned hooks file\n'
"$PYTHON3" - "$SETTINGS_FILE" "$HOOKS_FILE" <<'PY'
import json, sys
settings, hooks = sys.argv[1], sys.argv[2]
doc = json.load(open(settings))
assert doc["managed_hooks_path"] == hooks, "key not merged"
assert doc["provider"] == "meta", "foreign key lost"
assert doc["schema_version"] == 1, "schema_version lost"
PY
printf 'ok: setup merges managed_hooks_path, preserves keys\n'

# --- Case 2: doctor reports the muse slot wired ---
# (doctor exits 1 while rvd is down; the hosts map is still emitted.)
DOCTOR_JSON="$(HOME="$ORACLE_HOME" "$ORACLE_RV" doctor --robot 2>/dev/null)" || true
[[ -n "$DOCTOR_JSON" ]] || fail "doctor emitted no JSON"
"$PYTHON3" -c 'import json,sys; assert json.loads(sys.argv[1])["hosts"]["muse"] == "wired"' "$DOCTOR_JSON" \
  || fail "doctor muse slot not wired"
printf 'ok: doctor reports muse wired\n'

# --- Case 3: hook wire deny shape (exit 0 + permissionDecision) ---
# Note: `rv hook` currently denies every host pre-auth by transitional
# design (LocalControlBoundary); foreign-allow is pinned at codec level
# by MuseHookTests instead. This case proves the muse deny SHAPE.
OUT="$(printf 'not-json' | HOME="$ORACLE_HOME" "$ORACLE_RV" hook --host muse)" || fail "hook exit != 0 on malformed"
"$PYTHON3" -c 'import json,sys; d=json.loads(sys.argv[1])["hookSpecificOutput"]; assert d["hookEventName"]=="PreToolUse" and d["permissionDecision"]=="deny" and d["permissionDecisionReason"]' "$OUT" \
  || fail "malformed stdin did not deny on the muse wire"
printf 'ok: hook denies with permissionDecision + exit 0\n'

# --- Case 4: idempotent second run ---
BEFORE_HOOKS="$(cat "$HOOKS_FILE")"
BEFORE_SETTINGS="$(cat "$SETTINGS_FILE")"
HOME="$ORACLE_HOME" "$ORACLE_RV" setup --robot >/dev/null || fail "second setup exit != 0"
[[ "$(cat "$HOOKS_FILE")" == "$BEFORE_HOOKS" ]] || fail "hooks file changed on second run"
[[ "$(cat "$SETTINGS_FILE")" == "$BEFORE_SETTINGS" ]] || fail "settings changed on second run"
printf 'ok: second setup run is a no-op\n'

# --- Case 5: foreign key is occupied, never clobbered ---
printf '{"schema_version":1,"managed_hooks_path":"/other/hooks.json"}' > "$SETTINGS_FILE"
rm -f "$HOOKS_FILE"
HOME="$ORACLE_HOME" "$ORACLE_RV" setup --robot >/dev/null || fail "setup exit != 0 on foreign key"
[[ -f "$HOOKS_FILE" ]] && fail "owned file written despite foreign key"
grep -q '"/other/hooks.json"' "$SETTINGS_FILE" || fail "foreign key clobbered"
printf 'ok: foreign key skips without writing\n'

# --- Case 6: malformed settings untouched, run still green ---
printf 'not-json' > "$SETTINGS_FILE"
HOME="$ORACLE_HOME" "$ORACLE_RV" setup --robot >/dev/null || fail "setup exit != 0 on malformed settings"
[[ "$(cat "$SETTINGS_FILE")" == "not-json" ]] || fail "malformed settings touched"
[[ -f "$HOOKS_FILE" ]] && fail "owned file written despite malformed settings"
printf 'ok: malformed settings untouched\n'

# --- Case 7: missing settings never seeded ---
rm -f "$SETTINGS_FILE" "$HOOKS_FILE"
HOME="$ORACLE_HOME" "$ORACLE_RV" setup --robot >/dev/null || fail "setup exit != 0 on missing settings"
[[ -f "$SETTINGS_FILE" ]] && fail "settings.json seeded"
[[ -f "$HOOKS_FILE" ]] && fail "owned file written without settings"
printf 'ok: missing settings never seeded\n'

# --- Case 8: occupied owned file skips; --force backs up and rewrites ---
printf '{"schema_version":1}' > "$SETTINGS_FILE"
printf 'foreign-bytes' > "$HOOKS_FILE"
HOME="$ORACLE_HOME" "$ORACLE_RV" setup --robot >/dev/null || fail "setup exit != 0 on occupied file"
[[ "$(cat "$HOOKS_FILE")" == "foreign-bytes" ]] || fail "occupied file clobbered without --force"
printf 'ok: occupied owned file skips\n'
HOME="$ORACLE_HOME" "$ORACLE_RV" setup --force --robot >/dev/null || fail "setup --force exit != 0"
[[ -f "$HOOKS_FILE.bak" ]] || fail "no .bak on --force replace"
[[ "$(cat "$HOOKS_FILE.bak")" == "foreign-bytes" ]] || fail ".bak content wrong"
"$PYTHON3" -c 'import json,sys; json.load(open(sys.argv[1]))' "$HOOKS_FILE" || fail "rewritten hooks file invalid"
printf 'ok: --force backs up and rewrites owned file\n'

verify_login_untouched || fail "login HOME mutated"
printf 'ok: login HOME untouched\n'
printf 'muse-hook-proof: all cases passed\n'
