import Foundation
import RVDomain
import RVFileStore

// MARK: - Policy provenance labels

extension ToolPattern {
    /// Stable human label for the elicitation prompt: the pattern shape the
    /// winning rule matched, never a value.
    public var elicitationLabel: String {
        switch self {
        case .exact(let address):
            return "exact:\(address.literal)"
        case .any:
            return "any"
        case .trailingPrefix(let prefix):
            return "prefix:\(prefix)"
        case .singleMid(let prefix, let suffix):
            return "mid:\(prefix)*\(suffix)"
        case .segments(let pattern):
            return "segments:\(pattern.rawValue)"
        }
    }
}

extension EffectivePolicy {
    /// Provenance label for the elicitation prompt: the winning rule id,
    /// the static-pin literal, or the plugin-default fallback marker.
    public var elicitationLabel: String {
        switch provenance {
        case .fallback:
            return "plugin-default"
        case .staticPin(let literal):
            return "static:\(literal)"
        case .pattern(let id, _):
            return "policy:\(id)"
        }
    }
}

// MARK: - Argument validation

/// Validated tool arguments: a JSON object within size caps.
public struct MCPToolArguments: Hashable, Sendable, Equatable {
    /// Canonical arguments JSON object text. Read-only outside the
    /// validator's module: the text passed the schema at construction, and
    /// post-hoc reassignment could smuggle in an unvalidated object.
    public private(set) var json: String

    /// Largest arguments text accepted.
    public static let maximumBytes = 8_192
    /// Most keys accepted in the object.
    public static let maximumKeys = 64

    /// Assembles validated arguments. Internal: `MCPArgumentValidator` is
    /// the sole production factory, so every instance passed the schema.
    init(json: String) {
        self.json = json
    }
}

/// Per-tool argument shape: required keys plus caps.
public struct MCPArgumentSchema: Hashable, Sendable, Equatable {
    /// Keys that must be present with non-null values.
    public var requiredKeys: [String]
    /// Largest arguments text accepted for this tool.
    public var maximumBytes: Int
    /// Most keys accepted for this tool.
    public var maximumKeys: Int

    /// Assembles one schema from validated parts.
    public init(requiredKeys: [String] = [], maximumBytes: Int = MCPToolArguments.maximumBytes, maximumKeys: Int = MCPToolArguments.maximumKeys) {
        self.requiredKeys = requiredKeys
        self.maximumBytes = maximumBytes
        self.maximumKeys = maximumKeys
    }
}

/// Typed argument failures. Labels only; offending values never echo.
public enum MCPArgumentValidationError: Error, Hashable, Sendable, Equatable {
    /// The text is not a JSON object.
    case malformed
    /// The text exceeds the byte cap.
    case oversized
    /// The object holds too many keys.
    case tooManyKeys
    /// A key name is empty or overlong (label carries the index, not the key).
    case badKey(index: Int)
    /// A required key is missing or null (label carries the key name, which
    /// is schema vocabulary, never a value).
    case missingRequired(key: String)
}

/// Pure argument validator: per-address schemas with a default.
///
/// Validation runs after policy resolve and before elicitation (REQ-012),
/// so a malformed call never parks a human wait and never touches a secret.
public struct MCPArgumentValidator: Sendable {
    /// Schemas by exact address.
    public var schemas: [MCPToolAddress: MCPArgumentSchema]
    /// Schema for addresses without an entry.
    public var defaultSchema: MCPArgumentSchema

    /// Validates with per-address schemas plus a default.
    public init(schemas: [MCPToolAddress: MCPArgumentSchema] = [:], defaultSchema: MCPArgumentSchema = MCPArgumentSchema()) {
        self.schemas = schemas
        self.defaultSchema = defaultSchema
    }

    /// Validates raw arguments text for one address.
    public func validate(_ raw: String, for address: MCPToolAddress) throws(MCPArgumentValidationError) -> MCPToolArguments {
        let schema = schemas[address] ?? defaultSchema
        let bytes = Data(raw.utf8)
        guard bytes.count <= schema.maximumBytes else {
            throw MCPArgumentValidationError.oversized
        }
        guard let top = try? JSONSerialization.jsonObject(with: bytes),
            let object = top as? [String: Any]
        else {
            throw MCPArgumentValidationError.malformed
        }
        guard object.count <= schema.maximumKeys else {
            throw MCPArgumentValidationError.tooManyKeys
        }
        for (index, key) in object.keys.sorted().enumerated() {
            guard key.isEmpty == false, key.count <= 128 else {
                throw MCPArgumentValidationError.badKey(index: index)
            }
        }
        for key in schema.requiredKeys {
            guard let value = object[key], value is NSNull == false else {
                throw MCPArgumentValidationError.missingRequired(key: key)
            }
        }
        return MCPToolArguments(json: raw)
    }
}

// MARK: - Elicitation prompt

/// One approval prompt shown to the operator (SEC-006): tool address, the
/// matched policy provenance, and a capped, redacted argument preview.
/// Prompts carry labels only; secret-shaped values are scrubbed at build.
public struct MCPElicitationPrompt: Hashable, Sendable, Equatable, Codable {
    /// Canonical tool address literal.
    public var address: String
    /// Matched-pattern provenance label (see `EffectivePolicy.elicitationLabel`).
    public var matchedPattern: String
    /// Argument preview after redaction and capping.
    public var argumentPreview: String
    /// Idempotency key binding this prompt to one execution.
    public var idempotencyKey: String

    /// Longest preview in characters before the truncation marker.
    public static let maximumPreviewCharacters = 512

    /// Assembles one prompt from validated parts.
    public init(address: String, matchedPattern: String, argumentPreview: String, idempotencyKey: String) {
        self.address = address
        self.matchedPattern = matchedPattern
        self.argumentPreview = argumentPreview
        self.idempotencyKey = idempotencyKey
    }

