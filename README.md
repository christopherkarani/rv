<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Resources/rv-banner-dark.png">
    <img src="Resources/rv-banner.png" alt="rv — shell guard for coding agents" width="1280">
  </picture>
</p>

<p align="center">
  <a href="https://github.com/christopherkarani/rv/releases/latest"><img src="https://img.shields.io/github/v/release/christopherkarani/rv" alt="Release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache%202.0-0f172a" alt="Apache 2.0"></a>
  <a href="https://github.com/christopherkarani/rv"><img src="https://img.shields.io/github/stars/christopherkarani/rv?style=flat" alt="Stars"></a>
  <a href="https://discord.gg/uZn9MDUYKx"><img src="https://img.shields.io/badge/discord-join-5865F2?logo=discord&logoColor=white" alt="Discord"></a>
  <img src="https://img.shields.io/badge/packs-95-7928ca" alt="95 rule packs">
  <img src="https://img.shields.io/badge/platform-macOS%2015%2B%20(Apple%20Silicon)%20%7C%20Linux-111827" alt="macOS 15+ Apple Silicon and Linux">
</p>

# rv

**Your coding agent just tried to run `rm -rf /`. rv said no.**

rv is a fail-closed policy gate for AI coding agents. It sits on your
agent's pre-tool hook and blocks destructive shell commands, and reads or
edits of secret files, *before* the host runs them. One gate, three
verdicts: **allow · deny · indeterminate**. It never asks the agent; only
you can override, with a one-time code.

```sh
$ rv test 'git reset --hard'
{"decision":"deny","pack_id":"core.git","reason":"git reset --hard destroys uncommitted changes","rule_id":"core.git:reset-hard","schema":"rv.test.v1"}

$ rv test 'git status'
{"decision":"allow","schema":"rv.test.v1"}
```

**Guides:** [install and first run](docs/guides/install.md) ·
[secrets placeholders](docs/guides/secrets-placeholders.md) ·
[MCP gateway](docs/guides/mcp-gateway.md) ·
[audit log](docs/guides/audit-log.md) ·
[troubleshooting](docs/guides/troubleshooting.md) ·
[known limits](docs/guides/known-limits.md)

## Install (30 seconds)

```sh
curl -fsSL https://rykanv.com/install | sh
rv setup --dry-run   # optional: see which hooks setup would write
rv setup             # auto-detects your agents and wires their hooks
rv doctor            # verify everything is live
```

Want to watch before you enforce? Install in observe mode: rv logs what it
would block and lets everything run.

```sh
curl -fsSL https://rykanv.com/install | RV_INSTALL_MODE=observe sh
rv setup --observe   # same thing for an existing install (asks Touch ID if rv is already enforcing)
rv blocks            # what observe would have blocked
```

On macOS the installer also fetches the on-device judge weights (~649 MB,
verified by SHA-256, fully offline after) so the neural judge binds on first
run; Linux installs run packs-only until the ONNX runtime lands. Re-run the
installer anytime to pick up the weights.

