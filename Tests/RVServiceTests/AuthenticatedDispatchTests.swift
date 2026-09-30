import Foundation
import RVIPC
@testable import RVService
import Testing

@Suite("Authenticated dispatch boundary")
struct AuthenticatedDispatchTests {
    @Test func helloDoesNotGrantControlAuthority() async throws {
        let runtime = ServiceRuntime(home: nil)
        let hello = Hello(protocolName: ProtocolVersion.name, clientSemver: ProtocolVersion.serviceSemver)
        let response = await runtime.handleIncoming(try IPCJSON.encode(hello), handshakeOK: false)
        #expect(response.handshakeAccepted)
        let request = IPCRequest(method: .pendingList)
        let result = await runtime.handleIncoming(try IPCJSON.encode(request), handshakeOK: true)
        let decoded = try IPCJSON.decode(IPCResponse.self, from: result.frame)
        #expect(decoded.result == .error(.authorizationDenied))
    }

    @Test func payloadAndAsyncBoundaryCannotUpgradeCaller() async {
        let runtime = ServiceRuntime(home: nil)
        let context = AuthenticatedRequestContext.unauthenticated
        let connection = context.connectionID
        let result = await Task {
            #expect(context.connectionID == connection)
            return await runtime.dispatch(IPCRequest(method: .pendingList), context: context)
        }.value
        #expect(result.result == .error(.authorizationDenied))
    }

    @Test func diagnosticsRemainUnprivileged() {
        #expect(ServiceMethodAuthorization.permits(.listPacks, context: .unauthenticated))
        #expect(ServiceMethodAuthorization.permits(.doctorSnapshot, context: .unauthenticated))
        #expect(ServiceMethodAuthorization.permits(.pendingList, context: .unauthenticated) == false)
    }

    @Test func authorizationFailureRoundTrips() throws {
        let encoded = try IPCJSON.encode(IPCResponse(id: UUID(), result: .error(.authorizationDenied)))
        let decoded = try IPCJSON.decode(IPCResponse.self, from: encoded)
        #expect(decoded.result == .error(.authorizationDenied))
    }
}
