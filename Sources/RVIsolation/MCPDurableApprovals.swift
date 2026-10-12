import Foundation
import RVDomain

// MARK: - Elicitation source

/// Who raised an elicitation: the policy gate or the tool mid-call.
///
/// Executor parity (`ElicitationSource`, `elicitation.ts`): `"policy"` is a
/// consent-only gate whose terms are exactly "run this tool with these
/// arguments"; `"tool"` is anything the tool itself asked for, which may carry
/// its own terms. A host that already has consent may auto-accept the former
/// and must never auto-accept the latter. Absent reads as `"tool"`.
public enum MCPElicitationSource: String, Sendable, Hashable, Equatable, Codable {
    /// The policy approval gate (`require_approval`).
    case policy
    /// A mid-call tool request. The fail-closed default for absent sources.
    case tool
}

/// One approval prompt with its elicitation source.
///
/// `MCPElicitationPrompt` carries no source field; this wrapper pairs it with
/// one. A nil source reads as `.tool` (executor §5.5: absent means unknown,
/// unknown is tool), so only an explicit `.policy` ever auto-accepts.
public struct MCPApprovalPrompt: Sendable, Hashable, Equatable, Codable {
    /// The operator-facing prompt.
    public var prompt: MCPElicitationPrompt
    /// Who raised it. Nil reads as `.tool`.
    public var source: MCPElicitationSource?

    /// Pairs one prompt with its source. Nil source reads as `.tool`.
    public init(prompt: MCPElicitationPrompt, source: MCPElicitationSource? = nil) {
        self.prompt = prompt
        self.source = source
    }

    /// The effective source: the explicit value, or `.tool` when absent.
    public var effectiveSource: MCPElicitationSource {
        source ?? .tool
    }
}

// MARK: - Handler seam

/// One handler answer to an approval prompt.
public enum MCPApprovalResponse: String, Sendable, Hashable, Equatable, Codable {
    /// Run the call.
    case accept
    /// Refuse the call; nothing runs.
    case decline
    /// Abandon the wait; nothing runs.
    case cancel
}

/// Per-call elicitation policy: a handler, or accept-all.
///
/// Executor parity (`OnElicitation`, `elicitation.ts`: `handler |
/// "accept-all"`), with one RV difference, stated loudly: executor accept-all
/// accepts every request, while RV accept-all accepts only `.policy` gates
/// and declines `.tool` requests. A consent-only gate replays consent the
/// host already has; a tool request may carry terms the host never saw, so it
/// fails closed. Non-interactive callers set accept-all at the constructor and
/// policy-gated tools proceed unattended; tool requests still refuse.
public enum MCPApprovalHandler: Sendable {
    /// Answer each prompt by calling the closure. A throw fails the park with
    /// `.handlerFailed` (cancellation propagates unwrapped, never wrapped).
    case handler(@Sendable (MCPApprovalPrompt) async throws -> MCPApprovalResponse)
    /// Auto-answer: `.policy` accepts, `.tool` (or absent) declines. Never
    /// auto-accepts a tool request.
    case acceptAll

    /// Answers one prompt under this policy.
    public func resolve(_ prompt: MCPApprovalPrompt) async throws -> MCPApprovalResponse {
        switch self {
        case .handler(let answer):
            return try await answer(prompt)
        case .acceptAll:
            return prompt.effectiveSource == .policy ? .accept : .decline
        }
    }
}

// MARK: - Decline payload + wait errors

/// Which refusal ended the wait. Executor parity with the
/// `ElicitationDeclinedError` action field (`elicitation.ts`).
public enum MCPApprovalDeclineAction: String, Sendable, Hashable, Equatable, Codable {
    /// The operator (or handler) refused.
    case decline
    /// The wait was abandoned.
    case cancel
}

/// Typed refusal carrying address + action.
///
/// Replaces the unit `ElicitationDeclinedError` (which carries neither) for
/// the durable path. X1-S raises this from the invoker when the backend
/// reports a decline; this file defines the payload so backend, invoker, and
/// tests share one shape. Nothing in this file raises it yet — the invoker
/// split is X1-S work — and that must not change silently: when X1-S wires
/// the raise, these docs move with it.
public struct MCPApprovalDeclinedError: Error, Sendable, Hashable, Equatable {
    /// Canonical tool address literal that was refused.
    public var address: String
    /// How the wait ended.
    public var action: MCPApprovalDeclineAction

