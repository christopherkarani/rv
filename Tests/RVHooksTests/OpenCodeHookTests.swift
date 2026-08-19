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
    let request = codec.decode(try openCodeFixture(file))
    #expect(request.host == .opencode)
    #expect(request.command?.rawValue == expected)
}

@Test func openCodeDecode_nonShellIsNoOp() throws {
    let request = codec.decode(try openCodeFixture("allow-non-shell-read.json"))
    #expect(request.host == .opencode)
    #expect(request.command == nil)
}

@Test func openCodeDecode_emptyCommandIsNoOp() {
    #expect(codec.decode(#"{"tool":"bash","args":{}}"#).command == nil)
    #expect(codec.decode(#"{"tool":"bash","args":{"command":""}}"#).command == nil)
    #expect(codec.decode("not-json").command == nil)
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
