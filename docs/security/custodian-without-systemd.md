# The Linux custodian without systemd

Status: design, not implemented. Needs the owner's security review.

`rv mcp custodian install` refuses a host whose init is not systemd.
Cloud containers and most CI containers are such hosts: PID 1 is a shell,
an agent harness or a small init such as `tini`. There the MCP gateway
has no custodian, so no MCP approvals, and `mcp.json` is never trusted
([mcp-linux-custodian.md](mcp-linux-custodian.md)). This page says what a
mode without systemd would have to keep, why it is not a small change,
and a design for it.

## Conclusion

A container mode is feasible, but not as a contained change. The two
daemons already run in the foreground (`rv-mcp-custodian serve` and
`rv-mcp-custodian presence`), and `Scripts/linux-custodian-e2e.sh` starts
them that way on hosts without systemd. What systemd adds is not the
starting but the confinement in the two units, and one piece of it holds
up a guarantee, not just defence in depth. Reproducing it means rv doing,
in its own code, what systemd does for the units: mount and network
namespaces, a capability bounding set, a system-call filter. That is new
privileged code in a root process, and in a default Docker container
(no `CAP_SYS_ADMIN`) the namespace part cannot run at all. So no code was
written for this milestone.

## What the guarantees rest on

| Guarantee | What provides it | Without systemd |
| --- | --- | --- |
| The owner's account cannot read the keys | the key daemon's own account; `/var/lib/rv-mcp-custodian` mode 0700, owned by it | kept: plain file ownership |
| Root runs only code root owns | the source checks in `install` (rv, rv-cli, rv-mcp-custodian, their libraries and loader paths) | kept: the checks are rv's, not systemd's |
| Presence means the account's PAM stack accepted a typed answer | the root helper, PAM, `SO_PEERCRED` | kept |
| A PAM factor kept in a home directory (a `pam_u2f` key file, a TOTP secret) is not honoured, since the agent could rewrite it | `ProtectHome=yes` on the helper's unit | **lost** unless rv hides the homes itself |
| The helper cannot read the keys | `InaccessiblePaths=-/var/lib/rv-mcp-custodian` | file modes still keep it out only if the helper drops `CAP_DAC_OVERRIDE`/`CAP_DAC_READ_SEARCH`, which PAM needs; so **lost** without a mount namespace |
| A compromised key daemon cannot reach the network, homes or most of the kernel | `PrivateNetwork`, `ProtectHome`, `ProtectSystem=strict`, `SystemCallFilter`, empty capability set | defence in depth, lost |
| Only the helper's own lines carry `_SYSTEMD_UNIT=rv-mcp-presence.service` in the journal | journald | lost; containers usually have no `/dev/log` at all, so the helper's `authpriv` lines go nowhere |
| A crashed daemon comes back | `Restart=on-failure` | lost unless something supervises |

The fourth row is the one that matters. On a host whose PAM stack has a
module that reads its secret from the user's home, a helper that can see
homes lets the owner's account, and so the agent, approve. systemd hides
the homes from the helper; without it, something else must.

## Who the custodian protects in a container

The custodian keeps the key from the owner's account. It protects nothing
when the agent is root, which is the common case in cloud containers
(`docs/security/mcp-linux-custodian.md`: "Root is trusted"). It is worth
running only when:

- the agent runs as an account other than root;
- the container's entry point starts the custodian, as root, before the
  agent, and the agent has no way back to root (no `sudo`, no setuid
  helpers it can use, no writable path root executes from);
- a person can type at a terminal the agent does not control, since
  presence is a typed password. A headless container has no such person,
  so there the custodian can only be tested, never used to approve.

## Design

A third subcommand, `rv-mcp-custodian supervise`, run as root by the
container's entry point, does what the two units do, and refuses to start
if any step fails:

1. Check its own binary and libraries the way `install` does (root-owned
   path, `$ORIGIN` search path), so the entry point cannot be made to run
   the owner's code as root.
2. Create `/run/rv-mcp-custodian` (owned by the custodian account, 0755),
   `/run/rv-mcp-presence` (root, 0755) and `/var/lib/rv-mcp-custodian`
   (custodian account, 0700), each only if absent or already exactly so.
3. Start the key daemon in a child that: unshares mount and network
   namespaces; mounts empty tmpfs over `/home`, `/root` and `/run/user`;
   remounts `/` read-only except its state directory; sets
   `PR_SET_NO_NEW_PRIVS`; drops to the custodian account with no
   capabilities; installs a seccomp filter equivalent to
   `@system-service ~@privileged ~@resources` with `AF_UNIX` only; then
   execs `rv-mcp-custodian serve`.
4. Start the presence helper in a child that unshares a mount namespace;
   hides `/home`, `/root`, `/run/user` and `/var/lib/rv-mcp-custodian`;
   makes `/usr`, `/boot` and `/etc` read-only; bounds capabilities to the
   unit's list; sets `PR_SET_NO_NEW_PRIVS`; installs its filter; then
   execs `rv-mcp-custodian presence`.
5. Restart a child that exits with failure, at most once a second, and
   exit when asked (SIGTERM), taking both children with it.

`rv mcp custodian install --supervised` would do the account, the copies
and the PAM file as today, write no units, and print the one command the
entry point must run. `rv mcp custodian status` would say which mode is
installed.

Parts rv already has: the source checks (`MCPCustodianSetup`), a seccomp
filter builder and the Landlock trampoline for the MCP cage
(`RVIsolation`, `rv-isolation-exec`). Parts it does not have: mount and
network namespace setup, and a supervisor.

## Where it cannot run

- **No `CAP_SYS_ADMIN`** (Docker's default, most managed CI): no mount
  namespace, so no hidden homes. `supervise` must refuse. Offering a
  weaker mode there would bring back the home-directory PAM factor hole.
- **No user `rv-mcp-custodian` can be created** (read-only `/etc`):
  refuse.
- **rv itself in another user or pid namespace than the daemons**:
  refused today, unchanged (`SO_PEERCRED` would not name the caller).

An alternative for the first case: refuse only when the PAM stack
includes a module known to read from home directories. That turns a
mount guarantee into a list of module names, which fails open for any
module not on the list. Not recommended.

## What would prove it

- `MCPCustodianSetupTests`: the supervised install plan writes no units,
  refuses without root, without a PAM stack, from an untrusted source.
- A Linux test, as root in a private mount namespace, that starts
  `supervise` and checks from inside each child: `/home` empty, the state
  directory invisible to the helper, `NoNewPrivs: 1` and the expected
  `CapBnd` in `/proc/<pid>/status`, a `socket(AF_INET)` refused in the key
  daemon, a killed child restarted.
- `Scripts/linux-custodian-e2e.sh` with a `--supervised` path in place of
  its hand-started daemons, plus a PAM stack with a home-directory module
  (`pam_exec` reading a file in the owner's home) to show that factor is
  ignored.
- `supervise` refusing in a container started without `CAP_SYS_ADMIN`.

## Not covered by this page

- macOS: the custodian there is an XPC service and needs no init system.
- Approvals in the MCP host's own prompt, which need no custodian on any
  platform.
- A headless container approving anything: with nobody to type the
  password, the custodian refuses, by design. Automated tests of the
  gateway's approvals use `Scripts/linux-custodian-e2e.sh`'s throwaway
  account with a real password.
