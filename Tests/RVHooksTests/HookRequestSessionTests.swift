import Testing
import RVDomain
@testable import RVHooks

@Test func hookRequest_emptySessionCannotInhabit() {
    let request = HookRequest(
        host: .pi,
        command: ShellCommand(rawValue: "git status"),
        session: SessionID(validating: "")
    )
    #expect(request.session == nil)
}

@Test func proposedAction_usesActionFingerprintMake() throws {
    let session = try #require(SessionID(validating: "s1"))
    let cwd = try #require(WorkingDirectory(validating: "/repo"))
    let command = ShellCommand(rawValue: "git status")
    let request = HookRequest(
        host: .codex,
        command: command,
        cwd: cwd,
        session: session
    )
    #expect(
        CodexHostCodec().proposedAction(from: request).fingerprint
            == ActionFingerprint.make(
                host: .codex,
                session: session,
                cwd: cwd,
                command: command
            )
    )
    let cursorRequest = HookRequest(
        host: .cursor,
        command: command,
        cwd: cwd,
        session: session
    )
    #expect(
        CursorHostCodec().proposedAction(from: cursorRequest).fingerprint
            == ActionFingerprint.make(
                host: .cursor,
                session: session,
                cwd: cwd,
                command: command
            )
    )
}
