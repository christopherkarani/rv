import RVDomain
import RVTheme

/// The draft preview as the artifact shows it: the verdict as glyph and
/// verb, the command in bold, the branch after a dim arrow, then the rule
/// id dim on its own line. `✕ never git push --force → main`.
/// The predicate fields stay in `--json`; text shows what the rule does.
enum PolicyDraftPreview {
    private typealias Glyph = CommandVocabulary.Glyph

    /// Typed rules only add stops; an allow cannot loosen rv or a pack.
    static let restrictOnlyNote = "allow only narrows: it never lets through what rv or a pack stops"

    static func lines(_ preview: TypedRulePreview, palette: Palette) -> [String] {
        let rule = preview.rule
        let (glyph, verb, ink): (String, String, String)
        switch rule.verdict {
        case .deny: (glyph, verb, ink) = (Glyph.stopped.rawValue, "never", palette.deny)
        case .ask: (glyph, verb, ink) = (Glyph.watched.rawValue, CommandVocabulary.Verdict.ask, palette.mark)
        case .allow: (glyph, verb, ink) = (Glyph.done.rawValue, CommandVocabulary.Verdict.allow, palette.allow)
        }
        let (command, target, detail) = words(rule.predicate)
        var line = "  \(paint(glyph, ink, palette)) \(verb) \(paint(command, palette.fact, palette))"
        if let target {
            line += " \(paint(Glyph.next.rawValue, palette.muted, palette)) \(paint(DisplayedText.field(target), palette.fact, palette))"
        }
        for note in [detail, readAs(preview.sentence)].compactMap({ $0 }) {
            line += " " + paint("· \(note)", palette.muted, palette)
        }
        var lines = [line, "  " + paint(DisplayedText.field(rule.id.rawValue), palette.muted, palette)]
        if rule.verdict == .allow {
            lines.append("  " + paint(restrictOnlyNote, palette.muted, palette))
        }
        return lines
    }

    /// The command, what it is aimed at, and anything the two leave out.
    private static func words(_ predicate: PolicyPredicate) -> (String, target: String?, detail: String?) {
        switch predicate {
        case .gitPush(let force, let branch):
            let target = branch ?? "any branch"
            switch force {
            case .exactly(.force): return ("git push --force", target, nil)
            case .exactly(.forceWithLease): return ("git push --force-with-lease", target, nil)
            case .exactly(.none): return ("git push", target, "not forced")
            case .any: return ("git push", target, nil)
            }
        case .gitReset(let mode):
            return (mode.map { "git reset --\($0.rawValue)" } ?? "git reset", nil, nil)
        case .gitClean(let force, let directories):
            var letters = ""
            if force == true { letters += "f" }
            if directories == true { letters += "d" }
            return (letters.isEmpty ? "git clean" : "git clean -\(letters)", nil, nil)
        case .gitDiscardWorktree(let pathspec):
            return ("discard uncommitted changes", pathspec, nil)
        case .filesystemDelete(let recursive, let force):
            var letters = ""
            if recursive == true { letters += "r" }
            if force == true { letters += "f" }
            return (letters.isEmpty ? "rm" : "rm -\(letters)", nil, nil)
        case .filesystemMove:
            return ("mv", nil, nil)
        }
    }

    /// "origin/main read as branch main", when the draft said so.
    private static func readAs(_ sentence: String) -> String? {
        guard sentence.contains(" read as branch "), sentence.hasSuffix(")"),
            let open = sentence.range(of: "(", options: .backwards)
        else { return nil }
        return String(sentence[open.upperBound..<sentence.index(before: sentence.endIndex)])
    }

    static let example = "try: rv policy draft \"never force-push to main\""

    /// A refusal in the same language: what is wrong after a red ✕, then
    /// the fix as the last line. A reason is "problem; fix"; one with no
    /// fix ends with an example sentence, so every no has a next.
    static func refusalLines(_ refusal: EnglishCompileRefusal, reason: String, palette: Palette) -> [String] {
        let parts = reason.components(separatedBy: "; ")
        let problem = parts[0]
        let fix = parts.count > 1 ? parts.dropFirst().joined(separator: "; ") : example
        // A problem that already says no reads on its own; "can't read
        // that" is added only to one that does not.
        let lower = " " + problem.lowercased() + " "
        let saysNo = ["can't", "cannot", "not", "nothing", "doesn't", "isn't", "won't"]
            .contains { lower.contains(" \($0) ") || lower.contains(" \($0),") }
        let headline = saysNo ? problem : "\(lead(refusal)): \(problem)"
        return [
            "  \(paint(Glyph.stopped.rawValue, palette.deny, palette)) \(headline)",
            "  \(paint(Glyph.next.rawValue, palette.trace, palette)) \(fix)",
        ]
    }

    private static func lead(_ refusal: EnglishCompileRefusal) -> String {
        switch refusal {
        case .empty, .uncompilable: return "can't read that"
        case .unsupported, .unsupportedPredicate, .alreadyBuiltIn: return "can't make that a rule"
        case .hardStop: return "can't change that"
        }
    }

    private static func paint(_ text: String, _ ink: String, _ palette: Palette) -> String {
        palette.colorsEnabled && ink.isEmpty == false ? ink + text + palette.reset : text
    }
}
