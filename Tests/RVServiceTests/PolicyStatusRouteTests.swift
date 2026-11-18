import Foundation
import Testing
import RVDomain
import RVIPC
import RVPolicy
@testable import RVService

/// `policyStatus`: rvd reports the typed-policy load its evaluation runs,
/// for its own HOME and the caller's cwd.
@Suite("PolicyStatusRoute")
struct PolicyStatusRouteTests {
    @Test func cleanLoad_isReportedLoadedFromRvdsHome() async throws {
        try await withRuntime { runtime, home, workspace in
            let document = PolicyDocument(rules: [Self.denyReset])
            try TypedRuleStore(baseDirectory: RVPolicyPaths.configDirectory(home: home)).saveMachine(document)

            let status = try await Self.status(runtime, cwd: workspace)

            #expect(status.state == .loaded)
            #expect(status.machine?.hash == PolicyRevisionIdentity.hash(document))
            #expect(status.configDirectory == RVPolicyPaths.configDirectory(home: home).path)
            #expect(status.workspace == workspace.path)
        }
    }

    /// The route and evaluation read the same files the same way: a corrupt
    /// repo policy is `failed` here and a `typed-rules-invalid` deny there.
    @Test func corruptRepoPolicy_isFailed_andEvaluationDeniesTheSame() async throws {
        try await withRuntime { runtime, _, workspace in
            let url = TypedRuleStore.repoFileURL(workspace: workspace)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "[[rule]\nbroken".write(to: url, atomically: true, encoding: .utf8)

            let status = try await Self.status(runtime, cwd: workspace)
            #expect(status.state == .failed)
            #expect(status.failure == .repoInvalid)

            let reply = await runtime.evaluate(
                EvaluationRequest(command: ShellCommand(rawValue: "ls"), enabledPacks: dayOnePackIDs),
                cwd: WorkingDirectory(validating: workspace.path))
            guard case .deny(let deny) = reply.result.decision else {
                Issue.record("a failed load must deny, got \(reply.result.decision)")
                return
            }
            #expect(deny.ruleID == BuiltinRule.typedRulesInvalid.ruleID)
        }
    }

    @Test func isReadOnlyDiagnostic_noOwnerAuthNeeded() {
        let method = IPCMethod.policyStatus(PolicyStatusParams(cwd: nil))
        #expect(ServiceMethodAuthorization.requirement(for: method) == .diagnostic)
        #expect(ServiceMethodAuthorization.permits(method, context: .unauthenticated))
    }

    // MARK: Helpers

    private static let denyReset = PolicyDocumentRule(
        id: RuleID(rawValue: "typed.git:no-reset")!, verdict: .deny, predicate: .gitReset(mode: nil))

    private static func status(_ runtime: ServiceRuntime, cwd: URL) async throws -> PolicyLoadStatus {
        let response = await runtime.dispatch(IPCRequest(
            method: .policyStatus(PolicyStatusParams(cwd: WorkingDirectory(validating: cwd.path)))))
        guard case .policyStatus(let reply) = response.result else {
            throw StatusRouteError.unexpected("\(response.result)")
        }
        return reply.status
    }

    private enum StatusRouteError: Error { case unexpected(String) }

    private func withRuntime(
        _ body: (ServiceRuntime, HomeDirectory, URL) async throws -> Void
    ) async throws {
        let homeURL = try isolatedHomeDirectory()
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-status-ws-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: homeURL)
            try? FileManager.default.removeItem(at: workspace)
        }
        let home = try #require(HomeDirectory(validating: homeURL.path))
        let runtime = ServiceRuntime(home: home, allowOnceDirectory: try isolatedAllowOnceDirectory())
        try await body(runtime, home, workspace)
    }
}
