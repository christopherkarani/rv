import Foundation
import RVDomain
import RVIPC
import Testing
@testable import RVIsolation
@testable import RVService

/// IPC dispatch wiring for the ceremony methods: authorization gates plus
/// error mapping. The ceremony itself is covered by
/// `WorkspaceOperatorCeremonyTests`; these pin the dispatch contract.
@Suite("Operator ceremony dispatch")
struct OperatorCeremonyDispatchTests {
    private func peer(role: TrustedRVComponentRole?) -> AuthenticatedPeer {
        let code = PeerCodeIdentity(identifier: "dispatch-fixture", teamIdentifier: nil,
            cdHash: Data([3]), executablePath: "/dispatch-fixture", isAdHoc: true,
            hardenedRuntime: true, injectionExceptions: [])
        return AuthenticatedPeer(evidence: PlatformPeerEvidence(processID: 1,
            effectiveUserID: 501, auditToken: Data([3]), codeIdentity: code,
            componentRole: role), connectionID: UUID())
    }

    private func context(role: TrustedRVComponentRole?) -> AuthenticatedRequestContext {
        if let role {
            return .captured(peer: peer(role: role), connectionID: UUID())
        }
        return .unauthenticated
    }

    private func params() -> ProposeLaunchParams {
        ProposeLaunchParams(
            workspace: "/tmp/proj", hostID: UUID(), workspaceSessionID: UUID(),
            kind: "custom", executable: "/bin/echo",
            expectedDigest: String(repeating: "a", count: 64))
    }

    @Test func unauthenticatedProposeDenied() async {
        let runtime = ServiceRuntime()
        let response = await runtime.dispatch(
            IPCRequest(method: .proposeWorkspaceLaunch(params())),
            context: .unauthenticated)
        #expect(response.result == .error(.authorizationDenied))
    }

    @Test func cliProposeWithoutHostFailsUnknownHost() async {
        let runtime = ServiceRuntime()
        let response = await runtime.dispatch(
            IPCRequest(method: .proposeWorkspaceLaunch(params())),
            context: context(role: .cli))
        #expect(response.result == .error(.launchProposalFailed("unknownHost")))
    }

    @Test func cliInvalidProposalShapeFailsInvalid() async {
        let runtime = ServiceRuntime()
        let bad = ProposeLaunchParams(
            workspace: "", hostID: UUID(), workspaceSessionID: UUID(),
            kind: "custom", executable: "/bin/echo",
            expectedDigest: String(repeating: "a", count: 64))
        let response = await runtime.dispatch(
            IPCRequest(method: .proposeWorkspaceLaunch(bad)),
            context: context(role: .cli))
        #expect(response.result == .error(.launchProposalFailed("invalidProposal")))
    }

    @Test func operatorUIRoleCannotUseGenericPropose() async {
        let runtime = ServiceRuntime()
        let response = await runtime.dispatch(
            IPCRequest(method: .proposeWorkspaceLaunch(params())),
            context: context(role: .operatorUI))
        #expect(response.result == .error(.authorizationDenied))
    }

    @Test func cliStatusOfUnknownIsUnknown() async {
        let runtime = ServiceRuntime()
        let id = UUID()
        let response = await runtime.dispatch(
            IPCRequest(method: .launchProposalStatus(ProposalStatusParams(operationID: id))),
            context: context(role: .cli))
        #expect(response.result == .launchProposalStatus(
            ProposalStatusReply(operationID: id, status: "unknown")))
    }

    @Test func unauthenticatedStatusDenied() async {
        let runtime = ServiceRuntime()
        let response = await runtime.dispatch(
            IPCRequest(method: .launchProposalStatus(
                ProposalStatusParams(operationID: UUID()))),
            context: .unauthenticated)
        #expect(response.result == .error(.authorizationDenied))
    }

    @Test func protocolNameMismatchRejected() async {
        let runtime = ServiceRuntime()
        var request = IPCRequest(method: .launchProposalStatus(
            ProposalStatusParams(operationID: UUID())))
        request.protocolName = "wrong"
        let response = await runtime.dispatch(request, context: context(role: .cli))
        #expect(response.result == .error(.protocolSkew(.protocolSkew)))
    }
}
