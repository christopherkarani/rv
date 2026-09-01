#!/usr/bin/env bash
# Process proof for C hook pipe (spec AC-001…AC-006, AC-011, AC-012).
# Uses staged rv / rv-cli / rvd and a temp HOME. Snapshots and restores a
# pre-existing LaunchAgent for dev.rv.evaluate (restore failure is a failed
# proof). Fixture processes do not use the login HOME.
# Compatible with macOS /bin/bash 3.2.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="${RV_RELEASE_STAGE:-$ROOT/.build/release-stage}"
FIXTURES="$ROOT/Tests/RVHooksTests/Fixtures/grok"
CANONICAL='RV · Blocked. Destroys uncommitted changes. Use '\''git stash'\'' first.'
# Mint-on-deny leads with a paste so truncated host cards still show the code.
LABEL="dev.rv.evaluate"
UID_NUM="$(id -u)"
DOMAIN="gui/${UID_NUM}"
PROOF_ROOT="${TMPDIR:-/tmp}/rv-c-hook-proof-$$"
CLI_LOG="$PROOF_ROOT/rv-cli.log"
IMAGE_LOG="$PROOF_ROOT/image.log"
LOCKDIR="/tmp/swift-arch-c8hook21/c-hook-proof.lockdir"

fail() {
  printf 'c-hook-proof: %s\n' "$*" >&2
  exit 1
}

clang_c_hook() {
  local dest="$1"
  local os arch
  local flags=()
  os="$(uname -s)"
  arch="$(uname -m)"
  case "$os" in
    Darwin)
      flags=(-arch arm64 -mmacosx-version-min=26.0)
      ;;
    Linux)
      case "$arch" in
        aarch64|x86_64) ;;
        *) fail "Linux aarch64 or x86_64 only" ;;
      esac
      ;;
    *)
      fail "macOS 26 Apple Silicon, or Linux aarch64/x86_64"
      ;;
  esac
  clang -Os "${flags[@]}" -std=c11 -Wall \
    -I "$ROOT/Sources/rv-c" \
    -o "$dest" \
    "$ROOT/Sources/rv-c/json_escape.c" \
    "$ROOT/Sources/rv-c/json_reply.c" \
    "$ROOT/Sources/rv-c/rv.c"
  chmod 755 "$dest"
}

linux_c_hook_proof() {
  local out home bin fixture st
  out="${TMPDIR:-/tmp}/rv-c-hook-linux-$$"
  mkdir -p "$out/home/.local/bin"
  home="$out/home"
  bin="$home/.local/bin"
  clang_c_hook "$out/rv"
  printf 'linux-clang ok %s\n' "$out/rv"
  file "$out/rv" || true

  set +e
  HOME="$home" PATH="/usr/bin:/bin" "$out/rv" hook --host grok \
    <"$FIXTURES/deny-git-reset-hard.json" \
    >"$out/last-resort.out" 2>"$out/last-resort.err"
  st=$?
  set -e
  if [[ "$st" -ne 2 ]]; then
    fail "last_resort without rv-cli must _exit(2), got $st"
  fi
  printf 'linux-last_resort ok exit=%s\n' "$st"

  cp "$out/rv" "$bin/rv"
  chmod 755 "$bin/rv"
  cat >"$bin/rv-cli" <<'EOF'
#!/bin/sh
cat
exit 2
EOF
  chmod 755 "$bin/rv-cli"

  set +e
  HOME="$home" PATH="/usr/bin:/bin" "$bin/rv" hook --host grok \
    <"$FIXTURES/deny-git-reset-hard.json" \
    >"$out/miss.out" 2>"$out/miss.err"
  st=$?
  set -e
  if [[ "$st" -ne 2 ]]; then
    fail "miss_replay must call rv-cli (exit 2), got $st"
  fi
  fixture="$(tr -d '\n' <"$FIXTURES/deny-git-reset-hard.json")"
  if ! grep -q 'git reset --hard' "$out/miss.out"; then
    fail "miss_replay did not replay the deny fixture to rv-cli"
  fi
  printf 'linux-miss_replay ok exit=%s\n' "$st"
  printf 'linux-c-hook-proof ok\n'
  rm -rf "$out"
}

LOGIN_HOME="$(python3 -c 'import pwd, os; print(pwd.getpwuid(os.getuid()).pw_dir)')"
[[ -n "$LOGIN_HOME" ]] || fail "could not resolve login HOME via getpwuid"
LIVE_PLIST="$LOGIN_HOME/Library/LaunchAgents/dev.rv.evaluate.plist"
HAD_LIVE=0
RESTORE_PLIST=""
CLEANED=0

