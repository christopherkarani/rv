#!/usr/bin/env bash
# Scripts/linux-rv-run-e2e.sh — `rv run` on Linux with a real HTTPS
# request, end to end (docs/security/secrets-gateway-policy.md,
# "Uncontained launches").
#
# As root: makes a throwaway CA and a certificate for localhost, a
# throwaway account, and runs Scripts/linux-rv-run-e2e.py as that account
# inside a private mount namespace where the system CA bundle is the
# system's plus the throwaway CA. rv's gateway reaches its upstream with
# the system bundle and nothing else, so this is how a test upstream on
# localhost is trusted without touching the host's trust store. Everything
# it made is removed at the end.
#
#   Scripts/linux-rv-run-e2e.sh [BUILD-DIRECTORY]   (default .build/debug)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$(cd "${1:-$ROOT/.build/debug}" && pwd)"
OWNER="rv-e2e-run"
BUNDLE=/etc/ssl/certs/ca-certificates.crt

log() { printf 'rv-run-e2e: %s\n' "$*" >&2; }
die() { log "$*"; exit 1; }

[[ "$(uname -s)" == "Linux" ]] || die "Linux only"
[[ "$(id -u)" == "0" ]] || die "needs root (a mount namespace and a throwaway account)"
for binary in rv rv-isolation-exec; do
  [[ -x "$BUILD/$binary" ]] || die "$BUILD/$binary is not built (swift build)"
done
[[ -f "$BUNDLE" ]] || die "$BUNDLE is missing (package ca-certificates)"
command -v openssl >/dev/null || die "openssl is not installed"
getent passwd "$OWNER" >/dev/null && die "the account $OWNER already exists; not touching it"

STAGE="$(mktemp -d /var/tmp/rv-run-e2e.XXXXXX)"
cleanup() {
  local status=$?
  set +e
  pkill -KILL -u "$OWNER" 2>/dev/null
  userdel --remove "$OWNER" >/dev/null 2>&1
  rm -rf "$STAGE"
  exit "$status"
}
trap cleanup EXIT

# rv and its launcher where any account can run them, as an install has
# them, and the driver with them: a checkout is often under a home the
# throwaway account cannot enter.
install -m 0755 "$BUILD/rv" "$BUILD/rv-isolation-exec" "$STAGE/"
install -m 0644 "$ROOT/Scripts/linux-rv-run-e2e.py" "$STAGE/"
chmod 0755 "$STAGE"

mkdir "$STAGE/certificates"
(
  cd "$STAGE/certificates"
  openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 2 -subj "/CN=rv run e2e CA" 2>/dev/null
  openssl req -newkey rsa:2048 -nodes -keyout server.key -out server.csr -subj "/CN=localhost" 2>/dev/null
  printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\n' > san.cnf
  openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out server.pem -days 2 \
    -extfile san.cnf 2>/dev/null
  # The CA's key signs nothing else.
  rm -f ca.key ca.srl server.csr san.cnf
  cat "$BUNDLE" ca.pem > bundle.crt
)
chmod 0755 "$STAGE/certificates"
chmod 0644 "$STAGE/certificates"/*

useradd --create-home --shell /bin/bash "$OWNER"
log "driving rv run as $OWNER on $(uname -r)"

status=0
unshare --mount --propagation private -- sh -c "
  mount --bind '$STAGE/certificates/bundle.crt' '$BUNDLE' &&
  exec setpriv --reuid '$OWNER' --regid '$OWNER' --init-groups \
    env -i HOME='/home/$OWNER' USER='$OWNER' PATH=/usr/bin:/bin LANG=C.UTF-8 \
    python3 '$STAGE/linux-rv-run-e2e.py' '$STAGE/rv' '$STAGE/certificates'" || status=$?

[[ "$status" == "0" ]] && log "PASS" || log "FAILED"
exit "$status"
