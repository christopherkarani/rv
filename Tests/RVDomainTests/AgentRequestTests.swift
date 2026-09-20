import Foundation
import Testing
@testable import RVDomain

@Suite("AgentRequest")
struct AgentRequestTests {
    @Test func validOpenCodeShapedProcess_becomesAgentRequest() throws {
        let raw = RawAgentRequest.process(
            RawAgentProcessRequest(
                host: .opencode,
                command: "git status",
                workingDirectory: "/tmp/ws",
                session: "sess_oc"
            )
        )
        let process = try requireProcess(AgentRequest.validate(raw))
        #expect(process.host == .opencode)
        #expect(process.command.rawValue == "git status")
        #expect(process.workingDirectory?.rawValue == "/tmp/ws")
        #expect(process.session?.rawValue == "sess_oc")
    }

    @Test(arguments: [
        Optional<String>.none,
        "",
        " ",
        "\t",
        "\n",
        "  \n\t  ",
    ])
    func missingOrWhitespaceCommand_failsClosed(_ command: String?) {
        let result = AgentRequest.validate(
            .process(
                RawAgentProcessRequest(
                    host: .opencode,
                    command: command,
                    workingDirectory: "/tmp/ws",
                    session: "sess_oc"
                )
            )
        )
        #expect(result == .failure(.missingCommand))
    }

    @Test func emptyCwdAndSessionStrings_becomeNil() throws {
        let process = try requireProcess(
            AgentRequest.validate(
                .process(
                    RawAgentProcessRequest(
                        host: .opencode,
                        command: "echo hello",
                        workingDirectory: "",
                        session: ""
                    )
                )
            )
        )
        #expect(process.command.rawValue == "echo hello")
        #expect(process.workingDirectory == nil)
        #expect(process.session == nil)
    }

    @Test func nilCwdAndSession_remainAbsent() throws {
        let process = try requireProcess(
            AgentRequest.validate(
                host: .opencode,
                command: "echo hello",
                workingDirectory: nil,
                session: nil
            )
        )
        #expect(process.workingDirectory == nil)
        #expect(process.session == nil)
    }

    @Test func commandOneByteOverCap_isCommandTooLarge() {
        let oversized = String(repeating: "a", count: AgentRequestLimits.maxCommandUTF8Count + 1)
        let result = AgentRequest.validate(
            .process(
                RawAgentProcessRequest(host: .opencode, command: oversized)
            )
        )
        #expect(result == .failure(.commandTooLarge))
    }

    @Test func commandAtCap_isValidProcess() throws {
        let atCap = String(repeating: "a", count: AgentRequestLimits.maxCommandUTF8Count)
        let process = try requireProcess(
            AgentRequest.validate(
                .process(RawAgentProcessRequest(host: .opencode, command: atCap))
            )
        )
        #expect(process.command.rawValue.utf8.count == AgentRequestLimits.maxCommandUTF8Count)
    }

    @Test func typedHookValues_validateTheSameWay() throws {
        let command = ShellCommand(rawValue: "git reset --hard")
        let cwd = try #require(WorkingDirectory(validating: "/tmp/ws"))
        let session = try #require(SessionID(validating: "sess_oc"))
        let process = try requireProcess(
            AgentRequest.validate(
                host: .opencode,
                command: command,
                workingDirectory: cwd,
                session: session
            )
        )
        #expect(process.host == .opencode)
        #expect(process.command == command)
        #expect(process.workingDirectory == cwd)
        #expect(process.session == session)
    }

