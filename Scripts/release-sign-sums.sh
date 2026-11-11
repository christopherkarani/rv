#!/usr/bin/env bash
# Scripts/release-sign-sums.sh — sign a release's SHA256SUMS with rv's SSH
# release key, so installers can check checksums against a key they pin
# instead of trusting whatever SHA256SUMS the release serves.
# Compatible with macOS /bin/bash 3.2.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: Scripts/release-sign-sums.sh <assets-dir> [install.sh]

  Signs <assets-dir>/SHA256SUMS into <assets-dir>/SHA256SUMS.sig with
  `ssh-keygen -Y sign -n rv-release`, using the private key in
  $RV_RELEASE_SSH_SIGNING_KEY (unencrypted OpenSSH format, e.g. from
  `ssh-keygen -t ed25519 -N ''`; written to a 0600 temp file and removed
  afterwards).

  install.sh (default: the repo's) pins the public half in
  release_ssh_allowed_signers. When it is pinned, the new signature must
  verify against the pin, and a missing key fails: every installer would
  refuse the release. When it is empty, the signature is still published and
  the line to pin is printed. With no key and no pin, nothing is signed
  (a notice), unless RV_REQUIRE_SIGNED_RELEASE=1, which fails.
EOF
}

if [[ $# -lt 1 || $# -gt 2 || "$1" == "-h" || "$1" == "--help" ]]; then
  usage
  [[ $# -ge 1 && ( "$1" == "-h" || "$1" == "--help" ) ]] && exit 0
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS="$1"
INSTALL_SH="${2:-$ROOT/install.sh}"
PRINCIPAL="rv-release"
NAMESPACE="rv-release"

log() { printf 'release-sign-sums: %s\n' "$*" >&2; }

[[ -f "$ASSETS/SHA256SUMS" ]] || { log "missing $ASSETS/SHA256SUMS"; exit 1; }
[[ -f "$INSTALL_SH" ]] || { log "missing $INSTALL_SH"; exit 1; }

# The pin block: from `release_ssh_allowed_signers="` to its closing quote.
pin_block="$(awk '
  open { print; if (index($0, "\"")) exit; next }
  index($0, "release_ssh_allowed_signers=\"") == 1 {
    print
    if (index(substr($0, 30), "\"")) exit
    open = 1
  }' "$INSTALL_SH")"
[[ -n "$pin_block" ]] || { log "install.sh has no release_ssh_allowed_signers"; exit 1; }
release_ssh_allowed_signers=""
eval "$pin_block"
pinned="$release_ssh_allowed_signers"
rm -f "$ASSETS/SHA256SUMS.sig"

if [[ -z "${RV_RELEASE_SSH_SIGNING_KEY:-}" ]]; then
  if [[ -n "$pinned" ]]; then
    log "install.sh pins a release key but RV_RELEASE_SSH_SIGNING_KEY is not set: installers would refuse this release"
    exit 1
  fi
  if [[ "${RV_REQUIRE_SIGNED_RELEASE:-}" == "1" ]]; then
    log "RV_REQUIRE_SIGNED_RELEASE=1 but RV_RELEASE_SSH_SIGNING_KEY is not set"
    exit 1
  fi
  log "RV_RELEASE_SSH_SIGNING_KEY is not set; SHA256SUMS is published unsigned"
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::notice::RV_RELEASE_SSH_SIGNING_KEY is not configured; SHA256SUMS is not signed"
  fi
  exit 0
fi

command -v ssh-keygen >/dev/null 2>&1 || { log "ssh-keygen is required"; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/rv-sign-sums.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT
key="$work/key"
(umask 077 && printf '%s\n' "$RV_RELEASE_SSH_SIGNING_KEY" > "$key")

ssh-keygen -q -Y sign -f "$key" -n "$NAMESPACE" "$ASSETS/SHA256SUMS" >/dev/null
[[ -s "$ASSETS/SHA256SUMS.sig" ]] || { log "ssh-keygen did not write SHA256SUMS.sig"; exit 1; }

public="$(ssh-keygen -y -f "$key" | awk '{ print $1, $2 }')"
signers="$work/allowed_signers"
if [[ -n "$pinned" ]]; then
  printf '%s\n' "$pinned" > "$signers"
else
  printf '%s %s\n' "$PRINCIPAL" "$public" > "$signers"
fi
if ! ssh-keygen -Y verify -f "$signers" -I "$PRINCIPAL" -n "$NAMESPACE" \
  -s "$ASSETS/SHA256SUMS.sig" < "$ASSETS/SHA256SUMS" >/dev/null 2>&1; then
  rm -f "$ASSETS/SHA256SUMS.sig"
  if [[ -n "$pinned" ]]; then
    log "the signing key does not match install.sh's release_ssh_allowed_signers pin"
  else
    log "the new signature does not verify"
  fi
  exit 1
fi

if [[ -n "$pinned" ]]; then
  log "signed SHA256SUMS; verifies against install.sh's pinned key"
else
  log "signed SHA256SUMS; install.sh does not pin a key yet, so installers do not check it"
  log "to enforce it, set in install.sh: release_ssh_allowed_signers=\"$PRINCIPAL $public\""
fi
