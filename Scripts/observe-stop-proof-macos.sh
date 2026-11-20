#!/usr/bin/env bash
# macOS proof: in observe mode, booting out rvd's launchd job makes the C
# hook fail closed once the rvd state marker says rvd ran, while an
# announced restart still steps aside and an expired one fails closed again.
#
# Never touches the installed rv: the hook is compiled against a throwaway
# Mach service label (dev.rv.proof.observe-stop.<pid>), a fixture
# config.json, rvd state marker and managed-policy dir under /tmp, and the
# throwaway LaunchAgent is booted out on exit. dev.rv.evaluate, ~/.config/rv
# and /Library/Application Support/RV are never read or written.
# Compatible with macOS /bin/bash 3.2.
set -euo pipefail
unset RV_HOOK_WHEN_DOWN

[[ "$(uname -s)" == "Darwin" ]] || { printf 'observe-stop-proof: macOS only\n' >&2; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Sources/rv-c"
LABEL="dev.rv.proof.observe-stop.$$"
DOMAIN="gui/$(id -u)"
# launchd cannot read plists under Darwin TMPDIR (/var/folders/...).
WORK="/tmp/rv-observe-stop-proof-$$"
CONFIG="$WORK/config/config.json"
MARKER="$WORK/config/rvd-state"
MANAGED="$WORK/managed"
PLIST="$WORK/$LABEL.plist"
HOOK="$WORK/bin/rv"

fail() {
  printf 'observe-stop-proof: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$WORK/config" "$WORK/bin"
clang -Os -arch arm64 -mmacosx-version-min=15.0 -framework Security -framework CoreFoundation \
  -std=c11 -Wall -I "$SRC" \
  -DRV_MACH_SERVICE="\"$LABEL\"" \
  -DRV_HOOK_OBSERVE_CONFIG_PATH="\"$CONFIG\"" \
  -DRV_HOOK_RVD_STATE_PATH="\"$MARKER\"" \
  -DRV_HOOK_MANAGED_POLICY_DIR="\"$MANAGED\"" \
  -o "$HOOK" \
  "$SRC/json_escape.c" "$SRC/json_reply.c" "$SRC/daemon_trust.c" \
  "$SRC/hook_fallback.c" "$SRC/observe_gate.c" "$SRC/rvd_state.c" "$SRC/rv.c"

printf '{"guard":{"mode":"observe"}}' > "$CONFIG"
chmod 600 "$CONFIG"

# A real launchd job owning the throwaway Mach service, never launched
# (no client connects while it is registered).
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>MachServices</key><dict><key>$LABEL</key><true/></dict>
  <key>ProgramArguments</key><array><string>/usr/bin/false</string></array>
  <key>RunAtLoad</key><false/>
  <key>KeepAlive</key><false/>
</dict>
</plist>
EOF
launchctl bootstrap "$DOMAIN" "$PLIST" || fail "could not bootstrap $LABEL"
launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || fail "$LABEL not registered after bootstrap"

# rvd ran and armed the marker; then an agent boots rvd's job out.
printf 'armed\n' > "$MARKER"
chmod 600 "$MARKER"
launchctl bootout "$DOMAIN/$LABEL" || fail "could not boot out $LABEL"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
  sleep 0.2
done
launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 && fail "$LABEL still registered after bootout"

run_hook() {
  local name="$1"
  set +e
  printf '{"tool_name":"Bash","tool_input":{"command":"ls"}}' \
    | "$HOOK" hook --host claude >"$WORK/$name.out" 2>"$WORK/$name.err"
  echo $? >"$WORK/$name.status"
  set -e
}

expect_stopped() {
  local name="$1"
  run_hook "$name"
  [[ "$(cat "$WORK/$name.status")" == "0" ]] || fail "$name: exit $(cat "$WORK/$name.status")"
  grep -q '"permissionDecision":"ask"' "$WORK/$name.out" \
    && grep -q 'rvd was stopped or crashed after it last ran' "$WORK/$name.out" \
    || { cat "$WORK/$name.out" "$WORK/$name.err" >&2; fail "$name: expected the stopped ask"; }
  if grep -q 'allowed without being checked' "$WORK/$name.err"; then
    fail "$name: took the observe step-aside"
  fi
}

expect_step_aside() {
  local name="$1"
  run_hook "$name"
  [[ "$(cat "$WORK/$name.status")" == "0" && ! -s "$WORK/$name.out" ]] \
    && grep -q 'RV observe mode: daemon unavailable' "$WORK/$name.err" \
    || { cat "$WORK/$name.out" "$WORK/$name.err" >&2; fail "$name: expected the observe allow"; }
}

expect_stopped booted-out-armed
printf 'restarting %s\n' "$(( $(date +%s) + 60 ))" > "$MARKER"
expect_step_aside booted-out-restarting
printf 'restarting %s\n' "$(( $(date +%s) - 1 ))" > "$MARKER"
expect_stopped booted-out-expired
rm -f "$MARKER"
expect_step_aside booted-out-never-ran

printf 'observe-stop-proof: bootout fails closed once rvd ran; fresh install and announced restart step aside\n'
