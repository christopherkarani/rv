import Foundation
import RVDomain

public struct Hello: Sendable, Equatable, Codable {
    public var protocolName: String
    public var clientSemver: String

    public init(protocolName: String = ProtocolVersion.name, clientSemver: String = ProtocolVersion.serviceSemver) {
        self.protocolName = protocolName
        self.clientSemver = clientSemver
    }

    enum CodingKeys: String, CodingKey {
        case protocolName = "protocol"
        case clientSemver
    }
}

public struct HelloAck: Sendable, Equatable, Codable {
    public var protocolName: String
    public var serviceSemver: String
    public var ok: Bool
    public var skewReason: SkewReason?

    public init(
        protocolName: String = ProtocolVersion.name,
        serviceSemver: String = ProtocolVersion.serviceSemver,
        ok: Bool,
        skewReason: SkewReason? = nil
    ) {
        self.protocolName = protocolName
        self.serviceSemver = serviceSemver
        self.ok = ok
        self.skewReason = skewReason
    }

    enum CodingKeys: String, CodingKey {
        case protocolName = "protocol"
        case serviceSemver
        case ok
        case skewReason
    }
}

public struct IPCRequest: Sendable, Equatable, Codable {
    public var id: UUID
    public var protocolName: String
    public var method: IPCMethod

    public init(id: UUID = UUID(), protocolName: String = ProtocolVersion.name, method: IPCMethod) {
        self.id = id
        self.protocolName = protocolName
        self.method = method
    }

    enum CodingKeys: String, CodingKey {
        case id
        case protocolName = "protocol"
        case method
    }
}

public struct IPCResponse: Sendable, Equatable, Codable {
    public var id: UUID
    public var protocolName: String
    public var result: IPCResult

    public init(id: UUID, protocolName: String = ProtocolVersion.name, result: IPCResult) {
        self.id = id
        self.protocolName = protocolName
        self.result = result
    }

    enum CodingKeys: String, CodingKey {
        case id
        case protocolName = "protocol"
        case result
    }
}

public enum IPCError: Error, Sendable, Equatable, Codable {
    case unknownMethod
    case decodeFailed
    case handshakeRequired
    case protocolSkew(SkewReason?)
    case hookFailed
    case packMutationFailed
    case packNotFound(PackID)
    case allowOnceNotFound
    case allowOnceAlreadyConsumed
    case allowOnceExpired

    private enum CodingKeys: String, CodingKey {
        case unknownMethod
        case decodeFailed
        case handshakeRequired
        case protocolSkew
        case hookFailed
        case packMutationFailed
        case packNotFound
        case allowOnceNotFound
        case allowOnceAlreadyConsumed
        case allowOnceExpired
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .unknownMethod:
            try container.encode(true, forKey: .unknownMethod)
        case .decodeFailed:
            try container.encode(true, forKey: .decodeFailed)
        case .handshakeRequired:
            try container.encode(true, forKey: .handshakeRequired)
        case .protocolSkew(let reason):
            try container.encode(reason, forKey: .protocolSkew)
        case .hookFailed:
            try container.encode(true, forKey: .hookFailed)
        case .packMutationFailed:
            try container.encode(true, forKey: .packMutationFailed)
        case .packNotFound(let id):
            try container.encode(id, forKey: .packNotFound)
        case .allowOnceNotFound:
            try container.encode(true, forKey: .allowOnceNotFound)
        case .allowOnceAlreadyConsumed:
            try container.encode(true, forKey: .allowOnceAlreadyConsumed)
        case .allowOnceExpired:
            try container.encode(true, forKey: .allowOnceExpired)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.unknownMethod) {
            self = .unknownMethod
        } else if container.contains(.decodeFailed) {
            self = .decodeFailed
        } else if container.contains(.handshakeRequired) {
            self = .handshakeRequired
        } else if container.contains(.protocolSkew) {
            self = .protocolSkew(try container.decodeIfPresent(SkewReason.self, forKey: .protocolSkew))
        } else if container.contains(.hookFailed) {
            self = .hookFailed
        } else if container.contains(.packMutationFailed) {
            self = .packMutationFailed
        } else if let id = try container.decodeIfPresent(PackID.self, forKey: .packNotFound) {
            self = .packNotFound(id)
        } else if container.contains(.allowOnceNotFound) {
            self = .allowOnceNotFound
        } else if container.contains(.allowOnceAlreadyConsumed) {
            self = .allowOnceAlreadyConsumed
        } else if container.contains(.allowOnceExpired) {
            self = .allowOnceExpired
        } else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "unknown IPCError")
            )
        }
    }
}
