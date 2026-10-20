# rv feature inventory (from code)

Source of truth is the Swift, C, and Python source in this repo, not READMEs or docs.
Generated 2026-10-20 from the worktree source.

`rv` is a destructive-shell-command blocker and policy gate for AI coding agents.

## CLI surface

Root command: [RV.swift](../Sources/RVCLI/RV.swift).
Abstract is `Block destructive shell commands`.
It has 23 subcommands:

`opencode`, `workspace`, `test`, `explain`, `packs`, `policy`, `scan`,
`service`, `hook`, `setup`, `uninstall`, `doctor`, `allow-once`, `allowlist`,
`egress`, `safety`, `blocks`, `audit`, `secrets`, `mcp`, `managed`, `report`,
`operator`.

Shared output flags in [TestCommand.swift](../Sources/RVCLI/Commands/TestCommand.swift):
`--json`, `--robot`, `--plain`, `--no-color`.
Exit and emit convention lives in [CommandContext.swift](../Sources/RVCLI/CommandContext.swift).

Per-command surface:

- `rv test`: evaluate one command. `--explain` prints explain steps. Passthrough args.
- `rv explain`: show why a command is allowed or blocked. See [ExplainCommand.swift](../Sources/RVCLI/Commands/ExplainCommand.swift).
- `rv packs`: list packs. Subcommands `enable`, `disable`, `info`. Enablement works on pack, category, or preset IDs. See [PacksCommand.swift](../Sources/RVCLI/Commands/PacksCommand.swift).
- `rv policy`: `show`, `list`, `validate`, `export`, `apply`, plus `draft`. Show lists built-in, machine, and repo typed rules. List shows revisions oldest first. Export writes one origin as `policy.toml`. Apply previews or merges a shared document. Draft compiles English into a typed-rule preview. See [PolicyCommand.swift](../Sources/RVCLI/Commands/PolicyCommand.swift) and [PolicyDraftCommand.swift](../Sources/RVCLI/Commands/PolicyDraftCommand.swift).
- `rv allow-once`: redeem a six-character code from a hook deny. Subcommands `redeem`, `mint`, `list`, `clear`. List is redacted. Clear drops pending and granted rows. See [AllowOnceCommand.swift](../Sources/RVCLI/AllowOnceCommand.swift).
- `rv allowlist`: permanent user-layer exceptions. Subcommands `add` (rule-id), `add-command` (exact command), `remove`, `list`, `validate` (`allowlist.toml`). See [AllowlistCommand.swift](../Sources/RVCLI/AllowlistCommand.swift).
- `rv safety`: show or set `normal` or `strict`. Set requires owner authorization and writes machine config. Show resolves workspace-effective level. See [SafetyCommand.swift](../Sources/RVCLI/Commands/SafetyCommand.swift).
- `rv blocks`: list recent denials. See [BlocksCommand.swift](../Sources/RVCLI/Commands/BlocksCommand.swift).
- `rv audit`: unified audit trail. Subcommands `tail`, `verify`, `export`, `forward`. Verify checks the `audit.jsonl` hash chain and reports the first break. Export writes `rv.audit.v1` or OCSF JSON Lines for SIEM. Forward sends new events to a SIEM endpoint in one pass. See [AuditCommand.swift](../Sources/RVCLI/Commands/AuditCommand.swift) and [AuditForward.swift](../Sources/RVCLI/Commands/AuditForward.swift).
- `rv scan sessions`: offline deny-only forensics over 8 host session stores. See [ScanCommand.swift](../Sources/RVCLI/Commands/ScanCommand.swift).
- `rv hook`: evaluate a host shell hook on stdin. See [HookCommand.swift](../Sources/RVCLI/Commands/HookCommand.swift).
- `rv service status`: print whether `rvd` is running, down, or skewed. See [ServiceCommand.swift](../Sources/RVCLI/Commands/ServiceCommand.swift).
- `rv setup`: wire rv-owned host hooks and the `rvd` LaunchAgent. Supports `--force` (replace occupied owned hooks, backup to `*.bak`). Respects `RV_FROM_INSTALL`. See [SetupCommand.swift](../Sources/RVCLI/Commands/SetupCommand.swift).
- `rv uninstall`: remove rv-owned hook files, config, and the `rvd` LaunchAgent. Dangerous direction is LA-gated. See [UninstallCommand.swift](../Sources/RVCLI/Commands/UninstallCommand.swift).
- `rv doctor`: read service, pack, and host-adapter health. Uses live service diagnostics plus local environment. See [DoctorCommand.swift](../Sources/RVCLI/Commands/DoctorCommand.swift).
- `rv workspace`: `start`, `attach`, `status`, `run`, `agent`, `custom`, `tui`, `close`, `abandon`, `leftovers`. Start attaches when a host is already live. Leftovers lists workspaces left by a dead host across projects. Agent, custom, and abandon are present but marked not yet available. See [WorkspaceCommand.swift](../Sources/RVCLI/Commands/WorkspaceCommand.swift).
- `rv opencode`: launch OpenCode on the persistent workspace host. See [OpenCodeCommand.swift](../Sources/RVCLI/Commands/OpenCodeCommand.swift).
- `rv egress`: `pending`, `show`, `approve`, `deny`, `denials`. Pending lists network proposals awaiting a human. Approve is refused until authenticated service routes land. Denials shows proxy denials. See [EgressCommand.swift](../Sources/RVCLI/Commands/EgressCommand.swift).
- `rv secrets`: `list`, `check`, `set`, `remove`, `scan`, `describe`, `import`, `hook`. Check resolves providers and shows fingerprints, never values. Set stores in Keychain and defines on first use. Scan exits 1 on findings. Import reads Varlock `.env.schema` without copying literal values. Hook has `install`, `uninstall`, `run` for a git pre-commit scanner. See [SecretsCommand.swift](../Sources/RVCLI/Commands/SecretsCommand.swift).
- `rv mcp`: `list`, `check`, `serve`, `pending`, `approve`, `deny`, `trust`, `connect`, `import`, `setup`. Check exits 1 when any server bypasses rv, is unreviewed, or is blocked. Serve runs approved servers behind the policy gateway over stdio. Connect does OAuth sign-in with token refresh. Setup points hosts at `rv mcp serve` with `--undo`. See [MCPCommand.swift](../Sources/RVCLI/Commands/MCPCommand.swift).
- `rv managed`: `status`, `verify`, `keygen`, `sign`. Status shows installed org policy. Verify checks a bundle before deploy. Keygen creates an Ed25519 pair. Sign writes `policy.json.sig`. See [ManagedCommand.swift](../Sources/RVCLI/Commands/ManagedCommand.swift).
- `rv report`: emits `rv.report.v1` governance posture for MDM or fleet collection. Never resolves secrets. See [ReportCommand.swift](../Sources/RVCLI/Commands/ReportCommand.swift).
- `rv operator`: `propose` one identity launch for review, then `proposal-status` polls it. See [OperatorCommand.swift](../Sources/RVCLI/Commands/OperatorCommand.swift).

