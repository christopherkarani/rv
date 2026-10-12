import Foundation
import RVDomain
import RVPolicy

// MARK: - Upstream transport selection

/// Concrete wire transport to an upstream MCP server.
///
/// Ports Executor `McpTransport` (`streamable-http` | `sse` | `stdio` |
/// `auto`, `packages/plugins/mcp/src/sdk/types.ts`), minus the `auto`
/// preference, which resolves to an ordered candidate list instead of a
/// transport of its own.
public enum MCPUpstreamTransport: String, Sendable, Equatable, Hashable {
    /// Streamable HTTP (POST-first, the modern default).
    case streamableHTTP = "streamable-http"
    /// Legacy server-sent-events transport (GET-first).
    case sse
    /// Newline-delimited JSON over a spawned child's pipes.
    case stdio
}

/// Resolves an X1-I remote preference into the transports to try, in order.
///
/// Ports the `remoteTransport` default (`auto`,
/// `packages/plugins/mcp/src/sdk/types.ts`) plus the probe's legacy-GET
/// fallback (`packages/plugins/mcp/src/sdk/probe-shape.ts`): `.auto` tries
/// modern streamable HTTP first and legacy SSE second; an explicit
/// preference tries exactly that transport.
public enum MCPUpstreamTransportSelection: Sendable {
    public static func candidates(for preference: MCPRemoteTransport) -> [MCPUpstreamTransport] {
        switch preference {
        case .streamableHttp:
            return [.streamableHTTP]
        case .sse:
            return [.sse]
        case .auto:
            return [.streamableHTTP, .sse]
        }
    }
}

// MARK: - Shape probe verdict

/// Why the shape probe rejected an endpoint as not-MCP.
///
/// Ports `McpProbeRejectCategory` (`probe-shape.ts`): `authRequired` means
/// the endpoint answered 401/403 without proving it speaks MCP (the user's
/// next step is still "supply credentials and retry"); `wrongShape` means
/// the endpoint answered with a body or status no MCP server emits.
public enum MCPProbeRejectCategory: String, Sendable, Equatable, Hashable {
    case authRequired = "auth-required"
    case wrongShape = "wrong-shape"
}

/// Shape-probe outcome for one endpoint.
///
/// Ports `McpShapeProbeResult` (`probe-shape.ts`). Reasons are fixed
/// labels (status numbers at most), never response bodies: the probe
/// reason is never surfaced verbatim to the operator.
public enum MCPProbeVerdict: Sendable, Equatable {
    /// The endpoint speaks MCP. `requiresAuth` reports whether the proof
    /// was an auth challenge (401/403 + Bearer [REDACTED] an unauthenticated answer.
    case mcp(requiresAuth: Bool)
    /// The endpoint is reachable but the response does not look like MCP.
    case notMCP(category: MCPProbeRejectCategory, reason: String)
    /// Transport-level failure (DNS, TLS, timeout, refused, malformed URL).
    case unreachable(reason: String)
}

// MARK: - Shape probe classifier

/// One probe HTTP response: status, headers, and body text.
public struct MCPProbeHTTPResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: String

    public init(status: Int, headers: [String: String], body: String) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// Pure wire-shape classifier: the `classify` gate from `probe-shape.ts`.
///
/// `classify` returns nil exactly when Executor's gate falls through
/// (a status that is neither 2xx nor 401/403): the caller then runs the
/// legacy-GET retry or the modern `server/discover` fallback. The
/// `protectedResource` closure performs the RFC 9728 metadata check; it
/// runs only on the two paths Executor consults it (a challenge without
/// a Bearer [REDACTED] a bare Bearer [REDACTED] usable accept signal), so callers
/// can prove the extra request never fires otherwise.
public enum MCPProbeClassifier {
    /// Bodies past this size are not shape-sniffed: the body still
    /// arrived (the endpoint is reachable), but its shape is unread, so
    /// body-dependent gates treat it as absent. Matches the sibling
    /// envelope caps.
    public static let maximumBodyBytes = 65_536

    public static func classify(
        response: MCPProbeHTTPResponse,
        method: MCPHTTPMethod,
        protectedResource: () async -> Bool
    ) async -> MCPProbeVerdict? {
        let contentType = header(response.headers, name: "content-type") ?? ""
        let sse = isSSEContentType(contentType)
        if isAuthStatus(response.status) {
            return await classifyAuth(response: response, sse: sse, protectedResource: protectedResource)
        }
        if response.status >= 200 && response.status < 300 {
            return classifySuccess(response: response, method: method, sse: sse)
        }
        return nil
    }

    private static func classifyAuth(
        response: MCPProbeHTTPResponse,
        sse: Bool,
        protectedResource: () async -> Bool
    ) async -> MCPProbeVerdict? {
        let challenge = header(response.headers, name: "www-authenticate")
        guard let challenge, isBearerChallenge(challenge) else {
            if await protectedResource() {
                return .mcp(requiresAuth: true)
            }
            return .notMCP(
                category: .authRequired,
                reason: "\(response.status) without Bearer [REDACTED] — not an MCP auth challenge"
            )
        }
        if hasAuthParam(challenge, name: "resource_metadata") {
            return .mcp(requiresAuth: true)
        }
        if hasAuthParam(challenge, name: "error") {
            return .mcp(requiresAuth: true)
        }
        if sse {
            return .mcp(requiresAuth: true)
        }
        let body = sniffableBody(response.body)
        if isJSONRPCEnvelope(body) || isOAuthErrorBody(body) {
            return .mcp(requiresAuth: true)
        }
        if await protectedResource() {
            return .mcp(requiresAuth: true)
        }
        return .notMCP(
            category: .authRequired,
            reason: "\(response.status) + Bearer [REDACTED] resource_metadata, JSON-RPC body, or OAuth error body"
        )
    }

    private static func classifySuccess(
        response: MCPProbeHTTPResponse,
        method: MCPHTTPMethod,
        sse: Bool
    ) -> MCPProbeVerdict? {
        switch method {
        case .get:
            guard sse else {
                return .notMCP(category: .wrongShape, reason: "GET response is not an SSE stream")
            }
            return .mcp(requiresAuth: false)
        case .post:
            if sse {
                return .mcp(requiresAuth: false)
            }
            guard isJSONRPCEnvelope(sniffableBody(response.body)) else {
                return .notMCP(category: .wrongShape, reason: "2xx POST body is not a JSON-RPC envelope")
            }
            return .mcp(requiresAuth: false)
        }
    }

    /// 401 is what the MCP authorization spec mandates; 403 is what an
    /// edge authenticator (Cloudflare Access) answers instead.
    static func isAuthStatus(_ status: Int) -> Bool {
        status == 401 || status == 403
    }

    /// Case-insensitive header lookup (RFC 7230).
    static func header(_ headers: [String: String], name: String) -> String? {
        if let direct = headers[name] {
            return direct
        }
        let lower = name.lowercased()
        for (key, value) in headers where key.lowercased() == lower {
            return value
        }
        return nil
    }

    /// `/^\s*text\/event-stream\b/i`.
    static func isSSEContentType(_ value: String) -> Bool {
        tokenPrefix(value, token: "text/event-stream")
    }

    /// `/^\s*bearer\b/i`.
    static func isBearerChallenge(_ value: String) -> Bool {
        tokenPrefix(value, token: "bearer")
    }

    /// Leading whitespace, then `token` case-insensitively, then a word
    /// boundary (end of string or a non-word scalar). The boundary
    /// reads the first scalar after the token — not the first
    /// Character — so a multi-scalar grapheme (notably a base letter
    /// plus a combining mark) judges by its base, exactly like the
    /// `\b` this mirrors.
    private static func tokenPrefix(_ value: String, token: String) -> Bool {
        let rest = value.drop(while: { $0.isWhitespace })
        guard rest.count >= token.count else { return false }
        let head = rest.prefix(token.count)
        guard head.lowercased() == token else { return false }
        let tail = rest.dropFirst(token.count)
        guard tail.isEmpty == false else { return true }
        return tail.unicodeScalars.prefix(1).contains(where: { isWordCode($0.value) }) == false
    }

