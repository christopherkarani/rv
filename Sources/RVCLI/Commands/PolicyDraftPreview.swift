import RVDomain
import RVTheme

/// The draft preview as the artifact shows it: the verdict as glyph and
/// verb, the command in bold, the branch after a dim arrow, then the rule
/// id dim on its own line. `✕ never git push --force → main`.
/// The predicate fields stay in `--json`; text shows what the rule does.
enum PolicyDraftPreview {
    /// Typed rules only add stops; an allow cannot loosen rv or a pack.
    static let restrictOnlyNote = "allow only narrows: it never lets through what rv or a pack stops"

    static func lines(_ preview: TypedRulePreview, palette: Palette) -> [String] {
        let rule = preview.rule
        let (glyph, verb, ink): (String, String, String)
        switch rule.verdict {
        case .deny: (glyph, verb, ink) = ("✕", "never", palette.deny)
        case .ask: (glyph, verb, ink) = ("◐", "ask", palette.mark)
        case .allow: (glyph, verb, ink) = ("✓", "allow", palette.allow)
        }
        let (command, target, detail) = words(rule.predicate)
        var line = "  \(paint(glyph, ink, palette)) \(verb) \(paint(command, palette.fact, palette))"
        if let target {
            line += " \(paint("→", palette.muted, palette)) \(paint(DisplayedText.field(target), palette.fact, palette))"
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

    private static func paint(_ text: String, _ ink: String, _ palette: Palette) -> String {
        palette.colorsEnabled && ink.isEmpty == false ? ink + text + palette.reset : text
    }
}
