import RVPolicy
import RVPresentation

/// Static help copy for every CLI surface that can show `--help` / `rv help`.
///
/// Leaf pages omit title/blurb (the typed command is enough) and omit Next unless
/// it marks a real workflow beat (`After setup` / `After uninstall`). Root keeps both.
enum HelpCatalog {
    static func page(_ topic: HelpTopic) -> HelpViewModel {
        switch topic {
        case .root: root
        case .help: helpMeta
        case .test: test
        case .explain: explain
        case .service: service
        case .serviceStatus: serviceStatus
        case .hook: hook
        case .setup: setup
        case .initialize: initialize
        case .uninstall: uninstall
        case .doctor: doctor
        case .allowOnce: allowOnce
        case .packs: packs
        case .scan: scan
        case .policy: policy
        case .allowlist: allowlist
        case .safety: safety
        case .blocks: blocks
        case .audit: audit
        case .secrets: secrets
        case .mcp: mcp
        case .managed: managed
        case .report: report
        case .opencode: opencode
        case .workspace: workspace
        case .`operator`: operatorHelp
        case .egress: egress
        }
    }

    static let root = HelpViewModel(
        title: "rv",
        blurb: "Block destructive shell commands.",
        sections: [
            HelpSection(
                heading: "Get started",
                rows: [
                    HelpRow(name: "rv", description: "Open the workspace shell in the current project (contained runtime, macOS only)"),
                    HelpRow(name: "opencode", description: "Launch OpenCode in a workspace sandbox (contained runtime, macOS only)"),
                    HelpRow(name: "workspace", description: "Attach to the persistent workspace host (contained runtime, macOS only)"),
                    HelpRow(name: "setup", description: "Wire host hooks and start rvd"),
                    HelpRow(name: "init", description: "Generate a runtime resource profile for this project"),
                    HelpRow(name: "test", description: "Try a command before it runs"),
                    HelpRow(name: "doctor", description: "Check service, packs, and hosts"),
                ],
                accentNames: true
            ),
            HelpSection(heading: "Everyday", rows: [
                HelpRow(name: "explain", description: "Why something was allowed or blocked"),
                HelpRow(name: "allow-once", description: "Redeem the six-character code from a hook deny"),
                HelpRow(name: "scan", description: "Session forensics for deny-only findings"),
                HelpRow(name: "safety", description: "Show or set normal or strict"),
                HelpRow(name: "blocks", description: "List recent denials"),
                HelpRow(name: "audit", description: "Unified audit trail; export for SIEM"),
                HelpRow(name: "secrets", description: "Secrets agents use through placeholders"),
                HelpRow(name: "mcp", description: "Find, review, and govern MCP servers"),
                HelpRow(name: "egress", description: "Review blocked network egress"),
                HelpRow(name: "service", description: "Is rvd running, down, or skewed"),
            ]),
            HelpSection(heading: "Advanced", rows: [
                HelpRow(name: "packs", description: "List and enable or disable packs"),
                HelpRow(name: "policy", description: "Show, list, draft, or share typed rules"),
                HelpRow(name: "allowlist", description: "Permanent user-layer exceptions"),
                HelpRow(name: "hook", description: "Host stdin adapter (Pi / Grok / OpenCode / Claude / OpenClaw / Hermes / Codex / Cursor / Antigravity)"),
                HelpRow(name: "uninstall", description: "Remove rv-owned hooks, config, and LaunchAgent"),
                HelpRow(name: "operator", description: "Propose and poll identity launches (review required)"),
                HelpRow(name: "managed", description: "Organization policy: status, verify, keygen, sign"),
                HelpRow(name: "report", description: "Governance posture of this machine (MDM, --json)"),
            ]),
        ],
        examples: [
            "rv",
            "rv setup",
            "rv test 'git reset --hard'",
            "rv explain 'rm -rf ~'",
        ],
        next: [
            HelpNextItem(command: "rv setup", description: "Wire hosts and start rvd"),
            HelpNextItem(command: "rv help setup", description: "Flags and what setup writes"),
        ]
    )

    static let helpMeta = HelpViewModel(
        title: "",
        blurb: "",
        sections: [
            HelpSection(heading: "Usage", rows: [
                HelpRow(name: "rv help"),
                HelpRow(name: "rv help <command>"),
                HelpRow(name: "rv help service status"),
            ]),
        ]
    )

