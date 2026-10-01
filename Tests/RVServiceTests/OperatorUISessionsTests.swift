import Foundation
import Testing
@testable import RVIsolation
@testable import RVService

/// UI session registry logic. No XPC: peers are synthetic, exercising
/// registration rules only.
@Suite("Operator UI sessions")
struct OperatorUISessionsTests {
    private func peer(
        role: TrustedRVComponentRole? = .operatorUI,
        connectionID: UUID = UUID()
    ) -> AuthenticatedPeer {
        let code = PeerCodeIdentity(identifier: "ui-fixture", teamIdentifier: nil,
            cdHash: Data([9]), executablePath: "/ui-fixture", isAdHoc: true,
            hardenedRuntime: true, injectionExceptions: [])
        return AuthenticatedPeer(evidence: PlatformPeerEvidence(processID: 1,
            effectiveUserID: 501, auditToken: Data([9]), codeIdentity: code,
            componentRole: role), connectionID: connectionID)
    }

    @Test func registerMintsOneConnectionPerPeer() async throws {
        let sessions = LiveOperatorUISessionRegistry()
        let id = try await sessions.register(peer: peer())
        #expect(await sessions.session(connectionID: id.rawValue) == nil)
    }

    @Test func registrationIsIdempotentPerConnection() async throws {
        let sessions = LiveOperatorUISessionRegistry()
        let connection = UUID()
        let first = try await sessions.register(peer: peer(connectionID: connection))
        let second = try await sessions.register(peer: peer(connectionID: connection))
        #expect(first == second)
        #expect(await sessions.session(connectionID: connection)?.uiConnection == first)
    }

    @Test func distinctConnectionsMintDistinctIDs() async throws {
        let sessions = LiveOperatorUISessionRegistry()
        let first = try await sessions.register(peer: peer())
        let second = try await sessions.register(peer: peer())
        #expect(first != second)
    }

    @Test(arguments: ["cli", "service", "workspaceHost", "untrusted"])
    func nonUIRolesCannotRegister(rawRole: String) async {
        let sessions = LiveOperatorUISessionRegistry()
        let role = TrustedRVComponentRole(rawValue: rawRole)
        await #expect(throws: OperatorUISessionError.wrongComponentRole) {
            try await sessions.register(peer: peer(role: role))
        }
    }

    @Test func disconnectReturnsConnectionAndDropsSession() async throws {
        let sessions = LiveOperatorUISessionRegistry()
        let connection = UUID()
        let id = try await sessions.register(peer: peer(connectionID: connection))
        #expect(await sessions.disconnect(connectionID: connection) == id)
        #expect(await sessions.session(connectionID: connection) == nil)
        #expect(await sessions.disconnect(connectionID: connection) == nil)
    }

    @Test func unknownDisconnectIsSafeNoOp() async throws {
        let sessions = LiveOperatorUISessionRegistry()
        #expect(await sessions.disconnect(connectionID: UUID()) == nil)
    }
}
