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
