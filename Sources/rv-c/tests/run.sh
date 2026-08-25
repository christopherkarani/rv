#!/usr/bin/env bash
# Compile and run C JSON-escape unit tests. Not an SPM target.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SRC="$ROOT/Sources/rv-c"
OUT="${RV_C_TEST_OUT:-$ROOT/.build/rv-c-tests}"

if [[ "$(uname -m)" != "arm64" ]]; then
  printf "rv-c tests: Apple Silicon only\n" >&2
  exit 1
fi

mkdir -p "$OUT"
clang -Os -arch arm64 -mmacosx-version-min=26.0 -std=c11 -Wall \
  -I "$SRC" \
  -o "$OUT/json_escape_test" \
  "$SRC/tests/json_escape_test.c" \
  "$SRC/json_escape.c"
"$OUT/json_escape_test"

clang -Os -arch arm64 -mmacosx-version-min=26.0 -std=c11 -Wall \
  -I "$SRC" \
  -o "$OUT/json_reply_test" \
  "$SRC/tests/json_reply_test.c" \
  "$SRC/json_escape.c" \
  "$SRC/json_reply.c"
"$OUT/json_reply_test"

clang -Os -arch arm64 -mmacosx-version-min=26.0 -std=c11 -Wall \
  -I "$SRC" \
  -o "$OUT/rv" \
  "$SRC/json_escape.c" \
  "$SRC/json_reply.c" \
  "$SRC/rv.c"

if otool -L "$OUT/rv" | grep -E 'Foundation|CFNetwork' >/dev/null; then
  printf "rv-c tests: C rv must not link Foundation or CFNetwork\n" >&2
  otool -L "$OUT/rv" >&2
  exit 1
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

NUL_LOG="$OUT/nul.argv"
NUL_STDIN="$OUT/nul.stdin"
set +e
printf 'a\0b' | RV_C_ARGV_LOG="$NUL_LOG" RV_C_STDIN_LOG="$NUL_STDIN" "$PROBE/rv" hook --host grok
nul_st=$?
set -e
if [[ "$nul_st" -ne 17 ]]; then
  printf "rv-c tests: NUL miss expected replay exit 17, got %s\n" "$nul_st" >&2
  exit 1
fi
if ! grep -q -- '--host' "$NUL_LOG" || ! grep -q -- 'grok' "$NUL_LOG"; then
  printf "rv-c tests: NUL miss argv was not hook --host grok\n" >&2
  exit 1
fi

CLAUDE_NUL_LOG="$OUT/nul-claude.argv"
set +e
printf 'a\0b' | RV_C_ARGV_LOG="$CLAUDE_NUL_LOG" RV_C_STDIN_LOG="/dev/null" "$PROBE/rv" hook --host claude
claude_nul_st=$?
set -e
if [[ "$claude_nul_st" -ne 17 ]]; then
  printf "rv-c tests: Claude NUL miss expected replay exit 17, got %s\n" "$claude_nul_st" >&2
  exit 1
fi
if ! grep -q -- '--host' "$CLAUDE_NUL_LOG" || ! grep -q -- 'claude' "$CLAUDE_NUL_LOG"; then
  printf "rv-c tests: Claude NUL miss argv was not hook --host claude\n" >&2
  exit 1
fi
if [[ "$(wc -c < "$NUL_STDIN" | tr -d ' ')" != "3" ]]; then
  printf "rv-c tests: NUL miss did not replay exact stdin\n" >&2
  exit 1
fi

# Bounded oversize read: the hook must start the miss child after the XPC
# prefix limit, without waiting for EOF, and then replay the unread tail.
LIMIT="$OUT/bounded-stdin-probe"
rm -rf "$LIMIT"
mkdir -p "$LIMIT"
cp "$OUT/rv" "$LIMIT/rv"
cat > "$LIMIT/rv-cli" <<'EOF'
#!/bin/sh
: > "${RV_C_START_LOG:?}"
cat > "${RV_C_STDIN_LOG:?}"
wc -c < "$RV_C_STDIN_LOG" > "${RV_C_COUNT_LOG:?}"
exit 17
EOF
chmod 755 "$LIMIT/rv-cli"
FIFO="$LIMIT/stdin"
mkfifo "$FIFO"
{
  head -c 1048576 /dev/zero | tr '\0' 'x'
  printf 'x'
  printf 'tail-data-1234567'
} > "$LIMIT/expected"
(
  head -c 1048576 /dev/zero | tr '\0' 'x'
  printf 'x'
  while [[ ! -f "$LIMIT/release" ]]; do
    sleep 0.01
  done
  printf 'tail-data-1234567'
) > "$FIFO" &
limit_writer=$!
set +e
RV_C_START_LOG="$LIMIT/started" RV_C_COUNT_LOG="$LIMIT/count" \
  RV_C_STDIN_LOG="$LIMIT/replayed" \
  "$LIMIT/rv" hook --host grok < "$FIFO" >/dev/null 2>&1 &
limit_rv=$!
set -e
limit_started=0
for _ in $(seq 1 100); do
  if [[ -f "$LIMIT/started" ]]; then
    limit_started=1
    break
  fi
  sleep 0.01
done
if [[ "$limit_started" -ne 1 ]]; then
  kill "$limit_rv" "$limit_writer" 2>/dev/null || true
  wait "$limit_rv" 2>/dev/null || true
  wait "$limit_writer" 2>/dev/null || true
  printf "rv-c tests: bounded stdin waited for EOF before miss replay\n" >&2
  exit 1
fi
touch "$LIMIT/release"
set +e
wait "$limit_rv"
limit_status=$?
set -e
wait "$limit_writer" 2>/dev/null || true
if [[ "$limit_status" -ne 17 ]]; then
  printf "rv-c tests: bounded stdin replay exited %s, expected 17\n" "$limit_status" >&2
  exit 1
fi
if [[ "$(tr -d '[:space:]' < "$LIMIT/count")" != "1048594" ]]; then
  printf "rv-c tests: bounded stdin replay truncated the unread tail\n" >&2
  exit 1
fi
if ! cmp -s "$LIMIT/expected" "$LIMIT/replayed"; then
  printf "rv-c tests: bounded stdin replay changed input bytes\n" >&2
  exit 1
fi

EMPTY="$OUT/empty-home"
rm -rf "$EMPTY"
mkdir -p "$EMPTY"
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

# SIGPIPE replay: a child that exits before consuming stdin must leave the
# parent fail-closed at exit 2, never dead by signal 13. Stdin carries a NUL
# (skips XPC) and exceeds the 64 KiB pipe buffer so the write cannot win the
# race against the child's exit.
DIER="$OUT/sigpipe-probe"
rm -rf "$DIER"
mkdir -p "$DIER"
cp "$OUT/rv" "$DIER/rv"
printf '#!/bin/sh\nexit 9\n' > "$DIER/rv-cli"
chmod 755 "$DIER/rv" "$DIER/rv-cli"
SIG_STDIN="$OUT/sigpipe.stdin"
{ printf 'a\0b'; head -c 1200000 /dev/zero | tr '\0' 'x'; } > "$SIG_STDIN"
set +e
"$DIER/rv" hook --host grok < "$SIG_STDIN"
sig_st=$?
set -e
if [[ "$sig_st" -ne 2 ]]; then
  printf "rv-c tests: dead replay child must yield fail-closed exit 2, got %s (signal death is 141)\n" "$sig_st" >&2
  exit 1
fi
