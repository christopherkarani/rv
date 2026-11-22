import RVPresentation

extension HelpCatalog {
    /// `rv log --help`.
    static let log = HelpViewModel(
        title: "",
        blurb: "",
        sections: [
            HelpSection(heading: "Usage", rows: [
                HelpRow(name: "rv log [--all] [--rule <text>] [--host <host>] [--json] [--robot] [--plain] [--no-color]"),
            ]),
            HelpSection(heading: "Flags", rows: [
                HelpRow(name: "--all", description: "Every row, judge notes too (default: the newest 20)"),
                HelpRow(name: "--rule", description: "Only rules whose id contains this text"),
                HelpRow(name: "--host", description: "Only this agent"),
                HelpRow(name: "--json", description: "The rows shown and the summary counts, as JSON"),
                HelpRow(name: "--robot", description: "Same as --json"),
                HelpRow(name: "--plain", description: "Disable color"),
                HelpRow(name: "--no-color", description: "Disable color"),
            ]),
            HelpSection(heading: "Columns", rows: [
                HelpRow(name: "time", description: "Local time; the day too when it is not today"),
                HelpRow(name: "agent", description: "The host that sent the command"),
                HelpRow(name: "verdict", description: "✕ Stopped: it did not run. ◐ Would stop: watch mode let it run"),
                HelpRow(name: "rule", description: "The rule that matched"),
                HelpRow(name: "command", description: "The file it touched, or the tool: rv keeps no command text"),
                HelpRow(name: "code", description: "Names the row; the same row always has the same code"),
            ]),
            HelpSection(heading: "Notes", rows: [
                HelpRow(name: "judge", description: "The judge's notes in shadow fold into one count; --all or --rule core.judge lists them"),
                HelpRow(name: "ledger", description: "The same rows as rv blocks: the last 7 days, paths with ~ for home"),
            ]),
        ],
        examples: [
            "rv log",
            "rv log --rule core.git",
            "rv log --host claude --all",
            "rv log --json",
        ]
    )
}
