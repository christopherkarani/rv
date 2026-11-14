#!/usr/bin/env bash
# Scripts/linux-custodian-e2e.sh — the approvals custodian on a real host,
# end to end (docs/security/mcp-linux-custodian.md).
#
# As root: installs the custodian, makes a throwaway account with a
# password, and runs Scripts/linux-custodian-e2e.py as that account. The
# driver plays the owner at a terminal (who can type the password) and the
# agent (same account, no password): trust, the gateway, an approval, a
# replayed grant, a rolled-back mcp.json, and the audit log.
#
# Where systemd is the init system (a CI runner, a real machine) it uses
# the real `rv mcp custodian install`, so the units and their hardening
# are what is tested. Elsewhere (a container) it starts the two daemons
# itself, under the same accounts and paths. Either way everything it
# made is removed at the end.
#
#   Scripts/linux-custodian-e2e.sh [BUILD-DIRECTORY]   (default .build/debug)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$(cd "${1:-$ROOT/.build/debug}" && pwd)"
OWNER="rv-e2e-owner"
ACCOUNT="rv-mcp-custodian"

log() { printf 'custodian-e2e: %s\n' "$*" >&2; }
die() { log "$*"; exit 1; }

[[ "$(uname -s)" == "Linux" ]] || die "Linux only"
[[ "$(id -u)" == "0" ]] || die "needs root (it installs system services and makes an account)"
for binary in rv rv-mcp-custodian; do
  [[ -x "$BUILD/$binary" ]] || die "$BUILD/$binary is not built (swift build)"
done
[[ ! -S /run/rv-mcp-custodian/custodian.sock ]] || die "a custodian is already running on this host; not touching it"
getent passwd "$OWNER" >/dev/null && die "the account $OWNER already exists; not touching it"

SYSTEMD=0
[[ -d /run/systemd/system ]] && SYSTEMD=1
PIDS=()
STAGE="$(mktemp -d /var/tmp/rv-custodian-e2e.XXXXXX)"

cleanup() {
  local status=$?
  set +e
  if [[ "$SYSTEMD" == "1" ]]; then
    "$STAGE/rv" mcp custodian uninstall --purge >/dev/null 2>&1
  else
    for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null; done
    rm -rf /run/rv-mcp-custodian /run/rv-mcp-presence /var/lib/rv-mcp-custodian \
      /usr/local/libexec/rv/rv-mcp-custodian /etc/pam.d/rv-mcp-custodian
    rmdir /usr/local/libexec/rv 2>/dev/null
    userdel "$ACCOUNT" 2>/dev/null
  fi
  pkill -KILL -u "$OWNER" 2>/dev/null
  userdel --remove "$OWNER" >/dev/null 2>&1
  rm -rf "$STAGE"
  exit "$status"
}
trap cleanup EXIT

# The binaries where any account can run them, as an install would have them.
install -m 0755 "$BUILD/rv" "$BUILD/rv-mcp-custodian" "$STAGE/"
[[ -x "$BUILD/rv-isolation-exec" ]] && install -m 0755 "$BUILD/rv-isolation-exec" "$STAGE/"
chmod 0755 "$STAGE"

if [[ "$SYSTEMD" == "1" ]]; then
  log "installing with rv mcp custodian install (systemd)"
  "$STAGE/rv" mcp custodian install
  # A second install changes nothing and still succeeds.
  "$STAGE/rv" mcp custodian install >/dev/null
  systemctl is-active --quiet rv-mcp-custodian.service rv-mcp-presence.service \
    || { systemctl status rv-mcp-custodian.service rv-mcp-presence.service >&2; die "the units are not active"; }
  log "unit hardening: $(systemd-analyze security rv-mcp-custodian.service 2>/dev/null | tail -n 1)"