    /// Refuses one address with one action.
    public init(address: String, action: MCPApprovalDeclineAction) {
        self.address = address
        self.action = action
    }

    /// Telemetry-safe label: outcome + address, never arguments. Spelling
    /// matches the executor (`cancelled`, double-l).
    public var message: String {
        switch action {
        case .decline:
            return "Tool approval declined: \(address)"
        case .cancel:
            return "Tool approval cancelled: \(address)"
        }
    }
}

/// Typed durable-backend failures.
///
/// `parkFull`, `unknownTicket`, and `alreadyConsumed` reuse
/// `MCPElicitationError` (the drop-in contract shared with
/// `InMemoryElicitationBackend`); everything here is durable-specific.
/// Expiry and cancel are DISTINCT cases: the remaining collapse to one
/// invoker timeout error lives in `ScopedInvoker.elicit` (outside this
/// file's fence) and splits onto these cases in X1-S.
public enum MCPDurableApprovalError: Error, Sendable, Hashable, Equatable {
    /// The wait outlived its TTL. LOUD COLLAPSE NOTE: store `.expired` and
    /// `.timedOut` both map here — MCP has one expired status
    /// (`MCPElicitationStatus.expired`), and both mean "the TTL elapsed with
    /// no human". The address replays the parked prompt address (or the
    /// ticket id when the prompt is unrecoverable).
    case expired(address: String)
    /// The wait was canceled (operator, handler, or caller-deadline cancel).
    case canceled(address: String)
    /// The durable store failed. The wrapped error is the exact
    /// `PendingApprovalError`; store failures are typed, never silent.
    case storeFailed(PendingApprovalError)
    /// The approval handler threw. Label only: the message is redacted
    /// through the log rulebook before it reaches logs, and handlers should
    /// still throw value-free errors.
    case handlerFailed(String)
}

// MARK: - Durable prompt envelope (internal)

/// Crash-recovery payload for one parked prompt, stored in the record's
/// `.resume` continuation token (an opaque host-defined string: the MCP
/// bridge is the host here). After a rebind the new backend instance decodes
/// these tokens to show operators the pending prompts full-fidelity.
///
/// Format `mcp1` + five length-prefixed fields (address, matchedPattern,
/// argumentPreview, idempotencyKey, source raw or empty):
/// `mcp1:<n>:<bytes>...` with byte counts. Encoding is total by
/// construction (interpolation cannot fail, so it never branches and never
/// throws); decoding is strict and returns nil on any drift. An unknown
/// source value decodes to nil, which reads as `.tool` (fail-closed: never
/// auto-accepted).
struct MCPDurablePromptEnvelope: Sendable, Hashable, Equatable {
    /// Canonical tool address literal.
    var address: String
    /// Matched-pattern provenance label.
    var matchedPattern: String
    /// Redacted, capped argument preview.
    var argumentPreview: String
    /// Execution idempotency key.
    var idempotencyKey: String
    /// Who raised it. Nil reads as `.tool`.
    var source: MCPElicitationSource?

    /// Encodes the token. Total: interpolation cannot fail.
    func encoded() -> String {
        var token = "mcp1"
        for field in [address, matchedPattern, argumentPreview, idempotencyKey, source?.rawValue ?? ""] {
            token += ":\(field.utf8.count):\(field)"
        }
        return token
    }

    /// Decodes one token. Nil on any drift.
    static func decode(_ text: String) -> MCPDurablePromptEnvelope? {
        guard text.hasPrefix("mcp1") else {
            return nil
        }
        let bytes = Array(text.utf8.dropFirst(4))
        var cursor = 0
        var fields: [String] = []
        for _ in 0..<5 {
            guard let field = parseField(bytes, &cursor) else {
                return nil
            }
            fields.append(field)
        }
        guard cursor == bytes.count else {
            return nil
        }
        return MCPDurablePromptEnvelope(
            address: fields[0],
            matchedPattern: fields[1],
            argumentPreview: fields[2],
            idempotencyKey: fields[3],
            source: MCPElicitationSource(rawValue: fields[4])
        )
    }

