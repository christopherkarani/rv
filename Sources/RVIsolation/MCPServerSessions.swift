import Foundation
import RVDomain

/// Serving sessions (X1-K): provider auth outcome, resource routing, and the
/// in-memory MCP session store.
///
/// Ports Executor `packages/hosts/mcp/src/seams.ts` (`AuthOutcome` 4-way,
/// `principalOwns`, `mcpResourceKey`, the `McpSessionStore` seam) and
/// `in-memory-session-store.ts` (TTL/sweep/in-flight/ownership re-stamp/
/// close-all). Single-tenant RV mapping: no org principal — the
/// authenticated arm carries the RV agent context, and ownership keys on the
/// local owner alone; the Forbidden/Unavailable arms stay for session-aware
/// providers. Every ported behavior cites its oracle test below.
///
/// Wiring order (wave-2): X1-A `MCPEnvelopePipeline` runs method gate → auth
/// (this file's outcome mapped through `envelopeOutcome`) → session
/// short-circuit → dispatch (`acquire`/`withSession`, verdicts in X1-A's
/// `MCPDispatchVerdict`). The pre-initialize -32601 guard stays in X1-A
/// (`MCPPreInitializeGuard`) and runs before `create`, exactly as the
/// Executor's `create` runs `preInitializeMethodNotFound` before `openSession`.
///
/// An auth-level Forbidden never disposes a session id (envelope.test.ts:
/// "does not dispose a session id on an auth-level Forbidden outcome"): the
/// pipeline renders it before dispatch, so the store never sees the request.

// MARK: - Agent context (single-tenant principal)

/// Authenticated RV caller for serving sessions: the local owner under whose
/// authority RV runs, plus the agent definition serving the session.
///
/// Replaces the Executor org `Principal` (seams.ts): single-tenant RV has no
/// org, so ownership keys on the owner UID alone (cf `principalOwns` keying
/// on `(accountId, organizationId)`). The agent pin is re-stamped on every
/// forward like the Executor's roles, and like roles it never gates ownership
/// — pins stay metadata and never pierce the scoped plane.
public struct MCPServerAgentContext: Sendable, Equatable, Hashable {
    /// Kernel-attested local owner. The whole ownership identity.
    public let owner: OwnerPrincipal
    /// Agent definition serving under the owner. Re-stamped, never gating.
    public let agent: AgentDefinitionID

    /// Pairs one owner with its serving agent.
    public init(owner: OwnerPrincipal, agent: AgentDefinitionID) {
        self.owner = owner
        self.agent = agent
    }

    /// True when the presenter rides the stored session: same owner UID.
    /// Ports `principalOwns` (seams.ts) onto the single-tenant identity.
    /// Oracle: e2e "a session cannot be ridden by a different account's Bearer".
    public static func owns(owner: MCPServerAgentContext, presenter: MCPServerAgentContext) -> Bool {
        owner.owner == presenter.owner
    }
}

// MARK: - Provider auth outcome (4-way)

/// Per-request provider auth outcome. Ports the `AuthOutcome` union
/// (seams.ts): a typed, never-failing discriminant, never `Principal?`.
/// Providers return a value, never throw.
public enum MCPServerAuthOutcome: Sendable, Equatable {
    /// Authenticated under this agent context; continue to dispatch.
    case authenticated(MCPServerAgentContext)
    /// 401 with the outcome's own challenge, else the default challenge.
    case unauthorized(challenge: String?)
    /// 403 with the provider's message and optional code (default -32001).
    case forbidden(code: Int?, message: String)
    /// 503 with `Retry-After` for a transient auth outage.
    case unavailable(message: String)

    /// Maps onto X1-A's pipeline discriminant. A's outcome stays the single
    /// discriminant the envelope switches on; no parallel types.
    public var envelopeOutcome: MCPAuthOutcome {
        switch self {
        case .authenticated:
            return .authenticated
        case .unauthorized(let challenge):
            return .unauthorized(challenge: challenge)
        case .forbidden(let code, let message):
            return .forbidden(code: code, message: message)
        case .unavailable(let message):
            return .unavailable(message: message)
        }
    }
}

/// Bearer-token authentication onto the 4-way outcome. Bridges X1-N's
/// credential seam (`MCPServerAuth.isAuthorized`) into
/// `MCPServerAuthOutcome`; a miss carries no challenge so the envelope
/// synthesizes its default from the provider's resource-metadata URL.
/// Oracles: serve-shared.test.ts "accepts a matching Bearer" / "rejects a
/// missing or wrong token".
public enum MCPServerAuthentication {
    /// Authenticates one request's `Authorization` header value.
    public static func authenticate(
        authorizationHeader: String?,
        token: MCPCallerToken,
        context: MCPServerAgentContext
    ) -> MCPServerAuthOutcome {
        MCPServerAuth.isAuthorized(authorizationHeader: authorizationHeader, token: token)
            ? .authenticated(context)
            : .unauthorized(challenge: nil)
    }
}

