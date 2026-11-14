# Secret gateway policy

A gateway secret reaches the agent as a per-launch placeholder. The agent
sends requests to `http://127.0.0.1:<port>/s/<NAME>/...`, and rv swaps the
placeholder for the real value only toward the binding's `upstream`. This
page covers the per-secret limits on *where* that swap may happen.

## Substitution surfaces

`delivery.gateway.surfaces` lists the parts of a request where the
placeholder may be swapped:

| surface  | covers                                                           |
|----------|------------------------------------------------------------------|
| `header` | any forwarded header value, including decoded `Basic` credentials |
| `query`  | the query string                                                 |
| `path`   | the request path after `/s/<NAME>`                               |

The default is `["header"]`. Most APIs take credentials in `Authorization`
or a custom header, and query strings and paths end up in upstream access
logs, so `query` and `path` must be opted in. The body is never a surface:
it passes through untouched (see `secrets-tier3-design.md` item (g)).

```json
"delivery": {"gateway": {
  "upstream": "https://api.telegram.org", "baseURLEnv": "TELEGRAM_API",
  "surfaces": ["path"]
}}
```

From the CLI: `rv secrets set NAME --gateway URL --base-url-env VAR --surface path`
(repeatable). The flag applies only when the secret is first defined; edit
`secrets.json` to change an existing one.

Two refusals, both `403` and audited as denied. Neither one forwards
anything upstream:

- **Surface not allowed.** The placeholder sits on a surface the binding
  does not list. `403` rather than `400` because the request is well formed
  and the secret's own policy forbids it. Resending it unchanged will not help.
- **Repeated placeholder.** Each surface is filled at most once per request.
  A second occurrence in another header, another query parameter, or the
  same header value is refused. This stops an agent copying the secret into
  a second header that the upstream might log or echo. Git over https
  (`Authorization: Basic` with the token as the password) and
  `Authorization` with other ordinary headers are unaffected. A request
  with one placeholder in the path, one in the query, and one in a header
  is allowed when all three surfaces are.

Surface and repeat checks run before any value is encoded into the request.

## Method and path scope

Without rules, a placeholder grants the full authority of the credential:
a `GITHUB_TOKEN` placeholder can push and delete. `delivery.gateway.allow`
narrows it to the methods and paths listed. Each entry is a preset name or
a rule:

```json
"allow": [
  "read-only",
  {"methods": ["POST"], "path": "/graphql"},
  {"methods": "*", "path": "/v1/chat/**"}
]
```

- `methods` is `"*"` or a list of upper-case methods. `GET` does not imply
  `HEAD`.
- `path` is a glob on the upstream path, which is the upstream URL's own
  path followed by whatever the agent sends after `/s/<NAME>`. `*` matches
  within one segment (`/repos/*/issues`, `/files/*.json`). `**` matches any
  number of segments, including none. A glob may contain at most two `**`.

| preset         | rules                                                                                  |
|----------------|----------------------------------------------------------------------------------------|
| `read-only`    | GET, HEAD, OPTIONS on `/**`                                                            |
| `github-clone` | GET `/**/info/refs` with `service=git-upload-pack`, POST `/**/git-upload-pack`; no push |
| `github-read`  | GET, HEAD on `/**` (for `api.github.com`; no GraphQL, which needs POST)                 |

`github-clone` belongs on a binding whose upstream is `https://github.com`.
The query condition can only come from the preset; hand-written rules
match method and path only.

From the CLI: `rv secrets set GITHUB_TOKEN --allow github-read` or
`--allow "GET,HEAD /repos/**"` (repeatable). The flag applies only when the
secret is first defined. Defining a gateway secret without rules prints a
note.

