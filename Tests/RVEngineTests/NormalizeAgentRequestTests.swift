import Testing
import RVDomain
@testable import RVEngine

@Suite("NormalizeAgentRequest")
struct NormalizeAgentRequestTests {
    @Test func gitResetHard_isResetHardProposalWithWorkingTreeDiscard() throws {
        let request = try processRequest("git reset --hard")
        let action = try requireProposedAction(normalizeAgentRequest(request))
        #expect(action.gitAction == .reset(mode: .hard, target: nil))
        #expect(action.effects.kinds.contains(.workingTreeDiscard))
        #expect(action.supportingCommand?.rawValue == "git reset --hard")
        #expect(
            action.fingerprint
                == ActionFingerprint.make(
                    host: .opencode,
                    session: nil,
                    cwd: nil,
                    command: ShellCommand(rawValue: "git reset --hard")
                )
        )
        #expect(action.fingerprint.rawValue.hasPrefix("shell:git") == false)
        guard case .shell = action else {
            Issue.record("expected ProposedAction.shell, not an executable type")
            return
        }
    }

    @Test(arguments: ["echo hello", "git status"])
    func benignCommand_isUnauthorizedShellProposal(_ command: String) throws {
        let request = try processRequest(command)
        let action = try requireProposedAction(normalizeAgentRequest(request))
        guard case .shell(let shell) = action else {
            Issue.record("expected ProposedAction.shell for \(command)")
            return
        }
        #expect(shell.gitAction == nil, "do not invent git analysis the analyzer does not emit")
        #expect(shell.filesystemAction == nil)
        #expect(shell.analysis == nil)
        #expect(shell.effects.kinds.isEmpty)
        #expect(shell.supportingCommand?.rawValue == command)
        #expect(
            action.fingerprint
                == ActionFingerprint.make(
                    host: .opencode,
                    session: nil,
                    cwd: nil,
                    command: ShellCommand(rawValue: command)
                )
        )
    }

    @Test func protectedPathDelete_carriesFilesystemAnalysis() throws {
        let command = "env -C /tmp/.ssh rm config"
        let action = try requireProposedAction(normalizeAgentRequest(try processRequest(command)))
        guard case .shell(let shell) = action else {
            Issue.record("expected ProposedAction.shell")
            return
        }
        #expect(shell.gitAction == nil)
        #expect(
            shell.filesystemAction?.primaryTarget?.scope
                == .protectedPath(SecretPathMatch(pattern: "home-ssh", category: .ssh))
        )
        #expect(shell.filesystemAction?.primaryTarget?.canonical == "/tmp/.ssh/config")
        #expect(shell.effects == shell.filesystemAction?.effects)
        #expect(shell.resources == shell.filesystemAction?.resources)
    }

    @Test(arguments: [
        "bash -c git reset --hard",
        "zsh -c $CMD",
    ])
    func unwrapLimited_producesNoProposedAction(_ command: String) throws {
        let request = try processRequest(command)
        #expect(normalizeAgentRequest(request) == .failure(.unwrapLimited))
    }

    @Test func quotedBashDashC_peelsWrapperToGitReset() throws {
        let command = "bash -c 'git reset --hard'"
        let action = try requireProposedAction(normalizeAgentRequest(try processRequest(command)))
        #expect(action.gitAction == .reset(mode: .hard, target: nil))
        #expect(action.effects.kinds.contains(.workingTreeDiscard))
        #expect(action.supportingCommand?.rawValue == command)
        #expect(
            action.fingerprint
                == ActionFingerprint.make(
                    host: .opencode,
                    session: nil,
                    cwd: nil,
                    command: ShellCommand(rawValue: command)
                )
        )
    }

    @Test func agentRequestLimits_matchEvaluateCommandByteCap() {
        #expect(AgentRequestLimits.maxCommandUTF8Count == commandByteCap)
    }

    @Test func normalize_doesNotRequirePacks() throws {
        let result: Result<ProposedAction, AgentNormalizationError> =
            normalizeAgentRequest(try processRequest("echo hello"))
        guard case .success(.shell) = result else {
            Issue.record("normalize must return ProposedAction without packs or an executable type")
            return
        }
    }
}

private func processRequest(
    _ command: String,
    host: HookHost = .opencode
) throws -> AgentRequest {
    try AgentRequest.validate(
        .process(RawAgentProcessRequest(host: host, command: command))
    ).get()
}

private func requireProposedAction(
    _ result: Result<ProposedAction, AgentNormalizationError>,
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> ProposedAction {
    switch result {
    case .success(let action):
        return action
    case .failure(let error):
        Issue.record("expected ProposedAction, got \(error)", sourceLocation: sourceLocation)
        throw error
    }
}
