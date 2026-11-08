# rv domain glossary

Terms the code and reviews use with one meaning. Add a term when a module is named after it.

## Secrets

**Secret definition** — one entry in `secrets.json` (or imported from a Varlock schema): a name, a **source** (where the value is read), a **delivery** (how it reaches a runtime), and optional expiry, refresh and binaries. `SecretDefinition`.

**Secret release** — the decision that lets a value leave its provider for one **release target**, and the shaping that goes with it: organization policy, gateway-only, expiry, the provider read, OAuth access-token unwrapping, AWS credential-set parsing, and the target's text rule. Every path that reads a secret value to hand it on goes through `SecretRelease.release(_:to:)`. All definitions are admitted before any is read, so a refused set reads, mints and prompts for nothing.

**Release target** — where a released value goes, each with its own organization rule and text rule. `SecretTarget`:
- *cage*: a contained runtime, by the definition's own delivery (environment variable, gateway placeholder, AWS signing).
- *stdio server*: a stdio MCP server, which holds the real value whatever the delivery says.
- *header*: an HTTP header rv sends from the host (remote MCP server, `audit forward`).

**Secret refusal** — why a release did not happen: invalid organization policy, an organization rule, gateway-only, expired, a provider failure, or an unusable value. Callers own the wording; the decision is the release's. `SecretRefusal`.

**Gateway-only** — a value that is not a lasting token (an AWS credential set, an OAuth access token the gateway keeps fresh). Only a cage's gateway may spend it; stdio servers and headers are refused.

**Lease** — what one launch gets from the launch broker: environment entries plus the gateway placeholders to revoke when the runtime ends. The broker builds a lease from released secrets.

## Guard

**Host mode** — how rv guards one hook host: `block` (enforce, the default), `observe` (allow and record what would have been blocked) or `off` (rv's hooks removed from that host). Stored under `guard.hosts` in `config.json`; rvd resolves `RV_GUARD_MODE` > host mode > `guard.mode` > enforce, and an organization gate still pins enforce. `HostMode`, `HostModeStore`.

**Observed block** — a denial-ledger row for an observe-mode evaluation that enforcement would have denied (`"observed": true`; `command.observed` in the audit trail). The agent was not blocked.