    /// Builds the prompt for one validated call: redacts the arguments
    /// through the log rulebook, then caps past the preview limit.
    public static func build(
        address: MCPToolAddress,
        policy: EffectivePolicy,
        arguments: MCPToolArguments,
        idempotencyKey: String
    ) -> MCPElicitationPrompt {
        let scrubbed = ReviewSanitizer.redactLog(arguments.json)
        let preview: String
        if scrubbed.count > maximumPreviewCharacters {
            preview = String(scrubbed.prefix(maximumPreviewCharacters)) + "...[truncated]"
        } else {
            preview = scrubbed
        }
        return MCPElicitationPrompt(
            address: address.literal,
            matchedPattern: policy.elicitationLabel,
            argumentPreview: preview,
            idempotencyKey: idempotencyKey
        )
    }
}

/// SSE framing for elicitation prompts and answers over streamable HTTP.
///
/// Prompts ride `event: elicitation` with the prompt JSON as data; answers
/// ride `event: elicitation-decision` with `{"decision":"approved"}` or
/// `{"decision":"declined"}`. Full duplex in-call wiring lands in X1; T8
/// ships the frame codec plus roundtrip tests.
public enum MCPElicitationSSE {
    /// Renders one prompt frame.
    public static func renderPrompt(_ prompt: MCPElicitationPrompt) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(prompt),
            let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return MCPServerSentEvent(event: MCPServerSentEvent.elicitation, data: text).rendered()
    }

    /// Parses one prompt frame. Nil on any shape drift.
    public static func parsePrompt(_ text: String) -> MCPElicitationPrompt? {
        guard let frame = MCPServerSentEvent.parsed(text),
            frame.event == MCPServerSentEvent.elicitation,
            let data = frame.data.data(using: .utf8)
        else {
            return nil
        }
        return try? JSONDecoder().decode(MCPElicitationPrompt.self, from: data)
    }

    /// Renders one answer frame for a decision.
    public static func renderDecision(_ decision: MCPElicitationDecision) -> String {
        let word = decision == .approved ? "approved" : "declined"
        return MCPServerSentEvent(
            event: MCPServerSentEvent.elicitationDecision,
            data: "{\"decision\":\"\(word)\"}"
        ).rendered()
    }

    /// Parses one answer frame. Nil on any shape drift.
    public static func parseDecision(_ text: String) -> MCPElicitationDecision? {
        guard let frame = MCPServerSentEvent.parsed(text),
            frame.event == MCPServerSentEvent.elicitationDecision
        else {
            return nil
        }
        switch frame.data {
        case "{\"decision\":\"approved\"}":
            return .approved
        case "{\"decision\":\"declined\"}":
            return .declined
        default:
            return nil
        }
    }
}

// MARK: - Elicitation backend

/// The operator's answer to one parked prompt.
public enum MCPElicitationDecision: String, Hashable, Sendable, Equatable, Codable {
    /// The operator authorized this exact call.
    case approved
    /// The operator refused; no secret may be touched.
    case declined
}

/// One parked wait handle. The idempotency key binds replays to one wait.
public struct MCPElicitationTicket: Hashable, Sendable, Equatable {
    /// Minted wait identity.
    public var id: UUID
    /// Execution idempotency key this wait belongs to.
    public var idempotencyKey: String

    /// Assembles one ticket from validated parts.
    public init(id: UUID, idempotencyKey: String) {
        self.id = id
        self.idempotencyKey = idempotencyKey
    }
}

/// Poll-visible wait state. Terminal states end the wait.
public enum MCPElicitationStatus: Hashable, Sendable, Equatable {
    /// Still awaiting the operator.
    case waiting
    /// The operator approved.
    case approved
    /// The operator declined.
    case declined
    /// The wait outlived its TTL.
    case expired
    /// The wait was canceled.
    case canceled

    /// True for approved/declined/expired/canceled.
    public var isTerminal: Bool {
        self != .waiting
    }
}

/// Typed elicitation failures. Labels only.
public enum MCPElicitationError: Error, Hashable, Sendable, Equatable {
    /// Too many concurrent waits (the 8-park cap).
    case parkFull
    /// The ticket names no parked wait.
    case unknownTicket
    /// The grant was already consumed: replays must not run.
    case alreadyConsumed
}

/// Approval park/resume seam mirroring the `askBackend` contract
/// (`ActionApprovalAsking`): park one prompt, poll without consuming,
/// consume the grant at most once, cancel best-effort.
///
/// A `PendingApprovalStore`-backed implementation awaits the T0a
/// `ProposedAction` MCP case (adding an enum case there is outside this
/// ticket's fence); T8 ships the in-memory backend plus this seam and
/// records the store wiring as review evidence.
public protocol MCPElicitationBackend: Sendable {
    /// Parks one prompt for `ttl` seconds. Returns the wait ticket.
    func park(_ prompt: MCPElicitationPrompt, ttl: TimeInterval) async throws -> MCPElicitationTicket
    /// Safe status poll. Never consumes, never a grant.
    func poll(_ ticket: MCPElicitationTicket) async -> MCPElicitationStatus
    /// Atomically consumes the grant. Terminal waits only; exactly once.
    func consume(_ ticket: MCPElicitationTicket) async throws -> MCPElicitationDecision
    /// Best-effort cancel of one wait.
    func cancel(_ ticket: MCPElicitationTicket) async
}

