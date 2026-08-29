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

public enum HandshakeStatus: Sendable, Equatable {
    case ok
    case skew(SkewReason)
}

public struct HelloAck: Sendable, Equatable, Codable {
    public var protocolName: String
    public var serviceSemver: String
    public var status: HandshakeStatus

    public init(
        protocolName: String = ProtocolVersion.name,
        serviceSemver: String = ProtocolVersion.serviceSemver,
        status: HandshakeStatus
    ) {
        self.protocolName = protocolName
        self.serviceSemver = serviceSemver
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case protocolName = "protocol"
        case serviceSemver
        case ok
        case skewReason
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolName, forKey: .protocolName)
        try container.encode(serviceSemver, forKey: .serviceSemver)
        switch status {
        case .ok:
            try container.encode(true, forKey: .ok)
        case .skew(let reason):
            try container.encode(false, forKey: .ok)
            try container.encode(reason, forKey: .skewReason)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolName = try container.decode(String.self, forKey: .protocolName)
        serviceSemver = try container.decode(String.self, forKey: .serviceSemver)
        let ok = try container.decode(Bool.self, forKey: .ok)
        if ok {
            if container.contains(.skewReason) {
                throw DecodingError.dataCorruptedError(
                    forKey: .skewReason,
                    in: container,
                    debugDescription: "ok handshake must omit skewReason"
                )
            }
            status = .ok
        } else {
            let reason = try container.decode(SkewReason.self, forKey: .skewReason)
            status = .skew(reason)
        }
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
    case protocolSkew(SkewReason)
    case engine(String)
    case packNotFound(PackID)
    case allowOnceNotFound
    case allowOnceAlreadyConsumed
    case allowOnceExpired
    case pendingNotFound
    case pendingAlreadyTerminal
    case pendingIdentityMismatch
    case pendingFingerprintMismatch
    case ruleDraftMismatch
    case ruleHardStop

    private enum CodingKeys: String, CodingKey {
        case unknownMethod
        case decodeFailed
        case protocolSkew
        case engine
        case packNotFound
        case allowOnceNotFound
        case allowOnceAlreadyConsumed
        case allowOnceExpired
        case pendingNotFound
        case pendingAlreadyTerminal
        case pendingIdentityMismatch
        case pendingFingerprintMismatch
        case ruleDraftMismatch
        case ruleHardStop
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .unknownMethod:
            try container.encode(true, forKey: .unknownMethod)
        case .decodeFailed:
            try container.encode(true, forKey: .decodeFailed)
        case .protocolSkew(let reason):
            try container.encode(reason, forKey: .protocolSkew)
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
        case .pendingNotFound:
            try container.encode(true, forKey: .pendingNotFound)
        case .pendingAlreadyTerminal:
            try container.encode(true, forKey: .pendingAlreadyTerminal)
        case .pendingIdentityMismatch:
            try container.encode(true, forKey: .pendingIdentityMismatch)
        case .pendingFingerprintMismatch:
            try container.encode(true, forKey: .pendingFingerprintMismatch)
        case .ruleDraftMismatch:
            try container.encode(true, forKey: .ruleDraftMismatch)
        case .ruleHardStop:
            try container.encode(true, forKey: .ruleHardStop)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.unknownMethod) {
            self = .unknownMethod
        } else if container.contains(.decodeFailed) {
            self = .decodeFailed
        } else if let reason = try container.decodeIfPresent(SkewReason.self, forKey: .protocolSkew) {
            self = .protocolSkew(reason)
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
        } else if container.contains(.pendingNotFound) {
            self = .pendingNotFound
        } else if container.contains(.pendingAlreadyTerminal) {
            self = .pendingAlreadyTerminal
        } else if container.contains(.pendingIdentityMismatch) {
            self = .pendingIdentityMismatch
        } else if container.contains(.pendingFingerprintMismatch) {
            self = .pendingFingerprintMismatch
        } else if container.contains(.ruleDraftMismatch) {
            self = .ruleDraftMismatch
        } else if container.contains(.ruleHardStop) {
            self = .ruleHardStop
        } else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "unknown IPCError")
            )
        }
    }
}
