# Known limits

What rv does not do, stated plainly so you can decide where to rely on
it. Each limit links to where it is explained in more depth.

How this was checked: each item was confirmed in the source or its tests
on this branch. The macOS items come from the source and recorded
measurements; they were not run for these guides.

## Releases and platforms

- **No signed release yet.** The newest release, v0.2.1, is unsigned and
  predates most features described in these guides. The installer checks
  downloads against `SHA256SUMS` but does not yet check `SHA256SUMS`
  against a release key, and on macOS an unsigned binary only warns. See
  [Install](install.md#release-status-read-this-first).
- **Linux needs glibc 2.35 or later** (Ubuntu 22.04+, Debian 12+, Fedora
  36+, RHEL 10+). musl (Alpine) is not supported. macOS needs 15 or later
  on Apple Silicon.
- **Caged MCP servers on Linux need kernel 6.7 or later with Landlock**
  (ABI 4) and seccomp filters. On older kernels a server that asks for a
  sandbox is refused and one that does not runs uncaged. The Linux cage
  has been tested on x86-64 only.
- **The Linux custodian needs systemd and PAM,** must be installed from a
  root-owned copy of rv, and accounts with no password, fingerprint-only
  login, or a PAM factor kept in the home directory cannot approve. Its
  own limits (a password typed where the agent can watch, a prompt the
  agent starts) are in
  [docs/security/mcp-linux-custodian.md](../security/mcp-linux-custodian.md#known-limits).
- **Placeholders for MCP servers are macOS only.** On Linux a server with
  `"placeholders"` is refused.
- **Contained workspaces, micro-VMs and the on-device judge are macOS
  only.** Linux runs packs only.

## The secrets gateway

- **macOS can send a `GET` or `HEAD` up to three times.** When the
  upstream drops the connection before answering, macOS's URLSession
  retries a `GET` or `HEAD`, credential included, up to three times in
  all; it has no setting to stop this. `POST`, `PUT`, `PATCH`, `DELETE`
  and `OPTIONS` are sent once. On Linux every request is sent once. Do
  not put a credential behind the gateway for an API where a repeated
  `GET` has an effect.
- **Linux cuts off answers over 64 MiB from a fast upstream.** On Linux at
  most 64 MiB of one answer can wait for the client. An answer larger
  than that, from an upstream faster than the gateway forwards it, is cut
  off without the chunked terminator, so the client sees it as
  incomplete. On loopback a 256 MiB answer was cut after 32 MiB.
- **`rv run` is not a sandbox.** The command runs as you and can read
  anything you can, including where the real values are stored.
- **An MCP server's cage does not stop it asking your keychain or a
  provider for a value itself.**
- **`approve` rules are refused outside a workspace.** There is no
  approver for `rv run` or an MCP server, so requests an `approve` rule
  matches are refused under `rv run`, and an MCP placeholder server with
  such a secret is refused.
- **`secrets.json` is not signed.** The `mcp.json` signature does not
  cover it, so a later change to a secret's upstream changes what an MCP
  server's placeholder is spent on without a new review. Serve writes the
  binding to stderr each time a placeholder server starts.

See [Secrets placeholders](secrets-placeholders.md#what-is-protected-and-what-is-not).

## The MCP gateway

- **Restarts: at most five in any ten minutes.** After that the server
  stays failed until the MCP client restarts `rv mcp serve`. The window
  slides, so a server that fails every two minutes or so is restarted
  indefinitely, its secrets resolved again each time.
- **Each remote server gets at most 64 calls and 160 requests in
  flight.** Past either, rv does not send the request; nothing in flight
  is touched. An approved call that is not sent spends its approval. The
  limits are per remote server, not per serve process: on Linux, where
  each request is a connection, several saturated remotes add up and can
  still run rv out of file descriptors.
- **One slow server holds back every tool** until it starts or its
  `startTimeoutSeconds` runs out.
- **A timed-out call may still run.** rv asks the server to cancel and
  stops waiting; it cannot make the server stop.
- **A server that handles one request at a time is restarted after a
  call times out,** because it cannot answer rv's ping while busy.
- **Signals do not reach what a server started outside its process
  group** (`setsid`, a `docker run` container).
- **A running serve keeps the pins it started with.** After `rv mcp
  trust`, restart the MCP host.
- **Approval in the client's own prompt needs no custodian.** Whoever
  controls the MCP host can answer rv's in-client prompt. With an agent
  that controls its host, only `deny`, and calls held for
  `rv mcp approve`, are protected by the custodian.
- **On Linux, OAuth tokens from `rv mcp connect` are a file** in
  `~/.config/rv/mcp-oauth/` (mode 0600), readable by anything running as
  you.
- **Some fields of a pinned tool are forwarded as the server sent them**
  (vendor schema keywords, `enum` and `default` values, `icons`,
  `_meta`), and `rv mcp trust` does not cap how long a field it shows may
  be. Tool result text is forwarded byte for byte; rendering it safely is
  the MCP host's job.
- **Messages whose JSON keys differ only by Unicode normalization** are
  treated as having duplicate keys and dropped.
- **`mcp.tool.changed` and `mcp.hosts.ungoverned` have no OCSF mapping
  yet.**

## The guard that keeps agents from adding MCP servers around rv

While the gateway is in use, the hook guard refuses an agent's writes to
host MCP configs and host CLIs that add servers (`claude mcp add` and
the like). It reads command text, so it is not a boundary:

- **22 spellings are known gaps, recorded as expected failures in the
  test suite** (`Tests/RVEngineTests/MCPHostSpellingTests.swift`): 20 are
  `mcp install` with the `mcp` word given as a variable or command
  substitution (`chronic $M install srv`), bare and behind four wrappers;
  asking there would fire on every `$PM install`. The other two are a
  glob class closed only by a brace alternative, and a nameref whose
  target is built from an expansion.
- **Not guarded:** a nested agent started with servers rv does not govern
  (`claude --mcp-config …`, `claude --plugin-dir …`, `codex -c
  mcp_servers…`); a program that writes a config without its command line
  visible as text (a script or scheduled job written earlier, a shell fed
  an expansion, text decoded by `base64 -d`, `rev`, `tr` or a `printf`
  format, output joined across commands, a git hook or pager set up
  earlier); a glob the filesystem expands into a host and its group word;
  a config file name written through a brace or glob spelling.
- **It also asks for some harmless commands**, such as a `cat` of a path
  with an escaped space under `~/Library/Application Support`.

The README's "MCP governance" section lists every case.

## The hook guard

- **Search tools:** a search with no explicit path (Claude `Grep`/`Glob`,
  Cursor `Grep`) scans the working directory and can match inside
  non-ignored secret files there; rv does not read file contents.
- **Observe mode's protection of `rvd` is lexical.** It raises the bar on
  stopping or replacing `rvd` but does not catch `kill` by a numeric pid,
  interpreter or script forms, or a renamed `launchctl`. When `rvd` is
  absent, an observe host lets calls run unchecked.
- **Plain allows are not logged** in the audit log, only denies,
  overrides and changes.

## The audit log

- **The chain is unkeyed.** A process running as you can rewrite the
  file and recompute every hash, or cut off the tail. Compare the
  forwarded `rv_chain_head` off the machine to catch that.
- **An older CLI** that meets rvd's "audit log unwritable" answer says
  rvd is not reachable and points at `rv doctor` instead of the audit
  log.

## Anything running as you

rv's config directory is yours to write. rv's hook guard refuses an
agent's attempts to edit it, but a process running as you outside any
agent can still edit or delete `~/.config/rv`. rv flags an edited
`mcp.json` and refuses to use it, and the custodian refuses a rolled-back
one, but it cannot stop the edit.