## Core evaluation engine

- Three-way decision: `allow`, `deny`, `indeterminate`. Never Ask. See [Decision.swift](../Sources/RVDomain/Decision.swift).
- Indeterminate reasons: `budgetExhausted`, `commandTooLarge`, `corePacksUnavailable`.
- Pack-only `evaluate` in [Evaluate.swift](../Sources/RVEngine/Evaluate.swift). Empty command returns plain. Over 65,536 UTF-8 bytes returns `commandTooLarge`. Missing core packs returns `corePacksUnavailable`.
- Requires usable `core.git` and `core.filesystem` snapshots. Also requires compiled `reset-hard` and `fork-bomb` rules when present on snapshots.
- Normalizes input to a matching view. Splits multi-segment commands and evaluates each segment. Terminal deny or indeterminate short-circuits.
- Quick-reject fast path. Keyword gating per pack. Forced filesystem check on empty-paren pairs.
- Safe patterns are checked before destructive ones. A safe hit skips that pack and is remembered. First blocking-severity destructive hit denies. Non-blocking hits are remembered as `hit`.
- Pattern-attempt budget. Over-budget returns `budgetExhausted`.
- Documentation queries return nil and skip matching.
- Secret-path guard folds over allow-like outcomes. Strict safety also checks metadata. Allow-path exemptions can suppress the deny. Uses `SecretPathCatalog.dayOne` by default.
- File-tool door is catalog-only. Packs and policy gate never see the raw path. See [GatedEvaluate.swift](../Sources/RVService/GatedEvaluate.swift).

