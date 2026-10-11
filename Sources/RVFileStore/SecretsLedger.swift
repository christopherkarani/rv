#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain

/// Single secrets/MCP audit ledger: one record wire type, one hardened
/// append-only writer, one lock, one retention struct.
///
/// `RVIsolation` (broker, invoker) and `RVHistory` (store, shipper) share
/// this module without a package cycle: every hot append lands here through
/// `SecretsLedger.append`, so the ledger file, lock discipline, permissions,
/// and retention mean the same thing on every path. `RVHistory` keeps the
/// store's read/maintenance/ship API on these same types.

// MARK: - Execution and correlation IDs

/// Primary audit key for one secrets/MCP execution (T0c ID taxonomy).
///
/// Minted by the caller (T4/T8) at dispatch time and carried on every audit
/// row for that execution. The matching `PendingApprovalStore` row uses this
/// same value as its `ApprovalID`, so pending waits and audit rows join on
/// one key without a second durability mechanism.
public struct SecretsExecutionID: Hashable, Sendable, Equatable {
    /// Minted identifier value.
    public let rawValue: UUID

    /// Mints a fresh execution id.
    public init() {
        rawValue = UUID()
    }

    /// Names an id RV already minted. Naming one grants nothing.
    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    /// Parses a UUID string. Anything else fails closed to nil.
    public init?(validating text: String) {
        guard let rawValue = UUID(uuidString: text) else { return nil }
        self.rawValue = rawValue
    }
}

extension SecretsExecutionID: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let id = SecretsExecutionID(validating: text) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "invalid SecretsExecutionID"
            )
        }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue.uuidString)
    }
}

/// Error-linkage id (T0c ID taxonomy).
///
/// The caller-visible opaque defect (`Internal tool error [correlationId]`)
/// carries this value; the redacted server-side cause lives on the audit row
/// with the same id. One execution may mint several correlation ids (one per
/// failure); the execution id stays primary.
public struct SecretsCorrelationID: Hashable, Sendable, Equatable {
    /// Minted identifier value.
    public let rawValue: UUID

    /// Mints a fresh correlation id.
    public init() {
        rawValue = UUID()
    }

    /// Names an id RV already minted. Naming one grants nothing.
    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    /// Parses a UUID string. Anything else fails closed to nil.
    public init?(validating text: String) {
        guard let rawValue = UUID(uuidString: text) else { return nil }
        self.rawValue = rawValue
    }
}

extension SecretsCorrelationID: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let id = SecretsCorrelationID(validating: text) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "invalid SecretsCorrelationID"
            )
        }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue.uuidString)
    }
}

// MARK: - Principal, kind, target

/// Labels-only principal for one audit row.
///
/// Instance id, operator definition label, and owner UID. No authority
/// material, no capabilities, no secret values: everything here is safe to
/// retain in the ledger and ship off-host.
public struct SecretsAuditPrincipal: Hashable, Sendable, Equatable {
    /// Concrete execution of the agent definition that acted.
    public var instanceID: AgentInstanceID
    /// Operator-controlled definition label.
    public var definitionID: String
    /// Kernel-derived owner of the acting process.
    public var ownerUID: UInt32

    /// Assembles a principal from label parts.
    public init(instanceID: AgentInstanceID, definitionID: String, ownerUID: UInt32) {
        self.instanceID = instanceID
        self.definitionID = definitionID
        self.ownerUID = ownerUID
    }

    /// Extracts the labels-only projection of a trusted context.
    public init(context: AuthenticatedAgentContext) {
        self.init(
            instanceID: context.instance.id,
            definitionID: context.instance.definitionID.rawValue,
            ownerUID: context.instance.owner.uid
        )
    }

    private enum CodingKeys: String, CodingKey {
        case instanceID
        case definitionID
        case ownerUID
    }
}

extension SecretsAuditPrincipal: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let instanceText = try container.decode(String.self, forKey: .instanceID)
        guard let instanceUUID = UUID(uuidString: instanceText) else {
            throw DecodingError.dataCorruptedError(
                forKey: .instanceID,
                in: container,
                debugDescription: "invalid SecretsAuditPrincipal instanceID"
            )
        }
        self.init(
            instanceID: AgentInstanceID(rawValue: instanceUUID),
            definitionID: try container.decode(String.self, forKey: .definitionID),
            ownerUID: try container.decode(UInt32.self, forKey: .ownerUID)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(instanceID.rawValue.uuidString, forKey: .instanceID)
        try container.encode(definitionID, forKey: .definitionID)
        try container.encode(ownerUID, forKey: .ownerUID)
    }
}

/// Closed audit-event vocabulary. Wire names per spec section 4.5.
public enum SecretsAuditKind: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    /// Broker resolved (or refused) one secret ref.
    case secretResolve = "secret.resolve"
    /// Policy admitted one tool invocation for dispatch.
    case toolDispatch = "tool.dispatch"
    /// A human (or timeout) decided one parked approval.
    case toolApproval = "tool.approval"
    /// One invocation finished; the outcome row closes the execution.
    case toolOutcome = "tool.outcome"
}

/// Labels-only audit target: a secret label triple or a tool address.
///
/// Provider, item, and field names are operator-declared labels, never
/// values: no `SecretValue` can be expressed here by construction.
public enum SecretsAuditAddressOrRef: Sendable, Equatable, Hashable {
    /// One secret ref by labels. Field is nil for whole-item refs.
    case secret(provider: String, item: String, field: String?)
    /// One parsed MCP tool address.
    case tool(MCPToolAddress)
    /// One tool address literal that failed parsing, carried verbatim. The
    /// invoker audits the raw attempted literal when parsing fails, so
    /// decoding must tolerate it: the alternative is a row the reader
    /// cannot see. Re-encodes to the same `{"kind":"tool","address":...}`
    /// shape, so the ledger round-trips it byte-identically.
    case toolRaw(String)

    /// Labels a secret ref. The resolved value is never captured.
    public init(_ ref: SecretRef) {
        self = .secret(provider: ref.provider, item: ref.item, field: ref.field)
    }