/// In-memory elicitation backend with the 8-park cap.
///
/// At most `maximumParks` waits are parked at once; the 9th park throws
/// `.parkFull` (fail-closed DoS guard, matching the admission channel cap).
/// TTLs are enforced lazily at poll/consume; `resolve` is the operator
/// seam tests and the SSE answer path drive.
public actor InMemoryElicitationBackend: MCPElicitationBackend {
    /// Upper bound on simultaneously parked waits, matching the admission
    /// channel's 8-park cap: beyond it waits fail closed instead of piling up.
    public static let maximumParks = 8

    private struct Parked: Sendable {
        var prompt: MCPElicitationPrompt
        var status: MCPElicitationStatus
        var expiresAt: Date
        var consumed: Bool
    }

    private var parks: [UUID: Parked] = [:]
    private let now: @Sendable () -> Date

    /// Parks with `now` as the clock. Tests inject a scripted clock.
    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// Currently parked (non-terminal, unconsumed) wait count.
    public var parkedCount: Int {
        parks.values.filter { $0.consumed == false && $0.status == .waiting }.count
    }

    /// Tickets of currently parked waits. Operator-console listing seam;
    /// the SSE answer path resolves through these tickets.
    public func parkedTickets() -> [MCPElicitationTicket] {
        parks
            .filter { $0.value.consumed == false && $0.value.status == .waiting }
            .map { MCPElicitationTicket(id: $0.key, idempotencyKey: $0.value.prompt.idempotencyKey) }
    }

    /// Parks one prompt. Full or nonpositive TTL fails closed.
    public func park(_ prompt: MCPElicitationPrompt, ttl: TimeInterval) async throws -> MCPElicitationTicket {
        sweepLocked()
        guard parkedCount < Self.maximumParks, ttl > 0 else {
            throw MCPElicitationError.parkFull
        }
        let ticket = MCPElicitationTicket(id: UUID(), idempotencyKey: prompt.idempotencyKey)
        parks[ticket.id] = Parked(prompt: prompt, status: .waiting, expiresAt: now().addingTimeInterval(ttl), consumed: false)
        return ticket
    }

    /// Polls one wait, expiring it past its TTL. Unknown tickets read canceled.
    public func poll(_ ticket: MCPElicitationTicket) async -> MCPElicitationStatus {
        guard var parked = parks[ticket.id] else {
            return .canceled
        }
        if parked.status == .waiting, now() >= parked.expiresAt {
            parked.status = .expired
            parks[ticket.id] = parked
        }
        return parked.status
    }

    /// Operator seam: resolves a waiting ticket. Terminal and unknown
    /// tickets are left untouched.
    public func resolve(_ ticket: MCPElicitationTicket, decision: MCPElicitationDecision) {
        guard var parked = parks[ticket.id], parked.status == .waiting else {
            return
        }
        parked.status = decision == .approved ? .approved : .declined
        parks[ticket.id] = parked
    }

    /// Consumes one terminal grant exactly once. Waiting tickets throw
    /// `.unknownTicket` (no grant exists yet); replays throw `.alreadyConsumed`.
    public func consume(_ ticket: MCPElicitationTicket) async throws -> MCPElicitationDecision {
        guard var parked = parks[ticket.id] else {
            throw MCPElicitationError.unknownTicket
        }
        if parked.status == .waiting, now() >= parked.expiresAt {
            parked.status = .expired
            parks[ticket.id] = parked
        }
        guard parked.consumed == false else {
            throw MCPElicitationError.alreadyConsumed
        }
        let decision: MCPElicitationDecision
        switch parked.status {
        case .approved:
            decision = .approved
        case .declined:
            decision = .declined
        case .waiting, .expired, .canceled:
            throw MCPElicitationError.unknownTicket
        }
        parked.consumed = true
        parks[ticket.id] = parked
        return decision
    }

    /// Cancels one wait. Unknown tickets are a no-op.
    public func cancel(_ ticket: MCPElicitationTicket) async {
        guard var parked = parks[ticket.id], parked.status == .waiting else {
            return
        }
        parked.status = .canceled
        parks[ticket.id] = parked
    }

    /// Expires stale waits, then evicts consumed and dead (expired or
    /// canceled) parks so the table cannot grow without bound. Live
    /// approved/declined grants stay until consumed. Evicted tickets read
    /// back fail-closed: polls see `.canceled`, consumes throw
    /// `.unknownTicket`.
    private func sweepLocked() {
        let at = now()
        for (id, var parked) in parks where parked.status == .waiting && at >= parked.expiresAt {
            parked.status = .expired
            parks[id] = parked
        }
        for (id, parked) in parks where parked.consumed || parked.status == .expired || parked.status == .canceled {
            parks.removeValue(forKey: id)
        }
    }
}

/// Decline signal (SEC-006, AC-008). Raised when the operator declines;
/// the invoker guarantees no secret resolution or refresh happened first.
public struct ElicitationDeclinedError: Error, Hashable, Sendable, Equatable {
    /// Builds the decline signal.
    public init() {}
}

// MARK: - Credential resolution seam

/// Post-approval connection secret resolution. Called only after policy
/// approves and any elicitation accepts, with the fresh identity context;
/// declined, denied, and invalid calls never reach it.
public struct MCPCredentialResolver: Sendable {
    /// Resolves the connection's secret values for one fresh context.
    public let resolveConnectionValues: @Sendable (String, AuthenticatedAgentContext) async throws -> [SecretRef: SecretValue]

    /// Resolves through `resolveConnectionValues`.
    public init(
        resolveConnectionValues: @escaping @Sendable (String, AuthenticatedAgentContext) async throws -> [SecretRef: SecretValue]
    ) {
        self.resolveConnectionValues = resolveConnectionValues
    }

    /// Resolver over the `SecretBroker` actor. The `refs` closure maps a
    /// connection name to its refs; the broker call is atomic per batch,
    /// so a connection resolves all-or-nothing.
    public static func broker(
        _ broker: SecretBroker,
        refs: @escaping @Sendable (String) -> [SecretRef]
    ) -> MCPCredentialResolver {
        MCPCredentialResolver(resolveConnectionValues: { connection, ctx in
            try await broker.resolve(refs(connection), ctx: ctx)
        })
    }
}

// MARK: - Server-side cause log

/// Server-side cause drain for opaque defects (REQ-015).
///
/// Every record path redacts through the log rulebook before reaching the
/// sink, so causes stay server-side AND value-free. Production passes a
/// file or os_log writer; tests pass a capturing closure.
public struct MCPServerCauseLog: Sendable {
    /// Receives one redacted cause line.
    public var sink: @Sendable (String) -> Void

