#!/bin/sh
# Install rv (C hook), rv-cli, and rvd into $HOME/.local/bin, then run rv setup.
# Darwin: macOS 15 or newer + arm64. Linux: aarch64 or x86_64. No Windows.
# Tests must set HOME to a temp directory.
# Unset RV_INSTALL_BIN downloads a GitHub release into a temp dir, then uses
# the same atomic stage+setup path as a local stage. The release tag is
# resolved once (RV_INSTALL_VERSION pins it, otherwise the /releases/latest
# redirect) and every asset, SHA256SUMS included, comes from that tag. Every
# downloaded asset is checked against SHA256SUMS on all OSes before anything
# is unpacked or staged; RV_INSTALL_SKIP_CHECKSUMS=1 skips that (loudly).
# Downloaded macOS files are signature-checked before anything is staged. A
# file counts as signed only with a valid, notarized Developer ID signature
# from the pinned team. Ad-hoc and missing signatures, and Developer ID
# signatures while no team is pinned, only warn until signed_releases=1
# below. A mix of signed and unsigned never installs.
# TTY download UI matches SetupRenderer: "Downloading" + 24× ━/─ bar, driven by
# real Content-Length weights (and mid-file byte growth while each curl runs).
# RV_INSTALL_MODE picks the guard mode setup starts in: unset or `enforce`
# runs plain `rv setup` (which never changes an existing guard.mode);
# `observe` runs `rv setup --observe` (log what rv would
# block; while rvd runs, only rv's own self-protection still blocks). Any other value is
# refused before anything is downloaded or staged.
set -eu

case "${RV_INSTALL_MODE:-}" in
  ''|enforce|observe) ;;
  *)
    echo "rv: RV_INSTALL_MODE must be observe or enforce (got: $RV_INSTALL_MODE)" >&2
    exit 1
    ;;
esac

refuse() {
  echo "rv: macOS 15 Apple Silicon, or Linux aarch64/x86_64" >&2
  exit 1
}

os="$(uname -s)"
arch="$(uname -m)"

case "$os" in
  Darwin)
    [ "$arch" = "arm64" ] || refuse
    ver="$(sw_vers -productVersion 2>/dev/null || true)"
    major="${ver%%.*}"
    case "$major" in
      ''|*[!0-9]*) refuse ;;
    esac
    [ "$major" -ge 15 ] || refuse
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

release_repo="https://github.com/christopherkarani/rv/releases"
# Set by resolve_release_tag: $release_repo/download/<tag>.
release_base=""
sums_file=""
# Laya judge weights (Hugging Face). macOS curl installs fetch these into
# ~/.config/rv/models/laya-ft-v2-coreml so the judge binds on first run;
# Linux skips (no ONNX runtime yet — an ONNX-only dir would read as
# packs-only). Pinned by Scripts/laya/hf-upload.py; the same pins live in
# Scripts/laya/distribution-manifest.json (InstallScriptTests check they
# match). Override only via the env vars below, and update the manifest in
# the same commit.
models_hf_repo="${MODELS_HF_REPO:-karc14/rv-laya-ft-v2-coreml}"
models_hf_rev="${MODELS_HF_REVISION:-a71b1ce7cba9e795334ec60017a23c6488171ce8}"
models_bundle="laya-ft-v2-coreml"
# path, sha256, bytes — must match the manifest's ft engine files.
models_files="model.mlpackage/Manifest.json 3c713c254fee9e6914355e82f4c3e9adc4dbca667a956b284d38f5a18393a1d5 617
model.mlpackage/Data/com.apple.CoreML/model.mlmodel fd60b8928154754362d660163a4a15e203337ae4cb2ccf98b461233db366bce4 356877
model.mlpackage/Data/com.apple.CoreML/weights/weight.bin 5abb590e28cef8c312b3afc2f28046f186f1127893989bda6a880f352261377b 613899008
tokenizer.json 609d8f4c067cd3950f88594c5a802616cea245823836ef5848ee4fc40aab5b6f 34363188
config.json c0099d659944d44cb3d711b55c25482819f2e8f5e17f2d0b37d6d7cb1b22aba5 423"
# Release assets carry a per-target suffix (rv-linux-x86_64 and friends);
# downloaded files are always staged under their plain names.
case "$os/$arch" in
  Darwin/arm64) target="darwin-arm64" ;;
  Linux/aarch64) target="linux-aarch64" ;;
  Linux/x86_64) target="linux-x86_64" ;;
  *) refuse ;;
esac
# Flip to 1 and pin the Team ID once releases are Developer ID signed: from
# then on an unsigned download is refused unless RV_INSTALL_ALLOW_UNSIGNED=1.
signed_releases=0
release_team_id=""
tmp_fetch=""
tmp_rv=""
tmp_cli=""
tmp_rvd=""
tmp_host=""
tmp_span=""
tmp_isolation=""
tmp_models=""

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
  [ -n "${tmp_host:-}" ] && rm -f "$tmp_host"
  [ -n "${tmp_span:-}" ] && rm -f "$tmp_span"
  [ -n "${tmp_isolation:-}" ] && rm -f "$tmp_isolation"
  [ -n "${tmp_models:-}" ] && rm -rf "$tmp_models"
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
# $4 is the local filename when the asset name carries a target suffix.
download_release_asset() {
  dest="$1"
  name="$2"
  expected="$3"
  local_name="${4:-$name}"
  url="$release_base/$name"
  out="$dest/$local_name"

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
  verify_checksum "$name" "$out"
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

# Resolve the release tag exactly once so a download racing a new release
# cannot mix assets from two versions.
resolve_release_tag() {
  tag="${RV_INSTALL_VERSION:-}"
  if [ -z "$tag" ]; then
    final="$(curl -fsSIL -o /dev/null -w '%{url_effective}' "$release_repo/latest" 2>/dev/null)" || final=""
    tag="${final##*/releases/tag/}"
    [ "$tag" != "$final" ] || tag=""
  fi
  case "$tag" in
    ''|*[!A-Za-z0-9._-]*)
      echo "rv: failed to download: could not resolve a release tag (set RV_INSTALL_VERSION to pin one)" >&2
      exit 1
      ;;
  esac
  release_base="$release_repo/download/$tag"
}

