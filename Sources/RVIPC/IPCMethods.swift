import Foundation
import RVDomain

public struct EvaluateParams: Sendable, Equatable, Codable {
    public var request: EvaluationRequest
    public var cwd: String?
    /// Additive `rv.ipc.v1` field. Old clients omit it and Hello first.
    public var clientSemver: String?

    public init(request: EvaluationRequest, cwd: String? = nil, clientSemver: String? = nil) {
        self.request = request
        self.cwd = RequestCwdCoding.nonempty(cwd)
        self.clientSemver = clientSemver
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        request = try container.decode(EvaluationRequest.self, forKey: .request)
        cwd = RequestCwdCoding.nonempty(try container.decodeIfPresent(String.self, forKey: .cwd))
        clientSemver = try container.decodeIfPresent(String.self, forKey: .clientSemver)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(request, forKey: .request)
        try container.encodeIfPresent(cwd, forKey: .cwd)
        try container.encodeIfPresent(clientSemver, forKey: .clientSemver)
    }

    private enum CodingKeys: String, CodingKey {
        case request
        case cwd
        case clientSemver
    }
}

/// Evaluation route: trusted service reply (`xpc`) or client in-process fallback (`inProcess`).
///
/// On `EvaluateReply`, only `.xpc` decodes. `.inProcess` is reserved for client-side
/// routing and is rejected on the wire.
public enum EvaluationPath: String, Sendable, Equatable, Codable {
    case xpc
    case inProcess
}

public struct EvaluateReply: Sendable, Equatable, Codable {
    public var result: EvaluationResult
    public let via: EvaluationPath
    /// Additive `rv.ipc.v1` field. Replies without it cannot prove major
    /// compatibility, so clients reject them and fall back in-process.
    public var serviceSemver: String?

    public init(result: EvaluationResult, serviceSemver: String? = ProtocolVersion.serviceSemver) {
        self.result = result
        self.via = .xpc
        self.serviceSemver = serviceSemver
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        result = try container.decode(EvaluationResult.self, forKey: .result)
        let decodedVia = try container.decode(EvaluationPath.self, forKey: .via)
        guard decodedVia == .xpc else {
            throw DecodingError.dataCorruptedError(
                forKey: .via,
                in: container,
                debugDescription: "EvaluateReply.via must be \"xpc\""
            )
        }
        via = decodedVia
        serviceSemver = try container.decodeIfPresent(String.self, forKey: .serviceSemver)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(result, forKey: .result)
        try container.encode(via, forKey: .via)
        try container.encodeIfPresent(serviceSemver, forKey: .serviceSemver)
    }

    private enum CodingKeys: String, CodingKey {
        case result
        case via
        case serviceSemver
    }
}

public struct HookEvaluateParams: Sendable, Equatable, Codable {
    /// Closed host family. Unknown strings fail `init(from:)` with `dataCorrupted`.
    public var host: HookHost
    public var stdin: String
    /// Additive `rv.ipc.v1` field. Same implicit-hello rule as `EvaluateParams`.
    public var clientSemver: String?

    public init(host: HookHost, stdin: String, clientSemver: String? = nil) {
        self.host = host
        self.stdin = stdin
        self.clientSemver = clientSemver
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decode(HookHost.self, forKey: .host)
        stdin = try container.decode(String.self, forKey: .stdin)
        clientSemver = try container.decodeIfPresent(String.self, forKey: .clientSemver)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(host, forKey: .host)
        try container.encode(stdin, forKey: .stdin)
        try container.encodeIfPresent(clientSemver, forKey: .clientSemver)
    }

    private enum CodingKeys: String, CodingKey {
        case host
        case stdin
        case clientSemver
    }
}

public struct HookEvaluateReply: Sendable, Equatable, Codable {
    public var stdout: String
    public var exitCode: Int32
    public let via: EvaluationPath
    /// Additive `rv.ipc.v1` field. Replies without it cannot prove major
    /// compatibility; both the Swift CLI and the C hook replay through a
    /// real in-process evaluation instead of trusting them.
    public var serviceSemver: String?

    public init(stdout: String, exitCode: Int32, serviceSemver: String? = ProtocolVersion.serviceSemver) {
        self.stdout = stdout
        self.exitCode = exitCode
        self.via = .xpc
        self.serviceSemver = serviceSemver
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stdout = try container.decode(String.self, forKey: .stdout)
        exitCode = try container.decode(Int32.self, forKey: .exitCode)
        let decodedVia = try container.decode(EvaluationPath.self, forKey: .via)
        guard decodedVia == .xpc else {
            throw DecodingError.dataCorruptedError(
                forKey: .via,
                in: container,
                debugDescription: "HookEvaluateReply.via must be \"xpc\""
            )
        }
        via = decodedVia
        serviceSemver = try container.decodeIfPresent(String.self, forKey: .serviceSemver)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stdout, forKey: .stdout)
        try container.encode(exitCode, forKey: .exitCode)
        try container.encode(via, forKey: .via)
        try container.encodeIfPresent(serviceSemver, forKey: .serviceSemver)
    }

    private enum CodingKeys: String, CodingKey {
        case stdout
        case exitCode
        case via
        case serviceSemver
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
    /// Raw value is the wire-stable stage name (`normalize`, `quick-reject`, …).
    public var name: ExplainStep.ID
    public var elapsedMs: Double

    public init(name: ExplainStep.ID, elapsedMs: Double) {
        self.name = name
        self.elapsedMs = elapsedMs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .name)
        guard let id = ExplainStep.ID(rawValue: raw) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "unknown ExplainStage name")
            )
        }
        name = id
        elapsedMs = try container.decode(Double.self, forKey: .elapsedMs)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name.rawValue, forKey: .name)
        try container.encode(elapsedMs, forKey: .elapsedMs)
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case elapsedMs
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

