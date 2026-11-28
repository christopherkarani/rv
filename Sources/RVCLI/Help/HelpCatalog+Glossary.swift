import RVDomain
import RVPresentation

extension HelpCatalog {
    private typealias Glyph = CommandVocabulary.Glyph

    /// The words rv uses, one line each: the six glyphs, the two host
    /// modes, and the nouns a stop names. `rv why --help` shows them,
    /// and the README's "Words rv uses" table holds the same terms
    /// (`GlossaryTests`).
    static let glossary = HelpSection(heading: "Words", rows: [
        HelpRow(name: "\(Glyph.stopped.rawValue) stopped", description: "rv stopped the command. It did not run"),
        HelpRow(name: "\(Glyph.watched.rawValue) would stop", description: "Watching: rv logged it and let it run"),
        HelpRow(name: "\(Glyph.done.rawValue) ran", description: "It ran. rv had no objection"),
        HelpRow(name: "\(Glyph.ask.rawValue) asks", description: "It waits for a person to say yes"),
        HelpRow(name: "\(Glyph.next.rawValue) next", description: "The one command to type next"),
        HelpRow(name: "\(Glyph.rv.rawValue) rv", description: "rv speaking"),
        HelpRow(name: CommandVocabulary.PlannedWord.guarding, description: "An agent's mode that stops commands (rv guard)"),
        HelpRow(name: CommandVocabulary.PlannedWord.watching, description: "An agent's mode that only logs them (rv watch)"),
        HelpRow(name: "rule", description: "One pattern rv checks a command against"),
        HelpRow(name: "pack", description: "A named set of rules, such as core.git"),
        HelpRow(name: "code", description: "Six characters on a stop; a person runs it once with rv unlock"),
        HelpRow(name: CommandVocabulary.Verdict.incomplete, description: "rv could not finish checking, so it stops the command"),
    ])
}
