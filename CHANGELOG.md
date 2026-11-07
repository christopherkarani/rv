# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Action fingerprints now use an injective encoding. Pending runtime-HTTP asks, and pending asks for commands containing `:`, `,` or `\`, created before upgrade are re-asked after upgrade. Existing grants are unaffected. (#510)
- Hooks that cannot reach `rvd` now name the cause. (#441)
- `rvd` outages no longer block agents: client time budgets, judge warmup, safe idle exit, and setup/doctor repair. (#468)
- Hook ceremony peek evaluates with the live compile set. (#465)
- Config and policy layer updates are serialized under file locks. (#463, #464)
- `rv workspace run` ends cleanly when terminal output closes. (#477)
- Secret gateway refusals use explicit codes; `SecretSourceKind` is a single closed type shared by config, policy and varlock. (#503, #507)

### Added

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

- Every evaluation door now uses the owner's configured packs: contained workspaces (`rv workspace`, `rv opencode`), SDK `evaluate`, `explain` and `classify`. Before, the workspace host sent only the three day-one packs and SDK callers could send an empty list, so packs such as `cloud.aws` were skipped there.
- `rv scan` defaults to your configured packs instead of the day-one three, rejects `--packs` IDs that name no bundled pack, and refuses `--host` values it has no session reader for (Antigravity, Muse) instead of silently scanning nothing.
- Hook timeouts are ordered so rvd always gives up first: host shims now wait 13 s and host hook configs 15 s (Codex, Cursor, Antigravity, Grok, Muse), above the C client's 3 s hello + 8 s evaluate and rvd's 7 s budget. Before, a host could drop a reply while rvd still spent an allow-once grant on it. `rv setup` rewrites hooks written with the old timeouts without `--force`.
- Analytics honours the documented flat `"analytics.enabled": false` key as well as the nested form; when the two disagree, the opt-out wins. Events now report the product version instead of the IPC protocol version.
- Workspace publish refuses escaping symlinks; read-only workspace files are copied before their mode is applied. (#445, #490)
- Clocked vnode syscalls run on a bounded worker pool. (#444)
- `rv` commands guard against root fallback and have a `login` help topic. (#498)
- Untrusted text is escaped in egress, `secrets describe` and `audit verify` output, and display-hostile scalars are escaped in secrets, MCP and managed robot JSON. (#471, #511)
- Local test fixes for MCP sandbox creation on Darwin and the judge-unavailable floor. (#514, #525)

### Security

- Every enforced deny and every Policy-gate override (allow-once, allowlist, rebase recovery, contained delete) is now appended to the hash-chained `audit.jsonl` as `command.denied` or `command.override`, so `rv audit verify` covers the gate itself. Events carry the rule, host, tool and a home-redacted path, never command text. Plain allows are not logged. The audit export no longer lists a deny twice when it is also in `blocks.jsonl`.
- A same-user process can no longer enable or disable packs, save rules or resolve approvals over the SDK socket. Owner mutations stay refused on every generic IPC path; the Python SDK's `set_pack_enabled` now raises `AuthorizationDenied`.
- Contained runtimes (Seatbelt and the macOS guest) can no longer create, rewrite or remove agent and editor config that host tools run later: `.claude/settings.json`, `.claude/settings.local.json`, `.claude/hooks/`, `.mcp.json`, `.codex/config.toml`, `.cursor/hooks.json`, `.cursor/mcp.json`, `.gemini/settings.json`, `.vscode/tasks.json`, `.vscode/settings.json`, `opencode.json(c)` and `.envrc`. Matching is case-insensitive, and the cage also cannot create or remove the `.claude`, `.codex`, `.cursor`, `.gemini` and `.vscode` directories at the workspace root. The macOS guest profile now denies hard links and clones, as the host cage already did. The existing `.git/hooks`, `.git/config`, `.rv` and `.config/rv` protections gained case-insensitive companions.
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
