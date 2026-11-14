#!/usr/bin/env bash
# Scripts/linux-peer-binding-e2e.sh — the secrets gateway's Linux peer
# binding inside the environments that change what /proc shows.
#
# The binding reads /proc (docs/security/secrets-gateway-policy.md, "Runtime
# binding" -> "Linux"). Its unit tests run on whatever /proc the host has;
# this runs the same code where /proc hides processes, belongs to another
# pid namespace, or refuses reads, and checks it fails closed there:
#
#   hidepid    /proc remounted with hidepid=2 (private mount namespace)
#   subset     /proc remounted with subset=pid
#   foreign    a new pid namespace with the old /proc still mounted
#   noptrace   root without CAP_SYS_PTRACE (another user's descriptors unreadable)
#   confined   the test process under an AppArmor profile with no ptrace rule
#   yama       the whole suite at kernel.yama.ptrace_scope 1 and 2
#              (and 3, which cannot be undone, with RV_YAMA_IRREVERSIBLE=1)
#   container  the suite in a default Docker container (seccomp, no caps)
#
# Needs root and a built test bundle (swift build --build-tests). With no
# arguments it runs every regime this host supports and names the ones it
# skipped; RV_LINUX_PEER_STRICT=1 makes an unsupported regime a failure
# (CI on a real VM sets it).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
STRICT="${RV_LINUX_PEER_STRICT:-0}"
SUITES='SecretGatewayLinuxPeerTests|SecretGatewayLinuxAttackTests'
PROFILE="rv-peer-binding-e2e"

log() { printf 'peer-binding-e2e: %s\n' "$*" >&2; }
die() { log "$*"; exit 1; }

[[ "$(uname -s)" == "Linux" ]] || die "Linux only"
[[ "$(id -u)" == "0" ]] || die "needs root (mount, pid namespaces, sysctl)"
command -v swift >/dev/null || die "swift is not on PATH"

# `swift test` with a wall-clock bound: a hung child must fail, not stall CI.
run_tests() {
  timeout 600 swift test --skip-build --only-use-versions-from-resolved-file --filter "$1"
}

unsupported() {
  if [[ "$STRICT" == "1" ]]; then
    die "regime $1 is not supported here ($2), and RV_LINUX_PEER_STRICT=1 requires it"
  fi
  log "SKIPPED $1: $2"
  skipped+=("$1")
}

regime_mount() {
  local name="$1" options="$2" test="$3"
  log "regime $name: /proc mounted with $options"
  RV_PROC_REGIME="$name" unshare --mount --propagation private -- sh -c "
    mount -t proc -o '$options' proc /proc &&
    exec timeout 600 swift test --skip-build --only-use-versions-from-resolved-file --filter '$test'"
}

regime_foreign() {
  log "regime foreign: new pid namespace, old /proc"
  RV_PROC_REGIME=foreign unshare --pid --fork -- \
    timeout 600 swift test --skip-build --only-use-versions-from-resolved-file \
    --filter aProcOfAnotherPidNamespaceAnswersNothing
}

regime_noptrace() {
  log "regime noptrace: root without CAP_SYS_PTRACE"
  RV_PROC_REGIME=noptrace setpriv --bounding-set -sys_ptrace --inh-caps -sys_ptrace -- \
    timeout 600 swift test --skip-build --only-use-versions-from-resolved-file \
    --filter aChildOfAnotherUserWhoseDescriptorsAreUnreadable
}

