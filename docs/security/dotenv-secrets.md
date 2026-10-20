# Dotenv secrets: dev tier and enterprise posture

A `dotenv` secret source binds a name to a variable in a `.env` file:
`{"dotenv": {"path": "/abs/path/.env", "variable": "STRIPE_SECRET_KEY"}}`.
rv reads the file host-side at lease time and stages the value (or a gateway
placeholder) exactly like every other source. The cage never receives the
file handle. Bindings are created only by explicit user action
(`rv init --dotenv`, `rv secrets import --dotenv <file>`); values stay in
`.env` until `rv secrets harden` moves them to the Keychain. rv never edits,
chmods, deletes, or git-ignores the user's `.env`.

## Stated residuals (dev tier)

- **The bound `.env` is trusted input at every launch.** Whoever can write
  the file chooses the values the next lease stages. Lease-time trust checks
  refuse non-owner files, group/world-writable files, files with allow ACL
  entries, FIFOs/devices, and files over 256 KiB, but a writable-by-owner
  file is the operator's own input. Bindings store the canonical path
  captured at import: if that path later resolves elsewhere, the lease
  refuses instead of reading the retargeted file (re-import to rebind).
- **The bound `.env` usually lives inside the cage-writable workspace.**
  A cage process can edit `<project>/.env`, and the next lease reads the
  edited values: cross-launch persistence is inherent to the dev tier.
  Drift is visible, not prevented: every lease records a per-secret audit
  fingerprint (`rv audit --kind secret.use`), and `rv secrets check` prints
  current fingerprints. `rv secrets harden` or a strict managed policy
  closes this residual; there is no per-launch warning.
- **0644 is allowed.** A group/world-readable `.env` resolves (dev-tier
  reality) and is marked `[file-backed]` in `rv secrets list`. Anyone who
  can read the file has the values; rv adds no at-rest protection for
  dotenv sources and promises none.
- **Bindings are machine-global.** `secrets.json` is per-machine
  (`~/.config/rv/secrets.json`), so a name bound to project A's `.env`
  cannot also bind project B's. Import skips name the existing locator.
  Moving a project breaks its bindings until they are re-imported; stored
  paths are canonical and echoed at import time. `rv init --dotenv` wires a
  pre-existing name into the new profile only when it is already bound to
  that project's own `.env`; a name bound elsewhere is reported, never
  wired, in dry runs and writes alike. Loader/interpreter variable names
  (`LD_*`, `DYLD_*`, `NODE_OPTIONS`, …) are never bound from a file.
- **One file generation per lease.** All secrets from one file in a single
  lease come from one snapshot; a mid-lease identity change fails that
  file's remaining secrets. Nothing is cached across leases. Reads verify
  the file's identity after the read, so a replacement between canonicalize
  and open is refused; a same-inode, same-mtime, same-size in-place rewrite
  remains possible, but that is an owner edit — trusted input above.
  Parent-directory writers are likewise covered by the trusted-input
  residual: they can replace the file's contents, not retarget the binding
  (the canonical-path check refuses that) and not supply a file owned by
  someone else (the owner check refuses that).

## Strict posture (enterprise tier)

Sample policy forbidding dotenv and environment delivery:

```json
{"version":1,"secrets":{"allowedSources":["keychain","vault"],"allowEnvironmentDelivery":false}}
```

With it installed, launch, `rv secrets check`, `rv secrets import --dotenv`,
`rv init --dotenv`, MCP secret resolution, `rv secrets scan`, the git hook,
and `rv audit forward` header resolution all fail closed for dotenv-bound
secrets with `organization policy: <NAME> uses a dotenv source, which is not
allowed`. Scan and the hook treat any secret they could not check (policy
denial or resolution failure) as a failed gate, never a clean pass. MCP and
audit-forward enforce the delivery axis too: a secret with environment
delivery is refused when `allowEnvironmentDelivery` is false (release note:
this can break existing MCP deployments whose secrets use environment
delivery; `rv managed status` names dotenv's effective status and the
count of dotenv-bound secrets).

Default-allow warning: a policy without `allowedSources` allows dotenv.
Shipping this binary to a fleet silently grants the new source kind unless
the policy enumerates sources. `rv managed status` says so explicitly
whenever a dotenv binding exists.

## Rollout order

1. **Binaries before policies.** A policy or `secrets.json` mentioning
   `dotenv` makes older binaries fail the whole document closed (unknown
   kind). Ship binaries fleet-wide before pushing either.
2. **Migrate, then tighten.** `rv secrets harden --all` works under a
   dotenv-deny policy by design (carve-out): it reads the dotenv value,
   stores it in the Keychain, verifies by read-back, and rebinds, with its
   own audit event. It still requires `keychain` to be an allowed source.
   After hardening, rotate each value at the provider and remove its line
   from `.env`; `rv secrets scan` keeps flagging the unrotated file.
3. **Downgrade note.** Downgrading past this feature with dotenv bindings
   or a dotenv-mentioning policy in place fails closed at decode; remove
   the bindings (or harden them) before downgrading.

Lease-time note: policy is evaluated when a lease is taken. Gateway
placeholders already minted keep working until the runtime ends; the
gateway does not re-check policy per request.
