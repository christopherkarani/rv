# MCP server sandbox on Linux

`rv mcp serve` runs each local MCP server in a cage. On macOS the cage is a
Seatbelt profile (`MCPSandbox.profile`). On Linux it is three things,
applied by `rv-isolation-exec --confine` in the server's own process before
`exec`, from a plan built by `MCPLinuxCage` and `MCPSandbox.applyLinux`:

- **Landlock** (`Sources/RVIsolation/landlock_confine.c`) for files, TCP
  `bind` and `connect`, and what later ABIs add;
- **a seccomp socket filter** (`socket_filter.c`) for the ways onto the
  network that Landlock's rules do not cover;
- **a connector** (`proxy_connector.c`), only for a server with
  `sandbox.hosts`: the helper stays as the server's parent, outside the
  cage, and makes the server's connections to the allowlist proxy for it.

No namespaces, and nothing that needs privilege.

The cage is on wherever the kernel has Landlock ABI 4 (Linux 6.7) and
seccomp filters. There, as on macOS, every local server needs a `sandbox`
entry in `mcp.json` and runs in the cage; a server without one is refused.
On a kernel without them Linux behaves as a host without a sandbox: a
server with a `sandbox` entry is refused, with the reason; a server
without one runs uncaged, with a warning; under an organization's
`requireSandbox` no local server runs.

This page says what each mechanism closes, maps the Seatbelt profile to
Linux rule by rule, and lists what is left. The claims are measured:
`MCPLinuxSandboxTests` asserts each on the kernel it runs on, and the
pinned-kernel matrix (`Scripts/linux-kernel-e2e.sh`) asserts them on
Linux 6.8, 6.12 and 7.3, and the refusal on 5.10, 6.1 and 6.6.

## The network

Landlock's network rules cover two calls on a TCP socket, `bind` and
`connect` (ABI 4), and from ABI 10 the same for UDP. Alone they do not
keep a process off the network. Each route below reaches the network on
the kernels measured when nothing but Landlock is in the way (which ones
depends on the kernel build); the filter refuses every one of them on
every kernel:

| Route | Closed by |
| --- | --- |
| `connect` or `bind` on a TCP socket | Landlock: no port is allowed |
| An MPTCP socket (`IPPROTO_MPTCP`), which reaches any TCP server | filter: `socket` |
| UDP, ICMP, raw, SCTP and every other protocol of `AF_INET`/`AF_INET6` | filter: `socket` |
| Every other family (netlink, packet, ...) | filter: `socket` |
| `sendto`, `sendmsg`, `sendmmsg` with `MSG_FASTOPEN`, which connect without `connect` | filter |
| `listen` on a TCP socket never bound, which picks a port and accepts | filter, wherever TCP sockets can exist |
| A socket made through io_uring, which no filter on system calls sees | filter: `io_uring_setup`, `_enter` and `_register` answer `ENOSYS` |
| A 32-bit system call (`int 0x80`), whose numbers are not the filter's | filter: the process is killed; the x32 ABI answers `ENOSYS` |

`socket()` is allowed for exactly two things. A Unix socket, where
Landlock confines what it can reach (ABI 9; below it the server gets no
Unix socket at all, see "Unix sockets"). And a plain TCP socket
(`SOCK_STREAM`, protocol 0 or TCP) of `AF_INET` or `AF_INET6`, only for a
server with `sandbox.hosts`. The filter tests numbers passed in registers
(the family, type, protocol and flags), never memory a second thread
could change after the test. It is installed after Landlock and
`NO_NEW_PRIVS`, is inherited by everything the server starts, and cannot
be removed. If it cannot be installed the helper exits 125 and nothing
runs.

So a server with `network: false` and no hosts has no internet socket of
any kind and nothing to connect one with.

### A server with `sandbox.hosts`

Such a server may reach one place: rv's allowlist proxy, which listens on
`127.0.0.1` on a port chosen per launch and asks for a credential the
server is given. Landlock can name a port in a rule but not an address,
so a rule for the proxy's port would allow that port on every host, and a
server written to get out would connect to a machine that listens on it.
rv therefore gives Landlock no port at all, and the server never carries
out a `connect` on an internet socket itself:

1. the helper starts the server as its child and stays, outside the
   cage, as its connector;
2. the filter hands each `connect` the cage makes to the connector (a
   seccomp user notification) and the caller waits;
3. the connector takes its own copy of the caller's socket
   (`pidfd_getfd`). If it is not an internet socket the call is handed
   back to the kernel, where Landlock decides it. Otherwise the connector
   reads the address asked for, answers `EACCES` unless it is the proxy's
   port on a loopback address, and else connects the socket itself, to
   `127.0.0.1` and the proxy's port (`::ffff:127.0.0.1` for an IPv6
   socket), and answers with that call's result.

