import Foundation
import Synchronization
import Testing
import RVDomain
@testable import RVIsolation

// MARK: - Helpers

/// Deterministic clock: the store stamps and sweeps against this, so every
/// idle-boundary test pins exact instants instead of sleeping.
private final class ManualClock: Sendable {
    private let current: Mutex<Date>

    init(_ date: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        current = Mutex(date)
    }

    func now() -> Date {
        current.withLock { $0 }
    }

    func advance(by seconds: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(seconds) }
    }

    func store(
        idleTTL: TimeInterval = 60,
        resolver: @escaping @Sendable (MCPToolkitSlug) -> MCPToolkit? = { _ in nil }
    ) -> MCPServerSessions {
        MCPServerSessions(idleTTLSeconds: idleTTL, toolkitResolver: resolver, clock: { self.now() })
    }
}

/// Counts closer runs across disposal paths.
private final class CloseCounter: Sendable {
    private let runs = Mutex(0)

    var count: Int {
        runs.withLock { $0 }
    }

    func closer() -> @Sendable () async -> Void {
        { self.runs.withLock { $0 += 1 } }
    }
}

/// One-shot async rendezvous between a closer and the test body, so an
/// interleaving lands deterministically inside a sweep's suspension.
private final class Gate: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        var continuation: AsyncStream<Void>.Continuation!
        stream = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func signal() {
        continuation.yield()
    }

    func wait() async {
        for await _ in stream {
            return
        }
    }
}

private func makeContext(uid: UInt32 = 501, agent: String = "test-agent") throws -> MCPServerAgentContext {
    let id = try #require(AgentDefinitionID(validating: agent))
    return MCPServerAgentContext(owner: OwnerPrincipal(uid: uid), agent: id)
}

private func makeToolkit(
    slug: String = "kit",
    owner: PolicyOwner = .user,
    patterns: [String] = ["tools.github.*"]
) throws -> MCPToolkit {
    let slug = try MCPToolkitSlug.parse(slug)
    let connections = try patterns.enumerated().map { index, raw in
        MCPToolkitConnection(
            id: "c\(index)", pattern: try SegmentPattern.parse(raw),
            position: FractionalIndex(value: Double(index))
        )
    }
    return MCPToolkit(id: "tk", owner: owner, slug: slug, name: "Kit", connections: connections)
}

private func makeAddress(_ integration: String, tool: String = "get") throws -> MCPToolAddress {
    try MCPToolAddress(integration: integration, owner: "org", connection: "main", tool: tool)
}

private func makeRegistry() throws -> MCPRegistry {
    MCPRegistry(handlers: [
        MCPHandlerRecord(
            address: try makeAddress("github"), isStaticFqid: false, pluginDefault: .approve,
            description: "GitHub get"
        ),
        MCPHandlerRecord(
            address: try makeAddress("gitlab"), isStaticFqid: false, pluginDefault: .approve,
            description: "GitLab get"
        ),
    ])
}

@Suite("MCPServerSessions")
struct MCPServerSessionsTests {
    // MARK: - Auth outcome mapping (seams.ts AuthOutcome)

    @Test func authenticatedCarriesContextToEnvelope() throws {
        let context = try makeContext()
        let outcome = MCPServerAuthOutcome.authenticated(context)
        #expect(outcome.envelopeOutcome == .authenticated)
    }

    @Test func unauthorizedNilChallengeMapsToEnvelopeDefault() {
        let outcome = MCPServerAuthOutcome.unauthorized(challenge: nil)
        #expect(outcome.envelopeOutcome == .unauthorized(challenge: nil))
    }

    @Test func unauthorizedExplicitChallengePreserved() {
        let challenge = "Bearer realm=\"x\""
        let outcome = MCPServerAuthOutcome.unauthorized(challenge: challenge)
        #expect(outcome.envelopeOutcome == .unauthorized(challenge: challenge))
    }

    @Test func forbiddenDefaultCodeMaps() {
        let outcome = MCPServerAuthOutcome.forbidden(code: nil, message: "No organization in session")
        #expect(outcome.envelopeOutcome == .forbidden(code: nil, message: "No organization in session"))
    }

    @Test func forbiddenExplicitCodeMaps() {
        let outcome = MCPServerAuthOutcome.forbidden(code: -32003, message: "custom")
        #expect(outcome.envelopeOutcome == .forbidden(code: -32003, message: "custom"))
    }

    @Test func unavailableMaps() {
        let outcome = MCPServerAuthOutcome.unavailable(message: "Authentication temporarily unavailable")
        #expect(outcome.envelopeOutcome == .unavailable(message: "Authentication temporarily unavailable"))
    }

    @Test func authenticateAcceptsMatchingBearer() throws {
        // Oracle: serve-shared.test.ts "accepts a matching Bearer".
        let token = MCPCallerToken(rawValue: "caller-token")
        let context = try makeContext()
        let outcome = MCPServerAuthentication.authenticate(
            authorizationHeader: "Bearer caller-token", token: token, context: context
        )
        #expect(outcome == .authenticated(context))
        #expect(outcome.envelopeOutcome == .authenticated)
    }

    @Test func authenticateRejectsMissingAndWrong() throws {
        // Oracle: serve-shared.test.ts "rejects a missing or wrong token".
        let token = MCPCallerToken(rawValue: "caller-token")
        let context = try makeContext()
        for header in [nil, "Bearer wrong", "Basic caller-token", "Bearer "] as [String?] {
            let outcome = MCPServerAuthentication.authenticate(
                authorizationHeader: header, token: token, context: context
            )
            #expect(outcome == .unauthorized(challenge: nil))
        }
    }

    // MARK: - Ownership (seams.ts principalOwns)

    @Test func ownsIgnoresAgentPin() throws {
        let first = try makeContext(agent: "agent-a")
        let second = try makeContext(agent: "agent-b")
        #expect(MCPServerAgentContext.owns(owner: first, presenter: second))
        #expect(MCPServerAgentContext.owns(owner: second, presenter: first))
    }

    @Test func ownsRejectsDifferentOwner() throws {
        // Oracle: e2e "a session cannot be ridden by a different account's Bearer".
        let owner = try makeContext(uid: 501)
        let other = try makeContext(uid: 502)
        #expect(MCPServerAgentContext.owns(owner: owner, presenter: other) == false)
    }

