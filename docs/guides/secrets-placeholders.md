# Secrets placeholders

With rv, an agent, a script or an MCP server can call an API without ever
holding the API key. It holds a **placeholder**, a per-launch stand-in
such as `sk-rvph_161db642…`, and a base URL pointing at rv's gateway on
`127.0.0.1`. When a request leaves through the gateway, rv swaps the
placeholder for the real value, sends the request on to the one upstream
the secret allows, and removes the real value from anything that comes
back.

How this was checked: `rv secrets`, `rv run` and their refusals were run
on Linux, including the repository's end-to-end test
(`Scripts/linux-rv-run-e2e.sh`, 13 of 13 passed: real HTTPS upstream,
placeholder swapped, value never in the environment, placeholder refused
from outside the command). Storing a value in the Keychain (macOS), and
placeholders for MCP servers (macOS only), were taken from the source and
not run.

## 1. Store a secret

```text
rv secrets set <name> [--gateway <url> --base-url-env <var> | --provider <id> | --environment]
                     [--allow <rule>]... [--surface header|query|path]... [--placeholder-prefix <p>]
                     [--expires <date>|none] [--refresh <interval>|none] [--resource-profile <id>]
```

`<name>` is the environment variable the program reads. The value is read
from a hidden prompt, or from stdin when you pipe it. Values are 1 byte to
16 KiB with no NUL bytes. The value goes into the Keychain (macOS,
service `rv.secrets`) or the Secret Service keyring through `secret-tool`
(Linux); the definition goes into `~/.config/rv/secrets.json`, which holds
no values.

**A well-known name needs no flags.** `OPENAI_API_KEY`,
`ANTHROPIC_API_KEY`, `GITHUB_TOKEN`, `GH_TOKEN`, `STRIPE_SECRET_KEY` and
`VERCEL_TOKEN` get a curated upstream and least-privilege rules:

| Name | Upstream | Allowed by default |
| --- | --- | --- |
| `OPENAI_API_KEY` | `https://api.openai.com/v1` | `GET,POST /v1/**` |
| `ANTHROPIC_API_KEY` | `https://api.anthropic.com` | `GET,POST /v1/**` |
| `GITHUB_TOKEN`, `GH_TOKEN` | `https://api.github.com` | `github-read` (no GraphQL, so most `gh` subcommands need `--allow "POST /graphql"` too) |
| `STRIPE_SECRET_KEY` | `https://api.stripe.com` | `read-only` |
| `VERCEL_TOKEN` | `https://api.vercel.com` | `read-only` |

```bash
rv secrets set OPENAI_API_KEY
```

That writes this definition (captured from a run; note no value):

```json
{
  "name": "OPENAI_API_KEY",
  "source": {"keychain": {"service": "rv.secrets", "account": "OPENAI_API_KEY"}},
  "delivery": {"gateway": {
    "upstream": "https://api.openai.com/v1",
    "baseURLEnv": "OPENAI_BASE_URL",
    "placeholderPrefix": "sk-",
    "allow": [{"methods": ["GET", "POST"], "path": "/v1/**"}]
  }}
}
```

**Any other name needs a delivery**, or rv refuses:

```text
rv secrets set: ACME_API_KEY is new: pass --gateway URL --base-url-env VAR, or --environment
```

```bash
rv secrets set ACME_API_KEY --gateway https://api.acme.example --base-url-env ACME_BASE_URL --allow read-only
```

Or use a shipped provider profile (`rv secrets providers` lists them:
anthropic, openai, openrouter, github, vercel, stripe, npm, pypi);
`--allow` and `--surface` may only narrow a profile:

```bash
rv secrets set GITHUB_TOKEN --provider github
```

The flags that shape a gateway secret:

| Flag | Meaning |
| --- | --- |
| `--allow` | Methods and paths the placeholder may be spent on: a preset (`read-only`, `github-clone`, `github-read`) or `"GET,HEAD /repos/**"`. Repeatable. Without any rule (and no curated default) any method and path is allowed, and rv prints a note saying so. |
| `--surface` | Where in a request the placeholder may be swapped: `header` (default), `query`, `path`. A placeholder anywhere else, or twice on one surface, is refused with `403`. The body is never a surface. |
| `--placeholder-prefix` | Kept on the front of the placeholder, for SDKs that check a key's format (`sk-`). |
| `--expires` | `2026-12-31` or `2026-12-31T18:00:00Z`; past it launches fail and the gateway refuses. |
| `--refresh` | Re-read the value from its store this often in running sessions (`15m`, minimum `1m`). |
| `--environment` | Put the real value in the environment instead. Weaker; `rv run` refuses such secrets. |