Works with **Claude Code, Codex, Cursor, Grok, OpenCode, Pi, Hermes,
OpenClaw, Antigravity, and Muse**. Hooks are only written for hosts already
on your machine. Requires macOS 15+ (Apple Silicon) or Linux
(aarch64/x86_64) with glibc 2.35+ (Ubuntu 22.04+, Debian 12+, Fedora 36+,
RHEL 10+), libcurl and libsqlite3; the installer checks these first. musl
(Alpine) is not supported. On a Linux host with no login manager
(containers, WSL without systemd, `su`/`sudo -u` logins), `/run/user/<uid>`
must exist, owned by you, mode 0700, or `XDG_RUNTIME_DIR` must name such a
directory: `rvd` keeps its socket there and only root can create it
(`sudo install -d -m 0755 /run/user && sudo install -d -m 0700 -o $(id -u) /run/user/$(id -u)`).
`/run` is usually a tmpfs, so make it again after a reboot or container
restart. The installer checks this before downloading. Every download is
checked against the release's `SHA256SUMS`, which must carry a valid
signature from rv's release key (`SHA256SUMS.sig`); on macOS each binary
must also carry rv's Developer ID signature (see
[SECURITY.md](SECURITY.md#release-integrity)).

## How it works

Every shell and file-tool call from every host goes to one daemon (`rvd`)
and through one pipeline:

```text
agent ─▶ hook ─▶ rvd ─▶ rule packs ─▶ script gate ─▶ on-device judge ─▶ policy ─▶ allow / deny / indeterminate
                        safe-first     npm bodies     Laya (CoreML)      override
                        deny = floor   evaluated      can only raise     ladder
```

| Stage | What it does |
| --- | --- |
| **Rule packs** | 95 packs: git, filesystem, disks, cloud CLIs, Kubernetes, databases, Terraform, CI/CD, payments and more. Safe patterns run first; the first blocking hit denies. |
| **Script gate** | `npm test` can't hide a payload: rv evaluates the real `pre`/`post`/body scripts in `package.json`. |
| **Judge** | With a Laya CoreML bundle installed (macOS), pack-allowed commands get a local risk score. It can only raise a verdict, never lower a pack deny. Nothing leaves your machine. |
| **Policy** | A fixed override ladder: rebase recovery → pinned rules → allowlist → allow-once → contained-delete allowance, with `normal` or `strict` safety. Indeterminate (too large, budget spent, core packs missing) can never be overridden. |

Four rules hold everywhere:

- **Fail closed.** If `rvd` is down, slow or fails its identity check, the call is blocked.
- **Deny is a floor.** Nothing later in the pipeline can lower a pack deny.
- **Only you override.** The agent can't redeem its own code or change rv's rules.
- **Observe never relaxes rv's own protection.** In observe mode, rv admin commands and rv's config stay guarded while `rvd` runs ([details](docs/guides/install.md#observe-first-then-enforce)).

## What gets blocked

Three packs are on by default: `core.filesystem`, `core.git` and
`system.disk`. Browse the rest with `rv packs`; `rv packs enable <id>`
turns one on after owner authentication.

| Category | Examples |
| --- | --- |
| Destructive git | `reset --hard`, `push --force`, `clean -fd`, `stash clear`, `checkout -- .` |
| Destructive filesystem | `rm -rf /`, `rm -rf ~`, `find -delete`, fork bombs, disk wipes |
| Secret paths | `.env`, SSH keys, cloud credentials: shell *and* Read/Edit/Write on Grok, Claude, Cursor |
| Cloud and infra (opt-in packs) | `terraform destroy`, `kubectl delete`, `aws s3 rm --recursive`, `DROP TABLE`, … |

Not sure why something blocked? `rv explain 'git reset --hard'` shows
which pack and rule fired. rv does not read file contents, so a search
tool with no explicit path can still match inside secret files in the
working directory ([known limits](docs/guides/known-limits.md#the-hook-guard)).

## When you're blocked (and you meant it)

Every hook deny prints a six-character code. Redeem it once, from your
own terminal:

```sh
rv allow-once a1b2c3    # next matching call in this directory runs once
```

Redeeming needs owner authentication: Touch ID or your password on
macOS, your login password on Linux. The same check guards every command
that changes the gate: `rv allowlist add`, `rv packs enable`,
`rv safety strict|normal`, `rv policy draft --save`, `rv egress approve`,
`rv workspace abandon`. Typed rules live in `~/.config/rv/policy.toml`
(`rv policy show`).

On Linux the account needs a local password; an SSH-key-only user or
root in a container usually can't pass
([details](docs/guides/install.md#owner-authentication)).

## Locked out?

When rv can't decide (the daemon `rvd` is down or slow, or the `rv` binary
is gone), every hook fails closed: the agent's tool call is blocked, never
quietly allowed. The block message says which of these it was:

| Message starts with | What it means | What to do |
| --- | --- | --- |
| `RV daemon is not reachable` | `rvd` isn't running | `rv doctor`; `rv setup` repairs the service |
| `RV daemon did not answer in time`, `rv did not answer within 15s` | `rvd` is busy or hung | Retry; then `rv service status`, `rv service restart` |
| `RV daemon identity check failed`, `RV daemon sent an unexpected reply` | a stale `rvd` after an upgrade | `rv service restart`; if that doesn't fix it, `rv setup` |
| `rv is not installed at <path>` | the hook points at a binary that's gone | Reinstall rv, then `rv setup` |
| `rv at <path> could not be started`, `rv exited with code N` | `rv` is broken or crashed | `rv doctor` |
| `Laya judge is still loading` | the on-device judge is still loading after `rvd` started | Retry in a few seconds |
| `Laya judge queue is full` | too many commands are waiting for the judge | Retry shortly |
| `rv degraded: judge late` | the judge did not answer this command in time | Retry; if it keeps happening, `rv doctor` |
| `rv degraded: judge unavailable (circuit open, retrying in Ns)` | the judge failed several times in a row, so rv skips it for a minute and sends what it would have scored to review | Retry after N seconds; `rv doctor` shows the circuit |
| `Laya judge unavailable; failing closed` | the judge couldn't score this command | `rv doctor` |

Run these from your own terminal, not through the agent:

```sh
rv doctor                 # what's broken and how to fix it
rv service status         # is rvd running, down, or skewed?
rv service restart        # restart rvd
rv setup                  # repair the rvd service and host hooks
rv host list              # each host's mode and hook wiring
rv host mode claude off   # stop guarding one host (asks for owner authentication)
rv uninstall              # remove rv's hooks, rvd and binaries; keeps your secrets and audit log (owner-auth)
```

`rv host mode <host> block` turns guarding back on.

## Features

rv is one binary with 27 commands. Beyond the shell guard:

### Secrets without exposure
Agents in a contained workspace (macOS), or a command started with
`rv run`, see placeholders, never values. The real value is injected at
the boundary from Keychain, 1Password, Vault, AWS/GCP/Azure, Infisical or
Bitwarden, and scrubbed from everything that comes back. Hook-guarded
agents get secret-path blocking instead.

```sh
rv run --secret NAME -- command   # placeholders for one command (macOS, Linux)
rv login connect vercel           # reuse an existing Vercel or GitHub login
rv secrets scan                   # catch leaks before they land
```
→ [Secrets placeholders guide](docs/guides/secrets-placeholders.md)

### MCP gateway
`rv mcp serve` puts every MCP server behind one gateway: per-tool
allow/ask/deny, human approval for `ask`, tool definitions pinned to what
you reviewed, sandboxed servers and a full audit trail. While it is in
use, the hook guard also stops agents adding servers around it.

```sh
rv mcp serve    # run the gateway
rv mcp trust    # review and pin tool definitions
rv mcp check    # fail if any server bypasses rv
```
→ [MCP gateway guide](docs/guides/mcp-gateway.md)

### Contained workspaces (macOS)
`rv workspace` and `rv opencode` run agents on a private copy of the
project under a deny-default Seatbelt profile: workspace-only writes,
proxied HTTPS, no Keychain. `--microvm <image>` uses a network-less Linux
micro-VM instead (macOS 26+). Work is published back when the workspace
closes. This is a hardening layer, not a finished isolation boundary
([acceptance audit](docs/security/runtime-acceptance.md)).

### Egress control
Contained runtimes reach the network only through a per-runtime proxy
with SNI-bound tunnels and binary pinning. Blocked hosts queue for review
in `rv egress`; `rv egress approve` needs owner authentication.

### Tamper-evident audit
Every deny, override, MCP and secret event, and every change to the gate
itself, lands in a SHA-256 hash-chained `audit.jsonl` (rule and host,
never command text). `rv audit verify` checks the chain; export as OCSF
1.3.0 to your SIEM.
→ [Audit log guide](docs/guides/audit-log.md)

### Session forensics
`rv scan` replays past agent sessions offline and reports which commands
your enabled packs would have denied.

### Signed organization policy
Fleet-wide, restrict-only rules signed with Ed25519 and pinned root-owned
on disk: MCP tool rules, secret sources, audit forwarding, required packs,
strict safety. User config can never loosen them. `rv report` emits
posture for MDM and fleet tools.

## Supported hosts

Claude Code · Codex · Cursor · Grok · OpenCode · Pi · Hermes · OpenClaw ·
Antigravity · Muse

`rv setup` only wires hosts already on your machine. `rv host mode <host>
block|observe|off` sets each one separately.

## Fleet console

rv Console, the fleet dashboard for teams, is developed separately and is
no longer part of this repository. Machines send it their audit trail with
`rv audit forward` (per machine, or fleet-wide through `audit.forward` in
the organization policy) and their posture with `rv report --json`; both
are documented above and stay open source. The console's earlier source
remains in this repository's history under Apache 2.0, up to commit
`eda11f2b`.

## Platform support

| | macOS 15+ (Apple Silicon) | Linux (x86_64, aarch64; glibc 2.35+) |
| --- | --- | --- |
| Hook guard, packs, `rv test`, audit log | yes | yes |
| Secrets gateway binds a placeholder to the process tree it was leased to | yes (libproc) | yes (`/proc`); refuses where `/proc` hides processes |
| `rv run` (placeholders for one command) | yes | yes; needs `rv-isolation-exec` beside rv (the installer puts it there) and Linux 5.9+ |
| MCP gateway: per-tool policy, tool pinning, audit | yes | yes, with the custodian installed |
| MCP approvals signed by a key the agent cannot use | RVApprovals.app (Touch ID or password) | `sudo rv mcp custodian install` (login password through PAM; systemd) |
| MCP server sandbox | Seatbelt | Landlock, a seccomp socket filter and, for `sandbox.hosts`, a connector; Linux 6.7+ (x86-64 tested), see [limits](docs/security/mcp-linux-sandbox.md) |
| Contained workspaces, micro-VMs | yes | no |
| On-device judge | yes | no (packs only) |

## Everyday commands

```sh
rv test 'rm -rf /'          # evaluate a command, don't run it
rv explain 'rm -rf /'       # why would this block?
rv packs                    # what is on; rv packs --all browses the 95 packs
rv blocks                   # what got denied lately?
rv host list                # per-host mode (block / observe / off) and wiring
rv workspace vms            # micro-VM runtime sessions, newest first
rv scan                     # audit past agent sessions
rv audit verify             # check the audit hash chain
rv doctor                   # service, packs, hosts, judge health
rv uninstall                # remove rv's hooks, rvd and binaries (owner-auth)
rv uninstall --remove-models  # ...and the judge weights in ~/.config/rv/models
rv uninstall --purge        # ...and all of rv's data, including stored secret values
```

`rv uninstall` removes rv's hooks, stops the service, then deletes every
file install.sh put in `~/.local/bin` and `~/Applications/RVApprovals.app`,
plus `config.json` and the policy, allowlist, analytics and denial files in
`~/.config/rv`. It keeps your own data so a reinstall picks it up: secret
definitions and the values rv stored in the Keychain or Secret Service
(service `rv.secrets`), MCP config and its trust, pin and approval state
(on macOS also the MCP OAuth tokens under `rv.mcp.oauth`),
the audit log and its key, the judge weights, rvd's log and MCP caches. It
prints each kept path, how many secret values it kept and where, and the
commands that remove them once rv is gone. `rv uninstall --purge` removes
all of that too, deleting only the secret values rv itself stored; a value
it cannot delete (no session bus, locked keyring) is named and the command
exits non-zero after removing the rest. The Linux custodian's system files
stay for `sudo rv mcp custodian uninstall`. If rvd is not running, you
confirm at the terminal with your login password (or Touch ID) instead;
without a local owner check it refuses and says how to start rvd.

All commands speak `--json` / `--robot` / `--plain` / `--no-color`.
Anonymous usage counters are on by default; opt out with
`"analytics.enabled": false` (or `{"analytics": {"enabled": false}}`)
in `~/.config/rv/config.json`.

## Architecture

```text
 rv (C front door) ──exec──▶ Swift CLI (RVCLI) ──Unix socket / XPC──▶ rvd (RVService)
                                                                     │
   Capabilities   RVPolicy · RVHooks · RVMCP · RVIsolation · RVScan · RVLaya
   Core           RVEngine · RVPacks · RVHistory · RVIPC
   Foundation     RVDomain · RVFileStore
```

A small C front door execs the Swift CLI, which talks to the `rvd` daemon
over a Unix socket (XPC on macOS): 15 IPC methods, one gated evaluation
path for every door. `RVEngine` parses and evaluates commands against
`RVPacks`; `RVIsolation` holds the cage, egress proxy and secrets
gateway. See the [architecture map](rv-architecture-map.pdf) for the full
module graph.

## For developers

```sh
git clone https://github.com/christopherkarani/rv && cd rv
swift build --build-tests   # Swift 6.4
swift test                  # full suite (this is the PR gate)
```

A Python SDK lives in [`sdk/python`](sdk/python). Security model and
evidence: [`docs/security`](docs/security). Before opening a PR, read
[CONTRIBUTING.md](CONTRIBUTING.md); report vulnerabilities per
[SECURITY.md](SECURITY.md).

Site: [rykanv.com](https://rykanv.com) · Docs:
[rykanv.com/docs/introduction](https://rykanv.com/docs/introduction) ·
Discord: [discord.gg/uZn9MDUYKx](https://discord.gg/uZn9MDUYKx)

## License

Apache 2.0. See [LICENSE](LICENSE).
