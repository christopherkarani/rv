import Foundation
import RVIsolation
import RVMCP

/// What the listener sends back for one incoming frame, mirroring
/// `ServiceRuntime`'s `IncomingReply`.
public struct CustodianIncomingReply: Sendable {
    public var frame: Data
    public var handshakeAccepted: Bool
    public var includeEndpoint: Bool

    public init(frame: Data, handshakeAccepted: Bool, includeEndpoint: Bool) {
        self.frame = frame
        self.handshakeAccepted = handshakeAccepted
        self.includeEndpoint = includeEndpoint
    }
}

/// Pure request handling for the custodian: handshake, authorization,
/// and dispatch to the key service. Transport (XPC) and peer capture
/// wrap this; tests drive it with a fake key store and fake peer roles.
///
/// Authorization copies the daemon's strictest matrix: every operation,
/// hello included, requires the captured `.cli` component role — the
/// gateway and the CLI both run as the rv binary, and no daemon caller
/// exists. Anything else is `.unauthorized` and the key is never read.
/// The discovery connection answers hello only; requests there are
/// denied even after a handshake.
public struct CustodianRequestHandler: Sendable {
    public var service: MCPCustodianKeyService

    public init(service: MCPCustodianKeyService) {
        self.service = service
    }

    public func handleIncoming(
        _ data: Data,
        peerRole: TrustedRVComponentRole?,
        handshakeOK: Bool,
        discoveryOnly: Bool
    ) -> CustodianIncomingReply {
        let decoder = JSONDecoder()
        if let hello = try? decoder.decode(MCPCustodianHello.self, from: data), hello.hello {
            let accepted = peerRole == .cli && hello.protocolVersion == MCPCustodianWire.protocolVersion
            return CustodianIncomingReply(
                frame: encode(MCPCustodianHelloAck(ok: accepted)),
                handshakeAccepted: accepted,
                includeEndpoint: accepted && discoveryOnly)
        }
        guard discoveryOnly == false, handshakeOK, peerRole == .cli else {
            return CustodianIncomingReply(
                frame: encode(MCPCustodianResponse.error(.unauthorized)),
                handshakeAccepted: handshakeOK,
                includeEndpoint: false)
        }
        guard let request = try? decoder.decode(MCPCustodianRequest.self, from: data) else {
            return CustodianIncomingReply(
                frame: encode(MCPCustodianResponse.error(.badRequest)),
                handshakeAccepted: handshakeOK,
                includeEndpoint: false)
        }
        // The service re-validates wire bounds and the purpose allowlist,
        // so a purpose like `enrollment` is a bad request, never a MAC.
        return CustodianIncomingReply(
            frame: encode(service.handle(request)),
            handshakeAccepted: handshakeOK,
            includeEndpoint: false)
    }

    private func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }
}