    /// `/(?:^|[\s,])<name>\s*=/i`: the auth-param must start the
    /// challenge or follow whitespace/a comma; anything else (notably a
    /// hyphen, as in `x-error=`) does not match.
    static func hasAuthParam(_ challenge: String, name: String) -> Bool {
        let chars = Array(challenge)
        let needle = Array(name.lowercased())
        guard chars.count >= needle.count else { return false }
        for start in 0...(chars.count - needle.count) {
            let slice = chars[start..<(start + needle.count)]
            guard String(slice).lowercased() == name.lowercased() else { continue }
            if start > 0 {
                let before = chars[start - 1]
                guard before.isWhitespace || before == "," else { continue }
            }
            var rest = chars[(start + needle.count)...]
            while let first = rest.first, first.isWhitespace {
                rest = rest.dropFirst()
            }
            guard rest.first == "=" else { continue }
            return true
        }
        return false
    }

    /// Word scalar for the token boundary: ASCII letters, digits,
    /// and underscore (the `\w` this mirrors).
    private static func isWordCode(_ code: UInt32) -> Bool {
        (code >= 65 && code <= 90) || (code >= 97 && code <= 122)
            || (code >= 48 && code <= 57) || code == 95
    }

    private static func sniffableBody(_ body: String) -> String {
        body.utf8.count > maximumBodyBytes ? "" : body
    }

    /// A body parsing as a JSON-RPC 2.0 envelope: an object carrying
    /// `jsonrpc: "2.0"` plus `result`, `error`, or `method`.
    static func isJSONRPCEnvelope(_ body: String) -> Bool {
        guard let object = jsonObject(body),
            object["jsonrpc"] as? String == "2.0"
        else {
            return false
        }
        return object["result"] != nil || object["error"] != nil || object["method"] != nil
    }

    /// An RFC 6750 OAuth Bearer [REDACTED] envelope (`{error:
    /// "invalid_token", ...}`), explicitly excluding the GraphQL
    /// `{errors: [...]}` shape.
    static func isOAuthErrorBody(_ body: String) -> Bool {
        guard let object = jsonObject(body) else { return false }
        if object["errors"] is [Any] { return false }
        return object["error"] is String
    }

    private static func jsonObject(_ body: String) -> [String: Any]? {
        guard body.isEmpty == false else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: Data(body.utf8), options: []) as? [String: Any]
    }
}

// MARK: - Endpoint telemetry

/// Credential-free endpoint attributes for spans and logs.
///
/// Ports `endpointForTelemetry` / `endpointTelemetryAttributes`
/// (`packages/core/sdk/src/telemetry-endpoint.ts`): the sanitized URL
/// keeps scheme/host/path and drops query, fragment, and userinfo.
/// Unparseable input degrades through textual truncation, never
/// verbatim — a malformed paste is exactly where a stray credential
/// hides.
public struct MCPUpstreamEndpointAttributes: Sendable, Equatable {
    /// Scheme/host/path with query, fragment, and userinfo stripped.
    public var sanitized: String
    /// Scheme + host (+ port) for the parseable branch; nil when the
    /// endpoint did not parse.
    public var origin: String?
    /// A query string was present (and stripped).
    public var hasQuery: Bool
    /// A fragment was present (and stripped).
    public var hasFragment: Bool
    /// Userinfo was present (and stripped).
    public var hasUserinfo: Bool

    public init(sanitized: String, origin: String?, hasQuery: Bool, hasFragment: Bool, hasUserinfo: Bool) {
        self.sanitized = sanitized
        self.origin = origin
        self.hasQuery = hasQuery
        self.hasFragment = hasFragment
        self.hasUserinfo = hasUserinfo
    }
}

public enum MCPUpstreamEndpointTelemetry: Sendable {
    public static func attributes(endpoint: String) -> MCPUpstreamEndpointAttributes {
        guard let components = URLComponents(string: endpoint),
            let scheme = components.scheme,
            let host = components.host, host.isEmpty == false
        else {
            return opaque(endpoint: endpoint)
        }
        let authority = authorityOf(host: host, port: components.port)
        return MCPUpstreamEndpointAttributes(
            sanitized: "\(scheme.lowercased())://\(authority)\(components.percentEncodedPath)",
            origin: "\(scheme.lowercased())://\(authority)",
            hasQuery: components.query?.isEmpty == false,
            hasFragment: components.fragment?.isEmpty == false,
            hasUserinfo: userinfoPresent(user: components.user, password: components.password)
        )
    }

    /// The sanitized URL only; see `attributes(endpoint:)` for the rule.
    public static func sanitized(endpoint: String) -> String {
        attributes(endpoint: endpoint).sanitized
    }

    static func authorityOf(host: String, port: Int?) -> String {
        let lowered = host.lowercased()
        if lowered.hasPrefix("[") {
            guard let port else {
                return lowered
            }
            return "\(lowered):\(port)"
        }
        let bracketed = lowered.contains(":") ? "[\(lowered)]" : lowered
        guard let port else {
            return bracketed
        }
        return "\(bracketed):\(port)"
    }

    /// Userinfo is present when either half carries text: a bare
    /// `@` parses to empty halves, which name no credential (Executor
    /// `username !== "" || password !== ""`). Split out so the
    /// password-only arm (no URL parser produces a nil user beside a
    /// password) is directly testable.
    static func userinfoPresent(user: String?, password: String?) -> Bool {
        user?.isEmpty == false || password?.isEmpty == false
    }

    /// Textual fallback: cut at the first `?`/`#`, then drop anything
    /// before a remaining `@` (possible userinfo; over-stripping is the
    /// safe direction). A `?` after the `#` is fragment content, not a
    /// query.
    private static func opaque(endpoint: String) -> MCPUpstreamEndpointAttributes {
        let queryStart = endpoint.firstIndex(of: "?")
        let fragmentStart = endpoint.firstIndex(of: "#")
        let cut = [queryStart, fragmentStart].compactMap { $0 }.min()
        let beforeCut = cut.map { String(endpoint[..<$0]) } ?? endpoint
        let userinfoEnd = beforeCut.lastIndex(of: "@")
        let hasQuery: Bool = switch (queryStart, fragmentStart) {
        case (nil, _): false
        case (_, nil): true
        case (let query?, let fragment?): query < fragment
        }
        return MCPUpstreamEndpointAttributes(
            sanitized: userinfoEnd.map { String(beforeCut[beforeCut.index(after: $0)...]) } ?? beforeCut,
            origin: nil,
            hasQuery: hasQuery,
            hasFragment: fragmentStart != nil,
            hasUserinfo: userinfoEnd != nil
        )
    }
}

// MARK: - User-facing probe messages

/// Fixed operator messages for probe outcomes.
///
/// Ports `userFacingProbeMessage` (`plugin.ts`): the raw probe reason is
/// never surfaced verbatim. Every message is a compile-time constant,
/// so no endpoint, credential, or response text can leak through one.
public enum MCPProbeMessages: Sendable {
    /// Message for `.unreachable` (Executor verbatim).
    public static let unreachable =
        "Couldn't reach this URL. Check the address, your network, and that the server is running."
    /// Message for `.notMCP` of either category (Executor verbatim).
    public static let notMCP =
        "This URL doesn't appear to host an MCP server. Double-check the address, including the path."
    /// Empty-endpoint paste (Executor `probeEndpoint` verbatim).
    public static let missingEndpoint = "Endpoint URL is required"
    /// The endpoint speaks MCP but tools could not be discovered
    /// (Executor `probeEndpoint` close: "Executor" reads "RV").
    public static let undiscoverable =
        "This endpoint looks like MCP, but RV couldn't discover tools from it. Check the URL and try again."
    /// A stdio command that failed its spawn check.
    public static let stdioStartFailure =
        "Couldn't start this command. Check that it exists and is executable."

