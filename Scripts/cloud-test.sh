#!/usr/bin/env bash
# Scripts/cloud-test.sh — build and run the full suite the way Linux CI does,
# from a fresh cloud session (Claude Code on the web, a dev container, a VM).
#
# Usage:
#   Scripts/cloud-test.sh [--user NAME] [--build-only] [-- SWIFT_TEST_ARGS...]
#
#   --user NAME    unprivileged account to run as when started as root
#                  (default: rvtest; created if missing)
#   --build-only   build the tests, do not run them
#   -- ARGS        passed to `swift test --skip-build` (e.g. --filter RVPacksTests)
#
# Why not just `swift test`:
#   - CI runs as an ordinary user. As root, the tests that make a directory
#     unreadable or read-only to prove rv refuses safely all fail, because
#     root ignores file permissions. Started as root, this script re-runs
#     itself as NAME.
#   - Ubuntu gives such a user umask 002. rv rightly refuses group-writable
#     managed policy files, so the policy store tests fail under it. The
#     suite runs with umask 022, as on CI.
#   - The toolchain is the official Swift tarball (Scripts/install-official-
#     swift-linux.sh), never apt swift. As root, a tarball already in
#     root's cache is copied to NAME's cache instead of downloaded again.
#
# The checkout stays root-owned and is only read: the build goes to
# NAME's ~/.cache/rv-build (--scratch-path). ~/.config/rv is fingerprinted
# before and after the run, as in .github/workflows/pr.yml.
#
# Not covered here (see pr.yml "linux root e2e"): the root-only filtered
# runs, the rv run HTTPS e2e, and the systemd custodian e2e.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN_USER="rvtest"
BUILD_ONLY=0
TEST_ARGS=()

log() { printf 'cloud-test: %s\n' "$*" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) RUN_USER="${2:?--user needs a name}"; shift 2 ;;
    --build-only) BUILD_ONLY=1; shift ;;
    --) shift; TEST_ARGS=("$@"); break ;;
    -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) log "unknown option $1"; exit 2 ;;
  esac
done

if [[ "$(uname -s)" != "Linux" ]]; then
  log "Linux only"
  exit 1
fi

# Same list as pr.yml "Tarball runtime deps (not apt swift)".
APT_DEPS=(binutils gcc git gnupg2 libc6-dev libcurl4-openssl-dev libedit2 libgcc-13-dev
  libncurses-dev libpython3-dev libsqlite3-0 libsqlite3-dev libstdc++-13-dev libxml2-dev
  libz3-dev pkg-config tzdata zip unzip zlib1g-dev)