cleanup() {
  if [[ "$CLEANED" -eq 1 ]]; then
    return
  fi
  CLEANED=1
  /bin/launchctl bootout "${DOMAIN}/${LABEL}" >/dev/null 2>&1 || true
  if [[ "$HAD_LIVE" -eq 1 ]]; then
    if [[ -f "$LIVE_PLIST" ]]; then
      :
    elif [[ -n "$RESTORE_PLIST" && -f "$RESTORE_PLIST" ]]; then
      mkdir -p "$(dirname "$LIVE_PLIST")"
      cp "$RESTORE_PLIST" "$LIVE_PLIST" || {
        printf 'c-hook-proof: could not write restore plist to %s\n' "$LIVE_PLIST" >&2
        rm -rf "$PROOF_ROOT"
        rmdir "$LOCKDIR" >/dev/null 2>&1 || true
        exit 1
      }
    else
      printf 'c-hook-proof: LaunchAgent was loaded but no restore plist remains\n' >&2
      rm -rf "$PROOF_ROOT"
      rmdir "$LOCKDIR" >/dev/null 2>&1 || true
      exit 1
    fi
    if ! /bin/launchctl bootstrap "$DOMAIN" "$LIVE_PLIST"; then
      printf 'c-hook-proof: failed to restore LaunchAgent from %s\n' "$LIVE_PLIST" >&2
      rm -rf "$PROOF_ROOT"
      rmdir "$LOCKDIR" >/dev/null 2>&1 || true
      exit 1
    fi
  fi
  rm -rf "$PROOF_ROOT"
  rmdir "$LOCKDIR" >/dev/null 2>&1 || true
}

trap cleanup EXIT INT TERM

mkdir -p /tmp/swift-arch-c8hook21
for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
  if mkdir "$LOCKDIR" 2>/dev/null; then
    break
  fi
  sleep 1
  if [[ "$_i" -eq 30 ]]; then
    fail "could not acquire proof lock"
  fi
done

[[ -d "$FIXTURES" ]] || fail "missing Grok fixtures at $FIXTURES"

if [[ "$(uname -s)" == "Linux" ]]; then
  linux_c_hook_proof
  exit 0
fi