    /// Logs through `sink`.
    public init(sink: @escaping @Sendable (String) -> Void) {
        self.sink = sink
    }

    /// Discards every cause. Tests without a cause drain use this.
    public static var discarded: MCPServerCauseLog {
        MCPServerCauseLog(sink: { _ in })
    }

    /// Records one cause against its correlation id after redaction.
    public func record(_ cause: String, correlationID: SecretsCorrelationID) {
        sink("tool-error [\(correlationID.rawValue.uuidString)] \(ReviewSanitizer.redactLog(cause))")
    }
}

// MARK: - Invoke shape

/// One invoke step, in fixed order. The invoker reports each completed
/// step to its phase observer; tests pin the exact sequences.
public enum ScopedInvokePhase: Hashable, Sendable, Equatable {
    /// Policy resolved to a non-block verdict.
    case policyResolved
    /// Arguments validated against the schema.
    case argumentsValidated
    /// Elicitation accepted (require_approval path only).
    case approvalAccepted
    /// No elicitation needed (approve path).
    case approvalSkipped
    /// Connection secrets resolved.
    case credentialsResolved
    /// Tool invoked (first attempt finished, whatever the outcome).
    case invoked
    /// Single retry spent (idempotent path only).
    case retried
}

/// Per-call invoke options.
public struct ScopedInvokeOptions: Hashable, Sendable, Equatable {
    /// True when repeating the tool call is safe. The single retry (blip
    /// or post-refresh) is spent only for idempotent calls; non-idempotent
    /// calls attempt exactly once.
    public var idempotent: Bool
    /// Budget per transport roundtrip in seconds.
    public var transportTimeoutSeconds: Double
    /// Elicitation wait TTL in seconds.
    public var elicitationTTLSeconds: TimeInterval
    /// Elicitation poll interval in seconds. Tests inject less.
    public var elicitationPollSeconds: Double

    /// Assembles per-call options from validated parts.
    public init(
        idempotent: Bool,
        transportTimeoutSeconds: Double = 5,
        elicitationTTLSeconds: TimeInterval = 15 * 60,
        elicitationPollSeconds: Double = 0.05
    ) {
        self.idempotent = idempotent
        self.transportTimeoutSeconds = transportTimeoutSeconds
        self.elicitationTTLSeconds = elicitationTTLSeconds
        self.elicitationPollSeconds = elicitationPollSeconds
    }
}

/// One successful invocation result.
public struct MCPInvokeResult: Hashable, Sendable, Equatable {
    /// Tool result body text.
    public var body: String
    /// Execution id joining the audit rows.
    public var executionID: SecretsExecutionID
    /// Transport attempts spent (1, or 2 when the retry fired).
    public var attempts: Int

    /// Assembles one result from validated parts.
    public init(body: String, executionID: SecretsExecutionID, attempts: Int) {
        self.body = body
        self.executionID = executionID
        self.attempts = attempts
    }
}

/// Caller-visible opaque defect (REQ-015, AC-010). The message carries the
/// correlation id only; the cause lives on the cause log and the audit row
/// with the same id.
public struct MCPOpaqueDefect: Hashable, Sendable, Equatable {
    /// Error-linkage id shared with the cause log and audit row.
    public var correlationID: SecretsCorrelationID

    /// Builds the defect for one correlation id.
    public init(correlationID: SecretsCorrelationID) {
        self.correlationID = correlationID
    }

    /// Caller-visible message: `Internal tool error [correlationId]`.
    public var message: String {
        "Internal tool error [\(correlationID.rawValue.uuidString)]"
    }
}

/// Typed invoke failures.
///
/// Policy, validation, elicitation, and credential failures are typed and
/// caller-actionable. Transport and tool failures collapse to `.internalError`
/// carrying only the correlation id; unknown tools and audit failures are
/// typed fail-closed signals. No case echoes values or envelopes.
public enum ScopedInvokeError: Error, Sendable, Equatable {
    /// No authenticated principal; nothing was touched.
    case principalRequired
    /// Policy resolved to block (label carries the matched rule id, if any).
    case policyDenied(matchedPolicyId: String?)
    /// The address is malformed or names no registered tool.
    case unknownTool
    /// The address names a connection outside the session's bound
    /// resource. Denied before policy, elicitation, secrets, and
    /// transport are touched (REQ-013).
    case crossResource
    /// Arguments failed schema validation.
    case invalidArguments(MCPArgumentValidationError)
    /// The elicitation wait expired or was canceled. Declines are not this
    /// case: they raise `ElicitationDeclinedError` directly (AC-008).
    case elicitationTimeout
    /// No wait could park (cap full) or the backend failed.
    case elicitationUnavailable
    /// Post-approval secret resolution failed (typed broker cause).
    case credentialFailed(SecretsError)
    /// The audit append failed; the audited operation was denied.
    case auditFailed
    /// Opaque transport/tool failure. Callers see the message only.
    case internalError(MCPOpaqueDefect)

    /// True for the opaque case.
    public var isOpaque: Bool {
        if case .internalError = self {
            return true
        }
        return false
    }
}

// MARK: - Audit sink

/// Audit append seam. The invoker awaits one append per audited step
/// before proceeding (audit-before-commit): dispatch rows before elicitation
/// or invoke, approval rows before credential resolution, outcome rows
/// before returning. Rows are `SecretsAuditRecord` built by the
/// `toolDispatch`/`toolApproval`/`toolOutcome` factories, so the file-backed
/// production wiring appends to `<directory>/secrets-audit.jsonl` under the
/// shared ledger lock with no conversion step; tests inject a temp directory
/// or a capturing closure.
///
/// Explicit mapping note: the invoker's elicitation errors collapse to a
/// single `.elicitationTimeout` ("expired or was canceled"), so waits that
/// expire, waits the backend cancels, and waits still pending past the
/// caller's deadline all audit as `.expired` today. The `canceled`,
/// `timedOut`, and `consumed` decisions exist on the shared ledger type for
/// vocabulary parity; emitting them precisely is future work that also splits
/// the error enum, and must not change silently.
public struct ScopedInvokerAuditSink: Sendable {
    /// Appends one call's rows. An empty batch appends nothing.
    public var append: @Sendable ([SecretsAuditRecord]) async throws -> Void

