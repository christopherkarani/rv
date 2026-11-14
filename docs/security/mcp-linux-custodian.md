# The approvals key custodian on Linux

rv's MCP gateway rests on one key. With it rv signs three things: that
`mcp.json` (and the tool definitions pinned from it) is what the owner
reviewed, that a paused tool call was approved, and the records the
gateway keeps while a call waits. If the agent could use that key, it
could write its own `mcp.json` and approve its own calls.

On macOS the key sits in the data-protection keychain behind a custodian
process. Linux has no such store, so until now the key was a file the
agent could read, and rv refused to trust anything signed with it. The
custodian described here holds the key where the agent cannot reach it and
signs only when the owner is present.

Install it with `sudo rv mcp custodian install`. Without it, Linux behaves
as before: no MCP approvals, and `mcp.json` is never trusted.

## The property

A process running as the owner's account, without the owner's login
password, cannot obtain

- a grant for a tool call, or
- a signature over `mcp.json` or the tool pins,

and cannot make an old one count again. It can read and write every file
the owner can, run any program, and talk to the custodian itself.

## The parts

```
 owner's terminal        rv (owner's uid)            root                 rv-mcp-custodian (system account)
 ───────────────         ────────────────        ─────────────           ───────────────────────────────────
                         rv mcp trust/approve
                           │  key request  ──────────────────────────────▶  key daemon
                           │  ◀──────────────── presence required            /run/rv-mcp-custodian/custodian.sock
                           │  challenge?  ───────────────────────────────▶  keys + ledgers in
                           │  ◀──────────────── challenge c                  /var/lib/rv-mcp-custodian (0700)
   Password: ****  ◀──────▶│  prove(c) ───────▶ presence helper
                           │  ◀─ prompts ─────  /run/rv-mcp-presence/presence.sock
                           │  ── answers ────▶  PAM (service rv-mcp-custodian)
                           │                    attest(c, uid) ───────────▶  unlocks the connection that holds c
                           │  key request  ──────────────────────────────▶  signs
```

- **The key daemon** (`rv-mcp-custodian serve`) runs as the system account
  `rv-mcp-custodian`. It holds one key and one ledger per account
  (`/var/lib/rv-mcp-custodian/u<uid>/`), in a directory only it can enter.
  It never runs as root, and refuses to start if it is. It identifies each
  connection by `SO_PEERCRED`: requests act on the peer's own key, and
  nothing in a request can name another account.
- **The presence helper** (`rv-mcp-custodian presence`) runs as root,
  because checking another account's password needs it. It authenticates
  the connection's peer (again `SO_PEERCRED`, never a name in the request)
  with PAM, service `rv-mcp-custodian`, which includes the distribution's
  own `auth` and `account` stacks. Each conversation is its own
  single-threaded process, so PAM modules never share an address space
  with another account's conversation. If PAM succeeds, the helper tells
  the key daemon; the key daemon accepts that only from a peer whose uid is
  0.
- **rv** connects to both at fixed paths under `/run`, in directories only
  root can create, and checks each peer's uid: the key daemon must be the
  `rv-mcp-custodian` account, the helper must be root. There is no
  environment variable or configuration that moves the paths, because the
  agent could set it and point rv at a custodian of its own.

## What needs the owner, and what does not

| Operation | Needs presence | Why |
| --- | --- | --- |
| `status`, `verify` | no | Verifying is not a way to make a signature. `rv mcp serve` verifies with no terminal. |
| sign a **grant** | yes | It says the owner approved this call. |
| sign **`mcp.json`** or the **tool pins** | yes | It says this is what the owner reviewed. Every rv write of `mcp.json` signs. |
| sign a pending call's **confirmation code** and **argument names** | no | `rv mcp serve` makes these, unattended, when a call asks. See below. |

The last row is a decision the project's owner should confirm. On macOS
every use of the key prompts, the gateway's included, because the prompt
is a system dialog that needs no terminal. On Linux the gateway has no
terminal to ask on, so if these needed presence no call could ever be
recorded for approval. The cost: the agent can ask the key daemon for
these two signatures itself and so fabricate a pending request, with a
confirmation code it chose. What that buys it is nothing more than making
the same call through the gateway would: `rv mcp approve` shows the owner
the request's server, tool, argument names and argument digest, the grant
signs exactly those, and the gateway runs only a call that matches them.
On Linux the confirmation code therefore proves nothing against the agent;
the password does.

## Presence

A signature that needs the owner is refused with `presenceRequired`
unless the connection asking has been unlocked. To unlock it:

