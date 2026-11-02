import Foundation

/// Streaming replace of real values in upstream responses, including the
/// encodings an upstream is likely to echo a credential back in.
///
/// - Raw, percent-encoded (`%2F`/`%2f`, `+` for space, any mix of raw and
///   encoded bytes), and JSON-string-escaped (`\/`, `\"`, `\\`, `\n`, and
///   `\uXXXX` including surrogate pairs) forms become the placeholder. They
///   decode to the value, so the placeholder decodes to the placeholder.
/// - Base64 and base64url forms become `redactionMarker`. A value inside a
///   larger blob shares its edge characters with the neighbouring bytes, and
///   the placeholder's length shifts every later character, so no
///   replacement keeps the blob decoding correctly. The marker is visible
///   instead of silently corrupt. Each of the three byte alignments is
///   matched on the characters the value alone determines, so at most two
///   edge characters (under 12 bits of the value) can remain beside it.
///
/// - Hex forms, contiguous or space-separated and in either case, also become
///   `redactionMarker`. S3 `SignatureDoesNotMatch` bodies print the canonical
///   request, session token included, as space-separated hex bytes.
///
/// Not covered: double encodings (percent inside JSON, base64 of a
/// percent-encoded value), HTML entities, and compressed bodies. The
/// gateway asks upstream for identity encoding and refuses a compressed
/// response rather than forwarding bytes it could not scan.
///
/// A tripwire is a needle that must never reach the agent at all, such as the
/// `SecretAccessKey` field name of a response that mints credentials. Where
/// one matches, the scrubber drops it and everything after it, and `tripped`
/// reads true.
///
/// Only a trailing partial match is held back, so streamed output that
/// cannot be the start of a value flows through immediately.
struct SecretScrubber {
    static let redactionMarker = Array("[rv:redacted]".utf8)
    /// Shorter base64 runs collide with ordinary text too easily.
    static let minimumBase64Run = 8
    static let minimumHexRun = 8

    /// One way a value byte, or a whole scalar for `\uXXXX`, may appear.
    struct Form {
        var bytes: [UInt8]
        /// Hex digits in `%2f` and `é` may be either case.
        var caseless: Bool
        /// Value bytes this form stands for.
        var consumes: Int
    }

    struct Pattern {
        /// Alternatives for each value byte offset.
        var forms: [[Form]]
        var replacement: [UInt8]
        /// A match ends the stream instead of being replaced.
        var trips: Bool
        /// Bytes that can begin this pattern; every other position is skipped.
        var starts: [Bool]

        init(forms: [[Form]], replacement: [UInt8], trips: Bool = false) {
            self.forms = forms
            self.replacement = replacement
            self.trips = trips
            var starts = [Bool](repeating: false, count: 256)
            for form in forms.first ?? [] {
                guard let first = form.bytes.first else { continue }
                starts[Int(first)] = true
                if form.caseless {
                    starts[Int(SecretScrubber.lower(first))] = true
                    starts[Int(SecretScrubber.upper(first))] = true
                }
            }
            self.starts = starts
        }
    }

    enum Match: Equatable {
        case none
        /// The buffer ended while a match was still possible.
        case partial
        case full(end: Int)
    }

    private let patterns: [Pattern]
    /// Bytes that can begin some pattern; everything else is emitted at once.
    private let starts: [Bool]
    private var pending: [UInt8] = []
    /// True once a tripwire matched; nothing more is emitted.
    private(set) var tripped = false