    /// Appends through `append`.
    public init(append: @escaping @Sendable ([SecretsAuditRecord]) async throws -> Void) {
        self.append = append
    }

    /// File-backed sink rooted at `directory`, sharing the ledger writer
    /// (and its byte budget) with every other audit path. Ledger failures
    /// surface directly as `SecretsLedgerError`. Tests pass an isolated
    /// temp directory here.
    public static func file(
        directory: URL,
        retention: SecretsAuditRetention = .default
    ) -> ScopedInvokerAuditSink {
        ScopedInvokerAuditSink(append: { records in
            try SecretsLedger.append(records, directory: directory, retention: retention)
        })
    }
}

// MARK: - Dispatch action factory (T0a codec moved by E1-E)

// `MCPDispatchAction`, `MCPDispatchCodecError`, `MCPDispatchDigest`, and
// `MCPDispatchCodec` moved to `RVDomain/RuntimeAdmission.swift` when E1-E
// added the `.mcp` case: a downstream module cannot own an upstream case
// payload. Only this factory stays here — it takes validated
// `MCPToolArguments`, which live in this module.

extension MCPDispatchAction {
    /// Builds the action for one validated call, digesting the arguments.
    public static func build(address: MCPToolAddress, arguments: MCPToolArguments, idempotencyKey: String) -> MCPDispatchAction {
        MCPDispatchAction(
            address: address.literal,
            argsDigest: MCPDispatchDigest.hex(of: arguments.json),
            idempotencyKey: idempotencyKey,
            argumentsJSON: arguments.json
        )
    }
}

// MARK: - Scoped invoker

