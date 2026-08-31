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
    let invalid = PackID(rawValue: "Core.Git")
    #expect(invalid.rawValue == "Core.Git")
}

@Test func packID_decodeRejectsInvalidGrammar() {
    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(PackID.self, from: Data(#""Core.Git""#.utf8))
    }
}

@Test func packID_codableIsJSONString() throws {
    let pack = PackID(rawValue: "core.git")
    let data = try JSONEncoder().encode(pack)
    #expect(String(data: data, encoding: .utf8) == "\"core.git\"")
    #expect(try JSONDecoder().decode(PackID.self, from: data) == pack)
}

@Test func ruleID_isPackColonPattern() {
    let rule = RuleID(pack: PackID(rawValue: "core.git"), pattern: "reset-hard")
    #expect(rule.rawValue == "core.git:reset-hard")
    #expect(RuleID(rawValue: "core.git:reset-hard")?.pattern == "reset-hard")
}

@Test func ruleID_rejectsInvalidPackGrammar() {
    #expect(RuleID(rawValue: "Core.Git:reset-hard") == nil)
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
    #expect(dayOnePackIDs.map(\.rawValue) == ["core.filesystem", "core.git", "system.disk"])
    #expect(dayOnePackIDs.contains(.systemDisk))
}

@Test func evaluationRequest_makeDayOne_usesDayOnePacksAndNoBudget() {
    let command = ShellCommand(rawValue: "git status")
    let request = EvaluationRequest.makeDayOne(command: command)
    #expect(request.command == command)
    #expect(request.enabledPacks == dayOnePackIDs)
    #expect(request.budget == nil)
}

@Test func matchingView_encodesAsJSONStringNotObject() throws {
    let view = MatchingView("git reset --hard")
    let data = try JSONEncoder().encode(view)
    #expect(String(data: data, encoding: .utf8) == "\"git reset --hard\"")
    #expect(try JSONDecoder().decode(MatchingView.self, from: data) == view)
}

@Test func workingDirectory_rejectsEmptyAndAcceptsNonempty() throws {
    #expect(WorkingDirectory(validating: "") == nil)
    let cwd = try #require(WorkingDirectory(validating: "/tmp/ws"))
    #expect(cwd.rawValue == "/tmp/ws")
    #expect(WorkingDirectory(rawValue: "") == nil)
    #expect(WorkingDirectory(rawValue: "/tmp/ws") != nil)
}

@Test func repositoryRoot_rejectsEmptyAndAcceptsNonempty() throws {
    #expect(RepositoryRoot(validating: "") == nil)
    let root = try #require(RepositoryRoot(validating: "/tmp/repo"))
    #expect(root.rawValue == "/tmp/repo")
    #expect(RepositoryRoot(rawValue: "") == nil)
}

@Test func workingDirectory_codableIsJSONString() throws {
    let cwd = try #require(WorkingDirectory(validating: "/tmp/ws"))
    let encoder = JSONEncoder()
    encoder.outputFormatting = .withoutEscapingSlashes
    let data = try encoder.encode(cwd)
    #expect(String(data: data, encoding: .utf8) == "\"/tmp/ws\"")
    #expect(try JSONDecoder().decode(WorkingDirectory.self, from: data) == cwd)

    let empty = try JSONEncoder().encode("")
    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(WorkingDirectory.self, from: empty)
    }
}
