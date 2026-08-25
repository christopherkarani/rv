<p align="center">
  <img src="docs/assets/rv-banner.png" alt="rv — hook-grade shell guard" width="1280">
</p>

<p align="center">
  <a href="https://github.com/christopherkarani/rv/releases/latest"><img src="https://img.shields.io/github/v/release/christopherkarani/rv?label=v0.1.0" alt="Release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-0f172a" alt="MIT"></a>
  <a href="https://github.com/christopherkarani/rv"><img src="https://img.shields.io/github/stars/christopherkarani/rv?style=flat" alt="Stars"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2026%20arm64-111827" alt="macOS 26 arm64">
  <img src="https://img.shields.io/badge/grade-hook-64748b" alt="Hook grade">
  <img src="https://img.shields.io/badge/hosts-Pi%20%7C%20Grok%20%7C%20OpenCode-334155" alt="Hosts">
</p>

```sh
curl -fsSL https://rykanv.com/install | sh
```

# rv

**Hook-grade shell guard for coding agents.**

Pi, Grok, and OpenCode ask rv before a shell command runs. Known destructive git and filesystem calls deny. Unknown commands stay default-allow. Malformed hook JSON denies. Grade is hook, not OS.

Site: [rykanv.com](https://rykanv.com) · Docs: [rykanv.com/docs/introduction](https://rykanv.com/docs/introduction)

## What you get

| | |
| --- | --- |
| Hosts | Pi, Grok, OpenCode. Shell / command tools only. |
| Decision | `allow` or `deny`. No host Ask UI. |
| Packs | Local catalog of destructive git / filesystem / secret-path rules. |
| Allow once | `rv allow-once` spends one grant in that working directory. |
| Service | `rvd` on `gui/$(id -u)` so the C hook can hit a warm evaluate. |
| Platform | macOS 26, Apple Silicon. Swift 6.3. |
| License | MIT |

## What you do not get

- Not Seatbelt. Not Landlock. Not a sandbox.
- Not fail-closed on unknown commands.
- Not a host launcher. You still start the agent yourself.
- Not Homebrew. Not Linux. Not Windows. Not macOS 14/15.
- Not Claude / Codex as a v0.1 setup slot.

A host that never calls the hook is unguarded.

## After install

```sh
rv setup
rv test 'git reset --hard'
```

`rv setup` is idempotent. It writes only:

- `~/.grok/hooks/rv.json`
- `~/.pi/agent/extensions/rv-guard.ts`
- `~/.config/opencode/plugins/rv-guard.js`
- `~/.config/rv/`
- `~/Library/LaunchAgents/dev.rv.evaluate.plist` (`KeepAlive` false)

Foreign hook files stay untouched. Occupied owned names are skipped.

## Commands

One user command: `rv`.

```sh
rv setup                         # wire hosts + LaunchAgent
rv test 'git reset --hard'       # evaluate, do not run
rv explain 'git reset --hard'    # which pack would fire
rv allow-once 'git reset --hard' # next matching call in this cwd
rv packs                         # catalog
rv doctor                        # read-only health
rv uninstall                     # rv-owned files only
rv --version                     # 0.1.0
```

`rvd --version` also prints `0.1.0`. The XPC handshake is still protocol `1.0.0`. Do not “fix” that to match the tag.

## How a deny happens

The host is about to run a shell tool. The adapter sends `{ command, cwd? }` to `rv hook`. Known destructive → deny. Unknown → allow. Empty or garbage JSON → deny. Foreign host JSON → allow. The command does not run.

Adapters send `cwd` when the host has one. Policy uses that directory to honor `allow-once`. Missing `cwd` skips honor. rv never fills cwd from its own process directory.

```sh
rv allow-once 'git reset --hard'
# next `git reset --hard` in this repo is allowed once
# the same command in another repo still denies
```

## Hosts

| Host | Adapter | Notes |
| --- | --- | --- |
| Grok | `~/.grok/hooks/rv.json` | Envelope already carries `cwd`. |
| Pi | `~/.pi/agent/extensions/rv-guard.ts` | Sends `cwd` / `cwdPath`, else `process.cwd()`. |
| OpenCode | `~/.config/opencode/plugins/rv-guard.js` | Sends `input.cwd` / `input.directory`, else `process.cwd()`. |

No Read / Edit / MCP hooks in v0.1.

## Packs

Day-one packs live next to the installed binaries (`*_RVPacks.bundle`). The public installer unpacks `rv_RVPacks.bundle.tar.gz`. A bare `.bundle` file is skipped.

```sh
rv packs
rv test 'rm -rf /'
rv test 'cat .env'
```

Secret-path deny covers known credential files. It is not full MCP governance.

## Service

The C hook wins only when `rvd` is loaded in the Aqua `gui` domain:

```sh
launchctl print gui/$(id -u)/dev.rv.evaluate
```

`user/` must not have that job. `KeepAlive` is false on purpose — first hook after idle can spike once.

`rv doctor` is not that probe. `isHealthy` can be true with `rvd` down. Then every hook misses into Swift (~700 ms).

## Local / from source

```sh
tools/release.sh
RV_INSTALL_BIN=$PWD/.build/release-stage ./install.sh
```

Tests must set `HOME` to a temp directory. Do not run `install.sh` or `rv setup` against a real HOME from a test.

## Uninstall

```sh
rv uninstall
```

Removes rv-owned files only. Your agent configs that rv did not write stay.

## Honesty

| Claim | v0.1 |
| --- | --- |
| Destructive git / fs deny | yes |
| Secret-path deny | yes |
| Malformed payload deny | yes |
| Unknown command deny | no (default-allow) |
| OS isolation | no |
| Host Ask | no |
| History / telemetry of command text | off |

If rv saves you a bad day, [star the repo](https://github.com/christopherkarani/rv).

## License

MIT. See [LICENSE](LICENSE).
