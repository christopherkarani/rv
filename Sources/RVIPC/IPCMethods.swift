import Foundation
import RVDomain

public struct EvaluateParams: Sendable, Equatable, Codable {
    public var request: EvaluationRequest
    public var cwd: WorkingDirectory?
    /// Additive `rv.ipc.v1` field. Old clients omit it and Hello first.
    public var clientSemver: String?

    public init(request: EvaluationRequest, cwd: WorkingDirectory? = nil, clientSemver: String? = nil) {
        self.request = request
        self.cwd = cwd
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
    public var cwd: WorkingDirectory?

    public init(request: EvaluationRequest, cwd: WorkingDirectory? = nil) {
        self.request = request
        self.cwd = cwd
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
        suggestion: String? = nil,
        stages: [ExplainStage]
    ) {
        self.result = result
        self.normalized = normalized
        self.ruleID = result.outcome.explainRuleID
        self.packID = result.outcome.explainPackID
        self.suggestion = suggestion
        self.stages = stages
    }

    enum CodingKeys: String, CodingKey {
        case result
        case normalized
        case ruleID
        case packID
        case suggestion
        case stages
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        result = try container.decode(EvaluationResult.self, forKey: .result)
        normalized = try container.decode(String.self, forKey: .normalized)
        suggestion = try container.decodeIfPresent(String.self, forKey: .suggestion)
        stages = try container.decode([ExplainStage].self, forKey: .stages)
        ruleID = result.outcome.explainRuleID
        packID = result.outcome.explainPackID
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(result, forKey: .result)
        try container.encode(normalized, forKey: .normalized)
        try container.encodeIfPresent(ruleID, forKey: .ruleID)
        try container.encodeIfPresent(packID, forKey: .packID)
        try container.encodeIfPresent(suggestion, forKey: .suggestion)
        try container.encode(stages, forKey: .stages)
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
    /// Total derivation from `EvaluationOutcome`; unmatched deny is `.rated(.high)`.
    public static func derive(_ outcome: EvaluationOutcome) -> ClassifyRisk {
        switch outcome {
        case .quickRejected, .plain, .safeOnly:
            return .safe
        case .hit(let match, _):
            return .rated(match.severity)
        case .deny(_, .some(let match)):
            return .rated(match.severity)
        case .deny(_, .none):
            return .rated(.high)
        case .indeterminate:
            return .rated(.high)
        }
    }
}

public struct ClassifyParams: Sendable, Equatable, Codable {
    public var request: EvaluationRequest
    public var cwd: WorkingDirectory?

    public init(request: EvaluationRequest, cwd: WorkingDirectory? = nil) {
        self.request = request
        self.cwd = cwd
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

    public init(result: EvaluationResult, suggestions: [String] = []) {
        self.decision = result.decision
        self.risk = ClassifyRisk.derive(result.outcome)
        self.ruleID = result.outcome.explainRuleID
        self.packID = result.outcome.explainPackID
        self.suggestions = suggestions
        switch result.outcome {
        case .hit(let match, _), .deny(_, .some(let match)):
            reasons = [
                ClassifyReason(
                    ruleID: match.ruleID,
                    explanation: match.explanation ?? match.reason
                )
            ]
        case .quickRejected, .plain, .safeOnly, .deny(_, .none), .indeterminate:
            reasons = []
        }
    }

    enum CodingKeys: String, CodingKey {
        case decision
        case risk
        case ruleID
        case packID
        case reasons
        case suggestions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        decision = try container.decode(Decision.self, forKey: .decision)
        risk = try container.decode(ClassifyRisk.self, forKey: .risk)
        reasons = try container.decodeIfPresent([ClassifyReason].self, forKey: .reasons) ?? []
        suggestions = try container.decodeIfPresent([String].self, forKey: .suggestions) ?? []
        let siblingRuleID = try container.decodeIfPresent(RuleID.self, forKey: .ruleID)
        let siblingPackID = try container.decodeIfPresent(PackID.self, forKey: .packID)
        switch decision {
        case .allow:
            ruleID = siblingRuleID
            packID = siblingPackID
        case .deny(let deny):
            ruleID = deny.ruleID
            packID = deny.ruleID.pack
        case .indeterminate:
            ruleID = nil
            packID = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(decision, forKey: .decision)
        try container.encode(risk, forKey: .risk)
        try container.encodeIfPresent(ruleID, forKey: .ruleID)
        try container.encodeIfPresent(packID, forKey: .packID)
        try container.encode(reasons, forKey: .reasons)
        try container.encode(suggestions, forKey: .suggestions)
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

public enum RulePolarity: String, Sendable, Equatable {
    case allow
    case block
}

extension RulePolarity: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "allow":
            self = .allow
        case "block":
            self = .block
        default:
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription:
                        "Cannot initialize RulePolarity from invalid String value \(raw)"
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct RulePreviewParams: Sendable, Equatable, Codable {
    public var id: ApprovalID
    public var polarity: RulePolarity

    public init(id: ApprovalID, polarity: RulePolarity) {
        self.id = id
        self.polarity = polarity
    }
}

public struct RulePreviewReply: Sendable, Equatable, Codable {
    public var sentence: String
    public var draft: String
    public var allowedToSave: Bool

    public init(sentence: String, draft: String, allowedToSave: Bool) {
        self.sentence = sentence
        self.draft = draft
        self.allowedToSave = allowedToSave
    }
}

public struct RuleSaveParams: Sendable, Equatable, Codable {
    public var id: ApprovalID
    public var polarity: RulePolarity
    public var draft: String

    public init(id: ApprovalID, polarity: RulePolarity, draft: String) {
        self.id = id
        self.polarity = polarity
        self.draft = draft
    }
}

public struct RuleSaveReply: Sendable, Equatable, Codable {
    public var ruleID: RuleID
    public var waitResolved: Bool

    public init(ruleID: RuleID, waitResolved: Bool) {
        self.ruleID = ruleID
        self.waitResolved = waitResolved
    }
}

public enum IPCMethod: Sendable, Equatable {
    case evaluate(EvaluateParams)
    case hookEvaluate(HookEvaluateParams)
    case explain(ExplainParams)
    case classify(ClassifyParams)
    case listPacks
    case setPackEnabled(SetPackEnabledParams)
    case allowOnceConsume(AllowOnceConsumeParams)
    case doctorSnapshot
    case pendingList
    case pendingWatch(PendingWatchParams)
    case pendingResolve(PendingResolveParams)
    case rulePreview(RulePreviewParams)
    case ruleSave(RuleSaveParams)
}

public enum IPCResult: Sendable, Equatable {
    case evaluate(EvaluateReply)
    case hookEvaluate(HookEvaluateReply)
    case explain(ExplainReply)
    case classify(ClassifyReply)
    case listPacks(ListPacksReply)
    case setPackEnabled(SetPackEnabledReply)
    case allowOnceConsume(AllowOnceConsumeReply)
    case doctorSnapshot(DoctorSnapshotReply)
    case pendingList(PendingListReply)
    case pendingWatch(PendingWatchReply)
    case pendingResolve(PendingResolveReply)
    case rulePreview(RulePreviewReply)
    case ruleSave(RuleSaveReply)
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
        case allowOnceConsume
        case doctorSnapshot
        case pendingList
        case pendingWatch
        case pendingResolve
        case rulePreview
        case ruleSave
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
        case .allowOnceConsume(let params):
            try container.encode(params, forKey: .allowOnceConsume)
        case .doctorSnapshot:
            try container.encode(EmptyPayload(), forKey: .doctorSnapshot)
        case .pendingList:
            try container.encode(EmptyPayload(), forKey: .pendingList)
        case .pendingWatch(let params):
            try container.encode(params, forKey: .pendingWatch)
        case .pendingResolve(let params):
            try container.encode(params, forKey: .pendingResolve)
        case .rulePreview(let params):
            try container.encode(params, forKey: .rulePreview)
        case .ruleSave(let params):
            try container.encode(params, forKey: .ruleSave)
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
        } else if let params = try container.decodeIfPresent(AllowOnceConsumeParams.self, forKey: .allowOnceConsume) {
            self = .allowOnceConsume(params)
        } else if container.contains(.doctorSnapshot) {
            self = .doctorSnapshot
        } else if container.contains(.pendingList) {
            self = .pendingList
        } else if let params = try container.decodeIfPresent(PendingWatchParams.self, forKey: .pendingWatch) {
            self = .pendingWatch(params)
        } else if let params = try container.decodeIfPresent(PendingResolveParams.self, forKey: .pendingResolve) {
            self = .pendingResolve(params)
        } else if let params = try container.decodeIfPresent(RulePreviewParams.self, forKey: .rulePreview) {
            self = .rulePreview(params)
        } else if let params = try container.decodeIfPresent(RuleSaveParams.self, forKey: .ruleSave) {
            self = .ruleSave(params)
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
        case allowOnceConsume
        case doctorSnapshot
        case pendingList
        case pendingWatch
        case pendingResolve
        case rulePreview
        case ruleSave
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
        case .allowOnceConsume(let reply):
            try container.encode(reply, forKey: .allowOnceConsume)
        case .doctorSnapshot(let reply):
            try container.encode(reply, forKey: .doctorSnapshot)
        case .pendingList(let reply):
            try container.encode(reply, forKey: .pendingList)
        case .pendingWatch(let reply):
            try container.encode(reply, forKey: .pendingWatch)
        case .pendingResolve(let reply):
            try container.encode(reply, forKey: .pendingResolve)
        case .rulePreview(let reply):
            try container.encode(reply, forKey: .rulePreview)
        case .ruleSave(let reply):
            try container.encode(reply, forKey: .ruleSave)
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
        } else if let reply = try container.decodeIfPresent(AllowOnceConsumeReply.self, forKey: .allowOnceConsume) {
            self = .allowOnceConsume(reply)
        } else if let reply = try container.decodeIfPresent(DoctorSnapshotReply.self, forKey: .doctorSnapshot) {
            self = .doctorSnapshot(reply)
        } else if let reply = try container.decodeIfPresent(PendingListReply.self, forKey: .pendingList) {
            self = .pendingList(reply)
        } else if let reply = try container.decodeIfPresent(PendingWatchReply.self, forKey: .pendingWatch) {
            self = .pendingWatch(reply)
        } else if let reply = try container.decodeIfPresent(PendingResolveReply.self, forKey: .pendingResolve) {
            self = .pendingResolve(reply)
        } else if let reply = try container.decodeIfPresent(RulePreviewReply.self, forKey: .rulePreview) {
            self = .rulePreview(reply)
        } else if let reply = try container.decodeIfPresent(RuleSaveReply.self, forKey: .ruleSave) {
            self = .ruleSave(reply)
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

    static func nonempty(_ cwd: String?) -> WorkingDirectory? {
        cwd.flatMap { WorkingDirectory(validating: $0) }
    }

    static func decode(from decoder: Decoder) throws -> (EvaluationRequest, WorkingDirectory?) {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let request = try container.decode(EvaluationRequest.self, forKey: .request)
        let cwd = nonempty(try container.decodeIfPresent(String.self, forKey: .cwd))
        return (request, cwd)
    }

    static func encode(request: EvaluationRequest, cwd: WorkingDirectory?, to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(request, forKey: .request)
        try container.encodeIfPresent(cwd, forKey: .cwd)
    }
}
