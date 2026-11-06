#!/usr/bin/env bash
# Boot pinned Linux guest kernels under QEMU and run rv-isolation-exec's
# Landlock boundary checks on each (docs/linux-kernel-e2e.md).
#
#   Scripts/linux-kernel-e2e.sh all            # every lane in kernels.tsv
#   Scripts/linux-kernel-e2e.sh 5.10 6.12      # chosen lanes
#   Scripts/linux-kernel-e2e.sh --list
#
# Options: --accel auto|kvm|tcg (default auto: KVM when /dev/kvm is usable),
#          --cache DIR (default ${XDG_CACHE_HOME:-~/.cache}/rv-kernel-e2e).
# Env:     RV_KERNEL_E2E_TIMEOUT seconds per boot (default 300).
#
# Guest = pinned kernel + an initramfs holding only two static binaries built
# here from this checkout: the real trampoline (Sources/rv-isolation-exec)
# and the harness (linux-kernel-e2e/guest-init.c) as PID 1. Every download is
# SHA-256 pinned in linux-kernel-e2e/kernels.tsv and re-verified on each run,
# cached or not. Exit 0 = every lane passed, 1 = a lane failed, 2 = usage or
# unsupported host.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATA="$ROOT/Scripts/linux-kernel-e2e"
KERNELS="$DATA/kernels.tsv"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/rv-kernel-e2e"
ACCEL=auto
BOOT_TIMEOUT="${RV_KERNEL_E2E_TIMEOUT:-300}"

say() { printf 'linux-kernel-e2e: %s\n' "$*" >&2; }
die() { say "$1"; exit "${2:-1}"; }

usage() {
  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

lanes() { grep -v '^#' "$KERNELS" | cut -f1; }

lanes_requested=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --accel) [[ $# -ge 2 ]] || usage; ACCEL="$2"; shift 2 ;;
    --cache) [[ $# -ge 2 ]] || usage; CACHE="$2"; shift 2 ;;
    --list) lanes; exit 0 ;;
    -h|--help) usage ;;
    all) while IFS= read -r lane; do lanes_requested+=("$lane"); done < <(lanes); shift ;;
    -*) usage ;;
    *) lanes_requested+=("$1"); shift ;;
  esac
done
[[ ${#lanes_requested[@]} -gt 0 ]] || usage
case "$ACCEL" in auto|kvm|tcg) ;; *) usage ;; esac
case "$BOOT_TIMEOUT" in ''|*[!0-9]*) die "RV_KERNEL_E2E_TIMEOUT must be whole seconds" 2 ;; esac

[[ "$(uname -s)" == Linux ]] \
  || die "Linux host required (QEMU guest kernels + static glibc build); this host is $(uname -s)" 2
[[ "$(uname -m)" == x86_64 ]] \
  || die "x86_64 host required (pinned guest kernels are amd64); this host is $(uname -m)" 2
for tool in qemu-system-x86_64 cc cpio ar tar readelf sha256sum curl timeout; do
  command -v "$tool" >/dev/null 2>&1 || die "missing tool: $tool" 2
done

resolve_accel() {
  local kvm_ok=0
  if [[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
    kvm_ok=1
  fi
  case "$ACCEL" in
    kvm) [[ $kvm_ok == 1 ]] || die "--accel kvm but /dev/kvm is not usable" 2
         echo kvm ;;
    tcg) echo tcg ;;
    auto) if [[ $kvm_ok == 1 ]]; then echo kvm; else echo tcg; fi ;;
  esac
}

sha_of() { sha256sum "$1" | cut -d' ' -f1; }

# Cached deb, verified against the pin every time; re-fetched on mismatch.
fetch_deb() {
  local sha="$1" url="$2" deb="$CACHE/$1.deb" part
  if [[ -f "$deb" && "$(sha_of "$deb")" == "$sha" ]]; then
    echo "$deb"
    return
  fi
  rm -f "$deb"
  part="$(mktemp "$CACHE/.download.XXXXXX")"
  say "fetching $url"
  if ! curl -fsSL --retry 3 --proto '=https' -o "$part" "$url"; then
    rm -f "$part"
    die "download failed: $url"
  fi
  if [[ "$(sha_of "$part")" != "$sha" ]]; then
    rm -f "$part"
    die "SHA-256 mismatch for $url (want $sha)"
  fi
  mv "$part" "$deb"
  echo "$deb"
}