/// Policy-gated MCP tool invocation with fixed ordering (REQ-012).
///
/// Every call runs policy-resolve, then argument validation, then approval
/// elicitation (only for `require_approval`), then secret resolution, then
/// `invokeTool` over the bound transport with reactive OAuth refresh and a
/// single retry. Ordering is structural: each step's inputs exist only after
/// the previous step succeeds, so a decline provably performs no secret
/// refresh (SEC-006, AC-008), and policy or validation failures never park
/// a wait, never resolve a secret, and never touch the transport.
///
/// Retry rule: at most two transport attempts, and the second only when the
/// call is marked idempotent. 401 spends the retry on one OAuth refresh plus
/// one re-invoke; retryable blips (timeouts, 5xx) spend it on one plain
/// re-invoke. Credential resolution, elicitation, policy, and validation
/// never retry. Non-idempotent calls attempt exactly once.
///
/// Audit rule (audit-before-commit): dispatch rows land before elicitation
/// or invoke, approval rows before secret resolution, outcome rows before
/// returning. Commit-path audit failures deny the call as `.auditFailed`;
/// failure-path audits are best-effort and keep the original error.
/// Task cancellation propagates as `CancellationError` without committing
/// and without further audit, mirroring the broker.
public actor ScopedInvoker {
    private let registry: MCPRegistry
    private let policies: MCPPolicyStore
    private let validator: MCPArgumentValidator
    private let elicitation: any MCPElicitationBackend
    private let credentials: MCPCredentialResolver
    private let transport: any MCPTransport
    private let oauth: MCPOAuthRefresher
    private let audit: ScopedInvokerAuditSink
    private let causes: MCPServerCauseLog
    private let phases: @Sendable (ScopedInvokePhase) -> Void
    private let now: @Sendable () -> Date

    /// Assembles an invoker over its seams. Every seam is injected: tests
    /// pass scripted doubles with call counters that prove the ordering.
    public init(
        registry: MCPRegistry,
        policies: MCPPolicyStore,
        validator: MCPArgumentValidator = MCPArgumentValidator(),
        elicitation: any MCPElicitationBackend,
        credentials: MCPCredentialResolver,
        transport: any MCPTransport,
        oauth: MCPOAuthRefresher = .unavailable,
        audit: ScopedInvokerAuditSink,
        causes: MCPServerCauseLog = .discarded,
        phases: @escaping @Sendable (ScopedInvokePhase) -> Void = { _ in },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.registry = registry
        self.policies = policies
        self.validator = validator
        self.elicitation = elicitation
        self.credentials = credentials
        self.transport = transport
        self.oauth = oauth
        self.audit = audit
        self.causes = causes
        self.phases = phases
        self.now = now
    }

    /// Invokes one tool call through the fixed ordering.
    ///
    /// - Parameters:
    ///   - addressLiteral: Canonical `tools.*` address. Malformed or
    ///     unregistered literals throw `.unknownTool`.
    ///   - argumentsJSON: Raw arguments object text, schema-validated.
    ///   - session: Bound transport session (resource binding enforced).
    ///   - ctx: Fresh identity context. Unusable contexts throw
    ///     `.principalRequired` before anything else is touched.
    ///   - options: Idempotency plus transport and elicitation budgets.
    ///   - idempotencyKey: Key binding this execution's elicitation park and
    ///     transport envelope to one admitted call. The dispatch layer passes
    ///     the admitted wire key so elicitation, transport, and the admission
    ///     fingerprint join on one value; nil mints a fresh key (direct
    ///     callers and tests that do not thread a wire key).
    public func invoke(
        addressLiteral: String,
        argumentsJSON: String,
        session: MCPTransportSession,
        ctx: AuthenticatedAgentContext,
        options: ScopedInvokeOptions,
        idempotencyKey: String? = nil
    ) async throws -> MCPInvokeResult {
        var call = InvokeCall(
            attemptedLiteral: addressLiteral,
            executionID: SecretsExecutionID(),
            idempotencyKey: idempotencyKey ?? UUID().uuidString,
            principal: SecretsAuditPrincipal(context: ctx),
            timestamp: now()
        )
        guard ctx.isUsable else {
            try await deny(.principalRequired, call: call, outcome: true)
        }
        let parsed = try? MCPToolAddress.parse(addressLiteral)
        call.address = parsed
        guard let address = parsed,
            registry.handler(for: address) != nil
        else {
            try await deny(.unknownTool, call: call, outcome: true)
        }
        guard address.connection == session.resource.rawValue else {
            try await deny(.crossResource, call: call, outcome: true)
        }
        let policy = policies.resolve(address)
        guard policy.action != .block else {
            let matched: String?
            switch policy.provenance {
            case .pattern(let id, _):
                matched = id
            case .staticPin(let literal):
                matched = literal
            case .fallback:
                matched = nil
            }
            try await deny(.policyDenied(matchedPolicyId: matched), call: call, outcome: true)
        }
        phases(.policyResolved)
        let validated: MCPToolArguments
        do {
            validated = try validator.validate(argumentsJSON, for: address)
        } catch {
            try await deny(.invalidArguments(error), call: call, outcome: true)
        }
        phases(.argumentsValidated)
        if policy.action == .requireApproval {
            try await commit(call.dispatchRecord(decision: .pendingApproval, correlationID: call.linkageID, cause: nil, timestamp: now()))
            try await elicit(policy: policy, address: address, arguments: validated, call: call, options: options)
            phases(.approvalAccepted)
        } else {
            try await commit(call.dispatchRecord(decision: .allowed, correlationID: call.linkageID, cause: nil, timestamp: now()))
            phases(.approvalSkipped)
        }
        let values: [SecretRef: SecretValue]
        do {
            values = try await credentials.resolveConnectionValues(address.connection, ctx)
        } catch let error as SecretsError {
            try await deny(.credentialFailed(error), call: call, outcome: true)
        } catch {
            if error is CancellationError {
                throw error
            }
            try await deny(.credentialFailed(.providerDown(address.connection)), call: call, outcome: true)
        }
        try Task.checkCancellation()
        phases(.credentialsResolved)
        return try await invokeTool(
            address: address,
            arguments: validated,
            values: values,
            session: session,
            call: call,
            options: options
        )
    }

    // MARK: - Elicitation

    /// Parks, polls, and consumes one approval. Declines raise
    /// `ElicitationDeclinedError`; expiry and cancel throw
    /// `.elicitationTimeout`; an unparkable wait throws `.elicitationUnavailable`.
    private func elicit(
        policy: EffectivePolicy,
        address: MCPToolAddress,
        arguments: MCPToolArguments,
        call: InvokeCall,
        options: ScopedInvokeOptions
    ) async throws -> Void {
        let prompt = MCPElicitationPrompt.build(
            address: address,
            policy: policy,
            arguments: arguments,
            idempotencyKey: call.idempotencyKey
        )
        let ticket: MCPElicitationTicket
        do {
            ticket = try await elicitation.park(prompt, ttl: options.elicitationTTLSeconds)
        } catch {
            if error is CancellationError {
                throw error
            }
            try await deny(.elicitationUnavailable, call: call, outcome: true)
        }
        let status = await waitForTerminal(ticket: ticket, options: options)
        try Task.checkCancellation()
        switch status {
        case .approved, .declined:
            let decision: MCPElicitationDecision
            do {
                decision = try await elicitation.consume(ticket)
            } catch {
                if error is CancellationError {
                    throw error
                }
                await elicitation.cancel(ticket)
                try await deny(.elicitationUnavailable, call: call, outcome: true)
            }
            if decision == .approved {
                try await commit(call.approvalRecord(decision: .approved, correlationID: call.linkageID, cause: nil, timestamp: now()))
                return
            }
            try await decline(call: call)
        case .expired, .canceled, .waiting:
            // Explicit collapse (see the audit-sink mapping note): expired,
            // canceled, and caller-deadline waits share one error and one
            // approval decision until the error enum splits.
            await elicitation.cancel(ticket)
            try await deny(.elicitationTimeout, call: call, approval: .expired, outcome: true)
        }
    }

    /// Polls to a terminal status or the TTL budget. `.waiting` past the
    /// budget is treated as expiry by the caller.
    private func waitForTerminal(
        ticket: MCPElicitationTicket,
        options: ScopedInvokeOptions
    ) async -> MCPElicitationStatus {
        let deadline = now().addingTimeInterval(options.elicitationTTLSeconds)
        while true {
            let status = await elicitation.poll(ticket)
            if status.isTerminal {
                return status
            }
            if now() >= deadline {
                return .waiting
            }
            do {
                try await Task.sleep(for: .seconds(max(options.elicitationPollSeconds, 0.001)))
            } catch {
                return .canceled
            }
        }
    }

    // MARK: - Invoke with retry

    /// Runs the transport attempts: one invoke, plus the single retry for
    /// idempotent calls only. Tool failures collapse to opaque defects with
    /// a server-side cause and a failed outcome row.
    private func invokeTool(
        address: MCPToolAddress,
        arguments: MCPToolArguments,
        values: [SecretRef: SecretValue],
        session: MCPTransportSession,
        call: InvokeCall,
        options: ScopedInvokeOptions
    ) async throws -> MCPInvokeResult {
        let request = MCPTransportRequest(
            address: address,
            argumentsJSON: arguments.json,
            idempotencyKey: call.idempotencyKey,
            authorization: Self.authorization(values: values)
        )
        let first: MCPTransportResponse
        do {
            first = try await timedRoundtrip(request, session: session, budget: options.transportTimeoutSeconds)
        } catch {
            try Task.checkCancellation()
            guard let retry = await retryRequest(
                after: error,
                request: request,
                address: address,
                session: session,
                options: options
            ) else {
                try await failOpaque(error, call: call)
            }
            phases(.retried)
            return try await secondAttempt(request: retry, session: session, call: call, options: options)
        }
        phases(.invoked)
        try await commit(call.outcomeRecord(decision: .succeeded, correlationID: call.linkageID, cause: nil, timestamp: now()))
        return MCPInvokeResult(body: first.body, executionID: call.executionID, attempts: 1)
    }

    /// Runs the single retry attempt. Outcome commits stay outside the
    /// transport catch: a commit failure denies, never re-invokes.
    private func secondAttempt(
        request: MCPTransportRequest,
        session: MCPTransportSession,
        call: InvokeCall,
        options: ScopedInvokeOptions
    ) async throws -> MCPInvokeResult {
        let response: MCPTransportResponse
        do {
            response = try await timedRoundtrip(request, session: session, budget: options.transportTimeoutSeconds)
        } catch {
            try Task.checkCancellation()
            try await failOpaque(error, call: call)
        }
        phases(.invoked)
        try await commit(call.outcomeRecord(decision: .succeeded, correlationID: call.linkageID, cause: nil, timestamp: now()))
        return MCPInvokeResult(body: response.body, executionID: call.executionID, attempts: 2)
    }

    /// Decides the single retry. Returns the (possibly refreshed) request
    /// when the retry is allowed, else nil. Non-idempotent calls, exhausted
    /// budgets, and non-retryable failures never retry.
    private func retryRequest(
        after error: Error,
        request: MCPTransportRequest,
        address: MCPToolAddress,
        session _: MCPTransportSession,
        options: ScopedInvokeOptions
    ) async -> MCPTransportRequest? {
        guard options.idempotent else {
            return nil
        }
        if let transport = error as? MCPTransportError, transport == .unauthenticated {
            let token: MCPOAuthToken
            do {
                token = try await oauth.refresh(address.connection)
            } catch {
                return nil
            }
            guard token.connection == address.connection else {
                return nil
            }
            var refreshed = request
            refreshed.authorization = .bearer(token.accessToken)
            return refreshed
        }
        if let transport = error as? MCPTransportError, transport.isRetryable {
            return request
        }
        return nil
    }

    /// Collapses a tool failure to its opaque defect: cause-logged
    /// server-side, failed-outcome audited, caller sees the id only.
    private func failOpaque(_ error: Error, call: InvokeCall) async throws -> Never {
        if error is CancellationError {
            throw error
        }
        let defect = MCPOpaqueDefect(correlationID: SecretsCorrelationID())
        causes.record(String(describing: error), correlationID: defect.correlationID)
        let cause = SecretsAuditCause(redacting: String(describing: error))
        try? await audit.append([
            call.outcomeRecord(
                decision: .failed,
                correlationID: defect.correlationID,
                cause: cause,
                timestamp: now()
            )
        ])
        throw ScopedInvokeError.internalError(defect)
    }

    /// First `.text` value in ref order wins as the connection bearer.
    /// File-path values are staged files, never header material, and map
    /// to no header. Refs sort by provider, item, then field so
    /// multi-text connections pick deterministically.
    static func authorization(values: [SecretRef: SecretValue]) -> MCPTransportAuthorization? {
        let ordered = values.keys.sorted { left, right in
            if left.provider != right.provider { return left.provider < right.provider }
            if left.item != right.item { return left.item < right.item }
            return (left.field ?? "") < (right.field ?? "")
        }
        for ref in ordered {
            if case .text(let secret) = values[ref] {
                return .bearer(secret)
            }
        }
        return nil
    }

    /// One transport roundtrip under the per-RPC budget. A nonpositive
    /// budget fails immediately without touching the transport.
    private func timedRoundtrip(
        _ request: MCPTransportRequest,
        session: MCPTransportSession,
        budget: Double
    ) async throws -> MCPTransportResponse {
        guard budget > 0 else {
            throw MCPTransportError.requestTimeout
        }
        let outcome: Result<MCPTransportResponse, Error> = await withTaskGroup(
            of: Result<MCPTransportResponse, Error>.self,
            returning: Result<MCPTransportResponse, Error>.self
        ) { group in
            group.addTask {
                do {
                    return .success(try await self.transport.roundtrip(request, session: session))
                } catch {
                    return .failure(error)
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(for: .seconds(budget))
                    return .failure(MCPTransportError.requestTimeout)
                } catch {
                    return .failure(error)
                }
            }
            guard let first = await group.next() else {
                return .failure(MCPTransportError.requestTimeout)
            }
            group.cancelAll()
            return first
        }
        try Task.checkCancellation()
        return try outcome.get()
    }

    // MARK: - Audit commits

    /// Appends one commit-path row. Failures deny the call as `.auditFailed`:
    /// a success return always means the row persisted.
    private func commit(_ record: SecretsAuditRecord) async throws -> Void {
        do {
            try await audit.append([record])
        } catch {
            if error is CancellationError {
                throw error
            }
            throw ScopedInvokeError.auditFailed
        }
    }

    /// Appends best-effort failure rows (dispatch denied, plus the approval
    /// and outcome rows when asked), then throws. Failure-path audit never
    /// masks the original error.
    private func deny(
        _ error: ScopedInvokeError,
        call: InvokeCall,
        approval: ToolApprovalDecision? = nil,
        outcome: Bool = false
    ) async throws -> Never {
        try? await audit.append(
            failureRows(cause: Self.causeLabel(for: error), approval: approval, outcome: outcome, call: call)
        )
        throw error
    }

    /// Appends best-effort decline rows (dispatch denied, approval declined,
    /// outcome failed), then raises `ElicitationDeclinedError` (AC-008).
    private func decline(call: InvokeCall) async throws -> Never {
        try? await audit.append(
            failureRows(cause: "elicitationDeclined", approval: .declined, outcome: true, call: call)
        )
        throw ElicitationDeclinedError()
    }

    /// Builds one call's failure rows for a fixed cause label.
    private func failureRows(
        cause: String,
        approval: ToolApprovalDecision?,
        outcome: Bool,
        call: InvokeCall
    ) -> [SecretsAuditRecord] {
        var rows: [SecretsAuditRecord] = [
            call.dispatchRecord(
                decision: .denied,
                correlationID: call.linkageID,
                cause: SecretsAuditCause(redacting: cause),
                timestamp: now()
            )
        ]
        if let approval {
            rows.append(
                call.approvalRecord(
                    decision: approval,
                    correlationID: call.linkageID,
                    cause: nil,
                    timestamp: now()
                )
            )
        }
        if outcome {
            rows.append(
                call.outcomeRecord(
                    decision: .failed,
                    correlationID: call.linkageID,
                    cause: SecretsAuditCause(redacting: cause),
                    timestamp: now()
                )
            )
        }
        return rows
    }

    /// Fixed cause labels for failure rows. Exhaustive over
    /// `ScopedInvokeError` so a new case breaks the build until classified
    /// here. Labels name the failure and provider only, never values.
    static func causeLabel(for error: ScopedInvokeError) -> String {
        switch error {
        case .principalRequired:
            return "principalRequired"
        case .policyDenied(let id):
            return "policyDenied:\(id ?? "fallback")"
        case .unknownTool:
            return "unknownTool"
        case .crossResource:
            return "crossResource"
        case .invalidArguments(let validation):
            switch validation {
            case .malformed:
                return "invalidArguments:malformed"
            case .oversized:
                return "invalidArguments:oversized"
            case .tooManyKeys:
                return "invalidArguments:tooManyKeys"
            case .badKey:
                return "invalidArguments:badKey"
            case .missingRequired(let key):
                return "invalidArguments:missing:\(key)"
            }
        case .elicitationTimeout:
            return "elicitationTimeout"
        case .elicitationUnavailable:
            return "elicitationUnavailable"
        case .credentialFailed(let secrets):
            return "credentialFailed:\(SecretsAuditCause(secrets).redacted)"
        case .auditFailed:
            return "auditFailed"
        case .internalError(let defect):
            return "internalError:\(defect.correlationID.rawValue.uuidString)"
        }
    }
}

