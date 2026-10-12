import Foundation

/// Operator-entered display text: the shared legibility rule for human-facing
/// labels (connection identity labels, descriptions, health text) and opaque
/// external ids. Pure values; no IO.
///
/// Category rule: text rejects control characters, invisible format
/// characters, and line/paragraph separators
/// (`generalCategory == .control/.format/.lineSeparator/.paragraphSeparator`).
/// The separators break line-oriented logs and persistence exactly like `\n`
/// does; format characters (zero-width joiners, the BOM, directional marks)
/// render invisibly and smuggle spoof text into labels. Emoji and other
/// symbols pass: only the four categories are disallowed. `MCPConnection`
/// delegates its label validation here rather than duplicating the rule.
public enum OperatorText {
    /// True when any scalar falls in a disallowed category: control, format,
    /// line separator, or paragraph separator.
    public static func containsDisallowedTextScalar(_ value: String) -> Bool {
        value.unicodeScalars.contains {
            let category = $0.properties.generalCategory
            return category == .control || category == .format
                || category == .lineSeparator || category == .paragraphSeparator
        }
    }

    /// Human-facing text: byte-capped, spaces allowed; control, invisible
    /// format, and line/paragraph-separator characters rejected (the separators
    /// break line-oriented logs and persistence exactly like `\n` does).
    /// Errors carry field labels and caps only, never the rejected text.
    public static func requireDisplayText(
        _ value: String, field: MCPConnectionField, maxBytes: Int
    ) throws {
        guard value.utf8.count <= maxBytes else {
            throw MCPConnectionError.tooLong(field: field, maxBytes: maxBytes)
        }
        guard containsDisallowedTextScalar(value) == false else {
            throw MCPConnectionError.invalidCharacters(field: field)
        }
    }
}
