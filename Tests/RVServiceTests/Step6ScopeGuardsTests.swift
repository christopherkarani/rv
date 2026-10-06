import Foundation
import RVDomain
import RVIPC
import RVPolicy
import Testing
@testable import RVIsolation
@testable import RVService

/// Step 6 scope guards: what this step must NOT change. Persistent policy
/// mutation stays denied, the legacy draft resolve path stays denied, and
/// launch authority stays separate from action authority.
@Suite("Step 6 scope guards")
struct Step6ScopeGuardsTests {
    private func peer(role: TrustedRVComponentRole?) -> AuthenticatedPeer {
        let code = PeerCodeIdentity(
            identifier: "scope-fixture", teamIdentifier: nil,
            cdHash: Data([9]), executablePath: "/scope-fixture", isAdHoc: true,
            hardenedRuntime: true, injectionExceptions: [])
        return AuthenticatedPeer(
            evidence: PlatformPeerEvidence(
                processID: 1, effectiveUserID: 501, auditToken: Data([9]),
                codeIdentity: code, componentRole: role),
            connectionID: UUID())
    }

    private func context(role: TrustedRVComponentRole?) -> AuthenticatedRequestContext {
        let peer = peer(role: role)
        return AuthenticatedRequestContext.captured(
            peer: peer, connectionID: peer.connectionID)
    }

    private func ruleSaveMethod() -> IPCMethod {
        .ruleSave(RuleSaveParams(id: ApprovalID(rawValue: UUID().uuidString), polarity: .allow, draft: "draft"))
    }

    private func pendingResolveMethod() throws -> IPCMethod {
        .pendingResolve(PendingResolveParams(
            id: ApprovalID(rawValue: UUID().uuidString),
            decision: .allowOnce,
            fingerprint: ActionFingerprint(rawValue: "scope"),
            identity: ApprovalIdentity(
                session: try #require(SessionID(validating: "s")), agent: .opencode)))
    }

    @Test func ruleSaveDeniedForEveryRole() {
        let method = ruleSaveMethod()
        for role: TrustedRVComponentRole? in [.service, .workspaceHost, .cli, .operatorUI, nil] {
            #expect(
                ServiceMethodAuthorization.permits(method, context: context(role: role)) == false,
                "ruleSave must stay denied for \(String(describing: role))")
        }
        #expect(
            ServiceMethodAuthorization.permits(
                method, context: .unauthenticated) == false)
    }

    @Test func legacyPendingResolveDeniedForEveryRole() throws {
        let method = try pendingResolveMethod()
        for role: TrustedRVComponentRole? in [.service, .workspaceHost, .cli, .operatorUI, nil] {
            #expect(
                ServiceMethodAuthorization.permits(method, context: context(role: role)) == false,
                "legacy pendingResolve must stay denied for \(String(describing: role))")
        }
    }

    @Test func ruleSaveDispatchDeniesEvenService() async throws {
        let homeURL = try isolatedHomeDirectory()
        defer { try? FileManager.default.removeItem(at: homeURL) }
        let runtime = ServiceRuntime(
            home: try #require(HomeDirectory(validating: homeURL.path)),
            allowOnceDirectory: try isolatedAllowOnceDirectory(),
            clock: { Date() })
        let response = await runtime.dispatch(
            IPCRequest(method: ruleSaveMethod()),
            context: context(role: .service))
        #expect(response.result == .error(.authorizationDenied))
    }

    @Test func issuerEpochsAreFreshPerInstance() async {
        // Every authorizer mints its own epoch: a restarted service (a new
        // instance) can never honor the old incarnation's references.
        // Launch and action authority additionally live in compile-time
        // separate types — neither side's references even convert.
        let first = ActionApprovalAuthorizer()
        let second = ActionApprovalAuthorizer()
        #expect(first.epoch != second.epoch)
    }
}
