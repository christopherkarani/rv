#!/usr/bin/env bash
# tools/install-official-swift-linux.sh — official Swift Linux tarball only.
# Never apt-get install swift / swiftlang. Pin is .swift-version.
# Writes $HOME/.local/share/swift and $HOME/.cache/swift (not the repo).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIN_FILE="$ROOT/.swift-version"
PRINT_BIN=0

usage() {
  cat <<'EOF'
Usage: tools/install-official-swift-linux.sh [--print-bin]

  Install the official Swift RELEASE tarball from download.swift.org for this
  Linux distro/arch. Refuses apt swift. Pin is .swift-version.

  --print-bin   Print the toolchain usr/bin directory on stdout (CI PATH).
                Status, URL, and errors go to stderr.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --print-bin)
      PRINT_BIN=1
      shift
      ;;
    *)
      printf "install-official-swift-linux: unknown option %s\n" "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

log() { printf "install-official-swift-linux: %s\n" "$*" >&2; }

if [[ ! -f "$PIN_FILE" ]]; then
  log "missing .swift-version"
  exit 1
fi
PIN="$(tr -d '[:space:]' <"$PIN_FILE")"
if [[ -z "$PIN" ]]; then
  log "empty .swift-version"
  exit 1
fi

if [[ "$(uname -s)" != "Linux" ]]; then
  log "Linux only (this host is $(uname -s))"
  exit 1
fi

if [[ ! -r /etc/os-release ]]; then
  log "missing /etc/os-release"
  exit 1
fi
# shellcheck disable=SC1091
. /etc/os-release

ARCH="$(uname -m)"
OS_ARCH_SUFFIX=""
case "$ARCH" in
  x86_64) OS_ARCH_SUFFIX="" ;;
  aarch64) OS_ARCH_SUFFIX="-aarch64" ;;
  *)
    log "unsupported arch $ARCH (need x86_64 or aarch64)"
    exit 1
    ;;
esac

case "${ID:-}:${VERSION_ID:-}" in
  ubuntu:24.04) SWIFT_PLATFORM="ubuntu24.04" ;;
  ubuntu:22.04) SWIFT_PLATFORM="ubuntu22.04" ;;
  *)
    log "unsupported ${ID:-unknown} ${VERSION_ID:-unknown}; refuse apt swift"
    exit 1
    ;;
esac

PLATFORM_DIR="$(printf '%s' "$SWIFT_PLATFORM" | tr -d '.')${OS_ARCH_SUFFIX}"
TARBALL="swift-${PIN}-RELEASE-${SWIFT_PLATFORM}${OS_ARCH_SUFFIX}.tar.gz"
URL="https://download.swift.org/swift-${PIN}-release/${PLATFORM_DIR}/swift-${PIN}-RELEASE/${TARBALL}"

DEST="$HOME/.local/share/swift/swift-${PIN}-RELEASE-${SWIFT_PLATFORM}${OS_ARCH_SUFFIX}"
BIN="$DEST/usr/bin"
CACHE_DIR="$HOME/.cache/swift"
TAR_PATH="$CACHE_DIR/$TARBALL"
SIG_PATH="$TAR_PATH.sig"

log "url=$URL"
log "dest=$DEST"

already_ok() {
  [[ -x "$BIN/swift" ]] || return 1
  local ver
  ver="$("$BIN/swift" --version 2>/dev/null | head -n 1 || true)"
  local pin_re
  pin_re="$(printf '%s' "$PIN" | sed 's/\./\\./g')"
  printf '%s\n' "$ver" | grep -Eq "(^|[^0-9])${pin_re}([^0-9]|$)"
}

if already_ok; then
  log "already installed"
  "$BIN/swift" --version >&2 || true
else
  mkdir -p "$CACHE_DIR" "$(dirname "$DEST")"
  if [[ ! -s "$TAR_PATH" ]]; then
    log "downloading $TARBALL"
    curl -fL --retry 5 --retry-delay 4 -o "$TAR_PATH.partial" "$URL"
    mv "$TAR_PATH.partial" "$TAR_PATH"
  else
    log "using cached tarball $TAR_PATH"
  fi
  log "signature=${URL}.sig"
  curl -fL --retry 5 --retry-delay 4 -o "$SIG_PATH" "${URL}.sig"

  GNUPGHOME="$(mktemp -d "${TMPDIR:-/tmp}/swift-gpg.XXXXXX")"
  export GNUPGHOME
  cleanup_gpg() { rm -rf "$GNUPGHOME"; }
  trap cleanup_gpg EXIT
  # swift.org serves the keyring gzip-compressed; without --compressed
  # curl stores 1f 8b … and gpg reports "no valid OpenPGP data found".
  curl -fsSL --compressed "https://www.swift.org/keys/all-keys.asc" \
    | gpg --batch --import
  gpg --batch --verify "$SIG_PATH" "$TAR_PATH"
  trap - EXIT
  cleanup_gpg

  rm -rf "$DEST"
  mkdir -p "$DEST"
  tar -xzf "$TAR_PATH" -C "$DEST" --strip-components=1
  if ! already_ok; then
    log "extract did not produce Swift $PIN at $BIN/swift"
    exit 1
  fi
  "$BIN/swift" --version >&2 || true
fi

if [[ ! -x "$BIN/swift" ]]; then
  log "missing $BIN/swift"
  exit 1
fi

if [[ -n "${GITHUB_PATH:-}" ]]; then
  printf '%s\n' "$BIN" >>"$GITHUB_PATH"
fi

if [[ "$PRINT_BIN" -eq 1 ]]; then
  printf '%s\n' "$BIN"
else
  printf 'url=%s\n' "$URL"
  printf 'dest=%s\n' "$DEST"
  printf 'bin=%s\n' "$BIN"
  "$BIN/swift" --version
fi