    // MARK: - Resource keys (resource-key.test.ts)

    @Test func defaultResourceKeysDefault() {
        #expect(MCPServingResource.default.key == "default")
        #expect(MCPServingResource.key(of: .default) == "default")
    }

    @Test func toolkitResourceKeysSlug() throws {
        let slug = try MCPToolkitSlug.parse("github")
        #expect(MCPServingResource.toolkit(slug).key == "toolkit:github")
        #expect(MCPServingResource.key(of: .toolkit(slug)) == "toolkit:github")
    }

    @Test func missingResourceKeysDefault() {
        let missing: MCPServingResource? = nil
        #expect(MCPServingResource.key(of: missing) == "default")
    }

    @Test func legacyResourceMatchesExplicitDefault() {
        let missing: MCPServingResource? = nil
        #expect(MCPServingResource.matches(missing, .default))
        #expect(MCPServingResource.matches(.default, missing))
        #expect(MCPServingResource.matches(missing, missing))
    }

    @Test func resourceMismatchAcrossKeys() throws {
        let github = MCPServingResource.toolkit(try MCPToolkitSlug.parse("github"))
        let gitlab = MCPServingResource.toolkit(try MCPToolkitSlug.parse("gitlab"))
        #expect(MCPServingResource.matches(github, gitlab) == false)
        #expect(MCPServingResource.matches(github, .default) == false)
        #expect(MCPServingResource.matches(.default, github) == false)
        #expect(MCPServingResource.matches(github, github))
    }

    // MARK: - Routing (envelope.ts serving paths)

    @Test func routeDefaultPath() throws {
        #expect(try MCPServingRoute.route("/mcp") == .default)
    }

    @Test func routeToolkitPath() throws {
        let resource = try MCPServingRoute.route("/mcp/toolkits/github")
        #expect(resource == .toolkit(try MCPToolkitSlug.parse("github")))
    }

    @Test func routeUnknownPathsThrowTyped() {
        for path in ["", "/", "/nope", "/MCP", "/mcp/", "/mcp/toolkits", "/mcp/toolkits2/x", "/mcp2"] {
            #expect(throws: MCPServingRouteError.unknownPath) { try MCPServingRoute.route(path) }
        }
    }

    @Test func routeEmptySlugThrowsTyped() {
        #expect(throws: MCPServingRouteError.invalidSlug) { try MCPServingRoute.route("/mcp/toolkits/") }
    }