`--allow`, `--surface` and the delivery apply only when the secret is
first defined. To change them later, edit `secrets.json`. Running
`rv secrets set NAME` again for an existing secret stores a new value,
which running gateway sessions use from their next request.

Values can also come from 1Password, Vault, AWS Secrets Manager, GCP,
Azure, Infisical or Bitwarden, or an OAuth token minted by rv: write the
`source` in `secrets.json` by hand (`rv help secrets` lists the source
kinds). On Linux the Keychain-backed sources (`rv secrets set`,
`rv login connect`) need `secret-tool`; without it:

```text
rv secrets set: could not store OPENAI_API_KEY (no secret store: rv keeps values in the Secret Service through secret-tool; install libsecret-tools and a keyring such as gnome-keyring)
```

Check what you have:

```bash
rv secrets list
```

```text
EXAMPLE_API_KEY  host $EXAMPLE_REAL_KEY  gateway → api.example.com via $EXAMPLE_BASE_URL  profiles: -  surfaces: header  allow: read-only
```

```bash
rv secrets check
```

```text
ok    EXAMPLE_API_KEY  fingerprint 24ee62e4197a514c  host $EXAMPLE_REAL_KEY
```

`check` reads each value from its store and prints a fingerprint, never
the value. `rv secrets remove NAME` deletes the definition and the
rv-stored value.

## 2. Run a command with placeholders: `rv run`

```text
rv run --secret <name> [--secret <name>]... -- <command> [args...]
rv run --all -- <command> [args...]
```

```bash
rv run --secret OPENAI_API_KEY -- codex
```

```bash
rv run --all -- claude
```

`--all` takes every secret that can be a placeholder and names on stderr
the ones it skips (environment-delivered ones, and ones limited to an
agent with `agents`). Everything after `--` is the command, `--help`
included.

### What the command sees

A run with a test secret, captured on Linux (the real value was in the
parent shell as `EXAMPLE_REAL_KEY`, and a copy of it inside `COPY_OF_IT`):

```text
rv run: removed COPY_OF_IT, EXAMPLE_REAL_KEY from the command's environment: each held or contained a selected secret's real value
rv run: EXAMPLE_API_KEY staged as placeholders for this command only. Not a sandbox: see `rv help run`.
EXAMPLE_BASE_URL=http://127.0.0.1:35027/s/EXAMPLE_API_KEY
EXAMPLE_API_KEY=ex-rvph_161db642c2cb04feb42bf78aae3d1bd7
```

So the command gets:

- the secret's variable set to a **placeholder**, made for this launch
  only;
- the base URL variable set to rv's gateway, `http://127.0.0.1:<port>/s/<NAME>`.
  Most SDKs read a base URL variable (`OPENAI_BASE_URL`); a client that
  does not must be pointed at it;
- your environment otherwise, minus: every variable the selected secrets
  set, a `hostEnvironment` source's variable, any variable whose value is
  a selected secret's real value or contains one 12 bytes or longer
  (`Bearer <token>`, a URL with the password in it), and `VAULT_TOKEN`
  when a selected secret comes from Vault. Removed names are listed on
  stderr.

The command starts suspended, its placeholders are bound to its process
tree, and only then does it run. It gets the terminal when rv holds it
alone; SIGINT, SIGQUIT, SIGTERM and SIGHUP sent to rv are passed to it.
When it exits, rv revokes the placeholders, stops the gateway and kills
what is left of its process group.

Exit status: the command's own, or 128+N if signal N ended it. rv's own
codes: **125** rv refused and the command never started, **126** it could
not be started, **127** not found. For example:

```text
rv run: no secrets selected; pass --secret NAME (repeatable) or --all
rv run: secret NOPE is not defined in secrets.json
rv run: secret OPENAI_API_KEY: not found: keychain item rv.secrets / OPENAI_API_KEY
```

### How the swap works

1. The command sends its request to the base URL with the placeholder
   where the key goes (`Authorization: Bearer sk-rvph_…`).
2. The gateway checks the connection comes from the command or a process
   it started (on Linux by reading `/proc`), that the request matches the
   secret's `allow` rules, and that the placeholder sits only on allowed
   surfaces.
3. It replaces the placeholder with the real value and sends the request
   to the secret's `upstream`, over HTTPS, and nowhere else.
4. In the answer, an echoed real value (raw, percent-encoded or
   JSON-escaped) is turned back into the placeholder; base64 of it
   becomes `[rv:redacted]`; a compressed answer is refused with `502`.

What the program gets back when the gateway refuses:

| Status | Why |
| --- | --- |
| `403` | The placeholder came from a process outside the command's tree, the request is outside the `allow` rules, the placeholder is on a surface the secret does not allow, or it appears twice. |
| `400` | With `allow` rules, a path an upstream could read differently (`%2f`, `..`, `//`, …). |
| `502` | The upstream answered `401` (the stored value was rejected; no challenge is passed on), or answered compressed. Update the value with `rv secrets set`. |
| `408` | The client was too slow to send its request. |
| `503 gateway busy` | Too many connections at once. |

