# Troubleshooting

The messages you are most likely to meet, what causes each, and what to
do. Run the fixes in your own terminal, not through the agent: several of
them need you present, and the agent's shell cannot prove that.

How this was checked: message texts were copied from the source (the
hook clients, the gateway and the CLI); those marked "seen" were also
produced by a run on Linux.

## Agent tool calls are blocked

When rv cannot decide, the hook blocks the call. It never quietly allows
it (unless the host is in observe mode, see below).

**`rv failed`**
The host got a block with no reason; rv puts this text in when a reason
is empty. Run `rv doctor` and look at the Problems section.

**`RV daemon is not reachable (dev.rv.evaluate). Run `rv doctor`; `rv setup` repairs the service.`**
`rvd` is not running.

```bash
rv service status
```

```bash
rv setup
```

On Linux without a systemd user manager, `rvd` stops at logout or
reboot; `rv setup` says so and names the line to add to your shell
profile (`rv service start >/dev/null`). In observe mode a host lets the
call run unchecked instead, with a notice on stderr.

**`RV daemon did not answer in time. Retry; if it persists run `rv doctor`.`**
**`rv did not answer within 15s; the daemon may be busy or stopped. Run `rv doctor`.`**
`rvd` is busy or hung. Retry once. If it keeps happening:

```bash
rv service restart
```

**`RV daemon identity check failed (stale or mismatched rvd after an upgrade?) …`**
**`RV daemon sent an unexpected reply (version skew after an upgrade?) …`**
An old `rvd` is still running after an upgrade. `rv service restart`;
if that does not fix it, `rv setup`.

**`rv is not installed at <path>. Reinstall rv or run `rv setup`.`**
**`rv at <path> could not be started: … Run `rv doctor`.`**
**`rv exited with code N without a usable decision. Run `rv doctor`.`**
The hook points at a binary that is gone or broken. Reinstall, then
`rv setup`.

**A deny with a six-character code**
That is rv working. If you meant it, redeem the code once from your
terminal: `rv allow-once a1b2c3`. `rv explain '<command>'` shows which
pack and rule fired.

## `rv` commands refuse

**`device-owner authentication required`** (seen) with
**`… needs you at an interactive terminal while rvd is down (stdin and stdout must both be a terminal)`**
You ran a loosening command (`rv host mode … off`, `rv uninstall`, …)
from a script or an agent's shell while `rvd` was down. Run it yourself
in a terminal, or `rv setup` first.

**An account that cannot pass the owner check**
SSH-key-only users and root in containers often have a locked password
(`passwd -S` shows `L` or `NP`). rv says so instead of prompting. Set a
password with `sudo passwd $USER`.

**`rv secrets set: could not store NAME (no secret store: …install libsecret-tools and a keyring such as gnome-keyring)`** (seen)
Linux needs `secret-tool`, a D-Bus session bus and an unlocked keyring.
Over SSH with no desktop session there is usually no unlocked keyring;
use a source that does not need one (1Password, Vault, a cloud secret
manager) in `secrets.json`. A first `set` has already saved the
definition: once a keyring is available, run the same command again, or
`rv secrets set NAME`, to store the value.

**`rv run: rv-isolation-exec is not installed beside rv, so the command cannot be started suspended until its placeholders are bound; reinstall rv`**
Linux `rv run` needs the helper next to `rv` in `~/.local/bin`.
Reinstall. A kernel older than 5.9 also cannot run it.

**`rv run: the secrets gateway's peer check could not tell which process held a test connection here, …; refusing to launch`**
rv could not tell which process owns a connection, so it cannot bind
placeholders to your command. On Linux this happens with `/proc`
mounted `hidepid`, or in a different pid namespace. Run outside such a
container, or remount `/proc` without `hidepid`.

## The MCP gateway

**`rv mcp serve: mcp.json was edited outside rv (no rv signature); review it, then run `rv mcp trust`; not launching MCP servers`**
Serve refuses to start anything because `mcp.json` changed outside rv
(or was never signed). Read it, then `rv mcp trust`, then restart your
MCP host.