if [[ "$(id -u)" -eq 0 ]]; then
  if dpkg-query -W -f='${Status}\n' swift swiftlang 2>/dev/null | grep -q 'install ok installed'; then
    log "apt swift/swiftlang is installed; remove it (the suite needs the official tarball)"
    exit 1
  fi
  missing=()
  for pkg in "${APT_DEPS[@]}"; do
    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed' || missing+=("$pkg")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    log "installing ${missing[*]}"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${missing[@]}" >/dev/null
  fi

  if ! id "$RUN_USER" >/dev/null 2>&1; then
    log "creating user $RUN_USER"
    useradd --create-home --user-group --shell /bin/bash "$RUN_USER"
  fi
  user_home="$(getent passwd "$RUN_USER" | cut -d: -f6)"

  # Seed the user's tarball cache from root's, so the 1 GB download happens once.
  if compgen -G "/root/.cache/swift/swift-*.tar.gz" >/dev/null; then
    install -d -o "$RUN_USER" -g "$RUN_USER" "$user_home/.cache" "$user_home/.cache/swift"
    for f in /root/.cache/swift/swift-*.tar.gz /root/.cache/swift/swift-*.tar.gz.sig; do
      [[ -e "$f" ]] || continue
      dest="$user_home/.cache/swift/$(basename "$f")"
      if [[ ! -s "$dest" ]]; then
        log "seeding $(basename "$f") from root's cache"
        install -o "$RUN_USER" -g "$RUN_USER" -m 0644 "$f" "$dest"
      fi
    done
  fi

  if ! su "$RUN_USER" -s /bin/bash -c "test -r '$ROOT/Package.swift' && test -x '$ROOT/Scripts/cloud-test.sh'"; then
    log "$RUN_USER cannot read $ROOT; every directory above it needs o+x and the checkout o+r"
    exit 1
  fi

  args=()
  [[ "$BUILD_ONLY" -eq 1 ]] && args+=(--build-only)
  [[ ${#TEST_ARGS[@]} -gt 0 ]] && args+=(-- "${TEST_ARGS[@]}")
  log "re-running as $RUN_USER (root ignores the permissions some tests rely on)"
  # A login shell gives the user's own HOME, PATH and environment, not root's.
  # The agent proxy settings (HTTPS_PROXY, CA bundle) are passed through for
  # the toolchain download; nothing else from root's environment is.
  keep=()
  for v in HTTPS_PROXY https_proxy NO_PROXY no_proxy SSL_CERT_FILE CURL_CA_BUNDLE; do
    [[ -n "${!v:-}" ]] && keep+=("$v=${!v}")
  done
  printf -v cmd '%q ' env "${keep[@]}" "$ROOT/Scripts/cloud-test.sh" "${args[@]}"
  exec su - "$RUN_USER" -s /bin/bash -c "cd $(printf '%q' "$ROOT") && $cmd"
fi

umask 022
cd "$ROOT"

bin="$("$ROOT/Scripts/install-official-swift-linux.sh" --print-bin)"
export PATH="$bin:$PATH"
pin="$(tr -d '[:space:]' < .swift-version)"
swift --version 2>&1 | head -n 1 | grep -Eq "Swift version ${pin}( |\.|$)" || {
  log "swift on PATH is not $pin: $(swift --version 2>&1 | head -n 1)"
  exit 1
}

SCRATCH="$HOME/.cache/rv-build"
mkdir -p "$SCRATCH" "$HOME/.config"
LOGDIR="$HOME/.cache/rv-cloud-test"
mkdir -p "$LOGDIR"

log "swift $(swift --version 2>&1 | head -n 1 | sed 's/.*version //') · $(id -un) · umask $(umask) · scratch $SCRATCH"
start=$(date +%s)
swift build --build-tests --scratch-path "$SCRATCH" 2>&1 | tee "$LOGDIR/build.log" | grep -E "error:|Compiling|Build complete" | grep -v Compiling || true
if [[ "${PIPESTATUS[0]}" -ne 0 ]]; then
  log "build failed; see $LOGDIR/build.log"
  exit 1
fi
log "built in $(( $(date +%s) - start ))s"
[[ "$BUILD_ONLY" -eq 1 ]] && exit 0

python3 Scripts/config-dir-fingerprint.py "$HOME/.config/rv" --ignore workspaces > "$LOGDIR/config-rv.before"

status=0
start=$(date +%s)
swift test --skip-build --scratch-path "$SCRATCH" "${TEST_ARGS[@]}" > "$LOGDIR/test.log" 2>&1 || status=$?
log "tests finished in $(( $(date +%s) - start ))s (exit $status); full log $LOGDIR/test.log"

sed 's/\x1b\[[0-9;]*m//g' "$LOGDIR/test.log" | grep -E '^. Test run with' || true
if [[ "$status" -ne 0 ]]; then
  log "failures:"
  sed 's/\x1b\[[0-9;]*m//g' "$LOGDIR/test.log" | grep -E '^✘ Test .* (failed after|recorded an issue)' | head -60 >&2 || true
fi

python3 Scripts/config-dir-fingerprint.py "$HOME/.config/rv" --ignore workspaces > "$LOGDIR/config-rv.after"
if ! diff -u "$LOGDIR/config-rv.before" "$LOGDIR/config-rv.after" >&2; then
  log "swift test changed ~/.config/rv (diff above)"
  status=1
fi
exit "$status"
