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
# Why not just `swift test` as root, which is how cloud containers start:
#   - CI runs as an ordinary user. As root, the tests that make a directory
#     unreadable or read-only to prove rv refuses safely all fail, because
#     root ignores file permissions.
#   - CI's runner owns its checkout. Tests write under <repo>/.build and run
#     the products built there (signal probes, the C hook, install.sh), so
#     the user needs a checkout and build of its own, not a read-only one.
#   - CI starts on a fresh VM. Tests use fixed paths under /tmp, and a run
#     as root leaves root-owned ones behind (and can create /private/tmp,
#     which turns on macOS-shaped fixtures), so a later run as the user
#     fails on them. The suite gets a private, empty /tmp.
#   - Ubuntu gives a new user umask 002. rv rightly refuses group-writable
#     managed policy files, so the suite runs with umask 022, as on CI.
#
# Started as root, this script therefore: installs the pr.yml runtime deps,
# creates NAME, mirrors this checkout to ~NAME/rv (rsync, .build excluded),
# seeds NAME's Swift tarball cache from root's, and re-runs itself from
# that copy as NAME, in a mount namespace with a fresh tmpfs on /tmp.
# Started as any other user, it builds and tests the checkout it is in.
#
# The toolchain is the official Swift tarball (Scripts/install-official-
# swift-linux.sh), never apt swift. ~/.config/rv is fingerprinted before and
# after the run, as in .github/workflows/pr.yml.
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
    -h|--help) sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) log "unknown option $1"; exit 2 ;;
  esac
done

if [[ "$(uname -s)" != "Linux" ]]; then
  log "Linux only"
  exit 1
fi

# Same list as pr.yml "Tarball runtime deps (not apt swift)", plus rsync.
APT_DEPS=(binutils gcc git gnupg2 libc6-dev libcurl4-openssl-dev libedit2 libgcc-13-dev
  libncurses-dev libpython3-dev libsqlite3-0 libsqlite3-dev libstdc++-13-dev libxml2-dev
  libz3-dev pkg-config tzdata zip unzip zlib1g-dev rsync)

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
  as_user() { install -d -o "$RUN_USER" -g "$RUN_USER" "$@"; }

  # The user's own checkout, so the build and the tests can write under it.
  copy="$user_home/rv"
  log "mirroring $ROOT to $copy"
  as_user "$copy"
  rsync -a --delete --exclude '/.build/' --chown="$RUN_USER:$RUN_USER" "$ROOT/" "$copy/"

  # Seed the user's tarball cache from root's, so the 1 GB download happens once.
  if compgen -G "/root/.cache/swift/swift-*.tar.gz" >/dev/null; then
    as_user "$user_home/.cache" "$user_home/.cache/swift"
    for f in /root/.cache/swift/swift-*.tar.gz /root/.cache/swift/swift-*.tar.gz.sig; do
      [[ -e "$f" ]] || continue
      dest="$user_home/.cache/swift/$(basename "$f")"
      if [[ ! -s "$dest" ]]; then
        log "seeding $(basename "$f") from root's cache"
        install -o "$RUN_USER" -g "$RUN_USER" -m 0644 "$f" "$dest"
      fi
    done
  fi

  # Proxy settings for the toolchain download. A CA file under root's home is
  # unreadable to the user, so it gets a copy. Nothing else of root's
  # environment is passed on.
  keep=()
  for v in HTTPS_PROXY https_proxy NO_PROXY no_proxy; do
    [[ -n "${!v:-}" ]] && keep+=("$v=${!v}")
  done
  for v in SSL_CERT_FILE CURL_CA_BUNDLE; do
    ca="${!v:-}"
    [[ -n "$ca" && -r "$ca" ]] || continue
    if ! su "$RUN_USER" -s /bin/bash -c "test -r $(printf '%q' "$ca")"; then
      as_user "$user_home/.cache/rv-cloud-test"
      install -o "$RUN_USER" -g "$RUN_USER" -m 0644 "$ca" "$user_home/.cache/rv-cloud-test/$(basename "$ca")"
      ca="$user_home/.cache/rv-cloud-test/$(basename "$ca")"
    fi
    keep+=("$v=$ca")
  done

  args=()
  [[ "$BUILD_ONLY" -eq 1 ]] && args+=(--build-only)
  [[ ${#TEST_ARGS[@]} -gt 0 ]] && args+=(-- "${TEST_ARGS[@]}")
  printf -v cmd '%q ' env "${keep[@]}" "$copy/Scripts/cloud-test.sh" "${args[@]}"
  inner="cd $(printf '%q' "$copy") && $cmd"
  # A login shell gives the user's own HOME and PATH, not root's.
  printf -v su_cmd '%q ' su - "$RUN_USER" -s /bin/bash -c "$inner"

  if unshare --mount --propagation private true 2>/dev/null; then
    # Linux CI has no /private. Some tests switch on macOS-shaped fixtures
    # when /private/tmp exists, and an earlier root run can leave one
    # behind, so the namespace hides it rather than the host losing it.
    hide_private=""
    [[ -d /private ]] && hide_private="mount -t tmpfs -o size=1m,mode=0755 rv-cloud-test-private /private && "
    log "re-running as $RUN_USER from $copy with a private /tmp"
    exec unshare --mount --propagation private /bin/sh -c \
      "mount -t tmpfs -o size=8g,mode=1777 rv-cloud-test-tmp /tmp && ${hide_private}exec $su_cmd"
  fi
  log "cannot make a mount namespace; re-running as $RUN_USER with the shared /tmp"
  log "fixed /tmp paths left by an earlier root run may fail tests"
  exec /bin/sh -c "$su_cmd"
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

mkdir -p "$HOME/.config"
LOGDIR="$HOME/.cache/rv-cloud-test"
mkdir -p "$LOGDIR"

log "swift $(swift --version 2>&1 | head -n 1 | sed 's/.*version //') · $(id -un) · umask $(umask) · $ROOT"
start=$(date +%s)
status=0
swift build --build-tests > "$LOGDIR/build.log" 2>&1 || status=$?
if [[ "$status" -ne 0 ]]; then
  grep -E "error:" "$LOGDIR/build.log" | head -20 >&2 || true
  log "build failed; see $LOGDIR/build.log"
  exit 1
fi
log "built in $(( $(date +%s) - start ))s"
[[ "$BUILD_ONLY" -eq 1 ]] && exit 0

python3 Scripts/config-dir-fingerprint.py "$HOME/.config/rv" --ignore workspaces > "$LOGDIR/config-rv.before"

start=$(date +%s)
swift test --skip-build "${TEST_ARGS[@]}" > "$LOGDIR/test.log" 2>&1 || status=$?
log "tests finished in $(( $(date +%s) - start ))s (exit $status); full log $LOGDIR/test.log"

sed 's/\x1b\[[0-9;]*m//g' "$LOGDIR/test.log" | grep -E '^. Test run with' || true
if [[ "$status" -ne 0 ]]; then
  log "failing tests:"
  sed 's/\x1b\[[0-9;]*m//g' "$LOGDIR/test.log" | grep -E '^✘ Test .* failed after' | head -60 >&2 || true
fi

python3 Scripts/config-dir-fingerprint.py "$HOME/.config/rv" --ignore workspaces > "$LOGDIR/config-rv.after"
if ! diff -u "$LOGDIR/config-rv.before" "$LOGDIR/config-rv.after" >&2; then
  log "swift test changed ~/.config/rv (diff above)"
  status=1
fi
exit "$status"
