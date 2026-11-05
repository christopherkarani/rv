import Foundation
import RVDomain
import Testing
@testable import RVCLI

@Suite("robot JSON escapes every scalar DisplayedText flags")
struct RobotJSONEscapeTests {
    /// The one hostile-scalar test at the robot-JSON seam: every
    /// surface encodes through `RobotJSON`, so the escaping contract
    /// is pinned here once instead of per command.
    enum Preset: String, CaseIterable, Sendable {
        case compact, compactISO8601, pretty, auditVerify

        var options: RobotJSON.Options {
            switch self {
            case .compact: .compact
            case .compactISO8601: .compactISO8601
            case .pretty: .pretty
            case .auditVerify: .auditVerify
            }
        }

        func render(_ value: [String: String]) throws -> String {
            try RobotJSON.encode(value, options: options)
        }
    }

    /// Bidi embedding/isolate, NEL, RLM, a tag character, ESC, and
    /// LS/RLO each followed by a combining mark (one grapheme
    /// cluster, not a lone scalar).
    static let hostile = "a\u{202A}b\u{2066}c\u{0085}d\u{200F}e\u{E0041}f\u{001B}g\u{2028}\u{0301}h\u{202E}\u{0301}i"

    @Test(arguments: Preset.allCases)
    func noFlaggedScalarStaysRaw(_ preset: Preset) throws {
        let robot = try preset.render(["v": Self.hostile])
        let raw = robot.unicodeScalars.filter { $0.value >= 0x80 && DisplayedText.needsEscape($0) }
        #expect(raw.isEmpty, "raw scalars: \(raw.map { String(format: "U+%04X", $0.value) })")
        #expect(robot.unicodeScalars.contains { $0.value == 0x1B } == false)
        // Byte match: `String.contains` is grapheme-aware, and the combining
        // mark kept after the `\u2028` escape fuses with its final `8`.
        let bytes = Data(robot.utf8)
        for escape in ["\\u202a", "\\u2066", "\\u0085", "\\u200f", "\\udb40\\udc41", "\\u001b", "\\u2028", "\\u202e"] {
            #expect(bytes.range(of: Data(escape.utf8)) != nil, "missing \(escape)")
        }
    }

    @Test(arguments: Preset.allCases)
    func outputRoundTripsToTheInput(_ preset: Preset) throws {
        let robot = try preset.render(["v": Self.hostile])
        let object = try JSONSerialization.jsonObject(with: Data(robot.utf8))
        let decoded = try #require((object as? [String: Any])?["v"] as? String)
        #expect(Array(decoded.unicodeScalars) == Array(Self.hostile.unicodeScalars))
    }

    @Test func prettyStandaloneSeparatorsAndOverrideAreByteIdenticalToBefore() throws {
        let robot = try RobotJSON.encode(["v": "x\u{2028}y\u{2029}z\u{202E}w"], options: .pretty)
        #expect(robot == "{\n  \"v\" : \"x\\u2028y\\u2029z\\u202ew\"\n}\n")
    }

    @Test func compactKeepsSlashesRawAndOmitsTrailingNewline() throws {
        // Blocks' REQ-T7 divergence rides this preset: no `\/` spelling.
        let robot = try RobotJSON.encode(["path": "/tmp/rv/.env"], options: .compactISO8601)
        #expect(robot == "{\"path\":\"/tmp/rv/.env\"}")
    }

    @Test func compactISO8601SpellsDatesAsISO8601() throws {
        struct Row: Encodable { var at: Date }
        let robot = try RobotJSON.encode(
            Row(at: Date(timeIntervalSince1970: 0)), options: .compactISO8601)
        #expect(robot == "{\"at\":\"1970-01-01T00:00:00Z\"}")
    }

    @Test func encodeLinesTerminatesEveryLine() throws {
        let lines = try RobotJSON.encodeLines([["a": "1"], ["b": "2"]], options: .compact)
        #expect(lines == "{\"a\":\"1\"}\n{\"b\":\"2\"}\n")
    }

    @Test func auditVerifyKeepsEscapedSlashesAndEscapesScalars() throws {
        // The `\/` spelling is audit-verify's preserved layout byte;
        // scalar escaping is the seam's invariant on every surface.
        let robot = try RobotJSON.encode(
            ["head": "a/b\u{2028}"], options: .auditVerify)
        #expect(robot.contains("a\\/b"))
        #expect(robot.unicodeScalars.contains { $0.value == 0x2028 } == false)
        #expect(robot.contains("\\u2028"))
        #expect(robot.hasSuffix("\n"))
    }

    @Test func encodeFailureThrowsInsteadOfSwallowing() {
        struct Row: Encodable { var value: Double }
        #expect(throws: RobotRenderError.self) {
            try RobotJSON.encode(Row(value: .nan), options: .pretty)
        }
    }
}
