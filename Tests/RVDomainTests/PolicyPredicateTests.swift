import Foundation
import Testing
import RVDomain

@Suite("PolicyPredicate")
struct PolicyPredicateTests {
    @Test(arguments: [
        PolicyPredicate.gitPush(force: .force, branch: "main"),
        PolicyPredicate.gitPush(force: .forceWithLease, branch: "develop"),
        PolicyPredicate.gitPush(force: GitPushForce.none, branch: "feature"),
        PolicyPredicate.gitPush(force: .force, branch: nil),
        PolicyPredicate.gitPush(force: nil, branch: "main"),
        PolicyPredicate.gitPush(force: nil, branch: nil),
    ])
    func gitPush_codableRoundTrip(_ predicate: PolicyPredicate) throws {
        let data = try JSONEncoder().encode(predicate)
        #expect(try JSONDecoder().decode(PolicyPredicate.self, from: data) == predicate)
    }

    @Test func gitPush_decodesFromClosedFormLiteral() throws {
        let json = Data(#"{"gitPush":{"force":"force","branch":"main"}}"#.utf8)
        let predicate = try JSONDecoder().decode(PolicyPredicate.self, from: json)
        #expect(predicate == .gitPush(force: .force, branch: "main"))
    }

    @Test func gitPush_decodesForceNoneDistinctFromUnspecified() throws {
        let json = Data(#"{"gitPush":{"force":"none","branch":"feature"}}"#.utf8)
        let predicate = try JSONDecoder().decode(PolicyPredicate.self, from: json)
        #expect(predicate == .gitPush(force: GitPushForce.none, branch: "feature"))
        #expect(predicate != .gitPush(force: nil, branch: "feature"))
    }

    @Test func encodedForm_omitsSupportingCommand() throws {
        let data = try JSONEncoder().encode(PolicyPredicate.gitPush(force: .force, branch: "main"))
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