    /// The message for a rejecting verdict, or nil when the verdict
    /// carries no user-facing failure (`.mcp`).
    public static func message(for verdict: MCPProbeVerdict) -> String? {
        switch verdict {
        case .mcp:
            return nil
        case .notMCP:
            return notMCP
        case .unreachable:
            return unreachable
        }
    }
}

// MARK: - Probe seams

/// One probe HTTP request: method, absolute URL, headers, and body text.
public struct MCPProbeHTTPRequest: Sendable, Equatable {
    public var method: MCPHTTPMethod
    public var url: String
    public var headers: [String: String]
    public var body: String
    /// Per-request budget in milliseconds. The seam enforces it; a
    /// request that overruns surfaces as a seam timeout, which the
    /// prober reads as `.unreachable`.
    public var timeoutMs: Int

    public init(method: MCPHTTPMethod, url: String, headers: [String: String], body: String, timeoutMs: Int) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeoutMs = timeoutMs
    }
}

/// Closed seam-failure vocabulary. Labels only; URLs and bodies never echo.
public enum MCPProbeSeamError: Error, Sendable, Equatable {
    /// The request overran its budget.
    case timeout
    /// DNS, TLS, refused, reset — the far end never answered.
    case connectionFailed
}

/// One HTTP exchange. Production passes a URLSession-backed send;
/// tests pass a scripted closure. Every probe request — including the
/// RFC 9728 metadata fallback — flows through this seam.
///
/// Production contract: the send enforces `timeoutMs` per request
/// (surfacing overruns as `.timeout`), follows zero redirects
/// (a 3xx is just a response to classify, never chased — chasing
/// would forward probe credentials to an attacker-chosen host),
/// caps the buffered body (oversized bodies degrade to unread
/// at the classifier, but the seam must not buffer unboundedly to
/// get there), and never logs request URLs, headers, or bodies
/// (URLs and headers may carry rendered secrets).
public struct MCPProbeHTTPExchange: Sendable {
    public var send: @Sendable (MCPProbeHTTPRequest) async throws -> MCPProbeHTTPResponse

    public init(send: @escaping @Sendable (MCPProbeHTTPRequest) async throws -> MCPProbeHTTPResponse) {
        self.send = send
    }
}

/// What a successful discovery reports: the tool count plus the
/// server's self-description. Ports the `discoverToolsFromInput`
/// manifest projection (`probeEndpoint` reads `manifest.server` and
/// `manifest.tools.length`).
public struct MCPDiscoveredManifest: Sendable, Equatable {
    public var toolCount: Int
    public var serverName: String?
    public var instructions: String?

    public init(toolCount: Int, serverName: String?, instructions: String?) {
        self.toolCount = toolCount
        self.serverName = serverName
        self.instructions = instructions
    }
}

/// Full tool discovery ahead of the shape probe. Any throw degrades to
/// "undiscovered" and the shape probe decides from there, mirroring
/// `probeEndpoint`'s `Effect.catch` around `discoverToolsFromInput`.
///
/// The endpoint arrives with its rendered inputs (headers resolved,
/// literals verbatim), mirroring `discoverToolsFromInput`'s
/// headers/query-params arguments: discovery without them could never
/// connect to an authenticated endpoint even with correct credentials.
/// Production contract: the run is time-bounded (a hanging discovery
/// must not hang the probe past the caller's patience) and never
/// logs the rendered inputs (they may carry secret values).
public struct MCPProbeDiscovery: Sendable {
    public var run: @Sendable (String, MCPProbeRenderedInputs) async throws -> MCPDiscoveredManifest

    public init(run: @escaping @Sendable (String, MCPProbeRenderedInputs) async throws -> MCPDiscoveredManifest) {
        self.run = run
    }

    /// No live discovery: every attempt degrades to the shape probe.
    /// Production wiring replaces this when the connector lands.
    public static var unavailable: MCPProbeDiscovery {
        MCPProbeDiscovery(run: { _, _ in throw MCPProbeSeamError.connectionFailed })
    }
}

/// What the OAuth metadata probe reports: whether the authorization
/// server supports dynamic client registration.
public struct MCPProbeOAuthSignal: Sendable, Equatable {
    public var supportsDynamicRegistration: Bool

    public init(supportsDynamicRegistration: Bool) {
        self.supportsDynamicRegistration = supportsDynamicRegistration
    }
}

/// OAuth metadata probe (`ctx.oauth.probe`). Any throw degrades to
/// "no OAuth metadata" and the flow falls back to manual auth,
/// mirroring `probeEndpoint`'s `Effect.catch`.
///
/// Production contract: the run is time-bounded like discovery —
/// neither seam may hang the probe.
public struct MCPProbeOAuth: Sendable {
    public var run: @Sendable (String) async throws -> MCPProbeOAuthSignal

    public init(run: @escaping @Sendable (String) async throws -> MCPProbeOAuthSignal) {
        self.run = run
    }

    /// No OAuth probe: authenticated endpoints report manual auth.
    /// Production wiring replaces this when OAuth connections land.
    public static var unavailable: MCPProbeOAuth {
        MCPProbeOAuth(run: { _ in throw MCPProbeSeamError.connectionFailed })
    }
}

/// Broker secret resolution for probe-time header rendering. Nil means
/// the ref did not resolve and the probe fails closed with
/// `.unresolvedSecret` (the header label, never the value).
public struct MCPProbeSecretResolver: Sendable {
    public var resolve: @Sendable (MCPSecretSelector) async -> String?

    public init(resolve: @escaping @Sendable (MCPSecretSelector) async -> String?) {
        self.resolve = resolve
    }

    public static var unavailable: MCPProbeSecretResolver {
        MCPProbeSecretResolver(resolve: { _ in nil })
    }
}

/// Probe knobs. Ports `ProbeOptions` (`probe-shape.ts`).
public struct MCPProbeOptions: Sendable, Equatable {
    /// Per-request budget in milliseconds. Clamped to 1...60_000;
    /// Executor's default is 8000.
    public var timeoutMs: Int

    public init(timeoutMs: Int) {
        self.timeoutMs = min(max(timeoutMs, 1), 60_000)
    }

    /// Executor's default budget (8000ms).
    public static var `default`: MCPProbeOptions {
        MCPProbeOptions(timeoutMs: 8_000)
    }
}

/// Endpoint probe outcome. Ports `McpProbeResult`
/// (`McpProbeEndpointOutputSchema`); `versionNegotiation` has no RV
/// counterpart and is omitted. `supportsDynamicRegistration` is
/// always false until dynamic client registration lands.
public struct MCPProbeResult: Sendable, Equatable {
    public var connected: Bool
    public var requiresAuthentication: Bool
    public var requiresOAuth: Bool
    public var supportsDynamicRegistration: Bool
    /// Server name from discovery, else the endpoint hostname, else "mcp".
    public var name: String
    /// Derived namespace for the endpoint.
    public var slug: String
    public var toolCount: Int?
    public var serverName: String?
    public var instructions: String?

    public init(
        connected: Bool,
        requiresAuthentication: Bool,
        requiresOAuth: Bool,
        supportsDynamicRegistration: Bool,
        name: String,
        slug: String,
        toolCount: Int?,
        serverName: String?,
        instructions: String?
    ) {
        self.connected = connected
        self.requiresAuthentication = requiresAuthentication
        self.requiresOAuth = requiresOAuth
        self.supportsDynamicRegistration = supportsDynamicRegistration
        self.name = name
        self.slug = slug
        self.toolCount = toolCount
        self.serverName = serverName
        self.instructions = instructions
    }
}

/// Probe failures. Messages are fixed operator text (see
/// `MCPProbeMessages`); reasons are field labels, never values.
public enum MCPProbeError: Error, Sendable, Equatable {
    /// The pasted endpoint was empty.
    case missingEndpoint
    /// The endpoint rejects the probe (wrong shape) or is unreachable.
    /// The message is the fixed operator text for the verdict.
    case endpointFailed(message: String)
    /// The endpoint speaks MCP but tools could not be discovered.
    case undiscoverable(message: String)
    /// A declared header secret did not resolve. The label names the
    /// header (or `auth` for the auth declaration), never the value.
    case unresolvedSecret(label: String)
    /// A stdio command failed its spawn check.
    case stdioStartFailed(message: String)
}

