# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Curated secret defaults are least privilege instead of allowing every method and path at the gateway. A new `OPENAI_API_KEY` or `ANTHROPIC_API_KEY` allows `GET,POST /v1/**`; `GITHUB_TOKEN` and `GH_TOKEN` get `github-read` (no GraphQL, so most `gh` subcommands need `--allow "POST /graphql"`); `STRIPE_SECRET_KEY` and `VERCEL_TOKEN` get `read-only`. This applies to `rv secrets set NAME`, `rv login connect`, and a Varlock `@proxy` on the curated host. `--allow` on first set replaces the curated rules (`--allow "* /**"` restores full authority); secrets already on file keep their rules.
- Secret provider CLIs (`op`, `aws`, `infisical`, `bws`, `gcloud`, `az`) and the git hook's `git` are found in `/opt/homebrew/bin`, `/usr/local/bin` and `/usr/bin` first, so a caller's `PATH` can no longer put another binary in front of them. `PATH` is consulted only after those, and only for absolute directories that root owns and only root can write, with a binary that resolves inside such directories. A CLI installed elsewhere (for example `~/.cargo/bin/bws` or `~/google-cloud-sdk/bin/gcloud`) is refused with an error that names the directories searched; link it into one of them.
- The MCP gateway now fails closed without a key custodian the agent cannot read (macOS has one; Linux does not yet). There rv's approvals key is a file any process running as you can read, so mcp.json is never trusted (`rv mcp check` reports integrity `unsupported` with the reason), `rv mcp serve` launches no servers, and `rv mcp trust` and `rv mcp approve` refuse and say why. Before, an agent could edit mcp.json, re-sign it with that key, and have it treated as trusted.
- On a host without an MCP server sandbox (Linux today), an organization policy's `mcp.requireSandbox` now refuses every local server instead of being ignored, and `rv managed status` says so. `rv mcp check` names each bare server as running uncaged.