# vmlinuz is re-extracted from the verified deb each run, never cached.
extract_vmlinuz() {
  local deb="$1" out="$2" dir found=()
  dir="$(mktemp -d "$WORK/deb.XXXXXX")" || return 1
  (cd "$dir" && ar x "$deb") || { say "ar failed on $deb"; return 1; }
  tar -xf "$dir"/data.tar* -C "$dir" || { say "tar failed on $deb"; return 1; }
  shopt -s nullglob
  found=("$dir"/boot/vmlinuz-*)
  shopt -u nullglob
  if [[ ${#found[@]} -ne 1 ]]; then
    say "expected one boot/vmlinuz-* in $deb, found ${#found[@]}"
    return 1
  fi
  mv "${found[0]}" "$out" || return 1
  rm -rf "$dir"
}

build_initramfs() {
  local stage="$WORK/initramfs" bin
  mkdir -p "$stage/bin"
  cc -static -O2 -Wall -Wextra -Werror \
    -I"$ROOT/Sources/RVIsolation/include" \
    "$ROOT/Sources/rv-isolation-exec/main.c" -o "$stage/bin/rv-isolation-exec"
  cc -static -O2 -Wall -Wextra -Werror "$DATA/guest-init.c" -o "$stage/init"
  # The initramfs has no loader or libraries; a dynamic binary cannot run.
  for bin in "$stage/init" "$stage/bin/rv-isolation-exec"; do
    if readelf -l "$bin" | grep -q 'Requesting program interpreter'; then
      die "$bin is not statically linked"
    fi
  done
  (cd "$stage" && find . -print0 | LC_ALL=C sort -z \
    | cpio --null --create --format=newc --owner=0:0 --quiet) > "$WORK/initramfs.cpio"
}

# One boot. Pass only on exactly one PASS result line from a kernel whose
# release matches the lane; a timeout, panic, or missing line is a failure.
run_lane() {
  local lane="$1" abi="$2" sha="$3" url="$4" accel="$5"
  local deb vmlinuz="$WORK/vmlinuz-$lane" log="$WORK/serial-$lane.log" status=0
  local accel_args=()
  # Called under `if !`, where set -e is off: check each step explicitly.
  deb="$(fetch_deb "$sha" "$url")" || return 1
  extract_vmlinuz "$deb" "$vmlinuz" || return 1
  if [[ "$accel" == kvm ]]; then
    accel_args=(-accel kvm -cpu host)
  else
    accel_args=(-accel tcg -cpu max)
  fi
  say "lane $lane: booting (expect Landlock ABI $abi, accel $accel)"
  timeout "$BOOT_TIMEOUT" qemu-system-x86_64 \
    -nodefaults -no-reboot -display none -monitor none -serial stdio \
    -m 512 -smp 1 "${accel_args[@]}" \
    -kernel "$vmlinuz" -initrd "$WORK/initramfs.cpio" \
    -append "console=ttyS0 panic=-1 loglevel=4 lsm=landlock rv.expect_abi=$abi" \
    < /dev/null 2>&1 | tr -d '\r' | tee "$log" || status=$?
  if [[ $status -ne 0 ]]; then
    say "lane $lane: FAIL (qemu/timeout status $status)"
    return 1
  fi
  local results
  results="$(grep -c '^rv-kernel-e2e-result: ' "$log" || true)"
  if [[ "$results" != 1 ]]; then
    say "lane $lane: FAIL ($results result lines; guest did not finish cleanly)"
    return 1
  fi
  if ! grep -Eq "^rv-kernel-e2e-result: PASS .* kernel=${lane//./\\.}\\." "$log"; then
    say "lane $lane: FAIL ($(grep '^rv-kernel-e2e-result: ' "$log"))"
    return 1
  fi
  say "lane $lane: PASS"
}

mkdir -p "$CACHE"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rv-kernel-e2e.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

ACCEL_RESOLVED="$(resolve_accel)"
build_initramfs

failed=()
for lane in "${lanes_requested[@]}"; do
  row="$(awk -F'\t' -v lane="$lane" '$1 == lane' "$KERNELS")"
  [[ -n "$row" ]] || die "unknown lane '$lane' (have: $(lanes | tr '\n' ' '))" 2
  IFS=$'\t' read -r _ abi sha url <<< "$row"
  if ! run_lane "$lane" "$abi" "$sha" "$url" "$ACCEL_RESOLVED"; then
    failed+=("$lane")
  fi
done

if [[ ${#failed[@]} -gt 0 ]]; then
  die "failed lanes: ${failed[*]}"
fi
say "all lanes passed: ${lanes_requested[*]}"