    /// Labels a tool address.
    public init(_ address: MCPToolAddress) {
        self = .tool(address)
    }

    /// Labels a tool literal, parsed or raw. Labels only either way.
    public init(toolLiteral literal: String) {
        if let address = try? MCPToolAddress.parse(literal) {
            self = .tool(address)
        } else {
            self = .toolRaw(literal)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case provider
        case item
        case field
        case address
    }
}

extension SecretsAuditAddressOrRef: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "secret":
            self = .secret(
                provider: try container.decode(String.self, forKey: .provider),
                item: try container.decode(String.self, forKey: .item),
                field: try container.decodeIfPresent(String.self, forKey: .field)
            )
        case "tool":
            self.init(toolLiteral: try container.decode(String.self, forKey: .address))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "unknown SecretsAuditAddressOrRef kind"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .secret(let provider, let item, let field):
            try container.encode("secret", forKey: .kind)
            try container.encode(provider, forKey: .provider)
            try container.encode(item, forKey: .item)
            try container.encodeIfPresent(field, forKey: .field)
        case .tool(let address):
            try container.encode("tool", forKey: .kind)
            try container.encode(address.literal, forKey: .address)
        case .toolRaw(let literal):
            try container.encode("tool", forKey: .kind)
            try container.encode(literal, forKey: .address)
        }
    }
}

// MARK: - Decision, cause, record

/// Closed decision vocabulary across all four audit kinds.
public enum SecretsAuditDecision: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    /// `secret.resolve`: the broker served the ref (value never logged).
    case resolved
    /// `tool.dispatch`: policy approved without elicitation.
    case allowed
    /// `tool.dispatch`/`tool.approval`: parked for a human; the wait lives
    /// in `PendingApprovalStore`, never in this ledger.
    case pendingApproval
    /// Dispatch or resolve refused by policy or gate.
    case denied
    /// `tool.approval`: the human authorized the exact parked action.
    case approved
    /// `tool.approval`: the human declined; no credential was touched.
    case declined
    /// `tool.approval`: the wait expired.
    case expired
    /// `tool.approval`: the wait was canceled.
    case canceled
    /// `tool.approval`: the timeout policy closed the wait.
    case timedOut
    /// `tool.approval`: the resolution was delivered exactly once.
    case consumed
    /// `tool.outcome`: the invocation succeeded.
    case succeeded
    /// `tool.outcome`: the invocation failed; see the redacted cause.
    case failed
}

/// Closed decision vocabulary for `secret.resolve` rows. Raw values match
/// `SecretsAuditDecision` exactly; the `secretResolve` factory takes this
/// type so a resolve row can never carry a dispatch, approval, or outcome
/// decision.
public enum SecretResolveDecision: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    /// The broker served the ref (value never logged).
    case resolved
    /// The broker refused the ref; see the cause.
    case denied
}

/// Closed decision vocabulary for `tool.dispatch` rows. Raw values match
/// `SecretsAuditDecision` exactly; the `toolDispatch` factory takes this
/// type so a dispatch row can never carry a resolve, approval, or outcome
/// decision.
public enum ToolDispatchDecision: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    /// Policy approved without elicitation.
    case allowed
    /// Parked for a human; the wait lives in `PendingApprovalStore`,
    /// never in this ledger.
    case pendingApproval
    /// Dispatch refused by policy or gate.
    case denied
}

/// Closed decision vocabulary for `tool.approval` rows. Raw values match
/// `SecretsAuditDecision` exactly; the `toolApproval` factory takes this
/// type so an approval row can never carry a resolve, dispatch, or outcome
/// decision.
public enum ToolApprovalDecision: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    /// Parked for a human; the wait lives in `PendingApprovalStore`,
    /// never in this ledger.
    case pendingApproval
    /// The human authorized the exact parked action.
    case approved
    /// The human declined; no credential was touched.
    case declined
    /// The wait expired.
    case expired
    /// The wait was canceled.
    case canceled
    /// The timeout policy closed the wait.
    case timedOut
    /// The resolution was delivered exactly once.
    case consumed
}

/// Closed decision vocabulary for `tool.outcome` rows. Raw values match
/// `SecretsAuditDecision` exactly; the `toolOutcome` factory takes this
/// type so an outcome row can never carry a resolve, dispatch, or approval
/// decision.
public enum ToolOutcomeDecision: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    /// The invocation succeeded.
    case succeeded
    /// The invocation failed; see the redacted cause.
    case failed
}

extension SecretsAuditDecision {
    /// Lifts a resolve decision to the shared vocabulary. Exhaustive so a
    /// new per-kind case breaks the build until it is classified here.
    public init(_ decision: SecretResolveDecision) {
        switch decision {
        case .resolved:
            self = .resolved
        case .denied:
            self = .denied
        }
    }

    /// Lifts a dispatch decision to the shared vocabulary. Exhaustive so a
    /// new per-kind case breaks the build until it is classified here.
    public init(_ decision: ToolDispatchDecision) {
        switch decision {
        case .allowed:
            self = .allowed
        case .pendingApproval:
            self = .pendingApproval
        case .denied:
            self = .denied
        }
    }

    /// Lifts an approval decision to the shared vocabulary. Exhaustive so a
    /// new per-kind case breaks the build until it is classified here.
    public init(_ decision: ToolApprovalDecision) {
        switch decision {
        case .pendingApproval:
            self = .pendingApproval
        case .approved:
            self = .approved
        case .declined:
            self = .declined
        case .expired:
            self = .expired
        case .canceled:
            self = .canceled
        case .timedOut:
            self = .timedOut
        case .consumed:
            self = .consumed
        }
    }

    /// Lifts an outcome decision to the shared vocabulary. Exhaustive so a
    /// new per-kind case breaks the build until it is classified here.
    public init(_ decision: ToolOutcomeDecision) {
        switch decision {
        case .succeeded:
            self = .succeeded
        case .failed:
            self = .failed
        }
    }
}

