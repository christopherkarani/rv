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
  `STREAMING-UNSIGNED-PAYLOAD-TRAILER`.
- The AWS placeholder has no substitution surface. As a bearer token, in a
  query (presigned URLs), or anywhere besides the key id, it is refused with
  `surfaceNotAllowed`. `allow` rules, runtime binding, the audit-first
  forward record, and response scrubbing all apply as for
  `gateway` delivery.
- Expiry is the earlier of `expires` and the credentials' `Expiration`.
  Credentials are re-read every 5 minutes, or every `refresh` when set, using
  the refresh path in "Expiry and rotation"; each refresh takes the new
  `Expiration`.
- Responses are scrubbed of each generation's key id, secret key, and session
  token; each becomes the placeholder. S3 error bodies echo the key id.
- Limit: `allow` matches the method and path only. Signed headers such as
  `x-amz-copy-source` name other resources, so a `PUT` allowed on
  `/my-bucket/*` can still copy from a bucket the rules do not list. Scope
  the profile's IAM policy as well; the gateway never widens it.

| refusal | status | misuse | when |
|---------|--------|--------|------|
| `awsKeyMismatch` | 403 | yes | the key id in `Credential=` is not this secret's placeholder, or names a non-AWS secret |
| `awsSignedStreaming` | 400 | no | `X-Amz-Content-Sha256` is a signed-chunk or event-stream mode (`STREAMING-AWS4-HMAC-SHA256-PAYLOAD`, `...-TRAILER`, `...-EVENTS`, ECDSA). Each chunk signature chains to the seed signature the gateway replaces. Configure the SDK for unsigned payloads with trailing checksums |

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
  | `refused`  | refused for another reason: malformed, no or unknown placeholder, too large, unsafe value, audit unavailable, runtime unverified, `expired`, `refreshFailed`, `awsSignedStreaming` | denied |
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
`runtimeMismatch`, and `awsKeyMismatch`. The event's `runtime` is the runtime the presented
placeholder was leased to (absent for a percent-encoded placeholder, which
is never looked up). A client using its placeholder as configured never
triggers one, so it usually means a prompt-injected agent is probing, or a
placeholder was copied out of its runtime. In
`--format ocsf` it is a Detection Finding (2004), severity High,
`is_alert: true`. `rv audit --kind secret` shows both kinds.

`rv secrets list` and `rv secrets describe` show each gateway secret's
surfaces and allow rules (`allow: any method and path` when it has none),
and any expiry and refresh interval.
