#!/bin/sh
# Install rv (C hook), rv-cli, and rvd into $HOME/.local/bin, then run rv setup.
# Darwin: macOS 15 or newer + arm64. Linux: aarch64 or x86_64. No Windows.
# Tests must set HOME to a temp directory.
# Unset RV_INSTALL_BIN downloads the latest GitHub release trio into a temp
# dir, then uses the same atomic stage+setup path as a local stage.
# Downloaded macOS files are signature-checked before anything is staged:
# a signed file must be valid, notarized, and from the pinned team once one
# is set. Unsigned files only warn until signed_releases=1 below.
# TTY download UI matches SetupRenderer: "Downloading" + 24× ━/─ bar, driven by
# real Content-Length weights (and mid-file byte growth while each curl runs).
set -eu

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

release_base="https://github.com/christopherkarani/rv/releases/latest/download"
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

# Downloaded macOS release files must carry a valid, notarized Developer ID
# signature from the pinned team. A broken, foreign, or unpinned signature
# always refuses, including libswiftCompatibilitySpan.dylib. Unsigned files
# follow signed_releases; a mix never installs. An empty team id does not
# accept "any notarized Developer ID".
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
    [ -f "$file" ] || continue
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
    if ! "$codesign" --verify --strict "$file" >/dev/null 2>&1; then
      echo "rv: refusing to install: $name has an invalid code signature" >&2
      exit 1
    fi
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
    if [ -z "$team" ]; then
      echo "rv: refusing to install: $name is signed, but no Developer ID team is pinned (release_team_id)" >&2
      exit 1
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

if [ -n "${RV_INSTALL_BIN:-}" ]; then
  src="$RV_INSTALL_BIN"
  [ -x "$src/rv" ] && [ -x "$src/rv-cli" ] && [ -x "$src/rvd" ] && [ -x "$src/rv-workspace-host" ] || {
    echo "rv: RV_INSTALL_BIN must contain executable rv, rv-cli, rvd, and rv-workspace-host" >&2
    exit 1
  }
else
  tmp_fetch="$(mktemp -d "${TMPDIR:-/tmp}/rv-install.XXXXXX")"

  size_rv="$(normalize_size "$(content_length "$release_base/rv")")"
  size_cli="$(normalize_size "$(content_length "$release_base/rv-cli")")"
  size_rvd="$(normalize_size "$(content_length "$release_base/rvd")")"
  size_host="$(normalize_size "$(content_length "$release_base/rv-workspace-host")")"
  size_packs="$(normalize_size "$(content_length "$release_base/rv_RVPacks.bundle.tar.gz")")"
  size_span=0
  size_claim=0
  if [ "$os" = "Darwin" ]; then
    size_span="$(normalize_size "$(content_length "$release_base/libswiftCompatibilitySpan.dylib")")"
    size_claim="$(normalize_size "$(content_length "$release_base/rv-pty-claim")")"
  fi

  progress_total=$((size_rv + size_cli + size_rvd + size_host + size_packs + size_span + size_claim))
  size_isolation=0
  if [ "$os" = "Linux" ]; then
    size_isolation="$(normalize_size "$(content_length "$release_base/rv-isolation-exec")")"
    progress_total=$((progress_total + size_isolation))
  fi
  progress_base=0
  progress_have=0
  progress_start

  download_release_asset "$tmp_fetch" "rv" "$size_rv"
  download_release_asset "$tmp_fetch" "rv-cli" "$size_cli"
  download_release_asset "$tmp_fetch" "rvd" "$size_rvd"
  download_release_asset "$tmp_fetch" "rv-workspace-host" "$size_host"
  chmod 755 "$tmp_fetch/rv" "$tmp_fetch/rv-cli" "$tmp_fetch/rvd" "$tmp_fetch/rv-workspace-host"
  if [ "$os" = "Darwin" ] && [ "$size_span" -gt 0 ]; then
    download_release_asset "$tmp_fetch" "libswiftCompatibilitySpan.dylib" "$size_span"
    chmod 755 "$tmp_fetch/libswiftCompatibilitySpan.dylib"
  fi
  if [ "$os" = "Darwin" ] && [ "$size_claim" -gt 0 ]; then
    download_release_asset "$tmp_fetch" "rv-pty-claim" "$size_claim"
    chmod 755 "$tmp_fetch/rv-pty-claim"
  fi
  if [ "$os" = "Linux" ]; then
    download_release_asset "$tmp_fetch" "rv-isolation-exec" "$size_isolation"
    chmod 755 "$tmp_fetch/rv-isolation-exec"
  fi
  fetch_pack_bundles "$tmp_fetch" "$size_packs"
  progress_finish

  src="$tmp_fetch"
  [ -x "$src/rv" ] && [ -x "$src/rv-cli" ] && [ -x "$src/rvd" ] && [ -x "$src/rv-workspace-host" ] || {
    echo "rv: download did not produce executable rv, rv-cli, rvd, and rv-workspace-host" >&2
    exit 1
  }
  if [ "$os" = "Darwin" ]; then
    verify_release_signatures "$src" libswiftCompatibilitySpan.dylib \
      rv rv-cli rvd rv-workspace-host rv-pty-claim
  fi
fi

if [ "$os" = "Linux" ] && [ ! -x "$src/rv-isolation-exec" ]; then
  echo "rv: Linux installation requires executable rv-isolation-exec" >&2
  exit 1
fi

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
tmp_rv=""
tmp_cli=""
tmp_rvd=""
tmp_host=""

# Pack JSON lives next to the binaries (Scripts/release.sh). Darwin SPM emits
# *_RVPacks.bundle; Linux SPM emits *_RVPacks.resources. Bundle.module loads
# whichever name this platform's accessor baked.
for bundle in "$src"/*_RVPacks.bundle "$src"/*_RVPacks.resources; do
  [ -d "$bundle" ] || continue
  name="$(basename "$bundle")"
  rm -rf "$bin/$name"
  cp -R "$bundle" "$bin/$name"
done

RV_FROM_INSTALL=1 exec "$bin/rv" setup
