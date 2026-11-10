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
  -DRV_HOOK_USER_RUNTIME_ROOT="\"$RUNTIME_ROOT\"" \
  -o "$OUT/rv" \
  "$SRC/json_escape.c" \
  "$SRC/json_reply.c" \
  "$SRC/daemon_trust.c" \
  "$SRC/hook_fallback.c" \
  "$SRC/observe_gate.c" \
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
  RV_C_ARGV_LOG="$log" "$PROBE/rv" "$@"
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
stop = "RV blocked this command. Do not retry. Do not rewrite the command. Wait for the human."
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
    assert obj["permission"] == "deny" and obj["agent_message"] == stop, (host, obj)
    reason = obj["user_message"]
else:
    raise SystemExit("rv-c tests: no expected deny wire for HookHost %s" % host)
if status != expect_status:
    raise SystemExit("%s: deny exit %d, want %d" % (host, status, expect_status))
if not reason or want not in reason:
    raise SystemExit("%s: reason %r missing %r" % (host, reason, want))
PY
}

# Substrings of the hook_fallback.c messages (classified, not a generic sentence).
REASON_INPUT="RV could not read this hook request"
REASON_OVERSIZE="RV could not read this hook request"
REASON_UNREACHABLE='RV daemon is not reachable'
REASON_CONNECTION='RV daemon connection failed'
REASON_REJECTED='RV daemon identity check failed'

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
    rm -f "$PROBE/rvd"
    DOWN_ENV=("${LINUX_DOWN_ENV[@]}")
    printf 'rv-c daemon-down fallback: Linux socket classification passed\n'
  fi
  rm -f "$OBSERVE_CONFIG"
  printf 'rv-c daemon-down fallback: observe rendering passed\n'
fi

printf 'rv-c hook fallback boundary: %s host denial cases, no-daemon causes, and oversized input passed\n' "$host_count"
