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
note. The curated defaults (`GITHUB_TOKEN`, `OPENAI_API_KEY`, and so on)
still allow everything, so existing `gh` and API workflows keep working.

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
- A runtime's processes are: its leader's process group; every live
  descendant of the leader; and, when the leader leads its own session
  (terminal runtimes), that session. The cage denies the `setsid` and
  `setpgid` syscalls, but `posix_spawn` with `POSIX_SPAWN_SETSID` or
  `POSIX_SPAWN_SETPGROUP` (Node's `detached: true`) moves a child out of the
  group, and the descendant walk keeps those children in.
- On each request, rv takes the connection's port pair and looks, with
  libproc, for one of those processes holding the client socket: the group
  first, then the descendants (at most 4096), then the session. Each match
  is re-checked after the scan so a reused pid does not count. Every
  placeholder in the request is checked, so one runtime cannot spend
  another's placeholder beside its own.
- Not a member: `403`, refusal `runtimeMismatch`, and a `secret.misuse`
  finding. Another runtime, a host shell, or any other local process
  holding a copied placeholder lands here.
- Cannot tell: `403`, refusal `runtimeUnverified`, no misuse finding. This
  covers a libproc failure, a group whose leader is gone or was reused, a
  descendant walk past its bound, and a placeholder whose runtime has no
  recorded group. The gateway fails closed.

Limits: the check binds to the runtime, not to a binary inside it; any of
its processes may spend the placeholder. A process that left the group and
whose parent then exited (reparented to launchd) is no longer a descendant;
unless it is in a terminal runtime's session, its requests are refused as
`runtimeMismatch`. Linux has no check (no
libproc), so every gateway request there is `runtimeUnverified`. Contained
launches on Linux are already refused before exec.

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

A value split across response chunks is still caught. The gateway holds back
only a trailing partial match, so streamed output (SSE, token streams) that
cannot be the start of the value is forwarded at once.

Compressed bodies cannot be scanned. The gateway sends
`Accept-Encoding: identity` upstream in place of the agent's own header. If
a response with a body still carries a `Content-Encoding` other than
`identity`, the gateway returns `502` and forwards none of it.

Not covered: double encodings (percent inside JSON, base64 of an escaped
value), hex, HTML entities, and payloads that are themselves archives
(`application/zip`, `application/gzip`).

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
  | `refused`  | refused for another reason: malformed, no or unknown placeholder, too large, unsafe value, audit unavailable, runtime unverified | denied |
  | `error`    | forwarded, but no upstream response arrived                     | failed   |

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
and `runtimeMismatch`. The event's `runtime` is the runtime the presented
placeholder was leased to (absent for a percent-encoded placeholder, which
is never looked up). A client using its placeholder as configured never
triggers one, so it usually means a prompt-injected agent is probing, or a
placeholder was copied out of its runtime. In
`--format ocsf` it is a Detection Finding (2004), severity High,
`is_alert: true`. `rv audit --kind secret` shows both kinds.

`rv secrets list` and `rv secrets describe` show each gateway secret's
surfaces and allow rules (`allow: any method and path` when it has none).
