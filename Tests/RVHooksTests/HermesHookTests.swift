import Foundation
import Testing
import RVDomain
@testable import RVHooks

private let codec = HermesHostCodec()

private func hermesFixture(_ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/hermes/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
}

private func hermesExpected(_ stem: String) throws -> (stdout: String, exit: Int32) {
    let stdout = try hermesFixture("\(stem).out")
    let exitText = try hermesFixture("\(stem).exit")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let code = try #require(Int32(exitText))
    return (stdout, code)
}

@Test(arguments: [
    ("allow-git-status.json", "git status"),
    ("deny-git-reset-hard.json", "git reset --hard"),
])
func hermesDecode_extractsTerminalCommand(_ file: String, expected: String) throws {
    guard case .request(let request) = codec.decode(try hermesFixture(file)) else {
        Issue.record("expected .request for \(file)")
        return
    }
    #expect(request.host == .hermes)
    #expect(request.command.rawValue == expected)
}

@Test func hermesDecode_nonTerminalIsForeign() throws {
    #expect(codec.decode(try hermesFixture("allow-non-shell-read.json")) == .foreign)
}

@Test func hermesDecode_executeCodeIsForeign() {
    let stdin = """
    {"toolName":"execute_code","args":{"code":"print(1)"}}
    """
    #expect(codec.decode(stdin) == .foreign)
}

@Test func hermesDecode_emptyCommandIsMissingCommand() {
    #expect(codec.decode(#"{"toolName":"terminal","args":{}}"#) == .malformed(.missingCommand))
    #expect(codec.decode(#"{"toolName":"terminal","args":{"command":""}}"#) == .malformed(.missingCommand))
}

@Test func hermesDecode_notJSONIsUnreadable() {
    #expect(codec.decode("not-json") == .malformed(.unreadable))
}

@Test func hermesEncodeAllow_isEmptyExitZero() throws {
    let wire = codec.encodeAllow()
    let expected = try hermesExpected("allow-git-status")
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
    #expect(wire.stdout.isEmpty)
}

@Test func hermesEncodeDeny_matchesResetHardFixture() throws {
    let reason =
        resetHardHostDeny
    let wire = codec.encodeDeny(reason: reason)
    let expected = try hermesExpected("deny-git-reset-hard")
    #expect(wire.stdout == expected.stdout)
    #expect(wire.exitCode == expected.exit)
    #expect(wire.exitCode == 1)
    #expect(wire.stdout.hasSuffix("\n"))
    #expect(wire.stdout.contains("\"decision\":\"deny\""))
    #expect(wire.stdout.contains(reason))
}

@Test func hermesEncodeDeny_sameReasonAsPi() {
    let reason =
        resetHardHostDeny
    #expect(HermesHostCodec().encodeDeny(reason: reason).stdout
        == PiHostCodec().encodeDeny(reason: reason).stdout)
    #expect(HermesHostCodec().encodeDeny(reason: reason).exitCode == 1)
    #expect(PiHostCodec().encodeDeny(reason: reason).exitCode == 1)
}

@Test func hermesDecode_readsCwdSessionAndProposedAction() throws {
    guard case .request(let request) = codec.decode(try hermesFixture("allow-git-status.json")) else {
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
    #expect(shell.fingerprint.rawValue == "hermes:sess_1:/tmp/ws:git status")
}

@Test func hermesDecode_prefersWorkdirThenEnvelopeCwd() {
    let stdin = """
    {"toolName":"terminal","args":{"command":"git status","workdir":"/tmp/from-args"},"cwd":"/tmp/from-envelope"}
    """
    guard case .request(let request) = codec.decode(stdin) else {
        Issue.record("expected .request for workdir stdin")
        return
    }
    #expect(request.cwd?.rawValue == "/tmp/from-args")
}

@Test func hermesDecode_emptyCwdIsNil() {
    let stdin = """
    {"toolName":"terminal","cwd":"","args":{"command":"git status"}}
    """
    guard case .request(let request) = codec.decode(stdin) else {
        Issue.record("expected .request for empty cwd")
        return
    }
    #expect(request.cwd == nil)
    #expect(request.session == nil)
}

@Test func hermesDecode_taskIdWhenSessionIdMissing() {
    let stdin = """
    {"toolName":"terminal","taskId":"task_main","args":{"command":"git status"}}
    """
    guard case .request(let request) = codec.decode(stdin) else {
        Issue.record("expected .request for taskId")
        return
    }
    #expect(request.session == SessionID(validating: "task_main"))
}
