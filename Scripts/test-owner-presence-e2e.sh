#!/usr/bin/env bash
# Scripts/test-owner-presence-e2e.sh — owner flows end to end with nobody
# present, on a test-owner-presence build (docs/security/test-owner-presence.md).
#
# Starts the build's real rvd with a password the script chose in its
# environment, then drives the real rv as the owner (who knows it) and as an
# agent (who does not): a hook deny, allow-once redeem on a pseudo-terminal
# (wrong password, right password, the grant used once), an owner action
# (`rv packs disable`), the lockout, the audit chain. Then the same password
# sent by the test build's rv to rvd without it in its environment, and to
# a normal rvd with it there: both must check the login password instead.
# Linux only; any user, root included; no systemd, no session bus.
#
# "The agent does not know the password" holds only inside this script. In a
# test build any process of the owner's uid, an agent included, can read the
# password from /proc/<rvd pid>/environ, or restart rvd with its own: a test
# build gives no protection against the agent. It exists to exercise the
# plumbing; never install one where an agent works against real work.
#
#   RV_TEST_OWNER_PRESENCE=1 swift build --scratch-path .build/test-owner-presence
#   Scripts/test-owner-presence-e2e.sh .build/test-owner-presence/debug [NORMAL-BUILD-DIR]
#
# NORMAL-BUILD-DIR (default .build/debug) is a build without the feature;
# the last checks are skipped, and say so, when it is not built.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ $# -ge 1 ]] || { printf 'usage: %s TEST-BUILD-DIR [NORMAL-BUILD-DIR]\n' "$0" >&2; exit 2; }
BUILD="$(cd "$1" && pwd)"
NORMAL="${2:-$ROOT/.build/debug}"
FIXTURES="$ROOT/Tests/RVHooksTests/Fixtures/claude"

log() { printf 'owner-presence-e2e: %s\n' "$*" >&2; }
die() { log "FAIL $*"; exit 1; }
pass() { log "PASS $*"; }

[[ "$(uname -s)" == "Linux" ]] || die "Linux only (on macOS rvd shows its own prompt; see the doc)"
command -v script >/dev/null || die "needs script(1) from util-linux for a pseudo-terminal"
for binary in rv rvd; do
  [[ -x "$BUILD/$binary" ]] || die "$BUILD/$binary is not built"
done
[[ "$("$BUILD/rvd" --version)" == *"(rv-test-owner-presence build)" ]] \
  || die "$BUILD is not a test-owner-presence build (rvd --version: $("$BUILD/rvd" --version))"
# The release guard must see this build for what it is.
if bash "$ROOT/Scripts/check-no-test-owner-presence.sh" "$BUILD/rv" "$BUILD/rvd" 2>/dev/null; then
  die "check-no-test-owner-presence.sh passed a test-owner-presence build"
fi
pass "check-no-test-owner-presence.sh refuses this build"

# /tmp, not $TMPDIR: the socket path must fit in sockaddr_un (108 bytes).
WORK="$(mktemp -d /tmp/rv-owner-e2e.XXXXXX)"
chmod 0700 "$WORK"
RVD_PID=""
cleanup() {
  local status=$?
  set +e
  [[ -n "$RVD_PID" ]] && kill "$RVD_PID" 2>/dev/null && wait "$RVD_PID" 2>/dev/null
  rm -rf "$WORK"
  exit "$status"
}
trap cleanup EXIT

PASSWORD="$(head -c 18 /dev/urandom | base64 | tr -d '/+=')"
export HOME="$WORK/home" XDG_RUNTIME_DIR="$WORK/xdg"
mkdir -p -m 0700 "$HOME" "$XDG_RUNTIME_DIR"
umask 022
SOCKET="$XDG_RUNTIME_DIR/rv/evaluate.sock"
# Nothing of the caller's reaches rv but what each command is given.
unset RV_TEST_OWNER_PASSWORD

