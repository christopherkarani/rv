#!/usr/bin/env bash
# Scripts/cloud-test.sh — build and run the full suite the way Linux CI does,
# from a fresh cloud session (Claude Code on the web, a dev container, a VM).
#
# Usage:
#   Scripts/cloud-test.sh [--user NAME] [--build-only] [-- SWIFT_TEST_ARGS...]
#
#   --user NAME    unprivileged account to run as when started as root
#                  (default: rvtest; created if missing; never uid 0)
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
# creates NAME, has NAME mirror this checkout to ~NAME/rv-cloud-test (rsync
# --delete, .build and agent worktrees excluded), seeds NAME's Swift tarball
# cache from root's, and re-runs itself from that copy as NAME, in a mount
# namespace with a fresh tmpfs on /tmp (the shared /tmp, with a warning,
# where the namespace or the mount is refused).
# Started as any other user, it builds and tests the checkout it is in.
#
# Root never writes into NAME's home, which NAME controls: NAME does the
# copying itself (so the checkout must be readable by NAME), and root only
# passes it the tarballs and CA file on stdin. ~NAME/rv-cloud-test carries a
# marker the script writes when it makes the directory; an existing one
# without it, or a symlinked or foreign-owned copy or cache directory, is
# refused, so the rsync --delete never runs over another directory.
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
COPY_NAME="rv-cloud-test"
COPY_MARKER=".rv-cloud-test-copy"
BUILD_ONLY=0
TEST_ARGS=()

