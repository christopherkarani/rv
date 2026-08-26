import Foundation
import Testing
@testable import RVHooks

private let codec = OpenCodeHostCodec()

private func openCodeFixture(_ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/opencode/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
}

private func openCodeExpected(_ stem: String) throws -> (stdout: String, exit: Int32) {
    let stdout = try openCodeFixture("\(stem).out")
    let exitText = try openCodeFixture("\(stem).exit")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let code = try #require(Int32(exitText))
    return (stdout, code)
}

@Test(arguments: [
    ("allow-git-status.json", "git status"),
    ("deny-git-reset-hard.json", "git reset --hard"),
])
func openCodeDecode_extractsBashCommand(_ file: String, expected: String) throws {
    guard case .request(let request) = codec.decode(try openCodeFixture(file)) else {
        Issue.record("expected .request for \(file)")
        return
    }
    #expect(request.host == .opencode)
    #expect(request.command.rawValue == expected)
}

@Test func openCodeDecode_nonShellIsForeign() throws {
    #expect(codec.decode(try openCodeFixture("allow-non-shell-read.json")) == .foreign)
}

@Test func openCodeDecode_emptyCommandIsMissingCommand() {
    #expect(codec.decode(#"{"tool":"bash","args":{}}"#) == .malformed(.missingCommand))
    #expect(codec.decode(#"{"tool":"bash","args":{"command":""}}"#) == .malformed(.missingCommand))
}

@Test func openCodeDecode_notJSONIsUnreadable() {
    #expect(codec.decode("not-json") == .malformed(.unreadable))
}

@Test func openCodeEncodeAllow_isEmptyExitZero() throws {
    let wire = codec.encodeAllow()
    let expected = try openCodeExpected("allow-git-status")
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
    #expect(wire.stdout.isEmpty)
}

@Test func openCodeEncodeDeny_matchesResetHardFixture() throws {
    let reason =
        "Blocked git reset --hard (core.git/reset-hard). Run it in Terminal, or rv allow-once."
    let wire = codec.encodeDeny(reason: reason)
    let expected = try openCodeExpected("deny-git-reset-hard")
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
    #expect(wire.exitCode == 1)
    #expect(wire.stdout.hasSuffix("\n"))
    #expect(wire.stdout.contains("\"decision\":\"deny\""))
    #expect(wire.stdout.contains(reason))
}

@Test func openCodeEncodeDeny_sameReasonAsPi() {
    let reason =
        "Blocked git reset --hard (core.git/reset-hard). Run it in Terminal, or rv allow-once."
    #expect(OpenCodeHostCodec().encodeDeny(reason: reason).stdout
        == PiHostCodec().encodeDeny(reason: reason).stdout)
    #expect(OpenCodeHostCodec().encodeDeny(reason: reason).exitCode == 1)
    #expect(PiHostCodec().encodeDeny(reason: reason).exitCode == 1)
    #expect(GrokHostCodec().encodeDeny(reason: reason).exitCode == 0)
}

@Test func openCodeDecode_readsCwd() {
    let stdin = """
    {"tool":"bash","cwd":"/tmp/ws","args":{"command":"git status"}}
    """
    guard case .request(let request) = codec.decode(stdin) else {
        Issue.record("expected .request for cwd stdin")
        return
    }
    #expect(request.cwd?.rawValue == "/tmp/ws")
}

@Test func openCodeDecode_emptyCwdIsNil() {
    let stdin = """
    {"tool":"bash","cwd":"","args":{"command":"git status"}}
    """
    guard case .request(let request) = codec.decode(stdin) else {
        Issue.record("expected .request for empty cwd")
        return
    }
    #expect(request.cwd == nil)
}

@Test func openCodeDecode_missingCwdIsNil() {
    let stdin = """
    {"tool":"bash","args":{"command":"git status"}}
    """
    guard case .request(let request) = codec.decode(stdin) else {
        Issue.record("expected .request for missing cwd")
        return
    }
    #expect(request.cwd == nil)
}

@Test func openCodeDecode_readsHostAskSpend() {
    let stdin = """
    {"tool":"bash","cwd":"/tmp/ws","args":{"command":"git reset --hard"},"hostAsk":"spend"}
    """
    guard case .request(let request) = codec.decode(stdin) else {
        Issue.record("expected .request for hostAsk spend")
        return
    }
    #expect(request.hostAsk == .spend)
    #expect(request.cwd?.rawValue == "/tmp/ws")
}

@Test func openCodeEncodeAsk_isNotEmptyAllow() {
    let reason =
        "Blocked git reset --hard (core.git/reset-hard). Run it in Terminal, or rv allow-once."
    let wire = codec.encodeAsk(reason: reason, rule: "core.git/reset-hard", next: hookUnlockNext)
    #expect(wire.exitCode == 1)
    #expect(wire.stdout.isEmpty == false)
    #expect(wire.stdout.contains("\"decision\":\"ask\""))
    #expect(wire.stdout.contains("\"continuation\":\"hostNative\""))
    #expect(wire.stdout.contains(reason))
}