/// One invoke call's audit context. Pure row context: the invoker decides,
/// this carries the keys.
private struct InvokeCall: Sendable {
    /// Raw attempted literal (labels only; parsing may have failed).
    var attemptedLiteral: String
    /// Primary key joining every row of this execution.
    var executionID: SecretsExecutionID
    /// Idempotency key for elicitation and transport.
    var idempotencyKey: String
    /// Labels-only acting principal.
    var principal: SecretsAuditPrincipal
    /// When the call started.
    var timestamp: Date
    /// Linkage id for non-opaque rows. Opaque failures mint a fresh
    /// correlation id per defect instead.
    var linkageID: SecretsCorrelationID
    /// Parsed address once the attempted literal parses. Rows built
    /// before parsing carry the raw literal instead, so no attempted
    /// address is ever unaudited.
    var address: MCPToolAddress?

    /// Captures one call's keys with a fresh linkage id.
    init(
        attemptedLiteral: String,
        executionID: SecretsExecutionID,
        idempotencyKey: String,
        principal: SecretsAuditPrincipal,
        timestamp: Date
    ) {
        self.attemptedLiteral = attemptedLiteral
        self.executionID = executionID
        self.idempotencyKey = idempotencyKey
        self.principal = principal
        self.timestamp = timestamp
        self.linkageID = SecretsCorrelationID()
        self.address = nil
    }