// MARK: - Upstream prober

/// Rendered probe inputs: secret refs resolved, literals verbatim.
///
/// Literals pass through byte-identical: an embedded `secret-public-ref:`
/// marker that is not a leading prefix is literal text, never a ref.
/// Only the `.secret` object form resolves through the broker seam.
public struct MCPProbeRenderedInputs: Sendable, Equatable {
    public var headers: [String: String]
    public var query: [(key: String, value: String)]

    public init(headers: [String: String], query: [(key: String, value: String)]) {
        self.headers = headers
        self.query = query
    }

    public static func == (lhs: MCPProbeRenderedInputs, rhs: MCPProbeRenderedInputs) -> Bool {
        lhs.headers == rhs.headers && lhs.query.elementsEqual(rhs.query, by: { $0.key == $1.key && $0.value == $1.value })
    }
}

/// Probes upstream MCP servers: discovery, then the wire-shape gate,
/// then the auth-kind fork. Ports `probeEndpoint` (`plugin.ts`) with
/// every integration point behind a seam.
public struct MCPUpstreamProber: Sendable {
    public var exchange: MCPProbeHTTPExchange
    public var discovery: MCPProbeDiscovery
    public var oauth: MCPProbeOAuth
    public var secrets: MCPProbeSecretResolver

    public init(
        exchange: MCPProbeHTTPExchange,
        discovery: MCPProbeDiscovery,
        oauth: MCPProbeOAuth,
        secrets: MCPProbeSecretResolver
    ) {
        self.exchange = exchange
        self.discovery = discovery
        self.oauth = oauth
        self.secrets = secrets
    }

    /// Unauthenticated JSON-RPC `initialize` POST body (Executor
    /// `INITIALIZE_BODY`; the client name reads `rv-probe`).
    public static let initializeBody =
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"rv-probe","version":"0"}}}"#
    /// Modern `server/discover` POST body (Executor `DISCOVER_BODY`).
    public static let discoverBody =
        #"{"jsonrpc":"2.0","id":2,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}"#

    /// Probes one remote endpoint. Ports `probeEndpoint` exactly: trim,
    /// reject the empty paste, reject the undialable paste, resolve
    /// declared secrets, try discovery, then the shape gate, then the
    /// OAuth fork.
    public func probeRemote(
        endpoint: String,
        headers: [String: MCPHeaderValue],
        queryParams: [String: MCPHeaderValue],
        auth: MCPAuthConfig,
        options: MCPProbeOptions
    ) async -> Result<MCPProbeResult, MCPProbeError> {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return .failure(.missingEndpoint)
        }
        guard Self.validProbePaste(trimmed) else {
            return .failure(.endpointFailed(message: MCPProbeMessages.unreachable))
        }
        guard Self.probeableEndpoint(trimmed) else {
            return .failure(.endpointFailed(message: MCPProbeMessages.unreachable))
        }
        let name = Self.displayName(endpoint: trimmed)
        let slug = MCPIntegrationStore.deriveNamespace(name: "", endpoint: trimmed, command: nil)
        let inputs: MCPProbeRenderedInputs
        switch await renderProbeInputs(headers: headers, queryParams: queryParams, auth: auth) {
        case .success(let rendered):
            inputs = rendered
        case .failure(let error):
            return .failure(error)
        }
        if let manifest = try? await discovery.run(trimmed, inputs) {
            return .success(connectedResult(hostName: name, slug: slug, manifest: manifest))
        }
        switch await shapeProbe(endpoint: trimmed, headers: inputs.headers, query: inputs.query, options: options) {
        case .unreachable:
            return .failure(.endpointFailed(message: MCPProbeMessages.unreachable))
        case .notMCP(let category, _):
            if category == .wrongShape {
                return .failure(.endpointFailed(message: MCPProbeMessages.notMCP))
            }
            return .success(manualAuthResult(name: name, slug: slug))
        case .mcp(let requiresAuth):
            if let signal = try? await oauth.run(trimmed) {
                return .success(oauthResult(name: name, slug: slug, signal: signal))
            }
            if requiresAuth {
                return .success(manualAuthResult(name: name, slug: slug))
            }
            return .failure(.undiscoverable(message: MCPProbeMessages.undiscoverable))
        }
    }

    /// Probes one stdio server through a spawn seam. A manifest means
    /// the handshake discovered tools; nil means the spawn surface
    /// checks out but tools are undiscovered; a throw means the
    /// command failed to start.
    public func probeStdio(
        server: MCPUpstreamStdioServer,
        hostEnvironment: [String: String],
        spawn: MCPProbeStdioSpawn
    ) async -> Result<MCPProbeResult, MCPProbeError> {
        let spec = server.spawnSpec(hostEnvironment: hostEnvironment)
        let manifest: MCPDiscoveredManifest?
        do {
            manifest = try await spawn.run(spec)
        } catch {
            return .failure(.stdioStartFailed(message: MCPProbeMessages.stdioStartFailure))
        }
        let name = Self.displayStdioName(manifestName: manifest?.serverName, configName: server.config.name)
        return .success(MCPProbeResult(
            connected: true,
            requiresAuthentication: false,
            requiresOAuth: false,
            supportsDynamicRegistration: false,
            name: name,
            slug: server.namespace,
            toolCount: manifest?.toolCount,
            serverName: manifest?.serverName,
            instructions: manifest?.instructions
        ))
    }

    // MARK: Shape flow

    /// The `initialize` POST, the legacy SSE GET retry on
    /// 404/405/406/415, and the modern `server/discover` fallback on a
    /// wrong-shape verdict. A transport failure on the secondary
    /// `server/discover` request keeps the initialize verdict.
    func shapeProbe(
        endpoint: String,
        headers: [String: String],
        query: [(key: String, value: String)],
        options: MCPProbeOptions
    ) async -> MCPProbeVerdict {
        guard let url = Self.probeURL(endpoint: endpoint, query: query) else {
            return .unreachable(reason: "malformed-endpoint")
        }
        let postResponse: MCPProbeHTTPResponse
        do {
            postResponse = try await exchange.send(MCPProbeHTTPRequest(
                method: .post, url: url,
                headers: Self.postHeaders(configured: headers),
                body: Self.initializeBody, timeoutMs: options.timeoutMs
            ))
        } catch {
            return .unreachable(reason: Self.seamReason(error))
        }
        var verdict = await MCPProbeClassifier.classify(response: postResponse, method: .post) {
            await self.protectedResourceMatch(endpoint: endpoint, headers: headers, options: options)
        }
        if verdict == nil, [404, 405, 406, 415].contains(postResponse.status) {
            do {
                let getResponse = try await exchange.send(MCPProbeHTTPRequest(
                    method: .get, url: url,
                    headers: Self.getHeaders(configured: headers),
                    body: "", timeoutMs: options.timeoutMs
                ))
                verdict = await MCPProbeClassifier.classify(response: getResponse, method: .get) {
                    await self.protectedResourceMatch(endpoint: endpoint, headers: headers, options: options)
                }
            } catch {
                return .unreachable(reason: Self.seamReason(error))
            }
        }
        let initialize = verdict
            ?? .notMCP(category: .wrongShape, reason: "unexpected status \(postResponse.status) for initialize")
        guard case .notMCP(let category, _) = initialize, category == .wrongShape else {
            return initialize
        }
        guard let discoverResponse = try? await exchange.send(MCPProbeHTTPRequest(
            method: .post, url: url,
            headers: Self.discoverHeaders(configured: headers),
            body: Self.discoverBody, timeoutMs: options.timeoutMs
        )) else {
            return initialize
        }
        let discovered = await MCPProbeClassifier.classify(response: discoverResponse, method: .post) {
            await self.protectedResourceMatch(endpoint: endpoint, headers: headers, options: options)
        }
        return discovered ?? initialize
    }

    /// RFC 9728 fallback: a protected-resource document at the
    /// path-scoped well-known URL whose `resource` matches this
    /// endpoint upgrades a spec-non-compliant challenge to MCP.
    func protectedResourceMatch(
        endpoint: String,
        headers: [String: String],
        options: MCPProbeOptions
    ) async -> Bool {
        guard let metadataURL = Self.protectedResourceMetadataURL(endpoint: endpoint) else {
            return false
        }
        let request = MCPProbeHTTPRequest(
            method: .get, url: metadataURL,
            headers: ["accept": "application/json", "user-agent": Self.userAgent(configured: headers)],
            body: "", timeoutMs: options.timeoutMs
        )
        guard let response = try? await exchange.send(request) else {
            return false
        }
        guard response.status >= 200, response.status < 300 else {
            return false
        }
        guard let metadata = Self.decodeProtectedResourceMetadata(response.body) else {
            return false
        }
        guard metadata.authorizationServers.isEmpty == false else {
            return false
        }
        return Self.resourceMatchesEndpoint(resource: metadata.resource, endpoint: endpoint)
    }

    // MARK: Input rendering

    /// Renders declared headers, query params, and the auth
    /// declaration. Literals stay verbatim; secrets resolve through
    /// the broker seam; the first unresolvable ref (in sorted-key
    /// order) fails the probe with its label. The auth header
    /// replaces any declared header of the same name (matched
    /// case-insensitively, so no shadowed twin travels beside it).
    /// `.oauth2` renders nothing: the connection authenticates at
    /// connect time, not at probe time.
    func renderProbeInputs(
        headers: [String: MCPHeaderValue],
        queryParams: [String: MCPHeaderValue],
        auth: MCPAuthConfig
    ) async -> Result<MCPProbeRenderedInputs, MCPProbeError> {
        var renderedHeaders: [String: String] = [:]
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
            guard let rendered = await renderHeaderValue(value) else {
                return .failure(.unresolvedSecret(label: key))
            }
            renderedHeaders[key] = rendered
        }
        switch auth {
        case .none, .oauth2:
            break
        case .header(let headerName, let secret, let prefix):
            guard let resolved = await secrets.resolve(secret) else {
                return .failure(.unresolvedSecret(label: "auth"))
            }
            for key in renderedHeaders.keys where key.lowercased() == headerName.lowercased() {
                renderedHeaders.removeValue(forKey: key)
            }
            renderedHeaders[headerName] = (prefix ?? "") + resolved
        }
        var renderedQuery: [(key: String, value: String)] = []
        for (key, value) in queryParams.sorted(by: { $0.key < $1.key }) {
            guard let rendered = await renderHeaderValue(value) else {
                return .failure(.unresolvedSecret(label: key))
            }
            renderedQuery.append((key: key, value: rendered))
        }
        return .success(MCPProbeRenderedInputs(headers: renderedHeaders, query: renderedQuery))
    }

    func renderHeaderValue(_ value: MCPHeaderValue) async -> String? {
        switch value {
        case .literal(let text):
            return text
        case .secret(let selector, let prefix):
            guard let resolved = await secrets.resolve(selector) else {
                return nil
            }
            return (prefix ?? "") + resolved
        }
    }

    // MARK: Results

    func connectedResult(hostName: String, slug: String, manifest: MCPDiscoveredManifest) -> MCPProbeResult {
        MCPProbeResult(
            connected: true,
            requiresAuthentication: false,
            requiresOAuth: false,
            supportsDynamicRegistration: false,
            name: Self.connectedName(manifestName: manifest.serverName, hostName: hostName),
            slug: slug,
            toolCount: manifest.toolCount,
            serverName: manifest.serverName,
            instructions: manifest.instructions
        )
    }

    func manualAuthResult(name: String, slug: String) -> MCPProbeResult {
        MCPProbeResult(
            connected: false,
            requiresAuthentication: true,
            requiresOAuth: false,
            supportsDynamicRegistration: false,
            name: name,
            slug: slug,
            toolCount: nil,
            serverName: nil,
            instructions: nil
        )
    }

    func oauthResult(name: String, slug: String, signal: MCPProbeOAuthSignal) -> MCPProbeResult {
        MCPProbeResult(
            connected: false,
            requiresAuthentication: true,
            requiresOAuth: true,
            supportsDynamicRegistration: signal.supportsDynamicRegistration,
            name: name,
            slug: slug,
            toolCount: nil,
            serverName: nil,
            instructions: nil
        )
    }
}