/// Redacted free-text cause for one audit row.
///
/// Construction scrubs through the `ReviewSanitizer` rulebook and truncates
/// past `maxLength`, so the ledger can hold the server-side cause (REQ-015)
/// without ever holding secret material.
public struct SecretsAuditCause: Hashable, Sendable, Equatable {
    /// Cause text after rulebook scrubbing and truncation.
    public var redacted: String

    /// Longest stored cause in characters. Longer causes truncate with a marker.
    public static let maxLength = 4096

    /// Scrubs raw cause text through the log rulebook and truncates past the cap.
    public init(redacting raw: String) {
        let scrubbed = ReviewSanitizer.redactLog(raw)
        if scrubbed.count > Self.maxLength {
            redacted = String(scrubbed.prefix(Self.maxLength)) + "...[truncated]"
        } else {
            redacted = scrubbed
        }
    }

    /// T0c provider-only cause: names the failure and the provider id, never
    /// item, field, or values. Exhaustive over the error taxonomy so a new
    /// case breaks the build until it is classified here.
    public init(_ error: SecretsError) {
        let label: String
        switch error {
        case .invalidRef(let provider):
            label = "invalidRef:\(provider)"
        case .notFound(let provider):
            label = "notFound:\(provider)"
        case .denied(let provider):
            label = "denied:\(provider)"
        case .identityRequired:
            label = "identityRequired"
        case .leaseExpired(let provider):
            label = "leaseExpired:\(provider)"
        case .providerDown(let provider):
            label = "providerDown:\(provider)"
        case .oversized(let provider):
            label = "oversized:\(provider)"
        case .policyDenied:
            label = "policyDenied"
        case .timeout(let provider):
            label = "timeout:\(provider)"
        }
        self.init(redacting: label)
    }
}

extension SecretsAuditCause: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        redacted = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(redacted)
    }
}

/// One labels-only audit row (spec section 4.5).
///
/// JSON keys follow the spec taxonomy: `executionId`, `timestamp`,
/// `principal`, `kind`, `addressOrRef`, `decision`, `correlationId`, plus
/// the optional redacted `cause`. Emission call sites land in T4/T8; this
/// file delivers the types and the store those sites append through.
public struct SecretsAuditRecord: Sendable, Equatable, Hashable, Codable {
    /// Primary key: the execution this row belongs to.
    public var executionID: SecretsExecutionID
    /// When the audited event happened.
    public var timestamp: Date
    /// Labels-only acting principal.
    public var principal: SecretsAuditPrincipal
    /// Which audited event this row records. Read-only outside the ledger:
    /// kind and decision are paired at construction by the per-kind
    /// factories, and post-hoc reassignment could reopen an invalid combo.
    public private(set) var kind: SecretsAuditKind
    /// Labels-only target: secret labels or tool address.
    public var addressOrRef: SecretsAuditAddressOrRef
    /// Closed-vocabulary outcome. Read-only outside the ledger: see `kind`.
    public private(set) var decision: SecretsAuditDecision
    /// Error-linkage id for the opaque defect.
    public var correlationID: SecretsCorrelationID
    /// Redacted server-side cause. Nil when there is nothing to explain.
    public var cause: SecretsAuditCause?

    /// Assembles one audit row from validated parts. Internal: the
    /// per-kind factories below are the sole production path, so every row
    /// pairs its kind with a decision from the matching closed vocabulary.
    /// Callers holding an unparseable attempted literal use the
    /// `toolLiteral:` factory overloads instead of this init.
    init(
        executionID: SecretsExecutionID,
        timestamp: Date,
        principal: SecretsAuditPrincipal,
        kind: SecretsAuditKind,
        addressOrRef: SecretsAuditAddressOrRef,
        decision: SecretsAuditDecision,
        correlationID: SecretsCorrelationID,
        cause: SecretsAuditCause? = nil
    ) {
        self.executionID = executionID
        self.timestamp = timestamp
        self.principal = principal
        self.kind = kind
        self.addressOrRef = addressOrRef
        self.decision = decision
        self.correlationID = correlationID
        self.cause = cause
    }

    private enum CodingKeys: String, CodingKey {
        case executionID = "executionId"
        case timestamp
        case principal
        case kind
        case addressOrRef
        case decision
        case correlationID = "correlationId"
        case cause
    }

    /// Builds a `secret.resolve` row for one broker outcome.
    public static func secretResolve(
        executionID: SecretsExecutionID,
        timestamp: Date,
        principal: SecretsAuditPrincipal,
        ref: SecretRef,
        decision: SecretResolveDecision,
        correlationID: SecretsCorrelationID,
        cause: SecretsAuditCause? = nil
    ) -> SecretsAuditRecord {
        SecretsAuditRecord(
            executionID: executionID,
            timestamp: timestamp,
            principal: principal,
            kind: .secretResolve,
            addressOrRef: SecretsAuditAddressOrRef(ref),
            decision: SecretsAuditDecision(decision),
            correlationID: correlationID,
            cause: cause
        )
    }

    /// Builds a `secret.resolve` row for labels that name no valid ref
    /// (staging-drop fallback). The target carries the profile's labels
    /// with only the invalid part substituted, so no drop is ever
    /// unaudited; the per-kind decision keeps the row in the closed
    /// resolve vocabulary. Secret targets only.
    public static func secretResolve(
        executionID: SecretsExecutionID,
        timestamp: Date,
        principal: SecretsAuditPrincipal,
        addressOrRef: SecretsAuditAddressOrRef,
        decision: SecretResolveDecision,
        correlationID: SecretsCorrelationID,
        cause: SecretsAuditCause? = nil
    ) -> SecretsAuditRecord {
        SecretsAuditRecord(
            executionID: executionID,
            timestamp: timestamp,
            principal: principal,
            kind: .secretResolve,
            addressOrRef: addressOrRef,
            decision: SecretsAuditDecision(decision),
            correlationID: correlationID,
            cause: cause
        )
    }

