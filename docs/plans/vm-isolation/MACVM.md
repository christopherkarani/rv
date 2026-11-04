# macOS guest VMs for rv contained launches

Status: in progress (2026-11-02). Follows the Linux micro-VM backend (PR #480).

## Decisions (user)

- Built directly on Virtualization.framework. No tart: it is OpenAI-owned and FSL-1.1 ("Competing Use").
- Unattended image setup with `VZMacGuestProvisioningOptions` (macOS 27 SDK). Guests must be macOS 27 or later.

## Shape

```
rv workspace run --macvm NAME [--cpus N] [--memory-mib M] -- CMD
  └─ supervisor (unchanged path: volume, PTY claim, proxy, secrets, publish)
       └─ rv-macvm run --image NAME --workspace W --relay-port P ... -- CMD
            ├─ APFS clone of images/NAME/{disk.img, aux.img}; fresh machine identifier
            ├─ VZVirtualMachine: no network device, virtiofs tag "rvws" = W,
            │  virtio-socket, Mac graphics (headless), entropy
            ├─ handshake written once clone + config are valid (before boot; boot ≈ 30 s,
            │  the supervisor's establish deadline is 45 s)
            ├─ vsock listener per relay port P → host 127.0.0.1:P (BridgeBudget)
            └─ vsock → guest port 1024: rv-macvm-agent (LaunchDaemon, root)
                 ├─ mount_virtiofs rvws W
                 ├─ guest 127.0.0.1:P → vsock host:P   (per relay port)
                 └─ ssh rv@127.0.0.1 (root-only key, pinned host key)
                      → guest sshd (Remote Login holds Full Disk Access, which
                        TCC requires for the virtiofs share)
                      → forced command `rv-macvm-agent session`: PTY child as rv,
                        under sandbox-exec with workspaceControlDenies(W) plus a
                        deny of localhost:22
```

Guest values travel as `RV_GUEST_<NAME>` in `rv-macvm`'s environment, exactly as with `rv-microvm`, and reach the agent inside the exec request over vsock. They are never written to disk or put in argv.

`rv-macvm prepare --image NAME [--ipsw PATH|URL] [--disk-gib N] [--replace]`:
1. Fetches the IPSW: a path, a URL, or Apple's latest supported image.
2. Installs it with `VZMacOSInstaller`.
3. First boot, with a NAT network device attached for this boot only. Provisions user `rv` with a random password that is held only in memory, with SSH on.
4. Over one SSH session (password via `SSH_ASKPASS` env and `sudo -S` stdin), installs the agent and its LaunchDaemon from a virtiofs share. Creates the session key, pins the guest's host key, and installs the `sshd` drop-in (key-only, `rv@127.0.0.1`, forced command). Turns off Spotlight indexing, sleep and automatic updates, then shuts down.
5. Writes `image.json` (hardware model, OS build, agent sha256). The password is discarded, so the guest user has no usable sudo.

## Guarantees (verified on a macOS 27.2 guest)

- **No network interface.** Only relayed ports, through rv's credentialed egress proxy.
- **Workspace only.** The guest sees the workspace and no other host path. Writes go to the private volume and publish on close.
- **Control paths.** Seatbelt inside the guest denies `.git/hooks`, `.git/config`, `.rv` and `.config/rv`, and denies creating or deleting `.git`/`.config`. Absent paths are covered without placeholders.
- **Disposable clone.** It is deleted when the run ends, and nothing persists between runs.
- **Concurrency.** Apple allows at most two macOS guests per host. A third gets a clear refusal (exit 125).

## Not guaranteed

- No admission broker in the guest.
- A user image is not vetted beyond rv's own `prepare`.
- The guest user shares the per-runtime proxy credential.
- The guest boots macOS: about 30 s cold, and roughly 26 GB of IPSW plus about 25 GB of disk per image.

## Work items

- [x] Core (`RVMicroVMCore`): framed agent protocol, run options, layout and `image.json`. The guest Seatbelt profile is built by rv (`macOSGuestSandboxProfile`) from `workspaceControlDenies`. Unit tests.
- [x] `RVMacVMAgent` library + `rv-macvm-agent`: session (exec, PTY, resize, signals, exit), relay listener, virtiofs mount. Host tests over socketpair.
- [x] `rv-macvm`: `prepare`, `status`, `run` (clone, VM config, vsock relays, exec bridge, teardown, two-guest refusal).
- [x] Main package: `MicroVMLaunchOptions.guest` (`linux` | `macOS`), helper selection, `--macvm` CLI, status check (no automatic 26 GB prepare).
- [x] Release: build and sign `rv-macvm` (virtualization entitlement) and the agent, release assets, installer. The existing PR job and `gate.sh` already run the `Packages/rv-microvm` suites.
- [x] Docs: runtime-boundary section.
- [x] Real-guest proof on macOS 27.2 (26B123): `Scripts/macvm-proof.sh` runs the `RV_MACVM_E2E=1` suite. It covers no NIC and no default route, sshd unreachable from the command, workspace read and publish, proxy 200 and anonymous 407, control-file denies, cancel teardown, and unprepared fail-closed.