- Linux without a systemd user manager (WSL without systemd, containers, OpenRC/runit, logins without logind): `rv setup` no longer fails with "unable to enable systemd unit". It starts `rvd` directly in its own session, says plainly that it will not survive logout or reboot, and names the line to add to a shell profile (`rv service start >/dev/null`) or the command for a process supervisor. `rv service restart` restarts that `rvd` (or the systemd unit through `systemctl --user` where a user manager runs), new `rv service start` starts it only when it is not answering, `rv uninstall` stops it, and `rv doctor` adds a `systemd-user-manager` problem row with the fix. `systemctl` is found in `/usr/bin` or `/bin`.
- `rvd` on Linux binds `/run/user/<uid>/rv/evaluate.sock` when `XDG_RUNTIME_DIR` is unset, the path the C hook and the Swift CLI already dialled, instead of refusing to start; it creates `/run/user/<uid>` (0700) when missing and refuses one that is not owner-only, with a message that names the fix. The Python SDK resolves the same path.
- Every owner-check refusal exits `EX_NOPERM` (77) with one stderr line and no usage banner (`rv packs enable|disable`, `rv safety`, `rv allowlist`, `rv policy … --save`, `rv workspace abandon`, and the owner-check refusals of `rv allow-once` and `rv egress`). Other `rv allow-once`/`rv egress` gate refusals (TTY, `--json`, store) keep exit 2.
- `rv service status --json`/`--robot` prints an `rv.service.status.v1` JSON document; piped output without a flag keeps its `key=value` lines. `rv setup --json`/`--robot` prints an `rv.setup.v1` document on every run, including one that changed nothing and a failure.
- `rv doctor --json`: `service.fallback_ready` is now `service.local_packs_ready`, which is what it always measured; hooks have no in-process fallback.
- `rv packs info <id>` names an unknown pack instead of exiting 1 silently. `rv opencode` on Linux refuses before the macOS cage notice and the executable lookup, `rv init` on Linux suggests `rv setup` instead of `rv opencode`, and doctor's replaceable-interpreter fix no longer tells root to use the `/usr/bin/python3` it already uses.
- Action fingerprints now use an injective encoding. Pending runtime-HTTP asks, and pending asks for commands containing `:`, `,` or `\`, created before upgrade are re-asked after upgrade. Existing grants are unaffected. (#510)
- Hooks that cannot reach `rvd` now name the cause. (#441)
- `rvd` started by launchd (stderr on /dev/null) now writes its launch failures, with the cause, and transport warnings to an owner-only `~/Library/Logs/rv/rvd.log` (rotated at 1 MiB on startup). Under systemd they stay in the journal.
- `rv setup` refuses, before writing any hook, when the hooks would reject the installed `rvd` (an admin trust manifest that does not name it, or an unsigned build), instead of wiring hooks that deny every tool call. `rv doctor` reports `service.trust` with the reason and the fix, and `install.sh` refuses a local stage whose `rvd` cannot satisfy an installed trust manifest unless `RV_INSTALL_ALLOW_UNSIGNED=1`.
- `rvd` outages no longer block agents: client time budgets, judge warmup, safe idle exit, and setup/doctor repair. (#468)
- Hook ceremony peek evaluates with the live compile set. (#465)
- Config and policy layer updates are serialized under file locks. (#463, #464)
- `rv workspace run` ends cleanly when terminal output closes. (#477)
- Secret gateway refusals use explicit codes; `SecretSourceKind` is a single closed type shared by config, policy and varlock. (#503, #507)

### Added

- While rv's MCP gateway is in use (`~/.config/rv/mcp.json` exists, or the managed policy carries MCP rules), an agent can no longer add ungoverned MCP servers by rewriting a host's MCP config: shell writes (redirects, `tee`, `sed -i`, `mv`/`cp`/`ln` onto or into, `cd ~ && …`, `$HOME/…`, symlinked and dotfiles-aliased paths), unmodeled writers that name one (`python3`, `node`, `perl -i`, `sponge`, `xargs`), host CLIs that add servers or plugins (`claude mcp add`, `claude plugin install`, `codex|gemini|opencode mcp add`, `code --add-mcp`), and file-tool Edit/Write to `~/.claude.json`, project `.mcp.json`, Cursor/VS Code/Codex/OpenCode/Gemini/Antigravity/Windsurf/Muse/Claude Desktop configs, Claude Code's managed files and the `~/.claude/plugins` tree deny as `core.mcp:mcp-host-config`. Reads stay allowed, including a plain `cp` that only copies a guarded file elsewhere (`cp ~/.claude.json backup.json`) and read-only host CLI subcommands (`claude mcp list|get`, `claude plugin list`, `claude plugin marketplace list`); any other program that names a guarded file still asks, as does any command that pairs a guarded name with an unmodeled program (`echo .mcp.json | python3 …`), an environment assignment (`LESSOPEN=…`, `GIT_PAGER=…`), a git config override (`-c`, `--config-env`), a reader option that runs a program or writes a file (`less '+!cmd'`, `less -k`, `bat`/`ack`/`ag --pager=…`, `git grep -O…`, `git log --output=…`), or a missing working directory. Also asking, guarded name or not: a host CLI behind a launcher (`npx @anthropic-ai/claude-code mcp add`, `bunx`, `pnpm dlx`, `stdbuf`, `script`, `node …/cli.js`, Claude Code's native `…/claude/versions/X`), one whose subcommand rv cannot read (`claude "$@"` in a function, `claude $SUB add`, `… | xargs claude`, `$C mcp add`), MCP config installers (`mcp install`, `fastmcp install`, `@smithery/cli`, `install-mcp`, `add-mcp`), `gemini extensions install`, and a `cp`/`mv`/`ln`/`install` with an option word after an operand (macOS writes to the last word). `claude mcp serve` and `codex mcp-server` ask: they run the host's own tools for whatever client writes to them, outside rv's hooks. Rebase recovery never lifts this deny. The owner can approve one write through allow-once. Known limits, not guarded: a nested agent started with servers rv does not govern (`claude --mcp-config …`, `claude --plugin-dir …`, `codex -c mcp_servers…`), and a program that writes a config without its name on the command line (a script, or a git hook, diff/pager tool, `.ackrc` or lesskey file set up earlier). Observe mode does not block it: the would-be verdict is recorded in `rv blocks` (`observed ask` for shell commands, `observed` for Write/Edit). The guarded paths come from the same table as `rv mcp check`.
- `rv mcp check` and `rv report` inventory Claude Code plugin MCP servers (installed plugins from `installed_plugins.json`, honoring `CLAUDE_CODE_PLUGIN_CACHE_DIR`, and skills-directory plugins; `.mcp.json` and manifest `mcpServers`; `enabledPlugins: false` shows as disabled) and Claude Code's managed MCP config (`managed-mcp.json`, `managedMcpServers` in `managed-settings.json` and `managed-settings.d/`). `rv report` now also counts the project-level MCP configs of the directory it runs in.
- Install straight into observe mode: `rv setup --observe`, or `RV_INSTALL_MODE=observe` for `install.sh` (`enforce` or unset keeps today's behavior; any other value is refused before anything is downloaded). It stores `guard.mode: observe` before wiring hooks. Over an install that already enforces a wired host it asks for device-owner authentication first; under an organization gate it refuses. Hosts pinned to `block` stay enforced and setup names them. Observe still enforces rv's own self-protection while `rvd` runs. Because an observe host lets a call through when `rvd` is absent, observe also raises the bar on stopping or replacing `rvd`: `launchctl`/`systemctl` stops of rv's job (including `kickstart -k`, operand-less verbs fed by `xargs`, `launchctl asuser`), `pkill`/`killall` that may match `rvd` (a user/negation selection, or an operand-less program fed from stdin), `kill` of a pid looked up from `rvd` (`$(pgrep rvd)`, a `grep '[r]vd' | awk … | xargs kill` pipeline), launching a second `rvd`, Linux D-Bus stops (`busctl`/`dbus-send`/`systemd-run`/`loginctl` naming `dev.rv`), `echo`/`printf` of such a command piped to a shell or scheduler, and writes, moves or removes of rv's install (`~/.local/bin` binaries, `dev.rv.*` LaunchAgents, the systemd unit search dirs, `$XDG_RUNTIME_DIR/rv`) are floored at "run it in Terminal" through Bash and the Write/Edit tools; `rv setup --observe` from an agent is too (that one on every host). The stop/install floors are **observe-only** — enforce already fails such a call closed, so flooring there only adds false positives — and **lexical**, so they raise the bar but are not a boundary. Residual (not attempted): `kill` by a numeric pid or a pid/path held in a variable or file; interpreter or script forms (`python`/`node` subprocess, `bash -c "$(… | base64 -d)"`, a script file, a make/npm script); and a renamed or symlinked `launchctl`. An agent-supplied `pkill`/`awk` pattern cannot hang the gate: a catastrophic-backtracking or oversized pattern, or a huge verb word list, fails closed within a time bound. When `rvd` is unreachable, hooks under observe (read from `config.json` under the passwd home, never the environment, and never under an organization policy) let the call run unchecked with a stderr notice instead of prompting. A slow `rvd`, identity and protocol failures, and an explicit `RV_HOOK_WHEN_DOWN=deny` keep the existing ask/deny fallback.
- Per-host guard mode: `rv host list` and `rv host mode <host> block|observe|off` (`guard.hosts` in `config.json`). Loosening a host asks for device-owner authentication, and an agent that runs `rv host mode <host> observe|off` is told to run it in Terminal; `off` removes that host's rv hooks and `rv setup` skips it. A stored `block` outranks a global `guard.mode: observe`. An organization gate still pins enforce.
- Observe mode records what enforcement would have blocked: `rv blocks` rows carry `"observed": true` (an `observed` column in text output) and `rv audit` shows them as `command.observed`. Each observed row carries `"would_be": "deny"` or `"ask"`: whether the enforced hook would have denied outright or asked for human approval (`observed ask` in text output; rows written before this read as `deny`). Observe never relaxes rv's own protection while `rvd` runs: weakening rv commands and access to rv's config dir stay enforced.
- `rv workspace vms [--json] [--limit N]` lists micro-VM runtime sessions.
- Owner authentication for commands that change the gate: `rv packs enable|disable`, `rv safety`, `rv allowlist`, `rv policy draft --save`, `rv policy apply --save`, `rv policy export --output`, `rv egress approve|deny` and `rv workspace abandon` work again after Touch ID or the login password. On macOS `rvd` shows the Touch ID prompt itself, so this works on every install, including ones without a peer-trust manifest. On Linux `rvd` verifies the password with `unix_chkpwd`. Either way `rvd` allows one check at a time and locks checks for ten minutes after five wrong passwords or declined prompts. Every attempt is an `owner.action` audit event.
- `rv allow-once` works on Linux: the login password is the owner proof.
- The Swift CLI reaches `rvd` over its Unix socket on Linux (`rv hook` included), after checking the peer is the sibling `rvd` running as the same user.
- Signed organization policy has a restrict-only `gate` section: `requirePacks` lists packs every evaluation door applies whatever the user's pack config says, and `"safety": "strict"` forbids normal safety. A present but untrusted managed bundle now also forces strict safety. `rv managed status`, `rv safety` and `rv doctor` show the enforced level.
- Pretty output and `rv tui` ask the terminal for its background color (OSC 11) and use a light palette on light backgrounds. `RV_THEME=dark|light|auto` overrides; no answer, SSH sessions, and background jobs keep the dark palette.
- `rv tui` review pane (Ctrl-B R): pending egress proposals and recent blocks in one live list with a pending badge, details, and approve/deny through the same owner-authenticated ceremony as `rv egress approve`/`deny`.
- Secrets gateway: AWS SigV4 request signing from an `awsProfile` source, OAuth access-token minting from Keychain credentials, approve-rule requests held for a human, and binding of gateway secrets to the binaries allowed to spend them. (#483, #484, #485, #486, #487)
- Secrets gateway controls: per-secret substitution surfaces, method/path allow rules, Basic-auth placeholders, placeholders bound to their runtime, secret expiry with TTL refresh and live rotation, and per-position value encoding. (#452, #454, #455, #456, #459, #460)
- Secrets gateway audit: fail-closed audit, activity records and misuse findings. (#458)
- Varlock schema support: parse schemas with the env-spec grammar, correct schema import, map `@proxy` to gateway delivery. `rv init` no longer imports a project `.env.schema` on its own. (#448, #449, #450, #451)
- Secret scanning: in-memory pre-commit scan, token rules and a managed git hook block. (#461)
- Batch a launch's 1Password reads into one `op inject`. (#462)
- `rv login`: app logins that agents use through rv. (#439)
- MCP: Muse as an MCP host; Muse Code hook adapter (shell-only). (#436, #440)
- MCP approvals key custody moves to a signed custodian. (#438)
- Contained launches in a macOS guest (`rv workspace run --macvm`) and in a Linux micro-VM (`rv workspace run --microvm`). (#480, #489)
- Workspace publish is all-or-nothing. (#445)
- Competitive study and Tier 3 secrets design notes in the docs. (#447)

### Fixed

- `rv mcp serve` forwards tool results, upstream errors, and tool `inputSchema`/`outputSchema` exactly as the server sent them (after secret scrubbing). It used to rewrite every newline as a literal `\n` and double every backslash, which broke multi-line file contents and regex `pattern`s. Tool `description`/`title` keep newlines, tabs, and backslashes; only C0 controls other than TAB and LF, DEL, C1, format characters (bidi, zero-width, tag characters) and U+2028/U+2029 are shown as `\uXXXX`. The JSON rv writes escapes those same scalars, so nothing on the wire can split a line.
- `rv mcp serve` refuses a tool call with a JSON-RPC error (-32603) when it cannot write the call's `mcp.call` audit record, instead of printing a warning and forwarding it unrecorded. The record (`detail.stage: forward`) is written before the call goes upstream, as the secret gateway already does.
- Linux: hooks no longer deny every call 30 minutes after login. The systemd user unit was `Restart=no` and nothing relaunched an idle-exited `rvd`; it now keeps `rvd` resident (`--idle-exit-seconds=31536000`) with `Restart=always`, which also picks up an upgraded binary. `ExecStart` quotes the `rvd` path, so a HOME with a space or `%` no longer breaks the unit.
- Linux: `rv setup` no longer fails its readiness check on every systemd login, and `rv uninstall` / loosening `rv host mode` are no longer refused while `rvd` runs. The hook-door probes now say hello before their snapshot, which `rvd`'s socket requires; setup also warns when `rvd` is not answering.
- Linux: `rvd` no longer deadlocks under a burst of hook calls (each socket connection is served on its own thread instead of a dispatch worker blocked on its evaluation).
- A command with thousands of unmatched `$(`/`<(` openers was quadratic to scan (a 40 KB hook payload pinned `rvd`'s CPU for minutes, and was allowed); past 16 the segment fails closed.
- `cmd 2>/dev/null` and other output redirects to exactly `/dev/null` no longer deny as a write outside the repository.
- `rv doctor` on Linux: accepts `rv_RVPacks.bundle` (what Swift 6.4 emits) beside `rvd`, and reads a stopped `rvd` with its systemd unit installed as "down", not "not-installed".
- Linux owner checks: only `unix_chkpwd`'s wrong-password status counts toward the lockout; an account the helper cannot check (SSSD/LDAP/AD, systemd-homed, unreadable shadow) answers "cannot check". The helper is also found in `/run/wrappers/bin` (NixOS). Linux wording no longer mentions Touch ID, the RV approval app or the LaunchAgent.
- `swift-crypto` (a Linux-only dependency the Darwin-generated `Package.resolved` never pins) is pinned exactly.

- Linux release binaries are built on Ubuntu 22.04 (glibc 2.35) instead of 24.04 (glibc 2.39), so Ubuntu 22.04, Debian 12 and other glibc 2.35+ systems can run them; the release fails if a build needs newer glibc symbols. `install.sh` refuses up front, before downloading, on musl (Alpine), on glibc older than 2.35, and when libcurl or libsqlite3 is missing (naming the package to install); `RV_INSTALL_SKIP_LINUX_CHECKS=1` skips the glibc and library probes.
- Linux: `rv secrets set`, `rv login connect` and `rv mcp import` with credentials store values in the Secret Service keyring through `secret-tool` (libsecret-tools), and launches read `keychain` sources from it; without `secret-tool` or a session bus the refusal names what is missing. An agent's `secret-tool` and Secret Service D-Bus calls are denied (`core.secrets:secret-service`, kept enforced in observe mode).
- Linux: `rv mcp trust` and `rv mcp import` with credentials ask for the login password through `rvd` like other owner actions instead of refusing outright.
- Linux: an account with a locked or empty password (SSH-key-only users, root in containers) is told it cannot approve owner actions instead of being prompted and counted toward the lockout.
- Python SDK: falls back to `/run/user/<uid>` when `XDG_RUNTIME_DIR` is unset, like the Swift and C clients.

- An unreadable `~/.config/rv/config.toml` (permissions, invalid UTF-8) no longer drops the owner's enabled packs back to day-one at every door; rv evaluates under every bundled pack until the file is repaired. This includes a config directory without search permission, which used to read as "no config". `rv doctor` reports the packs as broken, `rv packs` warns, and `rv packs enable/disable` refuse to overwrite the file. Malformed TOML that still decodes is not caught yet.
- `rv packs` and `rv packs info` show packs the signed organization policy requires as enabled, `rv packs disable` says when a named pack stays enforced, and `rv scan` uses the org-required packs too. `rv managed status` warns when `gate.requirePacks` names an ID that is not a bundled pack, since nothing enforces it.
- `rv uninstall` also removes the `dev.rv.audit-forward` LaunchAgent that `rv audit forward --install` writes.
- `rv workspace run` help lists `--microvm`, `--macvm`, `--cpus` and `--memory-mib`.
- Every evaluation door now uses the owner's configured packs: contained workspaces (`rv workspace`, `rv opencode`), SDK `evaluate`, `explain` and `classify`. Before, the workspace host sent only the three day-one packs and SDK callers could send an empty list, so packs such as `cloud.aws` were skipped there.
- `rv scan` defaults to your configured packs instead of the day-one three, rejects `--packs` IDs that name no bundled pack, and refuses `--host` values it has no session reader for (Antigravity, Muse) instead of silently scanning nothing.
- Hook timeouts are ordered so rvd always gives up first. The C client no longer sends the evaluate request more than 5 s after it starts (it fails closed instead), so rvd is done by 12 s and the client by 13 s; host shims now wait 15 s and host hook configs 18 s (Codex, Cursor, Antigravity, Grok, Muse). Before, a host could drop a reply while rvd still spent an allow-once grant on it. `rv setup` rewrites hooks written with the old timeouts without `--force`.
- Analytics honours the documented flat `"analytics.enabled": false` key as well as the nested form; when the two disagree, the opt-out wins. Events now report the product version instead of the IPC protocol version.
- The egress proxy bounds host resolution (10 s; a late or over-budget lookup denies `dns-failed`) and refuses more non-public destinations after resolving: 192.0.0.0/24, 192.88.99.0/24, the Azure WireServer address, IPv4-translated IPv6, 2001::/23, 3fff::/20, anything outside 2000::/3, and NAT64 forms other than 64:ff9b::/96.
- Workspace publish refuses escaping symlinks; read-only workspace files are copied before their mode is applied. (#445, #490)
- Clocked vnode syscalls run on a bounded worker pool. (#444)
- `rv` commands guard against root fallback and have a `login` help topic. (#498)
- Untrusted text is escaped in egress, `secrets describe` and `audit verify` output, and display-hostile scalars are escaped in secrets, MCP and managed robot JSON. (#471, #511)
- Local test fixes for MCP sandbox creation on Darwin and the judge-unavailable floor. (#514, #525)
- Heredoc masking blanks the body where it was parsed, not the first copy of its text, so a body repeating an earlier word (`git reset --hard` then `cat <<EOF` / `git` / `EOF`) no longer hides that word from the gate. Bodies whose position is ambiguous (no terminator, CR, oddly quoted delimiter, `\` or `#` before the operator) stay visible.

### Security

- MCP tool rug-pull defence: only `rv mcp trust`, with you present, pins upstream tool definitions, in `~/.config/rv/mcp-tool-pins.json`, MAC'd with the approvals key that signs mcp.json. A pin is the hash of the whole tool object (name, description, title, annotations, input and output schema, `_meta`, icons, any other field). `rv mcp serve` never pins: it queues each definition that matches no pin in `~/.config/rv/mcp-tool-review.json` (unsigned, at most 1 MiB; a full queue drops new entries and says so on stderr) and says once per start on stderr how many tools on each server are not yet trusted. `rv mcp trust` shows every field of every queued definition, display-escaped, and pins exactly what it showed; if the pins on disk changed during the review it pins nothing and asks you to run it again. A missing, unreadable, or unverifiable pin store pins nothing, so deleting or rolling back the file can only make tools ask. A tool that is not pinned (new, changed, or not checkable, including one listed this session with any definition other than its pin, even once) is never called under `allow` for the rest of the session: it asks, and it is listed with rv's marker as its whole description, with no title, its schemas reduced to the keywords that decide validity, and only boolean annotations. Each such definition writes one `mcp.tool.changed` audit event. An approval is bound to the definition it was shown for. `rv mcp approve` says when a tool asks because it changed or is not yet trusted, and `--always` on such a tool approves once and points at `rv mcp trust`. A corrupt or oversized review queue is treated as empty and never blocks `rv mcp trust`. On Linux, where any same-user process can read the approvals key (rv does not honor approval grants there either), nothing is pinned and every MCP tool asks. Known limits: a running `rv mcp serve` keeps the pins it started with, so after `rv mcp trust` tools keep asking until the MCP host restarts it (trust says so); `mcp.tool.changed` has no OCSF mapping yet; JSON objects whose keys differ only by Unicode normalization (NFC/NFD) count as duplicate keys, so such a message is dropped.
- `rv mcp serve` builds a tool call's reply from the upstream's `result` or `error` only, so an upstream cannot add fields such as `method`/`params` to it. Every `description`/`title` string inside a pinned tool's schemas is shown with hiding scalars escaped, like the top-level description; `pattern`, `const`, `enum`, `default` and `examples` stay byte-exact. Tool result text is forwarded unchanged: rendering it safely (ESC sequences, bidi overrides, tag characters) is the MCP host's job. rv escapes those scalars wherever it shows or records text itself: approval prompts, `rv mcp trust`, stderr, and `audit.jsonl`, which now writes every such scalar as a JSON `\u` escape.
- `audit.jsonl` refuses an event whose line would exceed the verifier's line limit, instead of writing a line after which every append failed; the `mcp.call` event caps argument names (64 of at most 256 bytes, `argumentKeysTruncated`), the tool and subject (512 bytes) and the reason (1 KiB). `rv report` counts a forwarded MCP call once.
- Linux self-protection: the file-tool door now protects the Swift runtime libraries `rv-cli` and `rvd` load from `~/.local/bin` (`*.so`, `*.so.*`) and install.sh's `.rv*` files, as the shell guard already did, plus `~/.config/environment.d` (read into every user service, `rvd` included), systemd's `~/.config/systemd/user.conf`(`.d`) and `~/.config/systemd/user/service.d` drop-ins, and `rvd`'s `default.target.wants` link. An `rvd` that `rv setup`/`rv service start` runs directly (no systemd user manager) no longer inherits the caller's `LD_*` and other loader variables.
- A comment on an inert command (`ls # …`) is kept, and judged, when the same command can redefine that command name (an alias, function, `hash`, `eval`, `source`, `trap`, or a dynamic command word).
- `system.disk` denies Linux drive-destroying tools it missed: `mke2fs`/`mkntfs`/`mkdosfs`, `blkdiscard`, `sgdisk --zap-all`/`--clear`/`--delete`, `sfdisk` writes, `gdisk`, `nvme format`/`sanitize`, `sg_format`, `hdparm --security-erase`, `cryptsetup luksFormat`/`erase`, `ddrescue -f`, `badblocks -w`, `zpool destroy`, `zfs destroy`.

- Releases can sign `SHA256SUMS` (`SHA256SUMS.sig`, `ssh-keygen -Y`, namespace `rv-release`) with the `RV_RELEASE_SSH_SIGNING_KEY` secret. Once `install.sh` pins the public key, installs refuse a missing (unless `RV_INSTALL_ALLOW_UNSIGNED=1`) or invalid signature; until then Linux installs warn that release signatures are not verified.

- OAuth refresh-token state (`secrets-oauth/*.json`) and the loaded egress snapshot (`egress-loaded.json`) are now written owner-only (0600) with fsync, instead of with the process umask.
- Every hook and file-tool deny and every Policy-gate override (allow-once, allowlist, rebase recovery, contained delete) is now appended to the hash-chained `audit.jsonl` as `command.denied` or `command.override`, so `rv audit verify` covers the gate itself. Events carry the rule, host, tool and a home-redacted path, never command text. Plain allows and contained-workspace (`evaluateAgent`) decisions are not logged yet. The audit export and `rv audit forward` no longer send a deny twice when it is also in `blocks.jsonl`.
- A same-user process can no longer enable or disable packs, save rules or resolve approvals over the SDK socket. Owner mutations stay refused on every generic IPC path; the Python SDK's `set_pack_enabled` now raises `AuthorizationDenied`.
- Contained runtimes (Seatbelt and the macOS guest) can no longer create, rewrite or remove agent and editor config that host tools run later: `.claude/settings.json`, `.claude/settings.local.json`, `.claude/hooks/`, `.mcp.json`, `.codex/config.toml`, `.cursor/hooks.json`, `.cursor/mcp.json`, `.gemini/settings.json`, `.vscode/tasks.json`, `.vscode/settings.json`, `opencode.json(c)` and `.envrc`. Matching is case-insensitive, and the cage also cannot create or remove the `.claude`, `.codex`, `.cursor`, `.gemini` and `.vscode` directories at the workspace root. The macOS guest profile now denies hard links and clones, as the host cage already did. The existing `.git/hooks`, `.git/config`, `.rv` and `.config/rv` protections gained case-insensitive companions.
- Linux micro-VM guests now protect the agent and editor config listed in `WorkspaceRunLaterPaths`, the same set as the Seatbelt cage. Those files and hook directories are mounted read-only in the guest, and the `.claude`, `.codex`, `.cursor`, `.gemini`, `.vscode` and `.gemini/config` directories are pinned so they cannot be renamed aside. Matching in the guest is by exact name: unlike the Seatbelt rules, case variants such as `.Claude` are not covered. Missing paths get placeholders for the run (an empty directory or file, `{}` for JSON), removed afterwards unless changed. A test compares the guest's lists with the Seatbelt profile's.
- The Seatbelt cage can no longer create or remove `.gemini/config`. Before, a caged process could rename `.gemini/config` aside and rename a directory holding its own `hooks.json` into its place.
- Gate bypasses closed: in-place editors, interpreter writes, checkout paths, Cursor Grep/reads, Claude file tools, and a no-judge interpreter bypass. Installer downloads are now verified. (#442, #488, #491)
- Self-protection matches `rv` and its launchers case-, Unicode- and escape-insensitively. (#499)
- P0/P1 gaps in secrets handling and the secret-path guard fixed; `SecretValue` is redacted in reflection and gateway-only sources are refused on non-gateway delivery. (#523, #526)
- Organization policy now applies to secrets `scan`, `hook run` and `audit forward`; stdio MCP secrets are refused when environment delivery is forbidden. (#481, #482)
- Gateway proxy hardening; encoded secret echoes are scrubbed; compressed gateway responses and encoded placeholders are refused. (#453, #454, #457)
- Apple events are denied in the macOS guest profile. (#508)
- Symlinked MCP host configs are refused instead of replaced. (#472)

### Internal

- Roughly 45 architecture and test-coverage PRs (typed vocabularies, single-source modules for secret release, JSONL append, config roots, wire codecs, gated-evaluate effects, workspace terminal and recovery, TUI and runtime-terminal state models). (#437, #443, #446, #466, #467, #470, #473-#479, #492-#497, #500-#502, #504-#506, #509, #512, #518, #519, #528)

## [0.2.1] - 2026-10-26

### Added

- Laya judge lane (CoreML) and guard observe mode; judge weights ship via Hugging Face and are fetched by curl installs. (#423, #430)
- `rv init`, secrets fast path, `mcp onboard` and guided fixes. (#424)
- Linux release builds with per-target assets, including the Swift runtime libraries. (#432, #435)

### Changed

- MCP tool defaults flip to deny and require sandboxes. (#429)
- MCP fails closed on same-user key custody; direct mode never passes `check`. (#431)
- README rewritten to be shorter. (#427)

### Fixed

- One-line installer (unsigned-era verify), install smoke gates, and the Linux release smoke host (`claude-code` renamed to `claude`). (#433, #434)

### Security

- Mutual daemon authentication for the C and Swift hook clients. (#428)
- `SecretPathGuard` denies instead of skipping on operand overflow, and resolves symlink aliases. (#421, #422)

## [0.2.0] - 2026-10-17

### Added

- Agent governance, phase 1: `rv audit` unified audit trail, `rv workspace leftovers` crash-leftover scan, and accurate security status. (#395)
- Agent governance, phase 2: secrets the agent cannot leak, via a placeholder gateway and `rv secrets`. (#413)
- Agent governance, phase 3: MCP governance with inventory (`rv mcp list`/`check`), a gateway, approvals, import/setup, and sandboxed upstreams. (#414)
- Agent governance, phase 4: managed org policy, `rv report`, and OCSF audit forwarding. (#415)
- Productive workspace runtime v2: RV-managed home/cache/tmp per workspace, environment projection, sanitized PATH, and public-HTTPS egress policy. (#356)
- Contained shell UX with egress policy, a workspace TUI, and PTY-backed interactive runtime I/O. (#325, #326, #333, #337, #340)
- Per-runtime credentialed egress, network review (`rv egress`), binary pinning, and policy revision/rollback. (#416)
- Antigravity CLI host support. (#358)
- Python SDK (`rv-sdk`) and an owner-only macOS service socket for `rvd`. (#367)

### Changed

- Workspace stores moved to a shared `RVFileStore` module with file-locked JSONL. (#353, #354, #355)
- Shell parsing rebuilt on a shared Token/Argv vocabulary, with a single recursive unwrap, shared flag grammar and total filesystem and git parsers. (#343, #345, #346, #349, #350, #351, #383)
- Missing `--resource-profile` warnings name the remedy; workspace lifecycle refusals state the next action; unavailable workspace commands are marked in help; the banner and help disclose accepted runtime limits; TUI status indicators have text labels. (#401, #404, #406, #407, #403)
- Platform wording is scoped by feature and the contained-runtime refusal is shared. (#402)

### Fixed

- `rv doctor` grades ok from the worst component. (#412)
- Pack explanations are stored as plain prose with real newlines. (#410)
- Explicit `--plain` wins over piped/CI robot output. (#405)
- Egress and admission audit write failures are surfaced. (#411)

### Security

- Contained writes to workspace control paths are denied. (#408)
- Organization policy bundles that fail validation fail closed (MCP disabled, secret staging refused). (#415)
- Isolation review backlog fixes (typed core, resolve/compile split, race fixes) and recorded blocked P0 mechanism decisions. (#362, #400)

### Internal

- Arch/typing refactors (wire vocabulary, allow-once digest binding, pane state, launch payloads), build-cache CI speedups, Mutex replacing NSLock, and API-surface ratchets. (#328, #342, #348, #357, #359, #365, #380-#392, #394)

## [0.1.5] - 2026-09-21

### Added

- Contained `IsolationPlan` applied through Seatbelt (macOS) and Landlock (Linux), so writes outside the workspace fail closed. (#299, #300, #302, #303)
- Typed pipeline from agent request to executed action: `AgentRequest`, `ProposedAction` compiled to allowed/pending/denied, human approval decisions, and one-shot execution through `IsolationBackends.apply`. (#297, #304, #305, #306)
- Contained OpenCode host launch with inherited stdio. (#307)
- `PolicyWorkspace` for machine and repo policy documents. (#282)

### Changed

- A repeat deny reuses the same allow-once code, so agent retries do not mint a new one each time. (#301)
- Setup attach executes from a plan that names the host artifacts. (#284)

### Fixed

- Doctor pack health is read from config, not a stale `rvd` catalog. (#279)
- Unquoted newlines are treated as command separators, so a later-line `printf` is not a pipe operand. (#308)

### Internal

- Coverage and stress-test additions, public tree restacked on the Apple SPM layout, planning dumps removed, and several type-closing refactors. (#272-#278, #280, #281, #287, #289-#296)

## [0.1.4] - 2026-09-17

### Changed

- The curl installer accepts macOS 27 and later. Package tools are pinned to the Swift 6.4 release. (#271)

## [0.1.3] - 2026-09-17

### Added

- English policy drafts compile to typed rules (`rv policy show`, shareable `policy.toml`, compile then save); saved typed rules load at evaluate. (#181, #183, #185, #186, #188, #234)
- Host Ask for Claude and Hermes; OpenClaw spend-first Ask; Host Ask waits persist after `rvd` idle exit. (#187, #189, #268)
- Allow-once is minted on hook deny, and TTY redeem is the daily unlock. (#179)
- Typed predicates for discard, reset, clean, rm and move; git push, force-push, restore and shared-branch analysis. (#190, #213, #243, #244, #245, #269)
- Hooks deny Read/Edit/Write of catalog secret paths and honor file-tool Read on Cursor and Claude. (#199, #246)
- Wrapper and sink handling: peel `timeout`, `nice`, `mise` and `ssh`; unwrap pipe, stdin and process-substitution sinks; glued `rm` flags. (commits `b8b121c5`, `da769f07`, `b20541e0`)
- Quiet-allow for gray-area actions on hosts that cannot Ask. (#267)
- Faster hooks for large commands; hook deny tip and a default `system.disk`. (#176, #178)
- Optional stderr on the hook evaluate reply. (#173)

### Changed

- Install download bar is driven by real curl bytes. (#172)

### Fixed

- Documentation-only `--help` and `--version` are allowed. (#259)
- Data-role false positives in agent command parsing. (#260)
- Scan classify no longer fails closed as unresolved-path when the filesystem world is unprobed. (#210)

### Internal

- Roughly 40 typed-API, single-door evaluation and false-positive stress-test PRs. (#198, #201-#203, #220-#230, #237, #241, #242, #247-#249, #252, #254, #256-#258, #261-#266, #270)

## [0.1.2] - 2026-08-29

### Changed

- Swift owns the Host Ask pause; adapters honor `decision:ask` only. (#168)
- Session scan pipeline moved into `SessionScan`. (#167, #169)

### Fixed

- Doctor snapshot `keepAlive` parameter on Darwin. (#155)

### Internal

- `BoundReview` carried from semantics to the hook door; pending-approval consume folded into state. (#165, #166, #170)

## [0.1.1] - 2026-08-29

### Added

- Supported hosts: Cursor, Hermes, OpenClaw; host-native Ask for Pi, OpenCode and Claude. (#126, #125, #149, #129, #130)
- Semantic action analysis: filesystem, git, and recursive shell wrapper/interpreter analysis, plus a deterministic semantic policy engine and a repository filesystem boundary. (#119, #159, #160, #161, #162)
- Always-allow preview and save with hard-stop reject; pending list/watch/resolve on the service. (#156, #157)
- Sensitive host paths are protected by default. (#163)
- `rv scan sessions` with Pi, Grok and OpenCode session-store adapters, time window and dedupe, deny-only classify, and fail-on-findings. (#104-#110, #123)
- Claude `settings.json` merge, uninstall and doctor. (#100)
- Linux support: core tests on Linux, Linux `rvd` without XPC, C hook, CLI and install, and Ubuntu CI. (#113, #117, #120, #121)
- Apple Foundation Models reviewer in shadow mode. (#118)
- Apache 2.0 license and rewritten public README. (commits `b74c22fa`, `215a5af8`)

### Changed

- Host deny copy shortened. (#142, #143)
- Codex honor path is block, stderr reason, exit 2. (#140)
- Several performance changes in engine, IPC, scan and service caching. (#131-#138)
- `KeepAlive` is set only when the companion app is installed. (#152)

### Fixed

- LaunchAgent loads if already registered. (#122)
- `/tmp` deletes in compound scripts are no longer treated as root-home deletes. (#158)

## [0.1.0] - 2026-08-25

### Added

- Host hooks for Grok, Pi and OpenCode, with `rv hook`, `install.sh`, `rv setup` and uninstall. (#6, #7, #8)
- Pi deny card and OpenCode block toast. (#9)
- Allow-once from the TTY and a user allowlist. (#29)
- Catalog packs are off by default. (#30)
- Opt-out PostHog analytics for installs and daily active use. (#32)
- CLI polish: help, ceremonies and doctor; shared appearance for setup and status. (#22, #33)

### Changed

- The Policy gate is the only honor path. (#18)
- `rvd` health and doctor diagnostics deepened so `doctor` and `status` only format. (#23, #27)
- Host adapter ownership moved to `RVHooks`. (#17)

### Security

- Secret-path operands are denied after a pack allow. (#93)

### Internal

- Single-source evaluation, explain and lock modules, closed evaluation outcome state machine, typed wire enums, and an agent harness. (#10, #11, #19, #20, #24, #34, #35, #48, #50, #52, #55, #56, #74)

[Unreleased]: https://github.com/christopherkarani/rv/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/christopherkarani/rv/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/christopherkarani/rv/compare/v0.1.5...v0.2.0
[0.1.5]: https://github.com/christopherkarani/rv/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/christopherkarani/rv/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/christopherkarani/rv/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/christopherkarani/rv/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/christopherkarani/rv/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/christopherkarani/rv/releases/tag/v0.1.0
