/// Escaping for one fingerprint component. `\`, `,` and `:` are the
/// structural characters of a fingerprint, so a component that contains one
/// is escaped (`\\`, `\,`, `\:`). Every other component is the identity.
public enum FingerprintComponent {
    private static let escapeMarker: Character = "\\"
    private static let structural: Set<Character> = ["\\", ",", ":"]

    public static func escape(_ component: String) -> String {
        guard component.contains(where: { structural.contains($0) }) else { return component }
        var out = ""
        for character in component {
            if structural.contains(character) { out.append(escapeMarker) }
            out.append(character)
        }
        return out
    }

    /// Splits `encoded` on unescaped `separator`, leaving escapes intact.
    public static func split(_ encoded: String, separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var escaped = false
        for character in encoded {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == escapeMarker {
                current.append(character)
                escaped = true
            } else if character == separator {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts
    }

    /// Inverse of `escape`. Nil when `encoded` has a dangling or unknown escape.
    public static func unescape(_ encoded: String) -> String? {
        var out = ""
        var escaped = false
        for character in encoded {
            if escaped {
                guard structural.contains(character) else { return nil }
                out.append(character)
                escaped = false
            } else if character == escapeMarker {
                escaped = true
            } else if structural.contains(character) {
                return nil
            } else {
                out.append(character)
            }
        }
        return escaped ? nil : out
    }
}

/// One `:`-separated slot of a fingerprint.
public enum FingerprintSegment: Sendable, Equatable {
    /// A single component.
    case field(String)
    /// Items joined with `,`.
    case list([String])

    fileprivate var encoded: String {
        switch self {
        case .field(let value):
            return FingerprintComponent.escape(value)
        case .list(let items):
            return items.map(FingerprintComponent.escape).joined(separator: ",")
        }
    }
}

extension ActionFingerprint {
    /// The only producer API. `kind` is a trusted literal prefix and is not
    /// escaped. Segments are escaped, then joined with `:` (list items with `,`).
    public static func make(_ kind: String, _ segments: [FingerprintSegment]) -> ActionFingerprint {
        ActionFingerprint(rawValue: ([kind] + segments.map(\.encoded)).joined(separator: ":"))
    }
}
