#!/bin/sh
# Install rv (C hook), rv-cli, and rvd into $HOME/.local/bin, then run rv setup.
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
  echo "rv: set RV_INSTALL_BIN to a directory that contains rv, rv-cli, and rvd" >&2
  exit 1
fi

src="$RV_INSTALL_BIN"
[ -x "$src/rv" ] && [ -x "$src/rv-cli" ] && [ -x "$src/rvd" ] || {
  echo "rv: RV_INSTALL_BIN must contain executable rv, rv-cli, and rvd" >&2
  exit 1
}

# Stage all three copies before touching any destination: a copy failure
# must leave the previous install intact, never a torn trio (new C rv with
# no rv-cli sibling makes doctor unreachable and hooks deny-only).
tmp_rv="$bin/.rv.installing"
tmp_cli="$bin/.rv-cli.installing"
tmp_rvd="$bin/.rvd.installing"
trap 'rm -f "$tmp_rv" "$tmp_cli" "$tmp_rvd"' EXIT
rm -f "$tmp_rv" "$tmp_cli" "$tmp_rvd"
cp "$src/rv" "$tmp_rv"
cp "$src/rv-cli" "$tmp_cli"
cp "$src/rvd" "$tmp_rvd"
chmod 755 "$tmp_rv" "$tmp_cli" "$tmp_rvd"

# Unlink dest first: BSD cp writes through an existing dest symlink. Same
# directory rename after a successful staging is metadata-only.
rm -f "$bin/rv" "$bin/rv-cli" "$bin/rvd"
mv -f "$tmp_rv" "$bin/rv"
mv -f "$tmp_cli" "$bin/rv-cli"
mv -f "$tmp_rvd" "$bin/rvd"

# Pack JSON lives in SPM *_RVPacks.bundle next to the binaries (tools/release.sh).
for bundle in "$src"/*_RVPacks.bundle; do
  [ -d "$bundle" ] || continue
  name="$(basename "$bundle")"
  rm -rf "$bin/$name"
  cp -R "$bundle" "$bin/$name"
done

RV_FROM_INSTALL=1 exec "$bin/rv" setup
