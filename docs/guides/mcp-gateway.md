# The MCP gateway

`rv mcp serve` sits between your agent (the MCP client) and your MCP
servers. The agent talks to rv over stdio as if rv were one MCP server;
rv starts or connects to the real servers, applies a per-tool policy
(allow, ask, deny) to every call, keeps tool definitions pinned to what
you reviewed, and writes every call to the audit log.

How this was checked: the commands, flags and config keys below were run
with `--help` and read from the source on this branch; config limits,
defaults and every message quoted were taken from the source. On Linux
the repository's custodian end-to-end test
(`Scripts/linux-custodian-e2e.sh`) was run here and passed 40 of 40:
untrusted `mcp.json` refused, `rv mcp trust` with a password, serve with
no terminal, an unpinned tool asking, pinning, an approval granted once,
a replayed grant refused, a rolled-back `mcp.json` refused, and the audit
chain. Timeouts, restarts and the remote-server limits were not run here;
their behaviour and messages come from the source and its tests.
RVApprovals.app, Touch ID and the Seatbelt cage (macOS) were not run.

## Before you start: the approvals key

The gateway trusts `mcp.json` only if it carries rv's signature, and only
a key the agent cannot use can make that signature.

- **macOS:** RVApprovals.app holds the key; the installer puts it in
  `~/Applications` and `rv setup` registers it.
