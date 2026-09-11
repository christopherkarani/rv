import Foundation
import RVDomain

public struct PendingListItem: Sendable, Equatable, Codable {
    public var id: ApprovalID
    public var host: HookHost
    public var folder: String
    public var actionKind: String
    public var fingerprint: ActionFingerprint
    public var sessionSuffix: String?
    public var identity: ApprovalIdentity

    public init(
        id: ApprovalID,
        host: HookHost,
        folder: String,
        actionKind: String,
        fingerprint: ActionFingerprint,
        sessionSuffix: String? = nil,
        identity: ApprovalIdentity
    ) {
        self.id = id
        self.host = host
        self.folder = folder
        self.actionKind = actionKind
        self.fingerprint = fingerprint
        self.sessionSuffix = sessionSuffix
        self.identity = identity
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ApprovalID.self, forKey: .id)
        host = try container.decode(HookHost.self, forKey: .host)
        folder = try container.decode(String.self, forKey: .folder)
        actionKind = try container.decode(String.self, forKey: .actionKind)
        fingerprint = try container.decode(ActionFingerprint.self, forKey: .fingerprint)
        sessionSuffix = try container.decodeIfPresent(String.self, forKey: .sessionSuffix)
        identity = try container.decode(ApprovalIdentity.self, forKey: .identity)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(host, forKey: .host)
        try container.encode(folder, forKey: .folder)
        try container.encode(actionKind, forKey: .actionKind)
        try container.encode(fingerprint, forKey: .fingerprint)
        try container.encodeIfPresent(sessionSuffix, forKey: .sessionSuffix)
        try container.encode(identity, forKey: .identity)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case host
        case folder
        case actionKind
        case fingerprint
        case sessionSuffix
        case identity
    }
}

public struct PendingListReply: Sendable, Equatable, Codable {
    public var generation: UInt64
    public var items: [PendingListItem]

    public init(generation: UInt64, items: [PendingListItem]) {
        self.generation = generation
        self.items = items
    }
}

public typealias PendingWatchReply = PendingListReply

public struct PendingWatchParams: Sendable, Equatable, Codable {
    public var afterGeneration: UInt64

    public init(afterGeneration: UInt64) {
        self.afterGeneration = afterGeneration
    }
}

public enum PendingResolveDecision: String, Sendable, Equatable {
    case allowOnce
    case deny
}

extension PendingResolveDecision: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "allowOnce":
            self = .allowOnce
        case "deny":
            self = .deny
        default:
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription:
                        "Cannot initialize PendingResolveDecision from invalid String value \(raw)"
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct PendingResolveParams: Sendable, Equatable, Codable {
    public var id: ApprovalID
    public var decision: PendingResolveDecision
    public var fingerprint: ActionFingerprint
    public var identity: ApprovalIdentity

    public init(
        id: ApprovalID,
        decision: PendingResolveDecision,
        fingerprint: ActionFingerprint,
        identity: ApprovalIdentity
    ) {
        self.id = id
        self.decision = decision
        self.fingerprint = fingerprint
        self.identity = identity
    }
}

public struct PendingResolveReply: Sendable, Equatable, Codable {
    public var id: ApprovalID
    public var terminal: Bool

    public init(id: ApprovalID, terminal: Bool) {
        self.id = id
        self.terminal = terminal
    }
}
