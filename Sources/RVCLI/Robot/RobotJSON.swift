import Foundation
import RVDomain

/// The one robot-JSON module: every `--robot` surface encodes through
/// this seam, so scalar escaping, date spelling, pretty-vs-compact
/// layout, and the failure policy each have one place to fix. The
/// interface is one encode entry (plus its JSON-Lines sibling); the
/// depth behind it is the encoder recipe every caller used to copy.
///
/// Failure policy (REQ-T7): an encode failure throws
/// `RobotRenderError` — a command failure, never swallowed `{}`/`[]`
/// placeholder bytes on a zero exit.
enum RobotJSON {
    /// Per-surface layout choices. Presets pin each existing surface's
    /// layout bytes; scalar escaping is not a choice here — the seam
    /// escapes on every surface (spec §9), so no preset can opt out.
    struct Options: Sendable {
        let pretty: Bool
        let iso8601Dates: Bool
        /// `true` keeps `JSONEncoder`'s `\/` slash spelling. Only the
        /// audit-verify surface still spells slashes that way.
        let escapesSlashes: Bool
        let trailingNewline: Bool

        /// Sorted keys, compact, unescaped slashes, encoder-default
        /// dates, no trailing newline (callers add it).
        static let compact = Options(
            pretty: false, iso8601Dates: false, escapesSlashes: false,
            trailingNewline: false)

        /// Compact with ISO-8601 dates (egress, audit, blocks). Blocks
        /// gains unescaped slashes here — the REQ-T7 named divergence.
        static let compactISO8601 = Options(
            pretty: false, iso8601Dates: true, escapesSlashes: false,
            trailingNewline: false)

        /// Pretty-printed with a trailing newline (secrets, managed,
        /// mcp, report). `secrets describe` gains scalar escaping via
        /// this preset — the REQ-T7 named divergence.
        static let pretty = Options(
            pretty: true, iso8601Dates: false, escapesSlashes: false,
            trailingNewline: true)

        /// Audit-verify's layout, preserved: pretty, `\/` slash
        /// spelling, trailing newline. Slashes stay escaped only here
        /// because REQ-T7 names Blocks as the slash divergence; scalar
        /// escaping applies as on every surface, which no reachable
        /// `AuditChainReport` byte can observe (its `head` is SHA-256
        /// hex and its break reasons are internal sentences).
        static let auditVerify = Options(
            pretty: true, iso8601Dates: false, escapesSlashes: true,
            trailingNewline: true)
    }

    /// Encodes one robot document. `JSONEncoder` already writes ESC
    /// as `\u001b` but leaves separators, NEL, bidi controls, and other
    /// format scalars raw; `DisplayedText.escapeJSONScalars` escapes
    /// every one `DisplayedText.needsEscape` flags, so the result is
    /// still valid JSON with no flagged scalar raw. Policy strings
    /// are not fielded first: that would turn ESC into the literal
    /// spelling `\\u001b`.
    static func encode(_ value: some Encodable, options: Options = .compact) throws -> String {
        let text = try encodeRaw(value, options: options)
        return options.trailingNewline ? text + "\n" : text
    }

    /// Encodes values as JSON Lines: one document per line, each line
    /// newline-terminated. A failure throws for the whole export
    /// rather than dropping the unencodable event silently.
    static func encodeLines(_ values: [some Encodable], options: Options = .compactISO8601) throws -> String {
        var text = ""
        for value in values {
            text += try encodeRaw(value, options: options) + "\n"
        }
        return text
    }

    private static func encodeRaw(_ value: some Encodable, options: Options) throws -> String {
        let encoder = JSONEncoder()
        var formatting: JSONEncoder.OutputFormatting = [.sortedKeys]
        if options.pretty { formatting.insert(.prettyPrinted) }
        if options.escapesSlashes == false { formatting.insert(.withoutEscapingSlashes) }
        encoder.outputFormatting = formatting
        if options.iso8601Dates { encoder.dateEncodingStrategy = .iso8601 }
        let data: Data
        do {
            data = try encoder.encode(value)
        } catch {
            throw RobotRenderError.encodingFailed(String(describing: error))
        }
        let text = String(decoding: data, as: UTF8.self)
        return DisplayedText.escapeJSONScalars(text)
    }
}
