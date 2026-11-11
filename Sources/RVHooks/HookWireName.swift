import Foundation

/// Near-variant matching for host tool and event names.
///
/// Codecs match exact wire spellings (`HostWireVocabulary`), and anything
/// else was foreign, which allows. A payload naming `"bash"`, `"Bash "`
/// or `"preToolUse"` where the host's spelling is `Bash` / `PreToolUse`
/// therefore skipped the guard entirely. No host is known to send such a
/// spelling, but nothing guarantees one never will (or that a host does
/// not match its own names loosely), and guessing wrong fails open.
///
/// So before the strict tables run, a name that differs from one of the
/// host's guarded spellings only by letter case, whitespace, control or
/// format characters, `_` or `-` is read as that spelling. This only ever
/// moves a name from foreign (allowed unchecked) to guarded (evaluated);
/// it never makes a guarded name foreign. Distinct real tools such as
/// Claude's `BashOutput` or `KillShell` keep their own key and stay
/// foreign.
enum HookWireName {
    /// File-tool spellings every file-capable codec shares (`FileToolKind`).
    static let fileTools = ["Read", "read_file", "Edit", "edit_file", "Write", "write_file"]

    /// Comparison key: case-folded, with whitespace, control and format
    /// characters, `_` and `-` removed.
    static func key(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            if scalar == "_" || scalar == "-" { continue }
            switch scalar.properties.generalCategory {
            case .control, .format, .spaceSeparator, .lineSeparator, .paragraphSeparator:
                continue
            default:
                break
            }
            if scalar.properties.isWhitespace { continue }
            scalars.append(scalar)
        }
        return String(scalars).lowercased()
    }

    /// The guarded spelling `raw` is a near-variant of, else `raw` itself.
    /// An exact spelling always wins over a near-variant.
    static func canonical(_ raw: String?, among known: [String]) -> String? {
        guard let raw else { return nil }
        if known.contains(raw) { return raw }
        let rawKey = key(raw)
        guard rawKey.isEmpty == false else { return raw }
        return known.first { key($0) == rawKey } ?? raw
    }

    /// Event gate for hosts whose shell hook carries an event name.
    ///
    /// rv registers these hooks for the pre-tool event only, so an absent
    /// or blank event cannot be a different event: it is read as the
    /// pre-tool event (evaluated) rather than foreign (allowed unchecked).
    /// A near-variant of `preToolEvent` is the pre-tool event too. Any
    /// other spelling names a different event and stays foreign.
    static func isPreToolEvent(_ raw: String?, preToolEvent: String) -> Bool {
        guard let raw, key(raw).isEmpty == false else { return true }
        return canonical(raw, among: [preToolEvent]) == preToolEvent
    }
}