// MARK: - Prober wire details

extension MCPUpstreamProber {
    /// POST headers: JSON content/accept defaults under the configured
    /// headers (Executor applies configured headers after its own, so
    /// configured wins), plus the default-or-configured User-Agent.
    static func postHeaders(configured: [String: String]) -> [String: String] {
        merging(
            configured: configured,
            over: [
                "content-type": "application/json",
                "accept": "application/json, text/event-stream",
                "user-agent": userAgent(configured: configured),
            ]
        )
    }

    /// Legacy SSE GET headers: event-stream accept under configured.
    static func getHeaders(configured: [String: String]) -> [String: String] {
        merging(
            configured: configured,
            over: [
                "accept": "text/event-stream",
                "user-agent": userAgent(configured: configured),
            ]
        )
    }

    /// `server/discover` headers: POST headers plus the pinned
    /// protocol version, which Executor sets after configured
    /// headers, so it always wins.
    static func discoverHeaders(configured: [String: String]) -> [String: String] {
        var headers = postHeaders(configured: configured)
        for key in headers.keys where key.lowercased() == "mcp-protocol-version" {
            headers.removeValue(forKey: key)
        }
        headers["MCP-Protocol-Version"] = "2026-07-28"
        return headers
    }

    /// Case-insensitive override merge: a configured key replaces the
    /// default of any casing, so no shadowed twin travels beside it.
    static func merging(configured: [String: String], over defaults: [String: String]) -> [String: String] {
        var merged = defaults
        let configuredNames = Set(configured.keys.map { $0.lowercased() })
        for key in merged.keys where configuredNames.contains(key.lowercased()) {
            merged.removeValue(forKey: key)
        }
        for (name, value) in configured {
            merged[name] = value
        }
        return merged
    }

    /// The configured User-Agent wins (matched case-insensitively);
    /// otherwise the shared RV default, so upstreams that 403
    /// headerless clients still answer.
    static func userAgent(configured: [String: String]) -> String {
        if let existing = MCPProbeClassifier.header(configured, name: "user-agent") {
            return existing
        }
        return HTTPEgressLimits.userAgent
    }

    /// Dialable probe targets: absolute http(s) URLs with a host.
    /// Anything else — `file://`, `ftp://`, schemeless pastes, bare
    /// hosts — fails closed before any seam runs. Remote MCP is
    /// http(s) by transport definition, and handing a `file://` URL
    /// to a URLSession-backed seam would turn the probe into a local
    /// file-read oracle. Internal hosts, odd ports, and userinfo all
    /// pass: loopback and intranet MCP servers are legitimate probe
    /// targets, and a pasted userinfo is the operator's own credential
    /// for the probe to use.
    static func probeableEndpoint(_ endpoint: String) -> Bool {
        guard let components = URLComponents(string: endpoint),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = components.host, host.isEmpty == false
        else {
            return false
        }
        return true
    }

