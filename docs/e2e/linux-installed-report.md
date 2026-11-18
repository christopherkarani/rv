# rv installed and running on Linux: end-to-end report

The first run of rv as an installed product on Linux: built as a release,
installed with `install.sh`, set up, and driven the way a buyer's developer
would use it. Everything was done as a throwaway account (`rv-e2e`) with its
own home, never as the account running the test, and no agent's hooks were
ever pointed at rv. The hook path was exercised by feeding the hook entry
point the JSON Claude Code and Codex send. Only made-up secrets, local fake
upstreams and loopback servers were used.

Every step is in [`Scripts/e2e-installed-linux.sh`](../../Scripts/e2e-installed-linux.sh)
(run as root on a throwaway machine; it creates and removes its own
account, temp dirs and system files, exits 1 on a failed step, and reports
what the host cannot do as SKIP). Final run: **115 pass, 8 fail, 1 skip**.
The failures are the findings below.

## Environment

| | |
| --- | --- |
| Code | `claude/mcp-reliability` at `38f2f82b` (draft PR 587; contains PR 582 and `main`) |
| Distro | Ubuntu 24.04.5 LTS, x86_64, cloud VM (Firecracker) |
| Kernel | 6.18.44 |
| glibc | 2.39 |
| Landlock | yes: `CONFIG_LSM` starts with `landlock`, `rv-isolation-exec --landlock-abi` = 7 (`/sys/kernel/security` is not mounted, so `lsm` there cannot be read) |
| Init | not systemd (PID 1 is the VM's own init); no logind, no `/run/user/<uid>` for sudo/setpriv sessions |
| Swift | official 6.4 RELEASE tarball (`Scripts/install-official-swift-linux.sh`) |
| Extra packages | the release workflow's build deps, `libpam0g-dev`, `patchelf`, `gnome-keyring`, `libsecret-tools`, `dbus-x11` |

## How it was built and installed, and how that differs from a real release

1. **Build:** `Scripts/release.sh` unchanged (C units, `swift build -c
   release`, strip, stage the Swift runtime closure) into
   `.build/release-stage`.
2. **Assets:** `Scripts/release-assets.sh .build/release-stage <dir>
   linux-x86_64`, then `sha256sum -- * > SHA256SUMS`, as `release.yml` does.
3. **Install:** the unmodified `install.sh`, run as `rv-e2e` with
   `RV_INSTALL_VERSION=e2e`. A `curl` shim first on `PATH` rewrites only
   `https://github.com/christopherkarani/rv/releases/download/e2e/*` to a
   loopback HTTP server holding those assets (the `install-smoke.sh --local`
   method, but **not** neutered: the installer's final `exec rv setup`
   runs).

Differences from a customer's `curl -fsSL https://rykanv.com/install | sh`:

- The stage was built on Ubuntu 24.04, so it needs glibc 2.38. Releases are
  built on 22.04 for the 2.35 floor. The binaries' `RUNPATH` names this
  build's toolchain (`/root/.local/share/swift/...`), where a release names
  `/home/runner/...`.
- No `SHA256SUMS.sig`. `install.sh` has no release key pinned yet, so a real
  install does not check one either, and it says so (verified: the warning
  is printed).
- The tag is pinned, so the `/releases/latest` redirect is not exercised.
- The test account's `~/.config/rv/config.json` gets `"analytics":
  {"enabled": false}` before install. Analytics is on by default and posts
  to `us.i.posthog.com`, a third party this test must not call.
- The installer ran under `sudo -u rv-e2e` (pam_umask gives the Ubuntu
  default umask 002), with no logind session and no D-Bus session bus.
  That's like a container, WSL without systemd or a `su` login, not a
  desktop or SSH login.

## Results

| # | Scenario | Result |
| --- | --- | --- |
| 1.1 | release stage, assets, `install.sh` downloads, SHA256SUMS check, staging (binaries, Swift libs, packs, `.rv-swiftlibs`) | pass |
| 1.1b | `install.sh` removes its download directory | **fail**: F7 |
| 1.2 | `install.sh`'s own `rv setup` on a host without logind | **fail**: F1 |
| 1.3 | `rv setup` after the fix rvd.log names; Claude hooks wired | pass |
| 1.4 | `rv doctor` | rvd running, Claude wired: pass. False `fail` row: **fail**, F2 |
| 1.5 | `rv host list` | pass |
| 1.6 | `rv service status / restart / start`; stopping rvd (no `stop` subcommand, so kill) | pass |
| 1.7 | key custody (custodian): `sudo rv mcp custodian install` from `~/.local/bin` (refused, recipe given), from a root-only copy (source check passes, refused for lack of systemd) | pass (both refusals are documented). The shipped install path could not run: no systemd |
| 1.8 | observe vs enforce: agent refused (77), wrong password refused, owner switches; would-be denies run; self-protection still blocks; `rv blocks` shows `observed ask/deny`; per-host `block` re-enforces; loosening needs the password | pass; no global way back to enforce (F8) |
| 2.1 | allow (`git status`), ask (`git reset --hard`: deny with allow-once code), deny (`cat .env`, Read `~/.env`), through `rv hook --host claude` **and** the wired `rv-guard.py` command | pass |
| 2.2 | allow-once: agent refused, wrong password refused, owner redeems, runs once, denied again | pass |
| 2.3 | rvd down: Claude native `ask` with "RV daemon is not reachable"; `RV_HOOK_WHEN_DOWN=deny` denies; `=allow` ignored; Codex `block` + exit 2; observe + down runs unchecked with a notice | pass |
| 2.4 | `audit.jsonl`: denies, owner check, override recorded with rule and host, no command text; `rv audit verify` intact; an edited line is caught | pass |
| 2.5 | the indeterminate verdict (`rv host mode claude off` from the agent) is audited | **fail**: F6 |
| 3.1 | `rv secrets set` with no session bus: refused with a clear reason | pass; leaves a definition that blocks the same command's retry: **fail**, F5 |
| 3.2 | value in gnome-keyring; `rv run --secret E2E_API_KEY -- python3 client.py` against a local HTTPS upstream: child and grandchild see only a placeholder and no real value in env; upstream gets the real value over TLS; echoed value scrubbed back; outside process refused 403 and never reaches upstream; exit status passed through; value in no output, audit or rv file; audit has `secret.use` + `secret.misuse`; gateway gone after exit | pass (14 checks) |
| 4.1 | hand-written `mcp.json` untrusted; serve launches nothing; trust refused with no terminal and a wrong password; signed after the review | pass |
| 4.2 | first serve: tools of a stdio and an HTTP server listed with rv's untrusted marker and an empty schema; denied tool hidden; calls pause | pass |
| 4.3 | `rv mcp trust` pins; calls to both servers return results; denied call not forwarded | pass |
| 4.4 | rug pull: changed definition served as rv's "changed since the user trusted it" marker with an empty schema; its call asks; `mcp.tool.changed` audited | pass |
| 4.5 | approval: `rv mcp approve` refused without a terminal and with a wrong password; code + password grants one call; the next asks again. **Approval without a GUI also works through MCP elicitation**: rv sends `elicitation/create`, accept runs, decline does not | pass |
| 4.6 | Landlock cage (`sandbox: {network: false}`): fake `~/.ssh/id_ed25519`, `~/.aws/credentials`, `~/.claude.json`, `~/.cursor/mcp.json`, `~/.claude/.credentials.json`, keyring and rv's own config unreadable; home not writable; TCP refused; own files readable | pass |
| 4.7 | server with `"placeholders"`: refused on Linux ("only macOS supports today"); the others serve | pass |
| 4.8 | local server with no `sandbox` entry on a host that has a sandbox | **fail**: F3 |
| 4.9 | `callTimeoutSeconds: 3` with a call never answered: error at ~3 s, "may still have run"; server answering ping not restarted | pass |
| 4.10 | crash mid-call: "may have run"; not re-sent; restarted; `tools/list_changed`; only re-listed tools offered; a tool not re-listed refused (and audited) | pass |
| 4.11 | remote stops answering (SIGSTOP): error at its 4 s limit; ping fails, stopped and restarted; calls meanwhile refused "not run"; serves again once it answers | pass |
| 4.12 | SIGTERM to `rv mcp serve` with a call in flight: exits (143), local server gone, in-flight call gets a closing `mcp.call` record ("gateway stopped; the call may still have run"); chain verifies | pass |
| 5.1 | `rv uninstall`: agent refused; owner completes; rvd stopped; `~/.local/bin` empty; Claude hooks removed | pass |
| 5.2 | what is left behind | **fail**: F4 |

Not exercised here, and why:

- **systemd paths.** There is no systemd on this host, so these were not
  run: the systemd *user* unit (`Restart=always`, the resident rvd); the
  shipped `rv mcp custodian install` (units, hardening, `systemd-analyze
  security`); and `rv mcp custodian uninstall`. The custodian's two daemons
  were started by hand under the same accounts, paths and PAM service, as
  `Scripts/linux-custodian-e2e.sh` does on non-systemd hosts. **So the MCP
  results above hold for the custodian protocol, not for its packaging.**
- **A real logind or desktop session**, with its own `/run/user/<uid>` and
  keyring unlock at login.
- **A real agent host** (by rule), aarch64, an actual glibc 2.35 host, and
  a signed `SHA256SUMS.sig`.
- **macOS-only parts**: Seatbelt, Keychain, RVApprovals.app, Touch ID, and
  placeholders for MCP servers.

## Findings, ranked

### F1. On a host without logind, the install's own `rv setup` fails; the cause is only in rvd.log

Severity: **blocks a first sale** for container, devcontainer and WSL
buyers (the "no systemd user manager" case the CHANGELOG says is now
supported); otherwise should fix.

What a user sees after `curl … | sh`:

```
rv setup failed: rvd did not answer within 10 seconds of starting it (no systemd user manager is running, so rv starts rvd itself)
no hooks were wired: rv wires agent hooks only once rvd answers
fix: read ~/.local/state/rv/rvd.log, or run ~/.local/bin/rvd --socket --idle-exit-seconds=31536000 in a terminal …
```

`install.sh` exits 69 with nothing guarded. Only `rvd.log` says why:
`XDG_RUNTIME_DIR is unset and /run/user/<uid> is missing … fix: as root,
mkdir -p -m 0700 /run/user/<uid> && chown <uid> /run/user/<uid>`. After
that fix, `rv setup` works.

Repro: any account with no logind session (e.g. `sudo -u user sh
install.sh`, or a container user), with `/run/user` root-owned 0755 and no
`/run/user/<uid>`.

Fault: the CHANGELOG says `rvd` "creates `/run/user/<uid>` (0700) when
missing". But `Sources/RVService/UnixSocketPath.swift:171-178` calls
`mkdir(/run/user/<uid>)` as the user, and that can't succeed under a
root-owned `/run/user`. So the creation path only works where it's least
needed. Setup's message (`Sources/RVCLI/Setup/SetupError.swift:225-231`)
points to the log instead of saying the cause.

Suggested fix: have `rv setup` (and `install.sh`, before staging) check
`/run/user/<uid>` itself and print the one-line root command. Or pass
rvd's first stderr line through in the setup failure. Correct the
CHANGELOG sentence, and add the step to the README's Linux requirements.

### F2. `rv doctor` reports a failure on a working install with Ubuntu's default umask

Severity: **should fix**.

`rv doctor` exits 1 (`ok: false`) with `config-dir fail: ~/.config is
group/world-writable (mode 775); rvd refuses to start`, while `rvd` is
running and answering. On Ubuntu, pam_umask gives regular users umask 002,
so `~/.config` is usually 775 and this fires on most installs.

Fault: `Sources/RVCLI/Doctor/DoctorInstallProbes.swift:360-392`. The probe
"mirrors rvd's socket base-directory rule", but on Linux the socket is
under `/run/user/<uid>`, not `~/.config`, and the probe is not
platform-gated.

Suggested fix: run the probe on macOS only (or wherever the socket base
really is `~/.config`). On Linux, check only `~/.config/rv`, which rv
already creates 0700.

### F3. One local server without a `sandbox` entry stops the whole MCP gateway

Severity: **should fix**.

On a host with a sandbox (Landlock ABI ≥ 4), adding one local server
without `sandbox` makes `rv mcp serve` print `sandbox: bare needs a sandbox;
add "sandbox" to its mcp.json entry` and exit 1. The MCP host then has no
tools from any server. `rv mcp trust` signs such a config without a
warning; `rv mcp check` does flag it.

Docs say the server is refused (`docs/security/mcp-linux-sandbox.md`: "a
server without one is refused"; README: servers "are refused rather than
run uncaged"). A server with `placeholders` on Linux *is* refused alone,
and the others serve.

Fault: `Sources/RVMCP/MCPGatewayRuntime.swift:151-154` returns `.failure`
for the whole plan.

Suggested fix: mark that server failed with the reason (as the
placeholders path does) and serve the rest. Also refuse or warn in `rv mcp
trust`.

### F4. `rv uninstall` leaves rv's config, the audit key and the stored secret values

Severity: **should fix** (the docs disagree with the behaviour).

The README says `rv uninstall` removes "rv's hooks, config, and rvd"
(line 201) and "everything rv owns" (line 522). After an owner-approved
uninstall, these remain:

- In `~/.config/rv`: `secrets.json`, `mcp.json`, `mcp-integrity.json`,
  `mcp-tool-pins.json`, `mcp-tool-review.json`, `mcp-approvals.json`,
  `audit.jsonl`, `audit.key`, `judge-log.jsonl` and lock files.
- `~/.local/state/rv/rvd.log`, `~/.cache/rv-mcp/<server>`,
  `/run/user/<uid>/rv`, and empty `~/.claude/hooks` and
  `~/.config/systemd/user` directories.
- **The secret value in the Secret Service** (`secret-tool lookup service
  rv.secrets account E2E_API_KEY` still returns it).

Line 526 accurately describes the narrower behaviour (hooks, service and
`~/.local/bin`). The custodian's system files are a separate `sudo rv mcp
custodian uninstall`, as documented.

Fault: `Sources/RVCLI/Setup/SetupUninstall.swift:51-66` removes only the
listed analytics, policy and denial artifacts.

Suggested fix: decide what uninstall owns. Either remove the rest and
delete `rv.secrets` keyring items the way `rv secrets remove` already does
(keeping the audit log behind a flag), or make the README list exactly
what is kept, and have uninstall print it.

### F5. A refused `rv secrets set` leaves a definition that makes the same command fail on retry

Severity: **should fix** (minor for security, poor first experience).

With no session bus, `rv secrets set E2E_API_KEY --gateway … --base-url-env
…` refuses with a good reason ("needs this user's D-Bus session bus"), but
it has already written the definition to `secrets.json`. Running the same
command again with a keyring available fails: `E2E_API_KEY is already
defined; edit secrets.json to change its delivery`. What works, a bare
`rv secrets set E2E_API_KEY`, is said nowhere.

Fault: `Sources/RVCLI/Commands/SecretsCommand.swift:404-416` writes the
definition before the value, by design ("until a retry stores it"). But the
retry users will type hits the refusal at line 377.

Suggested fix: accept a re-run whose flags match the stored definition, or
say in the store-failure message "the definition was saved; once a keyring
is available run `rv secrets set NAME` to store the value".

### F6. The indeterminate verdict the agent sees as a deny is not audited

Severity: **minor**.

`rv host mode claude off`, sent through the hook by the agent, is denied
with "rv could not finish evaluating this command. Run it in Terminal."
`audit.jsonl` gains nothing for it, and neither does `rv blocks`. The
README says every hook deny is audited. The message also reads like a
fault, though it's a deliberate self-protection refusal.

Fault: `Sources/RVService/GatedEvaluate.swift:498` treats `.indeterminate`
like `.allow`. The deny ledger at line 1071 is "for every enforced deny"
and is never reached.

Suggested fix: write a `command.denied` (or a new `command.indeterminate`)
record with the reason class. For rv-protection cases, say so ("rv does not
let an agent change its own guard; run it in your terminal").

### F7. Every `install.sh` run leaves its 156 MB download directory in /tmp

Severity: **should fix**.

After each install, `/tmp/rv-install.XXXXXX` remains, owned by the user.
It holds every downloaded binary, the Swift runtime libraries, the pack
bundle and `SHA256SUMS` (156 MB here). Re-installs accumulate one each.

Fault: `install.sh:146` sets `trap cleanup EXIT`. But the script ends with
`exec "$bin/rv" setup` (`install.sh:1397` and `:1399`), which replaces the
shell, so the trap never runs.

Suggested fix: call `cleanup` (and clear the trap) just before the `exec`.
Or run `rv setup` without `exec` and `exit` with its status.

### F8. Minor findings and docs that disagree with behaviour

- **No way back to enforce globally.** The README sells observe as "watch
  before you enforce", but nothing sets `guard.mode` back to enforce.
  `rv setup` never touches it, and `rv host mode <host> block` works per
  host only, so a host set up later still observes. Suggest `rv setup
  --enforce` (tightening, no password).
- **"Ask" means two things.** The README says host-config commands "ask"
  (`ls mcp install`, `grep 'claude mcp add' docs/`). The hook returns a
  deny with an allow-once code (`permissionDecision: deny`). Claude's native
  `ask` only appears when rvd is down. Suggest saying "needs your approval
  (allow-once)".
- **macOS vocabulary on Linux.**
  - The daemon-down message names `dev.rv.evaluate`
    (`Sources/rv-c/hook_fallback.c:12`).
  - `rv service status` prints `label=dev.rv.evaluate keepAlive=false`.
  - `rv doctor --json` says `"launch_agent": "installed"`.
- **No `rv service stop`.** Stopping rvd means `kill`; probably deliberate,
  but undocumented.
- **Version string.** `rvd --version` prints `0.2.1`, the version of the old
  published release, on a tree with a large Unreleased section.
- **Group-writable files under umask 002.** rv's own files in
  `~/.config/rv` (`analytics-*.json`, `judge-log.jsonl`) and the
  `~/.config` it creates are made 664/775. The 0700 directory contains
  this, but rv could set modes explicitly.
- **Placeholders accepted silently on Linux.** `rv mcp trust` and
  `rv mcp check` accept a server with `placeholders` that can never start
  there. Only `serve` says so.
- **Prompt wording.** "rv: Authenticate to switch rv to observe mode.
  needs your login password at an interactive terminal": two sentences
  joined into one.

## Limits worth a product decision (documented, not bugs)

- **The MCP gateway needs systemd.** Without systemd as init, `rv mcp
  custodian install` refuses. On such hosts, which `rv setup` explicitly
  supports, `rv mcp serve` launches nothing. A container-based buyer gets
  the hook guard but no MCP gateway.
- **Custodian install from the normal install location.** `sudo rv mcp
  custodian install` refuses `~/.local/bin` (correctly) and asks the user to
  `sudo cp -R ~/.local/bin /opt/rv` first. From such a copy, the release
  binaries' `RUNPATH` still names the build host's toolchain directory.
  That is a documented known limit.
- **Analytics.** On by default and sent to a third-party host
  (`us.i.posthog.com`). The installer doesn't mention it; the README does.
- **Headless servers have no Secret Service.** There, `rv secrets set`
  cannot store values. The refusal says to use a desktop or SSH login, but
  an SSH login on a server usually has no keyring either.
