import Foundation
import Testing
@testable import RVDomain

@Suite("WorkspaceSession")
struct WorkspaceSessionDomainTests {
    @Test func mintedIdentifiersDifferFromEachOther() {
        let first = WorkspaceSessionID()
        let second = WorkspaceSessionID()
        #expect(first != second)
        #expect(first.rawValue != RuntimeSessionID().rawValue || first != second)
    }

    @Test func runtimeStartsOnlyWhileTheWorkspaceIsActive() {
        var life = WorkspaceLifecycle.creating
        #expect(life.acceptsRuntime == false)
        #expect(life.transition(.beginClose) == nil)
        life = life.transition(.becameActive)!
        #expect(life.acceptsRuntime)
        #expect(life.transition(.becameActive) == nil)
        life = life.transition(.beginClose)!
        #expect(life == .closing)
        #expect(life.acceptsRuntime == false)
        #expect(life.transition(.becameActive) == nil)
        life = life.transition(.becameClosed)!
        #expect(life == .closed)
        #expect(life.transition(.beginClose) == nil)
        #expect(life.acceptsRuntime == false)
    }

    @Test func admissionEventCarriesTheParentWorkspace() throws {
        let workspace = WorkingDirectory(validating: "/tmp/rv-workspace-session")!
        let workspaceID = WorkspaceSessionID()
        let session = RuntimeSession(
            id: RuntimeSessionID(),
            workspaceSessionID: workspaceID,
            host: .opencode,
            workspace: workspace,
            backend: .seatbelt,
            startedAt: Date(timeIntervalSince1970: 10),
            child: nil
        )
        let capability = RuntimeCapability()
        var binding: RuntimeChannelBinding? = RuntimeChannelBinding(
            session: session,
            capability: capability
        )
        let frame = RuntimeActionFrame(
            version: 1,
            requestID: RuntimeActionRequestID(),
            capability: capability,
            claimedSession: RuntimeSessionClaim(validating: session.id.rawValue.uuidString)!,
            action: .shell(ShellCommand(rawValue: "echo hello"))
        )
        let decision = RuntimeAdmissionGate.submit(
            binding: &binding,
            frame: .success(frame),
            propose: { _ in .failure(.failed) }
        )
        #expect(decision.response == .evaluationFailed)
        #expect(decision.execute == nil)
        #expect(decision.event.session == session.id.rawValue.uuidString)
        #expect(decision.event.workspace == workspaceID.rawValue.uuidString)
        #expect(RuntimeAdmissionSubject(session: session, policyWorkspace: workspace).session.workspaceSessionID == workspaceID)
    }
}
