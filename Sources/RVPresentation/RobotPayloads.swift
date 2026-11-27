import RVDomain

/// Robot schema identifiers owned by Presentation.
public enum RobotSchema {
    public static let test = "rv.test.v1"
    public static let explain = "rv.explain.v1"
    public static let doctor = "rv.doctor.v1"
    public static let packs = "rv.packs.v1"
    public static let scanSessions = "rv.scan.sessions.v1"
}

/// `rv.test.v1` object. Keys stay stable.
public struct TestRobotPayload: Equatable, Sendable, Encodable {
    public var schema: String
    public var decision: String
    public var packID: String?
    public var ruleID: String?
    public var reason: String?
    /// `observe` only when observe let the would-be `decision` run.
    package var mode: String? = nil
    /// What the hook did instead (`allow`); set with `mode`.
    package var effective: String? = nil

    enum CodingKeys: String, CodingKey {
        case schema
        case decision
        case packID = "pack_id"
        case ruleID = "rule_id"
        case reason
        case mode
        case effective
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
    /// `observe` only when observe let the would-be `decision` run.
    package var mode: String? = nil
    /// What the hook did instead (`allow`); set with `mode`.
    package var effective: String? = nil
    /// Typed rules that also match but did not decide; omitted when none.
    package var typedRules: [ExplainAlsoMatch]? = nil

    enum CodingKeys: String, CodingKey {
        case schema
        case decision
        case packID = "pack_id"
        case ruleID = "rule_id"
        case reason
        case explanation
        case nextAction = "next_action"
        case mode
        case effective
        case typedRules = "typed_rules"
    }
}

/// `rv.doctor.v1` object. Field set matches the previous CLI private struct.
public struct DoctorRobotPayload: Equatable, Sendable, Encodable {
    public struct Service: Equatable, Sendable, Encodable {
        public var state: String
        public var protocolName: String
        public var serviceSemver: String?
        /// The core packs load locally. Not a hook fallback: hooks have
        /// none, and deny or ask whenever rvd does not answer.
        public var localPacksReady: Bool
        public var launchAgent: String
        public var warning: String?
        /// Installed-rvd trust verdict; omitted when not evaluated.
        public var trust: Trust?

        enum CodingKeys: String, CodingKey {
            case state
            case protocolName = "protocol"
            case serviceSemver = "service_semver"
            case localPacksReady = "local_packs_ready"
            case launchAgent = "launch_agent"
            case warning
            case trust
        }
    }

    /// `DoctorServiceTrust`; `reason` omitted when satisfied.
    public struct Trust: Equatable, Sendable, Encodable {
        public var source: String
        public var satisfied: Bool
        public var reason: String?
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

    /// Counts are omitted when not applicable; `stranded_images` also when unknown.
    public struct Leftovers: Equatable, Sendable, Encodable {
        public var applicable: Bool
        public var sessions: Int?
        public var strandedImages: Int?
        public var unattachedImageFiles: Int?

        enum CodingKeys: String, CodingKey {
            case applicable
            case sessions
            case strandedImages = "stranded_images"
            case unattachedImageFiles = "unattached_image_files"
        }
    }

    public var schema: String
    public var service: Service
    public var packs: Packs
    public var hosts: [String: String]
    public var config: String
    public var grade: String
    public var isHealthy: Bool
    public var leftovers: Leftovers?
    /// Install problems with repair hints; omitted when there are none.
    public var problems: [Problem]?

    /// One install problem (`DoctorProblem`).
    public struct Problem: Equatable, Sendable, Encodable {
        public var id: String
        public var severity: String
        public var summary: String
        public var fix: String
    }

    enum CodingKeys: String, CodingKey {
        case schema
        case service
        case packs
        case hosts
        case config
        case grade
        case isHealthy = "ok"
        case leftovers
        case problems
    }
}

/// One `rv.packs.v1` row (also the `packs info` robot object).
public struct PacksRobotRow: Equatable, Sendable, Encodable {
    public var id: String
    public var name: String
    public var category: String
    public var description: String
    public var isEnabled: Bool
    public var safePatternCount: Int
    public var destructivePatternCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case category
        case description
        case isEnabled = "enabled"
        case safePatternCount = "safe_pattern_count"
        case destructivePatternCount = "destructive_pattern_count"
    }