    init(_ pairs: [(needle: [UInt8], replacement: [UInt8])], tripwires: [[UInt8]] = []) {
        var patterns: [(length: Int, pattern: Pattern)] = []
        var seen: Set<[UInt8]> = []
        for pair in pairs where pair.needle.isEmpty == false {
            if seen.insert(pair.needle).inserted {
                patterns.append((pair.needle.count, Pattern(forms: Self.forms(pair.needle), replacement: pair.replacement)))
            }
            for encoded in Self.base64Needles(pair.needle) + Self.hexNeedles(pair.needle) where seen.insert(encoded).inserted {
                patterns.append((encoded.count, Pattern(forms: Self.forms(encoded), replacement: Self.redactionMarker)))
            }
        }
        for needle in tripwires where needle.isEmpty == false {
            patterns.append((needle.count, Pattern(forms: Self.forms(needle), replacement: [], trips: true)))
        }
        // Longest first: a longer encoding still in flight holds back a shorter one.
        let sorted = patterns.sorted { $0.length > $1.length }.map(\.pattern)
        self.patterns = sorted
        starts = (0..<256).map { byte in sorted.contains { $0.starts[byte] } }
    }

    mutating func process(_ chunk: [UInt8]) -> [UInt8] {
        guard tripped == false else { return [] }
        pending += chunk
        return drain(final: false)
    }

    mutating func finish() -> [UInt8] {
        drain(final: true)
    }

    static func scrub(_ text: String, _ pairs: [(needle: [UInt8], replacement: [UInt8])]) -> String {
        var scrubber = SecretScrubber(pairs)
        let bytes = scrubber.process(Array(text.utf8)) + scrubber.finish()
        return String(decoding: bytes, as: UTF8.self)
    }

    private mutating func drain(final: Bool) -> [UInt8] {
        guard tripped == false else { return [] }
        var output: [UInt8] = []
        output.reserveCapacity(pending.count)
        var index = 0
        scan: while index < pending.count {
            let byte = Int(pending[index])
            if starts[byte] {
                for pattern in patterns where pattern.starts[byte] {
                    switch Self.match(pattern.forms, in: pending, at: index) {
                    case .none:
                        continue
                    case .full(let end):
                        if pattern.trips {
                            tripped = true
                            pending = []
                            return output
                        }
                        output += pattern.replacement
                        index = end
                        continue scan
                    case .partial:
                        if final { continue }
                        break scan
                    }
                }
            }
            output.append(pending[index])
            index += 1
        }
        pending.removeFirst(index)
        return output
    }

    /// Depth-first over (buffer offset, value offset). Forms of different
    /// lengths can both fit, e.g. a literal `%` and `%25`, so visited states
    /// are recorded to keep the search linear in the match length.
    static func match(_ forms: [[Form]], in buffer: [UInt8], at start: Int) -> Match {
        // Most positions fail on the first byte; skip the search state for them.
        guard let first = forms.first, first.contains(where: { compare($0, buffer, at: start) != .none }) else {
            return forms.isEmpty ? .full(end: start) : .none
        }
        var stack = [(position: start, consumed: 0)]
        var visited: Set<Int> = []
        var partial = false
        while let (position, consumed) = stack.popLast() {
            if consumed == forms.count { return .full(end: position) }
            if position == buffer.count {
                partial = true
                continue
            }
            for form in forms[consumed] {
                switch compare(form, buffer, at: position) {
                case .none:
                    break
                case .partial:
                    partial = true
                case .full(let end):
                    let next = (end, consumed + form.consumes)
                    if visited.insert((end - start) * (forms.count + 1) + next.1).inserted { stack.append(next) }
                }
            }
        }
        return partial ? .partial : .none
    }

    private static func compare(_ form: Form, _ buffer: [UInt8], at position: Int) -> Match {
        for (offset, expected) in form.bytes.enumerated() {
            guard position + offset < buffer.count else { return .partial }
            let actual = buffer[position + offset]
            guard actual == expected || (form.caseless && lower(actual) == lower(expected)) else { return .none }
        }
        return .full(end: position + form.bytes.count)
    }

