import Foundation
import RVDomain
import Testing
@testable import RVPolicy

private func emptyArrays(_ depth: Int) -> String {
    String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
}

private func scalarArrays(_ depth: Int) -> String {
    String(repeating: "[", count: depth) + "1" + String(repeating: "]", count: depth)
}

private func emptyObjects(_ depth: Int) -> String {
    String(repeating: "{\"a\":", count: depth - 1) + "{}" + String(repeating: "}", count: depth - 1)
}

private func scalarObjects(_ depth: Int) -> String {
    String(repeating: "{\"a\":", count: depth) + "1" + String(repeating: "}", count: depth)
}

/// Depth boundaries the legacy `JSONLiteral` entry has always enforced.
/// The unified parser must keep them at this adapter: an off-by-one here
/// either accepts policy the old parser refused or refuses policy it took.
@Suite("JSONLiteral depth")
struct JSONLiteralDepthTests {
    @Test func legacyEntryKeepsItsDepthBoundaries() {
        #expect(JSONLiteral.parse(Data(emptyArrays(64).utf8)) != nil)
        #expect(JSONLiteral.parse(Data(emptyArrays(65).utf8)) == nil)
        #expect(JSONLiteral.parse(Data(scalarArrays(63).utf8)) != nil)
        #expect(JSONLiteral.parse(Data(scalarArrays(64).utf8)) == nil)
        #expect(JSONLiteral.parse(Data(emptyObjects(64).utf8)) != nil)
        #expect(JSONLiteral.parse(Data(emptyObjects(65).utf8)) == nil)
        #expect(JSONLiteral.parse(Data(scalarObjects(63).utf8)) != nil)
        #expect(JSONLiteral.parse(Data(scalarObjects(64).utf8)) == nil)
    }

    @Test func legacyEntryRejectsDuplicateKeys() {
        #expect(JSONLiteral.parse(Data(#"{"a":1,"a":2}"#.utf8)) == nil)
        #expect(JSONLiteral.parse(Data(#"{"a":{"b":1,"b":2}}"#.utf8)) == nil)
    }
}

/// The parser module itself: malformed, depth, and duplicate tables at the
/// seam the two adapters now share.
@Suite("JSONSpellingParser")
struct JSONSpellingParserTests {
    private func parseError(_ text: String, maximumDepth: Int = 64, lenient: Bool = false) -> JSONSpellingParseError? {
        do throws(JSONSpellingParseError) {
            _ = try JSONSpellingParser.parse(text, maximumDepth: maximumDepth, lenient: lenient)
            return nil
        } catch {
            return error
        }
    }

    @Test func keepsEntryOrderAndNumberSpellings() throws {
        let value = try JSONSpellingParser.parse(#"{"z":1.50,"a":[9007199254740993.0,-0,2e10,true,null],"m":"x"}"#)
        #expect(value.entries?.map(\.key) == ["z", "a", "m"])
        #expect(value["z"] == .number("1.50"))
        #expect(value["a"] == .array([.number("9007199254740993.0"), .number("-0"), .number("2e10"), .bool(true), .null]))
        #expect(value.object?["m"] == .string("x"))
    }

    @Test func domainValueKeepsExactIntegersAsDigits() throws {
        #expect(try JSONSpellingParser.parse("9007199254740993").domainValue() == .string("\u{0}9007199254740993"))
        #expect(try JSONSpellingParser.parse("9007199254740993.0").domainValue() == .string("\u{0}9007199254740993"))
        #expect(try JSONSpellingParser.parse("\"9007199254740993\"").domainValue() == .string("9007199254740993"))
        #expect(try JSONSpellingParser.parse("2.0").domainValue() == .number(2))
        #expect(try JSONSpellingParser.parse("12.5").domainValue() == .number(12.5))
        #expect(try JSONSpellingParser.parse(#"{"a":[true,null]}"#).domainValue() == .object(["a": .array([.bool(true), .null])]))
    }

    @Test func malformedTableIsInvalidNeverTooDeepOrDuplicate() {
        for bad in ["", "{", #"{"a":}"#, "[1,]", "01", "1.", "tru", "\"a\u{01}\"", #"{"a":1}x"#, "// c\n1",
                    #""\ud83d""#, "[}", #"{"a":1,}"#, "-", "1e", #"{"a" 1}"#] {
            guard case .invalid(_) = parseError(bad) else {
                Issue.record("expected .invalid for \(bad.debugDescription), got \(String(describing: parseError(bad)))")
                continue
            }
        }
        #expect(parseError(#"{"a":1}x"#) == .invalid(offset: 7))
    }

    @Test func duplicateTableFailsClosed() {
        for dup in [#"{"a":1,"a":2}"#, #"{"a":{"b":1,"b":2}}"#, #"{"a":1,"a":}"#, #"[{"k":1,"k":2}]"#] {
            #expect(parseError(dup) == .duplicateKey, "\(dup)")
        }
    }

    @Test func depthTableScalesWithMaximumDepth() {
        for maximum in [0, 1, 2, 16, 64] {
            #expect(parseError(scalarArrays(maximum), maximumDepth: maximum) == nil, "scalar \(maximum)")
            #expect(parseError(scalarArrays(maximum + 1), maximumDepth: maximum) == .tooDeep, "scalar \(maximum + 1)")
            #expect(parseError(emptyArrays(maximum + 1), maximumDepth: maximum) == nil, "empty \(maximum + 1)")
            #expect(parseError(emptyArrays(maximum + 2), maximumDepth: maximum) == .tooDeep, "empty \(maximum + 2)")
            #expect(parseError(scalarObjects(maximum), maximumDepth: maximum) == nil, "object scalar \(maximum)")
            #expect(parseError(scalarObjects(maximum + 1), maximumDepth: maximum) == .tooDeep, "object scalar \(maximum + 1)")
            #expect(parseError(emptyObjects(maximum + 1), maximumDepth: maximum) == nil, "object empty \(maximum + 1)")
            #expect(parseError(emptyObjects(maximum + 2), maximumDepth: maximum) == .tooDeep, "object empty \(maximum + 2)")
        }
    }

    @Test func lenientIsExplicitNeverDefault() throws {
        let text = """
            // servers
            { "servers": { /* one */ "a": { "command": "x", }, }, }
            """
        #expect(parseError(text) != nil)
        #expect(try JSONSpellingParser.parse(text, lenient: true)["servers"]?["a"]?["command"] == .string("x"))
        #expect(parseError("/* unterminated", lenient: true) != nil)
    }

    @Test func unicodeEscapesAndByteOrderMark() throws {
        #expect(try JSONSpellingParser.parse(#""\u00e9\ud83d\ude00\/""#) == .string("é😀/"))
        let bom = Data([0xEF, 0xBB, 0xBF]) + Data(#"{"a":1}"#.utf8)
        #expect(try JSONSpellingParser.parse(bom)["a"] == .number("1"))
        #expect(parseError("\"é\"") == nil)
    }

    @Test func managedPolicyStaysStrictOnDuplicateKeys() {
        guard case .failure(let error) = ManagedPolicy.decode(Data(#"{"version":1,"version":1}"#.utf8)) else {
            Issue.record("duplicate policy key decoded")
            return
        }
        #expect(error.message == "policy.json is not a JSON object")
    }
}
