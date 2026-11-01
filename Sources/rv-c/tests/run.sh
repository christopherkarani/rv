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

clang -Os "${CLANG_OS_FLAGS[@]}" -std=c11 -Wall \
  -I "$SRC" \
  -o "$OUT/rv" \
  "$SRC/json_escape.c" \
  "$SRC/json_reply.c" \
  "$SRC/daemon_trust.c" \
  "$SRC/hook_fallback.c" \
  "$SRC/rv.c"

# Pipe hosts must match HookHost.setupSlotOrder. Invalid hosts exec rv-cli
# before the socket/XPC door, so a missing name is silent miss-as-operator.
if ! awk '
  /static int is_valid_host/,/^}/ { body = body $0 "\n" }
  END {
    n = split("grok pi opencode claude openclaw hermes codex cursor antigravity", want, " ")
    for (i = 1; i <= n; i++) {
      if (index(body, "\"" want[i] "\"") == 0) exit 1
    }
  }
' "$SRC/rv.c"; then
  printf "rv-c tests: is_valid_host must include every setupSlotOrder host\n" >&2
  exit 1
fi

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

# Every host denies malformed input directly; an executable CLI sibling must
# never receive authority-bearing fallback input.
for host in grok pi opencode claude openclaw hermes codex cursor antigravity; do
  log="$OUT/deny-$host.argv"
  rm -f "$log"
  set +e
  printf 'a\0b' | RV_C_ARGV_LOG="$log" "$PROBE/rv" hook --host "$host" >"$OUT/deny-$host.json" 2>"$OUT/deny-$host.err"
  status=$?
  set -e
  expected=1
  case "$host" in grok|claude|cursor|antigravity) expected=0 ;; codex) expected=2 ;; esac
  if [[ "$status" -ne "$expected" || -e "$log" ]]; then
    printf 'rv-c tests: %s fallback must deny without invoking CLI\n' "$host" >&2
    exit 1
  fi
  case "$host" in
    claude) marker='"permissionDecision":"deny"' ;;
    cursor) marker='"permission":"deny"' ;;
    codex) marker='"decision":"block"' ;;
    *) marker='"decision":"deny"' ;;
  esac
  if ! grep -q "$marker" "$OUT/deny-$host.json"; then
    printf 'rv-c tests: %s missing host denial wire\n' "$host" >&2
    exit 1
  fi
  if [[ "$host" == codex && ! -s "$OUT/deny-$host.err" ]]; then
    printf 'rv-c tests: Codex requires blocking stderr\n' >&2
    exit 1
  fi
done

# Oversized input must also deny without invoking a replay child.
set +e
head -c 1048577 /dev/zero | tr '\0' 'x' | RV_C_ARGV_LOG="$OUT/oversize.argv" "$PROBE/rv" hook --host codex >"$OUT/oversize.json" 2>"$OUT/oversize.err"
oversize_status=${PIPESTATUS[2]}
set -e
if [[ "$oversize_status" -ne 2 || -e "$OUT/oversize.argv" || ! -s "$OUT/oversize.err" ]]; then
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
# points XDG_RUNTIME_DIR at an empty dir (ENOENT); Darwin relies on
# dev.rv.evaluate being unregistered for this user and skips otherwise —
# a live service must never be poked by unit tests.
DOWN_ENV=()
down_ready=1
if [[ "$OS" == "Linux" ]]; then
  mkdir -p "$OUT/empty-xdg"
  DOWN_ENV=(XDG_RUNTIME_DIR="$OUT/empty-xdg")
elif launchctl print "gui/$(id -u)/dev.rv.evaluate" >/dev/null 2>&1; then
  down_ready=0
  printf 'rv-c tests: dev.rv.evaluate is registered; skipping daemon-down cases\n'
fi

expect_down() {
  local name="$1" host="$2" mode="$3" want_status="$4" marker="$5"
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
    || ! grep -q 'RV daemon is not reachable' "$OUT/down-$name.json"; then
    printf 'rv-c tests: down %s missing %s / unreachable reason\n' "$name" "$marker" >&2
    cat "$OUT/down-$name.json" >&2
    exit 1
  fi
}

if [[ "$down_ready" -eq 1 ]]; then
  expect_down claude-default claude "" 0 '"permissionDecision":"ask"'
  expect_down claude-junk claude "bogus" 0 '"permissionDecision":"ask"'
  expect_down cursor-default cursor "" 0 '"permission":"ask"'
  expect_down claude-deny claude deny 0 '"permissionDecision":"deny"'
  expect_down claude-allow claude allow 0 ''
  expect_down codex-default codex "" 2 '"decision":"block"'
  expect_down opencode-default opencode "" 1 '"decision":"deny"'
  if [[ ! -s "$OUT/down-codex-default.err" ]]; then
    printf 'rv-c tests: Codex down fallback requires blocking stderr\n' >&2
    exit 1
  fi
  # Malformed input stays a deny even when the operator chose allow.
  set +e
  printf 'a\0b' | RV_HOOK_WHEN_DOWN=allow "$PROBE/rv" hook --host claude >"$OUT/input-allow.json" 2>/dev/null
  st=$?
  set -e
  if [[ "$st" -ne 0 ]] || ! grep -q '"permissionDecision":"deny"' "$OUT/input-allow.json" \
    || ! grep -q 'could not read this hook request' "$OUT/input-allow.json"; then
    printf 'rv-c tests: malformed input must deny regardless of RV_HOOK_WHEN_DOWN\n' >&2
    exit 1
  fi
  printf 'rv-c daemon-down fallback: ask/deny/allow rendering passed\n'
fi

printf 'rv-c hook fallback boundary: 9 host denial cases and oversized input passed\n'