log() { printf 'cloud-test: %s\n' "$*" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) RUN_USER="${2:?--user needs a name}"; shift 2 ;;
    --build-only) BUILD_ONLY=1; shift ;;
    --) shift; TEST_ARGS=("$@"); break ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
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
  if [[ "$(id -u "$RUN_USER")" -eq 0 ]]; then
    log "--user $RUN_USER has uid 0; the suite must run unprivileged"
    exit 2
  fi
  user_home="$(getent passwd "$RUN_USER" | cut -d: -f6)"
  copy="$user_home/$COPY_NAME"
  if [[ -L "$copy" ]]; then
    log "$copy is a symlink; refusing"
    exit 1
  fi

  # Root never writes into the user's home: every path there is one the user
  # controls (a planted symlink would turn a root chown, copy or rsync
  # --delete onto /etc). The user makes its own copy of this checkout, which
  # it must be able to read, and root only hands it bytes on stdin.
  as_user() { su "$RUN_USER" -s /bin/bash -c "$1" cloud-test "${@:2}"; }
  if ! as_user 'cd / && test -r "$1/Package.swift" && test -x "$1"' "$ROOT"; then
    log "$RUN_USER cannot read $ROOT; make the checkout world-readable or clone it elsewhere"
    exit 1
  fi
  # Refuses a symlinked or foreign-owned path, so the user only ever writes
  # where it means to.
  user_lib='
    set -euo pipefail
    umask 022
    cd "$HOME"
    say() { printf "cloud-test: %s\n" "$*" >&2; }
    own_dir() {
      if [[ -L "$1" ]]; then say "$1 is a symlink; refusing"; exit 1; fi
      [[ -e "$1" ]] || mkdir "$1"
      if [[ ! -d "$1" || ! -O "$1" ]]; then say "$1 is not a directory owned by $(id -un); refusing"; exit 1; fi
    }
    own_file() {
      if [[ -L "$1" ]]; then say "$1 is a symlink; refusing"; exit 1; fi
      if [[ -e "$1" && ( ! -f "$1" || ! -O "$1" ) ]]; then say "$1 is not a file owned by $(id -un); refusing"; exit 1; fi
    }
    # Writes stdin to $1 via a temp file and rename, never through a link.
    put() {
      own_file "$1"
      tmp="$(mktemp "$1.XXXXXX")"
      cat > "$tmp"
      chmod 0644 "$tmp"
      mv -f -T "$tmp" "$1"
    }
  '

  # The user's own checkout, so the build and the tests can write under it.
  # A dedicated directory with a marker this script writes: rsync --delete
  # runs only over a directory this script made, never over an existing
  # ~/rv or anything else in a real account's home.
  log "mirroring $ROOT to $copy"
  as_user "$user_lib"'
    copy="$HOME/$2"
    marker="$copy/$3"
    if [[ -e "$copy" || -L "$copy" ]]; then
      own_dir "$copy"
      if [[ -L "$marker" || ! -f "$marker" ]]; then
        say "$copy exists but was not made by cloud-test.sh (no $3); refusing to rsync --delete over it"
        exit 1
      fi
    else
      own_dir "$copy"
      printf "made by Scripts/cloud-test.sh; rsync --delete mirrors a checkout here\n" > "$marker"
    fi
    rsync -a --delete --exclude ".build/" --exclude "/.claude/worktrees/" --exclude "/.worktrees/" \
      --exclude "/$3" "$1/" "$copy/"
  ' "$ROOT" "$COPY_NAME" "$COPY_MARKER"

  # Seed the user's tarball cache from root's, so the 1 GB download happens once.
  for f in /root/.cache/swift/swift-*.tar.gz /root/.cache/swift/swift-*.tar.gz.sig; do
    [[ -f "$f" && ! -L "$f" ]] || continue
    name="$(basename "$f")"
    if as_user 'test -s "$HOME/.cache/swift/$1"' "$name"; then
      continue
    fi
    log "seeding $name from root's cache"
    as_user "$user_lib"'own_dir .cache; own_dir .cache/swift; put ".cache/swift/$1"' "$name" < "$f"
  done

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
    if ! as_user 'test -r "$1"' "$ca"; then
      name="$(basename "$ca")"
      as_user "$user_lib"'own_dir .cache; own_dir .cache/rv-cloud-test; put ".cache/rv-cloud-test/$1"' "$name" < "$ca"
      ca="$user_home/.cache/rv-cloud-test/$name"
    fi
    keep+=("$v=$ca")
  done

  args=()
  [[ "$BUILD_ONLY" -eq 1 ]] && args+=(--build-only)
  [[ ${#TEST_ARGS[@]} -gt 0 ]] && args+=(-- "${TEST_ARGS[@]}")
  printf -v cmd '%q ' env "${keep[@]}" "$copy/Scripts/cloud-test.sh" "${args[@]}"
  # Parsed by the user's bash (su -s /bin/bash), which reads %q's $'...'.
  inner="cd $(printf '%q' "$copy") && $cmd"
  # A login shell gives the user's own HOME and PATH, not root's.
  run_as_user=(su - "$RUN_USER" -s /bin/bash -c "$inner")
  shared_tmp_warning='cloud-test: re-running as %s with the shared /tmp; fixed /tmp paths left by an earlier root run may fail tests\n'

  if unshare --mount --propagation private true 2>/dev/null; then
    # Linux CI has no /private. Some tests switch on macOS-shaped fixtures
    # when /private/tmp exists, and an earlier root run can leave one
    # behind, so the namespace hides it rather than the host losing it.
    # A namespace whose mounts are refused falls back to the shared /tmp.
    exec unshare --mount --propagation private /bin/bash -c '
      user="$1" copy="$2" warning="$3"; shift 3
      if mount -t tmpfs -o size=8g,mode=1777 rv-cloud-test-tmp /tmp 2>/dev/null; then
        if [[ -d /private ]] && ! mount -t tmpfs -o size=1m,mode=0755 rv-cloud-test-private /private 2>/dev/null; then
          printf "cloud-test: cannot hide /private; macOS-shaped fixtures may switch on\n" >&2
        fi
        printf "cloud-test: re-running as %s from %s with a private /tmp\n" "$user" "$copy" >&2
      else
        printf "cloud-test: cannot mount a private /tmp\n" >&2
        printf "$warning" "$user" >&2
      fi
      exec "$@"
    ' cloud-test "$RUN_USER" "$copy" "$shared_tmp_warning" "${run_as_user[@]}"
  fi
  log "cannot make a mount namespace"
  printf "$shared_tmp_warning" "$RUN_USER" >&2
  exec "${run_as_user[@]}"
fi

umask 022
cd "$ROOT"

bin="$("$ROOT/Scripts/install-official-swift-linux.sh" --print-bin)"
export PATH="$bin:$PATH"
pin="$(tr -d '[:space:]' < .swift-version)"
# Captured first: `swift --version | head -n 1` under pipefail can fail when
# head exits before swift finishes writing (SIGPIPE).
version="$(swift --version 2>&1)" || true
version="${version%%$'\n'*}"
[[ "$version" =~ Swift\ version\ ${pin//./\\.}( |\.|$) ]] || {
  log "swift on PATH is not $pin: $version"
  exit 1
}

mkdir -p "$HOME/.config"
LOGDIR="$HOME/.cache/rv-cloud-test"
mkdir -p "$LOGDIR"

log "swift ${version#*version } · $(id -un) · umask $(umask) · $ROOT"
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