1. rv asks the key daemon for a challenge: 32 random bytes, remembered for
   that connection for 120 seconds. A new challenge replaces the old.
2. rv gives the challenge to the presence helper, which runs PAM for the
   peer's account. PAM's prompts travel to rv, which shows them on the
   controlling terminal and returns what the owner types (no echo for a
   secret). rv never sees whether the answer was right; the helper does.
3. If PAM authenticates the account, the account is valid
   (`pam_acct_mgmt`), and the owner was asked for at least one answer, the
   helper sends `attest(challenge, uid)` to the key daemon.
4. The key daemon unlocks the one connection that holds that challenge, if
   its peer is that uid and the challenge has not expired. The challenge is
   then gone, whatever the outcome.

An unlocked connection may make up to 16 signatures in the next 30
seconds: enough for `rv mcp trust` to sign `mcp.json` and the pins after
one password. The unlock belongs to the connection, which belongs to the
process that asked; another process of the same account is not unlocked.

rv asks for presence in the place each command already asks for it:
`rv mcp approve` after the confirmation code, `rv mcp trust` and
`rv mcp import` after the review is shown. The password prompt comes
after the review, never before.

**No terminal, no signature.** A process with no controlling terminal (an
agent's shell, `rv mcp serve`, a service) cannot be asked, so rv refuses
before it contacts the helper. An agent that gives itself a
pseudo-terminal gets a prompt it cannot answer.

**A PAM stack that asks nothing proves nothing.** An account with an empty
password, or a stack that accepts without a prompt, is refused
(`nothingAsked`). This also refuses a stack that authenticates by
fingerprint alone, which asks for no typed answer; the owner should
confirm whether to accept that.

## Rollback and replay

Every signature the custodian issues is `v1.<counter>.<hmac>`. The counter
is per account, only rises, is made durable before the signature is
returned, and is inside the HMAC together with the scope (the rv
configuration directory, resolved) and the caller's fields.

- **`mcp.json` and the pins.** The ledger keeps, per file, the counter of
  its newest signature. An older `mcp.json` put back together with its old
  signature verifies under the key but is not the newest: it is reported
  as not matching. So is a signature for the same content in another
  configuration directory.
- **Grants.** A grant verifies once. The gateway's verification is what
  uses it, and that use is recorded before the answer is given. A granted
  row copied aside and put back after the call ran does not run it again.
  At most 256 grants are outstanding per account; the oldest gives way.
- **Presence.** A challenge is single-use and expires; an attestation
  names the uid and is accepted only from root's connection.

The wire protocol is versioned (`rv.mcp-custodian.socket.v1`, checked in a
hello before anything else is answered), every message is one
length-prefixed JSON frame of at most 512 KiB, and the key requests inside
are the same `MCPCustodianRequest` values the macOS custodian takes, under
the same bounds. Nothing in it is Linux-specific: the macOS custodian can
issue `v1` signatures and keep the same ledger. A bare 64-hex signature
(what macOS issues today) is never accepted by the Linux custodian.

## Why PAM behind a root helper

| Option | Verdict |
| --- | --- |
| **PAM, run by a root helper** (this) | Uses the host's own authentication policy (lockout, password quality, a second factor if the stack has one). Needs a root process, kept to one job. |
| polkit (`CheckAuthorization` with `auth_self`) | The prompt would come from the desktop's own agent, which is a better place to type a password. But it needs a session with a polkit agent (none over SSH or on a server), a D-Bus client in the custodian, and a non-root caller may not ask polkit about another account's process. Worth adding as a second presence method on desktops. |
| `sudo`/`pkexec` running an attest command | No PAM code of rv's own. But what it proves is "this account may become root now", which depends on sudoers: a cached timestamp or a `NOPASSWD` rule passes with nobody present, and an account that is not a sudoer cannot approve at all. |
| the key daemon reads `/etc/shadow` itself (group `shadow`) | One process instead of two, no root. Works only where `shadow` is group-readable (Debian, Ubuntu), only for local passwords, and gives the process that holds every key the password hashes too. |
| `unix_chkpwd` run by rvd, as rv's other owner checks do | rvd runs as the owner. Its verdict is one the agent's account produces, so it cannot gate a key the agent must not use. |
| a prompt in the owner's session (a code, a click) with no secret | Anything the owner's account can show or press, the agent can. |

## What `install` does

`sudo rv mcp custodian install`, in order, each step printed and written
to the system log (`authpriv`):

1. creates the system account `rv-mcp-custodian` (no home, no shell);
2. copies `rv-mcp-custodian` from beside rv to
   `/usr/local/libexec/rv/rv-mcp-custodian`, owned by root, so the
   services never run a file the owner's account can change;
3. writes `/etc/pam.d/rv-mcp-custodian`, which includes `common-auth` and
   `common-account`, or `system-auth`;
4. writes `rv-mcp-custodian.service` and `rv-mcp-presence.service`, then
   enables and (re)starts them.

It refuses, changing nothing, when it is not root, when systemd is not the
init system, when the binary is missing, when the host has neither PAM
stack, or when one of those files exists and was not written by rv.
Running it again replaces the binary and files and restarts the services.

`sudo rv mcp custodian uninstall` stops and disables the units and removes
the unit files, the PAM file and the binary. The keys stay in
`/var/lib/rv-mcp-custodian`; `--purge` deletes them and the account, which
voids every grant and signature. Removing what is already gone succeeds.

The key daemon's unit: its own user, an empty capability set,
`NoNewPrivileges`, `PrivateNetwork`, `PrivateDevices`, `ProtectSystem=strict`,
`ProtectHome=yes` (it cannot see any home), only `AF_UNIX`, a system-call
filter, and state it alone can enter. The helper's unit: root with a
capability set bounded to what PAM modules use, `NoNewPrivileges`,
`ProtectSystem=full`, read-only homes, no namespaces.

`sudo rv ...` runs the rv binary as root. If rv is installed where the
owner's account can write (`~/.local/bin`), check it before you do.

## Known limits

- **The password can be stolen.** The owner types it into a terminal their
  own account controls. A process of that account can replace the `rv`
  the owner runs, read the terminal, or (with `kernel.yama.ptrace_scope`
  at 0) trace the shell, and so learn the password and answer the next
  prompt itself. This is the limit `sudo` has. The agent cannot approve
  without the owner ever typing a password where it can see; it can after.
- **An unlocked connection can be driven by a tracer.** With
  `ptrace_scope=0`, a process of the account can inject requests into the
  owner's running `rv` during its 30-second window. Ubuntu and Debian
  default to 1, which prevents it for processes that are not rv's
  ancestors.
- **What is signed is what rv asked for.** The custodian signs fields; it
  does not show them. The review the owner reads is drawn by rv, running
  as the owner. A replaced `rv` could show one thing and ask for a
  signature over another.
- **Pending requests can be fabricated** (see the table above).
- **Fingerprint-only and passwordless accounts cannot approve.**
- **Root is trusted.** Root can read the keys, attest presence, and put
  back an old ledger. Whoever has passwordless sudo is root.
- **Denial of service by the owner's account.** It can use up a grant by
  verifying it, hold its eight connections, or start a presence
  conversation so that the owner's is told `busy` (one at a time per
  account, eight in all, each at most 150 seconds).
