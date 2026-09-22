import Foundation
import Testing
@testable import RVDomain

@Suite("RuntimeAdmission")
struct RuntimeAdmissionTests {
    @Test func extraWorkspaceKeyIsMalformedAndDoesNotPropose() throws {
        let fixture = AdmissionFixture()
        let body = Data(
            """
            {"v":1,"id":"\(UUID().uuidString)","capability":"\(fixture.capability.rawValue)","session":"\(fixture.session.id.rawValue.uuidString)","command":"touch marker","workspace":"/tmp/other"}
            """.utf8
        )
        var proposals = 0
        var binding: RuntimeChannelBinding? = fixture.binding
        let decision = RuntimeAdmissionGate.submit(binding: &binding, frame: .failure(.malformed)) { _ in
            proposals += 1
            return .failure(.failed)
        }
        _ = body
        let decoded = RuntimeAdmissionCodec.decodeRequest(body)
        #expect(decoded == .failure(.malformed) || decoded.isFailure)
        let wired = RuntimeAdmissionGate.submit(binding: &binding, frame: decoded) { _ in
            proposals += 1
            return .failure(.failed)
        }
        #expect(proposals == 0)
        #expect(decision.execute == nil)
        #expect(wired.execute == nil)
        if case .rejected(.malformed) = wired.response {
        } else {
            Issue.record("extra key must be rejected, got \(wired.response)")
        }
    }

    @Test func sessionIDWithoutChannelDoesNotAuthorize() {
        let fixture = AdmissionFixture()
        var binding: RuntimeChannelBinding?
        var proposed = false
        let decision = RuntimeAdmissionGate.submit(
            binding: &binding,
            frame: .success(fixture.frame(command: "touch marker"))
        ) { _ in
            proposed = true
            return .success(fixture.inside)
        }
        #expect(proposed == false)
        #expect(decision.execute == nil)
        #expect(decision.response == .rejected(.unknownSession))
        #expect(decision.event.executionAttempted == false)
    }

    @Test func wrongCapabilityDoesNotPropose() {
        let fixture = AdmissionFixture()
        var binding: RuntimeChannelBinding? = fixture.binding
        var proposed = false
        let decision = RuntimeAdmissionGate.submit(
            binding: &binding,
            frame: .success(fixture.frame(command: "touch marker", capability: RuntimeCapability()))
        ) { _ in
            proposed = true
            return .success(fixture.inside)
        }
        #expect(proposed == false)
        #expect(decision.execute == nil)
        #expect(decision.response == .rejected(.invalidCapability))
    }

    @Test func otherRuntimeSessionIsRejected() {
        let fixture = AdmissionFixture()
        let other = UUID()
        var binding: RuntimeChannelBinding? = fixture.binding
        let decision = RuntimeAdmissionGate.submit(
            binding: &binding,
            frame: .success(fixture.frame(command: "touch marker", claim: other))
        ) { _ in
            .success(fixture.inside)
        }
        #expect(decision.execute == nil)
        #expect(decision.response == .rejected(.impersonation))
        #expect(decision.event.session == fixture.session.id.rawValue.uuidString)
    }

    @Test func finishedBindingDoesNotAuthorize() {
        let fixture = AdmissionFixture()
        var binding: RuntimeChannelBinding? = fixture.binding.finished()
        let decision = RuntimeAdmissionGate.submit(
            binding: &binding,
            frame: .success(fixture.frame(command: "touch marker"))
        ) { _ in
            .success(fixture.inside)
        }
        #expect(decision.execute == nil)
        #expect(decision.response == .rejected(.inactiveSession))
    }

    @Test func allowIsOneShotForTheSameRequestAndTheSameCommand() {
        let fixture = AdmissionFixture()
        var binding: RuntimeChannelBinding? = fixture.binding
        let firstID = UUID()
        let first = RuntimeAdmissionGate.submit(
            binding: &binding,
            frame: .success(fixture.frame(command: "touch marker", id: firstID))
        ) { _ in
            .success(fixture.inside)
        }
        #expect(first.execute != nil)
        let replay = RuntimeAdmissionGate.submit(
            binding: &binding,
            frame: .success(fixture.frame(command: "touch marker", id: firstID))
        ) { _ in
            .success(fixture.inside)
        }
        #expect(replay.execute == nil)
        #expect(replay.response == .rejected(.replay))
        let sameCommand = RuntimeAdmissionGate.submit(
            binding: &binding,
            frame: .success(fixture.frame(command: "touch marker", id: UUID()))
        ) { _ in
            .success(fixture.inside)
        }
        #expect(sameCommand.execute == nil)
        #expect(sameCommand.response == .rejected(.replay))
    }

    @Test func deniedProposalDoesNotExecute() {
        let fixture = AdmissionFixture()
        var binding: RuntimeChannelBinding? = fixture.binding
        let decision = RuntimeAdmissionGate.submit(
            binding: &binding,
            frame: .success(fixture.frame(command: "touch /tmp/outside"))
        ) { _ in
            .success(fixture.outside)
        }
        #expect(decision.execute == nil)
        if case .denied(let deny) = decision.response {
            #expect(deny.ruleID == ActionPolicyEngine.Builtin.outsideRepository.ruleID)
        } else {
            Issue.record("outside write must be denied, got \(decision.response)")
        }
    }

