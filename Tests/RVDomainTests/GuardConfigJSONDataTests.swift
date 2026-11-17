import Foundation
import Testing
import RVDomain

/// `JSONDuplicateKeys` and `GuardConfig(jsonData:)`: a document that
/// repeats a key anywhere reads as `.empty`, whichever parser would have
/// read it.
@Suite("Guard config from bytes")
struct GuardConfigJSONDataTests {
    /// A JSON backslash, kept out of source literals so escapes are explicit.
    private static let backslash = String(UnicodeScalar(UInt8(92)))

    private static func distinct(_ json: String) -> Bool {
        JSONDuplicateKeys.allObjectKeysDistinct(Data(json.utf8))
    }

    struct ScanCase: Sendable, CustomTestStringConvertible {
        let name: String
        let json: String
        let distinct: Bool
        var testDescription: String { name }
    }

    static let scanCases: [ScanCase] = {
        let bs = backslash
        return [
            ScanCase(name: "no duplicates", json: #"{"guard": {"mode": "observe", "hosts": {"claude": "off"}}, "judge.engine": "ft"}"#, distinct: true),
            ScanCase(name: "same key in sibling objects", json: #"{"a": {"k": 1}, "b": {"k": 2}, "k": 3}"#, distinct: true),
            ScanCase(name: "same key in array elements", json: #"{"x": [{"k": 1}, {"k": 2}]}"#, distinct: true),
            ScanCase(name: "strings holding structure", json: #"{"a": "{\"a\": 1, ", "b": ":,[]}", "c": "\""}"#, distinct: true),
            ScanCase(name: "top-level duplicate", json: #"{"guard": {"mode": "observe"}, "guard": {"mode": "enforce"}}"#, distinct: false),
            ScanCase(name: "nested duplicate", json: #"{"guard": {"mode": "enforce", "mode": "observe"}}"#, distinct: false),
            ScanCase(name: "duplicate inside an array", json: #"{"x": [{"k": 1, "k": 2}]}"#, distinct: false),
            ScanCase(name: "duplicate in an unrelated object", json: #"{"guard.mode": "observe", "analytics": {"enabled": true, "enabled": false}}"#, distinct: false),
            ScanCase(name: "escaped-equal keys", json: #"{"guard": 1, "gu"# + bs + #"u0061rd": 2}"#, distinct: false),
            ScanCase(name: "escaped quote keeps a key distinct", json: #"{"a"# + bs + #""": 1, "a": 2}"#, distinct: true),
            ScanCase(name: "key matching a value is fine", json: #"{"mode": "mode"}"#, distinct: true),
            ScanCase(name: "UTF-8 BOM", json: "\u{FEFF}" + #"{"a": 1}"#, distinct: true),
            ScanCase(name: "scalars", json: #"{"a": [true, false, null, -1.5e3, 0]}"#, distinct: true),
            ScanCase(name: "unbalanced", json: #"{"a": [1}"#, distinct: false),
            ScanCase(name: "unterminated string", json: #"{"a": "b}"#, distinct: false),
            ScanCase(name: "NUL outside strings", json: "{\"a\": 1}\u{0}", distinct: false),
        ]
    }()

    @Test("duplicate-key scan", arguments: scanCases)
    func scan(_ testCase: ScanCase) {
        #expect(Self.distinct(testCase.json) == testCase.distinct)
    }

    /// Regression: each key insert used to copy the whole key set (40,000
    /// keys took ~33 s in release). Linear now, so this runs in well under
    /// a second even in debug.
    @Test("many keys in one object scan in linear time")
    func manyKeys() {
        let count = 50_000
        let members = (0..<count).map { #""k\#($0)": \#($0)"# }.joined(separator: ",")
        #expect(Self.distinct("{" + members + "}"))
        #expect(!Self.distinct("{" + members + #","k0": 0}"#))
    }

    @Test("UTF-16 and UTF-32 text fails closed")
    func wideEncodings() throws {
        let json = #"{"guard.mode": "observe"}"#
        for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian, .utf32LittleEndian, .utf32BigEndian] {
            let data = try #require(json.data(using: encoding))
            #expect(!JSONDuplicateKeys.allObjectKeysDistinct(data))
            #expect(GuardConfig(jsonData: data) == .empty)
        }
    }

    @Test("a duplicate anywhere reads as empty", arguments: [
        #"{"guard": {"mode": "observe"}, "guard": {"mode": "enforce"}}"#,
        #"{"guard": {"mode": "enforce"}, "guard": {"mode": "observe"}}"#,
        #"{"guard.mode": "enforce", "guard.mode": "observe"}"#,
        #"{"guard": {"hosts": {"claude": "observe", "claude": "block"}}}"#,
        #"{"guard.mode": "observe", "analytics": {"enabled": true, "enabled": false}}"#,
        #"{"judge": {"engine": "ft", "engine": "laya"}, "guard.mode": "observe"}"#,
    ])
    func duplicatesAreEmpty(_ json: String) {
        #expect(GuardConfig(jsonData: Data(json.utf8)) == .empty)
    }

    @Test("distinct keys decode as GuardConfig(JSONValue) does")
    func distinctDecodes() throws {
        let json = #"{"guard": {"mode": "Observe", "hosts": {"claude": "block"}}, "judge.engine": "laya"}"#
        let fromBytes = GuardConfig(jsonData: Data(json.utf8))
        #expect(fromBytes == GuardConfig(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))))
        #expect(fromBytes == GuardConfig(mode: .observe, hosts: [.claude: .block], judgeEngine: .laya))
    }

    @Test("unparseable or non-object bytes read as empty", arguments: [
        "", "observe", #"{"guard.mode": "observe""#, #"["observe"]"#, #""observe""#,
    ])
    func unparseable(_ json: String) {
        #expect(GuardConfig(jsonData: Data(json.utf8)) == .empty)
    }
}
