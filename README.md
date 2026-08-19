# rv

Mac-native destructive-command guard for coding-agent **shell** hooks.

- **Names:** `rv` (CLI / hook client), `rvd` (XPC service). Prefix `RV_`. Config `~/.config/rv/`.
- **Platform:** macOS 26, Apple Silicon only. Swift 6.3.
- **Hosts:** Pi, Grok, OpenCode. Shell / command tools only.
- **Parity:** same decisions and `rule_id` as pinned upstream **0.11.0** engine source. Not a Rust port. Not an alias of the upstream binary.
- **License:** deferred.
- **Grade:** hook. Not OS-enforced.

## Install

Hero path (real HOME, when you mean it):

```sh
RV_INSTALL_BIN=/path/to/dir-with-rv-and-rvd ./install.sh
```

`install.sh` copies `rv` and `rvd` to `~/.local/bin` and runs `rv setup`. It refuses anything that is not macOS 26 on Apple Silicon.

Brew is second, when a formula exists:

```sh
brew install rv && rv setup
```

Brew alone does not wire hooks. Homebrew `post_install` must not call setup.

```sh
rv setup      # idempotent; honors process HOME only
rv uninstall  # rv-owned files only
```

`rv setup` writes only:

- `~/.grok/hooks/rv.json`
- `~/.pi/agent/extensions/rv-guard.ts`
- `~/.config/opencode/plugins/rv-guard.js`
- `~/.config/rv/`
- `~/Library/LaunchAgents/dev.rv.evaluate.plist` (`KeepAlive` false)

Foreign hook files are left untouched. Occupied owned names are skipped. Hostless setup succeeds and prints one line to run `rv setup` later.

Do not run `install.sh` or `rv setup` from tests without overriding `HOME`.