// MARK: - Resource routing

/// MCP serving resource: the exact endpoint that minted a session. Ports
/// `McpResource` (seams.ts): a leaked `mcp-session-id` must not cross from
/// one capability set into another, so forwarding key-matches the stored
/// resource against the request's, else 403.
public enum MCPServingResource: Sendable, Equatable, Hashable {
    /// The default `/mcp` endpoint.
    case `default`
    /// A toolkit-scoped `/mcp/toolkits/<slug>` endpoint.
    case toolkit(MCPToolkitSlug)

    /// Ownership key. Oracle: resource-key.test.ts 'keys the default
    /// resource to "default"' / 'keys a toolkit resource to "toolkit:<slug>"'.
    public var key: String {
        switch self {
        case .default:
            return "default"
        case .toolkit(let slug):
            return "toolkit:\(slug.rawValue)"
        }
    }

    /// Legacy-tolerant key: a missing resource (pre-scope session meta) keys
    /// to default, exactly like the oracle's null/undefined guard, so no
    /// caller can throw on legacy data. Oracle: resource-key.test.ts "treats
    /// a missing resource (legacy session meta) as the default key".
    public static func key(of resource: MCPServingResource?) -> String {
        resource?.key ?? "default"
    }

    /// The exact comparison owner validation performs. Oracle:
    /// resource-key.test.ts "matches a legacy (missing) resource against an
    /// explicit default resource".
    public static func matches(_ lhs: MCPServingResource?, _ rhs: MCPServingResource?) -> Bool {
        key(of: lhs) == key(of: rhs)
    }
}

/// Serving-path routing failures. Fixed labels; never the rejected path.
public enum MCPServingRouteError: Error, Sendable, Equatable {
    /// The path is not a serving endpoint.
    case unknownPath
    /// The toolkit segment is not a valid slug.
    case invalidSlug
}

/// Routes serving paths onto resources. Ports the envelope's two serving
/// routes (envelope.ts: `/mcp` + `/mcp/toolkits/:toolkitSlug`). Declines
/// throw typed; errors never echo the rejected path.
public enum MCPServingRoute {
    /// The default serving path.
    public static let servingPath = "/mcp"
    /// Toolkit serving prefix; the remainder is the slug segment.
    public static let toolkitPrefix = "/mcp/toolkits/"
    /// Largest slug segment admitted before shape validation, bounding the
    /// work adversarial paths can demand.
    public static let maximumSlugBytes = 256

    /// Routes one request path. Matching is case-sensitive, mirroring the
    /// envelope's literal route table.
    public static func route(_ path: String) throws(MCPServingRouteError) -> MCPServingResource {
        if path == servingPath {
            return .default
        }
        guard path.hasPrefix(toolkitPrefix) else {
            throw MCPServingRouteError.unknownPath
        }
        let segment = String(path.dropFirst(toolkitPrefix.count))
        guard isBoundedOperatorText(segment) else {
            throw MCPServingRouteError.invalidSlug
        }
        guard let slug = try? MCPToolkitSlug.parse(segment) else {
            throw MCPServingRouteError.invalidSlug
        }
        return .toolkit(slug)
    }

    /// Operator path text: byte-capped, with control, invisible format, and
    /// line/paragraph-separator scalars rejected per `OperatorText`.
    static func isBoundedOperatorText(_ value: String) -> Bool {
        value.utf8.count <= maximumSlugBytes
            && OperatorText.containsDisallowedTextScalar(value) == false
    }
}

// MARK: - Session header

/// Serving-session failures. Fixed labels; never ids, slugs, or paths.
public enum MCPServerSessionError: Error, Sendable, Equatable {
    /// The `mcp-session-id` value is not canonical UUID text.
    case malformedSessionID
    /// No live session holds the id (unknown, expired, or disposed).
    case sessionNotFound
    /// The session belongs to another owner or resource.
    case forbidden
    /// No toolkit holds the resource slug.
    case unknownToolkit
}

/// The `mcp-session-id` header: lookup plus strict parse.
public enum MCPSessionHeader {
    /// Wire field name (envelope.ts reads `mcp-session-id`).
    public static let name = "mcp-session-id"

    /// Case-insensitive lookup over header fields.
    public static func value(from headers: [String: String]) -> String? {
        for (field, value) in headers where field.lowercased() == name {
            return value
        }
        return nil
    }

