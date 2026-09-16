#!/usr/bin/env bash
# tools/install-official-swift-macos.sh — official Swift RELEASE .pkg for Darwin CI.
# Pin is .swift-version. download.swift.org may name 6.4 as 6.4.0.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIN_FILE="$ROOT/.swift-version"

log() { printf "install-official-swift-macos: %s\n" "$*" >&2; }

if [[ "$(uname -s)" != "Darwin" ]]; then
  log "Darwin only (this host is $(uname -s))"
  exit 1
fi

if [[ ! -f "$PIN_FILE" ]]; then
  log "missing .swift-version"
  exit 1
fi
PIN="$(tr -d '[:space:]' <"$PIN_FILE")"
if [[ -z "$PIN" ]]; then
  log "empty .swift-version"
  exit 1
fi

ARTIFACT_IDS="$PIN"
case "$PIN" in
  *.*.*) ;;
  *.*) ARTIFACT_IDS="$PIN ${PIN}.0" ;;
esac

HOME_TC="$HOME/Library/Developer/Toolchains"
SYS_TC="/Library/Developer/Toolchains"
mkdir -p "$HOME_TC"

have_pin() {
  local dest="$1"
  [[ -x "$dest/usr/bin/swift" ]] || return 1
  local ver pin_re
  ver="$("$dest/usr/bin/swift" --version 2>/dev/null | head -n 1 || true)"
  pin_re="$(printf '%s' "$PIN" | sed 's/\./\\./g')"
  printf '%s\n' "$ver" | grep -Eq "(^|[^0-9])${pin_re}([^0-9]|$)"
}

for id in $ARTIFACT_IDS; do
  dest="$HOME_TC/swift-${id}-RELEASE.xctoolchain"
  if have_pin "$dest"; then
    log "already installed $dest"
    "$dest/usr/bin/swift" --version >&2 || true
    exit 0
  fi
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/swift-macos-pkg.XXXXXX")"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

downloaded=""
for id in $ARTIFACT_IDS; do
  pkg="swift-${id}-RELEASE-osx.pkg"
  url="https://download.swift.org/swift-${id}-release/xcode/swift-${id}-RELEASE/${pkg}"
  log "trying $url"
  if curl -fL --retry 5 --retry-delay 4 -o "$WORKDIR/$pkg" "$url"; then
    downloaded="$WORKDIR/$pkg"
    break
  fi
  rm -f "$WORKDIR/$pkg"
done

if [[ -z "$downloaded" ]]; then
  log "no official osx.pkg for pin $PIN (tried: $ARTIFACT_IDS)"
  exit 1
fi

sudo installer -pkg "$downloaded" -target /

copied=0
for id in $ARTIFACT_IDS; do
  sys="$SYS_TC/swift-${id}-RELEASE.xctoolchain"
  dest="$HOME_TC/swift-${id}-RELEASE.xctoolchain"
  if [[ -x "$sys/usr/bin/swift" ]]; then
    rm -rf "$dest"
    cp -R "$sys" "$dest"
    copied=1
  fi
done

for id in $ARTIFACT_IDS; do
  dest="$HOME_TC/swift-${id}-RELEASE.xctoolchain"
  if have_pin "$dest"; then
    log "installed $dest"
    "$dest/usr/bin/swift" --version >&2 || true
    exit 0
  fi
done

if [[ "$copied" -eq 0 ]]; then
  log "installer did not produce a home toolchain for pin $PIN"
fi
exit 1
