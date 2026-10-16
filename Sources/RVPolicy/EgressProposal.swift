import Foundation
import RVDomain

/// One live network rule: an exact DNS host plus an exact port.
///
/// Phase 4 live-update channel, network-rule-only by construction: this is
/// the only payload the channel carries, so a live update cannot name a
/// filesystem path, a process, or any other posture. Seatbelt filesystem
/// and process rules stay startup-fixed; only proxy enforcement moves.
///
/// Canonical form mirrors the proxy's `canonicalEgressDNSName`: lowercase,
/// one trailing dot stripped, multi-label LDH, never all-numeric (IP
/// literals are unrepresentable, so a rule can never smuggle a literal
/// past the dial filter). Enforcement re-checks admission through
/// `EgressHostPolicy.allows` semantics plus the public-unicast dial
/// filter, so an invalid rule is inert even if one were constructed.
public struct LiveNetworkRule: Sendable, Hashable, Equatable, Codable {
    public private(set) var host: String
    public private(set) var port: Int

    public init?(host: String, port: Int) {
        guard (1...65535).contains(port) else { return nil }
        guard let canonical = LiveNetworkRule.canonical(host) else { return nil }
        self.host = canonical
        self.port = port
    }

    private enum CodingKeys: String, CodingKey {
        case host
        case port
    }

    /// Decoding re-canonicalizes: a decoded rule carries the same
    /// invariant as a constructed one, so `{"host":"*","port":99999}`
    /// throws instead of materializing an unrepresentable rule.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawHost = try container.decode(String.self, forKey: .host)
        let rawPort = try container.decode(Int.self, forKey: .port)
        guard (1...65535).contains(rawPort),
            let canonical = LiveNetworkRule.canonical(rawHost)
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .host,
                in: container,
                debugDescription: "non-canonical live network rule"
            )
        }
        self.host = canonical
        self.port = rawPort
    }

    private static func canonical(_ raw: String) -> String? {
        var name = raw
        if name.hasSuffix(".") {
            name.removeLast()
        }
        guard name.isEmpty == false,
            name.hasPrefix(".") == false,
            name.hasSuffix(".") == false,
            name.contains("..") == false,
            name.utf8.count <= 253
        else { return nil }
        guard name.allSatisfy({ $0.asciiValue != nil }) else { return nil }
        name = name.lowercased()
        let labels = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard labels.count > 1, labels.allSatisfy({ $0.isEmpty == false }) else { return nil }
        for label in labels {
            guard label.count <= 63 else { return nil }
            guard label.first != "-", label.last != "-" else { return nil }
            guard label.allSatisfy(isLiveRuleLDH) else { return nil }
            if label.hasPrefix("0x") { return nil }
            if label.count > 1, label.first == "0", label.allSatisfy(isLiveRuleASCIIDigit) {
                return nil
            }
        }
        if labels.allSatisfy({ $0.allSatisfy(isLiveRuleASCIIDigit) }) { return nil }
        return name
    }
}

/// What the running proxy last accepted: the enforced generation plus the
/// exact rule set, written by the supervisor after each accepted push.
/// Display status only, never authority (same contract as the denials
/// log): the CLI shows it so an operator can see what is loaded, and a
/// missing or corrupt file reads as unknown, never as denied.
public struct EgressLoadedSnapshot: Sendable, Equatable, Codable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var generation: UInt64
    public var rules: [LiveNetworkRule]
    public var approvalIDs: [String]
    public var updatedAt: Date

    public init(
        generation: UInt64,
        rules: [LiveNetworkRule],
        approvalIDs: [String],
        updatedAt: Date
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.generation = generation
        self.rules = rules.sorted { ($0.host, $0.port) < ($1.host, $1.port) }
        self.approvalIDs = approvalIDs
        self.updatedAt = updatedAt
    }

    /// Parse or nil. Corrupt bytes, a wrong schema version, and rules
    /// that no longer canonicalize all read as unknown; invalid rules
    /// drop individually so one bad row cannot hide the rest.
    public static func parse(_ data: Data) -> EgressLoadedSnapshot? {
        guard let decoded = try? JSONDecoder().decode(Self.self, from: data),
            decoded.schemaVersion == currentSchemaVersion
        else { return nil }
        var snapshot = decoded
        snapshot.rules = decoded.rules.compactMap {
            LiveNetworkRule(host: $0.host, port: $0.port)
        }
        return snapshot
    }
}

private func isLiveRuleLDH(_ character: Character) -> Bool {
    guard let ascii = character.asciiValue else { return false }
    return isLiveRuleASCIIDigit(character) || (ascii >= 97 && ascii <= 122) || ascii == 45
}

private func isLiveRuleASCIIDigit(_ character: Character) -> Bool {
    guard let ascii = character.asciiValue else { return false }
    return ascii >= 48 && ascii <= 57
}

/// Generation-guarded live rule set. OpenShell mirror: a monotonic
/// generation travels with every push and the proxy applies only newer
/// generations, so a stale or reordered push can never narrow (or
/// otherwise rewrite) enforcement.
///
/// Additive-only within a supervisor lifetime: approvals append rules and
/// nothing removes them. A host restart drops the set (fail closed, like
/// the ephemeral allow-once epoch): the next denial mints a fresh
/// proposal. Durable network policy stays the static allowlist file.
public final class NetworkRuleLiveChannel: @unchecked Sendable {
    /// Maximum live rules. Appends past a full channel are refused (fail
    /// closed; the human retries against the static path). Bounds the
    /// per-request supplement check in the proxy.
    public static let maxRules = 1024

