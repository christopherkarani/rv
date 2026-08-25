#!/bin/sh
# Install rv (C hook), rv-cli, and rvd into $HOME/.local/bin, then run rv setup.
# macOS 26 + arm64 only. Tests must set HOME to a temp directory.
# Unset RV_INSTALL_BIN downloads the latest GitHub release trio into a temp
# dir, then uses the same atomic stage+setup path as a local stage.
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

release_base="https://github.com/christopherkarani/rv/releases/latest/download"
tmp_fetch=""
tmp_rv=""
tmp_cli=""
tmp_rvd=""

cleanup() {
  [ -n "${tmp_rv:-}" ] && rm -f "$tmp_rv"
  [ -n "${tmp_cli:-}" ] && rm -f "$tmp_cli"
  [ -n "${tmp_rvd:-}" ] && rm -f "$tmp_rvd"
  [ -n "${tmp_fetch:-}" ] && rm -rf "$tmp_fetch"
  :
}
trap cleanup EXIT

download_release_asset() {
  dest="$1"
  name="$2"
  url="$release_base/$name"
  curl -fSL "$url" -o "$dest/$name" || {
    echo "rv: failed to download $name from $url" >&2
    exit 1
  }
}

fetch_pack_bundles() {
  dest="$1"
  api="https://api.github.com/repos/christopherkarani/rv/releases/latest"
  json="$(curl -fSL "$api" 2>/dev/null || true)"
  names=""
  if [ -n "$json" ]; then
    names="$(printf '%s\n' "$json" | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*_RVPacks\.bundle\)".*/\1/p')"
  fi
  if [ -n "$names" ]; then
    printf '%s\n' "$names" > "$dest/.pack-bundle-names"
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      download_release_asset "$dest" "$name"
    done < "$dest/.pack-bundle-names"
    rm -f "$dest/.pack-bundle-names"
    return 0
  fi
  # Not listed (or API unavailable): probe the SPM bundle name. 404 is fine.
  if curl -fSL "$release_base/rv_RVPacks.bundle" -o "$dest/rv_RVPacks.bundle" 2>/dev/null; then
    return 0
  fi
  rm -f "$dest/rv_RVPacks.bundle"
}

if [ -n "${RV_INSTALL_BIN:-}" ]; then
  src="$RV_INSTALL_BIN"
  [ -x "$src/rv" ] && [ -x "$src/rv-cli" ] && [ -x "$src/rvd" ] || {
    echo "rv: RV_INSTALL_BIN must contain executable rv, rv-cli, and rvd" >&2
    exit 1
  }
else
  tmp_fetch="$(mktemp -d "${TMPDIR:-/tmp}/rv-install.XXXXXX")"
  download_release_asset "$tmp_fetch" "rv"
  download_release_asset "$tmp_fetch" "rv-cli"
  download_release_asset "$tmp_fetch" "rvd"
  chmod 755 "$tmp_fetch/rv" "$tmp_fetch/rv-cli" "$tmp_fetch/rvd"
  fetch_pack_bundles "$tmp_fetch"
  src="$tmp_fetch"
  [ -x "$src/rv" ] && [ -x "$src/rv-cli" ] && [ -x "$src/rvd" ] || {
    echo "rv: download did not produce executable rv, rv-cli, and rvd" >&2
    exit 1
  }
fi

# Stage all three copies before touching any destination: a copy failure
# must leave the previous install intact, never a torn trio (new C rv with
# no rv-cli sibling makes doctor unreachable and hooks deny-only).
tmp_rv="$bin/.rv.installing"
tmp_cli="$bin/.rv-cli.installing"
tmp_rvd="$bin/.rvd.installing"
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
tmp_rv=""
tmp_cli=""
tmp_rvd=""

# Pack JSON lives in SPM *_RVPacks.bundle next to the binaries (tools/release.sh).
for bundle in "$src"/*_RVPacks.bundle; do
  [ -d "$bundle" ] || continue
  name="$(basename "$bundle")"
  rm -rf "$bin/$name"
  cp -R "$bundle" "$bin/$name"
done

RV_FROM_INSTALL=1 exec "$bin/rv" setup