    /// Rebuilds the operator-facing prompt.
    func prompt() -> MCPElicitationPrompt {
        MCPElicitationPrompt(
            address: address,
            matchedPattern: matchedPattern,
            argumentPreview: argumentPreview,
            idempotencyKey: idempotencyKey
        )
    }

    /// Parses one `:<byte-count>:<bytes>` field at the cursor.
    private static func parseField(_ bytes: [UInt8], _ cursor: inout Int) -> String? {
        guard cursor < bytes.count, bytes[cursor] == 0x3A else {
            return nil
        }
        cursor += 1
        var end = cursor
        while end < bytes.count, bytes[end] != 0x3A {
            end += 1
        }
        guard end < bytes.count else {
            return nil
        }
        let countText = String(decoding: bytes[cursor..<end], as: UTF8.self)
        guard let count = Int(countText), count >= 0 else {
            return nil
        }
        cursor = end + 1
        guard bytes.count - cursor >= count else {
            return nil
        }
        guard let field = String(bytes: bytes[cursor..<(cursor + count)], encoding: .utf8) else {
            return nil
        }
        cursor += count
        return field
    }
}

// MARK: - Durable backend

/// `MCPElicitationBackend` over the durable `PendingApprovalStore`.
///
/// BRIDGE, not a parallel executor-shaped store: every wait is a
/// `PendingApproval` record bound by the store's fingerprint+identity
/// contract. Park creates the record, poll loads it, deny-consume consumes it
/// (durable exactly-once), cancel cancels it, and the TTL is the store's own
/// sweep (`timeoutPolicy .failTask`: past `expiresAt` the record times out on
/// next load — a timed-out MCP approval fails the call, it is never a human
/// deny; compare the ASK flow's `.autoDeny`).
///
/// Record shape per park: id = the ticket id (so a rebound backend
/// reconstructs tickets from record ids), identity = the constructor
/// identity, action = `.shell(.effectOnly)` carrying fingerprint
/// `mcp:<address>:<ticket-uuid>` (unique per park, so parks never dedupe and
/// the prefix filters MCP rows out of the shared store; the shell case is a
/// carrier only — no MCP `ProposedAction` case exists yet and adding one is
/// T0a work), reason = `.hostAsk` (this bridge is a host adapter asking),
/// continuation = `.resume(token)` carrying the prompt envelope (the token is
/// host-defined; the MCP bridge is the host here), timeoutPolicy = `.failTask`.
///
/// LOUD CONTRACT NOTES, each pinned by tests:
///
/// - Allow-consumption exactly-once is IN-MEMORY. Name-only `consume`
///   delivers denies only (`PendingApprovalLedger.consume` rejects
///   authorizing decisions, so restart persistence never mints authority);
///   the allow row stays `.resolved` durably and this backend's
///   `consumedApprovals` set enforces one delivery. A crash between consume
///   and invoke could re-deliver after a rebind. The window is narrow (the
///   invoker consumes once per ticket, tickets are memory-only, and resolved
///   rows never list — re-delivery needs an out-of-band ticket replay after
///   the crash), but it is real — closing it needs a durably-marked
///   allow-consume, which the store has no transition for. The same window
///   covers two LIVE backends over one store+identity (marks are per
///   instance), so wire exactly one backend per (store, identity).
/// - `allowOnce` and `createRule` both read as approved. MCP has no rule
///   surface (persistence negotiation is out of scope), so a `createRule`
///   resolution authorizes this one call exactly like `allowOnce`.
/// - `poll` maps every store failure (including outages) to `.canceled`:
///   the protocol signature cannot throw, so reads fail closed. The invoker
///   denies canceled waits without running anything.
/// - `cancel` is best-effort per the protocol and swallows store outages;
///   the next poll/consume surfaces store health typed.
/// - MCP rows must resolve via `MCPDurableApprovalBackend.resolve` (or
///   `store.resolve` directly). The shell allow-once ceremony
///   (`HookAskResolver`) cannot plant them — an MCP row has no
///   `supportingCommand` — so operator consoles must route `mcp:`-prefixed
///   rows here, never into the shell ceremony.
/// - There is no local park cap (the in-memory backend caps at 8): the
///   store's 256 awaiting-row cap is the cap, and `storeFull` maps to
///   `MCPElicitationError.parkFull`.
/// - Memory grows per park (prompt cache + consumed marks) and is never
///   evicted, matching the store's append-only rows. Compaction is future
///   work; dropping consumed-approval marks would reopen double delivery.
public actor MCPDurableApprovalBackend: MCPElicitationBackend {
    /// Fingerprint prefix marking MCP rows in the shared store.
    private static let fingerprintPrefix = "mcp:"

    private let store: any PendingApprovalCoordinating
    private let identity: ApprovalIdentity
    private let defaultHandler: MCPApprovalHandler?
    private let now: @Sendable () -> Date
    private var prompts: [UUID: MCPApprovalPrompt] = [:]
    private var consumedApprovals: Set<UUID> = []

    /// Bridges one durable store with one identity. `defaultHandler` answers
    /// parks that carry no per-call override (nil parks for a human);
    /// `now` is the clock (tests inject a scripted one).
    public init(
        store: any PendingApprovalCoordinating,
        identity: ApprovalIdentity,
        defaultHandler: MCPApprovalHandler? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.identity = identity
        self.defaultHandler = defaultHandler
        self.now = now
    }

    // MARK: Protocol

    /// Parks one prompt. LOUD SOURCE NOTE: the legacy seam carries only
    /// invoker policy gates (tool-side mid-call elicitation has no transport),
    /// so the source is `.policy` and constructor accept-all accepts these
    /// parks. The absent-reads-tool rule applies to the source FIELD
    /// (`MCPApprovalPrompt.source == nil`), not to this seam.
    public func park(_ prompt: MCPElicitationPrompt, ttl: TimeInterval) async throws -> MCPElicitationTicket {
        try await park(prompt, source: .policy, ttl: ttl, onApproval: nil)
    }

    /// Polls one wait without consuming. Unknown tickets, foreign records,
    /// and store outages all read `.canceled` (fail-closed; the protocol
    /// cannot throw, so this collapse is structural and loud).
    public func poll(_ ticket: MCPElicitationTicket) async -> MCPElicitationStatus {
        let record: PendingApproval
        do {
            record = try await store.load(id: ApprovalID(rawValue: ticket.id.uuidString), now: now())
        } catch {
            return .canceled
        }
        guard isOurs(record) else {
            return .canceled
        }
        return Self.status(for: record.state)
    }

    /// Consumes one terminal grant exactly once. Waiting tickets throw
    /// `.unknownTicket` (no grant exists yet); expired and canceled waits
    /// throw DISTINCT `.expired`/`.canceled` errors carrying the address;
    /// replays throw `.alreadyConsumed`. Deny delivery is durable (via
    /// `store.consume`); allow delivery is memory-guarded (see the type
    /// docs for the crash window).
    public func consume(_ ticket: MCPElicitationTicket) async throws -> MCPElicitationDecision {
        if consumedApprovals.contains(ticket.id) {
            throw MCPElicitationError.alreadyConsumed
        }
        let record: PendingApproval
        do {
            record = try await store.load(id: ApprovalID(rawValue: ticket.id.uuidString), now: now())
        } catch PendingApprovalError.notFound {
            throw MCPElicitationError.unknownTicket
        } catch {
            throw MCPDurableApprovalError.storeFailed(error)
        }
        guard isOurs(record) else {
            throw MCPElicitationError.unknownTicket
        }
        switch record.state {
        case .awaitingHuman:
            throw MCPElicitationError.unknownTicket
        case .resolved(let resolution):
            if resolution.decision.authorizesExactAction {
                // Re-check after the load: N consumers can all pass the
                // fast-path check above before any inserts (the load
                // suspends, so those checks interleave). No await sits
                // between this re-check and the insert, so they run in one
                // actor turn and exactly one consumer wins.
                if consumedApprovals.contains(ticket.id) {
                    throw MCPElicitationError.alreadyConsumed
                }
                consumedApprovals.insert(ticket.id)
                return .approved
            }
            do {
                _ = try await store.consume(
                    id: record.id,
                    fingerprint: record.fingerprint,
                    identity: identity,
                    now: now()
                )
            } catch {
                throw Self.mapConsumeStoreError(error, address: address(for: ticket, record: record))
            }
            return .declined
        case .consumed:
            throw MCPElicitationError.alreadyConsumed
        case .expired:
            throw MCPDurableApprovalError.expired(address: address(for: ticket, record: record))
        case .canceled:
            throw MCPDurableApprovalError.canceled(address: address(for: ticket, record: record))
        case .timedOut:
            throw MCPDurableApprovalError.expired(address: address(for: ticket, record: record))
        }
    }

    /// Best-effort cancel. Unknown tickets are a no-op; store outages are
    /// swallowed (the protocol cannot throw — see the type docs).
    public func cancel(_ ticket: MCPElicitationTicket) async {
        _ = try? await store.cancel(id: ApprovalID(rawValue: ticket.id.uuidString), now: now())
    }

    // MARK: Sourced park + operator seams

    /// Parks with an explicit source and an optional per-call handler
    /// override (executor `pickHandler`: the per-call `onElicitation` wins,
    /// else the constructor handler, else a human wait). A handler answer
    /// still writes its durable record first, then transitions it, so the
    /// park→poll→consume flow and the crash story stay uniform: handler
    /// failures throw typed and write nothing. Nonpositive or non-finite TTLs
    /// throw `.parkFull` before the handler runs, so a doomed park never
    /// invokes host code (the store's `ttl <= 0` check lets NaN through, and
    /// it has no non-finite expiry encoding, so the seam validates instead of
    /// misreporting store health; NaN matches the in-memory backend, while
    /// +inf diverges loudly — accepted there, unparkable here).
    public func park(
        _ prompt: MCPElicitationPrompt,
        source: MCPElicitationSource?,
        ttl: TimeInterval,
        onApproval: MCPApprovalHandler?
    ) async throws -> MCPElicitationTicket {
        guard ttl > 0, ttl.isFinite else {
            throw MCPElicitationError.parkFull
        }
        let ticket = MCPElicitationTicket(id: UUID(), idempotencyKey: prompt.idempotencyKey)
        let handler = onApproval ?? defaultHandler
        if let handler {
            let answer: MCPApprovalResponse
            do {
                answer = try await handler.resolve(MCPApprovalPrompt(prompt: prompt, source: source))
            } catch {
                if error is CancellationError {
                    throw error
                }
                throw MCPDurableApprovalError.handlerFailed(ReviewSanitizer.redactLog(String(describing: error)))
            }
            return try await parkResolved(
                ticket: ticket, prompt: prompt, source: source, ttl: ttl, answer: answer
            )
        }
        return try await parkAwaiting(ticket: ticket, prompt: prompt, source: source, ttl: ttl)
    }

    /// Operator seam: resolves a waiting ticket. Terminal, unknown, and
    /// foreign tickets are left untouched (no-op, matching the in-memory
    /// backend); store outages throw typed.
    public func resolve(_ ticket: MCPElicitationTicket, decision: MCPElicitationDecision) async throws {
        let record: PendingApproval
        do {
            record = try await store.load(id: ApprovalID(rawValue: ticket.id.uuidString), now: now())
        } catch PendingApprovalError.notFound {
            return
        } catch {
            throw MCPDurableApprovalError.storeFailed(error)
        }
        guard case .awaitingHuman = record.state else {
            return
        }
        guard isOurs(record) else {
            return
        }
        let rvDecision: ApprovalDecision = decision == .approved ? .allowOnce : .deny
        do {
            _ = try await store.resolve(
                id: record.id,
                decision: rvDecision,
                fingerprint: record.fingerprint,
                identity: identity,
                now: now()
            )
        } catch {
            switch error {
            case .alreadyResolved, .alreadyConsumed, .expired, .canceled, .timedOut:
                return
            case .invalidRequest, .duplicateID, .notFound, .fingerprintMismatch,
                .identityMismatch, .continuationMismatch, .notResolved,
                .encodeFailed, .lockFailed, .storeFull:
                throw MCPDurableApprovalError.storeFailed(error)
            }
        }
    }

    /// Lists waiting tickets (operator-console discovery; survives rebind —
    /// the tickets reconstruct from record ids). Foreign records, non-MCP
    /// fingerprints, and unparseable ids are skipped; undecodable prompts
    /// list with an empty key (the ticket still polls/consumes). Outages
    /// throw typed (this seam, unlike `poll`, is allowed to fail loudly).
    public func parkedTickets() async throws -> [MCPElicitationTicket] {
        let records: [PendingApproval]
        do {
            records = try await store.list(now: now())
        } catch {
            throw MCPDurableApprovalError.storeFailed(error)
        }
        var tickets: [MCPElicitationTicket] = []
        for record in records {
            guard isOurs(record), let id = UUID(uuidString: record.id.rawValue) else {
                continue
            }
            tickets.append(MCPElicitationTicket(id: id, idempotencyKey: Self.idempotencyKey(for: record)))
        }
        return tickets
    }

    /// Reads one prompt: memory first, else the durable envelope. Nil for
    /// unknown, foreign, and undecodable tickets; outages throw typed.
    public func prompt(for ticket: MCPElicitationTicket) async throws -> MCPApprovalPrompt? {
        if let cached = prompts[ticket.id] {
            return cached
        }
        let record: PendingApproval
        do {
            record = try await store.load(id: ApprovalID(rawValue: ticket.id.uuidString), now: now())
        } catch PendingApprovalError.notFound {
            return nil
        } catch {
            throw MCPDurableApprovalError.storeFailed(error)
        }
        guard isOurs(record) else {
            return nil
        }
        guard let envelope = Self.envelope(for: record) else {
            return nil
        }
        return MCPApprovalPrompt(prompt: envelope.prompt(), source: envelope.source)
    }

    /// Cached prompt count. Test seam: pins that failed parks strand nothing.
    var promptCacheCount: Int {
        prompts.count
    }

    // MARK: Private

    /// Parks for a human: writes the awaiting record.
    private func parkAwaiting(
        ticket: MCPElicitationTicket,
        prompt: MCPElicitationPrompt,
        source: MCPElicitationSource?,
        ttl: TimeInterval
    ) async throws -> MCPElicitationTicket {
        _ = try await createRecord(ticket: ticket, prompt: prompt, source: source, ttl: ttl)
        prompts[ticket.id] = MCPApprovalPrompt(prompt: prompt, source: source)
        return ticket
    }

    /// Parks with an immediate handler answer: writes the record, then
    /// transitions it. A failed transition best-effort cancels the orphan
    /// (so it never lingers as a phantom human wait) and throws typed.
    private func parkResolved(
        ticket: MCPElicitationTicket,
        prompt: MCPElicitationPrompt,
        source: MCPElicitationSource?,
        ttl: TimeInterval,
        answer: MCPApprovalResponse
    ) async throws -> MCPElicitationTicket {
        let record = try await createRecord(ticket: ticket, prompt: prompt, source: source, ttl: ttl)
        do {
            switch answer {
            case .accept:
                _ = try await store.resolve(
                    id: record.id,
                    decision: .allowOnce,
                    fingerprint: record.fingerprint,
                    identity: identity,
                    now: now()
                )
            case .decline:
                _ = try await store.resolve(
                    id: record.id,
                    decision: .deny,
                    fingerprint: record.fingerprint,
                    identity: identity,
                    now: now()
                )
            case .cancel:
                _ = try await store.cancel(id: record.id, now: now())
            }
        } catch {
            _ = try? await store.cancel(id: record.id, now: now())
            throw MCPDurableApprovalError.storeFailed(error)
        }
        // Cached only on success: the ticket never escapes on failure, so an
        // earlier insert would strand an unreachable prompt in memory forever.
        prompts[ticket.id] = MCPApprovalPrompt(prompt: prompt, source: source)
        return ticket
    }

    /// Writes one MCP record. Nonpositive TTLs and a full store reuse the
    /// drop-in `.parkFull`; every other store failure throws typed.
    private func createRecord(
        ticket: MCPElicitationTicket,
        prompt: MCPElicitationPrompt,
        source: MCPElicitationSource?,
        ttl: TimeInterval
    ) async throws -> PendingApproval {
        let envelope = MCPDurablePromptEnvelope(
            address: prompt.address,
            matchedPattern: prompt.matchedPattern,
            argumentPreview: prompt.argumentPreview,
            idempotencyKey: prompt.idempotencyKey,
            source: source
        )
        let request = PendingApprovalRequest(
            id: ApprovalID(rawValue: ticket.id.uuidString),
            identity: identity,
            action: .shell(.effectOnly(EffectShell(fingerprint: ActionFingerprint(rawValue: Self.fingerprint(prompt: prompt, ticket: ticket))))),
            reason: .hostAsk,
            continuation: .resume(ApprovalResumeToken(rawValue: envelope.encoded())),
            timeoutPolicy: .failTask,
            ttl: ttl
        )
        do {
            return try await store.create(request, now: now())
        } catch {
            throw Self.mapCreateError(error)
        }
    }

    /// One park's fingerprint: MCP-prefixed, address-labeled, ticket-unique.
    private static func fingerprint(prompt: MCPElicitationPrompt, ticket: MCPElicitationTicket) -> String {
        "mcp:\(prompt.address):\(ticket.id.uuidString)"
    }

    /// True for records this backend owns: our identity plus the MCP prefix.
    private func isOurs(_ record: PendingApproval) -> Bool {
        record.identity == identity && record.fingerprint.rawValue.hasPrefix(Self.fingerprintPrefix)
    }

    /// Decodes the record's prompt envelope. Nil for non-resume
    /// continuations and undecodable tokens.
    private static func envelope(for record: PendingApproval) -> MCPDurablePromptEnvelope? {
        guard case .resume(let token) = record.continuation else {
            return nil
        }
        return MCPDurablePromptEnvelope.decode(token.rawValue)
    }

    /// The listing key for one record: the envelope key, or empty when the
    /// prompt is unrecoverable (the ticket still polls and consumes).
    private static func idempotencyKey(for record: PendingApproval) -> String {
        if let envelope = envelope(for: record) {
            return envelope.idempotencyKey
        }
        return ""
    }

    /// The address for error payloads: memory first, else the durable
    /// envelope, else the ticket id (never empty, never a value).
    private func address(for ticket: MCPElicitationTicket, record: PendingApproval) -> String {
        if let cached = prompts[ticket.id] {
            return cached.prompt.address
        }
        if let envelope = Self.envelope(for: record) {
            return envelope.address
        }
        return ticket.id.uuidString
    }

    // MARK: Mappings (internal for direct unit tests)

    /// Maps store states to poll statuses. LOUD COLLAPSE NOTE: `.timedOut`
    /// reads `.expired` — MCP has one expired status and both mean "the TTL
    /// elapsed with no human". Any authorizing decision (`.allowOnce`,
    /// `.createRule`) reads approved; only `.deny` reads declined.
    static func status(for state: PendingApprovalState) -> MCPElicitationStatus {
        switch state {
        case .awaitingHuman:
            return .waiting
        case .resolved(let resolution):
            return resolution.decision.authorizesExactAction ? .approved : .declined
        case .consumed(let resolution, _):
            return resolution.decision.authorizesExactAction ? .approved : .declined
        case .expired:
            return .expired
        case .canceled:
            return .canceled
        case .timedOut:
            return .expired
        }
    }

    /// Maps park-time create failures. A full store and a nonpositive TTL
    /// (the only way our fixed request shape is invalid) reuse the drop-in
    /// `.parkFull`; everything else is a typed store failure.
    static func mapCreateError(_ error: PendingApprovalError) -> Error {
        switch error {
        case .storeFull, .invalidRequest:
            return MCPElicitationError.parkFull
        case .duplicateID, .notFound, .alreadyResolved, .expired, .canceled, .timedOut,
            .fingerprintMismatch, .identityMismatch, .continuationMismatch,
            .alreadyConsumed, .notResolved, .encodeFailed, .lockFailed:
            return MCPDurableApprovalError.storeFailed(error)
        }
    }

    /// Maps deny-consume race failures (the record moved between load and
    /// consume): terminal moves keep their distinct errors, vanished grants
    /// read unknown, and nothing else is ever silent.
    static func mapConsumeStoreError(_ error: PendingApprovalError, address: String) -> Error {
        switch error {
        case .alreadyConsumed:
            return MCPElicitationError.alreadyConsumed
        case .expired, .timedOut:
            return MCPDurableApprovalError.expired(address: address)
        case .canceled:
            return MCPDurableApprovalError.canceled(address: address)
        case .notFound, .notResolved:
            return MCPElicitationError.unknownTicket
        case .invalidRequest, .duplicateID, .alreadyResolved, .fingerprintMismatch,
            .identityMismatch, .continuationMismatch, .encodeFailed, .lockFailed, .storeFull:
            return MCPDurableApprovalError.storeFailed(error)
        }
    }
}