    /// The probe URL: the endpoint plus the rendered query pairs,
    /// percent-encoded. Nil when the endpoint is not a dialable
    /// http(s) URL. Non-colliding pasted pairs ride byte-identical;
    /// a pasted pair whose key collides with a rendered key is
    /// dropped so the rendered value wins outright (Executor
    /// `searchParams.set` parity: appending instead would emit
    /// duplicate keys and leave the winner to the server's
    /// first-or-last whim). Rendered pairs are strictly escaped, so
    /// a `+` in a secret cannot ride literally and decode as a
    /// space at the server.
    static func probeURL(endpoint: String, query: [(key: String, value: String)]) -> String? {
        guard var components = URLComponents(string: endpoint),
            probeableEndpoint(endpoint)
        else {
            return nil
        }
        if query.isEmpty == false {
            let encoded = query.map { "\(queryEscaped($0.key))=\(queryEscaped($0.value))" }
                .joined(separator: "&")
            if let existing = components.percentEncodedQuery, existing.isEmpty == false {
                let kept = stripCollidingQueryPairs(existing, renderedKeys: Set(query.map { $0.key }))
                components.percentEncodedQuery = kept.isEmpty ? encoded : kept + "&" + encoded
            } else {
                components.percentEncodedQuery = encoded
            }
        }
        return components.string
    }

    /// Drops pasted pairs whose decoded key collides with a rendered
    /// key, keeping the rest byte-identical (order included). Keys
    /// compare form-decoded (a literal `+` is a space, then `%XX`
    /// unescapes — Executor `searchParams` parity, so a pasted
    /// `a+b` never evicts a rendered `a+b` whose plus is literal);
    /// a pair whose key cannot decode is kept — a collision that
    /// cannot be proven is not acted on.
    static func stripCollidingQueryPairs(_ encodedQuery: String, renderedKeys: Set<String>) -> String {
        encodedQuery.split(separator: "&", omittingEmptySubsequences: false)
            .filter { pair in
                let rawKey = pair.prefix(while: { $0 != "=" })
                guard let decoded = String(rawKey).replacingOccurrences(of: "+", with: " ").removingPercentEncoding
                else {
                    return true
                }
                return renderedKeys.contains(decoded) == false
            }
            .joined(separator: "&")
    }

    /// Strict query-pair escaping: unreserved bytes ride literally,
    /// everything else percent-encodes. Total (never nil), unlike
    /// `URLQueryItem`, which leaves `+` and `?` literal — a literal
    /// `+` in a base64-ish secret decodes as a space at any
    /// form-decoding server, silently corrupting the credential.
    static func queryEscaped(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            if isQueryUnreservedByte(byte) {
                out.append(Character(UnicodeScalar(byte)))
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    /// RFC 3986 unreserved bytes: letters, digits, `- _ . ~`.
    static func isQueryUnreservedByte(_ byte: UInt8) -> Bool {
        (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57)
            || byte == 45 || byte == 95 || byte == 46 || byte == 126
    }

    /// RFC 9728 §3.1 path-scoped well-known URL:
    /// `https://host/api/mcp` →
    /// `https://host/.well-known/oauth-protected-resource/api/mcp`.
    /// Built textually (never carrying userinfo or the pasted query),
    /// so there is no Optional left to force open. The path rides
    /// percent-encoded (the decoded form would smuggle raw spaces
    /// and separators into the URL) and the scheme lowercased, like
    /// WHATWG `origin`. Nil unless the endpoint is a dialable
    /// http(s) URL, like the probe itself.
    static func protectedResourceMetadataURL(endpoint: String) -> String? {
        guard let components = URLComponents(string: endpoint),
            probeableEndpoint(endpoint),
            let scheme = components.scheme, let host = components.host,
            host.isEmpty == false
        else {
            return nil
        }
        let rawPath = components.percentEncodedPath
        let path = rawPath == "/" ? "" : rawPath
        let authority = MCPUpstreamEndpointTelemetry.authorityOf(host: host, port: components.port)
        return "\(scheme.lowercased())://\(authority)/.well-known/oauth-protected-resource\(path)"
    }

    /// The RFC 9728 `resource` must describe this endpoint: same
    /// origin, and an exact path match or a same-origin parent
    /// prefix. Paths compare percent-encoded (WHATWG `pathname`
    /// parity): comparing decoded would conflate an encoded `%2F`
    /// with a real segment separator and match unrelated resources.
    static func resourceMatchesEndpoint(resource: String, endpoint: String) -> Bool {
        guard let wanted = originParts(resource), let actual = originParts(endpoint) else {
            return false
        }
        guard wanted.scheme == actual.scheme, wanted.host == actual.host, wanted.port == actual.port else {
            return false
        }
        let resourcePath = trimmedPath(normalizedEncodedPath(wanted.path))
        let endpointPath = trimmedPath(normalizedEncodedPath(actual.path))
        return endpointPath == resourcePath || endpointPath.hasPrefix(resourcePath + "/")
    }

    /// Origin parts with defaulted ports, so `https://host` matches
    /// `https://host:443`. The path is percent-encoded, never
    /// decoded (see `resourceMatchesEndpoint`).
    static func originParts(_ value: String) -> MCPProbeOriginParts? {
        guard let components = URLComponents(string: value),
            let scheme = components.scheme?.lowercased(), let host = components.host?.lowercased(),
            host.isEmpty == false
        else {
            return nil
        }
        return MCPProbeOriginParts(
            scheme: scheme, host: host,
            port: components.port ?? defaultPort(scheme: scheme),
            path: components.percentEncodedPath
        )
    }

    /// Uppercases `%XX` escapes so equivalent encodings compare
    /// equal (WHATWG `pathname` normalizes hex to uppercase, while
    /// `percentEncodedPath` preserves the author's casing).
    /// Malformed `%` sequences ride through untouched: they can
    /// only fail the match, never force one.
    static func normalizedEncodedPath(_ path: String) -> String {
        var out = ""
        out.reserveCapacity(path.utf8.count)
        var rest = Substring(path)
        while let head = rest.first {
            if head == "%", rest.count >= 3 {
                let hex = rest.dropFirst().prefix(2)
                if hex.allSatisfy({ $0.isHexDigit }) {
                    out += "%" + hex.uppercased()
                    rest = rest.dropFirst(3)
                    continue
                }
            }
            out.append(head)
            rest = rest.dropFirst()
        }
        return out
    }

    static func defaultPort(scheme: String) -> Int? {
        switch scheme {
        case "http":
            return 80
        case "https":
            return 443
        default:
            return nil
        }
    }

    /// Trailing slashes trimmed (Executor `replace(/\/+$/, "")`).
    static func trimmedPath(_ path: String) -> String {
        var trimmed = path
        while trimmed.hasSuffix("/"), trimmed.isEmpty == false {
            trimmed.removeLast()
        }
        return trimmed
    }

    /// Decodes the two fields that prove a protected-resource
    /// document: `resource` plus a (possibly empty — the caller
    /// requires non-empty) `authorization_servers` list.
    static func decodeProtectedResourceMetadata(_ body: String) -> MCPProtectedResourceMetadata? {
        guard body.isEmpty == false,
            let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
            let resource = json["resource"] as? String,
            let servers = json["authorization_servers"] as? [String]
        else {
            return nil
        }
        return MCPProtectedResourceMetadata(resource: resource, authorizationServers: servers)
    }

    /// Pasted endpoint gate: byte-capped, OperatorText-clean. Surviving
    /// this gate does not mean parseable — the URL parse still decides.
    static func validProbePaste(_ value: String) -> Bool {
        value.utf8.count <= 2_048 && OperatorText.containsDisallowedTextScalar(value) == false
    }

    /// A hostname (or server name) safe to show the operator:
    /// non-empty, capped, OperatorText-clean.
    static func validProbeHost(_ value: String) -> Bool {
        value.isEmpty == false && value.utf8.count <= 256
            && OperatorText.containsDisallowedTextScalar(value) == false
    }

    /// Probe display name: the endpoint hostname, lowercased like
    /// WHATWG `hostname`, else "mcp" (Executor `probeEndpoint`).
    static func displayName(endpoint: String) -> String {
        guard let host = URLComponents(string: endpoint)?.host?.lowercased(), validProbeHost(host) else {
            return "mcp"
        }
        return host
    }

    /// Discovery names are external input: a clean manifest name wins,
    /// else the (already gated) hostname.
    static func connectedName(manifestName: String?, hostName: String) -> String {
        guard let manifestName, validProbeHost(manifestName) else {
            return hostName
        }
        return manifestName
    }

    /// Stdio display name: a clean manifest name wins, else a clean
    /// config name, else "mcp".
    static func displayStdioName(manifestName: String?, configName: String) -> String {
        if let manifestName, validProbeHost(manifestName) {
            return manifestName
        }
        if validProbeHost(configName) {
            return configName
        }
        return "mcp"
    }

    /// Seam throws collapse to fixed labels: timeouts stay
    /// distinguishable, everything else is one transport failure.
    /// Unknown error types (never the seam's own vocabulary) share it.
    static func seamReason(_ error: Error) -> String {
        guard let seam = error as? MCPProbeSeamError else {
            return "transport-failure"
        }
        switch seam {
        case .timeout:
            return "timeout"
        case .connectionFailed:
            return "connection-failed"
        }
    }
}

/// Origin parts for the RFC 9728 resource match.
public struct MCPProbeOriginParts: Sendable, Equatable {
    public var scheme: String
    public var host: String
    public var port: Int?
    public var path: String

    public init(scheme: String, host: String, port: Int?, path: String) {
        self.scheme = scheme
        self.host = host
        self.port = port
        self.path = path
    }
}

/// The two RFC 9728 fields the metadata fallback trusts.
public struct MCPProtectedResourceMetadata: Sendable, Equatable {
    public var resource: String
    public var authorizationServers: [String]

    public init(resource: String, authorizationServers: [String]) {
        self.resource = resource
        self.authorizationServers = authorizationServers
    }
}

// MARK: - Stdio spawn spec

/// Exact child spec for one stdio server spawn.
///
/// Spawn contract (X1-J1 amendment): `arguments` are `exec` argv
/// elements — never joined into a shell string — `workingDirectory`
/// is a `chdir` target, and `environment` values are opaque literals
/// passed byte-identical (an embedded non-prefix `secret-public-ref:`
/// marker is literal text; the store already rejects leading-prefix
/// markers in stdio env).
public struct MCPUpstreamSpawnSpec: Sendable, Equatable {
    public var executablePath: String
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String?

    public init(executablePath: String, arguments: [String], environment: [String: String], workingDirectory: String?) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }

    /// Host variables a stdio server inherits (Executor
    /// `inheritedEnvKeys`, `stdio-connector.ts`): proxy and CA
    /// configuration only — none carries a credential. Deliberately
    /// closed: anything else the server needs comes from declared env.
    public static let inheritedEnvironmentKeys = [
        "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY",
        "http_proxy", "https_proxy", "no_proxy",
        "NODE_EXTRA_CA_CERTS", "SSL_CERT_FILE", "SSL_CERT_DIR",
    ]

    /// The exact child environment: the withheld-by-default safe-list
    /// underneath the inherited infrastructure allowlist underneath
    /// the declared env, which wins every collision (Executor
    /// `stdioSpawnEnv` / `mergeStdioEnv` on a case-sensitive
    /// platform; RV targets are case-sensitive, so the win32
    /// case-folding arm has no counterpart). Set-but-empty host
    /// values are not inherited (Executor `inheritedEnv` drops
    /// falsy for the same reason: an empty `NO_PROXY` must not
    /// shadow the child's own default).
    public static func mergedEnvironment(
        host: [String: String],
        declared: [String: String]?
    ) -> [String: String] {
        var merged = MCPStdioProcessSpawn.minimalEnvironment
        for key in inheritedEnvironmentKeys {
            if let value = host[key], value.isEmpty == false {
                merged[key] = value
            }
        }
        guard let declared else {
            return merged
        }
        for (key, value) in declared {
            merged[key] = value
        }
        return merged
    }

    /// The executable names an existing, non-directory, executable file.
    public func executableUsable() -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: executablePath, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue == false
            && FileManager.default.isExecutableFile(atPath: executablePath)
    }

