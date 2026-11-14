# Linux kernel e2e

`Scripts/linux-kernel-e2e.sh` boots pinned Linux kernels under QEMU and runs
the real `rv-isolation-exec` trampoline on each one. CI runs it in
[`linux-kernel-e2e.yml`](../../.github/workflows/linux-kernel-e2e.yml). That
workflow is not a required check.

## What is kernel-dependent on Linux

Production Linux never runs a contained command. `prepareLandlock`
(`Sources/RVIsolation/LandlockApply.swift`) returns
`containedGuaranteesUnsupported` for every contained plan, and `spawn`
refuses any Landlock request before exec. Neither one asks the kernel
anything, so the host `swift test` run covers that refusal on any kernel.

The only Linux enforcement that depends on the kernel is the trampoline
(`Sources/rv-isolation-exec/main.c` plus
`Sources/RVIsolation/landlock_apply.c`). It closes inherited descriptors,
sets `NO_NEW_PRIVS`, requires Landlock ABI 3 or later, grants read and write
beneath the workspace, then execs. On any failure it exits 125 without exec.
ABI 1 and 2 are refused because they cannot handle `TRUNCATE`.

## Lanes

| Lane | Landlock | What the guest asserts |
| --- | --- | --- |
| 5.10 | none (ENOSYS) | valid argv exits 125, inner never runs, no write or truncate outside |
| 6.1 | ABI 2 | same refusal: no downgrade to a ruleset without TRUNCATE |
| 6.6 | ABI 3 (the floor) | enforcement (below); MCP confinement refuses |
| 6.8 | ABI 4 | enforcement; MCP confinement (below) |
| 6.12 | ABI 6 | enforcement; MCP confinement |
| 7.3 | ABI 11 | enforcement; MCP confinement |

Enforcement means that inside the workspace, write, read and mkdir succeed.
Outside it, write, read, readdir, mkdir and truncate fail with `EACCES`. A
workspace symlink pointing outside is denied, and so is a rename out of the
workspace. The inner sees `NO_NEW_PRIVS`. An fd opened outside before the
boundary is closed (`EBADF`). A missing inner exits 126.

Execing a binary outside the workspace also exits 126. Landlock needs
`READ_FILE` to exec a file, and the ruleset grants that only beneath the
workspace because there is no system read-only layer yet. So the guest runs
its probe from a copy inside the workspace. Once a read-only system layer
lands, the `exec-outside-workspace-denied` check is meant to flip.

The ABI 3+ lanes also check the argv lock (no arguments, a relative inner,
a missing `--`), a missing workspace and a non-canonical (symlinked)
workspace. Each must exit 125 and never exec. The 5.10 and 6.1 lanes skip
those cases: below ABI 3 the trampoline exits 125 for every argv, so they
could not tell the argv lock from the ABI refusal. Those lanes prove only the
refusal. The host script pins the exact number of checks each regime runs (7
below ABI 3, 23 at ABI 3, 43 from ABI 4), so a dropped case fails the lane.
The guest compares the live Landlock ABI with the lane's expected ABI, so a
kernel that boots with Landlock disabled fails its lane instead of quietly
testing the wrong regime. The kernel command line passes `lsm=landlock` so
the regime comes from the kernel version, not from the distro's LSM list.

## MCP server confinement

`rv-isolation-exec --confine` (the cage `rv mcp serve` puts each local MCP
server in; [mcp-linux-sandbox.md](mcp-linux-sandbox.md)) needs Landlock ABI
4. Below it (the 5.10, 6.1 and 6.6 lanes) a valid request exits 125 and the
inner never runs. From ABI 4 the guest checks, with listeners it holds
outside the cage: a read and a write inside the granted paths succeed and
outside them fail with `EACCES`; `NO_NEW_PRIVS` is set; a TCP connection is
refused without a port rule, accepted on the listed port and refused on
another; a floor above the kernel's ABI, or below 4, exits 125 and runs
nothing. A shared directory (`--temp`) is writable. Five channels are
checked against the lane's ABI, open below the ABI that closes them and
closed from it on: `ioctl` on a device the inner opens (`EACCES` from ABI
5), an abstract Unix socket and a signal to PID 1 (`EPERM` from ABI 6), a
pathname Unix socket outside the write roots or in a shared one (`EACCES`
from ABI 9; one in the inner's own write root stays reachable), and a UDP
datagram (`EACCES` from ABI 10). So 6.8 shows all five open, 6.12 two, and
7.3 none. A socket the inner makes itself in a shared directory, and one
another program made in a write root nested inside a shared directory
(where the scratch directory is), stay reachable on every lane. Two more
checks hold on every lane from ABI 4, and are why a network limit is
refused ([mcp-linux-sandbox.md](mcp-linux-sandbox.md)): `listen` on a
socket never bound succeeds, and at least one of an MPTCP `connect`, TCP
fast open and MPTCP fast open reaches a listener with no port rule. The
guest prints which (`INFO tcp-routes`).

## Image route

Each guest is a pinned kernel plus a tiny initramfs. The initramfs holds two
static binaries built from the checkout: the trampoline, and
`Scripts/linux-kernel-e2e/guest-init.c` running as PID 1. There is no distro
userland. A cloud image would tie the userland's glibc to the kernel age (a
5.10-era image cannot run binaries built on 24.04) and would add a rootfs
download plus cloud-init boot time. The binaries are static because a
Landlocked inner cannot read shared libraries outside the workspace.

The kernels are Ubuntu mainline builds (upstream source with Ubuntu's generic
config). [`kernels.tsv`](../../Scripts/linux-kernel-e2e/kernels.tsv) pins
each `.deb` by SHA-256, cross-checked against the build's `CHECKSUMS` when it
was pinned. The script checks the hash on every run, cached or not.

## Running locally

On an x86_64 Linux host with `qemu-system-x86_64`, `cc` with static glibc
(`libc6-dev`), `cpio`, `binutils` and `curl` installed:

```sh
Scripts/linux-kernel-e2e.sh all        # or: 5.10 6.1 6.6 6.8 6.12 7.3
Scripts/linux-kernel-e2e.sh --accel tcg 6.12
```

The script uses KVM when `/dev/kvm` is readable and writable, and falls back
to TCG otherwise. Downloads are cached under `~/.cache/rv-kernel-e2e`. On
macOS, or on a non-x86_64 host, the script exits 2 with "Linux host
required" or "x86_64 host required".

To add a lane, append a row to `kernels.tsv` and to the workflow matrix.
