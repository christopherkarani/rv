#!/bin/sh
# Scripts/install-smoke.sh — prove the one-line installer works end to end.
#
#   sh Scripts/install-smoke.sh --local <install.sh> <assets-dir>
#   sh Scripts/install-smoke.sh --live <install-url>
#
# --local serves <assets-dir> over loopback HTTP, redirects the installer's
# release downloads at it (a PATH curl shim that rewrites only the release
# base URL), and runs a neutered copy of the installer under an empty HOME
# with model fetching off. --live runs the same neutered install against a
# real install.sh URL (rykanv.com/install) with no redirection.
#
# Pass bar: the installer exits 0, the required binaries stage, at least
# one pack bundle stages, and the staged rv-cli/rvd execute. The neutered
# tail (`exec rv setup`) is covered by InstallScriptTests, which run the
# full script — including setup — against fixture binaries.
# Compatible with macOS /bin/sh and dash.
set -eu

usage() {
  cat <<'EOF'
Usage: Scripts/install-smoke.sh --local <install.sh> <assets-dir>
       Scripts/install-smoke.sh --live <install-url>
EOF
}

die() {
  echo "install-smoke: $*" >&2
  exit 1
}

fail() {
  echo "install-smoke: FAIL: $*" >&2
  echo "--- installer stdout ---" >&2
  cat "$WORK/stdout.log" >&2
  echo "--- installer stderr ---" >&2
  cat "$WORK/stderr.log" >&2
  for log in "$WORK/help.log" "$WORK/version.log"; do
    if [ -f "$log" ]; then
      echo "--- $log ---" >&2
      cat "$log" >&2
    fi
  done
  exit 1
}

mode=""
install_path=""
assets_dir=""
install_url=""
while [ $# -gt 0 ]; do
  case "$1" in
    --local)
      mode="local"; install_path="${2:?}"; assets_dir="${3:?}"; shift 3 ;;
    --live)
      mode="live"; install_url="${2:?}"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      usage >&2; exit 2 ;;
  esac
done
[ -n "$mode" ] || { usage >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/rv-install-smoke.XXXXXX")"
SERVER_PID=""
cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

if [ "$mode" = "live" ]; then
  curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 \
    "$install_url" -o "$WORK/upstream.sh" \
    || die "could not download $install_url"
  sh -n "$WORK/upstream.sh" || die "downloaded installer failed sh -n"
  install_path="$WORK/upstream.sh"
else
  [ -f "$install_path" ] || die "installer missing: $install_path"
  [ -d "$assets_dir" ] || die "assets dir missing: $assets_dir"
  sh -n "$install_path" || die "$install_path failed sh -n"
fi

# The smoke must never run setup: refuse unless the installer ends with the
# exact exec line, then replace that line with a marker.
want='RV_FROM_INSTALL=1 exec "$bin/rv" setup'
[ "$(tail -n 1 "$install_path")" = "$want" ] \
  || die "unexpected installer tail (expected: $want)"
sed '$ s/.*/echo SMOKE-STAGE-OK/' "$install_path" > "$WORK/install.sh"

SMOKE_PATH="$PATH"
if [ "$mode" = "local" ]; then
  command -v python3 >/dev/null 2>&1 || die "python3 is required"
  command -v curl >/dev/null 2>&1 || die "curl is required"
  base="$(grep -E '^release_base="' "$install_path" | cut -d'"' -f2)"
  [ -n "$base" ] || die "cannot find release_base in $install_path"
  port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
  (cd "$assets_dir" && exec python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1) &
  SERVER_PID=$!
  ready=0
  i=0
  while [ "$i" -lt 100 ]; do
    if curl -fsS "http://127.0.0.1:$port/" >/dev/null 2>&1; then
      ready=1
      break
    fi
    i=$((i + 1))
    sleep 0.1
  done
  [ "$ready" = "1" ] || die "asset server did not start on port $port"
  # Rewrites only the release base; every other argument passes through.
  # Smoke-controlled paths never contain spaces (see TMPDIR below).
  mkdir -p "$WORK/shim"
  cat > "$WORK/shim/curl" <<EOF
#!/bin/sh
rewritten=""
for arg in "\$@"; do
  case "\$arg" in
    "$base"/*) arg="http://127.0.0.1:$port/\${arg#"$base"/}" ;;
  esac
  rewritten="\$rewritten \$arg"
done
# shellcheck disable=SC2086
exec $(command -v curl) \$rewritten
EOF
  chmod 755 "$WORK/shim/curl"
  SMOKE_PATH="$WORK/shim:$PATH"
fi

SMOKE_HOME="$WORK/home"
mkdir -p "$SMOKE_HOME" "$WORK/tmp"
status=0
PATH="$SMOKE_PATH" HOME="$SMOKE_HOME" TMPDIR="$WORK/tmp" \
  RV_INSTALL_NO_MODELS=1 sh "$WORK/install.sh" \
  >"$WORK/stdout.log" 2>"$WORK/stderr.log" || status=$?
[ "$status" -eq 0 ] || fail "installer exited $status"
grep -qx 'SMOKE-STAGE-OK' "$WORK/stdout.log" || fail "stage marker missing"

BIN="$SMOKE_HOME/.local/bin"
for name in rv rv-cli rvd rv-workspace-host; do
  [ -x "$BIN/$name" ] || fail "$name not staged executable"
done
if [ "$(uname -s)" = "Linux" ]; then
  [ -x "$BIN/rv-isolation-exec" ] || fail "rv-isolation-exec not staged on Linux"
fi
packs=0
for bundle in "$BIN"/*_RVPacks.bundle "$BIN"/*_RVPacks.resources; do
  [ -d "$bundle" ] && packs=$((packs + 1))
done
[ "$packs" -ge 1 ] || fail "no pack bundle staged"

"$BIN/rv-cli" --help >"$WORK/help.log" 2>&1 \
  || fail "staged rv-cli --help exited $?"
grep -q 'setup' "$WORK/help.log" || fail "staged rv-cli --help has no setup"
"$BIN/rvd" --version >"$WORK/version.log" 2>&1 \
  || fail "staged rvd --version exited $?"
grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+' "$WORK/version.log" \
  || fail "staged rvd --version is not a version: $(cat "$WORK/version.log")"

echo "install-smoke: PASS ($mode): trio+host staged, $packs pack bundle(s), rvd $(cat "$WORK/version.log")"