    /// An absent working directory is fine (the child inherits the
    /// daemon's); a present one must name an existing directory.
    public func workingDirectoryUsable() -> Bool {
        guard let workingDirectory else {
            return true
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
    }
}

/// Stdio spawn seam for the probe. A manifest means the handshake
/// discovered tools; nil means the spawn surface checks out but tools
/// are undiscovered; a throw means the command failed to start.
public struct MCPProbeStdioSpawn: Sendable {
    public var run: @Sendable (MCPUpstreamSpawnSpec) async throws -> MCPDiscoveredManifest?

    public init(run: @escaping @Sendable (MCPUpstreamSpawnSpec) async throws -> MCPDiscoveredManifest?) {
        self.run = run
    }

    /// Static spawn-surface check: the executable must be usable and
    /// the working directory (when set) must exist. Tools stay
    /// undiscovered until the handshake seam lands.
    public static var executableCheck: MCPProbeStdioSpawn {
        MCPProbeStdioSpawn(run: { spec in
            guard spec.executableUsable(), spec.workingDirectoryUsable() else {
                throw MCPProbeSeamError.connectionFailed
            }
            return nil
        })
    }
}

// MARK: - Upstream servers

/// One registered remote server: an X1-I config plus its resolved namespace.
public struct MCPUpstreamRemoteServer: Sendable, Equatable {
    public var config: MCPRemoteIntegration

    public init(config: MCPRemoteIntegration) {
        self.config = config
    }

    /// Explicit namespace, else the derived one.
    public var namespace: String {
        config.resolvedNamespace
    }

    /// Transports to try, in order, from the stored preference.
    public var transportCandidates: [MCPUpstreamTransport] {
        MCPUpstreamTransportSelection.candidates(for: config.remoteTransport)
    }

    /// The canonical address for one tool on this server, or nil when
    /// the namespace cannot be embedded in a `tools.…` literal.
    public func toolAddress(owner: String, connection: String, tool: String) -> MCPToolAddress? {
        MCPUpstreamToolLiteral.address(
            namespace: namespace, owner: owner, connection: connection, tool: tool
        )
    }
}

/// One registered stdio server: an X1-I config plus its resolved namespace.
public struct MCPUpstreamStdioServer: Sendable, Equatable {
    public var config: MCPStdioIntegration

    public init(config: MCPStdioIntegration) {
        self.config = config
    }

    /// Explicit namespace, else the derived one.
    public var namespace: String {
        config.resolvedNamespace
    }

    /// Stdio servers speak exactly one transport.
    public var transportCandidates: [MCPUpstreamTransport] {
        [.stdio]
    }

    /// The exact child spec: argv elements (never a shell string), the
    /// chdir target, and the merged opaque-literal environment.
    public func spawnSpec(hostEnvironment: [String: String]) -> MCPUpstreamSpawnSpec {
        MCPUpstreamSpawnSpec(
            executablePath: config.command,
            arguments: config.args ?? [],
            environment: MCPUpstreamSpawnSpec.mergedEnvironment(host: hostEnvironment, declared: config.env),
            workingDirectory: config.cwd
        )
    }

    /// The canonical address for one tool on this server, or nil when
    /// the namespace cannot be embedded in a `tools.…` literal.
    public func toolAddress(owner: String, connection: String, tool: String) -> MCPToolAddress? {
        MCPUpstreamToolLiteral.address(
            namespace: namespace, owner: owner, connection: connection, tool: tool
        )
    }
}

/// One registered upstream server, remote or stdio.
public enum MCPUpstreamServer: Sendable, Equatable {
    case remote(MCPUpstreamRemoteServer)
    case stdio(MCPUpstreamStdioServer)

    /// Registers an X1-I config: remote streamable-http/sse/auto plus
    /// stdio command (Executor `McpServerInput` arms, `plugin.ts`).
    public init(_ config: MCPIntegrationConfig) {
        switch config {
        case .remote(let remote):
            self = .remote(MCPUpstreamRemoteServer(config: remote))
        case .stdio(let stdio):
            self = .stdio(MCPUpstreamStdioServer(config: stdio))
        }
    }

