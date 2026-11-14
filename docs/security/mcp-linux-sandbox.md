# MCP server sandbox on Linux

`rv mcp serve` runs each local MCP server in a cage. On macOS the cage is a
Seatbelt profile (`MCPSandbox.profile`). On Linux the cage is Landlock,
applied by `rv-isolation-exec --confine` in the server's own process before
`exec` (`Sources/RVIsolation/landlock_confine.c`), from a plan built by
`MCPLinuxCage` and `MCPSandbox.applyLinux`. Landlock only: no seccomp filter
and no namespaces.

**In this release the Linux cage is built and tested but not switched on.**
Landlock cannot keep a process off the network (see "The network limit"),
every sandbox policy limits the network, and rv does not start a server
under a limit it cannot hold. So `MCPLinuxCage.networkLimit` is `.refuse`:
Linux behaves as a host without a sandbox. A server with a `sandbox` entry
is refused, with the reason; a server without one runs uncaged, with a
warning; under an organization's `requireSandbox` no local server runs.
Switching it on is one constant, and a decision for the project's owner.
While it is off, `rv mcp check` and a refusal say only that; they do not
suggest a newer kernel or a reinstall, which would change nothing.

This page maps the Seatbelt profile to Landlock rule by rule and lists what
Landlock does not cover. The limits are measured, not assumed:
`MCPLinuxSandboxTests` asserts each one on the kernel it runs on, and the
pinned-kernel matrix (`Scripts/linux-kernel-e2e.sh`) asserts the ones an
ABI closes on Linux 6.6, 6.8, 6.12 and 7.3.

## The network limit

Landlock's network rules cover two calls on a TCP socket, `bind` and
`connect` (ABI 4), and from ABI 10 the same for UDP. A caged process
reaches the network without either. Which route is open depends on the
kernel build, by patch level as well as version:

| Route | 6.8.0 (ABI 4) | 6.12.0 (ABI 6) | 6.18.44-fc (ABI 7) | 7.3.0 (ABI 11) |
| --- | --- | --- | --- | --- |
| `connect` on an MPTCP socket (`IPPROTO_MPTCP`), which reaches any TCP server | denied | denied | open | open |
| `sendto` with `MSG_FASTOPEN` on a TCP socket, which connects without `connect` | open | open | open | denied |
| the same on an MPTCP socket | open | open | open | open |
| `listen` on a socket never bound, which picks a port and accepts | open | open | open | open |
| UDP to any address | open | open | open | denied |

These are exact builds: 6.18.44-fc (a vendor build) is the host
`MCPLinuxSandboxTests` ran on; the others are the mainline `.0` guests of
`Scripts/linux-kernel-e2e.sh`, which print each TCP route's result and
fail unless `listen` without `bind` and one of the three others get
through. Do not read a column as "the 6.8 series": the same harness, run
during review on Ubuntu 24.04's 6.8.0-151 and on stable 6.12.30, found
MPTCP `connect` open on both and TCP fast open denied on the first.
Every build measured leaves `listen` without `bind` open, and, where
MPTCP and TCP fast open are both enabled (the defaults), at least one way
out by TCP. With either switched off, a build that denies the other
leaves `listen`, the sockets that are neither TCP nor UDP (ICMP echo was
measured open on all four builds, with `net.ipv4.ping_group_range` opened
as most distributions ship it; SCTP was not measured) and, before ABI 10,
UDP.

So `network: false` and `sandbox.hosts` cannot be enforced against a
server that means to get out, and a server with `sandbox.hosts` can go
around the allowlist proxy. The rules do stop a server that only uses
ordinary TCP. The choices, for the owner:

1. **Refuse** (this release, `MCPLinuxCage.networkLimit = .refuse`). No
   server runs under a network limit rv cannot hold. Linux has no MCP
   server sandbox; file confinement is not used either.
2. **Disclose** (`.disclose`). Servers run with the file cage, which holds,
   and the TCP `connect`/`bind` rules; each start prints what the kernel
   leaves open. "No network" then means "no ordinary TCP".
3. **Close the gap with a second mechanism.** A seccomp filter on
   `socket(2)` (allow `AF_UNIX`, and `AF_INET`/`AF_INET6` stream sockets
   with protocol 0 or TCP only when the policy has `hosts`; deny
   `sendto`/`sendmsg` with `MSG_FASTOPEN` and `listen`) would make the
   limit hold. It is outside "Landlock only".

Everything below describes the cage as it runs under choice 2, which is
how the tests and the kernel matrix run it.

## What it needs

