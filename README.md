# rv

Mac-native destructive-command guard for coding-agent **shell** hooks.

- **Names:** `rv` (the only command), `rvd` (XPC service). Prefix `RV_`. Config `~/.config/rv/`.
- **Platform:** macOS 26, Apple Silicon only. Swift 6.3.
- **Hosts:** Pi, Grok, OpenCode. Shell / command tools only.
- **License:** MIT
- **Grade:** hook. Not OS-enforced.

## Install

v1 is curl only. Hero (real HOME, when you mean it):

```sh
curl -fsSL https://github.com/christopherkarani/rv/releases/latest/download/install.sh | sh
```

Until a release exists, local:

```sh
RV_INSTALL_BIN=/path/to/release-stage ./install.sh
```

`install.sh` stages the hook client, the operator sibling, and `rvd` to `$HOME/.local/bin`, then runs `rv setup`. It refuses anything that is not macOS 26 on Apple Silicon.

```sh
rv setup      # idempotent; honors process HOME only
rv uninstall  # rv-owned files only
rv doctor     # read-only service, pack, and Host adapter health
```

`rv setup` writes only:

- `~/.grok/hooks/rv.json`
- `~/.pi/agent/extensions/rv-guard.ts`
- `~/.config/opencode/plugins/rv-guard.js`
- `~/.config/rv/`
- `~/Library/LaunchAgents/dev.rv.evaluate.plist` (`KeepAlive` false)

Foreign hook files are left untouched. Occupied owned names are skipped. Hostless TTY setup prints `No hosts yet` then `Next  rv setup`. Non-TTY prints one line to run `rv setup` later.

Do not run `install.sh` or `rv setup` from tests without overriding `HOME`.

`rv doctor` reports service reachability/version, local fallback readiness,
LaunchAgent state, day-one packs, and each Host adapter installation state.
TTY output is one fact per line; `--robot` and non-TTY output are one JSON
object. Host wiring warnings do not make doctor fail, but unreadable config,
broken packs, or unavailable local fallback do.