    /// Strictly parses one header value into the id it names. Only UUID text
    /// parses; anything else is a typed decline, never a nil-coalesced miss.
    public static func parse(_ raw: String) throws(MCPServerSessionError) -> MCPSessionID {
        guard let id = UUID(uuidString: raw) else {
            throw MCPServerSessionError.malformedSessionID
        }
        return MCPSessionID(rawValue: id)
    }
}

// MARK: - Discovery scoping

/// Session discovery scopes: the `isBlocked` wiring behind every registry
/// call a session serves. Scopes come from X1-H (`MCPToolkit.dynamicScope`),
/// and the predicate delegates to H's `blockedPredicate` — never
/// hand-translated — so pins cannot pierce the scoped plane.
public enum MCPSessionDiscovery {
    /// Scopes for one session resource: the default plane reads unrestricted
    /// (nil), so a passed toolkit is ignored there; a toolkit plane reads its
    /// toolkit's scopes, and a missing toolkit fails closed to the empty set
    /// (blocks everything), never to the default plane.
    public static func scopes(
        resource: MCPServingResource,
        toolkit: MCPToolkit?
    ) -> [MCPDynamicToolScope]? {
        switch resource {
        case .default:
            return nil
        case .toolkit:
            return toolkit?.dynamicScope() ?? []
        }
    }

    /// The compiler-required `isBlocked` predicate over H scope predicates.
    public static func blockedPredicate(
        scopes: [MCPDynamicToolScope]?
    ) -> @Sendable (MCPToolAddress) -> Bool {
        MCPDynamicToolScope.blockedPredicate(scopes: scopes)
    }
}

// MARK: - In-memory session store

