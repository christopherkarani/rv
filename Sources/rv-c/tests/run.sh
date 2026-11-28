#!/usr/bin/env bash
# Compile and run C JSON-escape unit tests. Not an SPM target.
set -euo pipefail
# Cases below pin the default fallback posture; an operator's own setting
# must not leak in.
unset RV_HOOK_WHEN_DOWN

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SRC="$ROOT/Sources/rv-c"
OUT="${RV_C_TEST_OUT:-$ROOT/.build/rv-c-tests}"

OS="$(uname -s)"
ARCH="$(uname -m)"
CLANG_OS_FLAGS=()
case "$OS" in
  Darwin)
    if [[ "$ARCH" != "arm64" ]]; then
      printf "rv-c tests: Apple Silicon only\n" >&2
      exit 1
    fi
    CLANG_OS_FLAGS=(-arch arm64 -mmacosx-version-min=15.0 -framework Security -framework CoreFoundation)
    ;;
  Linux)
    case "$ARCH" in
      aarch64|x86_64) ;;
      *)
        printf "rv-c tests: Linux aarch64 or x86_64 only\n" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    printf "rv-c tests: macOS 15 Apple Silicon, or Linux aarch64/x86_64\n" >&2
    exit 1
    ;;
esac

mkdir -p "$OUT"
clang -Os "${CLANG_OS_FLAGS[@]}" -std=c11 -Wall \
  -I "$SRC" \
  -o "$OUT/json_escape_test" \
  "$SRC/tests/json_escape_test.c" \
  "$SRC/json_escape.c"
"$OUT/json_escape_test"

clang -Os "${CLANG_OS_FLAGS[@]}" -std=c11 -Wall \
  -I "$SRC" \
  -o "$OUT/json_reply_test" \
  "$SRC/tests/json_reply_test.c" \
  "$SRC/json_escape.c" \
  "$SRC/json_reply.c"
"$OUT/json_reply_test"

clang -Os "${CLANG_OS_FLAGS[@]}" -std=c11 -Wall \
  -I "$SRC" \
  -o "$OUT/hook_fallback_test" \
  "$SRC/tests/hook_fallback_test.c" \
  "$SRC/json_escape.c" \
  "$SRC/hook_fallback.c"
"$OUT/hook_fallback_test"

clang -Os "${CLANG_OS_FLAGS[@]}" -std=c11 -Wall \
  -I "$SRC" \
  -o "$OUT/observe_gate_test" \
  "$SRC/tests/observe_gate_test.c" \
  "$SRC/json_escape.c" \
  "$SRC/json_reply.c" \
  "$SRC/observe_gate.c"
"$OUT/observe_gate_test"

clang -Os "${CLANG_OS_FLAGS[@]}" -std=c11 -Wall \
  -I "$SRC" \
  -o "$OUT/rvd_state_test" \
  "$SRC/tests/rvd_state_test.c" \
  "$SRC/rvd_state.c"
"$OUT/rvd_state_test"

if [[ "$OS" == "Darwin" ]]; then
  # Trust manifest parsing is Darwin-only (Linux pins the sibling rvd).
  clang -Os "${CLANG_OS_FLAGS[@]}" -std=c11 -Wall \
    -I "$SRC" \
    -o "$OUT/daemon_trust_test" \
    "$SRC/tests/daemon_trust_test.c"
  "$OUT/daemon_trust_test"
fi

clang -Os "${CLANG_OS_FLAGS[@]}" -std=c11 -Wall \
  -I "$SRC" \
  -o "$OUT/evaluation_route_test" \
  "$SRC/tests/evaluation_route_test.c"
# Shared vectors: the same file drives EvaluationRouteTests.sharedVectorsMatchC
# on the Swift side. A vector both harnesses disagree on fails both suites.
"$OUT/evaluation_route_test" "$SRC/tests/evaluation_route_vectors.tsv"

# Overlong-row guard: a 4095-content-byte row (+ newline = 4096 bytes) needs
# NUL room the 4096-byte fgets buffer lacks, so C must fail loudly with the
# overlong diagnostic instead of mis-parsing a fragment Swift parses whole.
OVERLONG="$OUT/overlong-vectors.tsv"
cp "$SRC/tests/evaluation_route_vectors.tsv" "$OVERLONG"
awk 'BEGIN { for (i = 0; i < 4075; i++) printf "9"; print ".0.0\t1.0.0\tinProcess" }' >> "$OVERLONG"
set +e
"$OUT/evaluation_route_test" "$OVERLONG" 2>"$OUT/overlong.err"
overlong_st=$?
set -e
if [[ "$overlong_st" -eq 0 ]] || ! grep -q "overlong" "$OUT/overlong.err"; then
  printf "rv-c tests: overlong vector row must fail evaluation_route_test with the overlong diagnostic\n" >&2
  exit 1
fi

