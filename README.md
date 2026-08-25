<p align="center">
  <img src="docs/assets/rv-banner.png" alt="rv — shell guard for coding agents" width="1280">
</p>

<p align="center">
  <a href="https://github.com/christopherkarani/rv/releases/latest"><img src="https://img.shields.io/github/v/release/christopherkarani/rv?label=v0.1.0" alt="Release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache%202.0-0f172a" alt="Apache 2.0"></a>
  <a href="https://github.com/christopherkarani/rv"><img src="https://img.shields.io/github/stars/christopherkarani/rv?style=flat" alt="Stars"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2026%20arm64-111827" alt="macOS 26 arm64">
  <img src="https://img.shields.io/badge/hosts-Pi%20%7C%20Grok%20%7C%20OpenCode-334155" alt="Hosts">
</p>

```sh
curl -fsSL https://rykanv.com/install | sh
```

# rv

**Agents generate actions. rv authorizes them before they run.**

A local shell guard for coding agents. Pi, Grok, and OpenCode send the tool call to rv. Destructive git and filesystem commands deny. Secret paths like `.env` deny. You keep using the agent you already use.

Site: [rykanv.com](https://rykanv.com) · Docs: [rykanv.com/docs/introduction](https://rykanv.com/docs/introduction)

## Why this exists

Instructions in `AGENTS.md` do not stop `git reset --hard` or `rm -rf`. The host is about to run a shell tool. rv evaluates that command against local packs and returns allow or deny before the shell starts.

## Quick start

```sh
curl -fsSL https://rykanv.com/install | sh
rv setup
rv test 'git reset --hard'
```

Then start Pi, Grok, or OpenCode as you normally do.

## What it does

| | |
| --- | --- |
| Destructive git | `reset --hard`, `checkout --`, `clean -fd`, `push --force`, `stash clear` |
| Destructive fs | `rm -rf`, `find -delete`, and similar |
| Secret paths | `.env`, SSH keys, and other known credential files |
| Allow once | `rv allow-once` unlocks the next matching call in this working directory |
| Explain | `rv explain` shows which pack would fire |
| Hosts | Pi, Grok, OpenCode — wired by `rv setup` |
| Platform | macOS 26, Apple Silicon |

A workspace sandbox still lets `git reset --hard` and `rm -rf .` run inside the project. rv blocks those operations on the tool call, before the shell starts.

## Supported hosts

| Host | After `rv setup` |
| --- | --- |
| Grok | `~/.grok/hooks/rv.json` |
| Pi | `~/.pi/agent/extensions/rv-guard.ts` |
| OpenCode | `~/.config/opencode/plugins/rv-guard.js` |

## Commands

One command: `rv`.

```sh
rv setup                         # wire hosts
rv test 'git reset --hard'       # evaluate, do not run
rv explain 'git reset --hard'    # which pack would fire
rv allow-once 'git reset --hard' # next matching call in this cwd
rv packs                         # catalog
rv doctor                        # health
rv uninstall                     # rv-owned files only
```

```sh
rv allow-once 'git reset --hard'
# next matching call in this repo is allowed once
```

## How it works

1. The agent is about to run a shell command.
2. The host adapter sends the command (and `cwd` when it has one) to rv.
3. Packs decide allow or deny.
4. Deny means the command does not run.

`cwd` scopes `allow-once`. Same command, different repo, still denied.

## Packs

```sh
rv packs
rv test 'rm -rf /'
rv test 'cat .env'
```

The installer unpacks the pack bundle next to the binaries. `rv setup` is idempotent and only writes rv-owned paths.

## Uninstall

```sh
rv uninstall
```

## License

Apache 2.0. See [LICENSE](LICENSE).