start_rvd() { # BUILD-DIR [PASSWORD]
  local env=(HOME="$HOME" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" PATH=/usr/bin:/bin)
  [[ $# -ge 2 ]] && env+=(RV_TEST_OWNER_PASSWORD="$2")
  rm -f "$SOCKET"
  env -i "${env[@]}" "$1/rvd" >"$WORK/rvd.out" 2>"$WORK/rvd.err" &
  RVD_PID=$!
  for _ in $(seq 1 100); do [[ -S "$SOCKET" ]] && return 0; sleep 0.1; done
  cat "$WORK/rvd.err" >&2
  die "rvd did not listen at $SOCKET"
}
stop_rvd() {
  kill "$RVD_PID" 2>/dev/null || true
  wait "$RVD_PID" 2>/dev/null || true
  RVD_PID=""
}
# rv with no terminal, as an agent's shell runs it. Extra NAME=VALUE first.
rv_plain() { # BUILD-DIR [NAME=VALUE...] -- ARGS...
  local build="$1"; shift
  local env=(HOME="$HOME" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" PATH=/usr/bin:/bin)
  while [[ "$1" != "--" ]]; do env+=("$1"); shift; done
  shift
  env -i "${env[@]}" setsid "$build/rv" "$@" </dev/null
}
# rv on a pseudo-terminal of its own (allow-once needs one).
rv_tty() { # BUILD-DIR [NAME=VALUE...] -- ARGS...
  local build="$1"; shift
  local env=(HOME="$HOME" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" PATH=/usr/bin:/bin TERM=dumb)
  while [[ "$1" != "--" ]]; do env+=("$1"); shift; done
  shift
  local command
  printf -v command '%q ' env -i "${env[@]}" "$build/rv" "$@"
  script -qec "$command" /dev/null </dev/null
}
hook() { # BUILD-DIR FIXTURE
  env -i HOME="$HOME" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" PATH=/usr/bin:/bin \
    "$1/rv" hook --host claude <"$FIXTURES/$2"
}
# rvd, not the CLI, refused the password: only rvd's answers say these.
# A CLI that refused locally ("needs your login password at an interactive
# terminal", "was not done: …") never asked rvd anything.
rvd_checked_login_password() { # OUTPUT
  [[ "$1" == *"rv: wrong password;"* || "$1" == *"rv: rvd could not check your login password"* ]]
}
# Claude's hook prints nothing for an allow.
decision() {
  python3 -c 'import json, sys
text = sys.stdin.read().strip()
print(json.loads(text)["hookSpecificOutput"]["permissionDecision"] if text else "allow")'
}

start_rvd "$BUILD" "$PASSWORD"
grep -q "rv-test-owner-presence" "$WORK/rvd.err" || die "rvd did not say it uses the test owner check"
pass "rvd says it is a test build and uses the test owner check"

# 1. A destructive command is denied, with a code.
reply="$(hook "$BUILD" deny-git-reset-hard.json)"
[[ "$(decision <<<"$reply")" == "deny" ]] || die "git reset --hard was not denied: $reply"
code="$({ grep -oE 'rv (unlock|allow-once) [0-9a-f]{6}' <<<"$reply" || true; } | head -n 1 | awk '{print $3}')"
[[ -n "$code" ]] || die "the deny carried no allow-once code: $reply"
pass "hook denies git reset --hard with code $code"

# 2. Redeem: no password (an agent), then a wrong one, then the right one.
out="$(rv_tty "$BUILD" -- allow-once "$code" 2>&1 || true)"
[[ "$out" != *granted* ]] || die "redeemed with no password: $out"
out="$(rv_plain "$BUILD" RV_TEST_OWNER_PASSWORD="$PASSWORD" -- allow-once "$code" 2>&1 || true)"
[[ "$out" != *granted* ]] || die "redeemed with no terminal: $out"
[[ "$out" == *"interactive TTY"* ]] || die "no terminal was refused for another reason: $out"
out="$(rv_tty "$BUILD" RV_TEST_OWNER_PASSWORD="not-$PASSWORD" -- allow-once "$code" 2>&1 || true)"
[[ "$out" != *granted* ]] || die "redeemed with a wrong password: $out"
[[ "$out" == *"wrong password"* ]] || die "a wrong password was refused for another reason: $out"
pass "redeem refused without a password, without a terminal, and with a wrong password"
out="$(rv_tty "$BUILD" RV_TEST_OWNER_PASSWORD="$PASSWORD" -- allow-once "$code" 2>&1)" \
  || die "redeem with the right password failed: $out"
[[ "$out" == *granted* ]] || die "redeem with the right password did not grant: $out"
pass "redeem with the right password grants"
[[ "$(hook "$BUILD" deny-git-reset-hard.json | decision)" == "allow" ]] || die "the grant did not allow the command"
[[ "$(hook "$BUILD" deny-git-reset-hard.json | decision)" == "deny" ]] || die "the grant allowed the command twice"
pass "the grant allows the command once, then it is denied again"

# 3. An owner action, refused without the password and done with it.
out="$(rv_plain "$BUILD" -- packs disable core.git 2>&1)" && die "packs disable ran with no password: $out"
out="$(rv_plain "$BUILD" RV_TEST_OWNER_PASSWORD="wrong" -- packs disable core.git 2>&1)" \
  && die "packs disable ran with a wrong password: $out"
[[ "$out" == *"wrong password"* ]] || die "a wrong password was not reported as one: $out"
rv_plain "$BUILD" RV_TEST_OWNER_PASSWORD="$PASSWORD" -- packs disable core.git >/dev/null 2>&1 \
  || die "packs disable with the right password failed"
rv_plain "$BUILD" -- packs list --json | python3 -c '
import json, sys
packs = {p["id"]: p for p in json.load(sys.stdin)["packs"]}
sys.exit(0 if packs["core.git"]["enabled"] is False else 1)' || die "core.git is still enabled"
rv_plain "$BUILD" RV_TEST_OWNER_PASSWORD="$PASSWORD" -- packs enable core.git >/dev/null 2>&1 \
  || die "packs enable with the right password failed"
pass "packs disable/enable: refused without or with a wrong password, done with the right one"

# 4. Five wrong passwords lock owner checks, the right one included.
for _ in 1 2 3 4 5; do
  rv_plain "$BUILD" RV_TEST_OWNER_PASSWORD="wrong" -- packs disable core.git >/dev/null 2>&1 || true
done
out="$(rv_plain "$BUILD" RV_TEST_OWNER_PASSWORD="$PASSWORD" -- packs disable core.git 2>&1)" \
  && die "the right password passed during a lockout: $out"
[[ "$out" == *"locked"* ]] || die "the lockout was not reported: $out"
pass "five wrong passwords lock owner checks, the right one included"

# 5. Every owner check is in the audit chain, and the chain verifies.
rv_plain "$BUILD" -- audit verify >/dev/null 2>&1 || die "rv audit verify failed"
approved="$(grep -c '"owner.action"' "$HOME/.config/rv/audit.jsonl" || true)"
[[ "$approved" -ge 3 ]] || die "expected owner.action events in the audit log, found $approved"
pass "audit verify passes with $approved owner.action events"
stop_rvd

# 6. The same build with no password in rvd's environment is production:
#    the password in the CLI's environment goes to unix_chkpwd.
start_rvd "$BUILD"
grep -q "rv-test-owner-presence" "$WORK/rvd.err" && die "rvd used the test check with no password set"
out="$(rv_plain "$BUILD" RV_TEST_OWNER_PASSWORD="$PASSWORD" -- packs disable core.git 2>&1)" \
  && die "packs disable ran against an rvd with no test password: $out"
rvd_checked_login_password "$out" || die "the refusal did not come from rvd's password check: $out"
pass "with no test password, rvd checks the login password (refused: ${out##*rv: })"
stop_rvd

# 7. An rvd built without the feature ignores the variable. The test build's
#    rv is the client, since it is the one that sends the password (a normal
#    rv ignores the variable and, with no terminal, refuses before asking
#    rvd). rv trusts only the rvd beside it (its /proc/<pid>/exe must be the
#    sibling's real path), so both are copied into one directory, with the
#    resource bundles both look up beside themselves (the same source's).
if [[ -x "$NORMAL/rvd" ]] \
  && bash "$ROOT/Scripts/check-no-test-owner-presence.sh" "$NORMAL/rvd" 2>/dev/null; then
  MIXED="$WORK/mixed"
  mkdir -p "$MIXED"
  cp "$BUILD/rv" "$MIXED/rv"
  cp "$NORMAL/rvd" "$MIXED/rvd"
  for bundle in "$NORMAL"/*.bundle "$NORMAL"/*.resources; do
    if [[ -e "$bundle" ]]; then cp -R "$bundle" "$MIXED/"; fi
  done
  start_rvd "$MIXED" "$PASSWORD"
  grep -q "rv-test-owner-presence" "$WORK/rvd.err" && die "a normal rvd used the test check"
  out="$(rv_plain "$MIXED" RV_TEST_OWNER_PASSWORD="$PASSWORD" -- packs disable core.git 2>&1)" \
    && die "a normal rvd approved the test password: $out"
  rvd_checked_login_password "$out" || die "the normal rvd was not asked, or refused for another reason: $out"
  pass "a normal rvd given the variable checks the login password instead (refused: ${out##*rv: })"
  stop_rvd
else
  log "SKIP the normal-rvd check: $NORMAL has no rvd built without the feature"
fi
log "all checks passed"