    public enum AppendOutcome: Sendable, Equatable {
        case appended(generation: UInt64)
        case duplicate(generation: UInt64)
        case refusedFull(generation: UInt64)
    }

    private let lock = NSLock()
    private var rules: Set<LiveNetworkRule> = []
    private var generation: UInt64 = 0

    public init() {}

    public func append(_ rule: LiveNetworkRule) -> AppendOutcome {
        lock.lock()
        defer { lock.unlock() }
        if rules.contains(rule) {
            return .duplicate(generation: generation)
        }
        guard rules.count < Self.maxRules else {
            return .refusedFull(generation: generation)
        }
        rules.insert(rule)
        generation += 1
        return .appended(generation: generation)
    }

    public func snapshot() -> (rules: Set<LiveNetworkRule>, generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (rules, generation)
    }

    public func contains(_ rule: LiveNetworkRule) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return rules.contains(rule)
    }

    public var currentGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }
}

/// Scoped network proposals on the shared pending-approval review queue
/// (reuse, no parallel approval system).
///
/// A blocked CONNECT produces one proposal whose fingerprint is exactly
/// `egress:<host>:<port>` in canonical form: no path, no query, no
/// wildcard, no neighboring host. The action rides `EffectShell` — the
/// effect-only shape with no analyzed subject — because the fingerprint
/// namespace (`egress:`) cannot collide with any host-door (`<host>:`),
/// file (`file:`), or runtime-HTTP (`runtime:`) spelling, and a dedicated
/// `ProposedAction` case needs an RVDomain change owned by a later phase.
///
/// Identity is workspace-scoped (`egress:<workspace-uuid>`): the shared
/// proxy cannot attribute a denial to one runtime, so proposals never
/// claim a hook session. The agent slot is a fixed mechanical binding,
/// never displayed; reviewers see host/port from the fingerprint.
public enum EgressProposal: Sendable {
    public static let fingerprintPrefix = "egress:"
    public static let sessionPrefix = "egress:"

    /// Fixed agent binding for network proposals. Placeholder: a dedicated
    /// principal case needs an RVDomain `HookHost` change (exhaustive
    /// switches) owned by a later phase. Never displayed to reviewers.
    public static let proposalAgent: HookHost = .grok

    public static func fingerprint(for rule: LiveNetworkRule) -> ActionFingerprint {
        ActionFingerprint(rawValue: "\(fingerprintPrefix)\(rule.host):\(rule.port)")
    }

    /// Strict re-parse of a stored fingerprint. File text is untrusted, so
    /// anything that does not round-trip through `LiveNetworkRule`
    /// validation fails closed here, never at enforcement.
    public static func parse(_ fingerprint: ActionFingerprint) -> LiveNetworkRule? {
        let raw = fingerprint.rawValue
        guard raw.hasPrefix(fingerprintPrefix) else { return nil }
        let rest = String(raw.dropFirst(fingerprintPrefix.count))
        guard let colon = rest.lastIndex(of: ":") else { return nil }
        let host = String(rest[..<colon])
        let portText = String(rest[rest.index(after: colon)...])
        // Canonical port spelling only: `Int` also accepts `+443`/`0443`,
        // which no fingerprint this code mints ever contains.
        guard let port = Int(portText), String(port) == portText else { return nil }
        return LiveNetworkRule(host: host, port: port)
    }

    public static func identity(workspace: WorkspaceSessionID) -> ApprovalIdentity? {
        guard
            let session = SessionID(
                validating: "\(sessionPrefix)\(workspace.rawValue.uuidString.lowercased())"
            )
        else {
            return nil
        }
        return ApprovalIdentity(session: session, agent: proposalAgent)
    }

    /// One scoped proposal: human approval by default (`.mandatoryHuman`,
    /// fail-closed `.autoDeny`, no auto-approve path) with a `.retry`
    /// continuation naming the exact blocked request.
    public static func request(
        id: ApprovalID,
        rule: LiveNetworkRule,
        workspaceSession: WorkspaceSessionID,
        workspaceDirectory: WorkingDirectory,
        ttl: TimeInterval = PendingApprovalRequest.defaultTTL
    ) -> PendingApprovalRequest? {
        guard let identity = identity(workspace: workspaceSession) else { return nil }
        let fingerprint = fingerprint(for: rule)
        let action = ProposedAction.shell(
            .effectOnly(
                EffectShell(
                    fingerprint: fingerprint,
                    scope: ActionScope(workingDirectory: workspaceDirectory)
                )
            )
        )
        return PendingApprovalRequest(
            id: id,
            identity: identity,
            action: action,
            reason: .mandatoryHuman,
            continuation: .retry(fingerprint),
            timeoutPolicy: .autoDeny,
            ttl: ttl
        )
    }

    /// True for rows this queue owns: an effect-only shell with no command
    /// whose fingerprint strictly parses as a live rule. Anything else —
    /// hook asks, file asks, future `.network` rows — is another queue's.
    public static func isNetworkProposal(_ record: PendingApproval) -> Bool {
        guard case .shell(.effectOnly(let shell)) = record.action,
            shell.supportingCommand == nil
        else {
            return false
        }
        return parse(record.fingerprint) != nil
    }

    public static func rule(for record: PendingApproval) -> LiveNetworkRule? {
        guard isNetworkProposal(record) else { return nil }
        return parse(record.fingerprint)
    }
}
