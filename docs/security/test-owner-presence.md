# Test owner presence

Automated tests and cloud agents have no person to type the owner's login
password. Without one, nothing that needs the owner can be tested end to
end on Linux: `rv allow-once`, `rv allow-once mint`, and the owner actions
(`rv packs`, `rv safety`, `rv allowlist`, policy changes and the rest of
what `OwnerConfirmation` gates). A container's root account usually has no
password at all, so even a person could not approve there.

The test owner presence is a build of rv in which rvd checks the owner
against a password the test harness chose, instead of the login password.
It exists only in builds made for tests. A release never contains it.

## What it is

In a test-owner-presence build:

- **rvd**, started with `RV_TEST_OWNER_PASSWORD` set and not empty, checks
  each owner proof against that value instead of running `unix_chkpwd`. It
  says so on stderr (`rvd: TEST BUILD (rv-test-owner-presence) …`), and
  `rvd --version` ends in `(rv-test-owner-presence build)`. With the
  variable unset or empty it runs `unix_chkpwd`, as a release does.
- **rv**, given `RV_TEST_OWNER_PASSWORD`, sends that value where it would
  read the password from the terminal, and skips the "this account has no
  password" pre-check (`passwd -S`), since that rvd does not check the
  account's password.

Nothing else changes. rvd still decides: the CLI only hands over a
password, as before. The caller must still be an authenticated peer, one
check runs at a time, five wrong passwords in ten minutes lock checks for
ten minutes, and every approval is written to the audit chain before it
counts. `rv allow-once` still needs a terminal (a pseudo-terminal does), a
code rvd issued, and the code's own description from rvd.

Only the leaf check is replaced: `OwnerPresence.liveChecker` picks
`TestOwnerPasswordChecker` (constant-time compare, the same refusals as
`unix_chkpwd` for empty, over-long or NUL-containing passwords) in place of
`UnixChkpwdChecker`. The code is in `Sources/RVService/TestOwnerPresence.swift`
and three small `#if` blocks in `OwnerPresence.swift`, `RVDLaunch.swift` and
`Sources/RVCLI/OwnerConfirmation.swift`.

## How a build gets it

`Package.swift` defines the Swift compilation condition
`RV_TEST_OWNER_PRESENCE` for `RVService`, `RVCLI` and their test targets
only when both hold:

1. `RV_TEST_OWNER_PRESENCE=1` is in the environment of the `swift build`
   that evaluates the manifest, and
2. the build configuration is debug (`.when(configuration: .debug)`).

So:

| Build | Contains it |
| --- | --- |
| `swift build` (debug), the default and what CI's `swift test` uses | no |
| `RV_TEST_OWNER_PRESENCE=1 swift build` (debug) | yes |
| `swift build -c release`, with or without the variable | no |
| `Scripts/release.sh` | no, and it refuses to run with the variable set |

Checked on Linux: `RV_TEST_OWNER_PRESENCE=1 swift build -c release
--product rvd` gives an rvd whose `--version` is plain and which carries
none of the markers below; the same variable on a debug build gives one
that carries all three, stripped or not.

The variable at run time does nothing in a build without the feature: the
code that reads it is not compiled. `TestOwnerPresenceTests` checks that
rvd's checker stays `unix_chkpwd` with the variable set in a normal build.

Keep the test build in its own scratch directory, so it never replaces the
binaries of a normal build:

```
RV_TEST_OWNER_PRESENCE=1 swift build --scratch-path .build/test-owner-presence
```

## The release guard

`Scripts/check-no-test-owner-presence.sh` reads binaries as bytes and fails
if any carries one of three markers the feature always leaves, stripped or
not: the string `rv-test-owner-presence`, the string
`RV_TEST_OWNER_PASSWORD`, and the type name `TestOwnerPasswordChecker`
(Swift keeps type names in its metadata). `Scripts/release.sh` runs it over
the whole stage before signing, so the release workflow fails on a stage
that has it. `Scripts/test-owner-presence-e2e.sh` checks that the guard
does fail on a test build, so a guard that stopped finding the markers
would be noticed.