- **Linux:** install the custodian once, from a root-owned copy of rv
  (see [Install](install.md#key-custody-where-rv-keeps-what-an-agent-must-not-reach)),
  then check:

  ```bash
  rv mcp custodian status
  ```

Without a custodian, every trust command refuses with:

```text
rv mcp trust: MCP gateway trust is unavailable without a key custodian this agent cannot read (macOS, or Linux after `sudo rv mcp custodian install`): rv's signing key here is a file any process running as you can read, so rv cannot tell its own mcp.json from another program's edit; mcp.json stays untrusted and `rv mcp serve` will not launch servers from it
```

## mcp.json by example

The file is `~/.config/rv/mcp.json`. It must be a regular file only you
can write, at most 1 MiB, at most 128 servers. Unknown keys are errors.

```json
{
  "version": 1,
  "servers": [
    {
      "name": "files",
      "description": "Local filesystem tools for this repo",
      "command": "npx",
      "args": ["-y", "@example/files-mcp", "/home/dev/projects/acme"],
      "env": {"FILES_MCP_LOG": "warn"},
      "tools": {
        "allow": ["read_file", "list_directory"],
        "ask": ["write_file"],
        "deny": ["delete_*"]
      },
      "sandbox": {"network": false, "writable": ["/home/dev/projects/acme"]},
      "startTimeoutSeconds": 120
    },
    {
      "name": "tickets",
      "url": "https://mcp.tickets.example.com/mcp",
      "headers": {"Authorization": "Bearer ${secret:TICKETS_TOKEN}"},
      "tools": {"allow": ["search_*", "get_ticket"], "ask": ["create_ticket"]},
      "callTimeoutSeconds": 60
    },
    {
      "name": "fetcher",
      "command": "/usr/local/bin/fetch-mcp",
      "secrets": {"FETCH_API_KEY": "FETCH_API_KEY"},
      "tools": {"allow": ["fetch"]},
      "sandbox": {"hosts": ["api.fetch.example.com"]}
    }
  ]
}
```

- **`files`** is a local stdio server, caged with no network and one
  extra writable directory.
- **`tickets`** is a remote server over streamable HTTP. rv sends the
  header; the agent never sees it. `${secret:NAME}` takes the value from
  a secret in `secrets.json`.
- **`fetcher`** is a caged server whose only way out is rv's allowlist
  proxy, to `api.fetch.example.com` on port 443. It gets the **real**
  value of `FETCH_API_KEY` in its environment (`secrets`); to give it a
  placeholder instead see [Secrets placeholders](secrets-placeholders.md#3-give-an-mcp-server-placeholders-macos-only)
  (macOS only).

### Server keys

| Key | Local | Remote | Meaning |
| --- | --- | --- | --- |
| `name` | yes | yes | 1 to 64 of `A-Z a-z 0-9 . _ -`; unique |
| `description` | yes | yes | Shown in reviews |
| `command`, `args` | yes | no | What to run; found on `PATH` through `/usr/bin/env`. `args` may hold `${secret:NAME}` |
| `env` | yes | no | Literal, non-secret environment values |
| `secrets` | yes | no | `{"VAR": "SECRET_NAME"}`: the server gets the real value in `VAR`, and rv scrubs it from what the server returns |
| `placeholders` | yes | no | Secret names handed as placeholders (macOS only) |
| `url` | no | yes | `https://…` (plain `http` only to localhost); no credentials, secret-looking parts or fragment in it |
| `headers` | no | yes | Up to 32; values may hold `${secret:NAME}`; rv sets protocol headers itself |
| `transport` | no | yes | `http` (streamable HTTP, default) or `sse` (the older HTTP+SSE transport) |
| `tools` | yes | yes | `allow`, `ask`, `deny`: lists of globs (`*` any run, `?` one character) or argument rules |
| `sandbox` | yes | no | `network`, `writable`, `hosts`; see below |
| `startTimeoutSeconds` | yes | yes | 1 to 600, default **60** |
| `callTimeoutSeconds` | yes | yes | 1 to 86400, default **300** |

Top-level keys: `version` (must be 1), `servers`, `direct` (servers you
allow outside rv), `blocked` (servers never to run), `toolMode`
(`direct`, or `search` to show the client only `rv_search_tools` and
`rv_call_tool`). `defaultDecision` and `tools.default` are accepted but
ignored: a tool no rule names is always denied.

### Tool policy

- The strictest matching rule wins: deny over ask over allow. A tool no
  rule names is **denied** and hidden from the agent.
- A rule object decides by argument:
  `{"tool": "query", "when": {"/db": {"==": "prod"}}}`, with operators
  `==`, `!=`, `<`, `>`, `in`, `glob`. A rule never matches an argument
  the call left out.
- An organization policy can only make a decision stricter.
- A tool rv has not pinned (see "Trust") always asks, even if allowed.

### The cage (`sandbox`)

Where the host can cage a server (macOS always; Linux 6.7 or later with
Landlock and seccomp), **every local server needs a `sandbox` entry and
must stay off the network**. Either set `"network": false`, or list the
hosts it needs in `"hosts"` (which turns the network off for everything
else). `"network"` defaults to `true` when you leave it out, so
`"sandbox": {}` is refused:

```text
<name> stays off the network; list the hosts it needs in sandbox.hosts
```

| Key | Meaning |
| --- | --- |
| `network` | `false` for no network at all |
| `hosts` | Up to 32 exact DNS names, reached on port 443 through rv's allowlist proxy; no scheme, port, wildcard or IP |
| `writable` | Extra absolute or `~/` paths the server may write |

A caged server can always write its scratch directory
(`~/.cache/rv-mcp/<name>` on Linux, `~/Library/Caches/rv-mcp/<name>` on
macOS), the temp directory, `/dev`, `~/.npm` and `~/.cache`. It cannot
read credential stores (`~/.ssh`, `~/.aws`, `~/.config/gh`, keyrings,
browser profiles, `~/.netrc`, …), other agents' MCP configs, or rv's own
config. On Linux, `writable` paths must exist and not be symlinks, and a
server whose `env` sets `LD_*` or `GLIBC_TUNABLES` is refused. The full
Linux list is in
[docs/security/mcp-linux-sandbox.md](../security/mcp-linux-sandbox.md).

On Linux older than 6.7 there is no cage: a server **with** a `sandbox`
entry is refused, a server **without** one runs uncaged with a warning,
and under an organization `requireSandbox` no local server runs.
Remote servers are never caged.

## Getting servers into mcp.json

You can write `mcp.json` by hand and then trust it. Or let rv copy what
your agent already has:

```bash
rv mcp list
```

```bash
rv mcp onboard --host cursor --dry-run
```

```bash
rv mcp onboard --host cursor
```

- `rv mcp import --host <host>` copies a host's servers into `mcp.json`
  (literal credentials move into the Keychain or keyring); it needs you
  present.
- `rv mcp setup --host <host>` rewrites the host's own config so each
  server runs as `rv mcp serve --server <name>`; `--undo` restores the
  entries it changed. Restart the host afterwards.
- `rv mcp onboard --host <host>` does both.
- Imported servers start with every tool on **ask**. Add `allow` rules
  and a `sandbox` as you review them.

Hosts: Claude Code, Claude Desktop, Cursor, Codex, OpenCode, Gemini,
Antigravity, VS Code, Windsurf, Muse. `rv mcp check` exits 1 if any
server bypasses rv, is unreviewed or blocked, or has no usable sandbox;
run it in CI or from your MDM.

## Trust: `rv mcp trust`

Any edit to `mcp.json` that rv did not make leaves it untrusted, and
`rv mcp serve` then starts nothing:

```text
rv mcp serve: mcp.json was edited outside rv (no rv signature); review it, then run `rv mcp trust`; not launching MCP servers
```

```bash
rv mcp trust
```

It prints the whole file as a review (every server, command, argument,
variable, secret binding, rule, writable path and host, plus a SHA-256),
then asks for you: Touch ID or your password on macOS, your login
password on Linux. It refuses without a terminal, and a pseudo-terminal
an agent opens cannot answer. On success: `trusted mcp.json; rv signs it
again on every change it makes`.

Trust also pins **tool definitions**. rv never pins on its own:

1. Start your MCP host once, so `rv mcp serve` lists each server's tools.
   Serve says on stderr how many are not trusted yet:

   ```text
   rv mcp: 3 tools on files are not yet trusted; run `rv mcp trust`
   ```

2. Run `rv mcp trust`. It shows every field of every new or changed tool
   definition and pins exactly what it showed:
   `pinned 4 MCP tool definitions; rv serves them unchanged as trusted`.
3. **Restart your MCP host.** A running serve keeps the pins it started
   with.

Until a tool is pinned, and whenever its definition changes from the pin
(a "rug pull"), the agent sees only its name, an empty input schema and
this description, and every call asks:

```text
[rv: this tool changed since the user trusted it; its description and parameters are hidden until the user runs `rv mcp trust`; every call needs the user's approval]
```

A tool whose name is longer than 64 bytes or uses anything outside
`A-Z a-z 0-9 _ . -` is hidden and cannot be called; serve names one such
tool per server on stderr.

## Running it: `rv mcp serve`

```text
rv mcp serve [--server <name>]...
```

Your MCP host starts this, not you: it speaks MCP on stdin and stdout.
Without `--server` it serves every server in `mcp.json`. A host set up by
`rv mcp setup` runs one serve per server. When one serve has more than
one server, tool names are prefixed with the server's: `files__read_file`.

At start it reads your host configs once and warns (on stderr and in the
audit log) when servers bypass the gateway:

```text
rv mcp: host MCP configs hold 2 entries rv does not govern (1 bypass the gateway, 0 blocked in mcp.json but still run, 1 unreviewed); run `rv mcp check` to see them
```

It never stops serving because of that.

## Approvals

A call to a tool on `ask` (or an unpinned tool) is held for a person.

**In the client**, when it supports MCP elicitation, the agent's host
shows rv's prompt with the exact arguments:

```text
rv: allow MCP server tickets to run tool create_ticket?
Arguments: {"title":"Rotate staging keys"}
```

and an "Allow this call once" checkbox. Only that call, with exactly
those arguments, runs. A prompt not answered within 5 minutes expires
and the call is not run. Note that whoever controls the host can answer
this prompt; see [Known limits](known-limits.md).

**Out of band**, when the client cannot show a prompt, the agent gets:

```text
rv paused this call: tickets tool create_ticket needs the user's approval. Ask the user to run `rv mcp approve rv-…` in their own terminal (or `rv mcp approve rv-… --always`), then call the tool again with the same arguments.
```

and serve's stderr shows a confirmation code for it. In your own
terminal:

```bash
rv mcp pending
```

```bash
rv mcp approve <id>
```

`approve` shows the server, tool, argument names and argument digest,
asks you to type the confirmation code, then asks for Touch ID or your
password (macOS) or your login password (Linux). It prints `approved
tickets create_ticket once; the agent can retry the same call`. The
grant runs that call once; the same call again asks again. `--always`
also adds the tool to the server's `allow` list. `rv mcp deny <id>`
refuses it.

## Signing in to a remote server: `rv mcp connect`

For a remote server that uses OAuth, sign in once and rv keeps, sends and
refreshes the token:

```text
rv mcp connect <server> [--client-id <id>] [--scope <s>] [--no-browser] [--forget]
```

```bash
rv mcp connect tickets
```

rv finds the server's authorization server, registers a client (or uses
`--client-id`), opens your browser (`--no-browser` prints the URL
instead) and waits up to 300 seconds for the redirect on
`http://127.0.0.1:<port>/callback`. Tokens are kept in the Keychain on
macOS (service `rv.mcp.oauth`) and in
`~/.config/rv/mcp-oauth/<server>.json` (mode 0600) on Linux. On Linux
that file is readable by anything running as you, the agent included.
`--forget` deletes them. It refuses for a local server, for an untrusted
`mcp.json`, and for a server that already sends an `Authorization`
header from `mcp.json`.

## Time limits

| Limit | Default | Where |
| --- | --- | --- |
| A server must answer `initialize` | 60 s | `startTimeoutSeconds`, 1–600 |
| A `tools/call` may go unanswered | 300 s | `callTimeoutSeconds`, 1–86400; each progress notification restarts it |
| A call in all, even with progress | 10 × `callTimeoutSeconds` (50 min by default) | not configurable |
| A `tools/list` page | 30 s | not configurable |
| A server must answer rv's `ping` after a call timed out | 10 s | not configurable |
| The client must take what rv writes | 1 MiB per 30 s | not configurable |

Until every server has answered `initialize`, failed, or run out its
start time, every `tools/list` and `tools/call` waits, so one slow server
holds back all tools. These clocks stop while the machine sleeps.

## What the agent sees when things go wrong

These are the exact error texts rv returns to the client (JSON-RPC error
`-32603` unless noted). rv never sends a call twice.

| Situation | What the agent gets | What happened to the call |
| --- | --- | --- |
| Server did not start in time | `MCP server files is unavailable: it did not answer initialize within 60 s (its startTimeoutSeconds)` | not run; the server stays failed for the session |
| Call timed out | `MCP server files did not answer tool write_file within 300 s; rv stopped waiting. The call may still have run, so check before calling it again.` | rv asks the server to cancel; it cannot make it stop |
| Call hit its total limit | `MCP server files did not finish tool write_file within its total limit of 3000 s; rv stopped waiting. …` | as above |
| Server exited mid-call | `MCP server files exited before answering tool write_file. The call may have run, so check before calling it again.` | may have run |
| Call while it restarts | `MCP server files is unavailable: process exited; rv is restarting it. The call was not run; try it again in a few seconds.` | not run |
| Tool gone after restart | `Unknown tool: write_file. MCP server files did not list it after rv restarted it; the call was not run.` (code `-32602`) | not run |
| Restart limit reached | `MCP server files is unavailable: it went away again after 5 restarts within 10 minutes, so rv stopped restarting it; restart the MCP client to start it again` | not run |
| Policy denies | `rv policy denies files tool delete_all. Do not retry; ask the user if you need it.` (a tool error) | not run |
| Prompt declined | `The user declined tickets tool create_ticket in rv's approval prompt. Do not retry unless the user asks.` | not run |
| Audit log unwritable | `rv could not write the audit record for files tool read_file; the call was not run` | not run |
| 64 calls in flight to one remote | `MCP server tickets already has 64 calls in flight, the most rv sends a remote server at once; the call was not run. Try it again once one of them has finished.` | not run |
| 160 requests in flight to one remote | `MCP server tickets has too many requests in flight; tool search_tickets was not run. Try it again once some have finished.` | not run |

### Crashes and restarts

A server that was ready and then goes away is started again. "Goes away"
means it exits, ends its HTTP session (404), loses its connection under a
request, stops reading its input, or does not answer rv's `ping` within
10 s after one of its calls timed out. A server that handles one request
at a time cannot answer that ping while it is still busy with a slow call,
so it is stopped too and what it was running is cut off.

- It is restarted after 1, 2, 4, 8, then 16 s, **at most 5 times in any
  10 minutes**; after that it stays failed until the client restarts
  `rv mcp serve`. The window slides, so a server that dies every two
  minutes or so is restarted for as long as serve runs, and its secrets
  are resolved again each time (which can mean a provider unlock prompt
  each time).
- A server that never became ready is not restarted.
- A restart uses the `mcp.json` serve verified when it started, not the
  file on disk now. The restarted server is listed again before any call
  reaches it: a changed tool asks again, and an approval for the old
  definition does not carry over.
- The client gets `notifications/tools/list_changed` when the server goes
  and when it is back.

Serve's stderr shows each step:

```text
rv mcp: MCP server files is gone (process exited); restarting it in 1 s
rv mcp: MCP server files is back
```

### Limits per remote server

A remote server has at most **64 calls** and **160 requests of any kind**
(calls, cancels, listings, pings, notifications) in flight. Past either,
rv does not send the request: a call ends not run (the messages above), a
listing page fails, and a notification is dropped with a line on stderr.
Nothing already in flight is touched. A remote that has more than
128 MiB of its output waiting for the gateway is stopped and restarted.
A streamable HTTP answer over 64 MiB ends only the call it answers.

## Stopping serve

Serve ends when the client closes its input. It also catches SIGINT,
SIGTERM and SIGHUP (a terminal's Ctrl-C, a closed terminal, a host's
process-group kill) and stops its servers itself: SIGTERM to each
server's process group, SIGKILL 2 s later if still running. A second
signal kills what is left at once. Serve then exits with 128 plus the
signal; it exits 1 if the client stopped reading for 30 s. Each call
still in flight gets a last audit record ("gateway stopped; the call may
still have run").

What a server started in a session of its own (`setsid`) or outside rv
(the container of a `docker run` server) is not reached by those signals.

## Useful commands

```bash
rv mcp list
```

```bash
rv mcp check
```

```bash
rv audit --kind mcp.call --since 24h
```
