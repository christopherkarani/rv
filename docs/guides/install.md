# Install and first run

This guide puts rv on one machine, wires it into the agents already there,
and takes you from watching (observe mode) to enforcing. It ends with how
to remove rv again.

How this was checked: every command and flag below was run with `--help`
on a Linux build of this branch, and the Linux outputs shown were captured
from that build. The installer was read, not run against a release (see
"Release status"). macOS-only parts (Keychain, RVApprovals.app, Touch ID,
the judge weights) were taken from the source and have not been run.

## Release status: read this first

- The newest published release is **v0.2.2** (18 November 2026). It is
  **not signed**: its macOS binaries carry no Developer ID signature, and
  it has no `SHA256SUMS.sig`.
- The guides describe the code on the release branch, which may be ahead
  of v0.2.2. `curl … | sh` installs the newest published release.
- Signature checking is wired but switched off. `install.sh` checks every
  download against the release's `SHA256SUMS`. It does **not** yet check
  `SHA256SUMS` itself against rv's release key (the key is not pinned in
  the script), and on macOS an unsigned binary only warns. On Linux the
  installer says so on every install:

  ```text
  rv: warning: release signatures are not verified on Linux yet; downloads are checked only against this release's SHA256SUMS
  ```

  [SECURITY.md](../../SECURITY.md#release-integrity) shows how to check a
  release by hand once it is signed.

## Requirements

| | macOS | Linux |
| --- | --- | --- |
| OS | macOS 15 or later | x86_64 or aarch64 with **glibc 2.35 or later** (Ubuntu 22.04+, Debian 12+, Fedora 36+, RHEL/Rocky/Alma 10+). musl (Alpine) is refused. |
| Hardware | Apple Silicon (arm64) only | x86_64 or aarch64 |
| Runtime directory | none | `rvd` keeps its socket in `$XDG_RUNTIME_DIR`, or `/run/user/<uid>` when that is unset. A login manager (logind) makes `/run/user/<uid>`. On a host with none (containers, WSL without systemd, `su`/`sudo -u` logins) it must exist, owned by you, mode 0700, or `XDG_RUNTIME_DIR` must name such a directory, for `rvd` and for your agents. Only root can create it: `sudo install -d -m 0755 /run/user && sudo install -d -m 0700 -o $(id -u) /run/user/$(id -u)`. `/run` is usually a tmpfs, so make it again after a reboot or container restart. |
| Libraries | none extra | libcurl and libsqlite3 (the installer names the package for your distribution) |
| Storing secret values | the login Keychain | `secret-tool` (package `libsecret-tools`), a D-Bus session bus and an unlocked keyring (GNOME Keyring, KWallet, KeePassXC) |
| `rv run` | as shipped | kernel 5.9 or later, and `rv-isolation-exec` beside `rv` (the installer puts it there) |
| Caged MCP servers (`sandbox`) | Seatbelt, as shipped | **kernel 6.7 or later with Landlock** (ABI 4) and seccomp filters; tested on x86-64 only |
| MCP trust and approvals | RVApprovals.app, installed by the installer | systemd, PAM, and `sudo rv mcp custodian install` (see below) |
| Owner checks (`rv host mode … off`, `rv uninstall`, `rv allow-once`) | Touch ID or your password | your login password; the account needs a local password |

To check a Linux machine before you start:

```bash
getconf GNU_LIBC_VERSION
```

```bash
uname -r
```

An account with no usable password (an SSH-key-only cloud user, root in a
container) cannot pass rv's owner check: `passwd -S` shows `L` or `NP`
for it. rv says so instead of prompting. Give the account a password
(`sudo passwd $USER`) if you need to approve owner actions on it.

## Install

The installer writes only to your home directory (`~/.local/bin`, and on
macOS `~/Applications` and `~/.config/rv/models`), then runs `rv setup`.

```bash
curl -fsSL https://rykanv.com/install | sh
```

To start in observe mode (recommended for the first days):

```bash
curl -fsSL https://rykanv.com/install | RV_INSTALL_MODE=observe sh
```

The URL above is the one the README gives; it is expected to serve the
repository's `install.sh`. You can also download `install.sh` from the
release page and run `sh install.sh` yourself.

Installer settings, all environment variables:

| Variable | Effect |
| --- | --- |
| `RV_INSTALL_MODE` | `observe` runs `rv setup --observe`; `enforce` or unset runs `rv setup`. Any other value is refused before anything is downloaded. |
| `RV_INSTALL_VERSION` | Pin a release tag instead of the latest. |
| `RV_INSTALL_NO_MODELS=1` | macOS: skip the on-device judge weights (about 649 MB). |
| `RV_INSTALL_SKIP_LINUX_CHECKS=1` | Skip the glibc and library probes. Use only if you know the machine qualifies. |
| `RV_INSTALL_SKIP_CHECKSUMS=1` | Skip the `SHA256SUMS` check. Do not use this. |
| `RV_INSTALL_ALLOW_UNSIGNED=1` | Install files that fail the signature rules once those are switched on. |

What it does, in order:

1. Refuses anything but macOS 15+ on arm64 or Linux on x86_64/aarch64
   (`rv: macOS 15 Apple Silicon, or Linux aarch64/x86_64`).
2. On Linux, stops when `XDG_RUNTIME_DIR` is unset, it is not run as
   root, `/run/user/<uid>` does not exist, and you cannot write to
   `/run/user` (so `rvd` could not create it either), and prints the root
   command that makes it. It refuses musl, glibc older than 2.35, or a missing libcurl or
   libsqlite3, before downloading anything, and prints the package
   command for Debian/Ubuntu, Fedora/RHEL, openSUSE and Arch.
3. Downloads the release's files and checks each against `SHA256SUMS`.
4. Puts `rv`, `rv-cli`, `rvd` and `rv-workspace-host` in `~/.local/bin`,
   plus on Linux `rv-isolation-exec`, the Swift runtime libraries and,
   when the release has it, `rv-mcp-custodian`; on macOS
   `~/Applications/RVApprovals.app` when the release has it, and the judge
   weights. Files are staged first, so a failed copy leaves the previous
   install intact.
5. Runs `rv setup` (or `rv setup --observe`).

On macOS the installer also checks that rv's executables, the Swift
runtime dylib and RVApprovals.app carry rv's Developer ID signature, and
asks Gatekeeper (`spctl`) whether Apple notarized each of them but the
dylib. (The packs bundle and other downloads are covered by the signed
`SHA256SUMS`.) A bare binary cannot carry a stapled notarization
ticket, so Gatekeeper looks the ticket up online: a Mac that cannot reach
Apple (offline, or behind a proxy that blocks Apple's notarization
service) is refused with `Gatekeeper does not accept <file> as notarized`.
`RV_INSTALL_ALLOW_UNSIGNED=1` does not skip this check; install while the
Mac can reach Apple.

Make sure `~/.local/bin` is on your `PATH`.

## What `rv setup` does and asks

```text
rv setup [--force] [--observe] [--json] [--robot] [--plain] [--no-color]
```

Plain `rv setup` asks you nothing. It:

- finds the agents ("hosts") already on the machine and writes rv's hook
  into each one's config. Hosts rv knows: Claude Code, Codex, Cursor,
  Grok, OpenCode, Pi, Hermes, OpenClaw, Antigravity and Muse. Hosts that
  are not installed are skipped. `--force` replaces a hook slot another
  tool occupies and keeps a `*.bak` copy;
- installs and starts the daemon `rvd`, which every hook asks:
  - macOS: a LaunchAgent, `dev.rv.evaluate`;
  - Linux with a systemd user manager: the user unit
    `dev.rv.evaluate.service`, kept running (`Restart=always`);
  - Linux without one (WSL without systemd, containers, OpenRC/runit):
    it starts `rvd` directly and tells you it will not survive logout or
    reboot, and what to add to your shell profile
    (`rv service start >/dev/null`). When `XDG_RUNTIME_DIR` is unset and
    `/run/user/<uid>` is missing and only root can create it, it starts nothing, wires no hook, and
    prints the root command that makes the directory;
- **macOS only:** registers RVApprovals.app as the LaunchAgent
  `dev.rv.mcp-custodian` when the app is in `~/Applications`.

`rv setup --observe` stores `guard.mode: observe` before it wires any
hook. If rv is already enforcing on a wired host, that is a loosening, so
it asks for owner authentication first. Under an organization policy that
pins enforcement it refuses.

### Key custody: where rv keeps what an agent must not reach

rv runs as you, and so does your agent. Anything rv keeps in a file you
can read, the agent can read too. So rv keeps two kinds of things outside
your files:

| What | macOS (from source, not run) | Linux |
| --- | --- | --- |
| Secret **values** (`rv secrets set`) | the Keychain, service `rv.secrets` | the Secret Service keyring through `secret-tool`; the hook guard refuses an agent's own `secret-tool` and Secret Service D-Bus calls |
| The MCP **approvals key** (signs `mcp.json`, tool pins and approvals) | the data-protection keychain behind RVApprovals.app; using it asks for Touch ID or your password | a system service you install once with `sudo rv mcp custodian install`; signing asks for your login password at your terminal |

`rv setup` does not install the Linux custodian. Without it the MCP
gateway does nothing useful on Linux: `mcp.json` is never trusted and
`rv mcp serve` starts no servers (see [the MCP gateway guide](mcp-gateway.md#before-you-start-the-approvals-key)).

To install it on Linux (needs systemd and PAM): the custodian will not
install from a directory your account can write, because root would then
run whatever the agent left there. Copy rv into a root-owned directory
and install from there:

```bash
sudo cp -R ~/.local/bin /opt/rv
```

```bash
sudo /opt/rv/rv mcp custodian install
```

```bash
rv mcp custodian status
```

The full threat model is in
[docs/security/mcp-linux-custodian.md](../security/mcp-linux-custodian.md).
Releases before v0.2.2 do not ship `rv-mcp-custodian`.

### Owner authentication

Commands that weaken rv ask for proof that you, not the agent, are at the
keyboard: `rv host mode <host> observe|off`, `rv uninstall`,
`rv allow-once`, `rv packs enable|disable`, `rv safety`, `rv allowlist`,
and others. On macOS that is Touch ID or your password; on Linux it is
your login password, checked by `rvd` with the system's `unix_chkpwd`.
Five wrong passwords in ten minutes lock checks for ten minutes. Every
attempt is an `owner.action` record in the audit log.

When `rvd` is not running, rv confirms at the terminal instead, and only
when stdin and stdout are both a terminal. From a script or an agent's
shell you get, for example:

```text
rv: rvd is not running, so your password cannot be checked by rvd. Confirming locally instead.
rv: set rv to observe for claude needs you at an interactive terminal while rvd is down (stdin and stdout must both be a terminal). Run it yourself in a terminal, or repair rvd with `rv setup`.
rv host mode failed: device-owner authentication required
```

## Check that it works

Run these yourself, in your own terminal, not through the agent.

```bash
rv test 'git reset --hard'
```

```text
{"decision":"deny","pack_id":"core.git","reason":"git reset --hard destroys uncommitted changes","rule_id":"core.git:reset-hard","schema":"rv.test.v1"}
```

`rv test` exits 1 for a deny and 0 for an allow. It evaluates the command;
it never runs it.

```bash
rv doctor
```

`rv doctor` checks the service, every host's hook, the packs and the
config, and prints a `fix:` line for each problem. Exit status is
non-zero when something is wrong. A machine where rv was not set up looks
like this (Linux, abridged):

```text
  Service
  ◦  not installed  unavailable
                    dev.rv.evaluate · launch-agent missing · local packs ready
                    fix: run ~/.local/bin/rv setup

  Hosts
  ◦  Claude       absent-file
                  fix: rv setup
  ◦  Codex        missing
  ...
  Packs
    core.filesystem · core.git · system.disk
    extras off

  Problems
  ◦  rvd not found at ~/.local/bin/rvd; hooks have no daemon to ask
     fix: reinstall rv (curl -fsSL https://rykanv.com/install | sh)
```

`missing` means that agent is not installed; `absent-file` means it is
installed and rv's hook is not in its config yet. After a good setup the
service reads as running and each installed host as wired. `rv doctor
--json` gives the same as a JSON document for scripts.

```bash
rv host list
```

```text
antigravity  block  missing
claude  block  absent-file
codex  block  missing
...
```

Each line is a host, its effective mode (`block`, `observe` or `off`) and
its hook wiring. `rv service status` says whether `rvd` is running
(`state=down` when it is not).

## Observe first, then enforce

Observe mode lets every call run and records what rv would have blocked.
It is the safe way to learn what rv will refuse in your team's workflow.

1. Install with `RV_INSTALL_MODE=observe`, or run `rv setup --observe`.
2. Use your agents normally for a few days.
3. Review what would have been blocked:

   ```bash
   rv blocks
   ```

   Observed rows carry `"observed": true` and `"would_be": "deny"` or
   `"ask"` in `rv blocks --json` (an `observed` column in text), and
   `"session"`, the agent session id, when the host sent one (a
   `session=` column in text). In the audit log they are
   `command.observed` records.
4. Ask why any one of them would block:

   ```bash
   rv explain 'terraform destroy'
   ```

5. Enforce, one host at a time. A stored `block` outranks the global
   observe mode, and tightening needs no owner check:

   ```bash
   rv host mode claude block
   ```

   Or, to enforce everywhere at once, edit `~/.config/rv/config.json`
   yourself and change `"guard": {"mode": "observe"}` (what `rv setup
   --observe` wrote) to `"guard": {"mode": "enforce"}`. Any host you set
   with `rv host mode` keeps its own mode.

What observe never relaxes: while `rvd` runs, rv's own protection stays
enforced (an agent's attempts to weaken rv, and access to rv's config
directory). When `rvd` is absent, an observe host lets calls run
unchecked and unlogged, with a notice on stderr; an enforcing host blocks
them. An organization gate pins enforce and `rv setup --observe` refuses
under one.

### Observe and a stopped `rvd`

`"guard.mode": "observe"` logs would-be verdicts without
blocking, so you can measure before you enforce. `rv host mode
<host> observe` does the same for one host (`off` unwires it); `rv
blocks` marks what observe would have blocked with `"observed": true`.
`rv setup --observe` (or `RV_INSTALL_MODE=observe` for the installer)
starts there. Observe never relaxes rv's own protection (rv admin
commands, rv's config) while `rvd` is running. Because an idle observe
host lets a call through when `rvd` is absent, observe also raises the
bar on the common ways to stop or replace `rvd`: `launchctl`/`systemctl`
stops of rv's job, `pkill`/`killall` of `rvd`, `kill` of a pid looked up
from `rvd`, launching a second `rvd`, Linux D-Bus stops, and writes to
rv's binaries, LaunchAgent, systemd unit or socket dir become "run it in
Terminal". This check is **lexical, not a boundary** — it reads the
command text, so it raises the bar but a determined agent can still get
past it. It is observe-only; enforce already fails such a call closed.
Residual (not caught): `kill` by a numeric pid, or a pid or path held in
a variable or file; interpreter or script forms (a `python`/`node`
subprocess, `bash -c "$(… | base64 -d)"`, a script file, a make/npm
script); and a renamed or symlinked `launchctl`. When `rvd` is *absent*,
hooks under observe let the call run unchecked and
unlogged (with a notice on stderr) instead of prompting; a slow `rvd`, a
daemon that fails its identity check, or a malformed reply still asks or
denies (an "ask" is Claude Code's own prompt only in a session Claude
Code reports as attended, in a prompting permission mode, a block
everywhere else). Only `RV_HOOK_WHEN_DOWN=deny` closes the step-aside
and keeps denying an absent `rvd`; `"hookAskWhenDown": false` in
`config.json` only turns Claude Code's prompt into a block and does not
stop the observe step-aside. "Absent" is
platform-specific: on **macOS**, rv's launchd service is not registered
(discovery XPC returns INVALID) — the job is on-demand, so an idle `rvd`
is *not* absent; on **Linux**, the connect to
`/run/user/<uid>/rv/evaluate.sock` fails with `ENOENT`/`ECONNREFUSED` and
`XDG_RUNTIME_DIR` is unset or equals `/run/user/<uid>`. An organization gate pins enforce, and `rv setup
--observe` refuses under one. A host set `off` before an organization
gate arrived stays unwired until you run `rv setup`.

Per host, at any time:

```bash
rv host mode cursor observe
```

```bash
rv host mode cursor off
```

`off` removes that host's rv hooks and `rv setup` then skips it. Both
loosen, so both ask for owner authentication; an agent that runs them is
told to run them in Terminal.

## Uninstall

```bash
rv uninstall
```

It asks for owner authentication, removes rv's hooks from every host,
stops and removes the `rvd` service, and deletes the files `install.sh`
put in `~/.local/bin` and `~/Applications/RVApprovals.app`, plus
`config.json` and the policy, allowlist, analytics and denial files in
`~/.config/rv`. If `rvd` is not running you confirm at the terminal
instead.

It keeps your own data, so a reinstall picks it up: secret definitions
(`secrets.json`) and the values rv stored in the Keychain or the Secret
Service keyring under the service `rv.secrets`, `mcp.json` and its trust,
pin, review and approval files, on macOS the OAuth tokens `rv mcp connect`
stored in the Keychain (service `rv.mcp.oauth`, one item per server), the
audit log and `audit.key`, the judge weights, rvd's log (`~/.local/state/rv`, or `~/Library/Logs/rv` on macOS)
and the MCP server caches. It prints each kept path, the number of stored
secret values and where they are, and the commands that remove them by
hand, because no `rv` is left to do it: first the stored values, with
one `secret-tool clear service rv.secrets account NAME` per value on Linux
or one `security delete-generic-password -s rv.secrets -a NAME` per value
on macOS, plus on macOS one `security delete-generic-password -s
rv.mcp.oauth -a SERVER` per MCP server's OAuth tokens, then `rm -rf` of
the kept directories. Only when `secrets.json` cannot be read is the
secret command service-wide, deleting every item in `rv.secrets`.

```bash
rv uninstall --remove-models   # also delete the judge weights in ~/.config/rv/models
rv uninstall --purge           # also delete all of rv's data and the values it stored
```

`--purge` deletes the secret values rv stored (only a definition whose
source is the `rv.secrets` item named after the secret itself, the one
`rv secrets set` writes; never a value kept by 1Password, Vault or another
provider, nor any other Keychain item) and, on macOS, the MCP OAuth
tokens under `rv.mcp.oauth`, then all of `~/.config/rv`
including the audit log, its key and the judge weights, rvd's log
directory, the MCP caches, and on Linux `/run/user/<uid>/rv` (and
`$XDG_RUNTIME_DIR/rv` when that is set to another directory; a runtime
directory holding anything but rvd's `evaluate.sock` is left and named). A value it
cannot delete (no session bus, a locked keyring) is named on stderr,
`secrets.json` stays so it can be found, and the command exits non-zero
after removing everything else; so does a config directory it could not
list or remove. It enters none of those directories
through a symlink: one that is a symlink, or whose parent resolves
somewhere other than its place under your home, is left as it is and
named, and the command exits non-zero. When `~/.config/rv` itself is such
a path, the values its `secrets.json` names are not deleted either.

On Linux, if you installed the custodian:

```bash
sudo /opt/rv/rv mcp custodian uninstall
```

This keeps the keys in `/var/lib/rv-mcp-custodian`; add `--purge` to
delete them and the `rv-mcp-custodian` account, which voids every grant
and signature.