/// In-process MCP serving-session store. Ports `makeInMemoryMcpSessionStore`
/// (in-memory-session-store.ts): create stamps, forward re-stamps ownership
/// and claims in-flight, release restamps idle-from-finish, the sweep evicts
/// idle-past-TTL sessions with nothing in flight, dispose is idempotent, and
/// close drains every live session for host shutdown.
///
/// The store owns lifecycle only; per-session engines live behind the
/// caller's `closer`, which every disposal path runs exactly once. Time comes
/// from the injected clock so sweeps stay deterministic.
public actor MCPServerSessions {
    /// Idle window after which an untouched session is evicted. Ports
    /// `DEFAULT_SESSION_IDLE_TTL_MS` (30 minutes).
    public static let defaultIdleTTLSeconds: TimeInterval = 30 * 60
    /// Floor on the sweep cadence. Ports `MIN_SWEEP_INTERVAL_MS` (30 seconds).
    public static let minimumSweepIntervalSeconds: TimeInterval = 30

    /// Host sweep cadence for one TTL: `max(30s, floor(TTL/4))`, so a small
    /// TTL cannot spin the timer. Pure; the host schedules it.
    public static func sweepIntervalSeconds(idleTTLSeconds: TimeInterval) -> TimeInterval {
        max(minimumSweepIntervalSeconds, (idleTTLSeconds / 4).rounded(.down))
    }

    /// One live session: owner, resource, discovery scopes, idle stamp,
    /// in-flight count, and the disposal hook.
    private struct Session {
        var owner: MCPServerAgentContext
        var resource: MCPServingResource
        var scopes: [MCPDynamicToolScope]?
        var lastSeen: Date
        var inFlight: Int
        var closer: (@Sendable () async -> Void)?
    }

    /// Idle window in seconds. Zero or negative disables eviction (the sweep
    /// keeps nothing: it returns 0 without looking).
    private let idleTTL: TimeInterval
    /// Resolves toolkit slugs to toolkits at create; a miss throws
    /// `unknownToolkit` instead of serving the default plane.
    private let toolkitResolver: @Sendable (MCPToolkitSlug) -> MCPToolkit?
    /// Time source for stamps and default sweep instants.
    private let clock: @Sendable () -> Date
    /// Live sessions by id.
    private var sessions: [MCPSessionID: Session] = [:]

    /// Builds one store. The default resolver serves the default plane only:
    /// every toolkit create throws `unknownToolkit` until the host provides
    /// a resolver.
    public init(
        idleTTLSeconds: TimeInterval = defaultIdleTTLSeconds,
        toolkitResolver: @escaping @Sendable (MCPToolkitSlug) -> MCPToolkit? = { _ in nil },
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.idleTTL = idleTTLSeconds
        self.toolkitResolver = toolkitResolver
        self.clock = clock
    }

    /// Live initialized sessions currently owned by this store.
    public var sessionCount: Int {
        sessions.count
    }

    /// False when the TTL disables eviction; the host must not schedule
    /// sweeps then (the sweep itself also returns 0).
    public var evictionEnabled: Bool {
        idleTTL > 0
    }

    /// This store's sweep cadence: `max(30s, floor(TTL/4))`.
    public var sweepInterval: TimeInterval {
        Self.sweepIntervalSeconds(idleTTLSeconds: idleTTL)
    }

    /// Opens one session, stamped at the current instant. A toolkit resource
    /// resolves its toolkit up front so discovery scopes are fixed for the
    /// session's life; an unresolvable slug throws `unknownToolkit` and opens
    /// nothing. The closer runs exactly once on the disposal path that takes
    /// the session.
    ///
    /// Fixed scopes are the design, not a cache: the Executor follows live
    /// grants, but RV pins scopes at create, so the host must dispose every
    /// session whose grants changed — a disposed id answers `notFound`,
    /// prompting the client to reconnect under the new grants.
    /// `scopesPinnedAtCreateHostMustDispose` pins this contract.
    public func create(
        owner: MCPServerAgentContext,
        resource: MCPServingResource,
        closer: (@Sendable () async -> Void)? = nil
    ) throws(MCPServerSessionError) -> MCPSessionID {
        let scopes: [MCPDynamicToolScope]?
        switch resource {
        case .default:
            scopes = nil
        case .toolkit(let slug):
            guard let toolkit = toolkitResolver(slug) else {
                throw MCPServerSessionError.unknownToolkit
            }
            scopes = toolkit.dynamicScope()
        }
        // A mint colliding with a live id would orphan that session and drop
        // its closer, so loop rather than overwrite. A second turn needs a
        // 122-bit UUIDv4 collision, which no deterministic test can trigger
        // without widening an id-mint seam into `create` — and no such seam
        // exists (`init` takes only TTL/resolver/clock). The repeat form
        // keeps every region executable under that proof; `mintedIDsAreUUIDv4`
        // pins the v4 mint the proof rests on.
        var id: MCPSessionID
        repeat {
            id = MCPSessionID()
        } while sessions[id] != nil
        sessions[id] = Session(
            owner: owner, resource: resource, scopes: scopes,
            lastSeen: clock(), inFlight: 0, closer: closer
        )
        return id
    }

    /// Claims one in-flight request on a live session the presenter owns.
    /// Ports `forward` (in-memory-session-store.ts): unknown ids answer
    /// `notFound`, cross-owner or cross-resource presenters answer
    /// `forbidden`, and a handled forward re-stamps the stored owner to the
    /// presenter, touches the idle stamp, and claims in-flight so the sweep
    /// cannot take the session mid-request. Every `.handled` needs exactly
    /// one `release`; prefer `withSession`, which pairs them.
    public func acquire(
        id: MCPSessionID,
        owner: MCPServerAgentContext,
        resource: MCPServingResource
    ) -> MCPDispatchVerdict {
        guard var session = sessions[id] else {
            return .notFound
        }
        guard MCPServerAgentContext.owns(owner: session.owner, presenter: owner),
            MCPServingResource.matches(session.resource, resource)
        else {
            return .forbidden
        }
        session.owner = owner
        session.resource = resource
        session.lastSeen = clock()
        session.inFlight += 1
        sessions[id] = session
        return .handled
    }

    /// Releases one in-flight claim and restamps the session idle from the
    /// moment the call FINISHED, not from when it started — a later sweep
    /// still reclaims it if the client then goes quiet. Ports `endRequest`:
    /// a no-op once the session is gone, so it can never resurrect a
    /// disposed id.
    public func release(id: MCPSessionID) {
        guard var session = sessions[id] else {
            return
        }
        session.inFlight = max(session.inFlight - 1, 0)
        session.lastSeen = clock()
        sessions[id] = session
    }

    /// Runs one request body on a live owned session, pairing `acquire` with
    /// `release` across every completion path — including a body that throws
    /// or a session disposed mid-request, where the release is a no-op and
    /// the in-flight body still completes. Oracle: e2e "in-flight requests
    /// survive their session's teardown as protocol errors". Stale ids and
    /// ownership misses throw typed.
    public func withSession<T>(
        id: MCPSessionID,
        owner: MCPServerAgentContext,
        resource: MCPServingResource,
        body: () async throws -> T
    ) async throws -> T {
        switch acquire(id: id, owner: owner, resource: resource) {
        case .handled:
            break
        case .notFound:
            throw MCPServerSessionError.sessionNotFound
        case .forbidden:
            throw MCPServerSessionError.forbidden
        }
        defer { release(id: id) }
        return try await body()
    }

    /// Tears down one session by id. Idempotent (seams.ts: "Tear down a
    /// session by id (idempotent)"): unknown ids are a no-op, and the closer
    /// runs at most once. This is the internal teardown for sweep/close,
    /// which already own the sessions they take; a request-driven DELETE
    /// must use the ownership-enforcing overload below, so a presenter that
    /// cannot ride the session cannot tear it down either.
    public func dispose(id: MCPSessionID) async {
        guard let session = sessions.removeValue(forKey: id) else {
            return
        }
        await session.closer?()
    }

    /// Tears down one session the presenter owns on the request's resource.
    /// The authorized DELETE path (the pipeline answers a session-less
    /// DELETE with 204 before dispatch; a session DELETE lands here, then
    /// answers 204): unknown ids answer `notFound`, cross-owner or
    /// cross-resource presenters answer `forbidden` and the session survives,
    /// and an owned id is disposed — closer runs once — answering `handled`.
    /// Ports the Executor's DELETE-through-forward gate (a DELETE reaches the
    /// transport only past `forward`'s ownership check) onto the verdict the
    /// pipeline already renders. The check-then-take runs in one actor turn,
    /// so no interleaving acquire can slip between them.
    public func dispose(
        id: MCPSessionID,
        owner: MCPServerAgentContext,
        resource: MCPServingResource
    ) async -> MCPDispatchVerdict {
        guard let session = sessions[id] else {
            return .notFound
        }
        guard MCPServerAgentContext.owns(owner: session.owner, presenter: owner),
            MCPServingResource.matches(session.resource, resource)
        else {
            return .forbidden
        }
        sessions.removeValue(forKey: id)
        await session.closer?()
        return .handled
    }

    /// Removes one session for the sweep when it is still present, idle past
    /// the TTL against the sweep instant, and serving nothing. Synchronous,
    /// so the re-check and the removal run in one actor turn — the closer
    /// runs after — and no `acquire` can claim the session between them.
    private func takeIfIdle(_ id: MCPSessionID, instant: Date) -> Session? {
        guard let current = sessions[id],
            instant.timeIntervalSince(current.lastSeen) >= idleTTL,
            current.inFlight == 0
        else {
            return nil
        }
        return sessions.removeValue(forKey: id)
    }

    /// Disposes every session idle past the TTL with nothing in flight, and
    /// returns how many went. Ports `sweepIdleSessions`: a session serving a
    /// request is busy however long ago that request started. Oracle:
    /// "evicts a session that goes idle past the TTL and keeps a busy one" /
    /// "never evicts a session while one of its requests is still in flight".
    /// Each id is re-validated at disposal time: the sweep suspends on every
    /// closer, so an `acquire` may claim a snapshotted session before its
    /// turn comes, and that session must be skipped, never evicted mid-request.
    public func sweep(now: Date? = nil) async -> Int {
        guard idleTTL > 0 else {
            return 0
        }
        let instant = now ?? clock()
        let stale = sessions.compactMap { (id, session) -> MCPSessionID? in
            instant.timeIntervalSince(session.lastSeen) >= idleTTL && session.inFlight == 0 ? id : nil
        }
        var disposed = 0
        for id in stale {
            guard let taken = takeIfIdle(id, instant: instant) else {
                continue
            }
            await taken.closer?()
            disposed += 1
        }
        return disposed
    }

    /// Disposes every live session. The host shutdown hook (not a seam);
    /// idempotent. Oracle: "shuts down the scoped executor when
    /// sessions.close() is called".
    public func close() async {
        for id in Array(sessions.keys) {
            await dispose(id: id)
        }
    }

    /// The stored owner context for one live session: the approval-endpoint
    /// read side (cf `ownerAccess` in in-memory-session-store.ts). Stale ids
    /// throw typed.
    public func ownerContext(for id: MCPSessionID) throws(MCPServerSessionError) -> MCPServerAgentContext {
        guard let session = sessions[id] else {
            throw MCPServerSessionError.sessionNotFound
        }
        return session.owner
    }

    /// The compiler-required `isBlocked` predicate for one live session,
    /// built over H scope predicates. Stale ids throw typed, so discovery
    /// can never read a dead session's scopes.
    public func blockedPredicate(
        for id: MCPSessionID
    ) throws(MCPServerSessionError) -> @Sendable (MCPToolAddress) -> Bool {
        guard let session = sessions[id] else {
            throw MCPServerSessionError.sessionNotFound
        }
        return MCPSessionDiscovery.blockedPredicate(scopes: session.scopes)
    }
}