## Policy gate and overrides

Total override order in [PolicyGate.swift](../Sources/RVPolicy/PolicyGate.swift):

- Allow passes through. Indeterminate never allows.
- Deny order: rebase recovery, then rule pinning (pins block all allow overrides), then allowlist, then allow-once grant, then balanced-profile contained reversible delete.
- `normal` safety enables the balanced allowance for contained generated-output deletes. `strict` disables it. Default is strict.
- `consumingGrant` spends only service-held memory grants. The allow-once file is a projection and is never consulted. `preview` peeks without spending. Used by TTY `test` and `explain`.
- Grants require non-empty matching view and cwd. Pinned results return before consuming so single-use authority is not burned.
- Deny-to-allow transition preserves the hit structure. Other outcomes pass through unchanged.
- Supporting stores: allowlist snapshots, ephemeral allow-once table, rebase recovery, rule pinning, contained reversible delete, masked payload digests, invocation prefixes. See `Sources/RVPolicy/`.

## Packs

- Bundled JSON packs in `Sources/RVPacks/Resources/packs/`. About 90 files plus `index.json`.
- Domains include: `core.filesystem`, `core.git`, `strict_git`, `package_managers`, `system.*`, `containers.*`, `cloud.*`, `kubernetes.*`, `infrastructure.*`, `database.*`, `storage.*`, `backup.*`, `remote.*`, `cicd.*`, `monitoring.*`, `messaging.*`, `search.*`, `email.*`, `payment.*`, `featureflags.*`, `platform.*`, `dns.*`, `cdn.*`, `loadbalancer.*`, `apigateway.*`, `secrets.*`, and `careful_company_running_windows.*`.
- Registry, catalog, index, JSON decoding, enablement, and selection tokens in `Sources/RVPacks/`. Enablement supports pack, category, and preset IDs.
- Typed rules live in machine and repo layers with revision history. Draft path compiles English to a preview through `EnglishCompileChain`.

## Safety, config, and persistence

- Safety levels `normal` and `strict` in `Sources/RVDomain/SafetyLevel.swift`.
- Shared object store `config.json` in [MachineConfigJSON.swift](../Sources/RVPolicy/MachineConfigJSON.swift). Holds `analytics.enabled` and machine safety.
- Machine and repo typed-rule stores, packs config, allowlist store, allow-once ledger and store, safety store, pending approval store, denylist store, agent definition store, runtime resource policy store. See `Sources/RVPolicy/`.
- Env selection for judges: `RV_FT_BUNDLE`, `RV_LAYA_BUNDLE`, `RV_JUDGE_TOUCHED`. Install detection: `RV_FROM_INSTALL`. Output: `NO_COLOR`, `TERM=dumb`, CI detection.

## Daemon, service runtime, and IPC

- `rvd` daemon plus `RVService` library. Products defined in [Package.swift](../Package.swift).
- `ServiceRuntime` actor owns gated evaluation, pack catalog, grants, analytics, pending approvals, and three ceremony services: workspace launch, action approval, hook review. See [ServiceRuntime.swift](../Sources/RVService/ServiceRuntime.swift).
- Grants are one instance per daemon lifetime. A restart drops the table and invalidates every grant.
- Gated evaluate has `peek` vs `apply` intents. Peek never records a denial. Apply does.
- 17 IPC methods in [IPCMethods.swift](../Sources/RVIPC/IPCMethods.swift): `evaluate`, `hookEvaluate`, `explain`, `classify`, `listPacks`, `setPackEnabled`, `doctorSnapshot`, `pendingList`, `pendingWatch`, `pendingResolve`, `rulePreview`, `ruleSave`, `proposeWorkspaceLaunch`, `launchProposalStatus`, `attestTTYRedemption`.
- Extended IPC results cover UI registration, launch review lists, challenge bundles, operation status, action review lists and statuses, hook review lists and statuses, and host action approval create, status, and decision.
- Transports: Unix socket on all platforms, XPC on macOS. Unix framing, socket paths, and listener code in `Sources/RVService/`.
- Idle exit watchdog. Core warmup. Live git, rebase, and filesystem probes. Doctor snapshot builder.
- Production `ServiceLog` is protocol-only with a nil seam. RVD passes `log: nil` on both macOS and Linux branches. Only two optional-chaining emit sites exist. Only conformances are test doubles. See [ServiceLog.swift](../Sources/RVService/ServiceLog.swift), [RVDProcess.swift](../Sources/RVService/RVDProcess.swift), and `Tests/RVServiceTests/Support/RecordingLog.swift`.

