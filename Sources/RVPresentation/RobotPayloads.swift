import RVDomain

/// Robot schema identifiers owned by Presentation.
public enum RobotSchema {
    public static let test = "rv.test.v1"
    public static let explain = "rv.explain.v1"
    public static let doctor = "rv.doctor.v1"
    public static let packs = "rv.packs.v1"
}

/// `rv.test.v1` object. Keys stay stable.
public struct TestRobotPayload: Equatable, Sendable, Encodable {
    public var schema: String
    public var decision: String
    public var packID: String?
    public var ruleID: String?
    public var reason: String?

    enum CodingKeys: String, CodingKey {
        case schema
        case decision
        case packID = "pack_id"
        case ruleID = "rule_id"
        case reason
    }
}

/// `rv.explain.v1` object projected from `ExplainViewModel`.
public struct ExplainRobotPayload: Equatable, Sendable, Encodable {
    public var schema: String
    public var decision: String
    public var packID: String?
    public var ruleID: String?
    public var reason: String?
    public var explanation: String?
    public var nextAction: String?

    enum CodingKeys: String, CodingKey {
        case schema
        case decision
        case packID = "pack_id"
        case ruleID = "rule_id"
        case reason
        case explanation
        case nextAction = "next_action"
    }
}

/// `rv.doctor.v1` object. Field set matches the previous CLI private struct.
public struct DoctorRobotPayload: Equatable, Sendable, Encodable {
    public struct Service: Equatable, Sendable, Encodable {
        public var state: String
        public var protocolName: String
        public var serviceSemver: String?
        public var fallbackReady: Bool
        public var launchAgent: String
        public var warning: String?

        enum CodingKeys: String, CodingKey {
            case state
            case protocolName = "protocol"
            case serviceSemver = "service_semver"
            case fallbackReady = "fallback_ready"
            case launchAgent = "launch_agent"
            case warning
        }
    }

    public struct Packs: Equatable, Sendable, Encodable {
        public var registry: String
        public var dayOneReady: Bool
        public var enabled: [String]
        public var extrasEnabled: [String]

        enum CodingKeys: String, CodingKey {
            case registry
            case dayOneReady = "day_one_ready"
            case enabled
            case extrasEnabled = "extras_enabled"
        }
    }

    public var schema: String
    public var service: Service
    public var packs: Packs
    public var hosts: [String: String]
    public var config: String
    public var grade: String
    public var ok: Bool
}

/// One `rv.packs.v1` row (also the `packs info` robot object).
public struct PacksRobotRow: Equatable, Sendable, Encodable {
    public var id: String
    public var name: String
    public var category: String
    public var description: String
    public var enabled: Bool
    public var safePatternCount: Int
    public var destructivePatternCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case category
        case description
        case enabled
        case safePatternCount = "safe_pattern_count"
        case destructivePatternCount = "destructive_pattern_count"
    }

    public init(
        id: PackID,
        name: String,
        category: String,
        description: String,
        enabled: Bool,
        safePatternCount: Int,
        destructivePatternCount: Int
    ) {
        self.id = id.rawValue
        self.name = name
        self.category = category
        self.description = description
        self.enabled = enabled
        self.safePatternCount = safePatternCount
        self.destructivePatternCount = destructivePatternCount
    }
}

/// `rv.packs.v1` list object.
public struct PacksRobotPayload: Equatable, Sendable, Encodable {
    public var schema: String
    public var packs: [PacksRobotRow]
    public var enabledCount: Int
    public var totalCount: Int

    enum CodingKeys: String, CodingKey {
        case schema
        case packs
        case enabledCount = "enabled_count"
        case totalCount = "total_count"
    }
}

public func testRobotPayload(from result: EvaluationResult) -> TestRobotPayload {
    switch result.decision {
    case .allow:
        return TestRobotPayload(
            schema: RobotSchema.test,
            decision: "allow",
            packID: nil,
            ruleID: nil,
            reason: nil
        )
    case .deny(let deny):
        return TestRobotPayload(
            schema: RobotSchema.test,
            decision: "deny",
            packID: deny.ruleID.pack.rawValue,
            ruleID: deny.ruleID.rawValue,
            reason: factSentence(from: deny.reason)
        )
    case .indeterminate:
        return TestRobotPayload(
            schema: RobotSchema.test,
            decision: "indeterminate",
            packID: nil,
            ruleID: nil,
            reason: incompleteEvalSentence
        )
    }
}

public func explainRobotPayload(from model: ExplainViewModel) -> ExplainRobotPayload {
    ExplainRobotPayload(
        schema: RobotSchema.explain,
        decision: robotDecision(model.decision),
        packID: model.packID?.rawValue,
        ruleID: model.ruleID?.rawValue,
        reason: model.fact,
        explanation: model.explanation,
        nextAction: model.nextAction
    )
}

public func doctorRobotPayload(from model: DoctorViewModel) -> DoctorRobotPayload {
    DoctorRobotPayload(
        schema: RobotSchema.doctor,
        service: DoctorRobotPayload.Service(
            state: model.service.state.rawValue,
            protocolName: model.service.protocolName,
            serviceSemver: model.service.serviceSemver,
            fallbackReady: model.service.fallback == .ready,
            launchAgent: model.service.launchAgent.rawValue,
            warning: model.service.warning
        ),
        packs: DoctorRobotPayload.Packs(
            registry: model.packs.registry.rawValue,
            dayOneReady: model.packs.areDayOnePacksReady,
            enabled: model.packs.enabled.map(\.rawValue),
            extrasEnabled: model.packs.extrasEnabled.map(\.rawValue)
        ),
        hosts: Dictionary(
            uniqueKeysWithValues: model.hosts.map { ($0.host.robotName, $0.state.rawValue) }
        ),
        config: model.config.rawValue,
        grade: model.grade.rawValue,
        ok: model.isHealthy
    )
}

public func packsRobotPayload(
    rows: [PacksRobotRow],
    enabledCount: Int,
    totalCount: Int
) -> PacksRobotPayload {
    PacksRobotPayload(
        schema: RobotSchema.packs,
        packs: rows,
        enabledCount: enabledCount,
        totalCount: totalCount
    )
}

private func robotDecision(_ decision: Decision) -> String {
    switch decision {
    case .allow:
        "allow"
    case .deny:
        "deny"
    case .indeterminate:
        "indeterminate"
    }
}

extension SetupHostKind {
    fileprivate var robotName: String {
        switch self {
        case .grok:
            "grok"
        case .pi:
            "pi"
        case .openCode:
            "opencode"
        case .claude:
            "claude"
        }
    }
}
