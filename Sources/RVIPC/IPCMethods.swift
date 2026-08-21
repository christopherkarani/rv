import Foundation
import RVDomain

public struct EvaluateParams: Sendable, Equatable, Codable {
    public var request: EvaluationRequest
    public var cwd: String?

    public init(request: EvaluationRequest, cwd: String? = nil) {
        self.request = request
        self.cwd = RequestCwdCoding.nonempty(cwd)
    }

    public init(from decoder: Decoder) throws {
        (request, cwd) = try RequestCwdCoding.decode(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try RequestCwdCoding.encode(request: request, cwd: cwd, to: encoder)
    }
}

/// How an evaluate reply was produced. Wire values: `xpc`, `inProcess`.
public enum EvaluationPath: String, Sendable, Equatable, Codable {
    case xpc
    case inProcess
}

public struct EvaluateReply: Sendable, Equatable, Codable {
    public var result: EvaluationResult
    public var via: EvaluationPath

    public init(result: EvaluationResult, via: EvaluationPath = .xpc) {
        self.result = result
        self.via = via
    }
}

public struct ExplainParams: Sendable, Equatable, Codable {
    public var request: EvaluationRequest
    public var cwd: String?

    public init(request: EvaluationRequest, cwd: String? = nil) {
        self.request = request
        self.cwd = RequestCwdCoding.nonempty(cwd)
    }

    public init(from decoder: Decoder) throws {
        (request, cwd) = try RequestCwdCoding.decode(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try RequestCwdCoding.encode(request: request, cwd: cwd, to: encoder)
    }
}

public struct ExplainStage: Sendable, Equatable, Codable {
    public var name: String
    public var elapsedMs: Double

    public init(name: String, elapsedMs: Double) {
        self.name = name
        self.elapsedMs = elapsedMs
    }
}

public struct ExplainReply: Sendable, Equatable, Codable {
    public var result: EvaluationResult
    public var normalized: String
    public var ruleID: RuleID?
    public var packID: PackID?
    public var suggestion: String?
    public var stages: [ExplainStage]

    public init(
        result: EvaluationResult,
        normalized: String,
        ruleID: RuleID? = nil,
        packID: PackID? = nil,
        suggestion: String? = nil,
        stages: [ExplainStage]
    ) {
        self.result = result
        self.normalized = normalized
        self.ruleID = ruleID
        self.packID = packID
        self.suggestion = suggestion
        self.stages = stages
    }
}

public enum ClassifyRisk: String, Sendable, Equatable, Codable {
    case safe
    case low
    case medium
    case high
    case critical
}

public struct ClassifyParams: Sendable, Equatable, Codable {
    public var request: EvaluationRequest
    public var cwd: String?

    public init(request: EvaluationRequest, cwd: String? = nil) {
        self.request = request
        self.cwd = RequestCwdCoding.nonempty(cwd)
    }

    public init(from decoder: Decoder) throws {
        (request, cwd) = try RequestCwdCoding.decode(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try RequestCwdCoding.encode(request: request, cwd: cwd, to: encoder)
    }
}

public struct ClassifyReason: Sendable, Equatable, Codable {
    public var ruleID: RuleID
    public var explanation: String

    public init(ruleID: RuleID, explanation: String) {
        self.ruleID = ruleID
        self.explanation = explanation
    }
}

public struct ClassifyReply: Sendable, Equatable, Codable {
    public var decision: Decision
    public var risk: ClassifyRisk
    public var ruleID: RuleID?
    public var packID: PackID?
    public var reasons: [ClassifyReason]
    public var suggestions: [String]

    public init(
        decision: Decision,
        risk: ClassifyRisk,
        ruleID: RuleID? = nil,
        packID: PackID? = nil,
        reasons: [ClassifyReason] = [],
        suggestions: [String] = []
    ) {
        self.decision = decision
        self.risk = risk
        self.ruleID = ruleID
        self.packID = packID
        self.reasons = reasons
        self.suggestions = suggestions
    }
}

public struct PackRecord: Sendable, Equatable, Codable {
    public var id: PackID
    public var enabled: Bool
    public var bundled: Bool

    public init(id: PackID, enabled: Bool, bundled: Bool) {
        self.id = id
        self.enabled = enabled
        self.bundled = bundled
    }
}

public struct ListPacksReply: Sendable, Equatable, Codable {
    public var packs: [PackRecord]
    public var enabledCount: Int
    public var totalCount: Int

    public init(packs: [PackRecord], enabledCount: Int, totalCount: Int) {
        self.packs = packs
        self.enabledCount = enabledCount
        self.totalCount = totalCount
    }
}

public struct SetPackEnabledParams: Sendable, Equatable, Codable {
    public var id: PackID
    public var enabled: Bool

    public init(id: PackID, enabled: Bool) {
        self.id = id
        self.enabled = enabled
    }
}

public struct SetPackEnabledReply: Sendable, Equatable, Codable {
    public var pack: PackRecord

    public init(pack: PackRecord) {
        self.pack = pack
    }
}

public struct AllowOnceConsumeParams: Sendable, Equatable, Codable {
    public var command: String
    public var cwd: String

    public init(command: String, cwd: String) {
        self.command = command
        self.cwd = cwd
    }
}

public struct AllowOnceConsumeReply: Sendable, Equatable, Codable {
    public var consumed: Bool
    public var tokenID: String?

    public init(consumed: Bool, tokenID: String? = nil) {
        self.consumed = consumed
        self.tokenID = tokenID
    }
}

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

public struct DoctorCheck: Sendable, Equatable, Codable {
    public var id: String
    public var status: DoctorCheckStatus
    public var message: String

