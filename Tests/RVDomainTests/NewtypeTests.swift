import Foundation
import Testing
@testable import RVDomain

@Test func packID_acceptsDottedAndUndotted() {
    #expect(PackID(validating: "core.git") != nil)
    #expect(PackID(validating: "strict_git") != nil)
    #expect(PackID(validating: "package_managers") != nil)
    #expect(PackID(validating: "core.filesystem") != nil)
}

@Test func packID_rejectsInvalid() {
    #expect(PackID(validating: "Core.Git") == nil)
    #expect(PackID(validating: "core.git.extra") == nil)
    #expect(PackID(validating: "1git") == nil)
    #expect(PackID(validating: "") == nil)
    #expect(PackID(validating: ".git") == nil)
}

@Test func packID_rawValueInit_isNonFailable() {
    let pack = PackID(rawValue: "core.git")
    #expect(pack.rawValue == "core.git")
}

@Test func ruleID_isPackColonPattern() {
    let rule = RuleID(pack: PackID(rawValue: "core.git"), pattern: "reset-hard")
    #expect(rule.rawValue == "core.git:reset-hard")
    #expect(RuleID(rawValue: "core.git:reset-hard")?.pattern == "reset-hard")
}

@Test func deny_alwaysCarriesRuleAndReason() {
    let deny = Deny(
        ruleID: RuleID(pack: .coreGit, pattern: "reset-hard"),
        reason: "git reset --hard destroys uncommitted changes. Use 'git stash' first."
    )
    let decision = Decision.deny(deny)
    guard case .deny(let payload) = decision else {
        Issue.record("expected deny")
        return
    }
    #expect(payload.ruleID.rawValue == "core.git:reset-hard")
    #expect(payload.reason.contains("destroys uncommitted changes"))
}

@Test func severity_blocksByDefault() {
    #expect(Severity.critical.blocksByDefault)
    #expect(Severity.high.blocksByDefault)
    #expect(!Severity.medium.blocksByDefault)
    #expect(!Severity.low.blocksByDefault)
}

@Test func dayOnePackIDs_areNonFailableConstants() {
    #expect(dayOnePackIDs.map(\.rawValue) == ["core.filesystem", "core.git"])
}

@Test func matchingView_encodesAsJSONStringNotObject() throws {
    let view = MatchingView("git reset --hard")
    let data = try JSONEncoder().encode(view)
    #expect(String(data: data, encoding: .utf8) == "\"git reset --hard\"")
    #expect(try JSONDecoder().decode(MatchingView.self, from: data) == view)
}
