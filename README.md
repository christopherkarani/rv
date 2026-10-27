<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Resources/rv-banner-dark.png">
    <img src="Resources/rv-banner.png" alt="rv — shell guard for coding agents" width="1280">
  </picture>
</p>

<p align="center">
  <a href="https://github.com/christopherkarani/rv/releases/latest"><img src="https://img.shields.io/github/v/release/christopherkarani/rv" alt="Release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache%202.0-0f172a" alt="Apache 2.0"></a>
  <a href="https://github.com/christopherkarani/rv"><img src="https://img.shields.io/github/stars/christopherkarani/rv?style=flat" alt="Stars"></a>
  <a href="https://discord.gg/uZn9MDUYKx"><img src="https://img.shields.io/badge/discord-join-5865F2?logo=discord&logoColor=white" alt="Discord"></a>
  <img src="https://img.shields.io/badge/packs-95-7928ca" alt="95 rule packs">
  <img src="https://img.shields.io/badge/platform-macOS%2015%2B%20(Apple%20Silicon)%20%7C%20Linux-111827" alt="macOS 15+ Apple Silicon and Linux">
</p>

# rv

**Your coding agent just tried to run `rm -rf /`. rv said no.**

rv is a fail-closed policy gate for AI coding agents. It sits on your
agent's pre-tool hook and blocks destructive shell commands — and
secret-file reads/edits — *before* the host runs them. One gate, three
verdicts: **allow · deny · indeterminate**. It never asks the agent;
only you can override, with a one-time code.

```sh
$ rv test 'git reset --hard'
{"decision":"deny","pack_id":"core.git","reason":"git reset --hard destroys uncommitted changes","rule_id":"core.git:reset-hard","schema":"rv.test.v1"}

$ rv test 'git status'
{"decision":"allow","schema":"rv.test.v1"}
```

## Install (30 seconds)

```sh
curl -fsSL https://rykanv.com/install | sh
rv setup    # auto-detects your agents and wires their hooks
rv doctor   # verify everything is live
```

On macOS the installer also fetches the on-device judge weights (~649 MB,
verified by SHA-256, fully offline after) so the neural judge binds on first
run; Linux installs run packs-only until the ONNX runtime lands. Re-run the
installer anytime to pick up the weights.

Works with **Claude Code, Codex, Cursor, Grok, OpenCode, Pi, Hermes,
OpenClaw, Antigravity, and Muse**. Hooks are only written for hosts already
on your machine. Requires macOS 15+ (Apple Silicon) or Linux
(aarch64/x86_64).

## How it works

Every shell and file-tool call from every host funnels into one daemon
(`rvd`) and one pipeline:

```text
agent ─▶ hook ─▶ rvd ─▶ 95 rule packs ─▶ script gate ─▶ on-device judge ─▶ policy ─▶ allow / deny
                          safe-first       npm bodies     CoreML (Laya)      overrides
                          deny = floor     evaluated      can only raise
```

- **95 rule packs** — git, filesystem, disks, cloud CLIs, Kubernetes,
  databases, Terraform, CI/CD, payments, and more. Safe patterns run
  first; the first blocking hit denies. Three packs are on by default
  (`core.filesystem`, `core.git`, `system.disk`); enable the rest by
  pack, category, or preset with `rv packs enable`.
- **Script gate** — `npm test` can't hide a payload: rv evaluates the
  actual `pre`/`post`/body scripts in `package.json`, not just the
  command you see.
- **On-device neural judge** — with a Laya CoreML bundle installed,
  pack-allowed commands get a local risk score. The judge can only
  raise a verdict, never lower a pack deny. Nothing leaves your
  machine. `"guard.mode": "observe"` logs would-be verdicts without
  blocking, so you can measure before you enforce.
- **Policy gate** — a fixed override ladder (rebase recovery → pinned
  rules → allowlist → allow-once → contained-delete allowance) with
  `normal`/`strict` safety levels. Indeterminate (too large, budget
  exhausted, core packs missing) is never overridable.

## What gets blocked