    /// Raw, `%XX`, `+` for space, JSON short escapes, and `\uXXXX` for each
    /// scalar start. A value that is not UTF-8 gets `\u` forms only up to the
    /// first invalid byte.
    static func forms(_ value: [UInt8]) -> [[Form]] {
        let scalars = scalarStarts(value)
        return value.indices.map { index in
            let byte = value[index]
            var forms = [
                Form(bytes: [byte], caseless: false, consumes: 1),
                Form(bytes: [37] + hex(byte, digits: 2), caseless: true, consumes: 1),
            ]
            if byte == 32 { forms.append(Form(bytes: [43], caseless: false, consumes: 1)) }
            if let short = jsonShortEscape(byte) { forms.append(Form(bytes: [92, short], caseless: false, consumes: 1)) }
            if let scalar = scalars[index] {
                forms.append(Form(bytes: jsonUnicodeEscape(scalar), caseless: true, consumes: UTF8.width(scalar)))
            }
            return forms
        }
    }

    /// Base64 and base64url runs that only the value's bits determine, at
    /// each of the three alignments, plus the whole value's own encoding
    /// with and without padding so its tail goes too.
    static func base64Needles(_ value: [UInt8]) -> [[UInt8]] {
        var needles: [[UInt8]] = []
        let whole = Array(Data(value).base64EncodedString().utf8)
        needles.append(whole)
        for offset in 0..<3 {
            let encoded = Array(Data(Array(repeating: 0, count: offset) + value).base64EncodedString().utf8)
            let first = (8 * offset + 5) / 6
            let end = 8 * (offset + value.count) / 6
            guard end - first >= minimumBase64Run else { continue }
            needles.append(Array(encoded[first..<end]))
        }
        var all: [[UInt8]] = []
        for needle in needles {
            let url = needle.map { $0 == 43 ? 45 : $0 == 47 ? 95 : $0 }
            all += [needle, url]
        }
        if whole.last == 61 {
            let bare = Array(whole.prefix { $0 != 61 })
            all += [bare, bare.map { $0 == 43 ? 45 : $0 == 47 ? 95 : $0 }]
        }
        return all.filter { $0.count >= minimumBase64Run }
    }

    /// The value's bytes as hex digits, with and without a space between
    /// bytes, in lower and upper case.
    static func hexNeedles(_ value: [UInt8]) -> [[UInt8]] {
        var all: [[UInt8]] = []
        for separator in [[UInt8](), [32]] {
            for uppercase in [false, true] {
                let digits = value.map { byte in
                    let text = String(byte, radix: 16, uppercase: uppercase)
                    return Array((text.count < 2 ? "0" + text : text).utf8)
                }
                all.append(Array(digits.joined(separator: separator)))
            }
        }
        return all.filter { $0.count >= minimumHexRun }
    }

    private static func scalarStarts(_ value: [UInt8]) -> [Int: Unicode.Scalar] {
        var starts: [Int: Unicode.Scalar] = [:]
        var iterator = value.makeIterator()
        var decoder = UTF8()
        var position = 0
        while case .scalarValue(let scalar) = decoder.decode(&iterator) {
            starts[position] = scalar
            position += UTF8.width(scalar)
        }
        return starts
    }

    private static func jsonShortEscape(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 34, 92, 47: byte
        case 8: UInt8(ascii: "b")
        case 12: UInt8(ascii: "f")
        case 10: UInt8(ascii: "n")
        case 13: UInt8(ascii: "r")
        case 9: UInt8(ascii: "t")
        default: nil
        }
    }

    private static func jsonUnicodeEscape(_ scalar: Unicode.Scalar) -> [UInt8] {
        String(Character(scalar)).utf16.flatMap { Array(#"\u"#.utf8) + hex($0, digits: 4) }
    }

    private static func hex(_ value: some BinaryInteger, digits: Int) -> [UInt8] {
        let text = String(value, radix: 16, uppercase: true)
        return Array((String(repeating: "0", count: max(0, digits - text.count)) + text).utf8)
    }

    fileprivate static func lower(_ byte: UInt8) -> UInt8 {
        byte >= 65 && byte <= 90 ? byte + 32 : byte
    }

    fileprivate static func upper(_ byte: UInt8) -> UInt8 {
        byte >= 97 && byte <= 122 ? byte - 32 : byte
    }
}
