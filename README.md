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

Coding agents write and run shell. `AGENTS.md` is a suggestion. The moment that matters is the tool call.

rv sits on that wire. The host is about to run a command. Packs return allow or deny. Deny means the shell never starts.

A workspace sandbox still lets `git reset --hard` and `rm -rf .` run inside the project. rv blocks those operations on the tool call.

## Quick start

```sh
curl -fsSL https://rykanv.com/install | sh
rv setup
rv test 'git reset --hard'
```

Then start Pi, Grok, or OpenCode as you normally do.

Prove a deny without running anything:

```sh
rv test 'rm -rf /'
rv explain 'git push --force'
rv test 'cat .env'
```

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

## Supported hosts

| Host | After `rv setup` |
| --- | --- |
| Grok | `~/.grok/hooks/rv.json` |
| Pi | `~/.pi/agent/extensions/rv-guard.ts` |
| OpenCode | `~/.config/opencode/plugins/rv-guard.js` |

`rv setup` is idempotent. It writes rv-owned adapters, `~/.config/rv/`, and the evaluate LaunchAgent.

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

## How it works

1. The agent is about to run a shell command.
2. The host adapter sends the command, and `cwd` when the host has one.
3. Packs decide allow or deny.
4. Deny means the command does not run.

Same path for `rv test` and the live hook. If you can prove a deny with `rv test`, the wired host uses that evaluator.

## Example

Agent asks the host to run `git reset --hard`.

```
command: git reset --hard
cwd:     /Users/you/app
pack:    core.git
result:  deny
```

The host gets deny. The working tree stays. Grant one exception in that directory with `rv allow-once`.

## Allow once

Need this one reset in this repo:

```sh
rv allow-once 'git reset --hard'
```

The next matching call in this working directory is allowed. The same command in another repo still denies. `cwd` is what the host reports for the tool call.

## Packs

Day-one packs ship next to the binaries. The public installer unpacks the bundle.

```sh
rv packs
rv test 'rm -rf /'
rv test 'cat ~/.ssh/id_rsa'
```

Enable and disable packs locally. `rv explain` names the pack that would fire.

## From source

```sh
tools/release.sh
RV_INSTALL_BIN=$PWD/.build/release-stage ./install.sh
rv setup
```

## Uninstall

```sh
rv uninstall
```

Removes rv-owned files only. Agent configs rv did not write stay.

## License

Apache 2.0. See [LICENSE](LICENSE).
