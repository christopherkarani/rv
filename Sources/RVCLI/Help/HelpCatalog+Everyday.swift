import RVPresentation

/// Help pages for `rv check`, `rv prompt` and `rv news`.
extension HelpCatalog {
    static let check = HelpViewModel(
        title: "",
        blurb: "",
        sections: [
            HelpSection(heading: "Usage", rows: [
                HelpRow(name: "rv check \"cmd\" \"cmd\" …", description: "What rv would do with each step, in order"),
                HelpRow(name: "rv check < plan.txt", description: "One command per line; blank lines and # comments are skipped"),
                HelpRow(name: "--host claude", description: "Check as that agent's hook would, in its own guard mode"),
                HelpRow(name: "--json", description: "rv.check.v1: each step's outcome, rule and reason"),
            ]),
            HelpSection(heading: "Notes", rows: [
                HelpRow(name: "read-only", description: "Each step is checked like rv explain: nothing is approved, spent or written, and rvd is not asked"),
                HelpRow(name: "approves nothing", description: "A step that needs a person still needs one when the agent runs it"),
                HelpRow(name: "exit", description: "0 when nothing needs a person (watch-mode would-stops still run), 1 otherwise, 64 for bad input"),
                HelpRow(name: "one at a time", description: "Each step is checked on its own, from this folder: a cd in step 1 does not move step 2"),
            ]),
        ],
        examples: ["rv check \"npm test\" \"git push --force origin main\""]
    )

    static let prompt = HelpViewModel(
        title: "",
        blurb: "",
        sections: [
            HelpSection(heading: "Usage", rows: [
                HelpRow(name: "rv prompt", description: "◆ guarding · ◐ 2 watching, 2 would-stops today · ⏺ claude waiting · ✕ claude off · ✕ rv down"),
                HelpRow(name: "rv prompt --shell zsh", description: "Coloured, wrapped in %{ %} for PROMPT (bash: \\[ \\] for PS1)"),
            ]),
            HelpSection(heading: "Notes", rows: [
                HelpRow(name: "read-only", description: "Reads the guard mode, the pending requests and today's denial rows; sends rvd only a hello"),
                HelpRow(name: "fast", description: "Waits at most 30 ms for rvd, then shows ◆? (not known) instead of guessing; always exits 0"),
            ]),
        ],
        examples: [
            "PROMPT='%~ $(rv prompt --shell zsh) %# '",
            "PS1='\\w $(rv prompt --shell bash) \\$ '",
        ]
    )

    static let news = HelpViewModel(
        title: "",
        blurb: "",
        sections: [
            HelpSection(heading: "Usage", rows: [
                HelpRow(name: "rv news", description: "This rv's highlights, and your last 7 days: commands checked, stopped, watched"),
                HelpRow(name: "--json", description: "rv.news.v1"),
            ]),
            HelpSection(heading: "Notes", rows: [
                HelpRow(name: "read-only", description: "Reads the decision log and the audit log on this Mac; never writes them, never asks rvd or the network"),
                HelpRow(name: "commands checked", description: "Needs an rvd that keeps the decision log"),
            ]),
        ]
    )
}