# Hash via stdin: with a path argument, sha256sum / shasum prefix the digest
# with `\` when the path holds a newline or backslash (e.g. an odd TMPDIR).
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum < "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 < "$1" | awk '{print $1}'
  else
    return 1
  fi
}

# Download SHA256SUMS from the resolved tag. Fails closed: no checksum tool,
# or no SHA256SUMS, means no install.
fetch_checksums() {
  if [ "${RV_INSTALL_SKIP_CHECKSUMS:-}" = "1" ]; then
    echo "rv: WARNING: RV_INSTALL_SKIP_CHECKSUMS=1 set; downloaded files are NOT verified against SHA256SUMS" >&2
    return 0
  fi
  sha256_of /dev/null >/dev/null 2>&1 || {
    echo "rv: refusing to install: neither sha256sum nor shasum is available to verify the download" >&2
    exit 1
  }
  sums_file="$tmp_fetch/SHA256SUMS"
  if ! curl -fsSL "$release_base/SHA256SUMS" -o "$sums_file"; then
    echo "rv: refusing to install: failed to download $release_base/SHA256SUMS" >&2
    exit 1
  fi
}

# Check one downloaded asset ($1 release name, $2 local path) against
# SHA256SUMS. A missing entry is as fatal as a mismatch.
verify_checksum() {
  [ -n "$sums_file" ] || return 0
  want="$(awk -v n="$1" '$2 == n || $2 == "*" n { print tolower($1); exit }' "$sums_file")"
  if [ -z "$want" ]; then
    echo "rv: refusing to install: SHA256SUMS has no entry for $1" >&2
    exit 1
  fi
  have="$(sha256_of "$2")" || have=""
  if [ "$have" != "$want" ]; then
    echo "rv: refusing to install: checksum mismatch for $1 (expected $want, got $have)" >&2
    exit 1
  fi
}

