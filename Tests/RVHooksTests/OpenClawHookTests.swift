import Foundation
import Testing
import RVDomain
@testable import RVHooks

private let codec = OpenClawHostCodec()

private func openClawFixture(_ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/openclaw/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
}

private func openClawExpected(_ stem: String) throws -> (stdout: String, exit: Int32) {
    let stdout = try openClawFixture("\(stem).out")
    let exitText = try openClawFixture("\(stem).exit")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let code = try #require(Int32(exitText))
    return (stdout, code)
}

@Test(arguments: [
    ("allow-git-status.json", "git status"),
    ("deny-git-reset-hard.json", "git reset --hard"),
])
func openClawDecode_extractsExecCommand(_ file: String, expected: String) throws {
    guard case .request(let request) = codec.decode(try openClawFixture(file)) else {
        Issue.record("expected .request for \(file)")
        return
    }
    #expect(request.host == .openclaw)
    #expect(request.command.rawValue == expected)
}

@Test func openClawDecode_nonExecIsForeign() throws {
    #expect(codec.decode(try openClawFixture("allow-non-shell-read.json")) == .foreign)
}

@Test func openClawDecode_codeModeExecIsForeign() {
    let stdin = """
    {"toolName":"exec","toolKind":"code_mode_exec","params":{"command":"console.log(1)"}}
    """
    #expect(codec.decode(stdin) == .foreign)
}

@Test func openClawDecode_emptyCommandIsMissingCommand() {
    #expect(codec.decode(#"{"toolName":"exec","params":{}}"#) == .malformed(.missingCommand))
    #expect(codec.decode(#"{"toolName":"exec","params":{"command":""}}"#) == .malformed(.missingCommand))
}

@Test func openClawDecode_notJSONIsUnreadable() {
    #expect(codec.decode("not-json") == .malformed(.unreadable))
}

@Test func openClawEncodeAllow_isEmptyExitZero() throws {
    let wire = codec.encodeAllow()
    let expected = try openClawExpected("allow-git-status")
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
    #expect(wire.stdout.isEmpty)
}

@Test func openClawEncodeDeny_matchesResetHardFixture() throws {
    let reason =
        resetHardHostDeny
    let wire = codec.encodeDeny(reason: reason)
    let expected = try openClawExpected("deny-git-reset-hard")
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
    #expect(wire.exitCode == 1)
    #expect(wire.stdout.hasSuffix("\n"))
    #expect(wire.stdout.contains("\"decision\":\"deny\""))
    #expect(wire.stdout.contains(reason))
}

@Test func openClawEncodeDeny_sameReasonAsPi() {
    let reason =
        resetHardHostDeny
    #expect(OpenClawHostCodec().encodeDeny(reason: reason).stdout
        == PiHostCodec().encodeDeny(reason: reason).stdout)
    #expect(OpenClawHostCodec().encodeDeny(reason: reason).exitCode == 1)
    #expect(PiHostCodec().encodeDeny(reason: reason).exitCode == 1)
}

@Test func openClawDecode_readsCwdSessionAndProposedAction() throws {
    guard case .request(let request) = codec.decode(try openClawFixture("allow-git-status.json")) else {
        Issue.record("expected .request for cwd stdin")
        return
    }
    #expect(request.cwd?.rawValue == "/tmp/ws")
    #expect(request.session == SessionID(validating: "sess_1"))
    let action = codec.proposedAction(from: request)
    guard case .shell(let shell) = action else {
        Issue.record("expected ProposedAction.shell")
        return
    }
    #expect(shell.supportingCommand?.rawValue == "git status")
    #expect(shell.scope.workingDirectory?.rawValue == "/tmp/ws")
    #expect(shell.fingerprint.rawValue == "openclaw:sess_1:/tmp/ws:git status")
}

@Test func openClawDecode_prefersWorkdirThenEnvelopeCwd() {
    let stdin = """
    {"toolName":"exec","params":{"command":"git status","workdir":"/tmp/from-params"},"cwd":"/tmp/from-envelope"}
    """
    guard case .request(let request) = codec.decode(stdin) else {
        Issue.record("expected .request for workdir stdin")
        return
    }
    #expect(request.cwd?.rawValue == "/tmp/from-params")
}

@Test func openClawDecode_emptyCwdIsNil() {
    let stdin = """
    {"toolName":"exec","cwd":"","params":{"command":"git status"}}
    """
    guard case .request(let request) = codec.decode(stdin) else {
        Issue.record("expected .request for empty cwd")
        return
    }
    #expect(request.cwd == nil)
    #expect(request.session == nil)
}

@Test func openClawDecode_sessionKeyWhenSessionIdMissing() {
    let stdin = """
    {"toolName":"exec","sessionKey":"agent:main","params":{"command":"git status"}}
    """
    guard case .request(let request) = codec.decode(stdin) else {
        Issue.record("expected .request for sessionKey")
        return
    }
    #expect(request.session == SessionID(validating: "agent:main"))
}