The address the server asked for is used only to refuse. The connection
that is made is the connector's, to an address the connector chose, so a
server that rewrites the address after it was read gains nothing. A
server that swaps the descriptor for an internet socket after the
connector saw a Unix one gets the kernel's own `connect`, which Landlock
refuses.

What follows from the connector being the server's parent:

- The gateway holds the connector. It exits with the server's status, or
  dies of the signal the server died of. SIGTERM, SIGINT, SIGHUP and
  SIGQUIT sent to it are passed on; half a second after a SIGTERM it
  kills a server that is still there, and a server whose connector is
  killed is killed with it (`PR_SET_PDEATHSIG`).
- A process the server leaves behind when it exits has no connector, and
  its `connect` calls fail.
- The connector needs `/proc` and must be allowed to copy a descriptor
  from the server: `kernel.yama.ptrace_scope` 0 or 1 (the default on
  Ubuntu and Debian is 1), or 2 when the gateway runs as root. Where it
  is not allowed, a server with `sandbox.hosts` is not started and the
  helper says why; servers without hosts are not affected.
- Calls are answered one at a time.
- A program inside the cage that installs a seccomp filter with its own
  notification listener gets `EBUSY`.

### Unix sockets

Landlock confines Unix sockets in two steps: abstract sockets from ABI 6,
pathname sockets from ABI 9. Until both hold, a Unix socket could reach
whatever listens on a socket the user may open: the D-Bus session bus (and
through it the Secret Service and `systemd --user`, which runs commands
outside the cage), an SSH or GPG agent, a container daemon. So below ABI 9
the filter refuses `socket(AF_UNIX)`, and `socketpair` gives only a
stream or sequenced-packet pair, which stays connected to itself (a
datagram pair can be sent from to any address). From ABI 9 the server has
Unix sockets, reaches the ones it or its children make in its own
directories, and reaches no socket another program made outside the
scratch directory and `sandbox.writable`.

## What it needs

- Landlock ABI 4 or later: Linux 6.7 or later with Landlock enabled. rv
  asks the kernel for its ABI
  (`landlock_create_ruleset(NULL, 0, LANDLOCK_CREATE_RULESET_VERSION)`); it
  never reads the kernel version.
- seccomp filters (`CONFIG_SECCOMP_FILTER`), asked of the kernel the same
  way (`SECCOMP_GET_ACTION_AVAIL`).
- `rv-isolation-exec` beside the rv binary (the installer puts it there).
- x86-64 or arm64.

On a kernel with no Landlock, an ABI below 4, or no seccomp filters there
is no cage: `rv mcp serve` refuses every server that asks for a sandbox,
naming what is missing, and never runs one uncaged. Where the helper is
missing or cannot report, the host should have a cage and cannot say so:
every local server is refused. The helper checks again in the server's
process and exits 125 without running the server if any step fails, so a
server that runs is a server that was caged. A server whose `env` sets a
variable the dynamic loader acts on (`LD_*`, `GLIBC_TUNABLES`) is refused:
the loader would act on it in the helper, before the cage.

## The Seatbelt profile, rule by rule