    static let opencode = HelpViewModel(
        title: "",
        blurb: "",
        sections: [
            HelpSection(heading: "Usage", rows: [
                HelpRow(name: "rv opencode [--executable <absolute-path>] [--workspace <absolute-path>] [--resource-profile <id>] [--] <agent-arguments>"),
            ]),
            HelpSection(heading: "Flags", rows: [
                HelpRow(name: "--executable", description: "Absolute executable; default searches absolute PATH directories"),
                HelpRow(name: "--workspace", description: "Writable workspace; default is the current directory"),
                HelpRow(name: "--resource-profile", description: "Owner-authorized resource profile ID; without one no credentials are staged"),
                HelpRow(name: "--", description: "Pass all following arguments to OpenCode, including --help"),
            ]),
            HelpSection(heading: "Isolation", rows: [
                HelpRow(name: "files", description: "Workspace read and write, plus the system locations needed to start programs. Children inherit those rules"),
                HelpRow(name: "limits", description: "Public HTTPS through the RV proxy; loopback allowed. Direct public, LAN, and metadata connections denied, as are Unix-socket connections to host sockets. Signals outside the sandbox are denied. Linux refuses launch until it can enforce the same limits. Limits: \(AcceptedRuntimeLimits.line)"),
                HelpRow(name: "failure", description: "Sandbox initialization failure stops execution; no unrestricted fallback"),
                HelpRow(name: "platform", description: "Contained runtime is macOS-only today. Hook guard (rv hook) works on Linux and macOS; on Linux this launch is refused instead of using a weaker sandbox. See docs/security/runtime-boundary.md for why"),
            ]),
        ],
        examples: ["rv opencode", "rv opencode --workspace /path/to/repo -- run 'describe this project'"]
    )

    static let workspace = HelpViewModel(
        title: "",
        blurb: "",
        sections: [
            HelpSection(heading: "Usage", rows: [
                HelpRow(name: "rv workspace start [--workspace <absolute-path>]"),
                HelpRow(name: "rv workspace attach [--workspace <absolute-path>]"),
                HelpRow(name: "rv workspace status [--workspace <absolute-path>]"),
                HelpRow(name: "rv workspace close [--workspace <absolute-path>]"),
                HelpRow(name: "rv workspace run [--rows N] [--columns N] [--resource-profile <id>] [--hook <tag>] -- <absolute-executable> [args...]"),
                HelpRow(name: "rv workspace agent [--workspace <absolute-path>] [--rows N] [--columns N] <definition-id> -- [args...]", description: "Launch a trusted operator-configured Agent Definition (not yet available)"),
                HelpRow(name: "rv workspace custom [--workspace <absolute-path>] [--rows N] [--columns N] --expected-content-digest-sha256 <digest> -- <absolute-executable> [args...]", description: "Launch an ad-hoc definition (not yet available); executable image verification is deferred"),
                HelpRow(name: "rv workspace tui [--workspace <project-path>]", description: "Interactive terminal workspace for contained runtimes"),
                HelpRow(name: "rv workspace abandon [--workspace <absolute-path>]", description: "Discard a blocked workspace's unpublished volume and restore the saved tree (not yet available)"),
                HelpRow(name: "rv workspace leftovers", description: "List workspaces a dead host left behind, across all projects"),
            ]),
            HelpSection(heading: "Flags", rows: [
                HelpRow(name: "--workspace", description: "Project path; default is the current directory"),
                HelpRow(name: "--resource-profile", description: "Owner-authorized runtime resource profile ID"),
                HelpRow(name: "--hook", description: "Hook protocol host; tags never stage credentials"),
                HelpRow(name: "--expected-content-digest-sha256", description: "Lowercase SHA-256 digest for a custom Agent Definition"),
            ]),
            HelpSection(heading: "Platform", rows: [
                HelpRow(name: "platform", description: "Contained runtime is macOS-only today. Hook guard (rv hook) works on Linux and macOS; on Linux the workspace host refuses instead of using a weaker sandbox. See docs/security/runtime-boundary.md for why"),
            ]),
        ],
        examples: ["rv workspace start", "rv workspace status"]
    )

