/// The first name of the person who owns this Mac, as stop text says it:
/// "ask Chris to run  rv allow-once a1b2c3". rv reads it from the account's
/// passwd full name (the gecos field: macOS `RealName`), never from the
/// environment, which an agent controls. Changing the full name takes the
/// account password (`chfn`, System Settings) or root, so an agent cannot
/// put words in it; the parse below also keeps only one plain word.
///
/// `rv_owner_first_name` in `Sources/rv-c/hook_fallback.c` applies the
/// same rule byte for byte (`OwnerNameTests` and `hook_fallback_test.c`
/// share their cases).
public struct OwnerName: Sendable, Equatable {
    /// The validated first name, or nil when the full name gave none rv
    /// will print.
    public let firstName: String?

    /// What stop text says when no first name is known.
    public static let fallback = "your user"

    /// No first name: stop text says "your user".
    public static let unknown = OwnerName(validated: nil)

    /// Longest first name rv prints, in UTF-8 bytes.
    public static let maxBytes = 32

    private init(validated: String?) {
        firstName = validated
    }

    /// The first word of `gecos`'s first comma field, when it is a plain
    /// name: 1 to 32 bytes, starting with an uppercase letter, made of
    /// letters (ASCII or Latin-1 Supplement and Latin Extended-A/B), with
    /// `-` or `'` only between letters. Anything else (a machine account's
    /// lowercase name, digits, punctuation, controls, bidi marks, another
    /// script) is no name, so the text says "your user".
    public init(gecos: String?) {
        self.init(validated: gecos.flatMap(Self.firstName(fromGecos:)))
    }

    /// The name stop text speaks: the first name, or "your user".
    public var spoken: String {
        firstName ?? Self.fallback
    }

    static func firstName(fromGecos gecos: String) -> String? {
        let field = gecos.prefix { $0 != "," }
        let word = field.drop { $0 == " " }.prefix { $0 != " " }
        let name = String(word)
        guard name.utf8.count <= maxBytes, let first = name.unicodeScalars.first, isUpper(first) else {
            return nil
        }
        var previousWasJoiner = false
        for scalar in name.unicodeScalars {
            if scalar == "-" || scalar == "'" {
                if previousWasJoiner { return nil }
                previousWasJoiner = true
                continue
            }
            guard isLetter(scalar) else { return nil }
            previousWasJoiner = false
        }
        return previousWasJoiner ? nil : name
    }

    private static func isUpper(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x41...0x5A: true
        case 0xC0...0xDE: scalar.value != 0xD7
        default: false
        }
    }

    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A: true
        case 0xC0...0x24F: scalar.value != 0xD7 && scalar.value != 0xF7
        default: false
        }
    }
}