The curated defaults for well-known names are least privilege. A new
secret with one of these names (from `rv secrets set NAME` without
`--gateway`, from `rv login connect`, or from a Varlock `@proxy` whose
domain is the curated upstream's host) gets these rules:

| name                                | upstream                    | default `allow`  |
|-------------------------------------|-----------------------------|------------------|
| `OPENAI_API_KEY`                    | `https://api.openai.com/v1` | `GET,POST /v1/**` |
| `ANTHROPIC_API_KEY`                 | `https://api.anthropic.com` | `GET,POST /v1/**` |
| `GITHUB_TOKEN`, `GH_TOKEN`          | `https://api.github.com`    | `github-read`    |
| `STRIPE_SECRET_KEY`                 | `https://api.stripe.com`    | `read-only`      |
| `VERCEL_TOKEN`                      | `https://api.vercel.com`    | `read-only`      |

Where a narrow scope could not be fixed with confidence, the narrower one
was chosen:

- The model-provider keys reach only the `/v1` API with `GET` and `POST`
  (model calls, token counts, listings). `DELETE` (files, batches, stored
  responses) and paths outside `/v1` are refused.
- `github-read` refuses GraphQL, which needs `POST /graphql`, so most `gh`
  subcommands fail with `403` until widened. GraphQL can also mutate.
- `STRIPE_SECRET_KEY` and `VERCEL_TOKEN` are read-only: a Stripe secret
  key can move money, and a Vercel token can deploy and delete.

To widen, pass `--allow` when the secret is first defined; it replaces the
curated rules instead of adding to them. For example
`rv secrets set GITHUB_TOKEN --allow github-read --allow "POST /graphql"`
for `gh`, or `--allow "* /**"` for the full authority of the credential.
For a secret already defined, edit `delivery.gateway.allow` in
`secrets.json`. Secrets defined before this change keep the rules on file
(none, for a curated default), so they still allow everything until edited.

Enforcement:

- Rules are checked at the first placeholder lookup. That is before any
  value is placed in the request and before the body is read, so a refused
  upload never streams through the gateway.
- Matching uses the pre-substitution path, so the matched string never
  holds the secret.
- A request outside the rules gets `403`. It is audited with the method and
  the path, with any placeholder replaced by `rvph_[redacted]`, and never
  with the value. All gateway audit paths are redacted this way.
- With rules, the path is decoded once before matching. Requests an upstream
  could read differently are refused with `400`: encoded `/` or `\`
  (`%2f`, `%5c`), dot segments raw or encoded (`.`, `..`, `%2e%2e`), `//`,
  `;` parameters, backslashes, control bytes, invalid UTF-8, and a `%` left
  after one decode (`%252e`). A path such as GitLab's
  `projects/group%2Fproject` therefore needs no rules on its binding.

## Runtime binding

The gateway listens on `127.0.0.1`, and the cage may reach any loopback port
(dev servers bind ephemeral ports, so the Seatbelt profile cannot name
them). Loopback is shared by every process on the host. A placeholder is
therefore honored only on a connection from the runtime it was leased to.

- rv records the runtime leader (its pid, which is also its process group,
  and its start time) after spawn and before the runtime runs.
- A runtime's processes are: its leader; every live descendant of the
  leader; and, when the leader leads its own session (terminal runtimes),
  that session. The group is not membership: the cage denies the `setsid`
  and `setpgid` syscalls, but `posix_spawn` with `POSIX_SPAWN_SETPGROUP`
  lets any process in the same session join a group, so a sibling runtime
  could otherwise join this one. The same flag, and `POSIX_SPAWN_SETSID`
  (Node's `detached: true`), moves a child out of the group, and the
  descendant walk keeps those children in.
- On each request, rv takes the connection's port pair and looks (libproc
  on macOS, `/proc` on Linux; see below) for one of those processes holding
  the client socket: the leader
  first, then the descendants (at most 4096), then the session. The
  listings only name candidates. A candidate found holding the socket is
  proved a member again from fresh reads: it is the recorded leader, or
  every parent link from it up to the leader holds (each process read
  again after its parent was, and no parent younger than its child), or
  it is in the session the leader leads. So a pid that exited and was
  reused mid-scan, by the holder or by a process between it and the
  leader, does not count. Every
  placeholder in the request is checked, so one runtime cannot spend
  another's placeholder beside its own.
- Not a member: `403`, refusal `runtimeMismatch`, and a `secret.misuse`
  finding. Another runtime, a host shell, or any other local process
  holding a copied placeholder lands here.
- Cannot tell: `403`, refusal `runtimeUnverified`, no misuse finding. This
  covers a kernel read that failed, a group whose leader is gone or was reused, a
  descendant walk past its bound, and a placeholder whose runtime has no
  recorded group. The gateway fails closed.

Limits: the check binds to the runtime, not to a binary inside it; any of
its processes may spend the placeholder unless the secret lists `binaries`
(next section). A process whose parent exited
(reparented to launchd) is no longer a descendant, even if it stayed in the
leader's group; unless it is in a terminal runtime's session, its requests are refused as
`runtimeMismatch`. On Linux the parent is init or the nearest subreaper
(`systemd --user`), with the same effect.

### Linux

The check is the same scan; only the reads differ.

- The connection is found in `/proc/self/net/tcp` and `tcp6`, which show
  the reader's network namespace, the gateway's: the client end is the row
  `127.0.0.1:<client port> -> 127.0.0.1:<gateway port>` (IPv4, or IPv6
  v4-mapped for a dual-stack client socket). The gateway's own end must be
  in the same tables, and exactly one held client end (inode not 0) must
  be. A process holds it when one of its `/proc/<pid>/fd/*` links, or one
  of a thread's `/proc/<pid>/task/<tid>/fd/*` (a thread that unshared its
  table with `unshare(CLONE_FILES)`), reads `socket:[<inode>]`. A forked
  child that inherited the socket is a holder too. The kernel may print a
  row twice when the table changes while it is read; the same row twice
  is one socket.
- A socket registered with an io_uring instance
  (`IORING_REGISTER_FILES`, direct descriptors) whose descriptor was then
  closed is named by no `fd` link: the ring holds it. A process holding
  the ring (`anon_inode:[io_uring]`) holds every socket the ring's
  `/proc/<pid>/fdinfo/<fd>` lists under `UserFiles:`. A ring whose files
  cannot be read (the kernel omits the list while the ring is busy), or
  that holds another ring, leaves the scan undecided.
- A process is identified by its pid and its start time (`/proc/<pid>/stat`
  field 22, clock ticks after boot). The `comm` field is read from the last
  `)`, as bytes, so a process cannot forge the fields after its name. A
  `stat` that does not end in a newline is a read cut short and is refused.
- Descendants come from one pass over every process's `stat`, so every
  `stat` on the host must be readable.