fetch_pack_bundles() {
  dest="$1"
  expected="$2"
  # GitHub release assets are files. A bare *_RVPacks.bundle file is not a
  # payload: staging only copies a directory. Optional tarball unpacks to
  # $dest/rv_RVPacks.bundle so the existing [ -d ] stage works. 404 is fine.
  name="rv_RVPacks-$target.tar.gz"
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

  verify_checksum "$name" "$tarball"

  # Unpack into a scratch dir, never straight over $dest: the tarball is
  # not signature-checked, and an entry named like a binary must not
  # overwrite the verified downloads beside it. Only pack bundle
  # directories are promoted into $dest.
  unpack="$dest/.packs-unpack"
  rm -rf "$unpack"
  mkdir -p "$unpack"
  if tar -xzf "$tarball" -C "$unpack"; then
    rm -f "$tarball"
    for bundle in "$unpack"/*_RVPacks.bundle "$unpack"/*_RVPacks.resources; do
      [ -d "$bundle" ] && [ ! -L "$bundle" ] || continue
      promoted="$(basename "$bundle")"
      rm -rf "$dest/$promoted"
      mv "$bundle" "$dest/$promoted"
    done
    rm -rf "$unpack"
    if [ "$expected" -gt 0 ]; then
      progress_base=$((progress_base + expected))
      progress_have=$progress_base
      progress_update
    fi
    return 0
  fi
  rm -rf "$unpack"
  rm -f "$tarball"
  echo "rv: failed to unpack $name" >&2
  exit 1
}

# Linux Swift runtime libraries. The release binaries link the toolchain
# dynamically, and curl-install machines have no toolchain, so the release
# ships the loader closure as a tarball. Required: without these libraries
# nothing runs. Only top-level regular .so files stage; symlinks and other
# names stay in the scratch dir.
fetch_swift_libs() {
  dest="$1"
  expected="$2"
  name="rv-swiftlibs-$target.tar.gz"
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
      echo "rv: failed to download $name from $url" >&2
      exit 1
    fi
  else
    if ! curl -fsSL "$url" -o "$tarball" 2>/dev/null; then
      echo "rv: failed to download $name from $url" >&2
      exit 1
    fi
  fi

  verify_checksum "$name" "$tarball"

  unpack="$dest/.swiftlibs-unpack"
  rm -rf "$unpack"
  mkdir -p "$unpack"
  if tar -xzf "$tarball" -C "$unpack"; then
    rm -f "$tarball"
    promoted=0
    for lib in "$unpack"/*.so; do
      [ -f "$lib" ] && [ ! -L "$lib" ] || continue
      cp "$lib" "$dest/$(basename "$lib")"
      promoted=$((promoted + 1))
    done
    rm -rf "$unpack"
    if [ "$promoted" -eq 0 ]; then
      echo "rv: $name contained no shared libraries" >&2
      exit 1
    fi
    if [ "$expected" -gt 0 ]; then
      progress_base=$((progress_base + expected))
      progress_have=$progress_base
      progress_update
    fi
    return 0
  fi
  rm -rf "$unpack"
  rm -f "$tarball"
  echo "rv: failed to unpack $name" >&2
  exit 1
}

# Best-effort judge weights for macOS curl installs. Never fails the
# install: any error warns on stderr and the guard runs packs-only.
# Skipped for local stages (RV_INSTALL_BIN: tests/offline), with
# RV_INSTALL_NO_MODELS=1, and when a bundle is already installed.
fetch_model_bundle() {
  [ "$os" = "Darwin" ] || return 0
  [ -z "${RV_INSTALL_BIN:-}" ] || return 0
  [ "${RV_INSTALL_NO_MODELS:-}" != "1" ] || return 0
  dest="$HOME/.config/rv/models/$models_bundle"
  # A partial bundle does not count: JudgeRuntime.ftBundleDir requires the
  # model AND the tokenizer, so re-running the installer must repair a
  # partial bundle instead of skipping it.
  if [ -d "$dest/model.mlpackage" ] && { [ -f "$dest/tokenizer.json" ] || [ -f "$dest/tokenizer/tokenizer.json" ]; }; then
    return 0
  fi
  command -v shasum >/dev/null 2>&1 || { echo "rv: warning: shasum missing; skipping judge weights" >&2; return 0; }
  tmp_models="$(mktemp -d "${TMPDIR:-/tmp}/rv-models.XXXXXX")" || return 0
  while read -r rel _bytes; do
    [ -n "$rel" ] || continue
    out="$tmp_models/$rel"
    mkdir -p "$(dirname "$out")"
    url="https://huggingface.co/$models_hf_repo/resolve/$models_hf_rev/$rel"
    curl -fsSL --connect-timeout 15 --speed-limit 1000 --speed-time 60 "$url" -o "$out" &
    cpid=$!
    while kill -0 "$cpid" 2>/dev/null; do
      got="$(bytes_of "$out")"
      progress_have=$((progress_base + got))
      if [ "$progress_have" -gt "$progress_total" ]; then
        progress_total=$progress_have
      fi
      progress_update
      sleep 0.05
    done
    if ! wait "$cpid"; then
      echo "rv: warning: failed to download judge weights ($rel); continuing packs-only" >&2
      rm -rf "$tmp_models"
      tmp_models=""
      return 0
    fi
    progress_base=$((progress_base + $(bytes_of "$out")))
    progress_have=$progress_base
    progress_update
  done <<EOF
$(printf '%s\n' "$models_files" | awk '{print $1, $3}')
EOF
  total=0
  while read -r rel want_hash want_bytes; do
    [ -n "$rel" ] || continue
    got_hash="$(shasum -a 256 "$tmp_models/$rel" | awk '{print $1}')"
    got_bytes="$(bytes_of "$tmp_models/$rel")"
    if [ "$got_hash" != "$want_hash" ] || [ "$got_bytes" != "$want_bytes" ]; then
      echo "rv: warning: judge weights failed verification ($rel); continuing packs-only" >&2
      rm -rf "$tmp_models"
      tmp_models=""
      return 0
    fi
    total=$((total + got_bytes))
  done <<EOF
$models_files
EOF
  mkdir -p "$HOME/.config/rv/models" || { echo "rv: warning: could not create models dir; continuing packs-only" >&2; rm -rf "$tmp_models"; tmp_models=""; return 0; }
  rm -rf "$dest"
  if ! mv "$tmp_models" "$dest"; then
    echo "rv: warning: could not install judge weights; continuing packs-only" >&2
    rm -rf "$tmp_models" "$dest"
    tmp_models=""
    return 0
  fi
  tmp_models=""
  echo "rv: judge weights $models_hf_repo @ $(printf '%s' "$models_hf_rev" | cut -c1-12) installed ($total bytes)" >&2
}

# The last physical line whose text starts with $2. A newline inside
# Identifier=, Executable=, or a path is its own line, so an earlier
# injected TeamIdentifier= is not the signature's team.
last_field_prefix() {
  details=$1
  prefix=$2
  found=
  rest=$details
  while [ -n "$rest" ]; do
    case "$rest" in
      *"
"*)
        line=${rest%%
*}
        rest=${rest#*
}
        ;;
      *)
        line=$rest
        rest=
        ;;
    esac
    case "$line" in
      "$prefix"*) found=$line ;;
    esac
  done
  printf '%s' "$found"
}

# A real spctl verdict is the assessed path, the exact path passed to spctl,
# followed by ": accepted" or ": rejected". A certificate continuation that
# contains "/" and ends in ": accepted" is not a verdict, and neither is a
# bare ": accepted" or ": rejected (the code is valid...)". The source is the
# first source= line after the last real verdict. A later source= does not
# replace it, and a source= before that verdict is dropped.
source_after_verdict() {
  details=$1
  path=$2
  found=
  armed=
  took=
  rest=$details
  while [ -n "$rest" ]; do
    case "$rest" in
      *"
"*)
        line=${rest%%
*}
        rest=${rest#*
}
        ;;
      *)
        line=$rest
        rest=
        ;;
    esac
    if [ "$line" = "$path: accepted" ]; then
      armed=1
      found=
      took=
    else
      case "$line" in
        source=*)
          if [ -n "$armed" ] && [ -z "$took" ]; then
            found=$line
            took=1
          fi
          ;;
      esac
    fi
  done
  printf '%s' "$found"
}

# Prints "real" when a Developer ID Application authority is a certificate
# line, and "injected" when that line is still inside Identifier= or continues
# an earlier authority value. A newline inside the identifier must not become
# a trusted Authority line. Only the last Format= line ends the identifier.
# That includes Format=generic and Format=disk image, not only Mach-O and
# bundle formats. A planted Format=Mach-O before the real Format line does
# not end the span. Bare Format= ends it only when it is the last Format=
# line. CodeDirectory, Signature size=, TeamIdentifier=, and Timestamp= do
# not. A later Authority= line continues the previous authority value; it is
# not a new certificate.
classify_authorities() {
  details=$1
  needle="Authority=Developer ID Application:"
  format_count=0
  rest=$details
  while [ -n "$rest" ]; do
    case "$rest" in
      *"
"*)
        line=${rest%%
*}
        rest=${rest#*
}
        ;;
      *)
        line=$rest
        rest=
        ;;
    esac
    case "$line" in
      Format=*)
        format_count=$((format_count + 1))
        ;;
    esac
  done
  in_identifier=
  seen_authority=
  real=
  injected=
  rest=$details
  while [ -n "$rest" ]; do
    case "$rest" in
      *"
"*)
        line=${rest%%
*}
        rest=${rest#*
}
        ;;
      *)
        line=$rest
        rest=
        ;;
    esac
    case "$line" in
      Identifier=*)
        in_identifier=1
        ;;
      Format=*)
        format_count=$((format_count - 1))
        if [ "$format_count" -eq 0 ]; then
          in_identifier=
        fi
        ;;
      Authority=*)
        case "$line" in
          "$needle"*)
            if [ -n "$in_identifier" ] || [ -n "$seen_authority" ]; then
              injected=1
            else
              real=1
            fi
            ;;
        esac
        seen_authority=1
        ;;
    esac
  done
  printf '%s%s' "${real:+real}" "${injected:+ injected}"
}

# 0 when the Authority phrase appears on a line that does not start with it.
# That line is the leaf name (Identifier= or Executable=), not the certificate.
phrase_outside_authority() {
  details=$1
  needle="Authority=Developer ID Application:"
  rest=$details
  while [ -n "$rest" ]; do
    case "$rest" in
      *"
"*)
        line=${rest%%
*}
        rest=${rest#*
}
        ;;
      *)
        line=$rest
        rest=
        ;;
    esac
    case "$line" in
      "$needle"*) ;;
      *"$needle"*) return 0 ;;
    esac
  done
  return 1
}

# A downloaded macOS release file counts as signed only with a valid,
# notarized Developer ID signature from the pinned team. A broken signature
# or a pinned team that does not match always refuses, including
# libswiftCompatibilitySpan.dylib. Ad-hoc signatures, missing signatures,
# and Developer ID signatures while no team is pinned all take the unsigned
# path: warn until signed_releases=1, then refuse unless
# RV_INSTALL_ALLOW_UNSIGNED=1. A mix of signed and unsigned never installs.
verify_release_signatures() {
  dir="$1"
  shift
  # The pin comes only from this script. An environment override would let
  # whatever ran `curl | sh` (direnv, CI, a wrapper) silently re-pin trust.
  team="$release_team_id"
  # Absolute paths. A codesign earlier on PATH must not decide this check.
  codesign=/usr/bin/codesign
  spctl=/usr/sbin/spctl
  if [ ! -x "$codesign" ]; then
    echo "rv: refusing to install: codesign is not available, so a Developer ID signature cannot be checked" >&2
    exit 1
  fi
  signed=""
  unsigned=""
  for name in "$@"; do
    file="$dir/$name"
    [ -f "$file" ] || [ -d "$file" ] || continue
    # A newline in the path is a new line in codesign and spctl output.
    # Refuse before trusting any field, and name only the basename.
    case "$file" in
      *"
"*)
        echo "rv: refusing to install: $name is not a single path, so its signature cannot be checked" >&2
        exit 1
        ;;
    esac
    details="$("$codesign" -dvv "$file" 2>&1 || true)"
    # "not signed at all" inside Identifier, TMPDIR, or Executable= is not an
    # unsigned file. Only the unsigned diagnostic, and only when no Developer
    # ID authority is present, may take the unsigned warning.
    case "$details" in
      *"Authority=Developer ID Application:"*) ;;
      *"code object is not signed at all"*)
        unsigned="$unsigned $name"
        continue
        ;;
    esac
    case "$name" in
      *.app) verify_flags="--verify --deep --strict" ;;
      *) verify_flags="--verify --strict" ;;
    esac
    # shellcheck disable=SC2086 # verify_flags is a fixed two-word flag set
    if ! "$codesign" $verify_flags "$file" >/dev/null 2>&1; then
      echo "rv: refusing to install: $name has an invalid code signature" >&2
      exit 1
    fi
    # No Developer ID authority above, and the signature verifies, so an
    # ad-hoc file is unsigned for trust purposes: ad-hoc is self-asserted,
    # and refusing it while warning on truly-unsigned files would only push
    # an attacker to strip the signature. The signed_releases switch below
    # governs both. An Authority line keeps the strict path even beside
    # ad-hoc markers: that combination is a forged-injection shape, not a
    # plain ad-hoc file.
    case "$details" in
      *"Authority=Developer ID Application:"*) ;;
      *"Signature=adhoc"*|*"TeamIdentifier=not set"*)
        unsigned="$unsigned $name"
        continue
        ;;
    esac
    # A Developer ID certificate is an Authority line outside Identifier=.
    # The same text in the leaf name, or on a line a newline inside
    # Identifier= created, is not that certificate.
    kinds=$(classify_authorities "$details")
    real_authority=0
    injected_authority=0
    case "$kinds" in
      *real*) real_authority=1 ;;
    esac
    case "$kinds" in
      *injected*) injected_authority=1 ;;
    esac
    leaf_phrase=0
    case "$name" in
      *"Authority=Developer ID Application:"*) leaf_phrase=1 ;;
    esac
    if phrase_outside_authority "$details"; then
      leaf_phrase=1
    fi
    if [ "$injected_authority" = 1 ]; then
      leaf_phrase=1
    fi
    if [ "$real_authority" != 1 ] && [ "$leaf_phrase" != 1 ]; then
      echo "rv: refusing to install: $name is not signed with a Developer ID Application certificate" >&2
      exit 1
    fi
    # No pin yet: a Developer ID file the release cannot attribute (today the
    # Swift toolchain dylib, still carrying its own team's signature) is
    # unsigned for trust purposes. It warns until signed_releases=1, which
    # refuses; pinning the team moves attributed files to the signed path.
    # A pinned team that does not match still refuses below.
    if [ -z "$team" ]; then
      unsigned="$unsigned $name"
      continue
    fi
    team_line=$(last_field_prefix "$details" "TeamIdentifier=")
    sig_line=$(last_field_prefix "$details" "Signature=")
    # A Developer ID dylib is not passed to spctl. Ad-hoc is, including a
    # dylib: Signature=adhoc or TeamIdentifier=not set must not skip it.
    # "Signature=" does not match "Signature size=". A leaf name that
    # contains the Authority phrase is not that certificate, so the dylib
    # still goes through spctl.
    need_spctl=1
    case "$name" in
      *.dylib) need_spctl=0 ;;
    esac
    if [ "$sig_line" = "Signature=adhoc" ] || [ "$team_line" = "TeamIdentifier=not set" ]; then
      need_spctl=1
    fi
    if [ "$leaf_phrase" = 1 ]; then
      need_spctl=1
    fi
    if [ "$need_spctl" = 1 ]; then
      # Gatekeeper's exit status is part of the verdict: a rejected binary
      # whose output still names a Notarized source must not install.
      if verdict="$("$spctl" -a -t open --context context:primary-signature -vv "$file" 2>&1)"; then
        :
      else
        echo "rv: refusing to install: Gatekeeper does not accept $name as notarized" >&2
        exit 1
      fi
      source_line=$(source_after_verdict "$verdict" "$file")
      if [ "$source_line" != "source=Notarized Developer ID" ]; then
        echo "rv: refusing to install: Gatekeeper does not accept $name as notarized" >&2
        exit 1
      fi
    fi
    if [ "$team_line" != "TeamIdentifier=$team" ]; then
      echo "rv: refusing to install: $name is not signed by team $team" >&2
      exit 1
    fi
    signed="$signed $name"
  done
  if [ -n "$signed" ] && [ -n "$unsigned" ]; then
    echo "rv: refusing to install: some release files are signed and some are not:$unsigned" >&2
    exit 1
  fi
  [ -n "$unsigned" ] || return 0
  if [ "$signed_releases" = "1" ] && [ "${RV_INSTALL_ALLOW_UNSIGNED:-}" != "1" ]; then
    echo "rv: refusing to install unsigned release files:$unsigned" >&2
    echo "rv: set RV_INSTALL_ALLOW_UNSIGNED=1 to install them anyway" >&2
    exit 1
  fi
  echo "rv: warning: release files are not code-signed:$unsigned" >&2
}

# An admin trust manifest makes hooks trust only the rvd it names; any other
# rvd is denied on every agent tool call. An rvd under ~/.local/bin can only
# meet a manifest's production entry (Developer ID, team, hardened runtime;
# development pins need a root-owned path), so a staged rvd lacking those
# can never be trusted: refuse before staging. This is the necessary
# condition only; rv setup then applies the exact rule. The path override
# exists for tests (as HOME does) and can only skip this check, never add
# trust: hooks always read the fixed path.
trust_manifest="${RV_INSTALL_TRUST_MANIFEST:-/Library/Application Support/RV/peer-trust.json}"
if [ -n "${RV_INSTALL_TRUST_MANIFEST+set}" ]; then
  echo "rv: WARNING: RV_INSTALL_TRUST_MANIFEST is set: the trust-manifest check uses test override path $trust_manifest, not the path hooks read" >&2
fi

# present | absent | unknown:<reason>. Mirrors C trust_source: only a
# missing path (ENOENT) is "no manifest"; anything that hides the answer
# (an unsearchable or non-directory ancestor) is an invalid manifest there.
trust_manifest_state() {
  if [ -e "$1" ] || [ -L "$1" ]; then
    echo present
    return 0
  fi
  dir=$(dirname "$1")
  while :; do
    if [ -d "$dir" ]; then
      if [ -x "$dir" ]; then echo absent; else echo "unknown:$dir is not searchable"; fi
      return 0
    fi
    if [ -e "$dir" ] || [ -L "$dir" ]; then
      echo "unknown:$dir is not a directory"
      return 0
    fi
    [ "$dir" != "/" ] || { echo absent; return 0; }
    dir=$(dirname "$dir")
  done
}

# The manifest's service-entry value for key $2, or nothing.
manifest_service_field() {
  plutil=/usr/bin/plutil
  [ -x "$plutil" ] || return 0
  i=0
  while [ "$i" -lt 32 ]; do
    role="$("$plutil" -extract "$i.role" raw -o - "$1" 2>/dev/null)" || return 0
    if [ "$role" = "service" ]; then
      "$plutil" -extract "$i.$2" raw -o - "$1" 2>/dev/null || true
      return 0
    fi
    i=$((i + 1))
  done
}

# Why rvd $1 can never satisfy a trust manifest, or nothing.
staged_rvd_trust_gap() {
  codesign=/usr/bin/codesign
  if [ ! -x "$codesign" ]; then
    echo "cannot be checked (codesign is not available)"
    return 0
  fi
  details="$("$codesign" -dvv "$1" 2>&1 || true)"
  case "$details" in
    *"code object is not signed at all"*) echo "is not code-signed"; return 0 ;;
  esac
  if ! "$codesign" --verify --strict "$1" >/dev/null 2>&1; then
    echo "has an invalid code signature"
    return 0
  fi
  case "$details" in
    *"Signature=adhoc"*) echo "is ad-hoc signed"; return 0 ;;
    *"TeamIdentifier=not set"*) echo "has no team identifier"; return 0 ;;
  esac
  case "$(last_field_prefix "$details" "CodeDirectory ")" in
    *runtime*) ;;
    *) echo "lacks hardened runtime" ;;
  esac
}

refuse_untrusted_rvd_under_manifest() {
  [ "$os" = "Darwin" ] || return 0
  state="$(trust_manifest_state "$trust_manifest")"
  case "$state" in
    absent) return 0 ;;
    unknown:*)
      echo "rv: refusing to install: cannot tell whether trust manifest $trust_manifest exists (${state#unknown:})" >&2
      echo "rv: hooks treat that as an invalid manifest and would deny every agent tool call" >&2
      echo "rv: fix: make that directory searchable, or remove the manifest directory with sudo" >&2
      exit 1
      ;;
  esac
  gap="$(staged_rvd_trust_gap "$1/rvd")"
  [ -n "$gap" ] || return 0
  want_id="$(manifest_service_field "$trust_manifest" requiredIdentifier)"
  want_team="$(manifest_service_field "$trust_manifest" requiredTeamIdentifier)"
  if [ -n "$want_id" ] && [ -n "$want_team" ]; then
    requires="requires Developer ID $want_id (team $want_team)"
  else
    requires="requires a Developer ID signed rvd"
  fi
  if [ "${RV_INSTALL_ALLOW_UNSIGNED:-}" = "1" ]; then
    echo "rv: WARNING: trust manifest $trust_manifest $requires; staged rvd $gap" >&2
    echo "rv: WARNING: RV_INSTALL_ALLOW_UNSIGNED=1, staging it anyway; rv setup will refuse to wire hooks to it" >&2
    return 0
  fi
  echo "rv: refusing to install: trust manifest $trust_manifest $requires; staged rvd $gap" >&2
  echo "rv: hooks fail closed on an rvd the manifest does not trust, so hooks would deny every agent tool call" >&2
  echo "rv: fix: sign the build (RV_RELEASE_SIGN=1 Scripts/release.sh), or remove the manifest: sudo rm '$trust_manifest'" >&2
  echo "rv: set RV_INSTALL_ALLOW_UNSIGNED=1 to stage it anyway (rv setup will still refuse to wire hooks)" >&2
  exit 1
}

if [ -n "${RV_INSTALL_BIN:-}" ]; then
  src="$RV_INSTALL_BIN"
  [ -x "$src/rv" ] && [ -x "$src/rv-cli" ] && [ -x "$src/rvd" ] && [ -x "$src/rv-workspace-host" ] || {
    echo "rv: RV_INSTALL_BIN must contain executable rv, rv-cli, rvd, and rv-workspace-host" >&2
    exit 1
  }
else
  tmp_fetch="$(mktemp -d "${TMPDIR:-/tmp}/rv-install.XXXXXX")"
  resolve_release_tag
  fetch_checksums

  size_rv="$(normalize_size "$(content_length "$release_base/rv-$target")")"
  size_cli="$(normalize_size "$(content_length "$release_base/rv-cli-$target")")"
  size_rvd="$(normalize_size "$(content_length "$release_base/rvd-$target")")"
  size_host="$(normalize_size "$(content_length "$release_base/rv-workspace-host-$target")")"
  size_packs="$(normalize_size "$(content_length "$release_base/rv_RVPacks-$target.tar.gz")")"
  size_span=0
  size_claim=0
  size_microvm=0
  size_relay=0
  size_macvm=0
  size_macvm_agent=0
  size_approvals=0
  if [ "$os" = "Darwin" ]; then
    size_span="$(normalize_size "$(content_length "$release_base/libswiftCompatibilitySpan.dylib")")"
    size_claim="$(normalize_size "$(content_length "$release_base/rv-pty-claim-$target")")"
    # Micro-VM backend (`rv workspace run --microvm`). Older releases omit it.
    size_microvm="$(normalize_size "$(content_length "$release_base/rv-microvm-$target")")"
    size_relay="$(normalize_size "$(content_length "$release_base/rv-guest-relay-$target")")"
    # macOS guest backend (`rv workspace run --macvm`). Older releases omit it.
    size_macvm="$(normalize_size "$(content_length "$release_base/rv-macvm-$target")")"
    size_macvm_agent="$(normalize_size "$(content_length "$release_base/rv-macvm-agent-$target")")"
    size_approvals="$(normalize_size "$(content_length "$release_base/rv-approvals-darwin-arm64.zip")")"
  fi

  progress_total=$((size_rv + size_cli + size_rvd + size_host + size_packs + size_span + size_claim + size_microvm + size_relay + size_macvm + size_macvm_agent + size_approvals))
  size_isolation=0
  size_swiftlibs=0
  if [ "$os" = "Linux" ]; then
    size_isolation="$(normalize_size "$(content_length "$release_base/rv-isolation-exec-$target")")"
    size_swiftlibs="$(normalize_size "$(content_length "$release_base/rv-swiftlibs-$target.tar.gz")")"
    progress_total=$((progress_total + size_isolation + size_swiftlibs))
  fi
  progress_base=0
  progress_have=0
  progress_start

  download_release_asset "$tmp_fetch" "rv-$target" "$size_rv" "rv"
  download_release_asset "$tmp_fetch" "rv-cli-$target" "$size_cli" "rv-cli"
  download_release_asset "$tmp_fetch" "rvd-$target" "$size_rvd" "rvd"
  download_release_asset "$tmp_fetch" "rv-workspace-host-$target" "$size_host" "rv-workspace-host"
  chmod 755 "$tmp_fetch/rv" "$tmp_fetch/rv-cli" "$tmp_fetch/rvd" "$tmp_fetch/rv-workspace-host"
  if [ "$os" = "Darwin" ] && [ "$size_span" -gt 0 ]; then
    download_release_asset "$tmp_fetch" "libswiftCompatibilitySpan.dylib" "$size_span"
    chmod 755 "$tmp_fetch/libswiftCompatibilitySpan.dylib"
  fi
  if [ "$os" = "Darwin" ] && [ "$size_claim" -gt 0 ]; then
    download_release_asset "$tmp_fetch" "rv-pty-claim-$target" "$size_claim" "rv-pty-claim"
    chmod 755 "$tmp_fetch/rv-pty-claim"
  fi
  if [ "$os" = "Darwin" ] && [ "$size_microvm" -gt 0 ] && [ "$size_relay" -gt 0 ]; then
    download_release_asset "$tmp_fetch" "rv-microvm-$target" "$size_microvm" "rv-microvm"
    download_release_asset "$tmp_fetch" "rv-guest-relay-$target" "$size_relay" "rv-guest-relay"
    chmod 755 "$tmp_fetch/rv-microvm" "$tmp_fetch/rv-guest-relay"
  fi
  if [ "$os" = "Darwin" ] && [ "$size_macvm" -gt 0 ] && [ "$size_macvm_agent" -gt 0 ]; then
    download_release_asset "$tmp_fetch" "rv-macvm-$target" "$size_macvm" "rv-macvm"
    download_release_asset "$tmp_fetch" "rv-macvm-agent-$target" "$size_macvm_agent" "rv-macvm-agent"
    chmod 755 "$tmp_fetch/rv-macvm" "$tmp_fetch/rv-macvm-agent"
  fi
  # Optional: releases without a provisioned custodian bundle omit the asset.
  if [ "$os" = "Darwin" ] && [ "$size_approvals" -gt 0 ]; then
    download_release_asset "$tmp_fetch" "rv-approvals-darwin-arm64.zip" "$size_approvals"
    ditto -x -k "$tmp_fetch/rv-approvals-darwin-arm64.zip" "$tmp_fetch"
    rm -f "$tmp_fetch/rv-approvals-darwin-arm64.zip"
  fi
  if [ "$os" = "Linux" ]; then
    download_release_asset "$tmp_fetch" "rv-isolation-exec-$target" "$size_isolation" "rv-isolation-exec"
    chmod 755 "$tmp_fetch/rv-isolation-exec"
  fi
  fetch_pack_bundles "$tmp_fetch" "$size_packs"
  if [ "$os" = "Linux" ]; then
    fetch_swift_libs "$tmp_fetch" "$size_swiftlibs"
  fi
  # Judge weights ride the same progress bar. Best-effort: any failure
  # warns and the install continues packs-only.
  fetch_model_bundle
  progress_finish

  src="$tmp_fetch"
  [ -x "$src/rv" ] && [ -x "$src/rv-cli" ] && [ -x "$src/rvd" ] && [ -x "$src/rv-workspace-host" ] || {
    echo "rv: download did not produce executable rv, rv-cli, rvd, and rv-workspace-host" >&2
    exit 1
  }
  if [ "$os" = "Darwin" ]; then
    verify_release_signatures "$src" libswiftCompatibilitySpan.dylib \
      rv rv-cli rvd rv-workspace-host rv-pty-claim rv-microvm rv-macvm rv-macvm-agent RVApprovals.app
  fi
fi

if [ "$os" = "Linux" ] && [ ! -x "$src/rv-isolation-exec" ]; then
  echo "rv: Linux installation requires executable rv-isolation-exec" >&2
  exit 1
fi

refuse_untrusted_rvd_under_manifest "$src"

if [ "$os" = "Darwin" ] && command -v otool >/dev/null 2>&1; then
  if otool -L "$src/rv-cli" 2>/dev/null | grep -q 'libswiftCompatibilitySpan.dylib' \
    && [ ! -f "$src/libswiftCompatibilitySpan.dylib" ]; then
    echo "rv: rv-cli needs libswiftCompatibilitySpan.dylib beside it" >&2
    exit 1
  fi
fi

# Stage all required copies before touching any destination: a copy failure
# must leave the previous install intact, never a torn trio (new C rv with
# no rv-cli sibling makes doctor unreachable and hooks deny-only).
tmp_rv="$bin/.rv.installing"
tmp_cli="$bin/.rv-cli.installing"
tmp_rvd="$bin/.rvd.installing"
tmp_host="$bin/.rv-workspace-host.installing"
tmp_claim=""
tmp_span=""
rm -f "$tmp_rv" "$tmp_cli" "$tmp_rvd" "$tmp_host"
cp "$src/rv" "$tmp_rv"
cp "$src/rv-cli" "$tmp_cli"
cp "$src/rvd" "$tmp_rvd"
cp "$src/rv-workspace-host" "$tmp_host"
chmod 755 "$tmp_rv" "$tmp_cli" "$tmp_rvd" "$tmp_host"
if [ "$os" = "Darwin" ] && [ -f "$src/libswiftCompatibilitySpan.dylib" ]; then
  tmp_span="$bin/.libswiftCompatibilitySpan.dylib.installing"
  rm -f "$tmp_span"
  cp "$src/libswiftCompatibilitySpan.dylib" "$tmp_span"
  chmod 755 "$tmp_span"
fi
if [ "$os" = "Linux" ]; then
  tmp_isolation="$bin/.rv-isolation-exec.installing"
  rm -f "$tmp_isolation"
  cp "$src/rv-isolation-exec" "$tmp_isolation"
  chmod 755 "$tmp_isolation"
fi
# Optional: older stages and the Darwin install fixtures omit it. A present
# helper must land next to rv-workspace-host or contained PTY launches fail closed.
if [ "$os" = "Darwin" ] && [ -x "$src/rv-pty-claim" ]; then
  tmp_claim="$bin/.rv-pty-claim.installing"
  rm -f "$tmp_claim"
  cp "$src/rv-pty-claim" "$tmp_claim"
  chmod 755 "$tmp_claim"
fi

# Unlink dest first: BSD cp writes through an existing dest symlink. Same
# directory rename after a successful staging is metadata-only.
rm -f "$bin/rv" "$bin/rv-cli" "$bin/rvd" "$bin/rv-workspace-host"
mv -f "$tmp_rv" "$bin/rv"
mv -f "$tmp_cli" "$bin/rv-cli"
mv -f "$tmp_rvd" "$bin/rvd"
mv -f "$tmp_host" "$bin/rv-workspace-host"
if [ -n "$tmp_span" ]; then
  rm -f "$bin/libswiftCompatibilitySpan.dylib"
  mv -f "$tmp_span" "$bin/libswiftCompatibilitySpan.dylib"
  tmp_span=""
fi
if [ "$os" = "Linux" ]; then
  rm -f "$bin/rv-isolation-exec"
  mv -f "$tmp_isolation" "$bin/rv-isolation-exec"
  tmp_isolation=""
fi
if [ -n "$tmp_claim" ]; then
  rm -f "$bin/rv-pty-claim"
  mv -f "$tmp_claim" "$bin/rv-pty-claim"
  tmp_claim=""
fi
# Optional pair: rv-microvm installs rv-guest-relay into each guest from
# beside itself. rv-guest-relay is a Linux binary and carries no signature.
if [ "$os" = "Darwin" ] && [ -x "$src/rv-microvm" ] && [ -x "$src/rv-guest-relay" ]; then
  for helper in rv-microvm rv-guest-relay; do
    rm -f "$bin/.$helper.installing"
    cp "$src/$helper" "$bin/.$helper.installing"
    chmod 755 "$bin/.$helper.installing"
    rm -f "$bin/$helper"
    mv -f "$bin/.$helper.installing" "$bin/$helper"
  done
fi
# Optional pair: `rv-macvm prepare` installs rv-macvm-agent from beside itself.
if [ "$os" = "Darwin" ] && [ -x "$src/rv-macvm" ] && [ -x "$src/rv-macvm-agent" ]; then
  for helper in rv-macvm rv-macvm-agent; do
    rm -f "$bin/.$helper.installing"
    cp "$src/$helper" "$bin/.$helper.installing"
    chmod 755 "$bin/.$helper.installing"
    rm -f "$bin/$helper"
    mv -f "$bin/.$helper.installing" "$bin/$helper"
  done
fi
tmp_rv=""
tmp_cli=""
tmp_rvd=""
tmp_host=""

# Pack JSON lives next to the binaries (Scripts/release.sh). Swift Build (the
# SwiftPM default since 6.4) emits *_RVPacks.bundle on every platform; the
# legacy native build system emits *_RVPacks.resources on Linux. PackRegistry
# accepts either name.
for bundle in "$src"/*_RVPacks.bundle "$src"/*_RVPacks.resources; do
  [ -d "$bundle" ] || continue
  name="$(basename "$bundle")"
  rm -rf "$bin/$name"
  cp -R "$bundle" "$bin/$name"
done

# Linux Swift runtime libraries ship in rv-swiftlibs-<target>.tar.gz and
# land beside the binaries, where their $ORIGIN RUNPATH finds them. Their
# names are generic, so each is recorded in $bin/.rv-swiftlibs: `rv
# uninstall` removes only recorded names (InstallManifest.swiftLibsListName).
for lib in "$src"/*.so; do
  [ -f "$lib" ] && [ ! -L "$lib" ] || continue
  name="$(basename "$lib")"
  rm -f "$bin/$name"
  cp "$lib" "$bin/$name"
  chmod 755 "$bin/$name"
  printf '%s\n' "$name" >> "$bin/.rv-swiftlibs"
done
if [ -f "$bin/.rv-swiftlibs" ]; then
  sort -u "$bin/.rv-swiftlibs" > "$bin/.rv-swiftlibs.installing" \
    && mv -f "$bin/.rv-swiftlibs.installing" "$bin/.rv-swiftlibs"
fi

# The approvals custodian bundle lands in ~/Applications with the same
# stage-then-swap discipline as the binaries: setup registers it only when
# the executable is present there.
if [ "$os" = "Darwin" ] && [ -d "$src/RVApprovals.app" ]; then
  apps_dir="$HOME/Applications"
  mkdir -p "$apps_dir"
  tmp_app="$apps_dir/.RVApprovals.app.installing"
  rm -rf "$tmp_app"
  cp -R "$src/RVApprovals.app" "$tmp_app"
  rm -rf "$apps_dir/RVApprovals.app"
  mv -f "$tmp_app" "$apps_dir/RVApprovals.app"
fi

if [ "${RV_INSTALL_MODE:-}" = "observe" ]; then
  RV_FROM_INSTALL=1 exec "$bin/rv" setup --observe
fi
RV_FROM_INSTALL=1 exec "$bin/rv" setup
