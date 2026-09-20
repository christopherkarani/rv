import Foundation
import Testing
import RVDomain
import RVEngine
@testable import RVHooks

@Suite("OpenCode AgentRequest")
struct OpenCodeAgentRequestTests {
    private let codec = OpenCodeHostCodec()

    @Test(arguments: [
        ("allow-git-status.json", "git status"),
        ("deny-git-reset-hard.json", "git reset --hard"),
    ])
    func openCodeFixture_decodesThenBridgesToAgentRequest(
        _ file: String,
        expected: String
    ) throws {
        guard case .request(let hook) = codec.decode(try openCodeFixture(file)) else {
            Issue.record("expected .request for \(file)")
            return
        }
        guard case .shell = hook else {
            Issue.record("expected HookRequest.shell for \(file)")
            return
        }
        let process = try requireProcess(agentRequest(from: hook))
        #expect(process.host == .opencode)
        #expect(process.command.rawValue == expected)
    }

    @Test func openCodeSessionShell_bridgesToAgentRequest() throws {
        let stdin = """
        {"tool":"session.shell","args":{"command":"git reset --hard"}}
        """
        guard case .request(let hook) = codec.decode(stdin) else {
            Issue.record("expected .request for session.shell")
            return
        }
        guard case .shell = hook else {
            Issue.record("expected HookRequest.shell for session.shell")
            return
        }
        let process = try requireProcess(agentRequest(from: hook))
        #expect(process.host == .opencode)
        #expect(process.command.rawValue == "git reset --hard")
    }

    @Test func openCodeNonShell_staysForeignWithoutAgentRequest() throws {
        #expect(codec.decode(try openCodeFixture("allow-non-shell-read.json")) == .foreign)
    }

    @Test func hookRequestFile_isUnsupportedKind() {
        let request = HookRequest.file(
            host: .opencode,
            file: FileToolAction(
                kind: .read,
                path: FileToolPath(rawValue: "/tmp/rv-hook-fixture/README.md")
            ),
            cwd: nil,
            session: nil
        )
        #expect(agentRequest(from: request) == .failure(.unsupportedKind))
    }

    @Test func hookRequestSpend_isUnsupportedKind() {
        let request = HookRequest.spend(
            host: .opencode,
            command: ShellCommand(rawValue: "git reset --hard"),
            cwd: nil,
            session: nil
        )
        #expect(agentRequest(from: request) == .failure(.unsupportedKind))
    }

    @Test func openCodeHostAskSpend_doesNotBecomeAgentRequest() {
        let stdin = """
        {"tool":"bash","cwd":"/tmp/ws","args":{"command":"git reset --hard"},"hostAsk":"spend"}
        """
        guard case .request(let hook) = codec.decode(stdin) else {
            Issue.record("expected .request for hostAsk spend")
            return
        }
        guard case .spend = hook else {
            Issue.record("expected HookRequest.spend")
            return
        }
        #expect(agentRequest(from: hook) == .failure(.unsupportedKind))
    }

    @Test func openCodeGitResetHard_composesToProposedAction() throws {
        guard case .request(let hook) = codec.decode(
            try openCodeFixture("deny-git-reset-hard.json")
        ) else {
            Issue.record("expected .request for deny-git-reset-hard.json")
            return
        }
        let request = try agentRequest(from: hook).get()
        let result: Result<ProposedAction, AgentNormalizationError> =
            normalizeAgentRequest(request)
        let action = try result.get()
        #expect(action.gitAction == .reset(mode: .hard, target: nil))
        #expect(action.effects.kinds.contains(.workingTreeDiscard))
        guard case .shell = action else {
            Issue.record("composition must produce ProposedAction, not an executable type")
            return
        }
    }
}

private func openCodeFixture(_ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/opencode/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
}

private enum AgentRequestBridgeTestFailure: Error {
    case expectedProcess
}

private func requireProcess(
    _ result: Result<AgentRequest, AgentRequestValidationError>,
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> AgentProcessRequest {
    switch result {
    case .success(let request):
        guard case .process(let process) = request else {
            Issue.record("expected AgentRequest.process", sourceLocation: sourceLocation)
            throw AgentRequestBridgeTestFailure.expectedProcess
        }
        return process
    case .failure(let error):
        Issue.record("expected AgentRequest, got \(error)", sourceLocation: sourceLocation)
        throw error
    }
}
