#!/usr/bin/env bash
# Compile and run C JSON-escape unit tests. Not an SPM target.
set -euo pipefail

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

clang -Os "${CLANG_OS_FLAGS[@]}" -std=c11 -Wall \
  -I "$SRC" \
  -o "$OUT/rv" \
  "$SRC/json_escape.c" \
  "$SRC/json_reply.c" \
  "$SRC/daemon_trust.c" \
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

REASON_INPUT="The hook input was not readable UTF-8 text, so this command was blocked."
REASON_OVERSIZE="The hook input is larger than the 1 MiB limit, so this command was blocked."
REASON_UNREACHABLE='The RV background service (rvd) is not reachable, so this command was blocked. Run `rv doctor` to diagnose it.'
REASON_REJECTED='The running rvd service failed its identity check, so this command was blocked. Run `rv setup` to restart the service.'

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
# generic auth sentence. Linux pins an empty runtime dir (no socket);
# Darwin has no test-controlled Mach service, so a live foreign rvd may
# answer and be rejected by the identity check instead.
DOWN_XDG="$OUT/no-daemon-xdg"
rm -rf "$DOWN_XDG"
mkdir -p "$DOWN_XDG"
for host in $HOSTS; do
  log="$OUT/down-$host.argv"
  rm -f "$log"
  set +e
  printf '{}' | XDG_RUNTIME_DIR="$DOWN_XDG" RV_C_ARGV_LOG="$log" "$PROBE/rv" hook --host "$host" >"$OUT/down-$host.json" 2>"$OUT/down-$host.err"
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
    && check_deny "$host" "$OUT/down-$host.json" "$OUT/down-$host.err" "$status" "$REASON_REJECTED" 2>/dev/null; then
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

printf 'rv-c hook fallback boundary: %s host denial cases, no-daemon causes, and oversized input passed\n' "$host_count"
