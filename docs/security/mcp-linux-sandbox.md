# MCP server sandbox on Linux

`rv mcp serve` runs each local MCP server in a cage. On macOS the cage is a
Seatbelt profile (`MCPSandbox.profile`). On Linux it is Landlock, applied by
`rv-isolation-exec --confine` in the server's own process before `exec`
(`Sources/RVIsolation/landlock_confine.c`), from a plan built by
`MCPLinuxCage` and `MCPSandbox.applyLinux`. Landlock only: no seccomp filter
and no namespaces.

This page maps the Seatbelt profile to Landlock rule by rule and lists what
Landlock does not cover. The limits are measured, not assumed:
`MCPLinuxSandboxTests` asserts each one on the kernel it runs on, and the
pinned-kernel matrix (`Scripts/linux-kernel-e2e.sh`) asserts them on Linux
6.6, 6.8, 6.12 and 7.3.

## What it needs

- Landlock ABI 4 or later: Linux 6.7 or later with Landlock enabled. ABI 4
  is the first with network rules. rv asks the kernel for its ABI
  (`landlock_create_ruleset(NULL, 0, LANDLOCK_CREATE_RULESET_VERSION)`); it
  never reads the kernel version.
- `rv-isolation-exec` beside the rv binary (the installer puts it there).

Without either, `MCPSandbox.enforced` is false and `rv mcp serve` refuses
every server that asks for a sandbox, naming what is missing: an ABI below
4, no Landlock, or the helper. It never runs one uncaged. The helper checks
the ABI again in the server's process and exits 125 without running the
server if any step fails, so a server that runs is a server that was caged.

## The Seatbelt profile, rule by rule

| Seatbelt | What it does | Landlock on Linux |
| --- | --- | --- |
| `(allow default)` | Everything not denied below is allowed: reads, exec, process and IPC operations. | Landlock only grants. Reads and exec are granted on every path except the protected ones (next rows). Operations Landlock does not mediate stay allowed. |
| `(deny file-write*)` then `(allow file-write* ...)` | Writes only beneath the scratch directory, the temp directory, `/dev`, `~/.npm`, `~/.cache`, `~/Library/Caches`, and `sandbox.writable`. | The same list with Linux paths: `~/.cache/rv-mcp/<server>` (scratch and working directory), `/tmp`, `/dev`, `~/.npm`, `~/.cache`, `sandbox.writable`. Each gets every file right beneath it; nothing else is writable, truncatable, creatable, removable or renameable. A file cannot be hard-linked or renamed out of an unreadable directory into a writable one. |
| `(deny file-read* file-write* <stores>)` | No read of credential stores (`~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.kube`, `~/.docker`, `~/.config/gh`, `~/.config/gcloud`, `~/.azure`, keychains, browser profiles, `~/.netrc`, `~/.npmrc`, `~/.pypirc`), of other hosts' MCP configuration (`~/.claude.json`, `~/.codex`, `~/.cursor`, ...), or of rv's own configuration directory. | The same list, plus where Linux keeps what macOS has under `~/Library`: `~/.local/share/keyrings`, `~/.config/google-chrome`, `~/.config/chromium`, `~/.mozilla`, `~/.config/BraveSoftware`, `~/.config/Claude`. Landlock cannot deny beneath an allowed directory, so rv grants everything *beside* each protected path instead, at every level from `/` down. |
| symlink denies | A store that is a symlink is denied at its target too. | Each protected path is protected as spelled and as resolved. Rules attach to directories opened without following links, and a link itself is never granted: access through one is checked where it leads. |
| `(deny network*)` | No sockets at all: TCP, UDP, Unix. | TCP `bind` and `connect` are denied on every port (ABI 4). The rest depends on the kernel; see the limits. |
| `(allow network-outbound (remote tcp "localhost:<port>"))` | With `sandbox.hosts`, the allowlist proxy's port only. | `connect` is allowed to the proxy's port and no other. Landlock rules name a port, not an address. |
| (none) | Seatbelt does not set it. | `NO_NEW_PRIVS`: a setuid or file-capability binary gives the server nothing. |
| (none) | | From ABI 6, the server cannot signal a process outside its cage or connect to an abstract Unix socket outside it. A caged process may trace, or read the memory and environment of, only processes in its own cage. |

