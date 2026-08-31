import Testing
import RVDomain

@Test func actionFingerprint_make_nilSessionAndCwdUseEmptySlots() {
    let fingerprint = ActionFingerprint.make(
        host: .codex,
        session: nil,
        cwd: nil,
        command: ShellCommand(rawValue: "git status")
    )
    #expect(fingerprint.rawValue == "codex:::git status")
}

@Test func actionFingerprint_make_nilSessionKeepsCwdSlot() throws {
    let cwd = try #require(WorkingDirectory(validating: "/tmp/ws"))
    let fingerprint = ActionFingerprint.make(
        host: .codex,
        session: nil,
        cwd: cwd,
        command: ShellCommand(rawValue: "git status")
    )
    #expect(fingerprint.rawValue == "codex::/tmp/ws:git status")
}

@Test func actionFingerprint_make_nilCwdKeepsSessionSlot() throws {
    let session = try #require(SessionID(validating: "s1"))
    let fingerprint = ActionFingerprint.make(
        host: .codex,
        session: session,
        cwd: nil,
        command: ShellCommand(rawValue: "git status")
    )
    #expect(fingerprint.rawValue == "codex:s1::git status")
}

@Test(arguments: [
    (HookHost.grok, "grok:s1:/tmp/ws:git status"),
    (HookHost.pi, "pi:s1:/tmp/ws:git status"),
    (HookHost.opencode, "opencode:s1:/tmp/ws:git status"),
    (HookHost.codex, "codex:s1:/tmp/ws:git status"),
    (HookHost.cursor, "cursor:s1:/tmp/ws:git status"),
])
func actionFingerprint_make_matchesHostDoorSpelling(_ host: HookHost, expected: String) throws {
    let session = try #require(SessionID(validating: "s1"))
    let cwd = try #require(WorkingDirectory(validating: "/tmp/ws"))
    let fingerprint = ActionFingerprint.make(
        host: host,
        session: session,
        cwd: cwd,
        command: ShellCommand(rawValue: "git status")
    )
    #expect(fingerprint.rawValue == expected)
}