    static let test = HelpViewModel(
        title: "",
        blurb: "",
        sections: [
            HelpSection(heading: "Usage", rows: [
                HelpRow(name: "rv test [--explain] [--json] [--robot] [--plain] [--no-color] <command>"),
            ]),
            HelpSection(heading: "Flags", rows: [
                HelpRow(name: "--explain", description: "Print explain steps"),
                HelpRow(name: "--json", description: "Robot JSON on stdout"),
                HelpRow(name: "--robot", description: "Robot JSON on stdout"),
                HelpRow(name: "--plain", description: "Plain human output without color, even when piped"),
                HelpRow(name: "--no-color", description: "Disable color"),
            ]),
            HelpSection(heading: "Exit codes", rows: [
                HelpRow(name: "0", description: "Allow"),
                HelpRow(name: "1", description: "Deny (or incomplete evaluation)"),
            ]),
        ],
        examples: [
            "rv test 'git reset --hard'",
            "rv test --explain 'rm -rf /tmp/x'",
        ]
    )

    static let explain = HelpViewModel(
        title: "",
        blurb: "",
        sections: [
            HelpSection(heading: "Usage", rows: [
                HelpRow(name: "rv explain [--json] [--robot] [--plain] [--no-color] <command>"),
            ]),
            HelpSection(heading: "Flags", rows: [
                HelpRow(name: "--json", description: "Robot JSON on stdout"),
                HelpRow(name: "--robot", description: "Robot JSON on stdout"),
                HelpRow(name: "--plain", description: "Plain human output without color, even when piped"),
                HelpRow(name: "--no-color", description: "Disable color"),
            ]),
        ],
        examples: [
            "rv explain 'git reset --hard'",
            "rv explain 'git status'",
        ]
    )

    /// Parent page: discover status; flag Examples live on `service status`.
    static let service = HelpViewModel(
        title: "",
        blurb: "",
        sections: [
            HelpSection(heading: "Usage", rows: [
                HelpRow(name: "rv service"),
                HelpRow(name: "rv service status"),
            ]),
            HelpSection(heading: "Subcommands", rows: [
                HelpRow(name: "status", description: "Print whether rvd is running, down, or skewed (default)"),
            ]),
        ],
        examples: [
            "rv service",
        ]
    )

    static let serviceStatus = HelpViewModel(
        title: "",
        blurb: "",
        sections: [
            HelpSection(heading: "Usage", rows: [
                HelpRow(name: "rv service status [--json] [--robot] [--plain] [--no-color]"),
            ]),
            HelpSection(heading: "Flags", rows: [
                HelpRow(name: "--json", description: "key=value lines (same as --robot)"),
                HelpRow(name: "--robot", description: "key=value lines"),
                HelpRow(name: "--plain", description: "Disable browse and color"),
                HelpRow(name: "--no-color", description: "Disable color"),
            ]),
        ],
        examples: [
            "rv service status",
            "rv service status --robot",
        ]
    )

    /// Host stdin is adapter-owned — no fake file Examples.
    static let hook = HelpViewModel(
        title: "",
        blurb: "",
        sections: [
            HelpSection(heading: "Usage", rows: [
                HelpRow(name: "rv hook [--host <host>]"),
            ]),
            HelpSection(heading: "Flags", rows: [
                HelpRow(name: "--host <host>", description: "Host codec: grok (default), pi, opencode, claude, openclaw, hermes, codex, cursor, antigravity"),
            ]),
            HelpSection(heading: "Platform", rows: [
                HelpRow(name: "platform", description: "Hook guard works on Linux and macOS. Contained runtime (rv opencode / rv workspace) is macOS-only today; on Linux it refuses instead of using a weaker sandbox. See docs/security/runtime-boundary.md for why"),
            ]),
        ]
    )

    static let setup = HelpViewModel(
        title: "",
        blurb: "",
        sections: [
            HelpSection(heading: "Usage", rows: [
                HelpRow(name: "rv setup [--force] [--json] [--robot] [--plain] [--no-color]"),
            ]),
            HelpSection(heading: "Flags", rows: [
                HelpRow(name: "--force", description: "Replace occupied owned hooks (backup *.bak)"),
                HelpRow(name: "--json", description: "One line, no circles (same as --robot)"),
                HelpRow(name: "--robot", description: "One line, no circles"),
                HelpRow(name: "--plain", description: "Disable browse and color"),
                HelpRow(name: "--no-color", description: "Disable color"),
            ]),
        ],
        examples: [
            "rv setup",
            "rv setup --force",
            "rv setup --robot",
        ],
        nextHeading: "After setup",
        next: [
            HelpNextItem(command: "rv test 'git reset --hard'", description: "Prove day-one deny"),
            HelpNextItem(command: "rv doctor", description: "Confirm hosts and service"),
        ]
    )

