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
        case .uninstall: uninstall
        case .doctor: doctor
        }
    }

    static let root = HelpViewModel(
        title: "rv",
        blurb: "Block destructive shell commands.",
        sections: [
            HelpSection(
                heading: "Get started",
                rows: [
                    HelpRow(name: "setup", description: "Wire host hooks and start rvd"),
                    HelpRow(name: "test", description: "Try a command before it runs"),
                    HelpRow(name: "doctor", description: "Check service, packs, and hosts"),
                ],
                accentNames: true
            ),
            HelpSection(heading: "Everyday", rows: [
                HelpRow(name: "explain", description: "Why something was allowed or blocked"),
                HelpRow(name: "service", description: "Is rvd running, down, or skewed"),
            ]),
            HelpSection(heading: "Advanced", rows: [
                HelpRow(name: "hook", description: "Host stdin adapter (Pi / Grok / OpenCode)"),
                HelpRow(name: "uninstall", description: "Remove rv-owned hooks, config, and LaunchAgent"),
            ]),
        ],
        examples: [
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
                HelpRow(name: "--plain", description: "Disable browse and color"),
                HelpRow(name: "--no-color", description: "Disable color"),
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
                HelpRow(name: "--plain", description: "Disable browse and color"),
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
                HelpRow(name: "--json", description: "Robot JSON on stdout"),
                HelpRow(name: "--robot", description: "Robot JSON on stdout"),
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
                HelpRow(name: "--host <host>", description: "Host codec: grok (default), pi, opencode"),
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
                HelpRow(name: "--plain", description: "Disable browse and color"),
                HelpRow(name: "--no-color", description: "Disable color"),
            ]),
        ],
        examples: [
            "rv doctor",
            "rv doctor --json",
        ]
    )
}
