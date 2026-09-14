import Foundation
import Testing
import RVDomain

@Suite("PolicyPredicate")
struct PolicyPredicateTests {
    @Test(arguments: [
        PolicyPredicate.gitPush(force: .exactly(.force), branch: "main"),
        PolicyPredicate.gitPush(force: .exactly(.forceWithLease), branch: "develop"),
        PolicyPredicate.gitPush(force: .exactly(.none), branch: "feature"),
        PolicyPredicate.gitPush(force: .exactly(.force), branch: nil),
        PolicyPredicate.gitPush(force: .any, branch: "main"),
        PolicyPredicate.gitPush(force: .any, branch: nil),
    ])
    func gitPush_codableRoundTrip(_ predicate: PolicyPredicate) throws {
        let data = try JSONEncoder().encode(predicate)
        #expect(try JSONDecoder().decode(PolicyPredicate.self, from: data) == predicate)
    }

    @Test func gitPush_decodesFromClosedFormLiteral() throws {
        let json = Data(#"{"gitPush":{"force":"force","branch":"main"}}"#.utf8)
        let predicate = try JSONDecoder().decode(PolicyPredicate.self, from: json)
        #expect(predicate == .gitPush(force: .exactly(.force), branch: "main"))
    }

    @Test func gitPush_decodesForceNoneDistinctFromUnspecified() throws {
        let json = Data(#"{"gitPush":{"force":"none","branch":"feature"}}"#.utf8)
        let predicate = try JSONDecoder().decode(PolicyPredicate.self, from: json)
        #expect(predicate == .gitPush(force: .exactly(.none), branch: "feature"))
        #expect(predicate != .gitPush(force: .any, branch: "feature"))
    }

    @Test func gitPush_omitOrNullForceDecodesAsAny_distinctFromNone() throws {
        let omitted = Data(#"{"gitPush":{"branch":"main"}}"#.utf8)
        let nullForce = Data(#"{"gitPush":{"force":null,"branch":"main"}}"#.utf8)
        #expect(try JSONDecoder().decode(PolicyPredicate.self, from: omitted) == .gitPush(force: .any, branch: "main"))
        #expect(
            try JSONDecoder().decode(PolicyPredicate.self, from: nullForce)
                == .gitPush(force: .any, branch: "main")
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let anyJSON = try #require(
            String(data: encoder.encode(PolicyPredicate.gitPush(force: .any, branch: "main")), encoding: .utf8)
        )
        let noneJSON = try #require(
            String(
                data: encoder.encode(PolicyPredicate.gitPush(force: .exactly(.none), branch: "main")),
                encoding: .utf8
            )
        )
        #expect(anyJSON.contains("\"force\":\"none\"") == false)
        #expect(noneJSON.contains("\"force\":\"none\""))
        #expect(anyJSON != noneJSON)
    }

    @Test func encodedForm_omitsSupportingCommand() throws {
        let data = try JSONEncoder().encode(PolicyPredicate.gitPush(force: .exactly(.force), branch: "main"))
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("supportingCommand") == false)
    }

    @Test(arguments: [
        #"{"npm":{}}"#,
        #"{"mcp":{}}"#,
        #"{"status":{}}"#,
        #"{"gitStatus":{}}"#,
    ])
    func unknownCase_failsClosed(_ json: String) {
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(PolicyPredicate.self, from: Data(json.utf8))
        }
    }
}