## Hooks and host adapters

- 9 hook hosts in `Sources/RVDomain/HookHost.swift`: `grok`, `pi`, `opencode`, `claude`, `openclaw`, `hermes`, `codex`, `cursor`, `antigravity`.
- Embedded adapter templates in `Sources/RVHooks/Resources/hosts/`. Includes `rv-guard` Python, JS, and TS templates plus Hermes and OpenClaw manifests. Resource index in [HostAdapterResources.swift](../Sources/RVHooks/HostAdapterResources.swift).
- Hook dispatch in [HookDispatch.swift](../Sources/RVHooks/HookDispatch.swift): stdin to codec to evaluate. Shell and file doors. Foreign input encodes allow. Malformed input encodes deny with no next action. Empty file path denies.
- Hook authorization decides verdict, pending recording, and unlock mint. Ask guidance carries a recorded flag so a failed record renders unrecorded guidance instead of a false promise.
- Unlock mint prefers the command-carrying port so the daemon binds payload digest. Legacy port mints unbound rows.
- C front door `rv` locates and execs sibling `rv-cli`. Hook paths fail closed with host-compatible denials and never replay. See [rv-c README](../Sources/rv-c/README.md).

## Isolation and workspaces

- Backends: `seatbelt`, `landlock`, `none`. Modes: `observed`, `mediated`, `contained`. Contained uses Seatbelt on macOS and Landlock on Linux. Fails closed when the backend cannot establish. See [IsolationApply.swift](../Sources/RVIsolation/IsolationApply.swift).
- Refuse rules before spawn: non-absolute workspace, missing or unresolvable or unsafe workspace path, inode alias inside workspace, inode boundary failure, unsupported contained guarantees, inapplicable profile, resource staging failure, NUL in command, non-absolute executable, session record failure, Seatbelt not established, lifetime boundary failure, unresolved protected workspace.
- Isolated stdio: discard to `/dev/null`, inherit, or host-owned PTY with rows and columns.
- Credential delivery defaults to closed. Host keys and credential files enter the cage only under explicit opt-in. Legacy agent integration controls non-secret integration separately.
- `rv-workspace-host` is a macOS-only persistent host. Usage is `rv-workspace-host --workspace <path>`. Owns signal mask and session. See [rv-workspace-host main](../Sources/rv-workspace-host/main.swift).
- Workspace TUI is a SwiftTUI multipane terminal shell app with event delivery and detach cleanup. Runtimes stay alive after detach. See [WorkspaceTUIApp.swift](../Sources/RVWorkspaceTUI/WorkspaceTUIApp.swift).
- Helpers: [rv-pty-claim](../Sources/rv-pty-claim/main.c) does Darwin session-leader PTY claim then exec, 127 on failure. [rv-isolation-exec](../Sources/rv-isolation-exec/main.c) is Linux-only Landlock restrict-self then exec, exits 125 and 126 reserved. [rv-terminal-probe](../Sources/rv-terminal-probe/main.swift) is a macOS-only SIGINT restorer probe, exits 2 and 3.

## Egress control

