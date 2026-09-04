import Foundation
import Testing
import RVDomain

@Suite("TypedRule")
struct TypedRuleTests {
    @Test func holdsIdPredicateVerdictAndOrigin() {
        let rule = TypedRule(
            id: RuleID(pack: .coreGit, pattern: "force-push-main"),
            predicate: .gitPush(force: .force, branch: "main"),
            verdict: .deny,
            origin: .machine
        )
        #expect(rule.id == RuleID(pack: .coreGit, pattern: "force-push-main"))
        #expect(rule.predicate == .gitPush(force: .force, branch: "main"))
        #expect(rule.verdict == .deny)
        #expect(rule.origin == .machine)
    }

    @Test func equalityUsesAllFields() {
        let base = sampleRule()
        #expect(base == sampleRule())
        #expect(base != sampleRule(id: RuleID(pack: .coreGit, pattern: "other")))
        #expect(base != sampleRule(predicate: .gitPush(force: .force, branch: "feature")))
        #expect(base != sampleRule(verdict: .allow))
        #expect(base != sampleRule(verdict: .ask))
        #expect(base != sampleRule(origin: .builtin))
        #expect(base != sampleRule(origin: .repo))
    }

    @Test(arguments: [
        TypedRuleVerdict.allow,
        .ask,
        .deny,
    ], [
        TypedRuleOrigin.builtin,
        .machine,
        .repo,
    ])
    func codableRoundTrip(verdict: TypedRuleVerdict, origin: TypedRuleOrigin) throws {
        let rule = sampleRule(verdict: verdict, origin: origin)
        let data = try JSONEncoder().encode(rule)
        #expect(try JSONDecoder().decode(TypedRule.self, from: data) == rule)
    }

    @Test func decodesFromClosedFormLiteral() throws {
        let json = Data(
            #"{"id":"core.git:force-push-main","origin":"machine","predicate":{"gitPush":{"branch":"main","force":"force"}},"verdict":"deny"}"#
                .utf8
        )
        let rule = try JSONDecoder().decode(TypedRule.self, from: json)
        #expect(rule.id == RuleID(pack: .coreGit, pattern: "force-push-main"))
        #expect(rule.predicate == .gitPush(force: .force, branch: "main"))
        #expect(rule.verdict == .deny)
        #expect(rule.origin == .machine)
    }

    @Test(arguments: [
        #"{"id":"core.git:force-push-main","origin":"machine","predicate":{"gitPush":{"branch":"main","force":"force"}},"verdict":"permit"}"#,
        #"{"id":"core.git:force-push-main","origin":"machine","predicate":{"gitPush":{"branch":"main","force":"force"}},"verdict":"observe"}"#,
    ])
    func unknownVerdict_failsClosed(_ json: String) {
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(TypedRule.self, from: Data(json.utf8))
        }
    }

    @Test(arguments: [
        #"{"id":"core.git:force-push-main","origin":"user","predicate":{"gitPush":{"branch":"main","force":"force"}},"verdict":"deny"}"#,
        #"{"id":"core.git:force-push-main","origin":"pack","predicate":{"gitPush":{"branch":"main","force":"force"}},"verdict":"deny"}"#,
    ])
    func unknownOrigin_failsClosed(_ json: String) {
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(TypedRule.self, from: Data(json.utf8))
        }
    }

    @Test func encodedForm_omitsEnglish() throws {
        let data = try JSONEncoder().encode(sampleRule())
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("english") == false)
        #expect(json.contains("supportingCommand") == false)
    }

    @Test func englishKey_isNotPartOfTheForm() throws {
        let json = Data(
            #"{"english":"never allow force-push to main","id":"core.git:force-push-main","origin":"machine","predicate":{"gitPush":{"branch":"main","force":"force"}},"verdict":"deny"}"#
                .utf8
        )
        let rule = try JSONDecoder().decode(TypedRule.self, from: json)
        #expect(rule == sampleRule())
        let encoded = try JSONEncoder().encode(rule)
        let text = try #require(String(data: encoded, encoding: .utf8))
        #expect(text.contains("english") == false)
    }
}

private func sampleRule(
    id: RuleID = RuleID(pack: .coreGit, pattern: "force-push-main"),
    predicate: PolicyPredicate = .gitPush(force: .force, branch: "main"),
    verdict: TypedRuleVerdict = .deny,
    origin: TypedRuleOrigin = .machine
) -> TypedRule {
    TypedRule(id: id, predicate: predicate, verdict: verdict, origin: origin)
}