    public init(id: String, status: DoctorCheckStatus, message: String) {
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

public enum IPCMethod: Sendable, Equatable {
    case evaluate(EvaluateParams)
    case explain(ExplainParams)
    case classify(ClassifyParams)
    case listPacks
    case setPackEnabled(SetPackEnabledParams)
    case allowOnceConsume(AllowOnceConsumeParams)
    case doctorSnapshot
}

public enum IPCResult: Sendable, Equatable {
    case evaluate(EvaluateReply)
    case explain(ExplainReply)
    case classify(ClassifyReply)
    case listPacks(ListPacksReply)
    case setPackEnabled(SetPackEnabledReply)
    case allowOnceConsume(AllowOnceConsumeReply)
    case doctorSnapshot(DoctorSnapshotReply)
    case error(IPCError)
}

extension IPCMethod: Codable {
    private enum CodingKeys: String, CodingKey {
        case evaluate
        case explain
        case classify
        case listPacks
        case setPackEnabled
        case allowOnceConsume
        case doctorSnapshot
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .evaluate(let params):
            try container.encode(params, forKey: .evaluate)
        case .explain(let params):
            try container.encode(params, forKey: .explain)
        case .classify(let params):
            try container.encode(params, forKey: .classify)
        case .listPacks:
            try container.encode(EmptyPayload(), forKey: .listPacks)
        case .setPackEnabled(let params):
            try container.encode(params, forKey: .setPackEnabled)
        case .allowOnceConsume(let params):
            try container.encode(params, forKey: .allowOnceConsume)
        case .doctorSnapshot:
            try container.encode(EmptyPayload(), forKey: .doctorSnapshot)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let params = try container.decodeIfPresent(EvaluateParams.self, forKey: .evaluate) {
            self = .evaluate(params)
        } else if let params = try container.decodeIfPresent(ExplainParams.self, forKey: .explain) {
            self = .explain(params)
        } else if let params = try container.decodeIfPresent(ClassifyParams.self, forKey: .classify) {
            self = .classify(params)
        } else if container.contains(.listPacks) {
            self = .listPacks
        } else if let params = try container.decodeIfPresent(SetPackEnabledParams.self, forKey: .setPackEnabled) {
            self = .setPackEnabled(params)
        } else if let params = try container.decodeIfPresent(AllowOnceConsumeParams.self, forKey: .allowOnceConsume) {
            self = .allowOnceConsume(params)
        } else if container.contains(.doctorSnapshot) {
            self = .doctorSnapshot
        } else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "unknown IPCMethod")
            )
        }
    }
}

extension IPCResult: Codable {
    private enum CodingKeys: String, CodingKey {
        case evaluate
        case explain
        case classify
        case listPacks
        case setPackEnabled
        case allowOnceConsume
        case doctorSnapshot
        case error
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .evaluate(let reply):
            try container.encode(reply, forKey: .evaluate)
        case .explain(let reply):
            try container.encode(reply, forKey: .explain)
        case .classify(let reply):
            try container.encode(reply, forKey: .classify)
        case .listPacks(let reply):
            try container.encode(reply, forKey: .listPacks)
        case .setPackEnabled(let reply):
            try container.encode(reply, forKey: .setPackEnabled)
        case .allowOnceConsume(let reply):
            try container.encode(reply, forKey: .allowOnceConsume)
        case .doctorSnapshot(let reply):
            try container.encode(reply, forKey: .doctorSnapshot)
        case .error(let error):
            try container.encode(error, forKey: .error)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let reply = try container.decodeIfPresent(EvaluateReply.self, forKey: .evaluate) {
            self = .evaluate(reply)
        } else if let reply = try container.decodeIfPresent(ExplainReply.self, forKey: .explain) {
            self = .explain(reply)
        } else if let reply = try container.decodeIfPresent(ClassifyReply.self, forKey: .classify) {
            self = .classify(reply)
        } else if let reply = try container.decodeIfPresent(ListPacksReply.self, forKey: .listPacks) {
            self = .listPacks(reply)
        } else if let reply = try container.decodeIfPresent(SetPackEnabledReply.self, forKey: .setPackEnabled) {
            self = .setPackEnabled(reply)
        } else if let reply = try container.decodeIfPresent(AllowOnceConsumeReply.self, forKey: .allowOnceConsume) {
            self = .allowOnceConsume(reply)
        } else if let reply = try container.decodeIfPresent(DoctorSnapshotReply.self, forKey: .doctorSnapshot) {
            self = .doctorSnapshot(reply)
        } else if let error = try container.decodeIfPresent(IPCError.self, forKey: .error) {
            self = .error(error)
        } else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "unknown IPCResult")
            )
        }
    }
}

struct EmptyPayload: Sendable, Equatable, Codable {}

enum RequestCwdCoding {
    enum CodingKeys: String, CodingKey {
        case request
        case cwd
    }

    static func nonempty(_ cwd: String?) -> String? {
        cwd.flatMap { $0.isEmpty ? nil : $0 }
    }

    static func decode(from decoder: Decoder) throws -> (EvaluationRequest, String?) {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let request = try container.decode(EvaluationRequest.self, forKey: .request)
        let cwd = nonempty(try container.decodeIfPresent(String.self, forKey: .cwd))
        return (request, cwd)
    }

    static func encode(request: EvaluationRequest, cwd: String?, to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(request, forKey: .request)
        try container.encodeIfPresent(cwd, forKey: .cwd)
    }
}
