import Foundation
import RVDomain

public enum ServiceState: String, Sendable, Equatable, Codable {
    case running
    case idleExitArmed
    case down
    case skew
}

public enum DoctorCheckStatus: String, Sendable, Equatable, Codable {
    case ok
    case warning
    case error
    case skipped
}

public enum DoctorCheckID: String, Codable, Hashable, Sendable {
    case xpc, `protocol`, packs, launchd, lastError, grok, pi, opencode
}

public struct DoctorCheck: Sendable, Equatable, Codable {
    public var id: DoctorCheckID
    public var status: DoctorCheckStatus
    public var message: String

    public init(id: DoctorCheckID, status: DoctorCheckStatus, message: String) {
        self.id = id
        self.status = status
        self.message = message
    }
}

public struct DoctorSnapshotReply: Sendable, Equatable, Codable {
    public var protocolName: String
    public var serviceSemver: String
    public var label: String
    public var state: ServiceState
    public var keepAlive: Bool
    public var idleExitSeconds: Int
    public var packsEnabled: [PackID]
    public var lastError: String?
    public var checks: [DoctorCheck]

    public init(
        protocolName: String = ProtocolVersion.name,
        serviceSemver: String = ProtocolVersion.serviceSemver,
        label: String = "dev.rv.evaluate",
        state: ServiceState,
        keepAlive: Bool = false,
        idleExitSeconds: Int,
        packsEnabled: [PackID],
        lastError: String? = nil,
        checks: [DoctorCheck]
    ) {
        self.protocolName = protocolName
        self.serviceSemver = serviceSemver
        self.label = label
        self.state = state
        self.keepAlive = keepAlive
        self.idleExitSeconds = idleExitSeconds
        self.packsEnabled = packsEnabled
        self.lastError = lastError
        self.checks = checks
    }

    enum CodingKeys: String, CodingKey {
        case protocolName = "protocol"
        case serviceSemver
        case label
        case state
        case keepAlive
        case idleExitSeconds
        case packsEnabled
        case lastError
        case checks
    }
}