regime_confined() {
  if [[ ! -d /sys/kernel/security/apparmor ]] || ! command -v apparmor_parser >/dev/null \
    || ! command -v aa-exec >/dev/null; then
    unsupported confined "AppArmor, apparmor_parser or aa-exec is missing"
    return 0
  fi
  log "regime confined: AppArmor profile with no ptrace rule"
  local profile
  profile="$(mktemp)"
  # Everything but ptrace: reading another process's /proc/<pid>/fd is a
  # ptrace read, which a confined reader needs a rule for.
  cat >"$profile" <<EOF
abi <abi/4.0>,
profile $PROFILE flags=(attach_disconnected) {
  file,
  capability,
  network,
  signal,
  mount,
  unix,
  userns,
}
EOF
  apparmor_parser --replace "$profile"
  local status=0
  RV_PROC_REGIME=confined aa-exec -p "$PROFILE" -- \
    timeout 600 swift test --skip-build --only-use-versions-from-resolved-file \
    --filter aGatewayThatMayNotReadOtherProcessesCannotTell || status=$?
  apparmor_parser --remove "$profile" || true
  rm -f "$profile"
  return "$status"
}

regime_yama() {
  local knob=/proc/sys/kernel/yama/ptrace_scope
  if [[ ! -w "$knob" ]]; then
    unsupported yama "no Yama LSM"
    return 0
  fi
  local before scope
  before="$(cat "$knob")"
  for scope in 1 2; do
    log "regime yama: ptrace_scope=$scope"
    echo "$scope" >"$knob"
    run_tests "$SUITES"
  done
  if [[ "${RV_YAMA_IRREVERSIBLE:-0}" == "1" ]]; then
    log "regime yama: ptrace_scope=3 (stays until reboot)"
    echo 3 >"$knob"
    run_tests "$SUITES"
  else
    echo "$before" >"$knob"
    log "regime yama: ptrace_scope=3 not run (set RV_YAMA_IRREVERSIBLE=1; it cannot be undone)"
  fi
}

regime_container() {
  if ! command -v docker >/dev/null || ! docker info >/dev/null 2>&1; then
    unsupported container "no Docker daemon"
    return 0
  fi
  local toolchain image
  toolchain="$(cd "$(dirname "$(command -v swift)")/../.." && pwd)"
  image="${RV_PEER_E2E_IMAGE:-ubuntu:24.04}"
  log "regime container: default Docker ($image), toolchain $toolchain"
  # Default seccomp and AppArmor profiles, default capabilities (no
  # CAP_SYS_PTRACE), the container's own pid namespace and /proc. The
  # checkout and toolchain are mounted at their host paths, so the bundle
  # built outside runs unchanged. Kernel features the profile refuses
  # (io_uring, unshare) print `skipped:` there: not strict.
  docker run --rm \
    -v "$ROOT:$ROOT" -v "$toolchain:$toolchain:ro" -w "$ROOT" \
    -e PATH="$toolchain/usr/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    -e RV_PROC_REGIME=noptrace -e HOME=/tmp \
    "$image" sh -c "
      set -e
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq >/dev/null
      apt-get install -y -qq libsqlite3-0 libcurl4 libxml2 libedit2 libncurses6 libz3-4 libpython3.12 \
        libc6-dev libgcc-13-dev libstdc++-13-dev \
        binutils git util-linux ca-certificates >/dev/null
      git config --global --add safe.directory '$ROOT'
      timeout 900 swift test --skip-build --only-use-versions-from-resolved-file --filter '$SUITES|GatewayPeerBindingTests'"
}

skipped=()
regimes=("$@")
if [[ ${#regimes[@]} -eq 0 ]]; then
  regimes=(hidepid subset foreign noptrace confined container yama)
fi

for regime in "${regimes[@]}"; do
  case "$regime" in
    hidepid) regime_mount hidepid hidepid=2 aProcMountedToHideProcessesBindsNothing ;;
    subset) regime_mount subset subset=pid aProcMountedWithOnlyTheProcessFilesStillBinds ;;
    foreign) regime_foreign ;;
    noptrace) regime_noptrace ;;
    confined) regime_confined ;;
    container) regime_container ;;
    yama) regime_yama ;;
    *) die "unknown regime $regime" ;;
  esac
  log "regime $regime: ok"
done

if [[ ${#skipped[@]} -gt 0 ]]; then
  log "done; skipped: ${skipped[*]}"
else
  log "done; every regime ran"
fi
