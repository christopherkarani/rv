import Foundation
import RVDomain
import Testing
@testable import RVCLI

@Suite("robot JSON escapes every scalar DisplayedText flags")
struct RobotJSONEscapeTests {
    enum Writer: String, CaseIterable, Sendable {
        case secrets, mcp, managed

        func render(_ value: [String: String]) -> String {
            switch self {
            case .secrets: SecretsRun.robotJSON(value)
            case .mcp: MCPRun.robotJSON(value)
            case .managed: ManagedRun.robotJSON(value)
            }
        }
    }

    /// Bidi embedding/isolate, NEL, RLM, a tag character, and LS/RLO each
    /// followed by a combining mark (one grapheme cluster, not a lone scalar).
    static let hostile = "a\u{202A}b\u{2066}c\u{0085}d\u{200F}e\u{E0041}f\u{2028}\u{0301}g\u{202E}\u{0301}h"

    @Test(arguments: Writer.allCases)
    func noFlaggedScalarStaysRaw(_ writer: Writer) throws {
        let robot = writer.render(["v": Self.hostile])
        let raw = robot.unicodeScalars.filter { $0.value >= 0x80 && DisplayedText.needsEscape($0) }
        #expect(raw.isEmpty, "raw scalars: \(raw.map { String(format: "U+%04X", $0.value) })")
        // Byte match: `String.contains` is grapheme-aware, and the combining
        // mark kept after the `\u2028` escape fuses with its final `8`.
        let bytes = Data(robot.utf8)
        for escape in ["\\u202a", "\\u2066", "\\u0085", "\\u200f", "\\udb40\\udc41", "\\u2028", "\\u202e"] {
            #expect(bytes.range(of: Data(escape.utf8)) != nil, "missing \(escape)")
        }
    }

    @Test(arguments: Writer.allCases)
    func outputRoundTripsToTheInput(_ writer: Writer) throws {
        let robot = writer.render(["v": Self.hostile])
        let object = try JSONSerialization.jsonObject(with: Data(robot.utf8))
        let decoded = try #require((object as? [String: Any])?["v"] as? String)
        #expect(Array(decoded.unicodeScalars) == Array(Self.hostile.unicodeScalars))
    }

    @Test(arguments: Writer.allCases)
    func standaloneSeparatorsAndOverrideAreByteIdenticalToBefore(_ writer: Writer) {
        let robot = writer.render(["v": "x\u{2028}y\u{2029}z\u{202E}w"])
        #expect(robot == "{\n  \"v\" : \"x\\u2028y\\u2029z\\u202ew\"\n}\n")
    }
}