| Seatbelt | What it does | Landlock on Linux |
| --- | --- | --- |
| `(allow default)` | Everything not denied below is allowed: reads, exec, process and IPC operations. | Landlock only grants. Reads and exec are granted on every path except the protected ones (next rows). Operations Landlock does not mediate stay allowed. |
| `(deny file-write*)` then `(allow file-write* ...)` | Writes only beneath the scratch directory, the temp directory, `/dev`, `~/.npm`, `~/.cache`, `~/Library/Caches`, and `sandbox.writable`. | The same list with Linux paths: `~/.cache/rv-mcp/<server>` (scratch and working directory), `/tmp`, `/dev`, `~/.npm`, `~/.cache`, `sandbox.writable`. Each gets every file right Landlock has beneath it (device `ioctl` on none, and reaching another program's socket only in the scratch directory and `sandbox.writable`); nothing else can be written, truncated, created, removed or renamed. A file cannot be hard-linked or renamed out of an unreadable directory into a writable one. Mode, owner and times are not file rights to Landlock: see the limits. |
| `(deny file-read* file-write* <stores>)` | No read of credential stores (`~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.kube`, `~/.docker`, `~/.config/gh`, `~/.config/gcloud`, `~/.azure`, keychains, browser profiles, `~/.netrc`, `~/.npmrc`, `~/.pypirc`), of other hosts' MCP configuration (`~/.claude.json`, `~/.codex`, `~/.cursor`, ...), or of rv's own configuration directory. | The same list, plus where Linux keeps what macOS has under `~/Library` or in the Keychain: `~/.local/share/keyrings`, `~/.local/share/kwalletd`, `~/.password-store`, `~/.git-credentials`, `~/.config/google-chrome`, `~/.config/chromium`, `~/.mozilla`, `~/.config/BraveSoftware`, `~/snap/firefox`, `~/snap/chromium`, `~/.var/app` (Flatpak), `~/.config/Claude`, `~/.claude/.credentials.json`, `~/.config/containers/auth.json`, `~/.Xauthority`, `~/.config/git/credentials`, `~/.vault-token`, and the session's runtime directory `/run/user/<uid>` (container and X authority files; the sockets in it are never reachable). Landlock cannot deny beneath an allowed directory, so rv grants everything *beside* each protected path instead, at every level from `/` down. |
| symlink denies | A store that is a symlink is denied at its target too. | Each protected path is protected as spelled and as resolved. Rules attach to directories opened without following links, and a link itself is never granted: access through one is checked where it leads. |
| `(deny network*)` | No sockets at all: TCP, UDP, Unix. | No internet socket of any kind can be made, and no Unix socket below ABI 9 (see "The network"). From ABI 9 a Unix socket reaches only what is in the server's own directories. |
| `(allow network-outbound (remote tcp "localhost:<port>"))` | With `sandbox.hosts`, the allowlist proxy's port only. | The same: plain TCP sockets, connected by rv's connector to the proxy on `127.0.0.1` and nowhere else. A connection asked for to the proxy's port on any loopback address (`127.0.0.2`, `::1`) is made to `127.0.0.1`. |
| (none) | Seatbelt does not set it. | `NO_NEW_PRIVS`: a setuid or file-capability binary gives the server nothing. |
| (none) | | From ABI 5 the server cannot `ioctl` a device it opens (a terminal's `TIOCSTI`, for one); descriptors it inherits are not affected. From ABI 6 it cannot signal a process outside its cage or connect to an abstract Unix socket outside it. A caged process may trace, or read the memory and environment of, only processes in its own cage. |

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
- `TMPDIR` must be `/tmp` or inside it. A server cannot connect to a
  socket another program created in `/tmp`, `/dev` or the caches.
- No Unix sockets below ABI 9: no `syslog`, no D-Bus, no X11, and a
  server that talks to its own child over a named Unix socket does not
  work there (a `socketpair` or a pipe does).
- No netlink: a server cannot list the host's network interfaces
  (`getifaddrs`, Node's `os.networkInterfaces()`), and no UDP: it cannot
  ask a DNS server itself. With `sandbox.hosts` names are resolved by
  the proxy.
- io_uring is reported as not supported, which runtimes fall back from.
  A 32-bit program is killed at its first system call.
- With `sandbox.hosts` a server cannot `listen` on any socket, and its
  parent process is rv's connector.
- A terminal or other device the server opens itself cannot be controlled
  with `ioctl` from ABI 5, so it cannot allocate a pseudo-terminal.
- A file or directory beside a protected one and named after it is not
  readable either. "Named after" means its name contains the protected
  name, for a name with a dot or other punctuation or of five characters
  or more; a short plain one (`gh`) only as a whole word. So `.netrc.tmp`,
  `.git-credentialsXXXXXX` and `gh.bak` are unreadable, and so are
  unrelated things in the home directory such as `~/.dockerignore`,
  `~/.cursorrules`, `~/.cursor-server`, `~/.ssh-agent`,
  `~/.config/gh-dash` or `~/.config/google-chrome-beta`. The same names
  inside a project are not affected.
- The session's runtime directory (`/run/user/<uid>`) is not readable,
  `/run` cannot be listed, and what appears in `/run` after the server
  started is not readable. Where `/run/user` itself cannot be listed (a
  service run with systemd's `ProtectHome=yes`), every server is refused.
- A home with more than 16,384 entries beside the protected paths, or
  more than 1 MiB of their names, is refused.

## Known limits

rv handles every Landlock right it knows (through ABI 10) that the running
kernel has, and when it starts a server on a kernel that leaves one of
the first two rows open it writes one line to stderr saying so.

| Not blocked | Until | Consequence |
| --- | --- | --- |
| Signals to other processes | ABI 6 (Linux 6.12) | The server can signal the user's other processes. |
| `ioctl` on device files the server opens | ABI 5 (Linux 6.10) | Terminal and device control on `/dev` nodes, including typing into the user's terminal where `dev.tty.legacy_tiocsti` is on. From ABI 5 it is denied on every device, so a server cannot allocate a pseudo-terminal (`grantpt` fails) or drive a GPU, camera or sound device. |
| Mode, owner and times of any file the user owns | no ABI | Landlock does not mediate `chmod`, `chown`, `utimes` or extended attributes. A server cannot read `~/.ssh/id_ed25519`, but it can make it world-readable for another local account, or take the owner's own access away. |
| Everything in `/tmp` and `/dev` | no ABI | Both are write roots, as on macOS. Other programs' temporary files the user may open (a Kerberos ticket cache `/tmp/krb5cc_<uid>`), `/dev/shm`, and other sessions' terminals in `/dev/pts` (the server can write text to them). |
| A protected file that has another name | no ABI | Rules follow files, not names. A hard link to a key that already exists in a readable directory, or a bind mount of a store, is readable; the server cannot make such a link itself. A file that was beside a protected one when the server started and is then renamed over it (how many programs save) is readable for the rest of the server's life: rv does not grant a neighbour named after a protected file (`.git-credentials.lock`, `.netrcAbCdEf`), but a temporary file with an unrelated name is granted. |
| Other processes' command lines | no ABI | `/proc/<pid>/cmdline` is world-readable. |
| User namespaces, kernel keyrings, System V and POSIX IPC | no ABI rv handles | Not mediated by the rights rv applies. A user namespace gives the server no access the cage denies, and no socket the filter refuses. |
| A program outside the cage that hands the server a socket | no ABI | From ABI 9 a program outside can connect to a socket the server listens on in its own directories and pass it a descriptor. That needs a helper outside the cage, which the server cannot start. |
| Root | no ABI | A gateway run as root gives servers `CAP_PERFMON`, which lets them read other processes' environments and memory maps despite Landlock, and lets them open the block devices in `/dev`, a write root. Do not run `rv mcp serve` as root. |
| A request too large to start | n/a | The readable-path list is bounded at 16,384 paths and 1 MiB, but with a very large environment or a small stack limit the kernel can still refuse the helper's arguments. The server then fails to start with a generic error, not this one. |

Limits of the mechanism rather than of what it blocks:

- **Hosts that forbid the connector.** `kernel.yama.ptrace_scope` 2 (for
  a gateway that is not root) or 3, a missing `/proc`, or a container
  runtime that filters `pidfd_getfd`, `process_vm_readv` or seccomp
  notifications: servers with `sandbox.hosts` are not started there.
- **The proxy is the allowlist.** What a server can reach through it
  (the hosts listed, by name) is the proxy's rule, the same code as on
  macOS.
- **arm64 has not been run.** The filter is written for x86-64 and
  arm64; every test and every kernel lane ran on x86-64.

## Evidence

- `MCPLinuxCageTests`: the ABI table, what the helper's report means
  (no Landlock, too old, no seccomp filters, a helper that fails), which
  hosts require a cage, loader variables, the readable-path walk
  (including random trees: no grant ever covers a protected path) and its
  bounds, writable conflicts, the helper's arguments.
- `MCPLinuxSandboxTests` (real kernel, as root and as a user): credential
  stores and rv's configuration unreadable directly, through a link, and
  at a link's target; writes confined; every route in the table above
  refused in the cage where the same script succeeds outside it, with no
  hosts and with them; with hosts, the proxy reached (blocking, not
  blocking, from 24 threads at once, from an IPv6 socket where the host
  has IPv6) and the proxy's port on another address of the host, on
  another port and on an IPv6 address refused with `EACCES`; the server's
  exit status, a signal that kills it, SIGTERM passed on, a server that
  ignores SIGTERM killed, a server killed with its connector;
  `NO_NEW_PRIVS` and a setuid binary; other processes unreadable; another
  program's pathname, abstract and datagram Unix sockets never reached,
  the server's own from ABI 9; signals and device `ioctl` open or closed
  as the table says for the kernel's ABI; `chmod` of a protected file
  allowed; a loader variable refused; every other refusal; a Node server
  started by `npx` (through the proxy) and a Python server completing the
  MCP handshake in the cage.
- `Scripts/linux-kernel-e2e.sh`: the helper on pinned kernels. 5.10, 6.1
  and 6.6 (ABI none, 2, 3) refuse and run nothing; 6.8 (ABI 4), 6.12
  (ABI 6) and 7.3 (ABI 11) enforce. Each lane checks that every route
  works outside the cage and is refused inside it, with a port and
  without; that the listed port is reached on loopback and refused on
  another address of the guest; Unix sockets per ABI; an exit status
  through the connector.
- `Scripts/linux-custodian-e2e.sh` runs its fixture server in the cage.
- Not asserted by a test: the refusal where the host forbids the
  connector (asserted only by a test that needs
  `kernel.yama.ptrace_scope` 3, run in the Actions job that sets it; the
  pull request says whether it has passed), a container runtime's
  filter, a Go server (the reason for `SECCOMP_FILTER_FLAG_WAIT_KILLABLE_RECV`),
  hard links, bind mounts, and a rename over a protected file. ABI 5 has
  no lane of its own (6.8 is ABI 4, 6.12 is ABI 6); ABI 9 and 10
  behaviour is checked on the 7.3 guest (ABI 11).