    @Test func typedWhitespaceCommand_isMissingCommand() {
        #expect(
            AgentRequest.validate(
                host: .opencode,
                command: ShellCommand(rawValue: "   "),
                workingDirectory: nil,
                session: nil
            ) == .failure(.missingCommand)
        )
    }

    @Test func agentProcessRequest_internalInitIsTestSeamOnly() {
        let command = ShellCommand(rawValue: "git status")
        let built = AgentProcessRequest(
            host: .opencode,
            command: command,
            workingDirectory: nil,
            session: nil
        )
        guard case .process(let process) = AgentRequest.process(built) else {
            Issue.record("expected AgentRequest.process")
            return
        }
        #expect(process.host == .opencode)
        #expect(process.command == command)
    }

    @Test func rawAndValidatedRequests_onlyInhabitProcess() throws {
        let raw = RawAgentRequest.process(
            RawAgentProcessRequest(host: .opencode, command: "echo hi")
        )
        switch raw {
        case .process:
            break
        }
        switch try AgentRequest.validate(raw).get() {
        case .process:
            break
        }
    }

    @Test func process_gitResetHard_usesHostDoorFingerprintAndEffects() throws {
        let command = ShellCommand(rawValue: "git reset --hard")
        let cwd = try #require(WorkingDirectory(validating: "/tmp/ws"))
        let session = try #require(SessionID(validating: "sess_oc"))
        let analysis = SemanticAnalysis.git(.reset(mode: .hard, target: nil))
        let result = ProposedAction.process(
            host: .opencode,
            session: session,
            cwd: cwd,
            command: command,
            analysis: analysis
        )
        let action = try result.get()
        #expect(action.gitAction == .reset(mode: .hard, target: nil))
        #expect(action.effects.kinds.contains(.workingTreeDiscard))
        #expect(action.scope.workingDirectory == cwd)
        #expect(action.supportingCommand == command)
        #expect(
            action.fingerprint
                == ActionFingerprint.make(
                    host: .opencode,
                    session: session,
                    cwd: cwd,
                    command: command
                )
        )
        #expect(action.fingerprint.rawValue.hasPrefix("shell:git") == false)
        guard case .shell(let shell) = action else {
            Issue.record("expected ProposedAction.shell")
            return
        }
        #expect(shell.filesystemAction == nil)
    }

    @Test func process_wrappedGit_usesInnermost() throws {
        let command = ShellCommand(rawValue: "bash -c 'git reset --hard'")
        let analysis = SemanticAnalysis.git(.reset(mode: .hard, target: nil)).wrapping([.bash])
        let action = try ProposedAction.process(
            host: .opencode,
            session: nil,
            cwd: nil,
            command: command,
            analysis: analysis
        ).get()
        #expect(action.gitAction == .reset(mode: .hard, target: nil))
        #expect(action.effects.kinds.contains(.workingTreeDiscard))
    }

    @Test func process_unknown_isEmptyEffectShellProposal() throws {
        let command = ShellCommand(rawValue: "echo hello")
        let action = try ProposedAction.process(
            host: .opencode,
            session: nil,
            cwd: nil,
            command: command,
            analysis: .unknown
        ).get()
        #expect(action.gitAction == nil)
        #expect(action.effects.kinds.isEmpty)
        #expect(action.supportingCommand == command)
        guard case .shell(let shell) = action else {
            Issue.record("expected ProposedAction.shell")
            return
        }
        #expect(shell.analysis == nil)
        #expect(shell.filesystemAction == nil)
    }

    @Test func process_filesystem_copiesEffectsAndResources() throws {
        let command = ShellCommand(rawValue: "rm Sources/Foo.swift")
        let cwd = try #require(WorkingDirectory(validating: "/repo"))
        let filesystem = FilesystemAction.delete(
            targets: [
                FilesystemTarget(
                    apparent: "Sources/Foo.swift",
                    canonical: "/repo/Sources/Foo.swift",
                    scope: .insideRepository,
                    kind: .sourceCode
                ),
            ],
            recursive: false,
            force: false
        )
        let action = try ProposedAction.process(
            host: .grok,
            session: nil,
            cwd: cwd,
            command: command,
            analysis: .filesystem(filesystem)
        ).get()
        #expect(action.effects == filesystem.effects)
        #expect(action.resources == filesystem.resources)
        #expect(action.fingerprint.rawValue.hasPrefix("shell:fs") == false)
        guard case .shell(let shell) = action else {
            Issue.record("expected ProposedAction.shell")
            return
        }
        #expect(shell.filesystemAction == filesystem)
        #expect(shell.gitAction == nil)
    }

    @Test func process_unwrapLimited_producesNoProposedAction() {
        let command = ShellCommand(rawValue: "bash -c git reset --hard")
        #expect(
            ProposedAction.process(
                host: .opencode,
                session: nil,
                cwd: nil,
                command: command,
                analysis: .unwrapLimited
            ) == .failure(.unwrapLimited)
        )
    }

    @Test func pendingAction_stillDropsUnwrapLimitedOnStoredAction() {
        let command = ShellCommand(rawValue: "bash -c git reset --hard")
        let result = EvaluationResult(
            outcome: .plain,
            matchingView: MatchingView(command.rawValue),
            analysis: .unwrapLimited
        )
        let action = result.pendingAction(
            host: .opencode,
            session: nil,
            cwd: nil,
            command: command
        )
        #expect(action.effects.kinds.isEmpty)
        #expect(action.gitAction == nil)
        #expect(
            action.fingerprint
                == ActionFingerprint.make(
                    host: .opencode,
                    session: nil,
                    cwd: nil,
                    command: command
                )
        )
        guard case .shell(let shell) = action else {
            Issue.record("expected hook pendingAction to remain a shell proposal")
            return
        }
        #expect(shell.analysis == nil)
    }
}

private enum AgentRequestTestFailure: Error {
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
            throw AgentRequestTestFailure.expectedProcess
        }
        return process
    case .failure(let error):
        Issue.record("expected validation success, got \(error)", sourceLocation: sourceLocation)
        throw error
    }
}