    static let initialize = HelpViewModel(
        title: "",
        blurb: "",
        sections: [
            HelpSection(heading: "Usage", rows: [
                HelpRow(name: "rv init [--project <dir>] [--profile-id <id>] [--agent <tag>...] [--secret <name>...] [--varlock <file>] [--dry-run]"),
            ]),
            HelpSection(heading: "Flags", rows: [
                HelpRow(name: "--profile-id", description: "Profile id to create. Default: main"),
                HelpRow(name: "--agent", description: "Serve this agent tag (repeatable). Default: detect installed agents"),
                HelpRow(name: "--secret", description: "Wire this secret name into the profile (repeatable)"),
                HelpRow(name: "--varlock", description: ".env.schema to import. Default: <project>/.env.schema when present"),
                HelpRow(name: "--dry-run", description: "Show the plan; write nothing"),
            ]),
            HelpSection(heading: "Notes", rows: [
                HelpRow(name: "writes", description: "Appends one profile to ~/.config/rv/runtime-resources.json; other profiles untouched"),
                HelpRow(name: "detects", description: "Agent binaries on PATH plus installed credential files (claude, codex, opencode, muse)"),
                HelpRow(name: "explicit", description: "Launches still name the profile with --resource-profile; nothing is auto-selected"),
            ]),
        ],
        examples: [
            "rv init --dry-run",
            "rv init --secret OPENAI_API_KEY",
        ]
    )

    /// No Example — uninstall is destructive if pasted blindly.
    static let uninstall = HelpViewModel(
        title: "",
        blurb: "",
        sections: [
            HelpSection(heading: "Usage", rows: [
                HelpRow(name: "rv uninstall"),
            ]),
        ],
        nextHeading: "After uninstall",
        next: [
            HelpNextItem(command: "rv setup", description: "Re-wire hosts later"),
            HelpNextItem(command: "rv help", description: "All commands"),
        ]
    )

    static let doctor = HelpViewModel(
        title: "",
        blurb: "",
        sections: [
            HelpSection(heading: "Usage", rows: [
                HelpRow(name: "rv doctor [--json] [--robot] [--plain] [--no-color]"),
            ]),
            HelpSection(heading: "Flags", rows: [
                HelpRow(name: "--json", description: "Robot JSON on stdout"),
                HelpRow(name: "--robot", description: "Robot JSON on stdout"),
                HelpRow(name: "--plain", description: "Plain human output without color, even when piped"),
                HelpRow(name: "--no-color", description: "Disable color"),
            ]),
        ],
        examples: [
            "rv doctor",
            "rv doctor --json",
        ]
    )

    static let safety = HelpViewModel(
        title: "",
        blurb: "",
        sections: [
            HelpSection(heading: "Usage", rows: [
                HelpRow(name: "rv safety"),
                HelpRow(name: "rv safety normal"),
                HelpRow(name: "rv safety strict"),
            ]),
            HelpSection(heading: "Notes", rows: [
                HelpRow(
                    name: "normal",
                    description: "File-tool secret paths plus today's shell evaluate"
                ),
                HelpRow(
                    name: "strict",
                    description: "Also deny ls / test / stat of a catalog path"
                ),
            ]),
        ],
        examples: [
            "rv safety",
            "rv safety strict",
        ]
    )

    static let blocks = HelpViewModel(
        title: "",
        blurb: "",
        sections: [
            HelpSection(heading: "Usage", rows: [
                HelpRow(name: "rv blocks [--json] [--robot] [--plain] [--no-color]"),
            ]),
            HelpSection(heading: "Flags", rows: [
                HelpRow(name: "--json", description: "JSON array on stdout"),
                HelpRow(name: "--robot", description: "JSON array on stdout"),
                HelpRow(name: "--plain", description: "Disable color"),
                HelpRow(name: "--no-color", description: "Disable color"),
            ]),
            HelpSection(heading: "Notes", rows: [
                HelpRow(
                    name: "ledger",
                    description: "Denial-only. Paths replace the home prefix with ~"
                ),
            ]),
        ],
        examples: [
            "rv blocks",
            "rv blocks --json",
        ]
    )

