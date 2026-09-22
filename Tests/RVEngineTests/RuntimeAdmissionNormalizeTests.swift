import Foundation
import RVDomain
import Testing
@testable import RVEngine

@Suite("Runtime admission normalize")
struct RuntimeAdmissionNormalizeTests {
    @Test func insideTouchIsAllowedAndOutsideTouchIsDenied() throws {
        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-admission-norm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspaceURL) }
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let workspace = try #require(WorkingDirectory(validating: workspaceURL.path))
        let subject = try admissionSubject(workspace)

        let inside = try normalizeRuntimeAdmission(
            subject: subject,
            command: ShellCommand(rawValue: "touch marker")
        ).get()
        guard case .allowed = AgentAuthorization.decide(action: inside, policy: .empty) else {
            Issue.record("inside touch must be allowed")
            return
        }

        let outsideURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-admission-outside-\(UUID().uuidString)")
        let outside = try normalizeRuntimeAdmission(
            subject: subject,
            command: ShellCommand(rawValue: "touch \(outsideURL.path)")
        ).get()
        guard case .denied = AgentAuthorization.decide(action: outside, policy: .empty) else {
            Issue.record("outside touch must be denied")
            return
        }
    }

    @Test func uncoveredCommandStaysPending() throws {
        let workspace = try #require(WorkingDirectory(validating: "/tmp/rv-admission-norm"))
        let proposal = try normalizeRuntimeAdmission(
            subject: try admissionSubject(workspace),
            command: ShellCommand(rawValue: "echo hello")
        ).get()
        guard case .pending(let pending) = AgentAuthorization.decide(action: proposal, policy: .empty) else {
            Issue.record("echo must stay pending")
            return
        }
        #expect(pending.reason == .reviewAsk)
    }

    @Test func unwrapLimitedCommandProducesNoProposal() throws {
        let workspace = try #require(WorkingDirectory(validating: "/tmp/rv-admission-norm"))
        let proposal = normalizeRuntimeAdmission(
            subject: try admissionSubject(workspace),
            command: ShellCommand(rawValue: #"python3 -c "$CMD""#)
        )
        #expect(proposal == .failure(.failed))
    }
}

private func admissionSubject(_ workspace: WorkingDirectory) throws -> RuntimeAdmissionSubject {
    let plan = try compileIsolationPlan(
        IsolationCompileRequest(requested: .contained, workspace: workspace)
    ).get()
    let session = RuntimeSession(
        id: RuntimeSessionID(),
        host: .opencode,
        workspace: workspace,
        mode: plan.mode,
        backend: .seatbelt,
        startedAt: Date(timeIntervalSince1970: 0),
        child: nil
    )
    return RuntimeAdmissionSubject(session: session, policyWorkspace: workspace)
}
