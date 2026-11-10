import Foundation
import RVDomain
import RVIPC
import RVIsolation
import Testing
@testable import RVService

@Suite("Socket peer authorization matrix")
struct SocketPeerAuthorizationTests {
    private func socketContext() -> AuthenticatedRequestContext {
        let id = UUID()
        let peer = AuthenticatedPeer.socketPeer(
            processID: 4242, effectiveUserID: 501, connectionID: id)
        return .captured(peer: peer, connectionID: id)
    }

    private func hookMethod() -> IPCMethod {
        .hookEvaluate(HookEvaluateParams(host: .pi, stdin: "{}"))
    }

    private func attestMethod() -> IPCMethod {
        .attestTTYRedemption(AttestTTYRedemptionParams(
            fingerprint: GrantFingerprint(rawValue: String(repeating: "0", count: 64)),
            cwd: wd("/tmp/ws"),
            codeHash: CodeHash(rawValue: String(repeating: "1", count: 64)),
            clientSemver: ProtocolVersion.serviceSemver
        ))
    }

    private func proposeMethod() -> IPCMethod {
        .proposeWorkspaceLaunch(ProposeLaunchParams(
            workspace: "/tmp/proj", kind: .custom, executable: "/bin/echo"))
    }

    private func evaluateMethod() -> IPCMethod {
        .evaluate(EvaluateParams(request: EvaluationRequest(
            command: ShellCommand(rawValue: "git status"), enabledPacks: dayOnePackIDs
        )))
    }

    private func packMethod() -> IPCMethod {
        .setPackEnabled(SetPackEnabledParams(id: PackID(rawValue: "core.git"), enabled: true))
    }

    @Test func socketPeerMayConsultHooks() {
        // The M3 enablement: hook consult needs a peer, not a role.
        #expect(ServiceMethodAuthorization.permits(hookMethod(), context: socketContext()))
    }

    @Test func unauthenticatedMayNotConsultHooks() {
        #expect(ServiceMethodAuthorization.permits(hookMethod(), context: .unauthenticated) == false)
    }

    @Test func socketPeerCanAskToRedeemButCannotLaunch() {
        // Allow-once redeem is admitted: the handler answers only for codes
        // rvd issued and plants only after the owner's password checks out
        // (AllowOnceOwnerPromptTests). Launch proposals stay macOS-only: no
        // code identity means no .cli role, and the matrix fails closed.
        let context = socketContext()
        #expect(ServiceMethodAuthorization.permits(attestMethod(), context: context))
        #expect(ServiceMethodAuthorization.permits(proposeMethod(), context: context) == false)
        #expect(ServiceMethodAuthorization.permits(
            .launchProposalStatus(ProposalStatusParams(operationID: UUID())),
            context: context) == false)
    }

    @Test func socketPeerHasNoControlOrEvalAuthority() {
        let context = socketContext()
        #expect(ServiceMethodAuthorization.permits(evaluateMethod(), context: context) == false)
        #expect(ServiceMethodAuthorization.permits(.pendingList, context: context) == false)
        #expect(ServiceMethodAuthorization.permits(packMethod(), context: context) == false)
    }

    @Test func socketPeerKeepsDiagnosticAccess() {
        let context = socketContext()
        #expect(ServiceMethodAuthorization.permits(.listPacks, context: context))
        #expect(ServiceMethodAuthorization.permits(.doctorSnapshot, context: context))
    }

    // The same-UID SDK socket session widens the matrix for evaluate, hook
    // consult and control reads. It must never widen owner mutations: a
    // same-user process reaching the socket could otherwise disable core packs.
    @Test func sameUIDSocketSessionNeverAdmitsOwnerMutations() {
        #expect(ServiceMethodAuthorization.requirement(for: packMethod()) == .ownerMutation)
        #expect(ServiceRuntime.sameUIDSocketSession(packMethod(), enabled: true) == false)
        #expect(ServiceRuntime.sameUIDSocketSession(attestMethod(), enabled: true) == false)
        #expect(ServiceRuntime.sameUIDSocketSession(proposeMethod(), enabled: true) == false)
    }

    @Test func sameUIDSocketSessionKeepsSDKReads() {
        #expect(ServiceRuntime.sameUIDSocketSession(evaluateMethod(), enabled: true))
        #expect(ServiceRuntime.sameUIDSocketSession(hookMethod(), enabled: true))
        #expect(ServiceRuntime.sameUIDSocketSession(.pendingList, enabled: true))
        #expect(ServiceRuntime.sameUIDSocketSession(.listPacks, enabled: true))
        #expect(ServiceRuntime.sameUIDSocketSession(evaluateMethod(), enabled: false) == false)
    }

    @Test func sameUIDSocketCannotDisableCorePack() async throws {
        let runtime = ServiceRuntime(allowOnceDirectory: try isolatedAllowOnceDirectory())
        let reply = await runtime.dispatch(
            IPCRequest(method: .setPackEnabled(
                SetPackEnabledParams(id: PackID(rawValue: "core.git"), enabled: false))),
            context: socketContext(),
            sameUIDSocket: true
        )
        guard case .error(.authorizationDenied) = reply.result else {
            Issue.record("same-UID socket must not disable core.git, got \(reply.result)")
            return
        }
    }
}