    /// Builds a `tool.dispatch` row for one policy outcome.
    public static func toolDispatch(
        executionID: SecretsExecutionID,
        timestamp: Date,
        principal: SecretsAuditPrincipal,
        address: MCPToolAddress,
        decision: ToolDispatchDecision,
        correlationID: SecretsCorrelationID,
        cause: SecretsAuditCause? = nil
    ) -> SecretsAuditRecord {
        SecretsAuditRecord(
            executionID: executionID,
            timestamp: timestamp,
            principal: principal,
            kind: .toolDispatch,
            addressOrRef: SecretsAuditAddressOrRef(address),
            decision: SecretsAuditDecision(decision),
            correlationID: correlationID,
            cause: cause
        )
    }

    /// Builds a `tool.approval` row for one human (or timeout) decision.
    public static func toolApproval(
        executionID: SecretsExecutionID,
        timestamp: Date,
        principal: SecretsAuditPrincipal,
        address: MCPToolAddress,
        decision: ToolApprovalDecision,
        correlationID: SecretsCorrelationID,
        cause: SecretsAuditCause? = nil
    ) -> SecretsAuditRecord {
        SecretsAuditRecord(
            executionID: executionID,
            timestamp: timestamp,
            principal: principal,
            kind: .toolApproval,
            addressOrRef: SecretsAuditAddressOrRef(address),
            decision: SecretsAuditDecision(decision),
            correlationID: correlationID,
            cause: cause
        )
    }

    /// Builds a `tool.outcome` row closing one execution.
    public static func toolOutcome(
        executionID: SecretsExecutionID,
        timestamp: Date,
        principal: SecretsAuditPrincipal,
        address: MCPToolAddress,
        decision: ToolOutcomeDecision,
        correlationID: SecretsCorrelationID,
        cause: SecretsAuditCause? = nil
    ) -> SecretsAuditRecord {
        SecretsAuditRecord(
            executionID: executionID,
            timestamp: timestamp,
            principal: principal,
            kind: .toolOutcome,
            addressOrRef: SecretsAuditAddressOrRef(address),
            decision: SecretsAuditDecision(decision),
            correlationID: correlationID,
            cause: cause
        )
    }

    /// Builds a `tool.dispatch` row for an attempted literal that failed
    /// parsing. The literal is carried verbatim as the raw target, so no
    /// attempted address is ever unaudited; the per-kind decision keeps the
    /// row in the closed dispatch vocabulary.
    public static func toolDispatch(
        executionID: SecretsExecutionID,
        timestamp: Date,
        principal: SecretsAuditPrincipal,
        toolLiteral: String,
        decision: ToolDispatchDecision,
        correlationID: SecretsCorrelationID,
        cause: SecretsAuditCause? = nil
    ) -> SecretsAuditRecord {
        SecretsAuditRecord(
            executionID: executionID,
            timestamp: timestamp,
            principal: principal,
            kind: .toolDispatch,
            addressOrRef: SecretsAuditAddressOrRef(toolLiteral: toolLiteral),
            decision: SecretsAuditDecision(decision),
            correlationID: correlationID,
            cause: cause
        )
    }

    /// Builds a `tool.approval` row for an attempted literal that failed
    /// parsing. See the `toolDispatch` overload: verbatim raw target with
    /// a closed-vocabulary approval decision.
    public static func toolApproval(
        executionID: SecretsExecutionID,
        timestamp: Date,
        principal: SecretsAuditPrincipal,
        toolLiteral: String,
        decision: ToolApprovalDecision,
        correlationID: SecretsCorrelationID,
        cause: SecretsAuditCause? = nil
    ) -> SecretsAuditRecord {
        SecretsAuditRecord(
            executionID: executionID,
            timestamp: timestamp,
            principal: principal,
            kind: .toolApproval,
            addressOrRef: SecretsAuditAddressOrRef(toolLiteral: toolLiteral),
            decision: SecretsAuditDecision(decision),
            correlationID: correlationID,
            cause: cause
        )
    }

    /// Builds a `tool.outcome` row for an attempted literal that failed
    /// parsing. See the `toolDispatch` overload: verbatim raw target with
    /// a closed-vocabulary outcome decision.
    public static func toolOutcome(
        executionID: SecretsExecutionID,
        timestamp: Date,
        principal: SecretsAuditPrincipal,
        toolLiteral: String,
        decision: ToolOutcomeDecision,
        correlationID: SecretsCorrelationID,
        cause: SecretsAuditCause? = nil
    ) -> SecretsAuditRecord {
        SecretsAuditRecord(
            executionID: executionID,
            timestamp: timestamp,
            principal: principal,
            kind: .toolOutcome,
            addressOrRef: SecretsAuditAddressOrRef(toolLiteral: toolLiteral),
            decision: SecretsAuditDecision(decision),
            correlationID: correlationID,
            cause: cause
        )
    }

    /// Maps a `PendingApprovalStore` row to its audit decision. Pure: the
    /// pending record itself stays in the store; this only classifies the
    /// audit row the T4/T8 call site appends next to it.
    public static func approvalDecision(for approval: PendingApproval) -> ToolApprovalDecision {
        switch approval.state {
        case .awaitingHuman:
            return .pendingApproval
        case .resolved(let resolution):
            return resolution.decision.authorizesExactAction ? .approved : .declined
        case .consumed:
            return .consumed
        case .expired:
            return .expired
        case .canceled:
            return .canceled
        case .timedOut:
            return .timedOut
        }
    }
}

// MARK: - Paths and retention

/// Ledger file layout beside `blocks.jsonl`.
public struct SecretsAuditPaths: Sendable, Equatable {
    /// Hot ledger file name. Single source of truth: every writer and every
    /// test builds the hot path from this name.
    public static let fileName = "secrets-audit.jsonl"
    /// Ledger lock file name. Single source of truth: every path takes
    /// `LOCK_EX` on this file.
    public static let lockFileName = "secrets-audit.lock"
    /// Maintenance temp file name: `<hot>.tmp`. Residue note: a crash
    /// mid-maintenance can leave this sibling behind, and `rv uninstall`
    /// does not remove it.
    public static let tempFileName = fileName + ".tmp"