The environment is the same on both: `PATH`, `HOME`, `TMPDIR`, `LANG`,
`LC_*`, the server's own `env` and secrets, and the proxy variables when
`sandbox.hosts` is set.

## Differences in what a caged server sees

- A directory that holds a protected path cannot be listed: `/`, `/home`,
  the home directory, `~/.config`. Their entries are reachable by name
  (`stat`, `open`), and everything beside the protected paths is readable.
- A file or directory created beside a protected path after the server
  started is not readable until the server restarts.
- `sandbox.writable` must exist and must not be a symlink, and cannot be
  `/`, a directory that holds a protected path, or a path inside one: rv
  refuses the server, because Landlock would then expose the store.
- `TMPDIR` must be `/tmp` or inside it.
- A home with more than 16,384 entries beside the protected paths is
  refused.

## Known limits

Landlock closes these one ABI at a time. rv applies every right the running
kernel has, and when it starts a server it writes one line to stderr naming
what that kernel does not block.

| Not blocked | Until | Consequence |
| --- | --- | --- |
| `ioctl` on device files the server can open | ABI 5 (Linux 6.10) | Terminal and device control on `/dev` nodes. |
| Abstract Unix sockets; signals to other processes | ABI 6 (Linux 6.12) | The server can reach an abstract socket (an X server, an old session bus) and signal the user's other processes. |
| Connecting to pathname Unix sockets | ABI 9 | The server can talk to whatever listens on a socket the user may open: the D-Bus session bus (and through it the Secret Service and `systemd --user`, which will run commands outside the cage), an SSH or GPG agent, a container daemon. This is the counterpart of Mach services on macOS, which `(allow default)` leaves reachable. |
| UDP | ABI 10 | A server whose policy is `network: false` or `sandbox.hosts` can still send and receive UDP to any address, DNS included. **On kernels before ABI 10 "no network" means "no TCP".** |
| Sockets that are neither TCP, UDP nor Unix | no ABI | ICMP echo sockets (where `net.ipv4.ping_group_range` allows them, the default on most distributions), SCTP, and other families an unprivileged process may open. |
| The allowlist port on other hosts | no ABI | With `sandbox.hosts`, the server may connect to the proxy's port number on any address, not only loopback. The port is random per launch; a remote host listening on it is reachable. |
| Other processes' command lines | no ABI | `/proc/<pid>/cmdline` is world-readable. |
| Root | no ABI | A gateway run as root gives servers `CAP_PERFMON`, which lets them read other processes' environments and memory maps despite Landlock. Do not run `rv mcp serve` as root. |

`MCPLinuxCage.networkFloor` is the lowest ABI a server with a network
policy runs under. It is ABI 4, the project's decision for this release:
the limits above are disclosed rather than refused. Setting it to ABI 10
makes rv refuse every caged server on a kernel that cannot block UDP.

## Evidence

- `MCPLinuxCageTests`: the ABI table, admission, the readable-path walk
  (including random trees: no grant ever covers a protected path), writable
  conflicts, the helper's arguments.
- `MCPLinuxSandboxTests` (real kernel, as root and as a user): credential
  stores and rv's configuration unreadable directly, through a link, and
  at a link's target; writes confined; no TCP out or in; only the proxy's
  port with an allowlist; `NO_NEW_PRIVS` and a setuid binary; other
  processes unreadable; each limit above open or closed as this page says
  for the kernel's ABI; every refusal.
- `Scripts/linux-kernel-e2e.sh`: the helper on pinned kernels. 5.10, 6.1 and
  6.6 (ABI none, 2, 3) refuse and run nothing; 6.8 (ABI 4), 6.12 (ABI 6)
  and 7.3 enforce, with the channels each ABI closes checked per lane.