    static let audit = HelpViewModel(
        title: "",
        blurb: "",
        sections: [
            HelpSection(heading: "Usage", rows: [
                HelpRow(name: "rv audit [tail] [-n <count>] [--since <duration>] [--kind <kind>]... [--json]"),
                HelpRow(name: "rv audit export [--since <duration>] [--kind <kind>]... [--format rv|ocsf]"),
                HelpRow(name: "rv audit forward [--to <url>] [--header NAME=VALUE]... [--format ocsf|rv] [--from-now]"),
                HelpRow(name: "rv audit forward --install [--to <url>] [--header NAME=${secret:X}]..."),
                HelpRow(name: "rv audit verify [--json]"),
            ]),
            HelpSection(heading: "Flags", rows: [
                HelpRow(name: "-n, --limit", description: "Newest events to show (default 50)"),
                HelpRow(name: "--since", description: "Only events newer than 30m, 24h, 7d"),
                HelpRow(name: "--kind", description: "Kind or prefix: egress, admission, runtime, workspace, agent"),
                HelpRow(name: "--json", description: "JSON array on stdout"),
            ]),
            HelpSection(heading: "Notes", rows: [
                HelpRow(
                    name: "sources",
                    description: "Joins every rv ledger in ~/.config/rv into one rv.audit.v1 stream"
                ),
                HelpRow(name: "export", description: "JSON Lines, oldest first, for SIEM ingest (OCSF 1.3.0 with --format ocsf)"),
                HelpRow(name: "forward", description: "POSTs new events in batches; cursor advances only on 2xx (at-least-once)"),
                HelpRow(name: "forward --to", description: "https, or http to localhost; default is the org policy audit.forward"),
                HelpRow(name: "--install", description: "macOS LaunchAgent every 5 min; prints a LaunchDaemon template for root"),
                HelpRow(name: "chain", description: "Each audit.jsonl line holds prev, the SHA-256 of the line before it (unkeyed: anchoring needs the forwarded head)"),
                HelpRow(name: "verify", description: "Finds edits, deletions, and reordering that did not recompute the chain; exit 1 at the first break"),
                HelpRow(name: "head", description: "Forwarded events carry rv_chain_head; compare it off-machine to spot a cut or recomputed tail"),
            ]),
        ],
        examples: [
            "rv audit",
            "rv audit --kind egress --since 24h",
            "rv audit export --since 7d > rv-audit.jsonl",
            "rv audit forward --to https://siem.example.com/rv --header 'Authorization=Bearer ${secret:SIEM_TOKEN}'",
            "rv audit forward --install",
            "rv audit verify",
        ]
    )

    static let secrets = HelpViewModel(
        title: "",
        blurb: "",
        sections: [
            HelpSection(heading: "Usage", rows: [
                HelpRow(name: "rv secrets [list] [--json]"),
                HelpRow(name: "rv secrets check [<name>...] [--json]"),
                HelpRow(name: "rv secrets set <name> [--gateway <url> --base-url-env <var> | --environment] [--resource-profile <id>]"),
                HelpRow(name: "rv secrets remove <name>"),
                HelpRow(name: "rv secrets scan [<dir>] [--json]"),
                HelpRow(name: "rv secrets describe [--json]"),
                HelpRow(name: "rv secrets import --varlock <.env.schema> [--dry-run]"),
                HelpRow(name: "rv secrets hook install | uninstall"),
            ]),
            HelpSection(heading: "Flags", rows: [
                HelpRow(name: "--gateway", description: "https upstream the real value may be sent to"),
                HelpRow(name: "--base-url-env", description: "Variable that receives the gateway base URL"),
                HelpRow(name: "--placeholder-prefix", description: "Prefix kept on the placeholder, e.g. sk-"),
                HelpRow(name: "--environment", description: "Real value in the cage env instead (weaker)"),
                HelpRow(name: "--agent", description: "Only stage for this agent tag (repeatable)"),
                HelpRow(name: "--resource-profile", description: "Wire the secret into this runtime profile (see `rv init`)"),
            ]),
            HelpSection(heading: "Notes", rows: [
                HelpRow(name: "config", description: "~/.config/rv/secrets.json; profiles list names in \"secrets\""),
                HelpRow(
                    name: "gateway",
                    description: "Agents hold a per-launch placeholder; rv swaps in the value toward the upstream only"
                ),
                HelpRow(
                    name: "sources",
                    description: "keychain, hostEnvironment, onePassword, vault, aws, infisical, bitwarden, gcp, azure"
                ),
                HelpRow(
                    name: "defaults",
                    description: "OPENAI_API_KEY, ANTHROPIC_API_KEY, STRIPE_SECRET_KEY, GITHUB_TOKEN, GH_TOKEN default to their gateway"
                ),
                HelpRow(name: "describe", description: "Names, descriptions, types, and delivery for agents; never a value"),
                HelpRow(name: "varlock", description: "import --varlock reads @sensitive, @type, and provider refs; literals are skipped"),
                HelpRow(name: "hook", description: "pre-commit scans staged files and prints file:line:name; an existing hook is kept"),
                HelpRow(name: "audit", description: "rv audit --kind secret.use shows each use with a fingerprint"),
            ]),
        ],
        examples: [
            "rv secrets set OPENAI_API_KEY --resource-profile main",
            "rv secrets check",
            "rv secrets scan .",
        ]
    )

