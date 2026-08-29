#!/bin/sh
# Install rv (C hook), rv-cli, and rvd into $HOME/.local/bin, then run rv setup.
# Darwin: macOS 26 + arm64. Linux: aarch64 or x86_64. No Windows.
# Tests must set HOME to a temp directory.
# Unset RV_INSTALL_BIN downloads the latest GitHub release trio into a temp
# dir, then uses the same atomic stage+setup path as a local stage.
# TTY download UI matches SetupRenderer: "Downloading" + 24× ━/─ bar, driven by
# real Content-Length weights (and mid-file byte growth while each curl runs).
set -eu

refuse() {
  echo "rv: macOS 26 Apple Silicon, or Linux aarch64/x86_64" >&2
  exit 1
}

os="$(uname -s)"
arch="$(uname -m)"

case "$os" in
  Darwin)
    [ "$arch" = "arm64" ] || refuse
    ver="$(sw_vers -productVersion 2>/dev/null || true)"
    case "$ver" in
      26.*) ;;
      *) refuse ;;
    esac
    ;;
  Linux)
    case "$arch" in
      aarch64|x86_64) ;;
      *) refuse ;;
    esac
    ;;
  *)
    refuse
    ;;
esac

: "${HOME:?HOME is required}"

bin="$HOME/.local/bin"
mkdir -p "$bin"

release_base="https://github.com/christopherkarani/rv/releases/latest/download"
tmp_fetch=""
tmp_rv=""
tmp_cli=""
tmp_rvd=""

# Download progress. Same glyphs/width as Sources/RVTUI/SetupRenderer.swift.
progress_width=24
progress_fd=0
progress_total=0
progress_have=0
progress_base=0
progress_heading=""
progress_muted=""
progress_reset=""

cleanup() {
  [ -n "${tmp_rv:-}" ] && rm -f "$tmp_rv"
  [ -n "${tmp_cli:-}" ] && rm -f "$tmp_cli"
  [ -n "${tmp_rvd:-}" ] && rm -f "$tmp_rvd"
  [ -n "${tmp_fetch:-}" ] && rm -rf "$tmp_fetch"
  :
}
trap cleanup EXIT

bytes_of() {
  if [ -f "$1" ]; then
    wc -c < "$1" | tr -d ' \n'
  else
    printf '0'
  fi
}

content_length() {
  # Last Content-Length after redirects. Empty when unknown / missing.
  curl -fsSIL "$1" 2>/dev/null \
    | tr -d '\r' \
    | awk 'tolower($1) == "content-length:" { print $2 }' \
    | tail -n 1 || true
}

normalize_size() {
  case "$1" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$1" ;;
  esac
}

progress_enable() {
  # curl|sh usually has a TTY on stdout; prefer it. Fall back to stderr.
  if [ -n "${RV_INSTALL_FORCE_PROGRESS:-}" ]; then
    progress_fd=2
  elif [ -t 1 ]; then
    progress_fd=1
  elif [ -t 2 ]; then
    progress_fd=2
  else
    progress_fd=0
    return 0
  fi
  if [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
    progress_heading="$(printf '\033[1;36m')"
    progress_muted="$(printf '\033[2m')"
    progress_reset="$(printf '\033[0m')"
  fi
}

progress_paint_bar() {
  have="$1"
  total="$2"
  if [ "$total" -gt 0 ]; then
    filled=$((have * progress_width / total))
  else
    filled=0
  fi
  if [ "$filled" -gt "$progress_width" ]; then
    filled=$progress_width
  fi
  empty=$((progress_width - filled))
  fill=""
  track=""
  i=0
  while [ "$i" -lt "$filled" ]; do
    fill="${fill}━"
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt "$empty" ]; do
    track="${track}─"
    i=$((i + 1))
  done
  printf '  %s%s%s%s%s\n' \
    "$progress_heading" "$fill" "$progress_reset" \
    "$progress_muted" "$track$progress_reset" >&"$progress_fd"
}

progress_start() {
  progress_enable
  [ "$progress_fd" -ne 0 ] || return 0
  printf '\n  Downloading\n' >&"$progress_fd"
  progress_paint_bar 0 "$progress_total"
}

progress_update() {
  [ "$progress_fd" -ne 0 ] || return 0
  # Rewrite the bar line in place (title stays).
  printf '\033[1A\r\033[2K' >&"$progress_fd"
  progress_paint_bar "$progress_have" "$progress_total"
}

progress_finish() {
  [ "$progress_fd" -ne 0 ] || return 0
  if [ "$progress_total" -gt 0 ]; then
    progress_have=$progress_total
  fi
  progress_update
  printf '  ✓ Download complete\n' >&"$progress_fd"
}