Each use is recorded as `secret.use` in the audit log, and each refusal
by the secret's own policy as `secret.misuse` (see [the audit
log](audit-log.md)).

## 3. Give an MCP server placeholders (macOS only)

A local MCP server in `~/.config/rv/mcp.json` normally gets the **real**
value of each secret in its `secrets` map, and of each `${secret:NAME}`
in its arguments. To hand it a placeholder instead, list the secret under
`placeholders`:

```json
{
  "name": "llm-tools",
  "command": "llm-mcp",
  "placeholders": ["OPENAI_API_KEY"],
  "sandbox": {"network": false, "hosts": ["api.openai.com"]}
}
```

Rules, from the source:

- **macOS only.** On Linux a server with `placeholders` is refused.
- The server must have an enforced `sandbox` with `network` false
  (giving `sandbox.hosts` sets that for you).
- Local (`command`) servers only; a remote server with `placeholders` is
  rejected. A secret goes to a server one way: listing it both in
  `placeholders` and in `secrets` or `args` is rejected.
- Each listed secret must be in `secrets.json`, with gateway or
  `awsSigV4` delivery, an `https` (or loopback) upstream, no `agents`
  filter, no `approve` rules, and a source other than `hostEnvironment`.
  Otherwise that server is refused, with the reason on serve's stderr,
  and the other servers still start.
- `rv mcp trust` shows each placeholder, the variables it sets and the
  upstream its real value goes to, and signs nothing if `secrets.json`
  cannot be read or lacks a listed secret. `secrets.json` itself is not
  covered by the `mcp.json` signature, so once a server runs bound,
  `rv mcp serve` writes one stderr line per placeholder saying what it
  set and where the value goes. Read that line after you change
  `secrets.json`.
- A placeholder server is started suspended, bound, then resumed; only
  it and its live descendants can spend the placeholders, through
  serve's own gateway.

## App logins, once

`rv login connect vercel` imports the Vercel or
GitHub login you already have (CLI auth file, token variable, or
`gh auth token`; paste as fallback) into the Keychain as a gateway
secret, so agents use it through rv instead of logging in again.
On Linux rv keeps stored values in the Secret Service keyring (GNOME
Keyring, KWallet, KeePassXC) through `secret-tool` (package
`libsecret-tools`), which needs a session bus and an unlocked keyring;
the hook guard refuses an agent's own `secret-tool` and Secret Service
D-Bus calls, since that keyring has no per-app prompt.
`rv login list` / `check` report status and fingerprints, never values;
`rv login logout <app>` removes it.

## Vault addresses

`VAULT_ADDR` is set to the same origin: rv never sends your Vault token to a
server the environment does not name.


## What is protected and what is not

Protected:

- The real value is never in the program's environment, so it cannot
  print it, log it or paste it into a transcript.
- A placeholder is spent only from the process tree it was issued to,
  only toward its one upstream, only for requests the `allow` rules
  permit, and only while that program runs.
- Echoes of the value in answers are scrubbed.

Not protected:

- **`rv run` is not a sandbox.** The command runs as you, with your files
  and network. It can read anything your user can, which may include
  where the real value lives: a `.env` file, `~/.aws/credentials`, a
  signed-in password manager CLI, the keyring. It may be able to read its
  parent processes' environments, rv's included.
- Secrets you did not select pass through `rv run` unchanged.
- A process that leaves the command's tree in a way that reparents it can
  no longer spend the placeholders, but it is also not killed when the
  command exits.
- **An MCP server's cage does not stop it asking your keychain or a
  provider for the value itself** (the macOS cage allows Mach and XPC
  lookups). rv does not give it the value; it does not prevent every
  other way of getting it.
- `approve` rules (a human's yes per request) are refused outside a
  workspace: `rv run` refuses matching requests, and MCP placeholder
  servers with such rules are refused.

Limits you should know before relying on the gateway (details in
[Known limits](known-limits.md)):

- On **macOS** a `GET` or `HEAD` through the gateway can be sent to the
  upstream **up to three times**, credential included, when the upstream
  drops the connection before answering. macOS's networking library does
  this and has no setting to stop it. `POST`, `PUT`, `PATCH`, `DELETE` and
  `OPTIONS` are sent once, and on Linux every request is sent once.
- On **Linux** an answer **larger than 64 MiB** from an upstream faster
  than the gateway can forward it is **cut off**, without the chunked
  terminator, so the client sees an incomplete answer, never a complete
  one. On loopback a 256 MiB answer from an unthrottled upstream was cut
  after 32 MiB.