    /// Config directory holding the ledger.
    public var configDirectory: URL

    /// Creates paths rooted at `configDirectory`.
    public init(configDirectory: URL) {
        self.configDirectory = configDirectory
    }

    /// Hot ledger rows: `<config>/secrets-audit.jsonl`.
    public var fileURL: URL {
        configDirectory.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    /// Lock file: `<config>/secrets-audit.lock`.
    public var lockURL: URL {
        configDirectory.appendingPathComponent(Self.lockFileName, isDirectory: false)
    }

    /// Temp sibling `savePreserving` may leave behind on crash. Residue note:
    /// `rv uninstall` does not remove it.
    public var tempURL: URL {
        configDirectory.appendingPathComponent(Self.tempFileName, isDirectory: false)
    }

    /// Rotated generation file name: `secrets-audit.<n>.jsonl`, `n >= 1`.
    /// Single source of truth: the paths accessor and the at-fd rotation
    /// below both derive from this name.
    public static func rotatedFileName(generation: Int) -> String {
        "secrets-audit.\(generation).jsonl"
    }

    /// Rotated generation: `<config>/secrets-audit.<n>.jsonl`, `n >= 1`.
    /// Generation 1 is the most recent rotation; higher is older.
    public func rotatedURL(generation: Int) -> URL {
        configDirectory.appendingPathComponent(
            Self.rotatedFileName(generation: generation),
            isDirectory: false
        )
    }

    /// Hot ledger artifacts. Residue note: `rv uninstall` does not remove
    /// these, nor rotated `secrets-audit.*.jsonl` generations; listed here
    /// so cleanup callers agree on the set.
    public var uninstallArtifacts: [URL] {
        [fileURL, lockURL, tempURL]
    }
}

/// Deployment-tunable retention (COM-001: duration is deployment policy).
public struct SecretsAuditRetention: Sendable, Equatable {
    /// Newest rows kept after pruning.
    public var maxRows: Int
    /// Age window kept after pruning.
    public var maxAge: TimeInterval
    /// Ledger-full threshold in bytes for the hot file.
    public var maxBytes: Int
    /// Rotated generations kept. Zero disables rotation: over-budget
    /// appends deny instead of rotating.
    public var maxGenerations: Int

    /// Assembles retention from deployment values. Use `validated()` before enforcing.
    public init(maxRows: Int, maxAge: TimeInterval, maxBytes: Int, maxGenerations: Int) {
        self.maxRows = maxRows
        self.maxAge = maxAge
        self.maxBytes = maxBytes
        self.maxGenerations = maxGenerations
    }

    /// Ships-new-defaults retention: 2000 rows, 30 days, 1 MiB, 3 generations.
    public static var `default`: SecretsAuditRetention {
        SecretsAuditRetention(
            maxRows: 2000,
            maxAge: 30 * 24 * 60 * 60,
            maxBytes: 1024 * 1024,
            maxGenerations: 3
        )
    }

    /// Clamps nonsense deployments to enforceable floors.
    public func validated() -> SecretsAuditRetention {
        SecretsAuditRetention(
            maxRows: max(maxRows, 1),
            maxAge: max(maxAge, 1),
            maxBytes: max(maxBytes, 64),
            maxGenerations: max(maxGenerations, 0)
        )
    }
}

/// Fail-closed ledger failures. Callers deny the audited operation.
public enum SecretsLedgerError: Error, Sendable, Equatable {
    /// The ledger is over budget and rotation cannot relieve it: the hot
    /// file plus this batch exceeds `maxBytes` with rotation disabled, or a
    /// single row alone exceeds `maxBytes`. Existing rows are untouched.
    case ledgerFull
    /// A row falls outside retention (older than `maxAge`, or displaced
    /// by newer rows at the `maxRows` cap): nothing was written, so a
    /// success return always means the row persisted.
    case rowExpired
    /// Lock acquisition failed.
    case lockFailed
    /// A record failed JSON encoding; nothing was written.
    case encodeFailed
    /// Any filesystem I/O failure.
    case ioFailed
}

// MARK: - Ledger codec, reads, pruning

/// Single hardened writer and reader for the secrets/MCP audit ledger.
///
/// Every hot append — broker, invoker, and store — lands here: one lock,
/// one `O_APPEND` protocol, one retention gate. Appends never rewrite the
/// file, so undecodable lines (torn writes, unknown future vocabularies)
/// are never deleted by the hot path. Only the explicit maintenance op
/// (`purgeExpired`) rewrites, and it carries undecodable bytes forward
/// verbatim instead of dropping them.
public enum SecretsLedger {
    /// Ledger codec: one `iso8601`/`sortedKeys` line per row.
    static func encodeLine(_ record: SecretsAuditRecord) throws(SecretsLedgerError) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(record),
            let line = String(data: data, encoding: .utf8)
        else {
            throw SecretsLedgerError.encodeFailed
        }
        return line
    }