else
  log "no systemd here: starting the daemons directly, under the same accounts and paths"
  include=common
  [[ -e /etc/pam.d/common-auth ]] || include=system
  getent passwd "$ACCOUNT" >/dev/null \
    || useradd --system --user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$ACCOUNT"
  install -d -m 0755 /usr/local/libexec/rv
  install -m 0755 "$BUILD/rv-mcp-custodian" /usr/local/libexec/rv/rv-mcp-custodian
  if [[ "$include" == "common" ]]; then
    printf 'auth     include  common-auth\naccount  include  common-account\n' > /etc/pam.d/rv-mcp-custodian
  else
    printf 'auth     include  system-auth\naccount  include  system-auth\n' > /etc/pam.d/rv-mcp-custodian
  fi
  install -d -o "$ACCOUNT" -g "$ACCOUNT" -m 0700 /var/lib/rv-mcp-custodian
  install -d -o "$ACCOUNT" -g "$ACCOUNT" -m 0755 /run/rv-mcp-custodian
  install -d -m 0755 /run/rv-mcp-presence
  setpriv --reuid "$ACCOUNT" --regid "$ACCOUNT" --clear-groups \
    /usr/local/libexec/rv/rv-mcp-custodian serve 2>"$STAGE/custodian.log" &
  PIDS+=("$!")
  /usr/local/libexec/rv/rv-mcp-custodian presence 2>"$STAGE/presence.log" &
  PIDS+=("$!")
fi

for _ in $(seq 1 100); do
  [[ -S /run/rv-mcp-custodian/custodian.sock && -S /run/rv-mcp-presence/presence.sock ]] && break
  sleep 0.1
done
[[ -S /run/rv-mcp-custodian/custodian.sock && -S /run/rv-mcp-presence/presence.sock ]] \
  || die "the custodian's sockets did not appear"

# The state is the custodian's alone.
[[ "$(stat -c '%U %a' /var/lib/rv-mcp-custodian)" == "$ACCOUNT 700" ]] \
  || die "/var/lib/rv-mcp-custodian is $(stat -c '%U %a' /var/lib/rv-mcp-custodian), not the custodian's alone"

PASSWORD="$(head -c 18 /dev/urandom | base64 | tr -d '/+=')"
useradd --create-home --shell /bin/bash "$OWNER"
printf '%s:%s\n' "$OWNER" "$PASSWORD" | chpasswd
log "driving rv as $OWNER"

status=0
setpriv --reuid "$OWNER" --regid "$OWNER" --init-groups \
  env -i HOME="/home/$OWNER" USER="$OWNER" PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 \
  RV_E2E_PASSWORD="$PASSWORD" python3 "$ROOT/Scripts/linux-custodian-e2e.py" "$STAGE/rv" || status=$?

# What the custodian holds is unreadable to the account it holds it for.
if setpriv --reuid "$OWNER" --regid "$OWNER" --init-groups \
  sh -c 'ls /var/lib/rv-mcp-custodian || cat /var/lib/rv-mcp-custodian/u*/approvals.key' >/dev/null 2>&1; then
  log "FAIL the owner account can read the custodian's state"
  status=1
else
  log "PASS the owner account cannot read the custodian's state"
fi
ls /var/lib/rv-mcp-custodian/u"$(id -u "$OWNER")"/approvals.key >/dev/null \
  || { log "FAIL no key was made for the owner"; status=1; }

if [[ "$status" != "0" && "$SYSTEMD" == "0" ]]; then
  sed 's/^/custodian: /' "$STAGE/custodian.log" >&2 || true
  sed 's/^/presence: /' "$STAGE/presence.log" >&2 || true
fi
if [[ "$status" != "0" && "$SYSTEMD" == "1" ]]; then
  journalctl -u rv-mcp-custodian.service -u rv-mcp-presence.service --no-pager -n 50 >&2 || true
fi

if [[ "$SYSTEMD" == "1" ]]; then
  log "uninstalling"
  "$STAGE/rv" mcp custodian uninstall --purge
  for left in /etc/systemd/system/rv-mcp-custodian.service /etc/systemd/system/rv-mcp-presence.service \
    /etc/pam.d/rv-mcp-custodian /usr/local/libexec/rv/rv-mcp-custodian /var/lib/rv-mcp-custodian \
    /run/rv-mcp-custodian/custodian.sock; do
    [[ ! -e "$left" ]] || { log "FAIL uninstall left $left"; status=1; }
  done
  getent passwd "$ACCOUNT" >/dev/null && { log "FAIL uninstall left the $ACCOUNT account"; status=1; }
  # Removing what is already gone succeeds.
  "$STAGE/rv" mcp custodian uninstall --purge >/dev/null || { log "FAIL a second uninstall failed"; status=1; }
fi

[[ "$status" == "0" ]] && log "PASS" || log "FAILED"
exit "$status"
