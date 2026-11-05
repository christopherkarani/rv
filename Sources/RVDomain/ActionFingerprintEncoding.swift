/// Escaping for one fingerprint component. `\`, `,` and `:` are the
/// structural characters of a fingerprint, so a component that contains one
/// is escaped (`\\`, `\,`, `\:`). Every other component is the identity.
///
/// Works on Unicode scalars, not `Character`s: a structural scalar followed by
/// a combining mark is a single `Character` that is not `":"`, and would
/// otherwise slip through unescaped.
public enum FingerprintComponent {
    private static let escapeMarker: Unicode.Scalar = "\\"
    private static let structural: Set<Unicode.Scalar> = ["\\", ",", ":"]

    public static func escape(_ component: String) -> String {
        guard component.unicodeScalars.contains(where: { structural.contains($0) }) else { return component }
        var out = String.UnicodeScalarView()
        for scalar in component.unicodeScalars {
            if structural.contains(scalar) { out.append(escapeMarker) }
            out.append(scalar)
        }
        return String(out)
    }

    /// Splits `encoded` on unescaped `separator`, leaving escapes intact.
    public static func split(_ encoded: String, separator: Unicode.Scalar) -> [String] {
        var parts: [String] = []
        var current = String.UnicodeScalarView()
        var escaped = false
        for scalar in encoded.unicodeScalars {
            if escaped {
                current.append(scalar)
                escaped = false
            } else if scalar == escapeMarker {
                current.append(scalar)
                escaped = true
            } else if scalar == separator {
                parts.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        parts.append(String(current))
        return parts
    }

    /// Inverse of `escape`. Nil when `encoded` has a dangling or unknown escape.
    public static func unescape(_ encoded: String) -> String? {
        var out = String.UnicodeScalarView()
        var escaped = false
        for scalar in encoded.unicodeScalars {
            if escaped {
                guard structural.contains(scalar) else { return nil }
                out.append(scalar)
                escaped = false
            } else if scalar == escapeMarker {
                escaped = true
            } else if structural.contains(scalar) {
                return nil
            } else {
                out.append(scalar)
            }
        }
        return escaped ? nil : String(out)
    }
}

/// One `:`-separated slot of a fingerprint.
public enum FingerprintSegment: Sendable, Equatable {
    /// A single component.
    case field(String)
    /// Items joined with `,`. An empty list is `\[]`, an escape `escape`
    /// never produces, so it differs from a list of one empty item (`""`).
    /// A one-item list spells like a `.field`, so a kind must use one shape
    /// per slot.
    case list([String])

    private static let emptyListToken = "\\[]"

    fileprivate var encoded: String {
        switch self {
        case .field(let value):
            return FingerprintComponent.escape(value)
        case .list(let items) where items.isEmpty:
            return Self.emptyListToken
        case .list(let items):
            return items.map(FingerprintComponent.escape).joined(separator: ",")
        }
    }
}

extension ActionFingerprint {
    /// The only producer API. Injective over the projected fields only: `nil`
    /// and `""` alias for `remote`/`target`/`source`/`mode`, and
    /// `createBranch.startPoint` and `restore.source` are not encoded. That
    /// fails closed, since no fingerprint grants authority.
    /// `kind` is a trusted literal prefix and is not
    /// escaped. Segments are escaped, then joined with `:` (list items with `,`).
    public static func make(_ kind: String, _ segments: [FingerprintSegment]) -> ActionFingerprint {
        ActionFingerprint(rawValue: ([kind] + segments.map(\.encoded)).joined(separator: ":"))
    }
}