| Category | Examples |
| --- | --- |
| Destructive git | `reset --hard`, `push --force`, `clean -fd`, `stash clear`, `checkout -- .` |
| Destructive filesystem | `rm -rf /`, `rm -rf ~`, `find -delete`, fork bombs, disk wipes |
| Secret paths | `.env`, SSH keys, cloud credentials — shell *and* Read/Edit/Write on Grok, Claude, Cursor |
| Cloud & infra (opt-in packs) | `terraform destroy`, `kubectl delete`, `aws s3 rm --recursive`, `DROP TABLE`, … |

Not sure why something blocked? `rv explain 'git reset --hard'` shows
exactly which pack and rule fired.

## When you're blocked (and you meant it)

Every hook deny prints a six-character code. Redeem it once, from
your terminal — the agent can't redeem its own code:

```sh
rv allow-once a1b2c3    # next matching call in this directory runs once
```

Need it permanently? `rv allowlist add <rule-id>`. Typed rules live in
`~/.config/rv/policy.toml` (`rv policy show`); `rv safety set strict`
tightens everything to deny-by-default for generated-output deletes.

## Beyond the shell

rv is one binary, 24 commands. The rest of the surface:

- **Secrets without exposure** — agents see placeholders, never values.
  Real bytes are injected at the boundary from Keychain, 1Password,
  Vault, AWS/GCP/Azure, Infisical, or Bitwarden, then scrubbed from
  everything that comes back. `rv secrets scan` + a git pre-commit hook
  catch leaks before they land.
- **MCP governance** — `rv mcp serve` puts every MCP server behind one
  gateway with per-tool allow/ask/deny, human approval for `ask`, and
  a full audit trail. `rv mcp check` fails if any server bypasses rv.
- **Egress control** — contained runtimes reach the network only
  through a credentialed CONNECT proxy: per-runtime tokens, SNI-bound
  tunnels, binary pinning, and a human review queue (`rv egress`).
- **Tamper-evident audit** — every decision lands in a SHA-256
  hash-chained `audit.jsonl`. Verify with `rv audit verify`, export
  as OCSF 1.3.0 to your SIEM.
- **Session forensics** — `rv scan` replays past agent sessions
  (Claude, Codex, Cursor, Grok, Hermes, OpenClaw, OpenCode, Pi)
  offline and reports what *would* have been denied.
- **Signed org policy** — fleet-wide, restrict-only rules signed with
  Ed25519 and pinned root-owned on disk. User config can never loosen
  them. `rv report` emits posture for MDM/fleet collection.
- **Contained workspaces (macOS)** — `rv opencode` / `rv workspace`
  run agents on a persistent per-project host under a deny-default
  Seatbelt profile: workspace-only writes, proxied HTTPS, no Keychain,
  no host signals. Linux refuses rather than downgrade. This is a
  hardening layer, not a finished isolation boundary — see the
  [acceptance audit](docs/security/runtime-acceptance.md).

## Everyday commands

```sh
rv test 'rm -rf /'          # evaluate a command, don't run it
rv explain 'rm -rf /'       # why would this block?
rv packs                    # browse the 95 packs
rv packs enable cloud.aws   # turn on more coverage
rv blocks                   # what got denied lately?
rv scan                     # audit past agent sessions
rv audit verify             # check the audit hash chain
rv doctor                   # service, packs, hosts, judge health
rv uninstall                # remove everything rv owns (owner-auth)
```

All commands speak `--json` / `--robot` / `--plain` / `--no-color`.
Anonymous usage counters are on by default; opt out with
`"analytics.enabled": false` in `~/.config/rv/config.json`.

## For developers

```sh
git clone https://github.com/christopherkarani/rv && cd rv
swift build --build-tests   # Swift 6.4
swift test                  # full suite (this is the PR gate)
```

Architecture in one line: a tiny C front door (`rv`) execs the Swift
CLI, which talks to the `rvd` daemon over a Unix socket
(XPC on macOS) — 15 IPC methods, one gated evaluation path for every
door. A Python SDK lives in [`sdk/python`](sdk/python). Security
model and evidence: [`docs/security`](docs/security).

Site: [rykanv.com](https://rykanv.com) · Docs:
[rykanv.com/docs/introduction](https://rykanv.com/docs/introduction) ·
Discord: [discord.gg/uZn9MDUYKx](https://discord.gg/uZn9MDUYKx)

## License

Apache 2.0. See [LICENSE](LICENSE).