- Credentialed CONNECT proxy with per-grant tokens in [EgressProxy.swift](../Sources/RVIsolation/EgressProxy.swift). One 256-bit hex token per runtime or approval. Every request must present a mapped token. Tokens never hit the denial log.
- Denial reasons: header too large, policy, credential, malformed, DNS failed, address filtered, dial failed, binary mismatch, unattributed peer, SNI mismatch.
- Binds each tunnel to the origin it dials. TLS ClientHello SNI must match CONNECT authority on credentialed proxies.
- Binary-scoped policy with admission-time pinning. Fails closed on hash change, unreadable binary, missing pin, or unattributed peer.
- Policy blocks become proposals for the `rv egress` review queue.

## Secrets

- Placeholder model. Agents receive placeholders, never values.
- Source kinds: `keychain`, `hostEnvironment`, `onePassword`, `vault`, `awsSecretsManager`, `infisical`, `bitwarden`, `gcp`, `azure`. Managed policy can restrict allowed sources and environment delivery.
- Secret gateway is a placeholder-to-value loopback proxy. See [SecretGateway.swift](../Sources/RVIsolation/SecretGateway.swift).
- CLI covers list, check, set, remove, scan, describe, import, and git hook install, uninstall, and run.
- Upstream secret values are scrubbed from everything MCP upstreams return.

## MCP governance

- Config `mcp.json` v1, 1 MiB cap, 128 servers. See [MCPConfiguration.swift](../Sources/RVMCP/MCPConfiguration.swift).
- Gateway is an I/O-free state machine in [MCPGatewayCore.swift](../Sources/RVMCP/MCPGatewayCore.swift). Runtime supplies processes and pipes. Supported client versions include 2025-11-25, 2025-06-18, 2025-03-26, and 2024-11-05. Upstream version is 2025-06-18.
- Tool names join with `__`. List fanout caps at 64 pages per server. Cursor cycles end that server's pages. Replies from non-owning upstreams cannot consume a pending entry.
- `ask` approvals arrive via elicitation prompts or local `rv mcp approve`. Audit records server, tool, decision, approval ID, channel, argument keys only, duration, error, declined, and reason.
- Inventory across every host config with rv review status. Integrity checks. Redaction. Sandbox controls. Remote transport and upstream handling. OAuth connect with token storage and refresh. Host setup points configs at `rv mcp serve` with undo. Import moves literal credentials into Keychain.

## Managed org policy

- Restrict-only. User config can never loosen it. Defined in [ManagedPolicy.swift](../Sources/RVPolicy/ManagedPolicy.swift).
- `policy.json` version 1, 256 KiB max, strict unknown-key rejection. Optional non-negative integer `serial` with anti-rollback. Highest accepted serial is recorded.
- Ed25519 over exact policy bytes. `org-key.pub` can pin up to 16 keys with `#` comments for rotation. Any pinned key verifies. Reports 1-based signing-key position.
- Installed at `/Library/Application Support/RV/managed` on macOS and `/etc/rv/managed` on Linux. Must be root-owned with no group or other write. Ancestor chain checked to `/`. No env override. ACLs must be deny-only on Darwin.
- MCP section: blocked server globs, `allowDirect`, `requireSandbox`, `deny`, `ask`, `allow` globs, argument rules up to 1024, default decision. Strictest match wins. Glob supports `*` and `?`.
- Secrets section: allowed source kinds and environment-delivery flag.
- Audit section: forward URL plus headers. Header values may use `${secret:NAME}`.
- States: none, active bundle with sha256 and signed flag, or invalid with fail-closed reason.

## Audit, history, blocks, and report

- Hash-chained `audit.jsonl` with `prev=sha256`. Writer in [RVHistory.swift](../Sources/RVHistory/RVHistory.swift). Chain, cursor, log, event, and OCSF export in `Sources/RVHistory/`.
- Denial-only ledger: 200 rows and 7 days. Allows are never stored. Path redaction. Used by `rv blocks` and `rv egress denials`.
- `AuditLedger` is a 7-source read-side join. See [AuditLedger.swift](../Sources/RVHistory/AuditLedger.swift).
- `rv report` emits fleet posture without resolving secrets. Audit forward posts new events to SIEM.

## Scan forensics