    @Test func routeMalformedSlugsThrowTyped() {
        // Slugs admit only [a-z0-9-], never leading/trailing hyphens.
        for segment in ["has space", "a/b", "a.b", "-lead", "trail-", "under_score", "a--b..c"] {
            #expect(throws: MCPServingRouteError.invalidSlug) {
                try MCPServingRoute.route("/mcp/toolkits/\(segment)")
            }
        }
    }

    @Test func routeTraversalSlugsThrowTyped() {
        // No decoding step runs before the shape check, so encoded dots stay
        // literal and every traversal spelling lands on the slug reject.
        for segment in ["..", ".", "%2e%2e", "..%2f..", "a/../b"] {
            #expect(throws: MCPServingRouteError.invalidSlug) {
                try MCPServingRoute.route("/mcp/toolkits/\(segment)")
            }
        }
    }

    @Test func routeNormalizesSlugCasing() throws {
        // Executor trims + lowercases before the shape check (via H's parse).
        let resource = try MCPServingRoute.route("/mcp/toolkits/GitHub")
        #expect(resource == .toolkit(try MCPToolkitSlug.parse("github")))
    }

    @Test func routeControlSlugThrowsTyped() {
        for segment in ["a\u{0}b", "a\u{7F}b", "a\u{200B}b", "a\u{2028}b", "a\nb"] {
            #expect(throws: MCPServingRouteError.invalidSlug) {
                try MCPServingRoute.route("/mcp/toolkits/\(segment)")
            }
        }
    }

    @Test func routeOverlongSlugThrowsTyped() {
        let segment = String(repeating: "a", count: MCPServingRoute.maximumSlugBytes + 1)
        #expect(throws: MCPServingRouteError.invalidSlug) {
            try MCPServingRoute.route("/mcp/toolkits/\(segment)")
        }
    }

    @Test func boundedOperatorTextMatrix() {
        #expect(MCPServingRoute.isBoundedOperatorText("github01-x"))
        #expect(MCPServingRoute.isBoundedOperatorText(""))
        #expect(
            MCPServingRoute.isBoundedOperatorText(
                String(repeating: "a", count: MCPServingRoute.maximumSlugBytes)
            )
        )
        #expect(
            MCPServingRoute.isBoundedOperatorText(
                String(repeating: "a", count: MCPServingRoute.maximumSlugBytes + 1)
            ) == false
        )
        #expect(MCPServingRoute.isBoundedOperatorText("a\u{0}b") == false)
        #expect(MCPServingRoute.isBoundedOperatorText("a\u{FEFF}b") == false)
        #expect(MCPServingRoute.isBoundedOperatorText("ok-emoji-\u{1F600}"))
    }

    // MARK: - Session header

    @Test func headerValueLookup() {
        #expect(MCPSessionHeader.value(from: ["mcp-session-id": "abc"]) == "abc")
        #expect(MCPSessionHeader.value(from: ["MCP-SESSION-ID": "abc"]) == "abc")
        #expect(MCPSessionHeader.value(from: ["Mcp-Session-Id": "abc"]) == "abc")
        #expect(MCPSessionHeader.value(from: ["content-type": "application/json"]) == nil)
        #expect(MCPSessionHeader.value(from: [:]) == nil)
    }

    @Test func headerParseRoundTripsMintedID() throws {
        let id = MCPSessionID()
        let parsed = try MCPSessionHeader.parse(id.rawValue.uuidString)
        #expect(parsed == id)
    }

    @Test func headerParseAcceptsUppercase() throws {
        let id = MCPSessionID()
        let parsed = try MCPSessionHeader.parse(id.rawValue.uuidString.uppercased())
        #expect(parsed == id)
    }

    @Test func headerParseRejectsNonUUID() {
        let id = MCPSessionID().rawValue.uuidString
        for raw in ["", "not-a-uuid", "{\(id)}", id.replacingOccurrences(of: "-", with: ""), "\(id) ", String(id.dropLast())] {
            #expect(throws: MCPServerSessionError.malformedSessionID) {
                try MCPSessionHeader.parse(raw)
            }
        }
    }

    // MARK: - Discovery scoping (H predicates)

    @Test func scopesDefaultIgnoresToolkit() throws {
        // Pins do not pierce the scoped plane: the default plane reads
        // unrestricted even when a restrictive toolkit is passed.
        let toolkit = try makeToolkit(patterns: ["tools.github.*"])
        #expect(MCPSessionDiscovery.scopes(resource: .default, toolkit: toolkit) == nil)
        #expect(MCPSessionDiscovery.scopes(resource: .default, toolkit: nil) == nil)
    }

    @Test func scopesToolkitReadsDynamicScope() throws {
        let toolkit = try makeToolkit()
        let slug = try MCPToolkitSlug.parse("kit")
        #expect(
            MCPSessionDiscovery.scopes(resource: .toolkit(slug), toolkit: toolkit)
                == toolkit.dynamicScope()
        )
    }

    @Test func scopesMissingToolkitFailsClosed() throws {
        let slug = try MCPToolkitSlug.parse("kit")
        #expect(MCPSessionDiscovery.scopes(resource: .toolkit(slug), toolkit: nil) == [])
    }

    @Test func unrestrictedPredicateSeesWholeCatalog() throws {
        let registry = try makeRegistry()
        let isBlocked = MCPSessionDiscovery.blockedPredicate(scopes: nil)
        #expect(registry.list(isBlocked: isBlocked).count == 2)
        #expect(registry.search(query: "get", isBlocked: isBlocked).total == 2)
        let described = registry.describe(path: "gitlab.org.main.get", isBlocked: isBlocked)
        #expect(described.error == nil)
    }

    @Test func emptyPredicateBlocksWholeCatalog() throws {
        let registry = try makeRegistry()
        let isBlocked = MCPSessionDiscovery.blockedPredicate(scopes: [])
        #expect(registry.list(isBlocked: isBlocked).isEmpty)
        #expect(registry.search(query: "get", isBlocked: isBlocked).total == 0)
        let described = registry.describe(path: "github.org.main.get", isBlocked: isBlocked)
        #expect(described.error?.code == "tool_not_found")
    }

    @Test func toolkitPredicateHidesUngranted() throws {
        // Oracle: e2e "Local toolkits · scoped MCP hides blocked and unselected connections".
        let registry = try makeRegistry()
        let toolkit = try makeToolkit()
        let slug = try MCPToolkitSlug.parse("kit")
        let scopes = MCPSessionDiscovery.scopes(resource: .toolkit(slug), toolkit: toolkit)
        let isBlocked = MCPSessionDiscovery.blockedPredicate(scopes: scopes)
        let listed = registry.list(isBlocked: isBlocked)
        #expect(listed.count == 1)
        #expect(listed.first?.address.integration == "github")
        let searched = registry.search(query: "get", isBlocked: isBlocked)
        #expect(searched.total == 1)
        #expect(searched.items.first?.integration == "github")
        #expect(registry.describe(path: "github.org.main.get", isBlocked: isBlocked).error == nil)
        let hidden = registry.describe(path: "gitlab.org.main.get", isBlocked: isBlocked)
        #expect(hidden.error?.code == "tool_not_found")
        #expect(hidden.error?.suggestions?.contains("github.org.main.get") == true)
    }

    // MARK: - Create and ownership

    @Test func createDefaultCountsAndStampsOwner() async throws {
        let clock = ManualClock()
        let store = clock.store()
        let owner = try makeContext()
        let id = try await store.create(owner: owner, resource: .default)
        let count = await store.sessionCount
        #expect(count == 1)
        let enabled = await store.evictionEnabled
        #expect(enabled)
        let stored = try await store.ownerContext(for: id)
        #expect(stored == owner)
    }

    @Test func createToolkitWiresScopes() async throws {
        let toolkit = try makeToolkit()
        let clock = ManualClock()
        let store = clock.store(resolver: { slug in slug == toolkit.slug ? toolkit : nil })
        let owner = try makeContext()
        let id = try await store.create(owner: owner, resource: .toolkit(toolkit.slug))
        let isBlocked = try await store.blockedPredicate(for: id)
        #expect(isBlocked(try makeAddress("github")) == false)
        #expect(isBlocked(try makeAddress("gitlab")))
    }

    @Test func mintedIDsAreUUIDv4() async throws {
        // Pins the collision-loop exclusion proof: RFC 4122 v4 (the version
        // nibble leading the third group) carries 122 random bits, so no
        // deterministic test can trigger a re-mint.
        let clock = ManualClock()
        let store = clock.store()
        for _ in 0..<32 {
            let id = try await store.create(owner: try makeContext(), resource: .default)
            let groups = id.rawValue.uuidString.split(separator: "-")
            #expect(groups.count == 5)
            #expect(groups[2].first == "4")
        }
    }

    @Test func scopesPinnedAtCreateHostMustDispose() async throws {
        // Fixed scopes are the design: grants changing after create do not
        // reach the live session — the host must dispose it so the client
        // reconnects under the new grants.
        let github = try makeToolkit(patterns: ["tools.github.*"])
        let gitlab = try makeToolkit(patterns: ["tools.gitlab.*"])
        let current = Mutex(github)
        let clock = ManualClock()
        let store = clock.store(resolver: { _ in current.withLock { $0 } })
        let owner = try makeContext()
        let id = try await store.create(owner: owner, resource: .toolkit(github.slug))
        current.withLock { $0 = gitlab }
        let stale = try await store.blockedPredicate(for: id)
        #expect(stale(try makeAddress("github")) == false)
        #expect(stale(try makeAddress("gitlab")))
        // Host disposes; the reconnect serves the new grants.
        await store.dispose(id: id)
        let next = try await store.create(owner: owner, resource: .toolkit(github.slug))
        let fresh = try await store.blockedPredicate(for: next)
        #expect(fresh(try makeAddress("github")))
        #expect(fresh(try makeAddress("gitlab")) == false)
    }

    @Test func createUnknownToolkitThrowsAndOpensNothing() async throws {
        let clock = ManualClock()
        let store = clock.store()
        let owner = try makeContext()
        let slug = try MCPToolkitSlug.parse("kit")
        await #expect(throws: MCPServerSessionError.unknownToolkit) {
            try await store.create(owner: owner, resource: .toolkit(slug))
        }
        let count = await store.sessionCount
        #expect(count == 0)
    }

    @Test func defaultsServeDefaultPlaneOnly() async throws {
        // Bare defaults: the live clock stamps, and the nil resolver refuses
        // every toolkit create instead of serving the default plane.
        let store = MCPServerSessions()
        let owner = try makeContext()
        _ = try await store.create(owner: owner, resource: .default)
        let slug = try MCPToolkitSlug.parse("kit")
        await #expect(throws: MCPServerSessionError.unknownToolkit) {
            try await store.create(owner: owner, resource: .toolkit(slug))
        }
        let evicted = await store.sweep()
        #expect(evicted == 0)
        let enabled = await store.evictionEnabled
        #expect(enabled)
        let interval = await store.sweepInterval
        #expect(interval == 450)
    }

    @Test func createDefaultIgnoresResolver() async throws {
        let called = Mutex(false)
        let clock = ManualClock()
        let store = clock.store(resolver: { _ in
            called.withLock { $0 = true }
            return nil
        })
        _ = try await store.create(owner: try makeContext(), resource: .default)
        #expect(called.withLock { $0 } == false)
    }

    @Test func acquireUnknownAnswersNotFound() async throws {
        // Oracle: e2e "a terminated session's id is rejected with a reconnect error".
        let clock = ManualClock()
        let store = clock.store()
        let verdict = await store.acquire(
            id: MCPSessionID(), owner: try makeContext(), resource: .default
        )
        #expect(verdict == .notFound)
    }

    @Test func fixationAttackerIDGrantsNothing() async throws {
        // `create` mints; no API implants a caller-chosen id, so an attacker
        // UUID that parses cleanly still answers not-found on every handle.
        let clock = ManualClock()
        let store = clock.store()
        let owner = try makeContext()
        _ = try await store.create(owner: owner, resource: .default)
        let fixed = try MCPSessionHeader.parse(UUID().uuidString)
        let verdict = await store.acquire(id: fixed, owner: owner, resource: .default)
        #expect(verdict == .notFound)
        await #expect(throws: MCPServerSessionError.sessionNotFound) {
            try await store.ownerContext(for: fixed)
        }
        await #expect(throws: MCPServerSessionError.sessionNotFound) {
            try await store.blockedPredicate(for: fixed)
        }
        let removed = await store.dispose(id: fixed, owner: owner, resource: .default)
        #expect(removed == .notFound)
        let count = await store.sessionCount
        #expect(count == 1)
    }

    @Test func acquireWrongOwnerAnswersForbidden() async throws {
        let clock = ManualClock()
        let store = clock.store()
        let owner = try makeContext(uid: 501)
        let id = try await store.create(owner: owner, resource: .default)
        let verdict = await store.acquire(
            id: id, owner: try makeContext(uid: 502), resource: .default
        )
        #expect(verdict == .forbidden)
        // The miss re-stamps nothing: the stored owner is untouched.
        let stored = try await store.ownerContext(for: id)
        #expect(stored == owner)
    }

    @Test func acquireResourceMismatchAnswersForbidden() async throws {
        // A leaked id must not cross capability sets (seams.ts McpResource).
        let toolkit = try makeToolkit()
        let clock = ManualClock()
        let store = clock.store(resolver: { _ in toolkit })
        let owner = try makeContext()
        let plain = try await store.create(owner: owner, resource: .default)
        let scoped = try await store.create(owner: owner, resource: .toolkit(toolkit.slug))
        let crossUp = await store.acquire(id: plain, owner: owner, resource: .toolkit(toolkit.slug))
        #expect(crossUp == .forbidden)
        let crossDown = await store.acquire(id: scoped, owner: owner, resource: .default)
        #expect(crossDown == .forbidden)
        let same = await store.acquire(id: plain, owner: owner, resource: .default)
        #expect(same == .handled)
        await store.release(id: plain)
    }

    @Test func acquireRestampsOwnerPin() async throws {
        // Ports forward's owners.set: the stored context follows the presenter.
        let clock = ManualClock()
        let store = clock.store()
        let first = try makeContext(agent: "agent-a")
        let id = try await store.create(owner: first, resource: .default)
        let second = try makeContext(agent: "agent-b")
        let verdict = await store.acquire(id: id, owner: second, resource: .default)
        #expect(verdict == .handled)
        let stored = try await store.ownerContext(for: id)
        #expect(stored == second)
        await store.release(id: id)
    }

    @Test func acquireTouchesIdleStamp() async throws {
        let clock = ManualClock()
        let store = clock.store(idleTTL: 60)
        let owner = try makeContext()
        let id = try await store.create(owner: owner, resource: .default)
        clock.advance(by: 50)
        let verdict = await store.acquire(id: id, owner: owner, resource: .default)
        #expect(verdict == .handled)
        await store.release(id: id)
        // Idle from the touch (t=50), not from create (t=0): t=109 keeps it.
        clock.advance(by: 59)
        let kept = await store.sweep()
        #expect(kept == 0)
        let count = await store.sessionCount
        #expect(count == 1)
        clock.advance(by: 1)
        let evicted = await store.sweep()
        #expect(evicted == 1)
    }

    @Test func releaseUnknownIsNoop() async throws {
        let clock = ManualClock()
        let store = clock.store()
        let owner = try makeContext()
        _ = try await store.create(owner: owner, resource: .default)
        await store.release(id: MCPSessionID())
        let count = await store.sessionCount
        #expect(count == 1)
    }

    @Test func releaseSaturatesAtZero() async throws {
        // Extra releases never drive the counter negative: the session stays
        // evictable on its idle stamp alone.
        let clock = ManualClock()
        let store = clock.store(idleTTL: 60)
        let id = try await store.create(owner: try makeContext(), resource: .default)
        await store.release(id: id)
        await store.release(id: id)
        clock.advance(by: 61)
        let evicted = await store.sweep()
        #expect(evicted == 1)
    }

    // MARK: - withSession

    @Test func withSessionRunsBodyAndReleases() async throws {
        let clock = ManualClock()
        let store = clock.store(idleTTL: 60)
        let owner = try makeContext()
        let id = try await store.create(owner: owner, resource: .default)
        let value = try await store.withSession(id: id, owner: owner, resource: .default) { 42 }
        #expect(value == 42)
        clock.advance(by: 61)
        let evicted = await store.sweep()
        #expect(evicted == 1)
    }

    @Test func withSessionStaleThrowsTyped() async throws {
        let clock = ManualClock()
        let store = clock.store()
        await #expect(throws: MCPServerSessionError.sessionNotFound) {
            try await store.withSession(
                id: MCPSessionID(), owner: try makeContext(), resource: .default
            ) { 1 }
        }
    }

    @Test func withSessionForbiddenThrowsTyped() async throws {
        let clock = ManualClock()
        let store = clock.store()
        let id = try await store.create(owner: try makeContext(uid: 501), resource: .default)
        await #expect(throws: MCPServerSessionError.forbidden) {
            try await store.withSession(
                id: id, owner: try makeContext(uid: 502), resource: .default
            ) { 1 }
        }
    }

    @Test func withSessionBodyThrowStillReleases() async throws {
        struct BodyError: Error {}
        let clock = ManualClock()
        let store = clock.store(idleTTL: 60)
        let owner = try makeContext()
        let id = try await store.create(owner: owner, resource: .default)
        await #expect(throws: BodyError.self) {
            try await store.withSession(id: id, owner: owner, resource: .default) { throw BodyError() }
        }
        // Released despite the throw: the idle window reclaims the session.
        clock.advance(by: 61)
        let evicted = await store.sweep()
        #expect(evicted == 1)
    }

    // MARK: - Dispose (the DELETE path)

    @Test func disposeUnknownIsNoop() async throws {
        let clock = ManualClock()
        let store = clock.store()
        let owner = try makeContext()
        _ = try await store.create(owner: owner, resource: .default)
        await store.dispose(id: MCPSessionID())
        let count = await store.sessionCount
        #expect(count == 1)
    }

    @Test func disposeIsIdempotentCloserRunsOnce() async throws {
        // Oracle: seams.ts "Tear down a session by id (idempotent)".
        let clock = ManualClock()
        let store = clock.store()
        let counter = CloseCounter()
        let id = try await store.create(
            owner: try makeContext(), resource: .default, closer: counter.closer()
        )
        await store.dispose(id: id)
        await store.dispose(id: id)
        #expect(counter.count == 1)
        let count = await store.sessionCount
        #expect(count == 0)
    }

    @Test func disposeRemovesEveryHandle() async throws {
        let clock = ManualClock()
        let store = clock.store()
        let id = try await store.create(owner: try makeContext(), resource: .default)
        await store.dispose(id: id)
        let verdict = await store.acquire(
            id: id, owner: try makeContext(), resource: .default
        )
        #expect(verdict == .notFound)
        await #expect(throws: MCPServerSessionError.sessionNotFound) {
            try await store.ownerContext(for: id)
        }
        await #expect(throws: MCPServerSessionError.sessionNotFound) {
            try await store.blockedPredicate(for: id)
        }
    }

    @Test func deleteDisposePathIntegration() async throws {
        // Session DELETE: header value → strict parse → idempotent dispose.
        let clock = ManualClock()
        let store = clock.store()
        let id = try await store.create(owner: try makeContext(), resource: .default)
        let headers = ["mcp-session-id": id.rawValue.uuidString]
        let raw = try #require(MCPSessionHeader.value(from: headers))
        let parsed = try MCPSessionHeader.parse(raw)
        await store.dispose(id: parsed)
        let count = await store.sessionCount
        #expect(count == 0)
        await store.dispose(id: parsed)
        let again = await store.sessionCount
        #expect(again == 0)
    }

    @Test func disposeEnforcingUnknownAnswersNotFound() async throws {
        let clock = ManualClock()
        let store = clock.store()
        let verdict = await store.dispose(
            id: MCPSessionID(), owner: try makeContext(), resource: .default
        )
        #expect(verdict == .notFound)
    }

    @Test func disposeEnforcingWrongOwnerSurvives() async throws {
        // A presenter that cannot ride the session cannot tear it down
        // either: the Executor's DELETE reaches the transport only past
        // forward's ownership check.
        let clock = ManualClock()
        let store = clock.store()
        let counter = CloseCounter()
        let id = try await store.create(
            owner: try makeContext(uid: 501), resource: .default, closer: counter.closer()
        )
        let verdict = await store.dispose(
            id: id, owner: try makeContext(uid: 502), resource: .default
        )
        #expect(verdict == .forbidden)
        #expect(counter.count == 0)
        let serves = await store.acquire(
            id: id, owner: try makeContext(uid: 501), resource: .default
        )
        #expect(serves == .handled)
        await store.release(id: id)
    }

    @Test func disposeEnforcingResourceMismatchSurvives() async throws {
        let toolkit = try makeToolkit()
        let clock = ManualClock()
        let store = clock.store(resolver: { _ in toolkit })
        let owner = try makeContext()
        let id = try await store.create(owner: owner, resource: .toolkit(toolkit.slug))
        let verdict = await store.dispose(id: id, owner: owner, resource: .default)
        #expect(verdict == .forbidden)
        let count = await store.sessionCount
        #expect(count == 1)
    }

    @Test func disposeEnforcingOwnedDisposesOnce() async throws {
        let clock = ManualClock()
        let store = clock.store()
        let counter = CloseCounter()
        let owner = try makeContext()
        let id = try await store.create(
            owner: owner, resource: .default, closer: counter.closer()
        )
        let verdict = await store.dispose(id: id, owner: owner, resource: .default)
        #expect(verdict == .handled)
        #expect(counter.count == 1)
        // A second authorized DELETE finds nothing: the teardown is single-shot.
        let again = await store.dispose(id: id, owner: owner, resource: .default)
        #expect(again == .notFound)
        #expect(counter.count == 1)
        let count = await store.sessionCount
        #expect(count == 0)
    }

    @Test func disposeEnforcingReverseResourceMismatchSurvives() async throws {
        // The cross-plane matrix runs both directions: a toolkit presenter
        // cannot tear down a default-plane session either.
        let toolkit = try makeToolkit()
        let clock = ManualClock()
        let store = clock.store(resolver: { _ in toolkit })
        let counter = CloseCounter()
        let owner = try makeContext()
        let id = try await store.create(
            owner: owner, resource: .default, closer: counter.closer()
        )
        let verdict = await store.dispose(id: id, owner: owner, resource: .toolkit(toolkit.slug))
        #expect(verdict == .forbidden)
        #expect(counter.count == 0)
        let count = await store.sessionCount
        #expect(count == 1)
    }

    @Test func disposeEnforcingSameOwnerDifferentPinDisposes() async throws {
        // Ownership keys on the owner UID alone: a re-pinned presenter rides
        // — and therefore may tear down — the session.
        let clock = ManualClock()
        let store = clock.store()
        let counter = CloseCounter()
        let id = try await store.create(
            owner: try makeContext(agent: "agent-a"), resource: .default,
            closer: counter.closer()
        )
        let verdict = await store.dispose(
            id: id, owner: try makeContext(agent: "agent-b"), resource: .default
        )
        #expect(verdict == .handled)
        #expect(counter.count == 1)
        let count = await store.sessionCount
        #expect(count == 0)
    }

    @Test func disposeEnforcingBothWrongSurvives() async throws {
        // Both gates miss at once: still forbidden, never a partial take —
        // the session survives with its closer unrun.
        let toolkit = try makeToolkit()
        let clock = ManualClock()
        let store = clock.store(resolver: { _ in toolkit })
        let counter = CloseCounter()
        let id = try await store.create(
            owner: try makeContext(uid: 501), resource: .toolkit(toolkit.slug),
            closer: counter.closer()
        )
        let verdict = await store.dispose(
            id: id, owner: try makeContext(uid: 502), resource: .default
        )
        #expect(verdict == .forbidden)
        #expect(counter.count == 0)
        let count = await store.sessionCount
        #expect(count == 1)
    }

    // MARK: - Sweep, TTL, in-flight

    @Test func sweepKeepsFreshSessions() async throws {
        let clock = ManualClock()
        let store = clock.store(idleTTL: 60)
        let owner = try makeContext()
        _ = try await store.create(owner: owner, resource: .default)
        _ = try await store.create(owner: owner, resource: .default)
        let evicted = await store.sweep()
        #expect(evicted == 0)
        let count = await store.sessionCount
        #expect(count == 2)
    }

    @Test func sweepBoundaryIsInclusive() async throws {
        // `now - seen >= TTL` evicts: exactly TTL goes, a breath under stays.
        let clock = ManualClock()
        let store = clock.store(idleTTL: 60)
        let owner = try makeContext()
        _ = try await store.create(owner: owner, resource: .default)
        let start = clock.now()
        let early = await store.sweep(now: start.addingTimeInterval(59.999))
        #expect(early == 0)
        let exact = await store.sweep(now: start.addingTimeInterval(60))
        #expect(exact == 1)
        let count = await store.sessionCount
        #expect(count == 0)
    }

    @Test func sweepDisabledAtZeroTTL() async throws {
        let clock = ManualClock()
        let store = clock.store(idleTTL: 0)
        _ = try await store.create(owner: try makeContext(), resource: .default)
        let enabled = await store.evictionEnabled
        #expect(enabled == false)
        clock.advance(by: 1_000_000)
        let evicted = await store.sweep()
        #expect(evicted == 0)
        let count = await store.sessionCount
        #expect(count == 1)
    }

    @Test func sweepDisabledAtNegativeTTL() async throws {
        let clock = ManualClock()
        let store = clock.store(idleTTL: -5)
        _ = try await store.create(owner: try makeContext(), resource: .default)
        let enabled = await store.evictionEnabled
        #expect(enabled == false)
        let evicted = await store.sweep(now: Date.distantFuture)
        #expect(evicted == 0)
        let count = await store.sessionCount
        #expect(count == 1)
    }

    @Test func sweepExplicitNowBeatsClock() async throws {
        // An explicit instant drives the sweep even when the clock disagrees.
        let clock = ManualClock()
        let store = clock.store(idleTTL: 60)
        _ = try await store.create(owner: try makeContext(), resource: .default)
        let evicted = await store.sweep(now: clock.now().addingTimeInterval(61))
        #expect(evicted == 1)
    }

    @Test func sweepClockRewindKeepsSession() async throws {
        let clock = ManualClock()
        let store = clock.store(idleTTL: 60)
        _ = try await store.create(owner: try makeContext(), resource: .default)
        clock.advance(by: 120)
        clock.advance(by: -120)
        let evicted = await store.sweep()
        #expect(evicted == 0)
    }

    @Test func sweepSkipsInFlightThenReclaims() async throws {
        // Oracle: "never evicts a session while one of its requests is still
        // in flight" — and the reprieve ends when the call does.
        let clock = ManualClock()
        let store = clock.store(idleTTL: 60)
        let owner = try makeContext()
        let id = try await store.create(owner: owner, resource: .default)
        let verdict = await store.acquire(id: id, owner: owner, resource: .default)
        #expect(verdict == .handled)
        clock.advance(by: 600)
        let held = await store.sweep()
        #expect(held == 0)
        let count = await store.sessionCount
        #expect(count == 1)
        await store.release(id: id)
        // Released at t=600: idle from finish, so the next window reclaims it.
        let kept = await store.sweep()
        #expect(kept == 0)
        clock.advance(by: 60)
        let evicted = await store.sweep()
        #expect(evicted == 1)
    }

    @Test func sweepSkipsSessionClaimedAfterSnapshot() async throws {
        // A session claimed between the sweep's stale snapshot and its own
        // disposal turn is skipped, never evicted mid-request. The first
        // disposed session's closer rendezvouses with the test body so the
        // claim lands deterministically inside the sweep's suspension.
        let clock = ManualClock()
        let store = clock.store(idleTTL: 60)
        let owner = try makeContext()
        let started = Gate()
        let claimed = Gate()
        let armed = Mutex(true)
        let counter = CloseCounter()
        let closer: @Sendable () async -> Void = {
            await counter.closer()()
            let rendezvous = armed.withLock { $0 }
            if rendezvous {
                armed.withLock { $0 = false }
                started.signal()
                await claimed.wait()
            }
        }
        let first = try await store.create(owner: owner, resource: .default, closer: closer)
        let second = try await store.create(owner: owner, resource: .default, closer: closer)
        clock.advance(by: 61)
        let sweepTask = Task { await store.sweep() }
        await started.wait()
        // The disposed session is already gone; the survivor claims in-flight.
        // Dictionary order decides which is which, so claim both.
        let firstVerdict = await store.acquire(id: first, owner: owner, resource: .default)
        let secondVerdict = await store.acquire(id: second, owner: owner, resource: .default)
        #expect(firstVerdict != secondVerdict)
        let survivor = firstVerdict == .handled ? first : second
        claimed.signal()
        let evicted = await sweepTask.value
        #expect(evicted == 1)
        #expect(counter.count == 1)
        await store.release(id: survivor)
        // The reprieve ends when the call does: the next window reclaims it.
        clock.advance(by: 60)
        let reclaimed = await store.sweep()
        #expect(reclaimed == 1)
        #expect(counter.count == 2)
    }

    @Test func concurrentInFlightMatrix() async throws {
        let clock = ManualClock()
        let store = clock.store(idleTTL: 60)
        let owner = try makeContext()
        let id = try await store.create(owner: owner, resource: .default)
        let first = await store.acquire(id: id, owner: owner, resource: .default)
        let second = await store.acquire(id: id, owner: owner, resource: .default)
        #expect(first == .handled)
        #expect(second == .handled)
        clock.advance(by: 600)
        await store.release(id: id)
        let held = await store.sweep()
        #expect(held == 0)
        await store.release(id: id)
        // Second release restamps at t=600: still idle-fresh.
        let fresh = await store.sweep()
        #expect(fresh == 0)
        clock.advance(by: 60)
        let evicted = await store.sweep()
        #expect(evicted == 1)
    }

    @Test func forwardTouchKeepsBusyEvictsIdle() async throws {
        // Oracle: "evicts a session that goes idle past the TTL and keeps a
        // busy one" — the evicted id reports not-found, the busy one serves.
        let clock = ManualClock()
        let store = clock.store(idleTTL: 60)
        let owner = try makeContext()
        let idle = try await store.create(owner: owner, resource: .default)
        let busy = try await store.create(owner: owner, resource: .default)
        clock.advance(by: 30)
        let verdict = await store.acquire(id: busy, owner: owner, resource: .default)
        #expect(verdict == .handled)
        await store.release(id: busy)
        clock.advance(by: 31)
        let evicted = await store.sweep()
        #expect(evicted == 1)
        let count = await store.sessionCount
        #expect(count == 1)
        let gone = await store.acquire(id: idle, owner: owner, resource: .default)
        #expect(gone == .notFound)
        let serves = await store.acquire(id: busy, owner: owner, resource: .default)
        #expect(serves == .handled)
        await store.release(id: busy)
    }

    @Test func inFlightSurvivesTeardown() async throws {
        // Oracle: e2e "in-flight requests survive their session's teardown as
        // protocol errors" — the body completes; the trailing release is a
        // no-op that never resurrects the id.
        let clock = ManualClock()
        let store = clock.store(idleTTL: 60)
        let owner = try makeContext()
        let id = try await store.create(owner: owner, resource: .default)
        let value = try await store.withSession(id: id, owner: owner, resource: .default) {
            await store.dispose(id: id)
            return "completed"
        }
        #expect(value == "completed")
        let count = await store.sessionCount
        #expect(count == 0)
        let verdict = await store.acquire(id: id, owner: owner, resource: .default)
        #expect(verdict == .notFound)
    }

    @Test func releaseAfterDisposeNeverResurrects() async throws {
        let clock = ManualClock()
        let store = clock.store(idleTTL: 60)
        let owner = try makeContext()
        let id = try await store.create(owner: owner, resource: .default)
        let verdict = await store.acquire(id: id, owner: owner, resource: .default)
        #expect(verdict == .handled)
        await store.dispose(id: id)
        await store.release(id: id)
        await store.release(id: id)
        let count = await store.sessionCount
        #expect(count == 0)
        let evicted = await store.sweep()
        #expect(evicted == 0)
    }

    @Test func evictionRunsCloserOnce() async throws {
        // Oracle: "shuts down the scoped executor and custom closer when an
        // idle session is evicted".
        let clock = ManualClock()
        let store = clock.store(idleTTL: 60)
        let counter = CloseCounter()
        _ = try await store.create(
            owner: try makeContext(), resource: .default, closer: counter.closer()
        )
        clock.advance(by: 61)
        let evicted = await store.sweep()
        #expect(evicted == 1)
        #expect(counter.count == 1)
        let again = await store.sweep()
        #expect(again == 0)
        #expect(counter.count == 1)
    }

    @Test func evictionRemovesEveryHandle() async throws {
        // An evicted id answers stale on every handle, exactly like a
        // disposed one: acquire, owner read, and discovery read all decline.
        let clock = ManualClock()
        let store = clock.store(idleTTL: 60)
        let owner = try makeContext()
        let id = try await store.create(owner: owner, resource: .default)
        clock.advance(by: 61)
        let evicted = await store.sweep()
        #expect(evicted == 1)
        let verdict = await store.acquire(id: id, owner: owner, resource: .default)
        #expect(verdict == .notFound)
        await #expect(throws: MCPServerSessionError.sessionNotFound) {
            try await store.ownerContext(for: id)
        }
        await #expect(throws: MCPServerSessionError.sessionNotFound) {
            try await store.blockedPredicate(for: id)
        }
    }

    // MARK: - Close-all

    @Test func closeDrainsEverySession() async throws {
        // Oracle: "shuts down the scoped executor when sessions.close() is
        // called" — every closer runs, the store empties, close is idempotent.
        let clock = ManualClock()
        let store = clock.store(idleTTL: 60)
        let counters = [CloseCounter(), CloseCounter(), CloseCounter()]
        for counter in counters {
            _ = try await store.create(
                owner: try makeContext(), resource: .default, closer: counter.closer()
            )
        }
        _ = try await store.create(owner: try makeContext(), resource: .default)
        let before = await store.sessionCount
        #expect(before == 4)
        await store.close()
        let count = await store.sessionCount
        #expect(count == 0)
        #expect(counters.map(\.count) == [1, 1, 1])
        await store.close()
        #expect(counters.map(\.count) == [1, 1, 1])
        let swept = await store.sweep()
        #expect(swept == 0)
    }

    @Test func closeOnEmptyStoreIsNoop() async throws {
        let clock = ManualClock()
        let store = clock.store()
        await store.close()
        let count = await store.sessionCount
        #expect(count == 0)
    }

    @Test func closeDrainsInFlightSessions() async throws {
        // Close waits for no request: claimed sessions still go, and their
        // trailing releases are harmless no-ops.
        let clock = ManualClock()
        let store = clock.store(idleTTL: 60)
        let owner = try makeContext()
        let id = try await store.create(owner: owner, resource: .default)
        let verdict = await store.acquire(id: id, owner: owner, resource: .default)
        #expect(verdict == .handled)
        await store.close()
        let count = await store.sessionCount
        #expect(count == 0)
        await store.release(id: id)
        let again = await store.sessionCount
        #expect(again == 0)
    }

    @Test func closeIsConcurrentlyIdempotent() async throws {
        // Closes racing each other (and disposes) take every session once:
        // each closer runs exactly once however the turns interleave.
        let clock = ManualClock()
        let store = clock.store(idleTTL: 60)
        let owner = try makeContext()
        let counters = (0..<8).map { _ in CloseCounter() }
        var ids: [MCPSessionID] = []
        for counter in counters {
            ids.append(
                try await store.create(
                    owner: owner, resource: .default, closer: counter.closer()
                )
            )
        }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask { await store.close() }
            }
            for id in ids {
                group.addTask { await store.dispose(id: id) }
            }
            await group.waitForAll()
        }
        let count = await store.sessionCount
        #expect(count == 0)
        #expect(counters.map(\.count) == Array(repeating: 1, count: 8))
    }

    // MARK: - Sweep cadence

    @Test func sweepIntervalValues() async throws {
        // max(30s, floor(TTL/4)): the floor keeps small TTLs from spinning.
        #expect(MCPServerSessions.sweepIntervalSeconds(idleTTLSeconds: 1800) == 450)
        #expect(MCPServerSessions.sweepIntervalSeconds(idleTTLSeconds: 60) == 30)
        #expect(MCPServerSessions.sweepIntervalSeconds(idleTTLSeconds: 121) == 30)
        #expect(MCPServerSessions.sweepIntervalSeconds(idleTTLSeconds: 124) == 31)
        #expect(MCPServerSessions.sweepIntervalSeconds(idleTTLSeconds: 0) == 30)
        #expect(MCPServerSessions.sweepIntervalSeconds(idleTTLSeconds: -10) == 30)
        #expect(MCPServerSessions.defaultIdleTTLSeconds == 1800)
        #expect(MCPServerSessions.minimumSweepIntervalSeconds == 30)
        let clock = ManualClock()
        let interval = await clock.store(idleTTL: 1800).sweepInterval
        #expect(interval == 450)
    }

    // MARK: - Stress

    @Test func stressManySessionsSweepAll() async throws {
        let clock = ManualClock()
        let store = clock.store(idleTTL: 60)
        let owner = try makeContext()
        for _ in 0..<200 {
            _ = try await store.create(owner: owner, resource: .default)
        }
        let before = await store.sessionCount
        #expect(before == 200)
        clock.advance(by: 61)
        let evicted = await store.sweep()
        #expect(evicted == 200)
        let count = await store.sessionCount
        #expect(count == 0)
    }

    @Test func stressConcurrentWithSession() async throws {
        let clock = ManualClock()
        let store = clock.store(idleTTL: 60)
        let owner = try makeContext()
        let id = try await store.create(owner: owner, resource: .default)
        let wins = Mutex(0)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    let value = try await store.withSession(id: id, owner: owner, resource: .default) {
                        1
                    }
                    wins.withLock { $0 += value }
                }
            }
            try await group.waitForAll()
        }
        #expect(wins.withLock { $0 } == 64)
        // Every claim released: the idle window reclaims the session.
        clock.advance(by: 61)
        let evicted = await store.sweep()
        #expect(evicted == 1)
    }

    @Test func stressInterleavedCreateDisposeSweepClose() async throws {
        let clock = ManualClock()
        let store = clock.store(idleTTL: 60)
        let owner = try makeContext()
        let counter = CloseCounter()
        var live: [MCPSessionID] = []
        for round in 0..<100 {
            let id = try await store.create(
                owner: owner, resource: .default, closer: counter.closer()
            )
            live.append(id)
            if round % 3 == 0 {
                await store.dispose(id: live.removeFirst())
            }
            if round % 10 == 0 {
                clock.advance(by: 61)
                _ = await store.sweep()
                live = []
            }
        }
        await store.close()
        let count = await store.sessionCount
        #expect(count == 0)
        // Every created session's closer ran exactly once, on whichever
        // disposal path took it.
        #expect(counter.count == 100)
    }

    @Test func stressSweepRacesDispose() async throws {
        // A dispose racing the sweep double-takes nothing: the closer runs
        // once and the counts reconcile.
        let clock = ManualClock()
        let store = clock.store(idleTTL: 60)
        let owner = try makeContext()
        let counter = CloseCounter()
        var ids: [MCPSessionID] = []
        for _ in 0..<50 {
            ids.append(
                try await store.create(
                    owner: owner, resource: .default, closer: counter.closer()
                )
            )
        }
        clock.advance(by: 61)
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { await store.dispose(id: id) }
            }
            group.addTask { _ = await store.sweep() }
            await group.waitForAll()
        }
        let count = await store.sessionCount
        #expect(count == 0)
        #expect(counter.count == 50)
    }
}
