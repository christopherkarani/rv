<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Resources/rv-banner-dark.png">
    <img src="Resources/rv-banner.png" alt="rv — shell guard for coding agents" width="1280">
  </picture>
</p>

<p align="center">
  <a href="https://github.com/christopherkarani/rv/releases/latest"><img src="https://img.shields.io/github/v/release/christopherkarani/rv?label=v0.1.4" alt="Release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache%202.0-0f172a" alt="Apache 2.0"></a>
  <a href="https://github.com/christopherkarani/rv"><img src="https://img.shields.io/github/stars/christopherkarani/rv?style=flat" alt="Stars"></a>
  <a href="https://discord.gg/uZn9MDUYKx"><img src="https://img.shields.io/badge/discord-join-5865F2?logo=discord&logoColor=white" alt="Discord"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2026%20arm64%20%7C%20Linux-111827" alt="macOS 26 arm64 and Linux">
  <img src="https://img.shields.io/badge/hosts-Grok%20%7C%20Pi%20%7C%20OpenCode%20%7C%20Claude%20%7C%20OpenClaw%20%7C%20Hermes%20%7C%20Codex%20%7C%20Cursor-334155" alt="Hosts">
</p>


# rv (Rykan V)

**Control what your agent can do.** rv is a **hook-grade** guard: it blocks destructive shell (and Read / Edit / Write secret-path on Grok, Claude, and Cursor) when the host actually calls `rv`. It is not an OS sandbox. A host that never invokes the hook is not blocked.

Site: [rykanv.com](https://rykanv.com) · Docs: [rykanv.com/docs/introduction](https://rykanv.com/docs/introduction) · Discord: [discord.gg/uZn9MDUYKx](https://discord.gg/uZn9MDUYKx)

## Why this exists

Agents delete the wrong tree. rv sits on the host's pre-tool hook and denies the command before the host runs it. Install is one curl; `rv setup` writes adapters for hosts it can see.

## Quick start

```sh
curl -fsSL https://rykanv.com/install | sh
```

## What it does

| | |
| --- | --- |
| Destructive git | `reset --hard`, `checkout --`, `clean -fd`, `push --force`, `stash clear` |
| Destructive fs | `rm -rf`, `find -delete`, and similar |
| Secret paths | `.env`, SSH keys, and other known credential files |
| Allow once | Redeem the code from a block; the next matching call in this working directory runs once |
| Explain | `rv explain` shows which pack would fire |
| Hosts | Grok, Pi, OpenCode, Claude, OpenClaw, Hermes, Codex, Cursor. `rv setup` writes a host only when that host is already on the machine. |
| Platform | macOS 26 Apple Silicon, Linux aarch64/x86_64. PR CI Linux is ubuntu-24.04 x86_64; aarch64 is a supported install, not a PR job. |

## Supported hosts

| Host | After `rv setup` (if detected) | File-tool Read / Edit / Write |
| --- | --- | --- |
| Grok | `~/.grok/hooks/rv.json` | yes |
| Pi | `~/.pi/agent/extensions/rv-guard.ts` | shell only |
| OpenCode | `~/.config/opencode/plugins/rv-guard.js` | shell only |
| Claude | settings merge | yes |
| OpenClaw | `~/.openclaw/extensions/rv-guard/` | shell only |
| Hermes | `~/.hermes/plugins/rv-guard/` | shell only |
| Codex | `~/.codex/hooks/rv-guard.py` | shell only |
| Cursor | `~/.cursor/hooks/rv-guard.py` | yes |


## Commands

```sh
rv setup                         # wire hosts
rv test 'git reset --hard'       # evaluate, do not run
rv explain 'git reset --hard'    # which pack would fire
rv scan                          # session forensics (deny-only findings)
rv allow-once a1b2c3             # redeem the code from a hook deny
rv packs                         # catalog
rv packs enable <pack>           # enable an extra pack (day-one always compiled)
rv policy show                   # typed rules
rv allowlist list                # permanent exceptions
rv doctor                        # health
rv uninstall                     # remove rv-owned files
```

Anonymous usage is on by default. Turn it off with `"analytics.enabled": false` in `~/.config/rv/config.json`. Setup does not print a notice.

## License

Apache 2.0. See [LICENSE](LICENSE).