- Landlock ABI 4 or later: Linux 6.7 or later with Landlock enabled. rv
  asks the kernel for its ABI
  (`landlock_create_ruleset(NULL, 0, LANDLOCK_CREATE_RULESET_VERSION)`); it
  never reads the kernel version.
- `rv-isolation-exec` beside the rv binary (the installer puts it there).

On a kernel with no Landlock, or an ABI below 4, there is no cage:
`rv mcp serve` refuses every server that asks for a sandbox, naming what
is missing, and never runs one uncaged. Where the helper is missing or
cannot report the ABI, the host should have a cage and cannot say so: every
local server is refused. The helper checks the ABI again in the server's
process and exits 125 without running the server if any step fails, so a
server that runs is a server that was caged. A server whose `env` sets a
variable the dynamic loader acts on (`LD_*`, `GLIBC_TUNABLES`) is refused:
the loader would act on it in the helper, before the cage.

## The Seatbelt profile, rule by rule

| Seatbelt | What it does | Landlock on Linux |
| --- | --- | --- |
| `(allow default)` | Everything not denied below is allowed: reads, exec, process and IPC operations. | Landlock only grants. Reads and exec are granted on every path except the protected ones (next rows). Operations Landlock does not mediate stay allowed. |
| `(deny file-write*)` then `(allow file-write* ...)` | Writes only beneath the scratch directory, the temp directory, `/dev`, `~/.npm`, `~/.cache`, `~/Library/Caches`, and `sandbox.writable`. | The same list with Linux paths: `~/.cache/rv-mcp/<server>` (scratch and working directory), `/tmp`, `/dev`, `~/.npm`, `~/.cache`, `sandbox.writable`. Each gets every file right Landlock has beneath it (device `ioctl` on none, and reaching another program's socket only in the scratch directory and `sandbox.writable`); nothing else can be written, truncated, created, removed or renamed. A file cannot be hard-linked or renamed out of an unreadable directory into a writable one. Mode, owner and times are not file rights to Landlock: see the limits. |
| `(deny file-read* file-write* <stores>)` | No read of credential stores (`~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.kube`, `~/.docker`, `~/.config/gh`, `~/.config/gcloud`, `~/.azure`, keychains, browser profiles, `~/.netrc`, `~/.npmrc`, `~/.pypirc`), of other hosts' MCP configuration (`~/.claude.json`, `~/.codex`, `~/.cursor`, ...), or of rv's own configuration directory. | The same list, plus where Linux keeps what macOS has under `~/Library` or in the Keychain: `~/.local/share/keyrings`, `~/.local/share/kwalletd`, `~/.password-store`, `~/.git-credentials`, `~/.config/google-chrome`, `~/.config/chromium`, `~/.mozilla`, `~/.config/BraveSoftware`, `~/snap/firefox`, `~/snap/chromium`, `~/.var/app` (Flatpak), `~/.config/Claude`, `~/.claude/.credentials.json`, `~/.config/containers/auth.json`, `~/.Xauthority`, `~/.config/git/credentials`, `~/.vault-token`, and the session's runtime directory `/run/user/<uid>` (container and X authority files; the sockets in it stay connectable before ABI 9). Landlock cannot deny beneath an allowed directory, so rv grants everything *beside* each protected path instead, at every level from `/` down. |
| symlink denies | A store that is a symlink is denied at its target too. | Each protected path is protected as spelled and as resolved. Rules attach to directories opened without following links, and a link itself is never granted: access through one is checked where it leads. |
| `(deny network*)` | No sockets at all: TCP, UDP, Unix. | `bind` and `connect` on a TCP socket are denied on every port (ABI 4). That is not "no TCP": see "The network limit". |
| `(allow network-outbound (remote tcp "localhost:<port>"))` | With `sandbox.hosts`, the allowlist proxy's port only. | `connect` is allowed to the proxy's port and no other. Landlock rules name a port, not an address. |
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
- `TMPDIR` must be `/tmp` or inside it. From ABI 9 a server cannot connect
  to a socket another program created in `/tmp`, `/dev` or the caches.
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
kernel has, and when it starts a server it writes one line to stderr naming
what that kernel does not block.

| Not blocked | Until | Consequence |
| --- | --- | --- |
| TCP by a route the rules miss: MPTCP, fast open, `listen` without `bind` | no ABI closes them all | See "The network limit". |
| Sockets that are neither TCP, UDP nor Unix | no ABI | ICMP echo sockets (where `net.ipv4.ping_group_range` allows them, the default on most distributions), SCTP, and other families an unprivileged process may open. |
| UDP | ABI 10 | UDP to and from any address, DNS included. |
| Connecting to pathname Unix sockets | ABI 9 | The server can talk to whatever listens on a socket the user may open: the D-Bus session bus (and through it the Secret Service and `systemd --user`, which will run commands outside the cage), an SSH or GPG agent, a container daemon, rv's own daemon socket. This is the counterpart of Mach services on macOS, which `(allow default)` leaves reachable. From ABI 9 a socket another program made is reachable only in the scratch directory and `sandbox.writable`, not in `/tmp`, `/dev`, `~/.npm` or `~/.cache`; the server still reaches sockets it makes itself. |
| Abstract Unix sockets; signals to other processes | ABI 6 (Linux 6.12) | The server can reach an abstract socket (an X server, an old session bus) and signal the user's other processes. |
| `ioctl` on device files the server opens | ABI 5 (Linux 6.10) | Terminal and device control on `/dev` nodes, including typing into the user's terminal where `dev.tty.legacy_tiocsti` is on. From ABI 5 it is denied on every device, so a server cannot allocate a pseudo-terminal (`grantpt` fails) or drive a GPU, camera or sound device. |
| Mode, owner and times of any file the user owns | no ABI | Landlock does not mediate `chmod`, `chown`, `utimes` or extended attributes. A server cannot read `~/.ssh/id_ed25519`, but it can make it world-readable for another local account, or take the owner's own access away. |
| Everything in `/tmp` and `/dev` | no ABI | Both are write roots, as on macOS. Other programs' temporary files and sockets the user may open (a Kerberos ticket cache `/tmp/krb5cc_<uid>`, before ABI 9 an X11, tmux or agent socket), `/dev/shm`, and other sessions' terminals in `/dev/pts` (the server can write text to them). |
| A protected file that has another name | no ABI | Rules follow files, not names. A hard link to a key that already exists in a readable directory, or a bind mount of a store, is readable; the server cannot make such a link itself. A file that was beside a protected one when the server started and is then renamed over it (how many programs save) is readable for the rest of the server's life: rv does not grant a neighbour named after a protected file (`.git-credentials.lock`, `.netrcAbCdEf`), but a temporary file with an unrelated name is granted. |
| The allowlist port on other hosts | no ABI | With `sandbox.hosts`, the server may connect to the proxy's port number on any address, not only loopback. The port is random per launch; a remote host listening on it is reachable. |
| Other processes' command lines | no ABI | `/proc/<pid>/cmdline` is world-readable. |
| User namespaces, kernel keyrings, System V and POSIX IPC | no ABI rv handles | Not mediated by the rights rv applies. A user namespace gives the server no access the cage denies. |
| Root | no ABI | A gateway run as root gives servers `CAP_PERFMON`, which lets them read other processes' environments and memory maps despite Landlock, and lets them open the block devices in `/dev`, a write root. Do not run `rv mcp serve` as root. |
| A request too large to start | — | The readable-path list is bounded at 16,384 paths and 1 MiB, but with a very large environment or a small stack limit the kernel can still refuse the helper's arguments. The server then fails to start with a generic error, not this one. |

## Evidence

- `MCPLinuxCageTests`: the ABI table, admission under both answers to the
  network limit, which hosts require a cage, loader variables, the
  readable-path walk (including random trees: no grant ever covers a
  protected path) and its bounds, writable conflicts, the helper's
  arguments.
- `MCPLinuxSandboxTests` (real kernel, as root and as a user): the default
  refusal; credential stores and rv's configuration unreadable directly,
  through a link, and at a link's target; writes confined; TCP `connect`
  and `bind` denied where the same script succeeds uncaged; `listen`
  without `bind` open in the cage, at least one of MPTCP and TCP fast open
  too where the host has both, and no route open in the cage that is not
  open outside it; only the
  proxy's port with an allowlist; `NO_NEW_PRIVS` and a setuid binary; other
  processes unreadable; Unix sockets, signals, UDP and device `ioctl` open
  or closed as the table says for the kernel's ABI; `chmod` of a protected
  file allowed; a loader variable refused; every other refusal; a Node
  server started by `npx` and a Python server completing the MCP handshake
  in the cage.
- `Scripts/linux-kernel-e2e.sh`: the helper on pinned kernels. 5.10, 6.1 and
  6.6 (ABI none, 2, 3) refuse and run nothing; 6.8 (ABI 4), 6.12 (ABI 6)
  and 7.3 (ABI 11) enforce, with the channels each ABI closes checked per
  lane.
- Not asserted by a test: ICMP sockets (measured by hand on the four
  builds above) and SCTP (not measured), the proxy's port on a
  non-loopback address, hard links, bind mounts, and a rename over a
  protected file. ABI 5 has no lane of its own (6.8 is ABI 4, 6.12 is ABI
  6); a GitHub runner's kernel may be one.