    public var config: MCPIntegrationConfig {
        switch self {
        case .remote(let server):
            return .remote(server.config)
        case .stdio(let server):
            return .stdio(server.config)
        }
    }

    public var namespace: String {
        switch self {
        case .remote(let server):
            return server.namespace
        case .stdio(let server):
            return server.namespace
        }
    }

    public var transportCandidates: [MCPUpstreamTransport] {
        switch self {
        case .remote(let server):
            return server.transportCandidates
        case .stdio(let server):
            return server.transportCandidates
        }
    }

    public func toolAddress(owner: String, connection: String, tool: String) -> MCPToolAddress? {
        switch self {
        case .remote(let server):
            return server.toolAddress(owner: owner, connection: connection, tool: tool)
        case .stdio(let server):
            return server.toolAddress(owner: owner, connection: connection, tool: tool)
        }
    }
}

// MARK: - Dotted-namespace renderer watch

/// Guards `tools.…` literal rendering against dotted namespaces.
///
/// Explicit namespaces may contain dots (file-identity keys; the join
/// is enforced at registration, not at load). But a dotted namespace
/// embedded in a `tools.<integration>.…` literal would re-split on
/// parse and address the wrong tool — the canonical parser gives
/// trailing dot-separated parts to `tool`, silently shifting every
/// segment. So rendering refuses: `address` returns nil for dotted
/// (or otherwise unrenderable) namespaces, and the registry's
/// `unrenderableNamespaces` lists every server the watch catches.
/// Never interpolate a namespace into a literal without this gate.
public enum MCPUpstreamToolLiteral: Sendable {
    /// True when the namespace can be embedded: non-empty, at most
    /// 128 chars, dot-free, and without whitespace, controls, or
    /// invisible format characters (mirrors the `MCPToolAddress`
    /// integration-segment rule).
    public static func renderable(namespace: String) -> Bool {
        guard namespace.isEmpty == false, namespace.count <= 128, namespace.contains(".") == false else {
            return false
        }
        return namespace.contains(where: { $0.isWhitespace || $0.isNewline }) == false
            && namespace.unicodeScalars.contains(where: { isDisallowedAddressScalar($0.value) }) == false
            && namespace.unicodeScalars.contains(where: { $0.properties.generalCategory == .format }) == false
    }

    static func isDisallowedAddressScalar(_ code: UInt32) -> Bool {
        code < 0x20 || (0x7F...0x9F).contains(code)
    }

    /// The canonical address, or nil when the namespace (or any other
    /// segment) cannot be embedded.
    public static func address(
        namespace: String,
        owner: String,
        connection: String,
        tool: String
    ) -> MCPToolAddress? {
        guard renderable(namespace: namespace) else {
            return nil
        }
        return try? MCPToolAddress(integration: namespace, owner: owner, connection: connection, tool: tool)
    }
}

// MARK: - Registry

/// Registration failures. Namespaces are operator labels, never secrets.
public enum MCPUpstreamRegistryError: Error, Sendable, Equatable {
    /// The namespace is already registered (Executor
    /// `IntegrationAlreadyExistsError`: an explicit add never silently
    /// clobbers).
    case duplicateNamespace(String)
    /// No server holds this namespace.
    case unknownNamespace(String)
    /// The config behind this namespace changed since registration:
    /// the caller holds a stale handle and must re-resolve.
    case configDrift(namespace: String)
}

/// Registered upstream servers, keyed by resolved namespace.
public actor MCPUpstreamRegistry {
    private var servers: [String: MCPUpstreamServer] = [:]

    public init() {}

    /// Registers a validated set atomically: any duplicate rejects the
    /// whole set and registers nothing.
    public init(registering set: MCPIntegrationSet) throws(MCPUpstreamRegistryError) {
        self.servers = Dictionary(
            uniqueKeysWithValues: try Self.staged(set, against: [:])
        )
    }

    /// Registers one config. A taken namespace (explicit or derived)
    /// fails; nothing is clobbered.
    public func register(_ config: MCPIntegrationConfig) throws(MCPUpstreamRegistryError) {
        let namespace = config.resolvedNamespace
        guard servers[namespace] == nil else {
            throw MCPUpstreamRegistryError.duplicateNamespace(namespace)
        }
        servers[namespace] = MCPUpstreamServer(config)
    }

    /// Registers a set atomically: any duplicate (against the
    /// registry or within the set) rejects the whole set.
    public func registerAll(_ set: MCPIntegrationSet) throws(MCPUpstreamRegistryError) {
        let staged = try Self.staged(set, against: servers)
        for (namespace, server) in staged {
            servers[namespace] = server
        }
    }

    /// Stages a set against existing servers without committing: the
    /// shared atomic core behind `init(registering:)` and
    /// `registerAll`. Any duplicate throws before anything commits.
    static func staged(
        _ set: MCPIntegrationSet,
        against existing: [String: MCPUpstreamServer]
    ) throws(MCPUpstreamRegistryError) -> [(String, MCPUpstreamServer)] {
        var staged: [(String, MCPUpstreamServer)] = []
        var seen = Set<String>()
        for config in set.integrations {
            let namespace = config.resolvedNamespace
            guard existing[namespace] == nil, seen.insert(namespace).inserted else {
                throw MCPUpstreamRegistryError.duplicateNamespace(namespace)
            }
            staged.append((namespace, MCPUpstreamServer(config)))
        }
        return staged
    }

    /// The server behind this namespace, or nil.
    public func server(namespace: String) -> MCPUpstreamServer? {
        servers[namespace]
    }

    /// The server behind this config's namespace, rejecting drift: a
    /// config that differs from the registered one fails instead of
    /// silently addressing the wrong server.
    public func server(for config: MCPIntegrationConfig) throws(MCPUpstreamRegistryError) -> MCPUpstreamServer {
        let namespace = config.resolvedNamespace
        guard let stored = servers[namespace] else {
            throw MCPUpstreamRegistryError.unknownNamespace(namespace)
        }
        guard stored.config == config else {
            throw MCPUpstreamRegistryError.configDrift(namespace: namespace)
        }
        return stored
    }

    /// Registered namespaces, sorted.
    public func namespaces() -> [String] {
        servers.keys.sorted()
    }

    /// The renderer watch: namespaces that cannot be embedded in a
    /// `tools.…` literal, sorted. Non-empty means those servers'
    /// tools are unreachable by literal until renamed.
    public func unrenderableNamespaces() -> [String] {
        servers.keys.filter { MCPUpstreamToolLiteral.renderable(namespace: $0) == false }.sorted()
    }

    /// Per-integration probe errors for raw document bytes, via the
    /// store's `validate(_:)` diagnostics. Empty means the document
    /// loads cleanly.
    public static func probeDiagnostics(_ data: Data) -> [MCPUpstreamProbeDiagnostic] {
        MCPIntegrationStore.validate(data).map { problem in
            MCPUpstreamProbeDiagnostic(
                index: problem.index,
                reason: problem.reason,
                message: diagnosticMessage(index: problem.index, reason: problem.reason)
            )
        }
    }

    static func diagnosticMessage(index: Int, reason: String) -> String {
        if index == -1 {
            return documentMessage(reason: reason)
        }
        return "Integration \(index) has an invalid \(reason)."
    }

    static func documentMessage(reason: String) -> String {
        switch reason {
        case "oversized":
            return "The integrations document exceeds the size limit."
        case "unsupportedVersion":
            return "The integrations document version is not supported."
        case "tooManyIntegrations":
            return "The integrations document holds too many integrations."
        default:
            return "The integrations document is invalid."
        }
    }
}

/// One per-integration probe error: the document index, the failing
/// field label (never the value), and the fixed operator message.
public struct MCPUpstreamProbeDiagnostic: Sendable, Equatable {
    public var index: Int
    public var reason: String
    public var message: String

    public init(index: Int, reason: String, message: String) {
        self.index = index
        self.reason = reason
        self.message = message
    }
}
