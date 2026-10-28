import Foundation

/// Synchronous send-one-request seam. Nil means the custodian could not be
/// reached or did not answer; clients fail closed on it.
public typealias MCPCustodianTransport = @Sendable (MCPCustodianRequest) -> MCPCustodianResponse?

extension MCPApprovalSigning {
    /// Client side of the custodian seam: every operation is one request,
    /// and anything but the matching response case fails closed.
    public static func custodian(
        honorsGrants: Bool = true, transport: @escaping MCPCustodianTransport
    ) -> MCPApprovalSigning {
        MCPApprovalSigning(
            honorsGrants: honorsGrants,
            presenceAtSigning: true,
            status: {
                guard case .status(let status)? = transport(.status) else { return .unavailable }
                return status
            },
            mac: { purpose, fields, createIfMissing in
                let request = MCPCustodianRequest.mac(purpose: purpose, fields: fields, createIfMissing: createIfMissing)
                guard MCPCustodianWire.isValid(request), case .mac(let value)? = transport(request) else { return nil }
                return value
            },
            verify: { candidate, purpose, fields in
                guard let candidate else { return false }
                let request = MCPCustodianRequest.verify(candidate: candidate, purpose: purpose, fields: fields)
                guard MCPCustodianWire.isValid(request), case .verify(let valid)? = transport(request) else { return nil }
                return valid
            },
            beginFreshAuth: { _ = transport(.beginFreshAuth) })
    }
}

/// Custodian side of the seam: serves mac/verify requests from a signing
/// backend whose key bytes never leave the custodian. Transport and peer
/// authorization wrap `handle`; they are not its concern.
public struct MCPCustodianKeyService: Sendable {
    public var signing: MCPApprovalSigning

    public init(signing: MCPApprovalSigning) {
        self.signing = signing
    }

    public func handle(_ request: MCPCustodianRequest) -> MCPCustodianResponse {
        guard MCPCustodianWire.isValid(request) else { return .error(.badRequest) }
        switch request {
        case .status: return .status(signing.status())
        case .beginFreshAuth:
            signing.beginFreshAuth()
            return .status(signing.status())
        case .mac(let purpose, let fields, let createIfMissing):
            return .mac(signing.mac(purpose, fields, createIfMissing))
        case .verify(let candidate, let purpose, let fields):
            return .verify(signing.verify(candidate, purpose, fields))
        }
    }

    public var transport: MCPCustodianTransport {
        { self.handle($0) }
    }
}