    /// Decodes one raw file segment, tolerating framing the writer never
    /// emits: trailing CRs are stripped, surrounding whitespace is
    /// trimmed, and empty or undecodable segments read as nil. Matches
    /// `FileLockedJSONLStore.load` line for line.
    static func decodeSegment(_ segment: Data) -> SecretsAuditRecord? {
        guard let line = String(bytes: segment, encoding: .utf8) else {
            return nil
        }
        var withoutCR = line[...]
        while withoutCR.hasSuffix("\r") {
            withoutCR = withoutCR.dropLast()
        }
        let raw = withoutCR.trimmingCharacters(in: .whitespaces)
        guard raw.isEmpty == false,
            let lineData = raw.data(using: .utf8)
        else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SecretsAuditRecord.self, from: lineData)
    }

    /// Raw file segments split on LF bytes, without the separators. Any
    /// read failure (missing file, permission denied, unreadable path)
    /// reads as empty: fail-open, mirroring the store's historical reads.
    static func readSegments(fileURL: URL) -> [Data] {
        guard let data = try? Data(contentsOf: fileURL) else {
            return []
        }
        return data.split(separator: 0x0A).map(Data.init)
    }

    /// Decoded rows from one ledger file, in file order. Undecodable
    /// segments are skipped for reads; maintenance preserves them.
    public static func loadRecords(fileURL: URL) -> [SecretsAuditRecord] {
        readSegments(fileURL: fileURL).compactMap(decodeSegment)
    }

    /// Total order over audit rows: timestamp, then execution id, then
    /// kind. Shared by retention pruning and the off-host ship planner so
    /// both agree on oldest-first.
    public static func orderingKey(of record: SecretsAuditRecord) -> (Date, String, String) {
        (record.timestamp, record.executionID.rawValue.uuidString, record.kind.rawValue)
    }

    /// Rows still inside the age window, oldest-first, capped at `maxRows`
    /// (newest kept). Pure: shared by the append admission gate, reads,
    /// maintenance, and tests.
    public static func pruned(
        _ records: [SecretsAuditRecord],
        now: Date,
        retention: SecretsAuditRetention
    ) -> [SecretsAuditRecord] {
        let retention = retention.validated()
        let cutoff = now.addingTimeInterval(-retention.maxAge)
        // Keys computed once per row: the key embeds a UUID string, which
        // the comparator would otherwise rebuild on every comparison.
        let fresh = records
            .filter { $0.timestamp >= cutoff }
            .map { (orderingKey(of: $0), $0) }
            .sorted { $0.0 < $1.0 }
            .map { $0.1 }
        if fresh.count <= retention.maxRows {
            return fresh
        }
        return Array(fresh.suffix(retention.maxRows))
    }

    /// Appends one batch under the ledger lock with `O_APPEND`.
    ///
    /// Order: encode (pure, no IO) → budget check → rotation-independent
    /// pre-gate → prepare directory → lock → size-check → conditional
    /// rotate → admission gate → trailing-line repair → `O_APPEND`
    /// write → fsync. An empty batch performs no IO: not even the
    /// directory is created.
    ///
    /// The byte budget is enforced here: a batch that would push the hot
    /// file past `maxBytes` rotates first when generations are configured,
    /// otherwise throws `.ledgerFull` with existing rows untouched. A
    /// batch that cannot fit even an empty hot file, or a single row
    /// larger than `maxBytes`, throws `.ledgerFull` without rotating.
    ///
    /// The retention gate is opt-in via `admissionNow`: when set, a batch
    /// retention would immediately drop (backdated past `maxAge`, or
    /// displaced at the `maxRows` cap) throws `.rowExpired` with nothing
    /// written. Batches that fail retention on their own rows alone deny
    /// before rotating, so a denial never evicts history; batches that
    /// would only be displaced by the current hot file still rotate
    /// first, so rotation relieves displacement. The store passes its
    /// clock; broker and invoker hot appends pass nil and enforce the
    /// byte budget only.
    public static func append(
        _ records: [SecretsAuditRecord],
        directory: URL,
        retention: SecretsAuditRetention,
        admissionNow: Date? = nil
    ) throws(SecretsLedgerError) {
        guard records.isEmpty == false else { return }
        let retention = retention.validated()
        var lines: [String] = []
        lines.reserveCapacity(records.count)
        for record in records {
            lines.append(try encodeLine(record))
        }
        let growths = lines.map { $0.utf8.count + 1 }
        guard growths.allSatisfy({ $0 <= retention.maxBytes }) else {
            throw SecretsLedgerError.ledgerFull
        }
        let totalGrowth = growths.reduce(0, +)
        guard totalGrowth <= retention.maxBytes else {
            throw SecretsLedgerError.ledgerFull
        }
        if let admissionNow {
            let selfKept = pruned(records, now: admissionNow, retention: retention)
            guard selfKept.count == records.count else {
                throw SecretsLedgerError.rowExpired
            }
        }
        try withLedgerLock(directory: directory) { (directoryFD: Int32) throws(SecretsLedgerError) in
            var hotFD = try openHot(directoryFD: directoryFD)
            var hotStatus = stat()
            guard fstat(hotFD, &hotStatus) == 0 else {
                close(hotFD)
                throw SecretsLedgerError.ioFailed
            }
            if Int(hotStatus.st_size) + totalGrowth > retention.maxBytes {
                guard retention.maxGenerations > 0 else {
                    close(hotFD)
                    throw SecretsLedgerError.ledgerFull
                }
                close(hotFD)
                try rotateLocked(directoryFD: directoryFD, retention: retention)
                hotFD = try openHot(directoryFD: directoryFD)
            }
            defer { close(hotFD) }
            if let admissionNow {
                let paths = SecretsAuditPaths(configDirectory: directory)
                let kept = pruned(
                    loadRecords(fileURL: paths.fileURL) + records,
                    now: admissionNow,
                    retention: retention
                )
                guard records.allSatisfy({ kept.contains($0) }) else {
                    throw SecretsLedgerError.rowExpired
                }
            }
            try repairTrailingLine(hotFD: hotFD)
            let body = lines.joined(separator: "\n") + "\n"
            guard ledgerWriteAll(Data(body.utf8), to: hotFD) else {
                throw SecretsLedgerError.ioFailed
            }
            guard fsync(hotFD) == 0 else {
                throw SecretsLedgerError.ioFailed
            }
            _ = fsync(directoryFD)
        }
    }

    /// Rotates the hot file to generation 1 when rotation is configured.
    /// Returns false without touching disk when disabled or when the hot
    /// file is missing.
    public static func rotate(
        directory: URL,
        retention: SecretsAuditRetention
    ) throws(SecretsLedgerError) -> Bool {
        let retention = retention.validated()
        guard retention.maxGenerations > 0 else { return false }
        return try withLedgerLock(directory: directory) { (directoryFD: Int32) throws(SecretsLedgerError) in
            let exists = SecretsAuditPaths.fileName.withCString {
                faccessat(directoryFD, $0, F_OK, 0)
            }
            guard exists == 0 else { return false }
            try rotateLocked(directoryFD: directoryFD, retention: retention)
            return true
        }
    }

    /// Drops rows outside retention without appending, carrying every
    /// undecodable content segment forward verbatim. Recovery path after
    /// ledger-full: stale rows leave, and the next append can fit again.
    /// Never deletes bytes it cannot decode: unknown-kind lines, torn
    /// lines, and invalid-UTF-8 segments are rewritten byte-for-byte
    /// after the kept rows instead of being dropped. Blank framing
    /// lines carry no content and are dropped.
    public static func purgeExpired(
        directory: URL,
        retention: SecretsAuditRetention,
        now: Date
    ) throws(SecretsLedgerError) {
        let retention = retention.validated()
        try withLedgerLock(directory: directory) { (directoryFD: Int32) throws(SecretsLedgerError) in
            let paths = SecretsAuditPaths(configDirectory: directory)
            var kept: [SecretsAuditRecord] = []
            var preserved: [Data] = []
            for segment in readSegments(fileURL: paths.fileURL) {
                if let record = decodeSegment(segment) {
                    kept.append(record)
                } else if preservesSegment(segment) {
                    preserved.append(segment)
                }
            }
            try savePreserving(
                pruned(kept, now: now, retention: retention),
                preserved: preserved,
                directoryFD: directoryFD
            )
        }
    }

    /// Runs `body` with `LOCK_EX` held on the ledger lock, passing the
    /// validated directory fd so every path below resolves relative to
    /// it. Prepares the directory (0700) first so the lock file's parent
    /// exists. Only lock setup failures map to `.lockFailed`; body
    /// errors rethrow untouched.
    private static func withLedgerLock<T>(
        directory: URL,
        _ body: (Int32) throws(SecretsLedgerError) -> T
    ) throws(SecretsLedgerError) -> T {
        try prepareDirectory(directory)
        let directoryFD = directory.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard directoryFD >= 0 else { throw SecretsLedgerError.ioFailed }
        defer { close(directoryFD) }
        var directoryStatus = stat()
        guard fstat(directoryFD, &directoryStatus) == 0,
            directoryStatus.st_uid == getuid()
        else {
            throw SecretsLedgerError.ioFailed
        }
        let lockFD = openCreating(
            directoryFD: directoryFD,
            name: SecretsAuditPaths.lockFileName,
            flags: O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC
        )
        guard lockFD >= 0 else { throw SecretsLedgerError.lockFailed }
        defer { close(lockFD) }
        var lockStatus = stat()
        guard fstat(lockFD, &lockStatus) == 0,
            (lockStatus.st_mode & S_IFMT) == S_IFREG,
            lockStatus.st_uid == getuid(),
            fchmod(lockFD, 0o600) == 0
        else {
            throw SecretsLedgerError.lockFailed
        }
        guard flock(lockFD, LOCK_EX) == 0 else {
            throw SecretsLedgerError.lockFailed
        }
        defer { _ = flock(lockFD, LOCK_UN) }
        return try body(directoryFD)
    }

    /// Frames the batch: when the hot file ends mid-line (no trailing
    /// LF, e.g. a torn write from a crashed append), terminates it first
    /// so the batch starts its own decodable line. The torn bytes survive
    /// as their own segment; without this the new rows would fuse onto
    /// the tail and decode as nothing.
    private static func repairTrailingLine(hotFD: Int32) throws(SecretsLedgerError) {
        var status = stat()
        guard fstat(hotFD, &status) == 0 else {
            throw SecretsLedgerError.ioFailed
        }
        guard status.st_size > 0 else { return }
        var last: UInt8 = 0
        while true {
            let got = withUnsafeMutableBytes(of: &last) { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return pread(hotFD, base, 1, status.st_size - 1)
            }
            if got > 0 { break }
            if got == 0 { return }
            guard errno == EINTR else { throw SecretsLedgerError.ioFailed }
        }
        guard last == 0x0A else {
            guard ledgerWriteAll(Data([0x0A]), to: hotFD) else {
                throw SecretsLedgerError.ioFailed
            }
            return
        }
    }

    private static func prepareDirectory(_ directory: URL) throws(SecretsLedgerError) {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        } catch {
            throw SecretsLedgerError.ioFailed
        }
        // Tighten through an O_NOFOLLOW fd, never through the path: a
        // symlinked directory must deny without chmodding its target.
        let fd = directory.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else { throw SecretsLedgerError.ioFailed }
        defer { close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0,
            status.st_uid == getuid(),
            fchmod(fd, 0o700) == 0
        else {
            throw SecretsLedgerError.ioFailed
        }
    }

    /// Opens (creating) one ledger file relative to the directory fd.
    /// Retries spurious `ENOENT` only: racing `openat(O_CREAT)` calls on
    /// one name can observe it transiently (measured ~10% per opener at
    /// 50-way concurrency; path-based `open` never does). Every other
    /// errno — symlinks, permissions, type blocks — returns immediately,
    /// and persistent `ENOENT` gives up after the bound. Returns -1 on
    /// failure; callers map it to their own error.
    private static func openCreating(directoryFD: Int32, name: String, flags: Int32) -> Int32 {
        for _ in 0..<100 {
            let fd = name.withCString {
                openat(directoryFD, $0, flags, 0o600)
            }
            if fd >= 0 { return fd }
            guard errno == ENOENT else { return -1 }
            _ = sched_yield()
        }
        return -1
    }

    /// Opens the hot file for append: no-follow, owner-owned regular
    /// file, tightened to 0600 through the fd. Read-write (not
    /// write-only) so trailing-line repair can read the last byte back
    /// through the same fd; `O_APPEND` still lands every write at the end.
    private static func openHot(directoryFD: Int32) throws(SecretsLedgerError) -> Int32 {
        let fd = openCreating(
            directoryFD: directoryFD,
            name: SecretsAuditPaths.fileName,
            flags: O_RDWR | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC
        )
        guard fd >= 0 else { throw SecretsLedgerError.ioFailed }
        var status = stat()
        guard fstat(fd, &status) == 0,
            (status.st_mode & S_IFMT) == S_IFREG,
            status.st_uid == getuid(),
            fchmod(fd, 0o600) == 0
        else {
            close(fd)
            throw SecretsLedgerError.ioFailed
        }
        return fd
    }

    /// Rotates under the ledger lock using directory-fd-relative calls
    /// only: drops the oldest generation, shifts the rest up by one
    /// (missing middles are skipped), moves the hot file to generation
    /// 1, tightens it to 0600 through an fd, and fsyncs the directory.
    /// The hot file is validated (owner-owned regular file) before
    /// anything moves, so a surprising hot file denies with the ledger
    /// untouched. Shift steps ignore only ENOENT: any other failure
    /// denies before the hot file moves, so an unshifted generation is
    /// never overwritten.
    private static func rotateLocked(
        directoryFD: Int32,
        retention: SecretsAuditRetention
    ) throws(SecretsLedgerError) {
        let probe = SecretsAuditPaths.fileName.withCString {
            openat(directoryFD, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard probe >= 0 else { throw SecretsLedgerError.ioFailed }
        defer { close(probe) }
        var probeStatus = stat()
        guard fstat(probe, &probeStatus) == 0,
            (probeStatus.st_mode & S_IFMT) == S_IFREG,
            probeStatus.st_uid == getuid()
        else {
            throw SecretsLedgerError.ioFailed
        }
        let (unlinkRC, unlinkErrno): (Int32, Int32) = rotatedName(generation: retention.maxGenerations)
            .withCString { nameC in
                let rc = unlinkat(directoryFD, nameC, 0)
                return (rc, rc == 0 ? 0 : errno)
            }
        if unlinkRC != 0, unlinkErrno != ENOENT {
            throw SecretsLedgerError.ioFailed
        }
        if retention.maxGenerations > 1 {
            for generation in stride(from: retention.maxGenerations - 1, through: 1, by: -1) {
                let source = rotatedName(generation: generation)
                let target = rotatedName(generation: generation + 1)
                let (shiftRC, shiftErrno): (Int32, Int32) = source.withCString { sourceC in
                    target.withCString { targetC in
                        let rc = renameat(directoryFD, sourceC, directoryFD, targetC)
                        return (rc, rc == 0 ? 0 : errno)
                    }
                }
                if shiftRC != 0, shiftErrno != ENOENT {
                    throw SecretsLedgerError.ioFailed
                }
            }
        }
        let moved = SecretsAuditPaths.fileName.withCString { hotC in
            rotatedName(generation: 1).withCString { genC in
                renameat(directoryFD, hotC, directoryFD, genC)
            }
        }
        guard moved == 0 else { throw SecretsLedgerError.ioFailed }
        let rotated = rotatedName(generation: 1).withCString {
            openat(directoryFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard rotated >= 0,
            fchmod(rotated, 0o600) == 0
        else {
            if rotated >= 0 { close(rotated) }
            throw SecretsLedgerError.ioFailed
        }
        close(rotated)
        _ = fsync(directoryFD)
    }

    /// Whether an undecodable segment is carried forward by maintenance.
    /// Invalid UTF-8 cannot be judged blank, so it is always preserved;
    /// blank framing lines carry no content and are dropped.
    private static func preservesSegment(_ segment: Data) -> Bool {
        guard let line = String(bytes: segment, encoding: .utf8) else {
            return true
        }
        return line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private static func rotatedName(generation: Int) -> String {
        SecretsAuditPaths.rotatedFileName(generation: generation)
    }

    /// Atomic maintenance save: kept rows re-encoded oldest-first, then
    /// every undecodable segment verbatim, each followed by LF. Temp-file
    /// + fsync + `rename(2)` + directory fsync, 0600 throughout,
    /// resolved relative to the locked directory fd.
    private static func savePreserving(
        _ records: [SecretsAuditRecord],
        preserved: [Data],
        directoryFD: Int32
    ) throws(SecretsLedgerError) {
        var body = Data()
        for record in records {
            body += Data((try encodeLine(record) + "\n").utf8)
        }
        for segment in preserved {
            body += segment
            body += Data([0x0A])
        }
        let tempFD = SecretsAuditPaths.tempFileName.withCString {
            openat(directoryFD, $0, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard tempFD >= 0 else { throw SecretsLedgerError.ioFailed }
        let written = body.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return body.isEmpty }
            var offset = 0
            while offset < body.count {
                let result = write(tempFD, base.advanced(by: offset), body.count - offset)
                if result > 0 { offset += result; continue }
                if result == 0 { return false }
                if errno == EINTR { continue }
                return false
            }
            return true
        }
        let synced = fsync(tempFD) == 0
        let chmodded = fchmod(tempFD, 0o600) == 0
        let closed = close(tempFD) == 0
        guard written, synced, chmodded, closed else {
            SecretsAuditPaths.tempFileName.withCString {
                _ = unlinkat(directoryFD, $0, 0)
            }
            throw SecretsLedgerError.ioFailed
        }
        let renamed = SecretsAuditPaths.tempFileName.withCString { tempC in
            SecretsAuditPaths.fileName.withCString { hotC in
                renameat(directoryFD, tempC, directoryFD, hotC)
            }
        }
        guard renamed == 0 else {
            SecretsAuditPaths.tempFileName.withCString {
                _ = unlinkat(directoryFD, $0, 0)
            }
            throw SecretsLedgerError.ioFailed
        }
        _ = fsync(directoryFD)
        let final = SecretsAuditPaths.fileName.withCString {
            openat(directoryFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard final >= 0,
            fchmod(final, 0o600) == 0
        else {
            if final >= 0 { close(final) }
            throw SecretsLedgerError.ioFailed
        }
        close(final)
    }
}

/// Full `write(2)` loop with `EINTR` retry; `false` on short write or error.
private func ledgerWriteAll(_ data: Data, to fd: Int32) -> Bool {
    var offset = 0
    while offset < data.count {
        let written = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return write(fd, base.advanced(by: offset), data.count - offset)
        }
        if written > 0 { offset += written; continue }
        if written == 0 { return false }
        if errno == EINTR { continue }
        return false
    }
    return true
}