# Observe fallback inputs are pinned to fixtures at compile time so the
# operator's own ~/.config/rv/config.json and managed policy never leak in.
OBSERVE_CONFIG_DIR="$OUT/observe-config"
OBSERVE_CONFIG="$OBSERVE_CONFIG_DIR/config.json"
OBSERVE_MANAGED="$OUT/observe-managed"
RVD_STATE="$OBSERVE_CONFIG_DIR/rvd-state"
rm -rf "$OBSERVE_CONFIG_DIR" "$OBSERVE_MANAGED"
mkdir -p "$OBSERVE_CONFIG_DIR"
# Linux: the uid-derived runtime root (/run/user in release builds) is
# pinned to a short fixture too, so a live rvd is never poked and the
# socket path fits sockaddr_un under deep checkouts.
RUNTIME_ROOT="$(mktemp -d /tmp/rv-c-run.XXXXXX)"
trap 'rm -rf "$RUNTIME_ROOT"' EXIT
OWNER_RUNTIME="$RUNTIME_ROOT/$(id -u)"
clang -Os "${CLANG_OS_FLAGS[@]}" -std=c11 -Wall \
  -I "$SRC" \
  -DRV_HOOK_OBSERVE_CONFIG_PATH="\"$OBSERVE_CONFIG\"" \
  -DRV_HOOK_MANAGED_POLICY_DIR="\"$OBSERVE_MANAGED\"" \
  -DRV_HOOK_RVD_STATE_PATH="\"$RVD_STATE\"" \
  -DRV_HOOK_USER_RUNTIME_ROOT="\"$RUNTIME_ROOT\"" \
  -o "$OUT/rv" \
  "$SRC/json_escape.c" \
  "$SRC/json_reply.c" \
  "$SRC/daemon_trust.c" \
  "$SRC/hook_fallback.c" \
  "$SRC/observe_gate.c" \
  "$SRC/local_eval.c" \
  "$SRC/rvd_state.c" \
  "$SRC/rv.c"

# Pipe hosts must match the Swift HookHost enum exactly. Invalid hosts exec
# rv-cli before the socket/XPC door, so a missing name is silent
# miss-as-operator. Derived from the source of truth, never hard-coded.
HOOK_HOST_SWIFT="$ROOT/Sources/RVDomain/HookHost.swift"
HOSTS="$(awk '
  /^public enum HookHost:/ { inside = 1; next }
  inside && /^}/ { exit }
  inside && /^    case [a-z]+$/ { print $2 }