public enum ClassifyRisk: Sendable, Equatable {
    case safe
    case rated(Severity)
}

extension ClassifyRisk: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if raw == "safe" {
            self = .safe
        } else if let severity = Severity(rawValue: raw) {
            self = .rated(severity)
        } else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription:
                        "Cannot initialize ClassifyRisk from invalid String value \(raw)"
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .safe:
            try container.encode("safe")
        case .rated(let severity):
            try container.encode(severity.rawValue)
        }
    }
}

extension ClassifyRisk {
    /// Total derivation from Decision × matched rule; no default clause.
    public static func derive(decision: Decision, matched: RuleMatch?) -> ClassifyRisk {
        switch decision {
        case .allow:
            if let severity = matched?.severity {
                return .rated(severity)
            }
            return .safe
        case .deny:
            return .rated(matched?.severity ?? .high)
        case .indeterminate:
            return .rated(.high)
        }
    }
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

/// Host-name cases mirror `RVDomain.HookHost`; the remaining cases name doctor subsystems.
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

public enum IPCMethod: Sendable, Equatable {
    case evaluate(EvaluateParams)
    case hookEvaluate(HookEvaluateParams)
    case explain(ExplainParams)
    case classify(ClassifyParams)
    case listPacks
    case setPackEnabled(SetPackEnabledParams)
    case doctorSnapshot
}

public enum IPCResult: Sendable, Equatable {
    case evaluate(EvaluateReply)
    case hookEvaluate(HookEvaluateReply)
    case explain(ExplainReply)
    case classify(ClassifyReply)
    case listPacks(ListPacksReply)
    case setPackEnabled(SetPackEnabledReply)
    case doctorSnapshot(DoctorSnapshotReply)
    case error(IPCError)
}

extension IPCMethod: Codable {
    private enum CodingKeys: String, CodingKey {
        case evaluate
        case hookEvaluate
        case explain
        case classify
        case listPacks
        case setPackEnabled
        case doctorSnapshot
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .evaluate(let params):
            try container.encode(params, forKey: .evaluate)
        case .hookEvaluate(let params):
            try container.encode(params, forKey: .hookEvaluate)
        case .explain(let params):
            try container.encode(params, forKey: .explain)
        case .classify(let params):
            try container.encode(params, forKey: .classify)
        case .listPacks:
            try container.encode(EmptyPayload(), forKey: .listPacks)
        case .setPackEnabled(let params):
            try container.encode(params, forKey: .setPackEnabled)
        case .doctorSnapshot:
            try container.encode(EmptyPayload(), forKey: .doctorSnapshot)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let params = try container.decodeIfPresent(EvaluateParams.self, forKey: .evaluate) {
            self = .evaluate(params)
        } else if let params = try container.decodeIfPresent(HookEvaluateParams.self, forKey: .hookEvaluate) {
            self = .hookEvaluate(params)
        } else if let params = try container.decodeIfPresent(ExplainParams.self, forKey: .explain) {
            self = .explain(params)
        } else if let params = try container.decodeIfPresent(ClassifyParams.self, forKey: .classify) {
            self = .classify(params)
        } else if container.contains(.listPacks) {
            self = .listPacks
        } else if let params = try container.decodeIfPresent(SetPackEnabledParams.self, forKey: .setPackEnabled) {
            self = .setPackEnabled(params)
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
        case hookEvaluate
        case explain
        case classify
        case listPacks
        case setPackEnabled
        case doctorSnapshot
        case error
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .evaluate(let reply):
            try container.encode(reply, forKey: .evaluate)
        case .hookEvaluate(let reply):
            try container.encode(reply, forKey: .hookEvaluate)
        case .explain(let reply):
            try container.encode(reply, forKey: .explain)
        case .classify(let reply):
            try container.encode(reply, forKey: .classify)
        case .listPacks(let reply):
            try container.encode(reply, forKey: .listPacks)
        case .setPackEnabled(let reply):
            try container.encode(reply, forKey: .setPackEnabled)
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
        } else if let reply = try container.decodeIfPresent(HookEvaluateReply.self, forKey: .hookEvaluate) {
            self = .hookEvaluate(reply)
        } else if let reply = try container.decodeIfPresent(ExplainReply.self, forKey: .explain) {
            self = .explain(reply)
        } else if let reply = try container.decodeIfPresent(ClassifyReply.self, forKey: .classify) {
            self = .classify(reply)
        } else if let reply = try container.decodeIfPresent(ListPacksReply.self, forKey: .listPacks) {
            self = .listPacks(reply)
        } else if let reply = try container.decodeIfPresent(SetPackEnabledReply.self, forKey: .setPackEnabled) {
            self = .setPackEnabled(reply)
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