# Download one release asset. Updates the bar from real bytes while curl runs.
download_release_asset() {
  dest="$1"
  name="$2"
  expected="$3"
  url="$release_base/$name"
  out="$dest/$name"

  curl -fsSL "$url" -o "$out" &
  cpid=$!
  while kill -0 "$cpid" 2>/dev/null; do
    got="$(bytes_of "$out")"
    if [ "$expected" -gt 0 ]; then
      if [ "$got" -gt "$expected" ]; then
        got=$expected
      fi
      progress_have=$((progress_base + got))
    else
      progress_have=$((progress_base + got))
      if [ "$progress_have" -gt "$progress_total" ]; then
        progress_total=$progress_have
      fi
    fi
    progress_update
    sleep 0.05
  done
  if ! wait "$cpid"; then
    echo "rv: failed to download $name from $url" >&2
    exit 1
  fi
  got="$(bytes_of "$out")"
  if [ "$expected" -gt 0 ]; then
    progress_base=$((progress_base + expected))
  else
    progress_base=$((progress_base + got))
  fi
  progress_have=$progress_base
  if [ "$progress_have" -gt "$progress_total" ]; then
    progress_total=$progress_have
  fi
  progress_update
}

fetch_pack_bundles() {
  dest="$1"
  expected="$2"
  # GitHub release assets are files. A bare *_RVPacks.bundle file is not a
  # payload: staging only copies a directory. Optional tarball unpacks to
  # $dest/rv_RVPacks.bundle so the existing [ -d ] stage works. 404 is fine.
  name="rv_RVPacks.bundle.tar.gz"
  url="$release_base/$name"
  tarball="$dest/$name"

  if [ "$expected" -gt 0 ]; then
    curl -fsSL "$url" -o "$tarball" &
    cpid=$!
    while kill -0 "$cpid" 2>/dev/null; do
      got="$(bytes_of "$tarball")"
      if [ "$got" -gt "$expected" ]; then
        got=$expected
      fi
      progress_have=$((progress_base + got))
      progress_update
      sleep 0.05
    done
    if ! wait "$cpid"; then
      rm -f "$tarball"
      return 0
    fi
  else
    if ! curl -fsSL "$url" -o "$tarball" 2>/dev/null; then
      rm -f "$tarball"
      return 0
    fi
  fi

  if tar -xzf "$tarball" -C "$dest"; then
    rm -f "$tarball"
    if [ "$expected" -gt 0 ]; then
      progress_base=$((progress_base + expected))
      progress_have=$progress_base
      progress_update
    fi
    return 0
  fi
  rm -f "$tarball"
  echo "rv: failed to unpack $name" >&2
  exit 1
}

if [ -n "${RV_INSTALL_BIN:-}" ]; then
  src="$RV_INSTALL_BIN"
  [ -x "$src/rv" ] && [ -x "$src/rv-cli" ] && [ -x "$src/rvd" ] || {
    echo "rv: RV_INSTALL_BIN must contain executable rv, rv-cli, and rvd" >&2
    exit 1
  }
else
  tmp_fetch="$(mktemp -d "${TMPDIR:-/tmp}/rv-install.XXXXXX")"

  size_rv="$(normalize_size "$(content_length "$release_base/rv")")"
  size_cli="$(normalize_size "$(content_length "$release_base/rv-cli")")"
  size_rvd="$(normalize_size "$(content_length "$release_base/rvd")")"
  size_packs="$(normalize_size "$(content_length "$release_base/rv_RVPacks.bundle.tar.gz")")"

  progress_total=$((size_rv + size_cli + size_rvd + size_packs))
  progress_base=0
  progress_have=0
  progress_start

  download_release_asset "$tmp_fetch" "rv" "$size_rv"
  download_release_asset "$tmp_fetch" "rv-cli" "$size_cli"
  download_release_asset "$tmp_fetch" "rvd" "$size_rvd"
  chmod 755 "$tmp_fetch/rv" "$tmp_fetch/rv-cli" "$tmp_fetch/rvd"
  fetch_pack_bundles "$tmp_fetch" "$size_packs"
  progress_finish

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

# Pack JSON lives next to the binaries (tools/release.sh). Darwin SPM emits
# *_RVPacks.bundle; Linux SPM emits *_RVPacks.resources. Bundle.module loads
# whichever name this platform's accessor baked.
for bundle in "$src"/*_RVPacks.bundle "$src"/*_RVPacks.resources; do
  [ -d "$bundle" ] || continue
  name="$(basename "$bundle")"
  rm -rf "$bin/$name"
  cp -R "$bundle" "$bin/$name"
done

RV_FROM_INSTALL=1 exec "$bin/rv" setup