    /// Builds one `tool.dispatch` row for this call: the parsed-address
    /// factory when the attempted literal parsed, else the raw-literal
    /// factory overload.
    func dispatchRecord(
        decision: ToolDispatchDecision,
        correlationID: SecretsCorrelationID,
        cause: SecretsAuditCause?,
        timestamp: Date
    ) -> SecretsAuditRecord {
        if let address {
            return SecretsAuditRecord.toolDispatch(
                executionID: executionID,
                timestamp: timestamp,
                principal: principal,
                address: address,
                decision: decision,
                correlationID: correlationID,
                cause: cause
            )
        }
        return SecretsAuditRecord.toolDispatch(
            executionID: executionID,
            timestamp: timestamp,
            principal: principal,
            toolLiteral: attemptedLiteral,
            decision: decision,
            correlationID: correlationID,
            cause: cause
        )
    }

    /// Builds one `tool.approval` row for this call: the parsed-address
    /// factory when the attempted literal parsed, else the raw-literal
    /// factory overload.
    func approvalRecord(
        decision: ToolApprovalDecision,
        correlationID: SecretsCorrelationID,
        cause: SecretsAuditCause?,
        timestamp: Date
    ) -> SecretsAuditRecord {
        if let address {
            return SecretsAuditRecord.toolApproval(
                executionID: executionID,
                timestamp: timestamp,
                principal: principal,
                address: address,
                decision: decision,
                correlationID: correlationID,
                cause: cause
            )
        }
        return SecretsAuditRecord.toolApproval(
            executionID: executionID,
            timestamp: timestamp,
            principal: principal,
            toolLiteral: attemptedLiteral,
            decision: decision,
            correlationID: correlationID,
            cause: cause
        )
    }

    /// Builds one `tool.outcome` row for this call: the parsed-address
    /// factory when the attempted literal parsed, else the raw-literal
    /// factory overload.
    func outcomeRecord(
        decision: ToolOutcomeDecision,
        correlationID: SecretsCorrelationID,
        cause: SecretsAuditCause?,
        timestamp: Date
    ) -> SecretsAuditRecord {
        if let address {
            return SecretsAuditRecord.toolOutcome(
                executionID: executionID,
                timestamp: timestamp,
                principal: principal,
                address: address,
                decision: decision,
                correlationID: correlationID,
                cause: cause
            )
        }
        return SecretsAuditRecord.toolOutcome(
            executionID: executionID,
            timestamp: timestamp,
            principal: principal,
            toolLiteral: attemptedLiteral,
            decision: decision,
            correlationID: correlationID,
            cause: cause
        )
    }
}