    public init(
        id: PackID,
        name: String,
        category: String,
        description: String,
        isEnabled: Bool,
        safePatternCount: Int,
        destructivePatternCount: Int
    ) {
        self.id = id.rawValue
        self.name = name
        self.category = category
        self.description = description
        self.isEnabled = isEnabled
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

/// `observed`: observe let `result` (the would-be verdict) run; adds
/// `mode` / `effective`.
public func testRobotPayload(from result: EvaluationResult, observed: Bool = false) -> TestRobotPayload {
    var payload = baseTestRobotPayload(from: result)
    if observed {
        payload.mode = observeRobotMode
        payload.effective = observeRobotEffective
    }
    return payload
}

private func baseTestRobotPayload(from result: EvaluationResult) -> TestRobotPayload {
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

/// Observe fields follow `model.observeNote`: set only when observe let
/// the would-be decision run.
public func explainRobotPayload(from model: ExplainViewModel) -> ExplainRobotPayload {
    let observed = model.observeNote != nil
    return ExplainRobotPayload(
        schema: RobotSchema.explain,
        decision: robotDecision(model.decision),
        packID: model.packID?.rawValue,
        ruleID: model.ruleID?.rawValue,
        reason: model.fact,
        explanation: model.explanation,
        nextAction: model.nextAction,
        mode: observed ? observeRobotMode : nil,
        effective: observed ? observeRobotEffective : nil,
        typedRules: model.alsoMatches.isEmpty ? nil : model.alsoMatches
    )
}

public func doctorRobotPayload(from model: DoctorViewModel) -> DoctorRobotPayload {
    DoctorRobotPayload(
        schema: RobotSchema.doctor,
        service: DoctorRobotPayload.Service(
            state: model.service.state.rawValue,
            protocolName: model.service.protocolName,
            serviceSemver: model.service.serviceSemver,
            localPacksReady: model.service.fallback == .ready,
            launchAgent: model.service.launchAgent.rawValue,
            warning: model.service.warning,
            trust: model.service.trust.map {
                DoctorRobotPayload.Trust(source: $0.source, satisfied: $0.satisfied, reason: $0.reason)
            }
        ),
        packs: DoctorRobotPayload.Packs(
            registry: model.packs.registry.rawValue,
            dayOneReady: model.packs.areDayOnePacksReady,
            enabled: model.packs.enabled.map(\.rawValue),
            extrasEnabled: model.packs.extrasEnabled.map(\.rawValue)
        ),
        hosts: Dictionary(
            uniqueKeysWithValues: model.hosts.map { ($0.host.rawValue, $0.state.rawValue) }
        ),
        config: model.config.rawValue,
        grade: model.grade.rawValue,
        isHealthy: model.isHealthy,
        leftovers: model.leftovers.map(doctorRobotLeftovers),
        problems: doctorRobotProblems(model)
    )
}

/// Install problems that already say why rvd is not answering; with one of
/// these, a `service-<state>` row would report the same fault twice.
let doctorRvdFaultProblemIDs: Set<String> = ["rvd-missing", "rvd-startup-backoff"]

/// Every reason doctor fails, the service included: a script that reads
/// only `problems` must not miss an rvd that is down, skewed or missing.
private func doctorRobotProblems(_ model: DoctorViewModel) -> [DoctorRobotPayload.Problem]? {
    var problems = model.problems.map {
        DoctorRobotPayload.Problem(id: $0.id, severity: $0.severity.rawValue, summary: $0.summary, fix: $0.fix)
    }
    let faultAlreadyNamed = model.problems.contains { doctorRvdFaultProblemIDs.contains($0.id) }
    if model.service.state != .running, faultAlreadyNamed == false {
        problems.insert(
            DoctorRobotPayload.Problem(
                id: "service-\(model.service.state.rawValue)",
                severity: DoctorProblemSeverity.fail.rawValue,
                summary: model.service.warning ?? "rvd is \(model.service.state.rawValue); agent commands are refused",
                fix: model.service.fix ?? (model.service.state == .notInstalled ? "rv setup" : "rv service restart")
            ),
            at: 0
        )
    }
    return problems.isEmpty ? nil : problems
}

private func doctorRobotLeftovers(_ view: DoctorLeftoversView) -> DoctorRobotPayload.Leftovers {
    switch view {
    case .notApplicable:
        DoctorRobotPayload.Leftovers(applicable: false)
    case .summary(let summary):
        DoctorRobotPayload.Leftovers(
            applicable: true,
            sessions: summary.sessions,
            strandedImages: summary.strandedImages,
            unattachedImageFiles: summary.unattachedImageFiles
        )
    }
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