**`… MCP gateway trust is unavailable without a key custodian this agent cannot read (macOS, or Linux after `sudo rv mcp custodian install`) …`** (seen)
On Linux, install the custodian (see [Install](install.md#key-custody-where-rv-keeps-what-an-agent-must-not-reach)).
On macOS, RVApprovals.app is missing from `~/Applications`: reinstall
and run `rv setup`.

**Serve refuses to start for other reasons** (each line begins
`rv mcp serve:`):

| Message | Fix |
| --- | --- |
| `mcp.json defines no servers; see `rv mcp import`` | Add servers, or `rv mcp onboard --host <host>` |
| `mcp.json is invalid: …` | The rest of the line names the key; see [mcp.json](mcp-gateway.md#mcpjson-by-example) |
| `mcp.json is unsafe (…); it must be a regular file only you can write` | `chmod 600 ~/.config/rv/mcp.json`; no symlink |
| `<name> needs a sandbox; add "sandbox" to its mcp.json entry` | This host cages servers; add `"sandbox": {"network": false}` |
| `<name> stays off the network; list the hosts it needs in sandbox.hosts` | `"sandbox": {}` defaults to network on, which is refused; set `"network": false` or `"hosts"` |
| `<name> asks for a sandbox, but the MCP server sandbox is unavailable on this host (…); `rv mcp serve` will not run it uncaged` | Linux older than 6.7, or no Landlock or seccomp: run on a newer kernel, or remove the `sandbox` entry knowing it then runs uncaged |
| `organization policy requires a sandbox for <name>, but …` | Same, and the organization requires the cage |
| `<server> uses secret <name>, which secrets.json does not define` | `rv secrets set <name> …` |
| `<server> could not read secret <name>: …` | `rv secrets check <name>`; unlock the provider |
| `mcp.json changed while it was being checked; not launching MCP servers` | Start the host again |
| `rv cannot catch SIGINT, SIGTERM and SIGHUP here, so a signal would leave every MCP server running; not serving` | Linux only: rv could not set up how it hears signals (it needs one pipe, so usually rv is out of file descriptors). Close what holds them or raise the limit, then start the host again. Signals the parent left blocked are not the cause: serve unblocks the ones it handles |

**The agent sees `MCP server <name> did not answer tool <tool> within 300 s; rv stopped waiting. The call may still have run, so check before calling it again.`**
The tool took longer than its server's `callTimeoutSeconds`. If the tool
is meant to run that long, raise `callTimeoutSeconds` for that server
(up to 86400) and re-trust. Check whether it ran before retrying: rv
asked the server to cancel but cannot make it stop. After a timeout rv
pings the server; a server that cannot answer while busy is then stopped
and restarted. rv's ping goes out even when a remote server is at its
request limit, so a full remote is judged like any other.

**`MCP server <name> is unavailable: it did not answer initialize within 60 s (its startTimeoutSeconds)`**
The server took too long to start. An `npx` server's first download is
a common cause. Raise its `startTimeoutSeconds` (up to 600). It stays
failed until the MCP host restarts serve. Until every server has started
or failed, every tool call waits, so one slow server holds up the rest.

**`MCP server <name> is unavailable: <why>; rv is restarting it. The call was not run; try it again in a few seconds.`**
The server exited, lost its connection or stopped answering, and rv is
bringing it back (after 1, 2, 4, 8, then 16 s). The call was refused, not
queued; retrying in a few seconds is safe. If it keeps happening, look at
serve's stderr for the reason, and at the server's own logs.

**`MCP server <name> is unavailable: it went away again after 5 restarts within 10 minutes, so rv stopped restarting it; restart the MCP client to start it again`**
The restart limit is five in any ten minutes. Fix the server, then
restart your MCP client.

**`Unknown tool: <tool>. MCP server <name> did not list it after rv restarted it; the call was not run.`**
After a restart, rv lets calls reach only tools the server lists again.
The server came back without that tool (a different version, a feature
flag, a failed plugin). Check the server; when it lists the tool again,
calls work. A tool whose definition changed asks again and needs
`rv mcp trust`.

**`MCP server <name> exited before answering tool <tool>. The call may have run, so check before calling it again.`**
The server crashed during the call. rv never re-sends it.

**`MCP server <name> already has 64 calls in flight, …`** or **`… has too many requests in flight; …`**
A remote server is not answering fast enough and rv stopped sending
more (the limits are per remote server). Wait for calls to finish; if it
does not recover, the remote is likely stuck. The second message, for an
approved call, ends `Its approval was used up, so it must be approved
again.`: that approval was spent on a call that was not sent.

**`rv paused this call: … Ask the user to run `rv mcp approve <id>` …`**
Your client cannot show rv's prompt. Run `rv mcp pending`, then
`rv mcp approve <id>` with the confirmation code from serve's stderr.

**Every tool asks, or tools show `[rv: this tool is not yet trusted …]`**
Tools are pinned only by `rv mcp trust`. Start the host once, run
`rv mcp trust`, then restart the host.

**`rv mcp serve` exits with status 1 saying the client stopped reading**
The MCP client took nothing rv wrote for 30 seconds. That is a client
problem; restart it.

## Collecting information for support

```bash
rv --version
```

```bash
rv doctor --json
```

```bash
rv audit verify --json
```

```bash
rv mcp check --json
```

None of these print secret values. Add your MCP host's log of serve's
stderr for gateway problems.
