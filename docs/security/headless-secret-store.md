# A secret store for headless Linux

Status: design only. No product code. Needs the owner's security review.

On Linux rv keeps secret values (`rv secrets set`, `rv login connect`,
`rv mcp import`, `keychain` sources) in the freedesktop Secret Service
through `secret-tool` (`Sources/RVIsolation/SecretServiceStore.swift`).
That needs a D-Bus session bus and an unlocked keyring. Cloud containers,
CI runners and most servers have neither: no `/run/user/<uid>/bus`, no
login that unlocks a keyring. There rv refuses to store or read a value,
which is fail closed and correct, and the secrets gateway cannot be used.

This page compares ways to store values on such hosts against rv's
existing threat model and recommends one.

## The bar today

What the Secret Service gives rv on a Linux desktop
([overview.md](overview.md), section 3.4 and known limit 17):

- Values are encrypted at rest under the login password, and unlocked by
  the login.
- Once unlocked, **any process of the user on the session bus can read
  any item**. The Secret Service has no per-application access control.
- rv's protection against the agent is the hook guard rule
  `core.secrets:secret-service`, which refuses an agent's `secret-tool`
  and direct Secret Service D-Bus calls. It reads command text, so it is
  a check on a cooperating agent's tool calls, not a boundary. A program
  that links libsecret and that the agent was allowed to run reads every
  item.

So the honest bar is: values encrypted at rest; at run time, protected
from the agent only by the hook guard. A headless store must be at least
that, and the requirement in the brief, "an agent running as the same
user must not be able to read secrets", is stronger than what Linux
desktops get today. Only a store outside the agent's uid meets it.

## What any option must answer

1. **At rest:** who can read the stored bytes, and with what key.
2. **At run time:** once rv has the value (rvd, the gateway in `rv run`,
   `rv mcp serve`), can a process of the same uid read it? Today, yes:
   those processes run as the user, and same-uid processes can read each
   other's memory (`/proc/<pid>/mem`, `ptrace`) unless Yama restricts it.
   Containers often have no Yama at all.
3. **Unlock:** what opens the store without a person.
4. **Guard:** can the hook guard name the access, as it names
   `secret-tool` today?

Point 2 is the same for every store below as long as the gateway runs as
the user. Any store can only move where the value rests.

## Options

### A. A private session bus with gnome-keyring

Start `dbus-daemon --session` and `gnome-keyring-daemon --unlock` for rv,
and point `DBUS_SESSION_BUS_ADDRESS` at it.

- At rest: gnome-keyring's file under `~/.local/share/keyrings`,
  encrypted with the unlock password. With no person, that password must
  come from somewhere the agent can also read (a file, the environment),
  or be empty, which leaves the keyring file effectively unencrypted.
- Run time and guard: as today.
- Unlock: whatever starts the daemon must hold the password.
- Verdict: no better than a 0600 file, with more moving parts. Good for
  **tests**: it lets the existing Secret Service code and tests run in a
  container. Not a product answer.

### B. The kernel keyring (`keyctl`)