- **One prompt, several signatures.** Within its window an unlocked
  connection signs up to 16 requests of any kind for that account.
- **No key rotation or backup.** A lost `/var/lib/rv-mcp-custodian` means
  trusting `mcp.json` again; there is no export.
- **systemd only.** Hosts with another init system are refused by
  `install`. No SELinux or AppArmor policy is shipped.
- **Not verified here:** the units under a running systemd other than the
  GitHub runner's; a PAM stack other than `pam_unix` (SSSD, LDAP, U2F).

## Evidence

- `CustodianSocketServiceTests`: frames and their bounds, every message's
  encoding, the counter format; who may ask what (nothing before a hello,
  only root attests, root asks for nothing else); presence (which purposes
  need it, the window, its uses, one connection only, a challenge used
  once by its own account before it expires); rollback (an older signed
  file, a grant used twice); storage failures sign and verify nothing.
- `CustodianSocketClientTests` (Linux): the client over real sockets
  against the real service and key store: no terminal, a wrong answer, no
  answer, every helper refusal, a daemon or helper that is the wrong
  account, a socket that is not there.
- `MCPCustodianSetupTests`: the install and uninstall plans, every
  refusal, the units' confinement lines.
- `Scripts/linux-custodian-e2e.sh` (root): the real daemons, real PAM and
  a throwaway account with a password. As that account, on a pty and
  without one: trust refused without a terminal and with a wrong password,
  granted with the right one after the review; the gateway serving with no
  terminal; a tool that asks, approved with code and password, run once,
  not run again, not run from a replayed grant; a rolled-back `mcp.json`
  untrusted; a raw client refused a grant, an `mcp.json` signature and its
  own attestation; the audit chain. In CI it installs through
  `rv mcp custodian install` under systemd, checks the units are active,
  and uninstalls.