    @Test func pendingWithoutApprovalDoesNotExecute() {
        let fixture = AdmissionFixture()
        var binding: RuntimeChannelBinding? = fixture.binding
        let decision = RuntimeAdmissionGate.submit(
            binding: &binding,
            frame: .success(fixture.frame(command: "echo hello"))
        ) { _ in
            .success(fixture.uncovered)
        }
        #expect(decision.execute == nil)
        #expect(decision.response == .pending(.reviewAsk))
        #expect(decision.event.executionAttempted == false)
    }

    @Test func allowOnceApprovalCanExecuteAndChannelFailureCannot() {
        let fixture = AdmissionFixture()
        var binding: RuntimeChannelBinding? = fixture.binding
        let allowed = RuntimeAdmissionGate.submit(
            binding: &binding,
            frame: .success(fixture.frame(command: "echo hello")),
            approvalFor: { _ in .success(.allowOnce) }
        ) { _ in
            .success(fixture.uncovered)
        }
        #expect(allowed.execute != nil)

        var again: RuntimeChannelBinding? = fixture.binding
        let refused = RuntimeAdmissionGate.submit(
            binding: &again,
            frame: .success(fixture.frame(command: "echo hello")),
            approvalFor: { _ in .failure(.approvalUnavailable) }
        ) { _ in
            .success(fixture.uncovered)
        }
        #expect(refused.execute == nil)
        #expect(refused.response == .approvalUnavailable)

        var rule: RuntimeChannelBinding? = fixture.binding
        let created = RuntimeAdmissionGate.submit(
            binding: &rule,
            frame: .success(fixture.frame(command: "echo hello")),
            approvalFor: { _ in .success(.createRule) }
        ) { _ in
            .success(fixture.uncovered)
        }
        #expect(created.execute == nil)
        #expect(created.response == .approvalUnavailable)
    }

    @Test func evaluationFailureDoesNotExecute() {
        let fixture = AdmissionFixture()
        var binding: RuntimeChannelBinding? = fixture.binding
        let decision = RuntimeAdmissionGate.submit(
            binding: &binding,
            frame: .success(fixture.frame(command: "python3 -c \"$CMD\""))
        ) { _ in
            .failure(.failed)
        }
        #expect(decision.execute == nil)
        #expect(decision.response == .evaluationFailed)
        #expect(decision.event.executionAttempted == false)
    }
}

private extension Result where Failure == RuntimeAdmissionDecodeError {
    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}

private struct AdmissionFixture {
    let workspace: WorkingDirectory
    let session: RuntimeSession
    let capability: RuntimeCapability
    let binding: RuntimeChannelBinding
    let inside: ProposedAction
    let outside: ProposedAction
    let uncovered: ProposedAction

    init() {
        let workspace = WorkingDirectory(validating: "/tmp/rv-admission")!
        let session = RuntimeSession(
            id: RuntimeSessionID(),
            host: .opencode,
            workspace: workspace,
            mode: .contained(IsolationGuarantees.firstSliceContained(workspace: workspace)),
            backend: .seatbelt,
            startedAt: Date(timeIntervalSince1970: 0),
            child: nil
        )
        let capability = RuntimeCapability()
        self.workspace = workspace
        self.session = session
        self.capability = capability
        binding = RuntimeChannelBinding(session: session, capability: capability)
        inside = Self.shell(
            command: "touch marker",
            workspace: workspace,
            session: session,
            scope: .insideRepository,
            effects: [.filesystemCreate]
        )
        outside = Self.shell(
            command: "touch /tmp/outside",
            workspace: workspace,
            session: session,
            scope: .outsideRepository,
            effects: [.filesystemOverwrite, .outsideRepositoryMutation]
        )
        uncovered = ProposedAction.shell(
            ShellAction(
                fingerprint: ActionFingerprint(rawValue: "runtime:uncovered"),
                effects: ActionEffects(),
                resources: ActionResources(),
                scope: ActionScope(workingDirectory: workspace),
                supportingCommand: ShellCommand(rawValue: "echo hello")
            )
        )
    }

    func frame(
        command: String,
        capability: RuntimeCapability? = nil,
        claim: UUID? = nil,
        id: UUID = UUID()
    ) -> RuntimeActionFrame {
        RuntimeActionFrame(
            version: 1,
            requestID: RuntimeActionRequestID(validating: id.uuidString)!,
            capability: capability ?? self.capability,
            claimedSession: RuntimeSessionClaim(validating: (claim ?? session.id.rawValue).uuidString)!,
            command: ShellCommand(rawValue: command)
        )
    }

    private static func shell(
        command: String,
        workspace: WorkingDirectory,
        session: RuntimeSession,
        scope: FilesystemScope,
        effects: [ActionEffectKind]
    ) -> ProposedAction {
        let path = scope == .insideRepository ? "\(workspace.rawValue)/marker" : "/tmp/outside"
        let target = FilesystemTarget(
            apparent: path,
            canonical: path,
            scope: scope,
            kind: .unknown
        )
        return .shell(
            ShellAction(
                fingerprint: ActionFingerprint(
                    rawValue: "runtime:\(session.id.rawValue.uuidString):\(workspace.rawValue):\(command)"
                ),
                effects: ActionEffects(kinds: effects),
                resources: ActionResources(path: path, filesystemScope: scope, resourceKind: .unknown),
                scope: ActionScope(workingDirectory: workspace),
                supportingCommand: ShellCommand(rawValue: command),
                filesystemAction: .create(targets: [target])
            )
        )
    }
}
