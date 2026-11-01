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