    static let mcp = HelpViewModel(
        title: "",
        blurb: "",
        sections: [
            HelpSection(heading: "Usage", rows: [
                HelpRow(name: "rv mcp [list] [--project <dir>] [--json]"),
                HelpRow(name: "rv mcp check [--project <dir>] [--json]"),
                HelpRow(name: "rv mcp import --host <host> [--server <name>...] [--allow-tools] [--dry-run]"),
                HelpRow(name: "rv mcp onboard --host <host> [--server <name>...] [--allow-tools] [--dry-run]"),
                HelpRow(name: "rv mcp setup --host <host> [--server <name>...] [--rv-path <path>] [--undo]"),
                HelpRow(name: "rv mcp serve --server <name> [--server <name>...]"),
                HelpRow(name: "rv mcp pending | approve <id> [--always] | deny <id>"),
                HelpRow(name: "rv mcp trust"),
                HelpRow(name: "rv mcp connect <server> [--client-id <id>] [--scope <s>] [--no-browser] [--forget]"),
            ]),
            HelpSection(heading: "Tool policy", rows: [
                HelpRow(name: "order", description: "Strictest matching glob or rule (deny > ask > allow), else default"),
                HelpRow(
                    name: "rules",
                    description: "{\"tool\": \"query\", \"when\": {\"/db\": {\"==\": \"prod\"}}}; ops == != < > in glob"
                ),
                HelpRow(name: "missing", description: "A rule never matches an argument the call left out; keep a non-allow default"),
                HelpRow(name: "deny", description: "Hidden from the agent; calls fail"),
                HelpRow(name: "ask", description: "Approved in the host's prompt, or `rv mcp approve`; one identical call"),
                HelpRow(name: "approve", description: "Needs Touch ID or your password. A pseudo-terminal cannot approve"),
                HelpRow(name: "secrets", description: "\"secrets\": {\"VAR\": \"NAME\"} or ${secret:NAME} in args; values scrubbed"),
                HelpRow(
                    name: "sandbox",
                    description: "\"sandbox\" cages the server (macOS); \"hosts\" allows those names on port 443 through a proxy"
                ),
                HelpRow(
                    name: "profile",
                    description: "\"strict\": unlisted tools deny, local servers need a sandbox, network only via sandbox.hosts"
                ),
                HelpRow(name: "toolMode", description: "\"search\" lists only rv_search_tools and rv_call_tool; same policy per call"),
                HelpRow(name: "remote", description: "\"url\": https://… (\"transport\": http|sse, \"headers\" with ${secret:NAME}); no sandbox"),
                HelpRow(name: "oauth", description: "`rv mcp connect <server>` signs in once; rv stores, sends and refreshes the token"),
            ]),
            HelpSection(heading: "Statuses", rows: [
                HelpRow(name: "governed", description: "Host runs it through `rv mcp serve`"),
                HelpRow(name: "direct", description: "Allowed outside rv by mcp.json \"direct\""),
                HelpRow(name: "bypass", description: "rv has a definition; the host runs it directly"),
                HelpRow(name: "unreviewed", description: "rv has never reviewed it"),
                HelpRow(name: "blocked", description: "Listed in mcp.json \"blocked\""),
                HelpRow(name: "dangling", description: "Routed through rv, but mcp.json has no such server"),
            ]),
            HelpSection(heading: "Notes", rows: [
                HelpRow(name: "config", description: "~/.config/rv/mcp.json (owner-only)"),
                HelpRow(name: "integrity", description: "An outside edit does not launch until `rv mcp trust` (needs you present)"),
                HelpRow(name: "import", description: "Copying a host command into mcp.json needs you present"),
                HelpRow(name: "limits", description: "A process running as you can still edit or delete ~/.config/rv; rv flags it"),
                HelpRow(
                    name: "hosts",
                    description: "Claude Code, Claude Desktop, Cursor, Codex, OpenCode, Gemini, Antigravity, VS Code, Windsurf"
                ),
                HelpRow(name: "redaction", description: "Env and header values never shown; credential-like args masked"),
                HelpRow(name: "audit", description: "rv audit tail --kind mcp.call shows every tool call"),
            ]),
        ],
        examples: [
            "rv mcp list",
            "rv mcp onboard --host cursor --dry-run",
            "rv mcp onboard --host cursor",
            "rv mcp check",
        ]
    )