- Each candidate's `stat` is read before and after its descriptors. A
  change in between, or a process that exits after the scan listed it (it
  may have been the holder), leaves the scan undecided: unless another
  candidate is a holder, the answer is `runtimeUnverified`, not
  `runtimeMismatch`. A process already gone when
  the scan lists processes, or a zombie, is skipped, as on macOS. A
  process whose main thread exited while other threads run reads as a
  zombie in `stat` but is alive: it is kept while `/proc/<pid>/task` lists
  more than one thread. Its main thread has no descriptors any more (and
  the kernel gives that thread's `fd` directory to root), so only the
  threads that run are read.
- One decision reads a bounded amount of `/proc`: at most 2^20 files,
  links and directory entries (a listing is one read per process on the
  host; a descriptor scan is up to threads times descriptors per
  candidate). Past that every read fails and the answer is
  `runtimeUnverified`.
- In a terminal runtime's session, a listed process whose session cannot
  be read leaves the scan undecided too.
- `runtimeUnverified` also covers: a `/proc` whose `self` is not rv's pid
  (another pid namespace's: nothing at all is read from it, not one
  process's `stat`), a `/proc` mounted with `hidepid` other than
  `0`/`off` (a descendant running as another user could not be seen), an
  unreadable descriptor table, the process's or any thread's (a setuid,
  non-dumpable or other user's process when rv lacks `CAP_SYS_PTRACE`, rv
  itself confined by an LSM policy with no ptrace-read rule, or one that
  exited mid-read), a socket table that is missing, truncated,
  malformed, ambiguous, or lacks the gateway's end, and a client end no
  process holds (inode 0: time-wait or orphaned). Yama's `ptrace_scope`
  restricts attaching, not these reads, at every setting.
- A process in another network namespace cannot reach the gateway's
  loopback, so it is never a holder, even with the same port pair on its
  own loopback. A listening socket shared with
  `SO_REUSEPORT` does not matter: a connected 4-tuple is unique within a
  namespace. A descendant in a pid namespace of its own (`unshare --pid`,
  a rootless container) is still a process of rv's `/proc` and is read
  like any other; `/proc` mounted with `subset=pid` hides nothing the
  check reads.
- Descriptors that change hands: holding the socket is the criterion,
  however a process came to hold it. A runtime process that passes its
  connection to a process outside the runtime (`SCM_RIGHTS`, `fork`) is
  still a holder while it keeps its own descriptor, and the request is
  served, as it would be if the runtime relayed it; once the runtime
  closes its descriptor the connection is `runtimeMismatch`. The reverse
  is a limit (the same on macOS): a runtime process that receives
  descriptors from outside its runtime can be handed an outsider's
  connection, and is then its holder.
- Limits beyond macOS's:
  - A recorded group's start time is ticks after boot, so it names a
    process only until the host reboots, and only to the tick (10 ms): a
    pid reused within one tick is the same identity.
  - Socket inode numbers are 32 bits and the kernel reuses them after
    2^32 allocations (the limit `ss -p` and `lsof` share). A local process
    that can drive the counter around and land on the number of a socket
    a runtime process holds would be attributed to the runtime. Driving
    it takes on the order of hours of CPU.
  - A socket in flight inside a Unix socket message (sent, not yet
    received) is in no descriptor table: a request on it is
    `runtimeMismatch` until a runtime process receives it. A child forked
    after the scan listed processes, whose parent then exits, is missed
    the same way.
  - A process whose main thread exited has no readable `/proc/<pid>/exe`,
    so binary binding on it is `runtimeUnverified`. A secret with
    `binaries` is also `runtimeUnverified` while any runtime process has
    an unreadable descriptor table (a setuid or non-dumpable child such
    as `sudo` or `ssh-agent`): every holder must be read.
  - A container started through a daemon (`docker run`) is the daemon's
    child, not the runtime's: with host networking its requests are
    `runtimeMismatch`.

Verified on real kernels by `SecretGatewayLinuxPeerTests`,
`SecretGatewayLinuxAttackTests` and `Scripts/linux-peer-binding-e2e.sh`,
which runs the binding under `hidepid`, `subset=pid`, another pid
namespace's `/proc`, root without `CAP_SYS_PTRACE`, an AppArmor-confined
reader, Yama `ptrace_scope` 1 to 3, and a default Docker container.

## Uncontained launches (`rv run`)

`rv run --secret NAME -- COMMAND` (or `--all`) starts a command with no
cage and the gateway in front of it. It is for running `claude`, `codex`,
or a script with placeholders instead of real values, without a workspace.

How it starts the command:

- Only `gateway` and `awsSigV4` secrets are staged. A named secret with
  `environment` delivery, or with an `agents` filter (`rv run` carries no
  agent tag), is refused; `--all` skips those, names them on stderr, and
  removes what they would have set (and a `hostEnvironment` source's
  variable) from the command's environment. Nothing selected is refused.
- The command's environment is rv's own, minus every variable a selected
  secret stages (the shell's copy of the real value among them, and
  `AWS_SESSION_TOKEN`/`AWS_SECURITY_TOKEN` for an AWS secret), minus the
  variable a `hostEnvironment` source reads, minus any variable whose
  value (trimmed of surrounding whitespace or not) is a selected secret's
  real value or one part of an AWS credential set, or contains one that is
  12 bytes or longer (`Bearer <token>`, a connection URL with the password
  in it), plus the lease: placeholders, base URLs, and the AWS endpoint,
  key id and a throwaway signing key. A shorter value is matched only
  exactly, so a short PIN does not take unrelated variables with it. The
  names to strip come from the definitions the lease staged. When a
  selected secret comes from Vault, rv's own Vault login (`VAULT_TOKEN`) is
  removed too; `~/.vault-token` is not, and provider CLIs (`op`, `aws`,
  `infisical`, `bws`, `gcloud`, `az`) read their own logins, which rv does
  not name, so those pass through. Values are compared in memory as bytes;
  the names removed by value are listed on stderr. A variable whose value
  is not valid UTF-8 reaches rv already repaired by Foundation, so a real
  value hidden in one is not recognised.
- On macOS, `posix_spawn` with `POSIX_SPAWN_SETPGROUP` and
  `POSIX_SPAWN_START_SUSPENDED` creates the command as its own group leader
  and stops it before its first instruction. rv records the leader's pid
  and start time, binds the lease to it, hands it the terminal, and only
  then sends `SIGCONT`. If any step fails, or a signal reaches rv before
  the resume, the stopped child is killed. Only stdio is inherited.
- On Linux, where `posix_spawn` cannot start a process stopped, the child
  is a launcher: `rv-isolation-exec --stopped`, the helper installed
  beside rv and found from `/proc/self/exe` (never `PATH`). It is spawned
  as its own group leader (`POSIX_SPAWN_SETPGROUP`), closes every
  descriptor above stdio with `close_range` (it exits 125 instead if the
  kernel refuses, so a kernel before 5.9 cannot run `rv run`), stops
  itself with `SIGSTOP`, and execs the command only once continued. rv
  waits for that stop, and takes only a stop by `SIGSTOP` for it: a
  launcher that exited, was killed, or stopped for another reason is
  killed and the launch refused. The rest is the same code as on macOS:
  rv records the stopped process's pid and start time, which survive
  `exec`, binds the lease, hands over the terminal and sends `SIGCONT`.
  So the command's image runs no instruction before its placeholders are
  bound, and holds none of rv's descriptors. If `exec` then fails the
  launcher says why on stderr and exits 126. A `SIGSTOP` sent to the new
  child by another process before its own is indistinguishable from it;
  the command then stops once more as it starts, bound either way.
- `SIGINT`, `SIGQUIT`, `SIGTERM` and `SIGHUP` sent to rv go to the
  command's group, each followed by `SIGCONT` so a stopped group gets it,
  until the leader exits; nothing is signalled once it is reaped. One rv
  inherited ignored (`nohup`) stays ignored for the command. The
  dispositions are process-wide and installed once however many guards
  are open; `SIGCHLD` is default meanwhile, so nothing reaps the command
  behind rv. macOS ignores the four signals and reads them from a signal
  source. Linux discards an ignored signal unread, so there each has a
  handler that writes its number to a pipe one thread reads; a handler
  does not survive `exec`, so the signals rv inherited ignored are
  ignored again for the instant of the spawn. rv takes its terminal from `/dev/tty`, so a command reading
  the terminal while stdin is a pipe still stops and resumes with job
  control. Ctrl-Z stops rv with the command, and `fg` resumes both; `bg`
  resumes both and leaves the terminal with the shell. rv hands the
  terminal on only while it holds the foreground and its process group
  holds nothing but rv and its own parents (read with
  `proc_listpgrppids`; on Linux from one pass over `/proc`, and a `/proc`
  that cannot be listed counts as shared). In a pipeline (`rv run -- x | less`) the other
  commands share rv's group, so the terminal stays with them: Ctrl-C
  reaches the command only because rv forwards it, and Ctrl-Z stops rv but
  not the command. rv takes the terminal back only from the command's
  group, or from a group nobody is in any more: if the shell gave it to
  another job while rv was stopped, that job keeps it. Terminal modes are
  saved when rv takes it back and re-applied when it hands it on. rv exits with
  the command's code, or 128 plus the signal that ended it; 125 means
  `rv run` refused and the command never ran (126: could not be started,
  127: not found).
- When the leader exits, rv kills what is left of its process group,
  revokes the placeholders and stops the gateway, on every path.

What it protects:

- The real values are never in the command's environment, so it cannot
  print, log, or paste into a transcript a value it was never given.
- A placeholder is spent only on a connection from the command or a process
  it started ([runtime binding](#runtime-binding)), only for requests the
  secret's `allow` rules permit, and only while the command runs. Requests an
  `approve` rule matches are refused: there is no approver outside a
  workspace.

What it does not:

- It is not a sandbox. The command runs as you, with your files and
  network. It can read whatever your user can, which may include where the
  real values are stored: a `.env` file, `~/.aws/credentials`, a signed-in
  password manager CLI, a keychain item it is allowed to read. It may also
  be able to read the environments of its parent processes, rv's own
  (which holds what rv inherited) included.
- Other variables pass through unchanged, including secrets you did not
  select (other than those `--all` skipped).
- A process in a new session or group (`setsid`) can still spend the
  placeholders while its chain of parents reaches the command. Only a
  process reparented to launchd (its parent exited) cannot, and it is not
  killed when the command exits.

Before resolving any secret, `rv run` checks both things it relies on by
doing them (`SecretRunCapability.check`): it spawns a suspended probe
child holding one end of a loopback connection, and the gateway's peer
check must call that connection the probe's and a second one not. A
platform without a no-window spawn, or whose peer check cannot tell
(`/proc` hidden or another pid namespace's, no libproc, rv confined so
it may not read other processes, the Linux launcher missing), is refused
with exit 125 and the command never starts.

## Binary binding

`binaries` on a `gateway` or `awsSigV4` secret narrows the runtime check
to the processes running listed programs:

```json
{"name": "GH_TOKEN", "binaries": ["/opt/homebrew/bin/git", "/opt/homebrew/bin/gh"], ...}
```

- 1 to 16 distinct absolute paths, without `.` or `..` components.
  Environment delivery refuses the field: rv cannot see which process
  reads an environment variable.
- At launch, rv resolves each path (symlinks followed) and pins the file
  by device, inode, size, and change time. A path that is not a regular
  file fails the launch, and so does one nothing would ever run as, with an
  error that says why: a `#!` script (the kernel reports its interpreter,
  so list the interpreter or the program that runs it), or an Xcode
  developer-tool shim. `/usr/bin/git`, `python3`, `make`, and `clang` are
  `xcrun` trampolines that exec the real tool in the same process, so no
  process ever runs as `/usr/bin/git`. rv detects a shim without running
  anything: a file in `/usr/bin` whose name also exists in the `usr/bin` of
  `DEVELOPER_DIR`, the `xcode-select` target, or the Command Line Tools.
  The error names that real path (`xcrun --find git` prints it); list it,
  or a Homebrew binary such as `/opt/homebrew/bin/git`. ctime is pinned, not mtime, because `utimes` can
  restore an mtime and nothing in user space sets ctime. So a binary
  replaced or rewritten after launch no longer matches. An upgrade (for
  example `brew upgrade gh`) takes effect at the next launch.
- After the runtime check passes, rv finds every runtime process holding
  the client socket (a forked child inherits it). Each one must run a
  pinned binary or descend from one that does. The ancestor walk follows
  parent pids up to the runtime leader or launchd, at most 64 levels. The
  holder's start time is read before its descriptors, and the walk checks
  it against the first process it reads. After the walk, rv re-reads every
  process: the start time and parent pid must be unchanged, and no parent
  may have started after its child. So a pid reused between the descriptor
  scan and the walk, or during it, is `unverifiable`, as is a walk that
  hits the 64-level bound before reaching the leader or launchd. The kernel reports an executable by its real path, so a script's
  interpreter is what is matched.
- What is compared. macOS: the path libproc reports (`proc_pidpath`) must
  be the pinned path, and the file at that path must still be the pinned
  file. Linux: the same, and the file the process actually runs, read
  through `/proc/<pid>/exe` (`stat` follows it even to an unlinked file),
  must be the pinned file too: same device, inode, size and change time.
  That catches a process that bind-mounts another binary over the pinned
  path in its own mount namespace. A target the kernel marks ` (deleted)`
  (the binary was replaced or removed) never matches. Neither platform
  compares a code signature or a content hash.
- Mismatch: `403`, refusal `binaryMismatch`, and a `secret.misuse`
  finding. Cannot tell (a process exited or changed mid-walk, a descriptor
  table or path could not be read): `403`, `runtimeUnverified`, no
  misuse finding.
- Each connection serves one request, so the answer is not cached.

| refusal | status | misuse | when |
|---------|--------|--------|------|
| `binaryMismatch` | 403 | yes | a process holding the connection runs no listed binary and descends from none, up to the runtime leader |

Limits:
- An ancestor match is coarse: every child of an allowed `git` (hooks, a
  credential helper, `core.sshCommand`) is admitted, and an agent can make
  git start any command (`git -c alias.x='!cmd' x`). Against a hostile
  agent, list binaries that cannot be told to run others, and note that
  even those do not stop the socket-passing trick below.
- The check runs once the request head is read, before the body. A process
  that sends the head and then execs an allowed binary, keeping the socket,
  passes.
- The scan reads process descriptor tables, so a socket in transit does not
  count. A process can pass the connection over a Unix socket
  (`SCM_RIGHTS`) and leave it parked in a message, held by no process. If
  an idle pinned binary is then the only visible holder, the request
  passes, and the sender reclaims the socket to send the body and read the
  response. Against a hostile agent in the same runtime this defeats binary
  binding, whatever binaries are listed. It is a limit rv does not close.
- An interpreter (`node`, `python3`) as an allowed binary admits any
  script it runs.
- A binary without the hardened runtime can be made to load other code
  (`DYLD_INSERT_LIBRARIES`) and still match.
- A process outside the runtime fails the runtime check first.

## Response scrubbing

The real value never goes back to the agent. Before any response header or
body byte reaches the cage, the gateway replaces the value with the
placeholder, including these encoded forms:

- percent-encoded (`%2F` or `%2f`, `+` for a space, any mix of raw and
  encoded bytes);
- JSON-string-escaped (`\/`, `\"`, `\\`, `\n`, `\uXXXX` including
  surrogate pairs).

Base64 and base64url copies, at any of the three byte alignments inside a
larger blob, become `[rv:redacted]`. The placeholder is not used there
because the value's edge characters share bits with the neighbouring bytes
and its length would shift the rest of the blob, so no replacement still
decodes correctly. At most two edge characters, under 12 bits of the value,
can remain beside the marker. Base64 runs shorter than 8 characters are not
matched.

Hex copies of the value, contiguous or space-separated and in either case,
also become `[rv:redacted]`. S3 `SignatureDoesNotMatch` bodies print the
canonical request, signed session token included, as space-separated hex
bytes. Hex runs shorter than 8 characters are not matched.

A value split across response chunks is still caught. The gateway holds back
only a trailing partial match, so streamed output (SSE, token streams) that
cannot be the start of the value is forwarded at once.

Compressed bodies cannot be scanned. The gateway sends
`Accept-Encoding: identity` upstream in place of the agent's own header. If
a response with a body still carries a `Content-Encoding` other than
`identity`, the gateway returns `502` and forwards none of it.

Not covered: double encodings (percent inside JSON, base64 of an escaped
value), HTML entities, and payloads that are themselves archives
(`application/zip`, `application/gzip`).

## Expiry and rotation

`expires` (an ISO-8601 date or a date-time with a zone; a date alone means
00:00 UTC that day) stops a secret from being delivered. Set it with
`rv secrets set NAME --expires 2026-12-31`, or `--expires none` to clear it.

- At launch an expired secret fails the launch, as an unresolvable one does.
  Nothing from that lease is staged.
- In a running session the gateway refuses requests past expiry with `403`
  (`refusal: expired`).
- `rv secrets list` and `describe` warn when a secret has expired or expires
  within 7 days.

A gateway entry no longer has to hold its launch value for the runtime's
life:

- **Keychain sources** (including everything `rv secrets set` stores) are
  checked on the request path, at most every 2 seconds, for a changed
  modification date. Only the item's attributes are read, so the check never
  prompts. A change makes the next request wait for a re-read, so
  `rv secrets set NAME` reaches running sessions without a restart.
- **`refresh`** (`rv secrets set NAME --refresh 15m`, from 1m to 30d)
  re-resolves any source on a timer. Once the interval has passed, the next
  request starts a refresh in the background and is served the current value.
  If the refresh fails, the current value is still used for a grace of one
  more interval, with retries no more often than a quarter interval. After
  that, requests wait for a refresh and are refused with `503`
  (`refusal: refreshFailed`) while it keeps failing.
- One refresh runs per entry at a time; concurrent requests share it.
- A refresh re-reads `secrets.json` and takes the expiry on file. If the
  secret's source or delivery has changed, the refresh fails, because a live
  placeholder must not receive a value it was not bound to. Start a new
  session to use the new definition.
- The previous 8 values stay in the response scrubber, so an upstream that
  echoes a pre-rotation value still has it redacted.

Environment-delivered secrets cannot rotate: the value is in the process
environment from launch, and `refresh` is refused for them. Restart the
session to pick up a new value. Removing a secret does not revoke it from a
running session; end the session. Dynamic secrets with leases and
revoke-on-exit are not supported, since rv has no dynamic sources.

## AWS SigV4 signing

AWS requests carry no bearer value to swap: the SDK signs each request with
the secret key, and the signature covers the host, so it cannot be forwarded
to AWS from `127.0.0.1`. An `awsProfile` source with `awsSigV4` delivery
makes the gateway sign instead:

```json
{"name": "AWS_DEV",
 "source": {"awsProfile": {"profile": "dev"}},
 "delivery": {"awsSigV4": {
   "upstream": "https://s3.us-east-1.amazonaws.com", "region": "us-east-1",
   "service": "s3", "endpointEnv": "AWS_ENDPOINT_URL_S3",
   "allow": ["read-only"]}}}
```

- The source runs `aws configure export-credentials --profile P --format
  process`, so SSO, assumed roles, and `credential_process` profiles work as
  the AWS CLI resolves them. The output must be version 1 JSON with
  `AccessKeyId` and `SecretAccessKey`; `SessionToken` and `Expiration` are
  optional. Anything else fails the launch with a message that never quotes
  the output. The two kinds only pair with each other.
- The cage gets `AWS_ACCESS_KEY_ID` set to a placeholder, a random
  `AWS_SECRET_ACCESS_KEY` that signs nothing upstream, `AWS_REGION`, and
  `endpointEnv` set to `http://127.0.0.1:<port>/s/<NAME>`. No
  `AWS_SESSION_TOKEN` is staged. For S3 the SDK's endpoint rules choose path
  style for an IP endpoint, so buckets appear in the path and `allow` rules
  match `/<bucket>/...`. One `upstream` means one region per secret. Two AWS
  secrets in one launch would both set `AWS_ACCESS_KEY_ID`, so that launch is
  refused (`variableCollision`).
- A request is AWS-signed when `Authorization` starts with `AWS4-`. Its
  `Credential=` key id must be exactly this route's placeholder. The gateway
  drops `Authorization`, `X-Amz-Date`, `X-Amz-Security-Token`, and
  `X-Amz-Content-Sha256`, then signs for the upstream host with the real
  keys and session token. It signs `host`, `content-type`, `content-md5`, and
  every remaining `x-amz-*` header. The body is hashed by the gateway; the
  agent's hash is ignored unless it chose `UNSIGNED-PAYLOAD` or
  `STREAMING-UNSIGNED-PAYLOAD-TRAILER`, which only an S3 binding accepts;
  any other `service` refuses them (`awsUnsignedPayload`).
- The AWS placeholder has no substitution surface. As a bearer token, in a
  query (presigned URLs), or anywhere besides the key id, it is refused with
  `surfaceNotAllowed`. `allow` rules, runtime binding, the audit-first
  forward record, and response scrubbing all apply as for
  `gateway` delivery.
- Expiry is the earlier of `expires` and the credentials' `Expiration`.
  Credentials are re-read every 5 minutes, or every `refresh` when that is
  shorter (a longer `refresh` never stretches the 5 minutes), using the
  refresh path in "Expiry and rotation"; each refresh takes the new
  `Expiration`. A request that arrives after `Expiration` waits for a fresh
  read before it is refused with `expired`; a failed read is not repeated for
  5 seconds.
- Responses are scrubbed of each generation's key id, secret key, and session
  token; each becomes the placeholder. S3 error bodies echo the key id.
- A binding cannot sign for a service that mints credentials. The decoder
  refuses `sts`, `iam`, `sso`, `sso-oauth`, `awsssoportal`, `awsssooidc`,
  `signin`, `cognito-identity`, `cognito-idp`, `s3express`, `ecr`,
  `ecr-public`, and `codeartifact`: a call such as `AssumeRole`,
  `CreateAccessKey`, or `GetAuthorizationToken` would return new credentials
  the gateway has no way to scrub. As defence in depth, for every service except `s3` a response
  that contains the field name `SecretAccessKey` is refused
  (`awsCredentialsInResponse`). While the first 64 KiB of the response are
  held, the agent gets a plain `502` and none of it; if the name shows up
  later, the stream is cut short just before it. An S3 binding passes object
  bodies through untouched.
- The credential set is spent only by the gateway. An MCP server or an
  `audit forward` header that names an `awsProfile` secret is refused
  before the profile is read.
- Limit: query-protocol services (`ec2`, `sqs`, `sns`, `rds`,
  `elasticloadbalancing`, `autoscaling`, `cloudformation`, `elasticache`,
  `redshift`, `ses`, `sdb`, `cloudsearch`, `importexport`, `monitoring`) take
  the action as a parameter, so `GET /?Action=TerminateInstances` is a GET on
  `/`. Method and path rules cannot tell a read from a write there, and the
  decoder refuses the `read-only` preset for them. Scope the profile's IAM
  policy for those services.
- Limit: `allow` matches the method and path only. Signed headers such as
  `x-amz-copy-source` name other resources, so a `PUT` allowed on
  `/my-bucket/*` can still copy from a bucket the rules do not list. Scope
  the profile's IAM policy as well; the gateway never widens it.

| refusal | status | misuse | when |
|---------|--------|--------|------|
| `awsKeyMismatch` | 403 | yes | the key id in `Credential=` is not this secret's placeholder, or names a non-AWS secret |
| `awsUnsignedPayload` | 400 | no | `X-Amz-Content-Sha256` is `UNSIGNED-PAYLOAD` or `STREAMING-UNSIGNED-PAYLOAD-TRAILER` on a binding whose `service` is not `s3`. Send the body with a payload hash |
| `awsCredentialsInResponse` | 502 | no | the upstream's answer contains a `SecretAccessKey` field (a non-S3 binding). The upstream produced it, not the agent, so it is not misuse; the response is not forwarded |
| `awsSignedStreaming` | 400 | no | `X-Amz-Content-Sha256` is a signed-chunk or event-stream mode (`STREAMING-AWS4-HMAC-SHA256-PAYLOAD`, `...-TRAILER`, `...-EVENTS`, ECDSA). Each chunk signature chains to the seed signature the gateway replaces. Configure the SDK for unsigned payloads with trailing checksums |

## OAuth tokens

An `oauth` source mints short-lived access tokens at an RFC 6749 token
endpoint. rv runs no browser flow: obtain the refresh token or client secret
elsewhere and store it in the Keychain
(`security add-generic-password -U -s SERVICE -a ACCOUNT -w`).

```json
"source": {"oauth": {
  "tokenURL": "https://oauth2.example.com/token",
  "clientID": "my-client",
  "clientSecret": {"service": "rv.oauth", "account": "example-client-secret"},
  "refreshToken": {"service": "rv.oauth", "account": "example-refresh"},
  "scope": "repo"
}}
```

- With `refreshToken`, rv uses the `refresh_token` grant and writes a
  rotated refresh token back to that item. Without it, rv uses
  `client_credentials`, which needs `clientSecret`. The client secret is
  sent in the form body (`client_secret_post`).
- Only `gateway` delivery spends an `oauth` source. The cage gets a
  placeholder, and the access token is bound like any gateway value:
  surfaces, `allow`, `approve`, runtime binding, audit, and scrubbing.
- A token is minted at launch and again only while the runtime uses it.
  Past half its lifetime, the next request mints in the background; at
  expiry, a request waits for a new one, even when the token lives under
  the 15 s pacing floor. `refresh` caps the interval. A token without a
  positive `expires_in` is re-minted every 30 minutes, and `expires_in` is
  clamped to 1 s through 1 day, so an issuer cannot claim an unbounded
  lifetime. Once the definition's own `expires` has passed, nothing is
  minted: the request is refused `refreshFailed`, without an exchange that
  would rotate the refresh token for nothing.
- `tokenURL` must be https with no query, and is used exactly as written
  (a trailing `/` is kept). Redirects are not followed.
- Exchanges of one refresh token are serialized across rv processes, by a
  lock in `~/.config/rv/secrets-oauth`. Before each one, rv records the
  refresh token's HMAC fingerprint there, never the token.
- Each failure names a recovery:

  | recovery | when | then |
  |----------|------|------|
  | `retry` | no connection; an RFC 6749 error with an unknown code, on any status; client credentials: any HTTP 5xx | a later request tries again |
  | `fixConfiguration` | `invalid_client`, `unauthorized_client`, `invalid_scope`, `unsupported_grant_type`, `invalid_request`, a redirect; `invalid_grant` on client credentials | a later request tries again; fix secrets.json |
  | `reauthorize` | `invalid_grant`; no answer after the request was sent; a 200 without a usable bearer token; refresh grant: an HTTP 5xx without an OAuth `error` body (a proxy may answer after the issuer rotated); a rotated refresh token rv could not store | that refresh token is never sent again |
  | `investigate` | rv stopped mid-exchange | that refresh token is never sent again |

  A 200 whose JSON carries `error` and no `access_token` (GitHub does this)
  is classified by the same code table as a 4xx: nothing was issued. A
  rotated `refresh_token` that arrives with an unusable access token is
  stored before the access token is rejected.

  Storing a different refresh token in the item lifts `reauthorize` and
  `investigate`. So does `rv secrets oauth-reset NAME`, for an issuer that
  does not rotate refresh tokens (Google, say), where a timeout or an rv
  quit mid-refresh would otherwise block the only token for good. It
  deletes the state file for NAME's refresh-token item,
  `~/.config/rv/secrets-oauth/<key>.json` (`<key>` is the first 32 hex
  digits of SHA-256 of `service NUL account`; the file holds the recovery
  class and the token's HMAC, never the token), waiting out an exchange in
  flight. It reads, sends, and prints no token. If the issuer does rotate
  refresh tokens and the earlier refresh may have been spent, store a new
  token instead: resending a spent one can make the issuer revoke the
  grant. rv shows only the issuer's `error` code, filtered, and never its
  description or body.
- A request that needs a new token and cannot get one is refused with
  `refreshFailed` (503), and the `event: refresh` audit record carries the
  recovery. `rv secrets check` mints once and prints the access token's
  fingerprint, the one the gateway audits. `rv secrets scan`
  looks for the stored refresh token and client secret and never mints.

## Request approvals

`approve` on `gateway` or `awsSigV4` delivery takes rules in the same
shape as `allow`. A request they match needs a human's yes, every time:

```json
"approve": [{"methods": ["POST", "DELETE"], "path": "/repos/**"}]
```

- `allow` is checked first; `approve` only holds requests `allow` lets
  through. An ambiguous path is held, not passed. `approve` matching is
  also forgiving where `allow` is exact: a request is held when it matches
  a rule as sent, or after the method is upper-cased, the path is
  lower-cased, and a trailing slash is dropped from path and rule. So
  `DELETE /repos/*/*` also holds `DELETE /repos/o/r/` and `/Repos/O/R`.
  `allow` keeps exact matching.
- The gateway files the request with rv's action-approval service as a
  `secretRequest` action (mandatory human, nothing downgrades it). The
  approver sees the secret's name, method, host, the redacted path without
  its query, the body's size and SHA-256, and the operation-selecting
  headers the request carries (`x-amz-target`, `x-amz-copy-source`,
  `stripe-account`, `content-type`; names and values, placeholders
  redacted, long values cut at 200 bytes). Never the secret value, the
  placeholder, the `Authorization` value, or the body.
- The action binds the full request target (query included), the body, and
  the request headers by SHA-256. A retry with any other query, body or
  bound header is a different action and a new approval. Headers are
  hashed before substitution with names lowercased and sorted and
  placeholders redacted, so the hash does not depend on the runtime.
  These volatile headers, which an SDK changes between retries of one
  call, are left out: `authorization`, `date`, `x-amz-date`,
  `x-amz-content-sha256` (the body is bound separately),
  `x-amz-security-token`, `amz-sdk-invocation-id`, `amz-sdk-request`,
  `user-agent`, `x-amz-user-agent`, `content-length`, `traceparent`,
  `tracestate`, `x-amzn-trace-id`, `x-request-id`, `idempotency-key`, and
  hop-by-hop headers (`connection`, `keep-alive`, `te`, `trailer`,
  `transfer-encoding`, `upgrade`, `expect`, `accept-encoding`, `host`,
  `proxy-*`). Every other header is bound, so a client whose other headers
  vary between calls is asked again, never waved through.
- An approval is filed for one placeholder, so one runtime. Another
  runtime's identical request files its own approval and never waits on or
  spends this one.
- The request is held up to 20 seconds. Then it is refused with
  `approvalPending` and `Retry-After: 5`. Once the human approves, the next
  identical request consumes the approval and is forwarded. Each approval
  forwards one request.
- At most 16 requests are held at once (the gateway has 64 connection
  slots); past that, a request checks once and is refused if still pending.
- After the human approves, the gateway reads the secret again before it
  forwards: a placeholder revoked or expired during the hold is refused
  (`unknownPlaceholder`, `expired`), and a value refreshed during the hold
  is substituted fresh.
- The approval is consumed before the AWS signature and before the
  `event: forward` audit record. If either then fails (`auditUnavailable`,
  a signing refusal), the request is not forwarded and the approval is
  spent; the next request asks again. The forward record has to stay last
  before the send, so this order is deliberate.
- Approvals need the runtime's admission channel and a live agent
  principal: a runtime launched with an agent definition. Otherwise, a
  request `approve` matches is refused with `approvalUnavailable`.
- Revoking the lease or ending the runtime cancels its open approvals.

| refusal | status | misuse | when |
|---------|--------|--------|------|
| `approvalPending` | 403 | no | filed and not yet approved; retry the identical request (`Retry-After: 5`) |
| `approvalDenied` | 403 | no | the human denied it, it expired or was cancelled, or the approval could not be consumed. The next request files a new one |
| `approvalUnavailable` | 403 | no | no approval service for this runtime, no live agent principal, or the service declined to file it (for example, 8 approvals already open for the agent) |

## Audit

Every gateway request writes `secret.use` events to `audit.jsonl`. None of
them carries the value, the placeholder, or the query string.

- A forwarded request is recorded twice: `event: forward` before it leaves
  rv, and `event: request` with the outcome. **If the forward record cannot
  be appended, the request is not forwarded.** The agent gets `503` ("the
  audit log could not record this request").
- `detail.activity` is one of:

  | activity   | meaning                                                         | decision |
  |------------|-----------------------------------------------------------------|----------|
  | `brokered` | value placed and forwarded; the upstream answered               | allowed  |
  | `blocked`  | refused by the secret's own policy (see below)                   | denied   |
  | `refused`  | refused for another reason: malformed, no or unknown placeholder, too large, unsafe value, audit unavailable, runtime unverified, `expired`, `refreshFailed`, `awsSignedStreaming`, `awsUnsignedPayload`, `awsCredentialsInResponse`, `approvalPending`, `approvalDenied`, `approvalUnavailable` | denied |
  | `error`    | forwarded, but no upstream response arrived                     | failed   |
  | `refreshed` | `event: refresh`; a refresh swapped in a new value (new `fingerprint`) | info |
  | `refreshFailed` | `event: refresh`; a refresh could not read the provider (`reason`) | failed |

- Other `detail` fields: `refusal` (code), `method`, `path` (placeholders
  redacted, a percent-encoded placeholder decoded and then redacted),
  `surfaces` the value was placed on, `status` sent to the agent,
  `upstreamStatus` (it differs after the 401 to 502 rewrite or a refused
  compressed response), `durationMs`, `upstream`, and the value's
  `fingerprint`.

A `blocked` request also writes a `secret.misuse` event with
`detail.severity: high`: the refusal code, method, and redacted path. The
codes are `foreignPlaceholder`, `surfaceNotAllowed`, `repeatedPlaceholder`,
`outsideAllowRules`, `encodedPlaceholder`, `ambiguousPath`, `echoMethod`,
`runtimeMismatch`, `awsKeyMismatch`, and `binaryMismatch`. The event's `runtime` is the runtime the presented
placeholder was leased to (absent for a percent-encoded placeholder, which
is never looked up). A client using its placeholder as configured never
triggers one, so it usually means a prompt-injected agent is probing, or a
placeholder was copied out of its runtime. In
`--format ocsf` it is a Detection Finding (2004), severity High,
`is_alert: true`. `rv audit --kind secret` shows both kinds.

`rv secrets list` and `rv secrets describe` show each gateway secret's
surfaces and allow rules (`allow: any method and path` when it has none),
and any expiry and refresh interval.
