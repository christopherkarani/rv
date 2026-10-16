import Foundation
import RVDomain
import Testing
@testable import RVPolicy

/// The production path: policy and argument values reach the rules through
/// `JSONLiteral`, which keeps number spellings exact. Decoding fixtures with
/// `JSONDecoder` would round what production compares exactly.
private func json(_ text: String) throws -> JSONValue {
    try #require(JSONLiteral.parse(Data(text.utf8))).domainValue()
}

private func rule(_ text: String) throws -> ToolArgumentRule {
    try ToolArgumentRule.decode(json(text))
}

@Suite("ToolArgumentRule")
struct ToolArgumentRuleTests {
    struct MatchCase: Sendable, CustomTestStringConvertible {
        var rule: String
        var arguments: String
        var matches: Bool
        var testDescription: String { "\(rule) on \(arguments)" }
    }

    static let matchCases: [MatchCase] = [
        .init(rule: #"{"tool":"push","when":{"/branch":{"==":"main"}}}"#, arguments: #"{"branch":"main"}"#, matches: true),
        .init(rule: #"{"tool":"push","when":{"/branch":{"==":"main"}}}"#, arguments: #"{"branch":"dev"}"#, matches: false),
        .init(rule: #"{"tool":"push","when":{"/branch":{"==":"main"}}}"#, arguments: #"{}"#, matches: false),
        .init(rule: #"{"tool":"push","when":{"/branch":{"!=":"main"}}}"#, arguments: #"{"branch":"dev"}"#, matches: true),
        .init(rule: #"{"tool":"push","when":{"/branch":{"!=":"main"}}}"#, arguments: #"{"branch":"main"}"#, matches: false),
        .init(rule: #"{"tool":"push","when":{"/branch":{"!=":"main"}}}"#, arguments: #"{}"#, matches: false),
        .init(rule: #"{"tool":"pay","when":{"/amount":{">":100}}}"#, arguments: #"{"amount":250}"#, matches: true),
        .init(rule: #"{"tool":"pay","when":{"/amount":{">":100}}}"#, arguments: #"{"amount":100}"#, matches: false),
        .init(rule: #"{"tool":"pay","when":{"/amount":{">":100}}}"#, arguments: #"{"amount":"250"}"#, matches: true),
        .init(rule: #"{"tool":"pay","when":{"/amount":{">":100}}}"#, arguments: #"{"amount":"50"}"#, matches: false),
        .init(rule: #"{"tool":"pay","when":{"/amount":{">":100}}}"#, arguments: #"{"amount":"999999"}"#, matches: true),
        .init(rule: #"{"tool":"pay","when":{"/amount":{">":"100"}}}"#, arguments: #"{"amount":"250"}"#, matches: true),
        .init(rule: #"{"tool":"pay","when":{"/amount":{">":100}}}"#, arguments: #"{"amount":9007199254740993}"#, matches: true),
        .init(rule: #"{"tool":"pay","when":{"/amount":{">":9007199254740994}}}"#, arguments: #"{"amount":9007199254740993}"#, matches: false),
        .init(rule: #"{"tool":"pay","when":{"/amount":{"<":9007199254740995}}}"#, arguments: #"{"amount":9007199254740994}"#, matches: true),
        .init(rule: #"{"tool":"pay","when":{"/amount":{"<":10.5}}}"#, arguments: #"{"amount":10.25}"#, matches: true),
        .init(rule: #"{"tool":"pay","when":{"/amount":{">":0,"<":10}}}"#, arguments: #"{"amount":5}"#, matches: true),
        .init(rule: #"{"tool":"pay","when":{"/amount":{">":0,"<":10}}}"#, arguments: #"{"amount":15}"#, matches: false),
        .init(rule: #"{"tool":"q","when":{"/db":{"in":["prod","billing"]}}}"#, arguments: #"{"db":"prod"}"#, matches: true),
        .init(rule: #"{"tool":"q","when":{"/db":{"in":["prod","billing"]}}}"#, arguments: #"{"db":"test"}"#, matches: false),
        .init(rule: #"{"tool":"q","when":{"/n":{"in":[1,2]}}}"#, arguments: #"{"n":2.0}"#, matches: true),
        .init(rule: #"{"tool":"write","when":{"/path":{"glob":"/etc/*"}}}"#, arguments: #"{"path":"/etc/hosts"}"#, matches: true),
        .init(rule: #"{"tool":"write","when":{"/path":{"glob":"/etc/*"}}}"#, arguments: #"{"path":"/tmp/x"}"#, matches: false),
        .init(rule: #"{"tool":"write","when":{"/path":{"glob":"/etc/*"}}}"#, arguments: #"{"path":["/etc/x"]}"#, matches: false),
        .init(rule: #"{"tool":"write_*","when":{"/path":{"glob":"*"}}}"#, arguments: #"{"path":"a"}"#, matches: true),
        .init(rule: #"{"tool":"q","when":{"/opts/flags/1":{"==":"force"}}}"#, arguments: #"{"opts":{"flags":["dry","force"]}}"#, matches: true),
        .init(rule: #"{"tool":"q","when":{"/opts/flags/2":{"==":"force"}}}"#, arguments: #"{"opts":{"flags":["dry","force"]}}"#, matches: false),
        .init(rule: #"{"tool":"q","when":{"/a~1b/c~0d":{"==":true}}}"#, arguments: #"{"a/b":{"c~d":true}}"#, matches: true),
        .init(rule: #"{"tool":"q","when":{"/x":{"==":null}}}"#, arguments: #"{"x":null}"#, matches: true),
        .init(rule: #"{"tool":"q","when":{"/x":{"==":{"k":[1]}}}}"#, arguments: #"{"x":{"k":[1]}}"#, matches: true),
        .init(rule: #"{"tool":"q","when":{"":{"==":{}}}}"#, arguments: #"{}"#, matches: true),
        .init(rule: #"{"tool":"q","when":{"/a":{"==":1},"/b":{"==":2}}}"#, arguments: #"{"a":1,"b":2}"#, matches: true),
        .init(rule: #"{"tool":"q","when":{"/a":{"==":1},"/b":{"==":2}}}"#, arguments: #"{"a":1,"b":3}"#, matches: false),
        .init(rule: #"{"tool":"q","when":{"/id":{"==":9007199254740993}}}"#, arguments: #"{"id":9007199254740992}"#, matches: false),
        .init(rule: #"{"tool":"q","when":{"/id":{"==":9007199254740993}}}"#, arguments: #"{"id":9007199254740993}"#, matches: true),
        .init(rule: #"{"tool":"q","when":{"/id":{"==":"9007199254740993"}}}"#, arguments: #"{"id":9007199254740993}"#, matches: false),
        .init(rule: #"{"tool":"q","when":{"/id":{"==":9007199254740993}}}"#, arguments: #"{"id":"9007199254740993"}"#, matches: false),
        .init(rule: #"{"tool":"q","when":{"/id":{"in":[9007199254740993]}}}"#, arguments: #"{"id":"9007199254740993"}"#, matches: false),
        .init(rule: #"{"tool":"q","when":{"/id":{"glob":"900*"}}}"#, arguments: #"{"id":9007199254740993}"#, matches: false),
        .init(rule: #"{"tool":"q","when":{"/n":{"==":0}}}"#, arguments: #"{"n":0e-2}"#, matches: true),
        .init(rule: #"{"tool":"q","when":{"/n":{"==":0}}}"#, arguments: #"{"n":0.00e-10}"#, matches: true),
        .init(rule: #"{"tool":"q","when":{"/id":{"==":9007199254740993}}}"#, arguments: #"{"id":9007199254740993}"#, matches: true),
    ]

    @Test(arguments: matchCases)
    func matching(_ testCase: MatchCase) throws {
        let parsed = try rule(testCase.rule)
        #expect(parsed.matches(tool: parsed.tool.replacingOccurrences(of: "*", with: "x"), arguments: try json(testCase.arguments)) == testCase.matches)
    }

    @Test func toolGlobMustMatchToo() throws {
        let parsed = try rule(#"{"tool":"write_*","when":{"/path":{"glob":"*"}}}"#)
        #expect(parsed.matches(tool: "write_file", arguments: try json(#"{"path":"a"}"#)))
        #expect(parsed.matches(tool: "read_file", arguments: try json(#"{"path":"a"}"#)) == false)
        #expect(parsed.namesTool("write_file"))
        #expect(parsed.namesTool("read_file") == false)
    }

    struct InvalidCase: Sendable, CustomTestStringConvertible {
        var rule: String
        var message: String
        var testDescription: String { rule }
    }

    static let invalidCases: [InvalidCase] = [
        .init(rule: #""push""#, message: "must be an object"),
        .init(rule: #"{"when":{"/a":{"==":1}}}"#, message: "needs a \"tool\" glob"),
        .init(rule: #"{"tool":"","when":{"/a":{"==":1}}}"#, message: "needs a \"tool\" glob"),
        .init(rule: #"{"tool":"push"}"#, message: "needs a non-empty \"when\""),
        .init(rule: #"{"tool":"push","when":{}}"#, message: "needs a non-empty \"when\""),
        .init(rule: #"{"tool":"push","when":{"/a":{"==":1}},"extra":1}"#, message: "unknown key \"extra\""),
        .init(rule: #"{"tool":"push","when":{"a":{"==":1}}}"#, message: "is not a JSON pointer"),
        .init(rule: #"{"tool":"push","when":{"/a~2":{"==":1}}}"#, message: "is not a JSON pointer"),
        .init(rule: #"{"tool":"push","when":{"/a":{}}}"#, message: "needs at least one operator"),
        .init(rule: #"{"tool":"push","when":{"/a":"main"}}"#, message: "needs at least one operator"),
        .init(rule: #"{"tool":"push","when":{"/a":{"~=":1}}}"#, message: "unknown operator \"~=\""),
        .init(rule: #"{"tool":"push","when":{"/a":{">":"10.0"}}}"#, message: "\">\" needs a number"),
        .init(rule: #"{"tool":"push","when":{"/a":{"<":true}}}"#, message: "\"<\" needs a number"),
        .init(rule: #"{"tool":"push","when":{"/a":{"in":"x"}}}"#, message: "\"in\" needs a non-empty array"),
        .init(rule: #"{"tool":"push","when":{"/a":{"in":[]}}}"#, message: "\"in\" needs a non-empty array"),
        .init(rule: #"{"tool":9007199254740993,"when":{"/a":{"==":1}}}"#, message: "needs a \"tool\" glob"),
        .init(rule: #"{"tool":"push","when":{"/a":{"glob":9007199254740993}}}"#, message: "\"glob\" needs a non-empty string"),
        .init(rule: #"{"tool":"push","when":{"/a":{"glob":1}}}"#, message: "\"glob\" needs a non-empty string"),
    ]

    @Test(arguments: invalidCases)
    func invalid(_ testCase: InvalidCase) throws {
        let error = #expect(throws: ToolArgumentRuleError.self) { try rule(testCase.rule) }
        #expect(error?.message.contains(testCase.message) == true, "\(error?.message ?? "nil")")
    }

    @Test func roundTripsThroughItsEncoding() throws {
        let text = #"{"tool":"pay","when":{"/amount":{">":100,"<":1000},"/currency":{"in":["usd","eur"]}}}"#
        let parsed = try rule(text)
        #expect(try ToolArgumentRule.decode(parsed.encoded) == parsed)
        #expect(parsed.conditions.map(\.pointer) == ["/amount", "/amount", "/currency"])
    }

    @Test func describesItselfForListings() throws {
        let parsed = try rule(#"{"tool":"pay","when":{"/amount":{">":100},"/currency":{"in":["usd"]}}}"#)
        #expect(parsed.summary == #"pay when /amount > 100, /currency in ["usd"]"#)
    }

    @Test func strictestMatchingRuleWins() throws {
        let rules: [ToolArgumentRule.Decided] = [
            .init(decision: .allow, rule: try rule(#"{"tool":"q","when":{"/db":{"glob":"*"}}}"#)),
            .init(decision: .ask, rule: try rule(#"{"tool":"q","when":{"/db":{"==":"prod"}}}"#)),
            .init(decision: .deny, rule: try rule(#"{"tool":"q","when":{"/db":{"==":"billing"}}}"#)),
        ]
        #expect(ToolArgumentRule.strictest(rules, tool: "q", arguments: try json(#"{"db":"test"}"#)) == .allow)
        #expect(ToolArgumentRule.strictest(rules, tool: "q", arguments: try json(#"{"db":"prod"}"#)) == .ask)
        #expect(ToolArgumentRule.strictest(rules, tool: "q", arguments: try json(#"{"db":"billing"}"#)) == .deny)
        #expect(ToolArgumentRule.strictest(rules, tool: "q", arguments: try json(#"{}"#)) == nil)
        #expect(ToolArgumentRule.strictest(rules, tool: "other", arguments: try json(#"{"db":"prod"}"#)) == nil)
    }

    @Test func aPresentNonNumberDoesNotRevealAWeakerDecision() throws {
        let deny = ToolArgumentRule.Decided(decision: .deny, rule: try rule(#"{"tool":"pay","when":{"/amount":{">":100}}}"#))
        let allow = ToolArgumentRule.Decided(decision: .allow, rule: try rule(#"{"tool":"pay","when":{"/amount":{">":100}}}"#))
        for arguments in [#"{"amount":"nope"}"#, #"{"amount":true}"#, #"{"amount":"999999.0"}"#] {
            #expect(ToolArgumentRule.strictest([deny], tool: "pay", arguments: try json(arguments)) == .deny)
            #expect(ToolArgumentRule.strictest([allow], tool: "pay", arguments: try json(arguments)) == .deny)
        }
        #expect(ToolArgumentRule.strictest([deny], tool: "pay", arguments: try json(#"{}"#)) == nil)
        #expect(try rule(#"{"tool":"pay","when":{"/amount":{">":9007199254740993}}}"#).matches(
            tool: "pay", arguments: try json(#"{"amount":9007199254740994}"#)))
    }
}

extension ToolArgumentRuleTests {
    @Test func nestedMarkedValuesSummarizeWithoutTheMarker() throws {
        let parsed = try rule(#"{"tool":"q","when":{"/id":{"in":[9007199254740993]}}}"#)
        #expect(parsed.summary.contains("\u{0}") == false, "\(parsed.summary)")
        #expect(parsed.summary.contains("9007199254740993"))
    }
}
