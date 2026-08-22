import Foundation
import Testing
@testable import RVHooks

private let codec = PiHostCodec()

private func piFixture(_ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/pi/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
}

private func piExpected(_ stem: String) throws -> (stdout: String, exit: Int32) {
    let stdout = try piFixture("\(stem).out")
    let exitText = try piFixture("\(stem).exit")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let code = try #require(Int32(exitText))
    return (stdout, code)
}

@Test(arguments: [
    ("allow-git-status.json", "git status"),
    ("deny-git-reset-hard.json", "git reset --hard"),
])
func piDecode_extractsBashCommand(_ file: String, expected: String) throws {
    guard case .request(let request) = codec.decode(try piFixture(file)) else {
        Issue.record("expected .request for \(file)")
        return
    }
    #expect(request.host == .pi)
    #expect(request.command.rawValue == expected)
}

@Test func piDecode_nonShellIsForeign() throws {
    #expect(codec.decode(try piFixture("allow-non-shell-read.json")) == .foreign)
}

@Test func piDecode_emptyCommandIsMissingCommand() {
    #expect(codec.decode(#"{"toolName":"bash","input":{}}"#) == .malformed(.missingCommand))
    #expect(codec.decode(#"{"toolName":"bash","input":{"command":""}}"#) == .malformed(.missingCommand))
}

@Test func piDecode_notJSONIsUnreadable() {
    #expect(codec.decode("not-json") == .malformed(.unreadable))
}

@Test func piEncodeAllow_isEmptyExitZero() throws {
    let wire = codec.encodeAllow()
    let expected = try piExpected("allow-git-status")
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
    #expect(wire.stdout.isEmpty)
}

@Test func piEncodeDeny_matchesResetHardFixture() throws {
    let reason =
        "Blocked git reset --hard (core.git/reset-hard). Run it in Terminal, or rv allow-once."
    let wire = codec.encodeDeny(reason: reason)
    let expected = try piExpected("deny-git-reset-hard")
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
    #expect(wire.exitCode == 1)
    #expect(wire.stdout.hasSuffix("\n"))
    #expect(wire.stdout.contains("\"decision\":\"deny\""))
    #expect(wire.stdout.contains(reason))
}

@Test func piEncodeDeny_indeterminateUsesPlanSentence() {
    let reason = "rv could not finish evaluating this command. Run it in Terminal."
    let wire = codec.encodeDeny(reason: reason)
    #expect(wire.exitCode == 1)
    #expect(wire.stdout.contains("\"decision\":\"deny\""))
    #expect(wire.stdout.contains(reason))
    #expect(wire.stdout.contains("core.git") == false)
}