stage_ok() {
  [[ -x "$STAGE/rv" && -x "$STAGE/rv-cli" && -x "$STAGE/rvd" ]] || return 1
  local b
  for b in "$STAGE"/*_RVPacks.bundle; do
    if [[ -d "$b" ]]; then
      return 0
    fi
  done
  return 1
}

# Skip is not a free pass on yesterday's C image.
stage_stale() {
  local src
  [[ -x "$STAGE/rv" ]] || return 0
  for src in "$ROOT/Sources/rv-c"/*.[ch]; do
    [[ -f "$src" ]] || continue
    if [[ "$STAGE/rv" -ot "$src" ]]; then
      return 0
    fi
  done
  return 1
}

if [[ "${RV_C_HOOK_SKIP_RELEASE:-0}" == "1" ]] && stage_ok && ! stage_stale; then
  printf 'c-hook-proof: using existing stage %s\n' "$STAGE"
else
  RV_RELEASE_STAGE="$STAGE" bash "$ROOT/tools/release.sh"
  stage_ok || fail "release stage incomplete: $STAGE"
fi

if otool -L "$STAGE/rv" | grep -E 'Foundation|CFNetwork' >/dev/null; then
  fail "staged rv links Foundation or CFNetwork"
fi
if grep -E 'RV_BYPASS|RV_SKIP|RV_NO_EVAL' "$ROOT/Sources/rv-c"/*.[ch] >/dev/null 2>&1; then
  fail "C hook sources mention a skip-evaluate env"
fi

mkdir -p "$PROOF_ROOT/home/.local/bin" "$PROOF_ROOT/bin"
PROOF_HOME="$PROOF_ROOT/home"
# Login HOME is only for LaunchAgent restore. Fixture processes use this HOME.
export HOME="$PROOF_HOME"
BIN="$PROOF_HOME/.local/bin"
cp "$STAGE/rv" "$BIN/rv"
chmod 755 "$BIN/rv"
cat > "$BIN/rv-cli" <<EOF
#!/bin/sh
{
  printf 'exe=%s\n' "\$0"
  printf 'argv=%s\n' "\$*"
} >> "$CLI_LOG"
exec "$STAGE/rv-cli" "\$@"
EOF
chmod 755 "$BIN/rv-cli"

clear_cli() {
  rm -f "$CLI_LOG"
}

cli_invoked() {
  [[ -s "$CLI_LOG" ]]
}

write_runner() {
  cat > "$PROOF_ROOT/run_hook.py" <<'PY'
import ctypes
import os
import subprocess
import sys

PROC_PIDPATHINFO_MAXSIZE = 4096


def pid_path(pid):
    lib = ctypes.CDLL("/usr/lib/libproc.dylib")
    buf = ctypes.create_string_buffer(PROC_PIDPATHINFO_MAXSIZE)
    n = lib.proc_pidpath(
        ctypes.c_int(pid), buf, ctypes.c_uint32(PROC_PIDPATHINFO_MAXSIZE)
    )
    if n <= 0:
        return ""
    return buf.value.decode()


def main():
    rv, home, stdin_path = sys.argv[1], sys.argv[2], sys.argv[3]
    extra = sys.argv[4:]
    env = os.environ.copy()
    env["HOME"] = home
    env["PATH"] = "/usr/bin:/bin"
    env["TERM"] = "dumb"
    with open(stdin_path, "rb") as handle:
        payload = handle.read()
    proc = subprocess.Popen(
        [rv, "hook", "--host", "grok"] + extra,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    )
    image = pid_path(proc.pid)
    out, err = proc.communicate(payload)
    sidecar = os.environ.get("RV_C_HOOK_IMAGE_LOG")
    if sidecar:
        with open(sidecar, "w", encoding="utf-8") as handle:
            handle.write(image + "\n")
    sys.stdout.buffer.write(out)
    sys.stderr.buffer.write(err)
    raise SystemExit(proc.returncode)


if __name__ == "__main__":
    main()
PY
}

write_runner

run_hook() {
  local stdin_path="$1"
  shift
  HOME="$PROOF_HOME" RV_C_HOOK_IMAGE_LOG="$IMAGE_LOG" python3 \
    "$PROOF_ROOT/run_hook.py" "$BIN/rv" "$PROOF_HOME" "$stdin_path" "$@"
}

run_argv() {
  HOME="$PROOF_HOME" PATH="/usr/bin:/bin" TERM="dumb" "$@"
}

minted_reset_hard_deny_ok() {
  python3 - "$1" "$CANONICAL" <<'PY'
import json
import re
import sys

path, canonical = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read().strip()
if not text:
    raise SystemExit(2)
obj = json.loads(text)
if obj.get("decision") != "deny":
    raise SystemExit("decision=%r" % (obj.get("decision"),))
reason = obj.get("reason")
why = canonical[len("RV · Blocked. "):] if canonical.startswith("RV · Blocked. ") else canonical
minted = re.compile(
    r"^RV · Blocked\. Paste in Terminal to allow once: rv allow-once [0-9a-f]{6}\. "
    + re.escape(why)
    + r"$"
)
if minted.match(reason or "") is None:
    raise SystemExit("reason=%r" % (reason,))
if "git reset --hard" in (reason or ""):
    raise SystemExit("reason echoes command")
if "hookSpecificOutput" in obj or "updatedInput" in obj or "block" in obj:
    raise SystemExit("extra host keys present")
PY
}

expect_json() {
  local stdout_file="$1"
  local expect_decision="$2"
  if [[ "$expect_decision" != "deny" ]]; then
    fail "expect_json only covers minted pack deny (got $expect_decision)"
  fi
  minted_reset_hard_deny_ok "$stdout_file"
}

expect_robot_deny() {
  python3 - "$1" <<'PY'
import json
import sys

obj = json.loads(open(sys.argv[1], encoding="utf-8").read())
if obj.get("schema") != "rv.test.v1":
    raise SystemExit("schema=%r" % (obj.get("schema"),))
if obj.get("decision") != "deny":
    raise SystemExit("decision=%r" % (obj.get("decision"),))
if obj.get("rule_id") != "core.git:reset-hard":
    raise SystemExit("rule_id=%r" % (obj.get("rule_id"),))
PY
}

expect_c_image() {
  local image
  image="$(sed -n '1p' "$IMAGE_LOG")"
  local resolved_image resolved_rv
  resolved_image="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$image")"
  resolved_rv="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$BIN/rv")"
  if [[ "$resolved_image" != "$resolved_rv" ]]; then
    fail "process image is $resolved_image (want C hook $resolved_rv)"
  fi
  if [[ "$image" == *rv-cli* ]]; then
    fail "process image names rv-cli: $image"
  fi
}

write_plist() {
  local program="$1"
  local dest="$2"
  cat > "$dest" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>dev.rv.evaluate</string>
	<key>MachServices</key>
	<dict>
		<key>dev.rv.evaluate</key>
		<true/>
	</dict>
	<key>ProgramArguments</key>
	<array>
		<string>${program}</string>
	</array>
	<key>EnvironmentVariables</key>
	<dict>
		<key>HOME</key>
		<string>${PROOF_HOME}</string>
	</dict>
	<key>WorkingDirectory</key>
	<string>${STAGE}</string>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<false/>
	<key>EnableTransactions</key>
	<true/>
	<key>StandardOutPath</key>
	<string>${PROOF_ROOT}/rvd.out</string>
	<key>StandardErrorPath</key>
	<string>${PROOF_ROOT}/rvd.err</string>
</dict>
</plist>
EOF
}

bootout_label() {
  /bin/launchctl bootout "${DOMAIN}/${LABEL}" >/dev/null 2>&1 || true
}

bootstrap_plist() {
  local plist="$1"
  bootout_label
  /bin/launchctl bootstrap "$DOMAIN" "$plist" || fail "launchctl bootstrap failed for $plist"
  /bin/launchctl kickstart -k "${DOMAIN}/${LABEL}" >/dev/null 2>&1 || true
}

if /bin/launchctl print "${DOMAIN}/${LABEL}" >/dev/null 2>&1; then
  HAD_LIVE=1
  if [[ ! -f "$LIVE_PLIST" ]]; then
    fail "LaunchAgent ${LABEL} is loaded but ${LIVE_PLIST} is missing; refuse to replace it"
  fi
  RESTORE_PLIST="$PROOF_ROOT/restore-launchagent.plist"
  cp "$LIVE_PLIST" "$RESTORE_PLIST" || fail "could not snapshot LaunchAgent plist"
fi

write_plist "$STAGE/rvd" "$PROOF_ROOT/rvd.plist"
bootstrap_plist "$PROOF_ROOT/rvd.plist"

warm=0
for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  clear_cli
  set +e
  run_hook "$FIXTURES/allow-git-status.json" >"$PROOF_ROOT/warm.out" 2>"$PROOF_ROOT/warm.err"
  st=$?
  set -e
  if [[ "$st" -eq 0 && ! -s "$PROOF_ROOT/warm.out" ]] && ! cli_invoked; then
    warm=1
    break
  fi
  sleep 0.25
done
if [[ "$warm" -ne 1 ]]; then
  printf 'c-hook-proof: rvd.err\n' >&2
  cat "$PROOF_ROOT/rvd.err" >&2 || true
  fail "could not warm staged rvd (last exit $st cli=$(cat "$CLI_LOG" 2>/dev/null || true))"
fi

# AC-001: warm pipe deny, C image, existing Grok deny JSON.
clear_cli
set +e
run_hook "$FIXTURES/deny-git-reset-hard.json" >"$PROOF_ROOT/ac001.out" 2>"$PROOF_ROOT/ac001.err"
ac001=$?
set -e
[[ "$ac001" -eq 0 ]] || fail "AC-001 exit $ac001 stderr=$(cat "$PROOF_ROOT/ac001.err")"
expect_json "$PROOF_ROOT/ac001.out" "deny" || fail "AC-001 JSON: $?"
expect_c_image
if cli_invoked; then
  fail "AC-001 invoked rv-cli (pipe path must stay on the C hook): $(cat "$CLI_LOG")"
fi
printf 'AC-001 ok\n'

# AC-002: warm pipe allow.
clear_cli
set +e
run_hook "$FIXTURES/allow-git-status.json" >"$PROOF_ROOT/ac002.out" 2>"$PROOF_ROOT/ac002.err"
ac002=$?
set -e
[[ "$ac002" -eq 0 ]] || fail "AC-002 exit $ac002"
[[ ! -s "$PROOF_ROOT/ac002.out" ]] || fail "AC-002 stdout not empty"
expect_c_image
if cli_invoked; then
  fail "AC-002 invoked rv-cli: $(cat "$CLI_LOG")"
fi
clear_cli
set +e
run_hook "$FIXTURES/allow-medium-stash-drop.json" >"$PROOF_ROOT/ac002b.out" 2>"$PROOF_ROOT/ac002b.err"
ac002b=$?
set -e
[[ "$ac002b" -eq 0 ]] || fail "AC-002 stash-drop exit $ac002b"
[[ ! -s "$PROOF_ROOT/ac002b.out" ]] || fail "AC-002 stash-drop stdout not empty"
expect_c_image
if cli_invoked; then
  fail "AC-002 stash-drop invoked rv-cli: $(cat "$CLI_LOG")"
fi
printf 'AC-002 ok\n'

# AC-005: help is HelpDispatch; C execs rv-cli and does not pipe.
clear_cli
set +e
run_argv "$BIN/rv" hook --help >"$PROOF_ROOT/ac005.out" 2>"$PROOF_ROOT/ac005.err"
ac005=$?
set -e
[[ "$ac005" -eq 0 ]] || fail "AC-005 exit $ac005 stderr=$(cat "$PROOF_ROOT/ac005.err")"
grep -q '^Usage' "$PROOF_ROOT/ac005.out" || fail "AC-005 missing Usage"
grep -q 'rv hook \[--host' "$PROOF_ROOT/ac005.out" || fail "AC-005 missing hook usage"
if grep -q 'OVERVIEW:' "$PROOF_ROOT/ac005.out"; then
  fail "AC-005 looks like ArgumentParser overview"
fi
if grep -q 'SUBCOMMANDS:' "$PROOF_ROOT/ac005.out"; then
  fail "AC-005 looks like ArgumentParser subcommands"
fi
cli_invoked || fail "AC-005 did not exec rv-cli"
grep -q -- '--help' "$CLI_LOG" || fail "AC-005 rv-cli argv missing --help"
printf 'AC-005 ok\n'

# REQ-004: invalid host execs rv-cli and does not evaluate (not deny JSON, not allow-exit-0).
clear_cli
set +e
run_argv "$BIN/rv" hook --host nope \
  <"$FIXTURES/deny-git-reset-hard.json" \
  >"$PROOF_ROOT/req004.out" 2>"$PROOF_ROOT/req004.err"
req004=$?
set -e
[[ "$req004" -ne 0 ]] || fail "REQ-004 invalid host exit 0 (looks like allow)"
cli_invoked || fail "REQ-004 did not exec rv-cli"
grep -q -- 'nope' "$CLI_LOG" || fail "REQ-004 rv-cli argv missing host"
python3 - "$PROOF_ROOT/req004.out" <<'PY' || fail "REQ-004 produced a host Decision JSON"
import json
import sys

text = open(sys.argv[1], encoding="utf-8").read().strip()
if not text:
    raise SystemExit(0)
try:
    obj = json.loads(text)
except Exception:
    raise SystemExit(0)
if obj.get("decision") in ("deny", "allow"):
    raise SystemExit(1)
PY
printf 'REQ-004 ok\n'

# AC-006: operator argv execs rv-cli; robot Decision is deny.
clear_cli
set +e
run_argv "$BIN/rv" test --robot --plain 'git reset --hard' \
  >"$PROOF_ROOT/ac006.out" 2>"$PROOF_ROOT/ac006.err"
ac006=$?
set -e
[[ "$ac006" -eq 1 ]] || fail "AC-006 exit $ac006 (want 1) stderr=$(cat "$PROOF_ROOT/ac006.err")"
expect_robot_deny "$PROOF_ROOT/ac006.out" || fail "AC-006 robot JSON"
cli_invoked || fail "AC-006 did not exec rv-cli"
grep -q -- 'test' "$CLI_LOG" || fail "AC-006 rv-cli argv missing test"
printf 'AC-006 ok\n'

# AC-011: skip-shaped envs do not skip evaluate (pipe still denies).
clear_cli
set +e
RV_BYPASS=1 RV_ALLOW=1 RV_SKIP=1 RV_DISABLE=1 RV_NO_EVAL=1 \
  run_hook "$FIXTURES/deny-git-reset-hard.json" \
  >"$PROOF_ROOT/ac011.out" 2>"$PROOF_ROOT/ac011.err"
ac011=$?
set -e
[[ "$ac011" -eq 0 ]] || fail "AC-011 exit $ac011"
expect_json "$PROOF_ROOT/ac011.out" "deny" || fail "AC-011 honored a skip env"
if cli_invoked; then
  fail "AC-011 fell off the pipe path: $(cat "$CLI_LOG")"
fi
printf 'AC-011 ok\n'

# AC-012: NUL and oversize take miss; do not send truncated hookEvaluate.
python3 - "$FIXTURES/deny-git-reset-hard.json" "$PROOF_ROOT/nul.bin" <<'PY'
import sys
body = open(sys.argv[1], "rb").read()
open(sys.argv[2], "wb").write(body[:20] + b"\x00" + body[20:])
PY
clear_cli
set +e
run_hook "$PROOF_ROOT/nul.bin" >"$PROOF_ROOT/ac012-nul.out" 2>"$PROOF_ROOT/ac012-nul.err"
ac012n=$?
set -e
cli_invoked || fail "AC-012 NUL did not take miss (rv-cli quiet)"
python3 - "$FIXTURES/deny-git-reset-hard.json" "$PROOF_ROOT/oversize.bin" <<'PY'
import sys
body = open(sys.argv[1], "rb").read().rstrip() + b"\n"
need = 1048577 - len(body)
open(sys.argv[2], "wb").write(body + (b" " * max(need, 1)))
PY
clear_cli
set +e
run_hook "$PROOF_ROOT/oversize.bin" >"$PROOF_ROOT/ac012-over.out" 2>"$PROOF_ROOT/ac012-over.err"
ac012o=$?
set -e
cli_invoked || fail "AC-012 oversize did not take miss (rv-cli quiet)"
printf 'AC-012 ok\n'

# AC-003 / AC-004: rvd down → miss, still deny / empty allow.
bootout_label
sleep 0.2
clear_cli
set +e
run_hook "$FIXTURES/deny-git-reset-hard.json" >"$PROOF_ROOT/ac003.out" 2>"$PROOF_ROOT/ac003.err"
ac003=$?
set -e
[[ "$ac003" -eq 0 ]] || fail "AC-003 down exit $ac003"
expect_json "$PROOF_ROOT/ac003.out" "deny" || fail "AC-003 down was not deny"
cli_invoked || fail "AC-003 down did not take miss"
printf 'AC-003-down ok\n'

# AC-011 miss: rv-cli hook must still deny under skip-shaped envs.
clear_cli
set +e
RV_BYPASS=1 RV_ALLOW=1 RV_SKIP=1 RV_DISABLE=1 RV_NO_EVAL=1 \
  run_hook "$FIXTURES/deny-git-reset-hard.json" \
  >"$PROOF_ROOT/ac011-miss.out" 2>"$PROOF_ROOT/ac011-miss.err"
ac011m=$?
set -e
[[ "$ac011m" -eq 0 ]] || fail "AC-011 miss exit $ac011m"
expect_json "$PROOF_ROOT/ac011-miss.out" "deny" || fail "AC-011 miss honored a skip env"
cli_invoked || fail "AC-011 miss did not take rv-cli: $(cat "$CLI_LOG" 2>/dev/null || true)"
printf 'AC-011-miss ok\n'

clear_cli
set +e
run_hook "$FIXTURES/deny-empty-command.json" >"$PROOF_ROOT/ac004.out" 2>"$PROOF_ROOT/ac004.err"
ac004=$?
set -e
[[ "$ac004" -eq 0 ]] || fail "AC-004 empty-command exit $ac004"
python3 - "$PROOF_ROOT/ac004.out" <<'PY' || fail "AC-004 empty-command was not missingCommand deny JSON"
import json, sys
obj = json.loads(open(sys.argv[1], encoding="utf-8").read())
if obj.get("decision") != "deny":
    raise SystemExit("decision=%r" % (obj.get("decision"),))
if obj.get("reason") != "rv received a shell hook with no command text and blocked the command. Run it in Terminal.":
    raise SystemExit("reason=%r" % (obj.get("reason"),))
if obj.get("rule") or obj.get("next"):
    raise SystemExit("unexpected rule/next")
if "hookSpecificOutput" in obj or "updatedInput" in obj or "block" in obj:
    raise SystemExit("extra host keys present")
PY
cli_invoked || fail "AC-004 empty-command did not take miss"

clear_cli
set +e
run_hook "$FIXTURES/allow-non-shell-read.json" >"$PROOF_ROOT/ac004b.out" 2>"$PROOF_ROOT/ac004b.err"
ac004b=$?
set -e
[[ "$ac004b" -eq 0 ]] || fail "AC-004 non-shell exit $ac004b"
[[ ! -s "$PROOF_ROOT/ac004b.out" ]] || fail "AC-004 non-shell stdout not empty"
cli_invoked || fail "AC-004 non-shell did not take miss"
printf 'AC-004 ok\n'

# AC-003 skew: major-semver listener returns empty allow; C must miss and deny.
cat > "$PROOF_ROOT/skew-rvd.c" <<'EOF'
#include <dispatch/dispatch.h>
#include <string.h>
#include <xpc/xpc.h>

#define RV_IPC_KEY "rv.ipc"

static const char kReply[] =
    "{\"id\":\"00000000-0000-0000-0000-000000000001\","
    "\"protocol\":\"rv.ipc.v1\","
    "\"result\":{\"hookEvaluate\":{"
    "\"exitCode\":0,\"serviceSemver\":\"2.0.0\",\"stdout\":\"\",\"via\":\"xpc\"}}}";

int main(void) {
    xpc_connection_t listener = xpc_connection_create_mach_service(
        "dev.rv.evaluate",
        NULL,
        XPC_CONNECTION_MACH_SERVICE_LISTENER
    );
    if (listener == NULL) {
        return 1;
    }
    xpc_connection_set_event_handler(listener, ^(xpc_object_t event) {
        if (xpc_get_type(event) != XPC_TYPE_CONNECTION) {
            return;
        }
        xpc_connection_t peer = event;
        xpc_connection_set_event_handler(peer, ^(xpc_object_t msg) {
            xpc_object_t reply;
            xpc_connection_t remote;
            if (xpc_get_type(msg) != XPC_TYPE_DICTIONARY) {
                return;
            }
            reply = xpc_dictionary_create_reply(msg);
            if (reply == NULL) {
                return;
            }
            xpc_dictionary_set_data(reply, RV_IPC_KEY, kReply, sizeof kReply - 1);
            remote = xpc_dictionary_get_remote_connection(msg);
            if (remote != NULL) {
                xpc_connection_send_message(remote, reply);
            }
            xpc_release(reply);
        });
        xpc_connection_resume(peer);
    });
    xpc_connection_resume(listener);
    dispatch_main();
    return 0;
}
EOF
clang -Os -arch arm64 -mmacosx-version-min=26.0 -std=c11 -Wall \
  -o "$PROOF_ROOT/skew-rvd" "$PROOF_ROOT/skew-rvd.c"
chmod 755 "$PROOF_ROOT/skew-rvd"
write_plist "$PROOF_ROOT/skew-rvd" "$PROOF_ROOT/skew.plist"
bootstrap_plist "$PROOF_ROOT/skew.plist"
skew_warm=0
for _i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  clear_cli
  set +e
  run_hook "$FIXTURES/deny-git-reset-hard.json" >"$PROOF_ROOT/ac003-skew.out" 2>"$PROOF_ROOT/ac003-skew.err"
  ac003s=$?
  set -e
  if [[ "$ac003s" -eq 0 ]]; then
    if minted_reset_hard_deny_ok "$PROOF_ROOT/ac003-skew.out"; then
      if cli_invoked; then
        skew_warm=1
        break
      fi
    fi
  fi
  sleep 0.25
done
[[ "$skew_warm" -eq 1 ]] || fail "AC-003 skew did not miss-and-deny (exit $ac003s out=$(cat "$PROOF_ROOT/ac003-skew.out" 2>/dev/null || true))"
printf 'AC-003-skew ok\n'
printf 'AC-003 ok\n'

bootout_label

# AC-003 unparseable: echo the request id so miss is from advertised
# serviceSemver, not id mismatch. Empty allow must still deny.
cat > "$PROOF_ROOT/unparseable-rvd.c" <<'EOF'
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <string.h>
#include <xpc/xpc.h>

#define RV_IPC_KEY "rv.ipc"

static const char kIdKey[] = "\"id\":\"";
static const char kFmt[] =
    "{\"id\":\"%s\","
    "\"protocol\":\"rv.ipc.v1\","
    "\"result\":{\"hookEvaluate\":{"
    "\"exitCode\":0,\"serviceSemver\":\"not-a-version\",\"stdout\":\"\",\"via\":\"xpc\"}}}";

static int extract_id(const char *json, size_t n, char out[37]) {
    size_t i;
    if (n < sizeof kIdKey - 1 + 36) {
        return -1;
    }
    for (i = 0; i + sizeof kIdKey - 1 + 36 <= n; i++) {
        if (memcmp(json + i, kIdKey, sizeof kIdKey - 1) == 0) {
            memcpy(out, json + i + sizeof kIdKey - 1, 36);
            out[36] = '\0';
            return 0;
        }
    }
    return -1;
}

int main(void) {
    xpc_connection_t listener = xpc_connection_create_mach_service(
        "dev.rv.evaluate",
        NULL,
        XPC_CONNECTION_MACH_SERVICE_LISTENER
    );
    if (listener == NULL) {
        return 1;
    }
    xpc_connection_set_event_handler(listener, ^(xpc_object_t event) {
        if (xpc_get_type(event) != XPC_TYPE_CONNECTION) {
            return;
        }
        xpc_connection_t peer = event;
        xpc_connection_set_event_handler(peer, ^(xpc_object_t msg) {
            xpc_object_t reply;
            xpc_connection_t remote;
            size_t n = 0;
            const void *data;
            char request_id[37];
            char payload[256];
            int wrote;
            if (xpc_get_type(msg) != XPC_TYPE_DICTIONARY) {
                return;
            }
            data = xpc_dictionary_get_data(msg, RV_IPC_KEY, &n);
            if (data == NULL || extract_id(data, n, request_id) != 0) {
                return;
            }
            wrote = snprintf(payload, sizeof payload, kFmt, request_id);
            if (wrote < 0 || wrote >= (int)sizeof payload) {
                return;
            }
            reply = xpc_dictionary_create_reply(msg);
            if (reply == NULL) {
                return;
            }
            xpc_dictionary_set_data(reply, RV_IPC_KEY, payload, (size_t)wrote);
            remote = xpc_dictionary_get_remote_connection(msg);
            if (remote != NULL) {
                xpc_connection_send_message(remote, reply);
            }
            xpc_release(reply);
        });
        xpc_connection_resume(peer);
    });
    xpc_connection_resume(listener);
    dispatch_main();
    return 0;
}
EOF
clang -Os -arch arm64 -mmacosx-version-min=26.0 -std=c11 -Wall \
  -o "$PROOF_ROOT/unparseable-rvd" "$PROOF_ROOT/unparseable-rvd.c"
chmod 755 "$PROOF_ROOT/unparseable-rvd"
write_plist "$PROOF_ROOT/unparseable-rvd" "$PROOF_ROOT/unparseable.plist"
bootstrap_plist "$PROOF_ROOT/unparseable.plist"
unparseable_warm=0
for _i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  clear_cli
  set +e
  run_hook "$FIXTURES/deny-git-reset-hard.json" >"$PROOF_ROOT/ac003-unparseable.out" 2>"$PROOF_ROOT/ac003-unparseable.err"
  ac003u=$?
  set -e
  if [[ "$ac003u" -eq 0 ]]; then
    if minted_reset_hard_deny_ok "$PROOF_ROOT/ac003-unparseable.out"; then
      if cli_invoked; then
        unparseable_warm=1
        break
      fi
    fi
  fi
  sleep 0.25
done
[[ "$unparseable_warm" -eq 1 ]] || fail "AC-003 unparseable did not miss-and-deny (exit $ac003u out=$(cat "$PROOF_ROOT/ac003-unparseable.out" 2>/dev/null || true))"
printf 'AC-003-unparseable ok\n'
bootout_label

# AC-013: with the rv-cli sibling missing, operator argv (doctor) must say
# why on stderr instead of dying silently — doctor stays reachable in
# exactly the broken state it diagnoses.
hidden_cli="$PROOF_ROOT/rv-cli.hidden"
mv "$BIN/rv-cli" "$hidden_cli"
ac013_st=0
HOME="$PROOF_HOME" PATH="/usr/bin:/bin" TERM="dumb" \
  "$BIN/rv" doctor >"$PROOF_ROOT/ac013.out" 2>"$PROOF_ROOT/ac013.err" || ac013_st=$?
ac013_err="$(cat "$PROOF_ROOT/ac013.err")"
mv "$hidden_cli" "$BIN/rv-cli"
if [[ "$ac013_st" -eq 0 ]]; then
  fail "AC-013 doctor must not succeed while rv-cli is missing"
fi
if [[ "$ac013_st" -ne 2 ]]; then
  fail "AC-013 expected deterministic exit 2, got $ac013_st"
fi
grep -q "rv-cli not found" "$PROOF_ROOT/ac013.err" \
  || fail "AC-013 missing-sibling stderr explanation absent: $ac013_err"
printf 'AC-013 ok\n'

printf 'c-hook-proof: all ACs ok stage=%s\n' "$STAGE"