## Running the flows

```
RV_TEST_OWNER_PRESENCE=1 swift build --scratch-path .build/test-owner-presence
swift build                                  # the normal build, for the last check
Scripts/test-owner-presence-e2e.sh .build/test-owner-presence/debug
```

As any user, root included, with no systemd and no session bus, in a
throwaway `HOME` and `XDG_RUNTIME_DIR`, it runs the real rvd and rv:

- the hook denies `git reset --hard` with a code;
- redeem is refused with no password, with no terminal, and with a wrong
  password; it grants with the right one; the grant allows the command
  once;
- `rv packs disable` is refused with no password and with a wrong one,
  and done with the right one;
- five wrong passwords lock owner checks, the right one included;
- `rv audit verify` passes and the log has the `owner.action` events;
- the same build's rvd with no password set refuses the password the CLI
  sends (it went to `unix_chkpwd`);
- a normal rvd given the variable, with the test build's rv sending the
  password, approves nothing: the refusal is rvd's login-password check,
  not the CLI's "needs a terminal", so the normal rvd was really asked.

## Why this keeps the trust model

The property rv relies on is that an agent cannot approve its own command:
it has no finger and does not know the password, and rvd, not the caller,
decides. A release keeps that property unchanged, because the release
contains none of this code, which the release guard checks.

In a test build the property does not hold, by design, and the build
gives **no protection against the agent at all**. The agent runs as the
owner's uid, and any process of that uid can:

- read the password from `/proc/<rvd pid>/environ` (rvd is not
  non-dumpable, and same-uid processes may read each other's environment
  and memory), or from the environment of the `rv` it was given to;
- kill rvd and start the same build's rvd again with a password of its
  own choosing, then approve anything with it.

So "the agent does not know the password" is not true of a test build in
any sense that matters. Removing the variable from rvd's environment after
reading it would not change that: `/proc/<pid>/environ` shows the
environment as the process started, `unsetenv` does not erase it, and the
restart above needs no secret anyway. That is why rvd does not try.

A test build exists to exercise the plumbing (the CLI, the socket, rvd's
checks, the lockout, the audit chain) with nobody present, in a throwaway
environment. Never install one, or run its rvd, where an agent works
against real code, credentials or policy. What keeps it out of real use:

- a normal `swift build` does not contain it, so building from source
  for use does not get it by accident;
- `-c release` cannot contain it, whatever the environment;
- the release script refuses the variable and checks its stage;
- a test build says what it is in `rvd --version`, and rvd says on
  stderr when it starts with the test check.

## What is not covered

- **macOS.** rvd shows its own LocalAuthentication prompt there and the
  password checker is never asked, so a test build on macOS behaves like a
  normal one. Driving that prompt needs a different seam (an
  `OwnerAuthenticating` stand-in) and was not done.
- **The daemon-down fallback** (`rv uninstall`, `rv host mode` with rvd
  stopped) runs `unix_chkpwd` in the CLI and is unchanged.
- **The MCP approvals custodian** checks the password with PAM in its own
  root helper, not through rvd; `rv mcp approve` and `rv mcp trust` are
  unchanged. `Scripts/linux-custodian-e2e.sh` already drives those with a
  throwaway account that has a real password, which needs root.
- **The CLI's own seam.** In-process CLI tests already stand in for the
  owner with `CLIProcess.Context.ownerAuthOutcome`, which never reaches rvd.
  That seam is unchanged and is not what this build is for.
- **A test build that someone installs anyway.** Nothing stops a person
  from copying a test build into `~/.local/bin`. It says what it is in
  `rvd --version`; `rv doctor` does not warn about it yet.

## Alternative without a special build

On Linux the same flows can run against a normal build: create a
throwaway account, give it a password with `chpasswd`, and drive rv as
that account on a pseudo-terminal. `Scripts/linux-custodian-e2e.sh` does
this for the custodian. It needs root to create the account, changes the
host's account database, and cannot run on macOS, which is why the build
above exists.