' "$HOOK_HOST_SWIFT" | sort)"
C_HOSTS="$(awk '
  /static int is_valid_host/,/^}/ {
    line = $0
    while (match(line, /strcmp\(s, "[a-z]+"\)/)) {
      chunk = substr(line, RSTART, RLENGTH)
      sub(/^strcmp\(s, "/, "", chunk)
      sub(/"\)$/, "", chunk)
      print chunk
      line = substr(line, RSTART + RLENGTH)
    }
  }
' "$SRC/rv.c" | sort)"
if [[ -z "$HOSTS" || "$HOSTS" != "$C_HOSTS" ]]; then
  printf "rv-c tests: is_valid_host must accept exactly the HookHost cases\n" >&2
  printf "HookHost: %s\nrv.c:     %s\n" "$(echo $HOSTS)" "$(echo $C_HOSTS)" >&2
  exit 1
fi
# Shipped host templates must name only HookHost cases.
for tmpl_host in $(grep -ho -- '--host [a-z]*' "$ROOT"/Sources/RVHooks/Resources/hosts/*.tmpl | awk '{ print $2 }' | sort -u); do
  if ! grep -qx "$tmpl_host" <<<"$HOSTS"; then
    printf "rv-c tests: template host %s is not a HookHost case\n" "$tmpl_host" >&2
    exit 1
  fi
done

if [[ "$OS" == "Darwin" ]]; then
  if otool -L "$OUT/rv" | grep -E 'Frameworks/Foundation\.framework|CFNetwork' >/dev/null; then
    printf "rv-c tests: C rv must not link Foundation or CFNetwork\n" >&2
    otool -L "$OUT/rv" >&2
    exit 1
  fi
fi

PROBE="$OUT/argv-probe"
rm -rf "$PROBE"
mkdir -p "$PROBE"
cp "$OUT/rv" "$PROBE/rv"
cat > "$PROBE/rv-cli" <<'EOF'
#!/bin/sh
{
  printf '%s\n' "$0"
  printf '%s\n' "$@"
} > "${RV_C_ARGV_LOG:?}"
cat > "${RV_C_STDIN_LOG:-/dev/null}"
exit 17
EOF
chmod 755 "$PROBE/rv-cli"

# The installed front door must locate its real sibling even when argv[0]
# comes from PATH or is deliberately forged. HOME is never a code locator.
for invocation in path forged; do
  log="$OUT/$invocation.argv"
  set +e
  if [[ "$invocation" == "path" ]]; then
    PATH="$PROBE:/usr/bin:/bin" HOME="$PROBE" RV_C_ARGV_LOG="$log" rv opencode < /dev/null
  else
    HOME="$PROBE" RV_C_ARGV_LOG="$log" /bin/bash -c 'exec -a untrusted-argv-zero "$1" opencode' _ "$PROBE/rv" < /dev/null
  fi
  st=$?
  set -e
  if [[ "$st" -ne 17 || ! -f "$log" ]]; then
    printf 'rv-c tests: %s invocation did not execute the installed sibling (exit %s)\n' "$invocation" "$st" >&2
    exit 1
  fi
done

expect_exec() {
  local name="$1"
  shift
  local log="$OUT/$name.argv"
  local st
  set +e
  RV_C_ARGV_LOG="$log" "$PROBE/rv" "$@" </dev/null
  st=$?
  set -e
  if [[ "$st" -ne 17 ]]; then
    printf "rv-c tests: %s expected exec rv-cli exit 17, got %s\n" "$name" "$st" >&2
    exit 1
  fi
  if [[ ! -f "$log" ]]; then
    printf "rv-c tests: %s did not exec rv-cli\n" "$name" >&2
    exit 1
  fi
}

expect_exec help hook --help
if ! grep -q -- '--help' "$OUT/help.argv"; then
  printf "rv-c tests: help argv missing --help\n" >&2
  exit 1
fi

expect_exec invalid_host hook --host nope
if ! grep -q -- 'nope' "$OUT/invalid_host.argv"; then
  printf "rv-c tests: invalid host argv missing nope\n" >&2
  exit 1
fi

expect_exec operator test --plain
if ! grep -q -- 'test' "$OUT/operator.argv"; then
  printf "rv-c tests: operator argv missing test\n" >&2
  exit 1
fi

# Host deny wire must match the Swift codecs (RVHooks/*HostCodec.swift):
# exact keys, exit code, and Codex blocking stderr. Every HookHost needs an
# explicit expectation here, so a new host cannot inherit a guessed shape.
check_deny() {
  python3 - "$@" <<'PY'
import json
import sys

host, out_path, err_path, status, want = sys.argv[1:6]
status = int(status)
text = open(out_path, encoding="utf-8").read()
err = open(err_path, encoding="utf-8").read()
if not text.endswith("\n") or text.count("\n") != 1:
    raise SystemExit("%s: deny must be one JSON line, got %r" % (host, text))
obj = json.loads(text)
leftover = {"grok": 0, "antigravity": 0, "pi": 1, "opencode": 1, "openclaw": 1, "hermes": 1}
if host in leftover:
    expect_status = leftover[host]
    assert set(obj) == {"decision", "reason"} and obj["decision"] == "deny", (host, obj)
    reason = obj["reason"]
elif host == "codex":
    expect_status = 2
    assert set(obj) == {"decision", "reason"} and obj["decision"] == "block", (host, obj)
    reason = obj["reason"]
    assert err == reason + "\n", ("codex stderr must carry the blocking reason", err)
elif host in ("claude", "muse"):
    expect_status = 0
    keys = {"hookSpecificOutput"} | ({"systemMessage"} if host == "claude" else set())
    assert set(obj) == keys, (host, obj)
    hso = obj["hookSpecificOutput"]
    assert set(hso) == {"hookEventName", "permissionDecision", "permissionDecisionReason"}, (host, hso)
    assert hso["hookEventName"] == "PreToolUse" and hso["permissionDecision"] == "deny", (host, hso)
    reason = hso["permissionDecisionReason"]
    if host == "claude":
        assert obj["systemMessage"] == reason, (host, obj)
elif host == "cursor":
    expect_status = 0
    assert set(obj) == {"permission", "user_message", "agent_message"}, (host, obj)
    # The agent reads the same stop as the person (B1).
    reason = obj["user_message"]
    assert obj["permission"] == "deny" and obj["agent_message"] == reason, (host, obj)
else:
    raise SystemExit("rv-c tests: no expected deny wire for HookHost %s" % host)
if status != expect_status:
    raise SystemExit("%s: deny exit %d, want %d" % (host, status, expect_status))
if not reason or want not in reason:
    raise SystemExit("%s: reason %r missing %r" % (host, reason, want))
# One shape for every stop (B1): verdict with the rule id, why, who acts;
# the owner runs the fix, never the agent.
lines = reason.split("\n")
if not lines[0].startswith("\u2715 Stopped   (rv.hook/") or not lines[0].endswith(")"):
    raise SystemExit("%s: stop must name its rule id, got %r" % (host, lines[0]))
if len(lines) != 3 or not lines[1].startswith("why     ") or not lines[2].startswith("who     ask "):
    raise SystemExit("%s: stop shape mismatch %r" % (host, reason))
if "allow-once" in reason or "unlock" in reason or "\x1b" in reason:
    raise SystemExit("%s: stop must not offer an unlock or colour %r" % (host, reason))
PY
}

# Substrings of the hook_fallback.c messages (classified, not a generic sentence).
REASON_INPUT="rv could not read this hook request"
REASON_OVERSIZE="rv could not read this hook request"
REASON_UNREACHABLE="rv's daemon is not running"
REASON_CONNECTION='rv lost its daemon before a verdict'
REASON_REJECTED="rv's daemon failed its identity check"
REASON_TIMEOUT="rv's daemon did not answer in time"
REASON_STOPPED='rvd stopped or crashed after it last ran'

# Every host denies malformed input directly; an executable CLI sibling must
# never receive authority-bearing fallback input.
host_count=0
for host in $HOSTS; do
  host_count=$((host_count + 1))
  log="$OUT/deny-$host.argv"
  rm -f "$log"
  set +e
  printf 'a\0b' | RV_C_ARGV_LOG="$log" "$PROBE/rv" hook --host "$host" >"$OUT/deny-$host.json" 2>"$OUT/deny-$host.err"
  status=$?
  set -e
  if [[ -e "$log" ]]; then
    printf 'rv-c tests: %s fallback must deny without invoking CLI\n' "$host" >&2
    exit 1
  fi
  if ! check_deny "$host" "$OUT/deny-$host.json" "$OUT/deny-$host.err" "$status" "$REASON_INPUT"; then
    printf 'rv-c tests: %s malformed-input denial wire mismatch\n' "$host" >&2
    exit 1
  fi
done

# Well-formed input with no reachable daemon names the cause, never a
# generic auth sentence. RV_HOOK_WHEN_DOWN=deny pins the deny wire on the
# ask-capable hosts (Claude, Cursor) too. Linux leaves XDG_RUNTIME_DIR unset,
# so the hook uses the (empty) fixture uid-derived runtime dir; Darwin has no
# test-controlled Mach service, so a live foreign rvd may answer and be
# rejected by the identity check, or drop the connection, instead.
for host in $HOSTS; do
  log="$OUT/down-$host.argv"
  rm -f "$log"
  set +e
  printf '{}' | env -u XDG_RUNTIME_DIR RV_HOOK_WHEN_DOWN=deny RV_C_ARGV_LOG="$log" "$PROBE/rv" hook --host "$host" >"$OUT/down-$host.json" 2>"$OUT/down-$host.err"
  status=$?
  set -e
  if [[ -e "$log" ]]; then
    printf 'rv-c tests: %s no-daemon path must deny without invoking CLI\n' "$host" >&2
    exit 1
  fi
  if check_deny "$host" "$OUT/down-$host.json" "$OUT/down-$host.err" "$status" "$REASON_UNREACHABLE" 2>/dev/null; then
    continue
  fi
  if [[ "$OS" == "Darwin" ]] \
    && { check_deny "$host" "$OUT/down-$host.json" "$OUT/down-$host.err" "$status" "$REASON_REJECTED" 2>/dev/null \
      || check_deny "$host" "$OUT/down-$host.json" "$OUT/down-$host.err" "$status" "$REASON_CONNECTION" 2>/dev/null; }; then
    continue
  fi
  printf 'rv-c tests: %s no-daemon deny must name the unreachable service\n' "$host" >&2
  cat "$OUT/down-$host.json" >&2
  exit 1
done

# Oversized input must also deny without invoking a replay child.
set +e
head -c 1048577 /dev/zero | tr '\0' 'x' | RV_C_ARGV_LOG="$OUT/oversize.argv" "$PROBE/rv" hook --host codex >"$OUT/oversize.json" 2>"$OUT/oversize.err"
oversize_status=${PIPESTATUS[2]}
set -e
if [[ -e "$OUT/oversize.argv" ]] \
  || ! check_deny codex "$OUT/oversize.json" "$OUT/oversize.err" "$oversize_status" "$REASON_OVERSIZE"; then
  printf 'rv-c tests: oversized hook must deny without CLI replay\n' >&2
  exit 1
fi

EMPTY="$OUT/empty-home"
rm -rf "$EMPTY"
mkdir -p "$EMPTY"
mkdir -p "$EMPTY/.local/bin"
printf '#!/bin/sh\nexit 19\n' > "$EMPTY/.local/bin/rv-cli"
chmod 755 "$EMPTY/.local/bin/rv-cli"
set +e
HOME="$EMPTY" "$OUT/rv" hook --help
miss_st=$?
set -e
if [[ "$miss_st" -ne 2 ]]; then
  printf "rv-c tests: missing rv-cli must exit 2 (Grok deny), got %s\n" "$miss_st" >&2
  exit 1
fi

# Broken-sibling operator argv: non-hook commands must name the missing
# sibling on stderr so doctor stays reachable in the state it diagnoses.
BROKEN="$OUT/broken-operator"
rm -rf "$BROKEN"
mkdir -p "$BROKEN"
set +e
HOME="$BROKEN" "$OUT/rv" doctor 2>"$BROKEN/err"
broken_st=$?
set -e
if [[ "$broken_st" -ne 2 ]]; then
  printf "rv-c tests: broken-sibling operator argv must exit 2, got %s\n" "$broken_st" >&2
  exit 1
fi
if ! grep -q "rv-cli not found" "$BROKEN/err"; then
  printf "rv-c tests: broken-sibling operator argv must explain the missing sibling on stderr\n" >&2
  cat "$BROKEN/err" >&2
  exit 1
fi

# Daemon down: RV_HOOK_WHEN_DOWN rendering at the process boundary. Linux
# unsets XDG_RUNTIME_DIR so the hook uses the fixture uid-derived runtime
# dir, which has no socket (ENOENT); Darwin relies on dev.rv.evaluate being
# unregistered for this user and skips otherwise — a live service must
# never be poked by unit tests.
DOWN_ENV=()
down_ready=1
if [[ "$OS" == "Linux" ]]; then
  DOWN_ENV=(-u XDG_RUNTIME_DIR)
elif launchctl print "gui/$(id -u)/dev.rv.evaluate" >/dev/null 2>&1; then
  down_ready=0
  printf 'rv-c tests: dev.rv.evaluate is registered; skipping daemon-down cases\n'
fi

expect_down() {
  local name="$1" host="$2" mode="$3" want_status="$4" marker="$5"
  local reason="${6:-$REASON_UNREACHABLE}"
  local st
  rm -f "$OUT/down-$name.argv"
  set +e
  printf '{"tool_name":"Bash","tool_input":{"command":"ls"}}' \
    | env ${DOWN_ENV[@]+"${DOWN_ENV[@]}"} ${mode:+RV_HOOK_WHEN_DOWN="$mode"} \
      RV_C_ARGV_LOG="$OUT/down-$name.argv" "$PROBE/rv" hook --host "$host" \
      >"$OUT/down-$name.json" 2>"$OUT/down-$name.err"
  st=$?
  set -e
  if [[ "$st" -ne "$want_status" || -e "$OUT/down-$name.argv" ]]; then
    printf 'rv-c tests: down %s expected exit %s without CLI, got %s\n' "$name" "$want_status" "$st" >&2
    exit 1
  fi
  if [[ -z "$marker" ]]; then
    if [[ -s "$OUT/down-$name.json" ]]; then
      printf 'rv-c tests: down %s must print nothing\n' "$name" >&2
      exit 1
    fi
  elif ! grep -q "$marker" "$OUT/down-$name.json" \
    || ! grep -q "$reason" "$OUT/down-$name.json"; then
    printf 'rv-c tests: down %s missing %s / %s\n' "$name" "$marker" "$reason" >&2
    cat "$OUT/down-$name.json" >&2
    exit 1
  fi
}

if [[ "$down_ready" -eq 1 ]]; then
  expect_down claude-default claude "" 0 '"permissionDecision":"ask"'
  expect_down claude-junk claude "bogus" 0 '"permissionDecision":"ask"'
  expect_down cursor-default cursor "" 0 '"permission":"ask"'
  expect_down claude-deny claude deny 0 '"permissionDecision":"deny"'
  # "allow" is not a bypass: it parses as the default ask.
  expect_down claude-allow claude allow 0 '"permissionDecision":"ask"'
  expect_down codex-default codex "" 2 '"decision":"block"'
  expect_down opencode-default opencode "" 1 '"decision":"deny"'
  # Muse has no ask primitive: its deny wire (hookSpecificOutput, exit 0).
  expect_down muse-default muse "" 0 '"permissionDecision":"deny"'
  if [[ ! -s "$OUT/down-codex-default.err" ]]; then
    printf 'rv-c tests: Codex down fallback requires blocking stderr\n' >&2
    exit 1
  fi
  # Malformed input stays a deny whatever RV_HOOK_WHEN_DOWN says.
  set +e
  printf 'a\0b' | RV_HOOK_WHEN_DOWN=allow "$PROBE/rv" hook --host claude >"$OUT/input-allow.json" 2>/dev/null
  st=$?
  set -e
  if [[ "$st" -ne 0 ]] || ! grep -q '"permissionDecision":"deny"' "$OUT/input-allow.json" \
    || ! grep -q 'could not read this hook request' "$OUT/input-allow.json"; then
    printf 'rv-c tests: malformed input must deny regardless of RV_HOOK_WHEN_DOWN\n' >&2
    exit 1
  fi
  printf 'rv-c daemon-down fallback: ask/deny rendering passed\n'

  # Observe mode in the owner's config: an unreachable daemon steps aside with
  # the host's allow wire and a stderr notice. RV_GUARD_MODE and
  # RV_HOOK_WHEN_DOWN never turn it on; an explicit RV_HOOK_WHEN_DOWN=deny,
  # a per-host block or an organization policy directory keeps the normal
  # fallback.
  expect_observe() {
    local name="$1" host="$2" want_out="$3"
    local st
    rm -f "$OUT/observe-$name.argv"
    set +e
    printf '{"tool_name":"Bash","tool_input":{"command":"ls"}}' \
      | env ${DOWN_ENV[@]+"${DOWN_ENV[@]}"} \
        RV_C_ARGV_LOG="$OUT/observe-$name.argv" "$PROBE/rv" hook --host "$host" \
        >"$OUT/observe-$name.json" 2>"$OUT/observe-$name.err"
    st=$?
    set -e
    if [[ "$st" -ne 0 || -e "$OUT/observe-$name.argv" ]] \
      || [[ "$(cat "$OUT/observe-$name.json")" != "$want_out" ]] \
      || ! grep -q 'RV observe mode: daemon unavailable' "$OUT/observe-$name.err"; then
      printf 'rv-c tests: observe %s expected allow wire %s, got exit %s\n' "$name" "$want_out" "$st" >&2
      cat "$OUT/observe-$name.json" "$OUT/observe-$name.err" >&2
      exit 1
    fi
  }
  printf '{"guard":{"mode":"observe"}}' > "$OBSERVE_CONFIG"
  chmod 600 "$OBSERVE_CONFIG"
  expect_observe claude claude ''
  expect_observe codex codex ''
  expect_observe opencode opencode ''
  expect_observe cursor cursor '{"permission":"allow"}'
  expect_observe antigravity antigravity '{"decision":"allow"}'
  # Malformed input still denies under observe.
  set +e
  printf 'a\0b' | "$PROBE/rv" hook --host claude >"$OUT/observe-input.json" 2>/dev/null
  set -e
  if ! grep -q '"permissionDecision":"deny"' "$OUT/observe-input.json"; then
    printf 'rv-c tests: malformed input must deny under observe\n' >&2
    exit 1
  fi
  expect_down observe-explicit-deny claude deny 0 '"permissionDecision":"deny"'
  printf '{"guard":{"mode":"observe","hosts":{"claude":"block"}}}' > "$OBSERVE_CONFIG"
  expect_down observe-host-block claude "" 0 '"permissionDecision":"ask"'
  printf '{"guard":{"mode":"observe"}}' > "$OBSERVE_CONFIG"
  mkdir -p "$OBSERVE_MANAGED"
  expect_down observe-managed claude "" 0 '"permissionDecision":"ask"'
  rmdir "$OBSERVE_MANAGED"
  printf '{"guard":{"mode":"enforce"}}' > "$OBSERVE_CONFIG"
  set +e
  printf '{"tool_name":"Bash","tool_input":{"command":"ls"}}' \
    | env ${DOWN_ENV[@]+"${DOWN_ENV[@]}"} RV_GUARD_MODE=observe RV_HOOK_WHEN_DOWN=observe \
      "$PROBE/rv" hook --host claude >"$OUT/observe-env.json" 2>/dev/null
  set -e
  if ! grep -q '"permissionDecision":"ask"' "$OUT/observe-env.json"; then
    printf 'rv-c tests: RV_GUARD_MODE / RV_HOOK_WHEN_DOWN must not enable observe fallback\n' >&2
    exit 1
  fi
  printf '{"guard":{"mode":"observe"}}' > "$OBSERVE_CONFIG"

  # rvd state marker (rvd_state.h): observe steps aside only when rvd never
  # ran here (no marker) or a restart was announced and is still due. An
  # rvd that ran and then stopped or crashed keeps the ask/deny fallback.
  write_rvd_state() {
    rm -f "$RVD_STATE"
    printf '%s' "$1" > "$RVD_STATE"
    chmod "${2:-600}" "$RVD_STATE"
  }
  now="$(date +%s)"
  write_rvd_state $'armed\n'
  expect_down state-armed claude "" 0 '"permissionDecision":"ask"' "$REASON_STOPPED"
  expect_down state-armed-cursor cursor "" 0 '"permission":"ask"' "$REASON_STOPPED"
  expect_down state-armed-codex codex "" 2 '"decision":"block"' "$REASON_STOPPED"
  expect_down state-armed-opencode opencode "" 1 '"decision":"deny"' "$REASON_STOPPED"
  expect_down state-armed-deny claude deny 0 '"permissionDecision":"deny"'
  if grep -q 'allowed without being checked' "$OUT/down-state-armed.err"; then
    printf 'rv-c tests: an armed marker must not take the observe path\n' >&2
    exit 1
  fi
  write_rvd_state "restarting $((now + 60))"$'\n'
  expect_observe state-restarting claude ''
  expect_observe state-restarting-cursor cursor '{"permission":"allow"}'
  write_rvd_state "restarting $((now - 5))"$'\n'
  expect_down state-expired claude "" 0 '"permissionDecision":"ask"' "$REASON_STOPPED"
  write_rvd_state "restarting $((now + 86400))"$'\n'
  expect_down state-far-future claude "" 0 '"permissionDecision":"ask"' "$REASON_STOPPED"
  write_rvd_state $'allow\n'
  expect_down state-garbage claude "" 0 '"permissionDecision":"ask"' "$REASON_STOPPED"
  write_rvd_state "restarting $((now + 60))"$'\n' 666
  expect_down state-world-writable claude "" 0 '"permissionDecision":"ask"' "$REASON_STOPPED"
  rm -f "$RVD_STATE"
  printf 'restarting %s\n' "$((now + 60))" > "$OBSERVE_CONFIG_DIR/elsewhere"
  ln -s "$OBSERVE_CONFIG_DIR/elsewhere" "$RVD_STATE"
  expect_down state-symlink claude "" 0 '"permissionDecision":"ask"' "$REASON_STOPPED"
  rm -f "$RVD_STATE" "$OBSERVE_CONFIG_DIR/elsewhere"
  # Outside observe mode the marker changes nothing: enforce keeps the
  # unreachable message, not the stopped one.
  printf '{"guard":{"mode":"enforce"}}' > "$OBSERVE_CONFIG"
  write_rvd_state $'armed\n'
  expect_down state-enforce claude "" 0 '"permissionDecision":"ask"' "$REASON_UNREACHABLE"
  write_rvd_state "restarting $((now + 60))"$'\n'
  expect_down state-enforce-restarting claude "" 0 '"permissionDecision":"ask"' "$REASON_UNREACHABLE"
  rm -f "$RVD_STATE"
  printf '{"guard":{"mode":"observe"}}' > "$OBSERVE_CONFIG"
  expect_observe state-absent claude ''
  printf 'rv-c daemon-down fallback: rvd state marker passed\n'
  if [[ "$OS" == "Linux" ]]; then
    # Only a miss on the uid-derived socket may step aside. An agent can set
    # XDG_RUNTIME_DIR through project-scoped host config, so a miss anywhere
    # else, an empty or over-long value, keeps the ask/deny fallback.
    LINUX_DOWN_ENV=("${DOWN_ENV[@]}")
    DOWN_ENV=(XDG_RUNTIME_DIR="$OWNER_RUNTIME")
    expect_observe xdg-owner claude ''
    DOWN_ENV=(XDG_RUNTIME_DIR="$OUT/no-such-runtime-dir")
    expect_down xdg-foreign claude "" 0 '"permissionDecision":"ask"' "$REASON_CONNECTION"
    expect_down xdg-foreign-codex codex "" 2 '"decision":"block"' "$REASON_CONNECTION"
    DOWN_ENV=(XDG_RUNTIME_DIR="$OWNER_RUNTIME/")
    expect_down xdg-owner-slash claude "" 0 '"permissionDecision":"ask"' "$REASON_CONNECTION"
    DOWN_ENV=(XDG_RUNTIME_DIR=)
    expect_down xdg-empty claude "" 0 '"permissionDecision":"ask"' "$REASON_CONNECTION"
    DOWN_ENV=(XDG_RUNTIME_DIR="/tmp/$(printf 'x%.0s' $(seq 1 120))")
    expect_down xdg-too-long claude "" 0 '"permissionDecision":"ask"' "$REASON_CONNECTION"

    # Fake sibling rvd: the peer check accepts it, so failures are classified
    # exactly as with the real daemon.
    clang -Os -std=c11 -Wall -o "$PROBE/rvd" "$SRC/tests/fake_rvd.c"
    mkdir -p "$OWNER_RUNTIME/rv"
    # ECONNREFUSED (stale socket file, no listener) on the uid-derived path
    # is an absent daemon.
    "$PROBE/rvd" stale "$OWNER_RUNTIME/rv/evaluate.sock"
    DOWN_ENV=("${LINUX_DOWN_ENV[@]}")
    expect_observe stale-socket claude ''
    # ... but not under an agent-chosen XDG_RUNTIME_DIR.
    mkdir -p "$OUT/foreign-runtime/rv"
    rm -f "$OUT/foreign-runtime/rv/evaluate.sock"
    "$PROBE/rvd" stale "$OUT/foreign-runtime/rv/evaluate.sock"
    DOWN_ENV=(XDG_RUNTIME_DIR="$OUT/foreign-runtime")
    expect_down stale-foreign claude "" 0 '"permissionDecision":"ask"' "$REASON_CONNECTION"
    rm -f "$OWNER_RUNTIME/rv/evaluate.sock" "$OUT/foreign-runtime/rv/evaluate.sock"

    # rvd in its startup backoff wait: bound and listening, not accepting.
    # connect succeeds into the backlog, the peer check passes, the reply
    # times out: TIMEOUT (ask), never UNREACHABLE, so observe (configured
    # here) must not step aside.
    "$PROBE/rvd" hold "$OWNER_RUNTIME/rv/evaluate.sock" 20 &
    hold_pid=$!
    for _try in $(seq 1 50); do
      [[ -S "$OWNER_RUNTIME/rv/evaluate.sock" ]] && break
      sleep 0.1
    done
    DOWN_ENV=("${LINUX_DOWN_ENV[@]}")
    expect_down backoff-hold claude "" 0 '"permissionDecision":"ask"' "$REASON_TIMEOUT"
    if grep -q 'observe' "$OUT/down-backoff-hold.err"; then
      printf 'rv-c tests: a bound but not yet accepting rvd must not take the observe path\n' >&2
      exit 1
    fi
    kill "$hold_pid" 2>/dev/null || true
    wait "$hold_pid" 2>/dev/null || true
    rm -f "$OWNER_RUNTIME/rv/evaluate.sock"

    # Post-send drop: a verified daemon reads the whole request and closes
    # without replying (rvd drains in-flight requests on shutdown, which an
    # agent can trigger). That is never an absent daemon.
    rm -f "$OUT/drop.record"
    "$PROBE/rvd" drop "$OWNER_RUNTIME/rv/evaluate.sock" "$OUT/drop.record" &
    drop_pid=$!
    for _try in $(seq 1 50); do
      [[ -S "$OWNER_RUNTIME/rv/evaluate.sock" ]] && break
      sleep 0.1
    done
    DOWN_ENV=("${LINUX_DOWN_ENV[@]}")
    expect_down post-send-drop claude "" 0 '"permissionDecision":"ask"' "$REASON_CONNECTION"
    if ! wait "$drop_pid" || [[ ! -s "$OUT/drop.record" ]] || [[ "$(cat "$OUT/drop.record")" -le 4 ]]; then
      printf 'rv-c tests: post-send drop must reach the fake daemon with a whole request\n' >&2
      exit 1
    fi
    if grep -q 'observe' "$OUT/down-post-send-drop.err"; then
      printf 'rv-c tests: post-send drop must not take the observe path\n' >&2
      exit 1
    fi
    # A daemon that fails the peer check and is gone by the retry: the
    # retry's ENOENT does not prove absence after a live (if unverified)
    # daemon answered, so the untrusted deny stands.
    cp "$PROBE/rvd" "$OUT/not-the-sibling"
    "$OUT/not-the-sibling" drop "$OWNER_RUNTIME/rv/evaluate.sock" "$OUT/untrusted.record" &
    untrusted_pid=$!
    for _try in $(seq 1 50); do
      [[ -S "$OWNER_RUNTIME/rv/evaluate.sock" ]] && break
      sleep 0.1
    done
    expect_down untrusted-then-gone claude "" 0 '"permissionDecision":"deny"' "$REASON_REJECTED"
    wait "$untrusted_pid" || true
    if [[ -e "$OUT/untrusted.record" ]]; then
      printf 'rv-c tests: hook sent request bytes to an unverified daemon\n' >&2
      exit 1
    fi
    rm -f "$PROBE/rvd" "$OUT/not-the-sibling"
    DOWN_ENV=("${LINUX_DOWN_ENV[@]}")
    printf 'rv-c daemon-down fallback: Linux socket classification passed\n'
  fi
  rm -f "$OBSERVE_CONFIG"
  printf 'rv-c daemon-down fallback: observe rendering passed\n'
fi

# The hook-local door (local_eval.h). Fake evaluators stand in for
# rv-hook-local; FAKE_LOG records what each was given.
LOCAL="$OUT/local-door"
rm -rf "$LOCAL"
mkdir -p "$LOCAL"
for mode in final escalate hang crash garbage wrong-id; do
  clang -Os "${CLANG_OS_FLAGS[@]}" -std=c11 -Wall \
    -DFAKE_MODE="\"$mode\"" -DFAKE_LOG="\"$LOCAL/$mode.log\"" \
    -o "$LOCAL/fake-$mode" "$SRC/tests/fake_evaluator.c"
done
clang -Os "${CLANG_OS_FLAGS[@]}" -std=c11 -Wall \
  -I "$SRC" \
  -o "$OUT/local_eval_test" \
  "$SRC/tests/local_eval_test.c" \
  "$SRC/local_eval.c"
"$OUT/local_eval_test" "$LOCAL/fake-final" "$LOCAL/fake-escalate" "$LOCAL/fake-hang" \
  "$LOCAL/fake-crash" "$LOCAL/fake-garbage" "$LOCAL/final.log"

# An rv whose peer trust is pinned to "no manifest" (sibling pinning), so
# the operator's installed /Library manifest never decides these cases.
clang -Os "${CLANG_OS_FLAGS[@]}" -std=c11 -Wall \
  -I "$SRC" \
  -DRV_HOOK_OBSERVE_CONFIG_PATH="\"$OBSERVE_CONFIG\"" \
  -DRV_HOOK_MANAGED_POLICY_DIR="\"$OBSERVE_MANAGED\"" \
  -DRV_HOOK_USER_RUNTIME_ROOT="\"$RUNTIME_ROOT\"" \
  -DRV_HOOK_RVD_STATE_PATH="\"$RVD_STATE\"" \
  -DRV_MANIFEST_PATH="\"$LOCAL/no-manifest.json\"" \
  -o "$LOCAL/rv" \
  "$SRC/json_escape.c" \
  "$SRC/json_reply.c" \
  "$SRC/daemon_trust.c" \
  "$SRC/hook_fallback.c" \
  "$SRC/observe_gate.c" \
  "$SRC/rvd_state.c" \
  "$SRC/local_eval.c" \
  "$SRC/rv.c"
PASSWD_HOME="$(python3 -c 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')"
LOCAL_INPUT='{"tool_name":"Bash","tool_input":{"command":"ls"}}'

# run_local <case> <evaluator binary | script>: a dir holding rv and that
# evaluator as its sibling, run under a hostile environment the evaluator
# must never see.
run_local() {
  local name="$1" evaluator="$2" dir="$LOCAL/case-$1"
  rm -rf "$dir"
  mkdir -p "$dir"
  cp "$LOCAL/rv" "$dir/rv"
  if [[ "$evaluator" == "script" ]]; then
    # A well-formed final for this very request: only peer trust stops it.
    cat > "$dir/rv-hook-local" <<'SH'
#!/bin/sh
cat >/dev/null
printf 'rv-hook-local/1 final\n{"id":"%s","protocol":"rv.ipc.v1","result":{"hookEvaluate":{"exitCode":0,"serviceSemver":"1.0.0","stdout":"LOCAL-FINAL-MARKER\\n","via":"xpc"}}}' "$4"
SH
    chmod 755 "$dir/rv-hook-local"
  else
    cp "$evaluator" "$dir/rv-hook-local"
  fi
  set +e
  printf '%s' "$LOCAL_INPUT" \
    | env -u XDG_RUNTIME_DIR HOME=/rv-evil-home USER=evil RV_GUARD_MODE=observe \
      RV_EVIL_MARKER=1 RV_HOOK_WHEN_DOWN=deny \
      "$dir/rv" hook --host claude >"$LOCAL/$name.out" 2>"$LOCAL/$name.err"
  LOCAL_STATUS=$?
  set -e
}

# A local final is delivered as rvd's reply would be, from a sanitized call.
run_local final "$LOCAL/fake-final"
if [[ "$LOCAL_STATUS" -ne 0 || "$(cat "$LOCAL/final.out")" != "LOCAL-FINAL-MARKER" ]]; then
  printf 'rv-c tests: local final must be delivered (exit %s)\n' "$LOCAL_STATUS" >&2
  cat "$LOCAL/final.out" "$LOCAL/final.err" >&2
  exit 1
fi
python3 - "$LOCAL/final.log" "$PASSWD_HOME" "$(id -un)" "$LOCAL_INPUT" <<'PY'
import re
import sys

log, home, user, stdin = sys.argv[1:5]
lines = open(log, encoding="utf-8").read().split("\n")
args = [l[4:] for l in lines if l.startswith("arg=")]
# Darwin's libSystem adds __CF_USER_TEXT_ENCODING to every new process.
env = sorted(l[4:] for l in lines
             if l.startswith("env=") and not l.startswith("env=__CF_USER_TEXT_ENCODING="))
assert len(args) == 4 and args[:3] == ["--host", "claude", "--request-id"], args
assert re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", args[3], re.I), args
want = sorted(["HOME=" + home, "USER=" + user, "LOGNAME=" + user, "PATH=/usr/bin:/bin:/usr/sbin:/sbin"])
assert env == want, ("evaluator environment must be the passwd identity only", env)
assert "cwd=/" in lines, lines
assert ("stdin=" + stdin) in lines, ("evaluator must receive the exact hook stdin", lines)
PY

# Anything but a valid final reply to this request falls through to rvd's
# path (here no reachable or trusted daemon, so the RV_HOOK_WHEN_DOWN=deny
# wire naming the daemon) and never delivers what the evaluator printed.
# As for the daemon-down cases, a registered dev.rv.evaluate must never be
# sent a test call: skip there (local_eval_test still covers each cause).
FALL_THROUGH=(escalate hang crash garbage wrong-id untrusted)
if [[ "$OS" == "Darwin" && "$down_ready" -ne 1 ]]; then
  FALL_THROUGH=()
  printf 'rv-c tests: dev.rv.evaluate is registered; skipping hook-local fall-through cases\n'
fi
for name in ${FALL_THROUGH[@]+"${FALL_THROUGH[@]}"}; do
  if [[ "$name" == "untrusted" ]]; then
    run_local untrusted script
  else
    run_local "$name" "$LOCAL/fake-$name"
  fi
  if grep -q 'LOCAL-FINAL-MARKER' "$LOCAL/$name.out"; then
    printf 'rv-c tests: local %s must not deliver the evaluator output\n' "$name" >&2
    exit 1
  fi
  if ! check_deny claude "$LOCAL/$name.out" "$LOCAL/$name.err" "$LOCAL_STATUS" "$REASON_UNREACHABLE" 2>/dev/null \
    && ! check_deny claude "$LOCAL/$name.out" "$LOCAL/$name.err" "$LOCAL_STATUS" "$REASON_REJECTED" 2>/dev/null \
    && ! check_deny claude "$LOCAL/$name.out" "$LOCAL/$name.err" "$LOCAL_STATUS" "$REASON_CONNECTION" 2>/dev/null; then
    printf 'rv-c tests: local %s must fall through to the rvd path\n' "$name" >&2
    cat "$LOCAL/$name.out" "$LOCAL/$name.err" >&2
    exit 1
  fi
done
printf 'rv-c hook-local door: final, sanitized call, and escalate/hang/crash/garbage/wrong-id/untrusted fall-through passed\n'

printf 'rv-c hook fallback boundary: %s host denial cases, no-daemon causes, and oversized input passed\n' "$host_count"