    static let managed = HelpViewModel(
        title: "",
        blurb: "",
        sections: [
            HelpSection(heading: "Usage", rows: [
                HelpRow(name: "rv managed [status] [--json]"),
                HelpRow(name: "rv managed verify <dir> [--json]"),
                HelpRow(name: "rv managed keygen --out <dir>"),
                HelpRow(name: "rv managed sign <policy.json> --key <org-key.private> [--out <file>]"),
            ]),
            HelpSection(heading: "Notes", rows: [
                HelpRow(name: "location", description: "\(ManagedPolicyLocation.installedDirectory) (root-owned)"),
                HelpRow(name: "files", description: "policy.json; org-key.pub pins a key, then policy.json.sig is required"),
                HelpRow(name: "rotation", description: "org-key.pub may list several keys, one per line (# comments); any one verifies"),
                HelpRow(name: "serial", description: "A serial lower than one already accepted is a rollback and makes the policy invalid"),
                HelpRow(name: "restrict-only", description: "Org rules only tighten mcp.json and secrets.json; deny > ask > allow"),
                HelpRow(name: "invalid", description: "A bad owner, mode, signature, or key disables MCP and secret staging"),
            ]),
        ],
        examples: [
            "rv managed keygen --out ./org-keys",
            "rv managed sign ./bundle/policy.json --key ./org-keys/org-key.private",
            "rv managed verify ./bundle",
            "rv managed status",
        ]
    )

    static let report = HelpViewModel(
        title: "",
        blurb: "",
        sections: [
            HelpSection(heading: "Usage", rows: [
                HelpRow(name: "rv report [--json] [--strict]"),
            ]),
            HelpSection(heading: "Notes", rows: [
                HelpRow(name: "schema", description: "rv.report.v1: version, org policy, config hashes, MCP, secrets, audit"),
                HelpRow(name: "secrets", description: "Names, source kinds, and delivery only; values are never read"),
                HelpRow(name: "--strict", description: "Exit 1 when the machine is not compliant"),
            ]),
        ],
        examples: [
            "rv report",
            "rv report --json",
        ]
    )


    static let egress = HelpViewModel(
        title: "",
        blurb: "",
        sections: [
            HelpSection(heading: "Usage", rows: [
                HelpRow(name: "rv egress pending [--json] [--robot] [--plain] [--no-color]"),
                HelpRow(name: "rv egress show <id> [--json] [--robot] [--plain] [--no-color]"),
                HelpRow(name: "rv egress approve <id>"),
                HelpRow(name: "rv egress deny <id> --reason <text>"),
                HelpRow(name: "rv egress denials [--limit N] [--json] [--robot] [--plain] [--no-color]"),
            ]),
            HelpSection(heading: "Notes", rows: [
                HelpRow(
                    name: "review",
                    description: "Blocked CONNECTs become scoped host:port proposals; approval loads the rule live"
                ),
                HelpRow(
                    name: "mutations",
                    description: "approve and deny refuse until authenticated service routes land"
                ),
            ]),
        ],
        examples: [
            "rv egress pending",
            "rv egress show <id>",
            "rv egress denials --limit 20",
        ]
    )