- At rest: nothing. Keys live in kernel memory until reboot (or the
  `@persistent` keyring's expiry). Something must load them at each boot,
  so this is a hand-off, not a store.
- Run time: a key whose permissions grant nothing to "user" and read only
  to "possessor", held in a session keyring that only rvd's process tree
  possesses, is not readable by another process of the same uid through
  `keyctl`. But rvd reads the value into its own memory to use it, and
  same-uid `ptrace` or `/proc/<pid>/mem` reads it there. Anything in the
  user keyring (`@u`) or persistent keyring is readable by every process
  of the uid.
- Guard: `keyctl` and `add_key`/`request_key` are nameable commands.
- Verdict: useful as the channel by which an entry point hands rvd
  values it got from elsewhere (see E). Not a store.

### C. `systemd-creds`

- Encrypts with a host key (`/var/lib/systemd/credential.secret`, root
  only) and/or a TPM2, and decrypts for a service unit
  (`LoadCredentialEncrypted=`). Per-user use goes through systemd's own
  credential service, which decrypts for any process of that uid.
- Needs systemd, which these hosts do not run (that is the problem being
  solved). For a user service it gives no protection from the same uid.
- Verdict: not available headless; where available, protects from other
  uids only.

### D. An encrypted file keyed from a TPM or similar

- At rest: ciphertext sealed to the TPM (or a cloud KMS).
- Unlock: whoever can talk to the TPM device (or holds the KMS
  credential) can unseal. That is the user's uid, so the agent too, unless
  the seal policy requires a PIN, which is a person again.
- Cloud containers rarely expose `/dev/tpmrm0`; this one has none.
- Verdict: protects a copied disk or image, not a running container from
  its own uid.

### E. Values injected from outside the container

The platform holds the value and adds it to requests at an egress proxy
outside the container, or hands it to the entry point before the agent
starts. Some cloud agent platforms already offer the first (an HTTPS proxy
that adds a credential for a named host).

- At rest and at run time: the value never enters the container (proxy
  injection), or enters only the processes the entry point gives it to.
- This is rv's own secrets gateway design, one level further out.
- Verdict: the strongest option where the platform has it. rv's part is
  to recognise it and get out of the way. Whether `rv run` and
  `rv mcp serve` work with no stored value when the credential is added
  outside was not checked for this page.

### F. A secrets custodian under its own account

The approvals custodian's model applied to values: a daemon under its own
system account holds the values in a directory only it can enter; and the
part of the gateway that needs the value (the TLS client that adds the
credential to the upstream request) runs under that account too, so the
user's processes never hold it.

- At rest: a file only the custodian account can read (optionally
  encrypted to a TPM or host key against a copied disk).
- Run time: the agent's uid cannot read the custodian's memory (different
  uid, and `ptrace` across uids needs `CAP_SYS_PTRACE`).
- Unlock: none needed at run time; storing or replacing a value needs the
  owner, through the custodian's presence check, which headless cannot
  give. Values for headless hosts would be provisioned by root at image
  build or entry point.
- Needs root once (an account, a root-started daemon), and not systemd if
  it is started like the design in
  [custodian-without-systemd.md](custodian-without-systemd.md). Does
  nothing when the agent is root.
- Verdict: the only option that meets "the same uid cannot read the
  value". It is a large change: the gateway's credential step moves out
  of the user's process.

### G. A 0600 file in `~/.config/rv`

- At rest: plain text (or encrypted with a key kept beside it, which is
  the same).
- Run time and guard: the hook guard's secret-path catalog already
  refuses an agent's file-tool reads and writes of `~/.config/rv`. A file
  is easier to read in ways the guard cannot see than a D-Bus call.
- Verdict: weaker than today's bar at rest. Listed because it is what
  `~/.config/rv/mcp-oauth/` already does on Linux (known-limits.md).

## Recommendation

1. **Do not add a same-uid store as a product default.** Every option the
   user's account can unlock alone (A, B as a store, C per-user, D without
   a PIN, G) gives the agent the value once the agent runs any program.
   Shipping one would turn today's fail-closed refusal into a store that
   looks protected and is not.
2. **Support E first.** Document that on a cloud platform with egress
   credential injection the value should stay with the platform, and make
   sure `rv run` / `rv mcp serve` and their placeholders work when the
   credential is added outside (no value in rv at all). This should need
   little code and no new store; it was not checked.
3. **Design F as the real headless store,** after the custodian runs
   without systemd. Only F holds against the same uid.
4. **Use A for tests only**, so the existing Secret Service tests can run
   in containers. It must stay out of product code paths.

## What tests would prove it

For F, if built:

- the owner's account cannot list or read the store directory, or read
  the custodian's `/proc/<pid>/mem`, `environ` or `fd/*`;
- a request through the gateway reaches a local upstream with the real
  value while the user's process (`rv run`'s child, `rv mcp serve`) never
  holds it: scan the user processes' memory and environment for the value
  after the request;
- storing or replacing a value without presence is refused;
- with the custodian stopped, every secret use is refused (no fallback to
  any same-uid store);
- the hook guard still refuses the agent's direct access to the
  custodian's socket for anything but what the gateway needs.

For E:

- `rv run --secret NAME` with no stored value and a proxy that adds the
  credential: the upstream sees it, rv never had it, the audit log says so.

For A (tests only):

- `SecretServiceStore` tests pass in a container with the private bus and
  an unlocked keyring, and the same tests are skipped, not failed, without
  them.

## A test helper for A

Not added. It would be a script under `Scripts/` that runs a command with
a private bus and an unlocked keyring, needing `dbus-daemon`,
`gnome-keyring` and `libsecret-tools`:

```
dbus-run-session -- sh -c '
  printf "%s" "$KEYRING_PASSWORD" | gnome-keyring-daemon --unlock --components=secrets >/dev/null
  exec "$@"' sh swift test --skip-build --filter SecretService
```

`SecretServiceTool.availability` accepts `DBUS_SESSION_BUS_ADDRESS` when
`/run/user/<uid>/bus` is absent, which is the case in a container, so no
product change is needed for it. Root-only test failures and the shared
container in this milestone are why it was left out.
