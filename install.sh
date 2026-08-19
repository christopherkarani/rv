#!/bin/sh
# Install rv and rvd into $HOME/.local/bin, then run rv setup.
# macOS 26 + arm64 only. Tests must set HOME to a temp directory.
set -eu

refuse() {
  echo "rv: macOS 26 on Apple Silicon only" >&2
  exit 1
}

os="$(uname -s)"
arch="$(uname -m)"
ver="$(sw_vers -productVersion 2>/dev/null || true)"

[ "$os" = "Darwin" ] || refuse
[ "$arch" = "arm64" ] || refuse
case "$ver" in
  26.*) ;;
  *) refuse ;;
esac

: "${HOME:?HOME is required}"

bin="$HOME/.local/bin"
mkdir -p "$bin"

if [ -z "${RV_INSTALL_BIN:-}" ]; then
  echo "rv: set RV_INSTALL_BIN to a directory that contains rv and rvd" >&2
  exit 1
fi

src="$RV_INSTALL_BIN"
[ -x "$src/rv" ] && [ -x "$src/rvd" ] || {
  echo "rv: RV_INSTALL_BIN must contain executable rv and rvd" >&2
  exit 1
}

# Unlink dest first: BSD cp writes through an existing dest symlink.
rm -f "$bin/rv" "$bin/rvd"
cp "$src/rv" "$bin/rv"
cp "$src/rvd" "$bin/rvd"
chmod 755 "$bin/rv" "$bin/rvd"

exec "$bin/rv" setup
