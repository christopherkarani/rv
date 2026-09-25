import Testing
import RVDomain
@testable import RVHooks

@Test func decodedPayload_shellBuildsShellRequest() {
    let cwd = wd("/tmp/ws")
    let session = SessionID(validating: "sess_1")
    #expect(
        HookRequest.decoded(
            host: .pi,
            cwd: cwd,
            session: session,
            payload: .shell(command: "git status", ask: nil)
        )
            == .request(
                .shell(
                    host: .pi,
                    command: ShellCommand(rawValue: "git status"),
                    cwd: cwd,
                    session: session
                )
            )
    )
}

@Test func decodedPayload_shellWithSpendAskBuildsSpendRequest() {
    #expect(
        HookRequest.decoded(
            host: .pi,
            cwd: nil,
            session: nil,
            payload: .shell(command: "git reset --hard", ask: .spend)
        )
            == .request(
                .spend(
                    host: .pi,
                    command: ShellCommand(rawValue: "git reset --hard"),
                    cwd: nil,
                    session: nil
                )
            )
    )
}

@Test func decodedPayload_shellWithoutCommandIsMissingCommand() {
    #expect(
        HookRequest.decoded(
            host: .pi,
            cwd: nil,
            session: nil,
            payload: .shell(command: nil, ask: nil)
        ) == .malformed(.missingCommand)
    )
    #expect(
        HookRequest.decoded(
            host: .pi,
            cwd: nil,
            session: nil,
            payload: .shell(command: "", ask: nil)
        ) == .malformed(.missingCommand)
    )
}

@Test func decodedPayload_spendWithoutCommandIsMissingCommand() {
    #expect(
        HookRequest.decoded(
            host: .pi,
            cwd: nil,
            session: nil,
            payload: .shell(command: nil, ask: .spend)
        ) == .malformed(.missingCommand)
    )
}

@Test func decodedPayload_fileBuildsFileRequest() {
    let cwd = wd("/tmp/ws")
    let session = SessionID(validating: "sess_1")
    let file = FileToolAction(
        kind: .read,
        path: FileToolPath(rawValue: "/tmp/rv-oracle/.env")
    )
    #expect(
        HookRequest.decoded(
            host: .claude,
            cwd: cwd,
            session: session,
            payload: .file(file)
        )
            == .request(
                .file(host: .claude, file: file, cwd: cwd, session: session)
            )
    )
}