- Offline session forensics. Deny-only findings. Adapters for Claude, Codex, Cursor, Grok, Hermes, OpenClaw, OpenCode, and Pi session stores. SQLite-backed with directory walking, include globs, JSON parsing, time windows, and dedupe. See `Sources/RVScan/` and [ScanCommand.swift](../Sources/RVCLI/Commands/ScanCommand.swift).

## Laya judges

- Stock 3-question CoreML judge plus single-pass fine-tuned judge. Judge context v2 serialization. See [FineTunedJudge.swift](../Sources/RVLaya/FineTunedJudge.swift) and [LayaJudge.swift](../Sources/RVLaya/LayaJudge.swift).
- Verdict has choice probabilities, `riskScore`, `malicious`, `risk`, checkpoint, latency, and truncated flag. Risk formula is `P(block) + 0.5*P(review)`, max with malicious. Action thresholds default to block at 0.8 and review at 0.45. Truncated views must not bind an allow.
- Guard questions are fixed Korean prompts for action choice, risk score, and malicious or instruction-hijack detection.
- Compiled-model cache keys on package path plus mtime. Compute units are CPU and GPU.
- `rv-judge` binary batches CoreML verdicts as JSON per command. Engine selection via `--ft` or `--stock` plus `RV_FT_BUNDLE`, `RV_LAYA_BUNDLE`, and `RV_JUDGE_TOUCHED`. See [rv-judge main](../Sources/rv-judge/main.swift).
- Harness in `Scripts/laya/`: `bench.py` runs guard testsets against `rv test`. `training/` has finetune, prepare, and convert scripts plus testsets and `export-onnx.sh`.

## Operator review and UI

- `rv-operator-ui` is a SwiftUI 3-tab review UI for launch, action, and hook reviews over an XPC bridge. Off-XPC uses an unavailable bridge. See [rv-operator-ui main](../Sources/rv-operator-ui/main.swift).
- Ceremonies for workspace launches, principal-bound action approvals, and hook asks. Pending approval store with resolve, sweep, and expiry. Hook asks resolve only through `HookAskResolver`, never as agent-instance grants.
- `rv operator propose` and `proposal-status` drive the identity-launch review flow from CLI.

## Output, theme, and presentation

- TTY-pair browse and color eligibility probe in [ThemeProbe.swift](../Sources/RVTheme/ThemeProbe.swift). Overrides: `--no-color`, `NO_COLOR`, `TERM=dumb`, `json`, `robot`, `plain`, `ci`.
- `RVPresentation`, `RVTUI`, and `RVTheme` libraries. `sysexits` taxonomy in [SetupError.swift](../Sources/RVCLI/Setup/SetupError.swift).
- Shell completions for bash, fish, and zsh in `Resources/Completions/`.

## SDK, binaries, and installer

- Python SDK sync `Client` in [client.py](../sdk/python/src/rv/client.py). Curated methods: `evaluate`, `explain`, `classify`, `listPacks`, `setPackEnabled`, `doctorSnapshot`, `pendingList`, `pendingWatch`, `pendingResolve`, `rulePreview`, `ruleSave`. `hookEvaluate` is raw-only. Includes `runtime_status`, `ensure_runtime` spawn, Hello handshake, Unix socket transport, typed skew errors, and a raw verbatim escape hatch.
- SPM products in [Package.swift](../Package.swift): executables `rv`, `rvd`, `rv-judge`, `rv-workspace-host`, macOS-only `rv-operator-ui`, `rv-terminal-probe`, `rv-pty-claim`, Linux-only `rv-isolation-exec`. Libraries for every `RV*` subsystem. Linux links system `sqlite3` and uses `swift-crypto`. Darwin uses CryptoKit and embedded SQLite.
- [install.sh](../install.sh) stages the `rv`, `rv-cli`, and `rvd` trio, runs setup, and signature-checks macOS downloads.

## Analytics and diagnostics

- Anonymous PostHog allow, deny, and indeterminate counters in [RVAnalytics.swift](../Sources/RVAnalytics/RVAnalytics.swift). Opt out via `analytics.enabled`.
- `rv doctor` combines service diagnostics with local pack and adapter health. `rv service status` detects skewed daemons.
