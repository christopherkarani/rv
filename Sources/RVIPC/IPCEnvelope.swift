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
    public var skewReason: String?

    public init(
        protocolName: String = ProtocolVersion.name,
        serviceSemver: String = ProtocolVersion.serviceSemver,
        ok: Bool,
        skewReason: String? = nil
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
    case protocolSkew(String)
    case engine(String)
    case packNotFound(PackID)
    case allowOnceNotFound
    case allowOnceAlreadyConsumed
    case allowOnceExpired

    private enum CodingKeys: String, CodingKey {
        case unknownMethod
        case decodeFailed
        case protocolSkew
        case engine
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
        case .protocolSkew(let message):
            try container.encode(message, forKey: .protocolSkew)
        case .engine(let message):
            try container.encode(message, forKey: .engine)
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
        } else if let message = try container.decodeIfPresent(String.self, forKey: .protocolSkew) {
            self = .protocolSkew(message)
        } else if let message = try container.decodeIfPresent(String.self, forKey: .engine) {
            self = .engine(message)
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