    static let operatorHelp = HelpViewModel(
        title: "",
        blurb: "",
        sections: [
            HelpSection(heading: "Usage", rows: [
                HelpRow(name: "rv operator propose --workspace <path> --kind named --definition <id>"),
                HelpRow(name: "rv operator propose --workspace <path> --kind custom --executable <path> --digest <hex>"),
                HelpRow(name: "rv operator proposal-status <operation-id>"),
            ]),
            HelpSection(heading: "Notes", rows: [
                HelpRow(
                    name: "review",
                    description: "Proposals are untrusted hints. Nothing launches until the host prepares a description and the device owner authorizes it in RVOperatorUI"
                ),
            ]),
        ],
        examples: [
            "rv operator propose --workspace /tmp/p --kind named --definition test-agent",
        ]
    )

    static let allowOnce = HelpViewModel(
        title: "",
        blurb: "",
        sections: [
            HelpSection(heading: "Usage", rows: [
                HelpRow(name: "rv allow-once <code>"),
                HelpRow(name: "rv allow-once mint -- <command>"),
                HelpRow(name: "rv allow-once list"),
                HelpRow(name: "rv allow-once clear"),
            ]),
            HelpSection(heading: "Notes", rows: [
                HelpRow(
                    name: "redeem",
                    description: "Paste the six-character code from a hook deny on a TTY"
                ),
                HelpRow(
                    name: "mint",
                    description: "Optional pre-arm; daily unlock is the code already on the deny"
                ),
            ]),
        ],
        examples: [
            "rv allow-once a1b2c3",
            "rv allow-once mint -- git reset --hard",
        ]
    )

    static let packs = HelpViewModel(
        title: "",
        blurb: "",
        sections: [
            HelpSection(heading: "Usage", rows: [
                HelpRow(name: "rv packs [--enabled] [--verbose] [--json]"),
                HelpRow(name: "rv packs enable <pack>"),
                HelpRow(name: "rv packs disable <pack>"),
                HelpRow(name: "rv packs info <pack>"),
            ]),
        ],
        examples: [
            "rv packs",
            "rv packs enable core.git",
        ]
    )

    static let scan = HelpViewModel(
        title: "",
        blurb: "",
        sections: [
            HelpSection(heading: "Usage", rows: [
                HelpRow(name: "rv scan [sessions] [path] [--host <host>] [--days N] [--all]"),
            ]),
            HelpSection(heading: "Notes", rows: [
                HelpRow(
                    name: "sessions",
                    description: "Offline host session stores; deny-only findings. Not a repo scanner."
                ),
            ]),
        ],
        examples: [
            "rv scan",
            "rv scan sessions ~/.pi",
        ]
    )

    static let policy = HelpViewModel(
        title: "",
        blurb: "",
        sections: [
            HelpSection(heading: "Usage", rows: [
                HelpRow(name: "rv policy show [--base] [--effective]"),
                HelpRow(name: "rv policy list [--repo]"),
                HelpRow(name: "rv policy draft --english <text> [--save]"),
                HelpRow(name: "rv policy validate"),
                HelpRow(name: "rv policy export"),
                HelpRow(name: "rv policy apply"),
            ]),
            HelpSection(heading: "Notes", rows: [
                HelpRow(
                    name: "draft",
                    description: "Typed gitPush preview. Apple Intelligence when available; otherwise a canned gitPush fixture."
                ),
            ]),
        ],
        examples: [
            "rv policy show",
            "rv policy draft --english 'never allow force-push to main'",
        ]
    )

    static let allowlist = HelpViewModel(
        title: "",
        blurb: "",
        sections: [
            HelpSection(heading: "Usage", rows: [
                HelpRow(name: "rv allowlist list"),
                HelpRow(name: "rv allowlist add <rule>"),
                HelpRow(name: "rv allowlist add-command <command>"),
                HelpRow(name: "rv allowlist remove <rule>"),
                HelpRow(name: "rv allowlist validate"),
            ]),
        ],
        examples: [
            "rv allowlist list",
        ]
    )
}
