import Foundation
import RVDomain
import RVPolicy
import Testing
@testable import RVIsolation

// MARK: - Helpers

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [MCPProbeHTTPRequest] = []

    func record(_ request: MCPProbeHTTPRequest) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(request)
    }

    var requests: [MCPProbeHTTPRequest] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

private struct DummyError: Error {}

private let jsonRPCResult = #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25"}}"#
private let jsonRPCRemoteError = #"{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"nope"}}"#
private let jsonRPCMethod = #"{"jsonrpc":"2.0","method":"ping"}"#
private let oauthErrorBody = #"{"error":"invalid_token","error_description":"expired"}"#
private let graphqlBody = #"{"errors":[{"message":"Unauthorized"}]}"#
private let probeEndpoint = "https://mcp.example.com/api/mcp"

private func probeResponse(status: Int, headers: [String: String], body: String) -> MCPProbeHTTPResponse {
    MCPProbeHTTPResponse(status: status, headers: headers, body: body)
}

private func scriptedExchange(
    log: RequestLog,
    handler: @escaping @Sendable (MCPProbeHTTPRequest) throws -> MCPProbeHTTPResponse
) -> MCPProbeHTTPExchange {
    MCPProbeHTTPExchange(send: { request in
        log.record(request)
        return try handler(request)
    })
}

private func testSelector() -> MCPSecretSelector {
    MCPSecretSelector(provider: "file", item: "github/token", field: nil)
}

private func makeRemote(
    name: String,
    endpoint: String,
    transport: MCPRemoteTransport,
    namespace: String?
) throws -> MCPIntegrationConfig {
    try .remote(MCPRemoteIntegration(
        name: name, endpoint: endpoint, remoteTransport: transport, namespace: namespace
    ))
}

private func makeStdio(
    name: String,
    command: String,
    args: [String]?,
    env: [String: String]?,
    cwd: String?,
    namespace: String?
) throws -> MCPIntegrationConfig {
    try .stdio(MCPStdioIntegration(
        name: name, command: command, args: args, env: env, cwd: cwd, namespace: namespace
    ))
}

private func makeProber(
    exchange: MCPProbeHTTPExchange,
    discovery: MCPProbeDiscovery,
    oauth: MCPProbeOAuth,
    secrets: MCPProbeSecretResolver
) -> MCPUpstreamProber {
    MCPUpstreamProber(exchange: exchange, discovery: discovery, oauth: oauth, secrets: secrets)
}

private func probeOptions() -> MCPProbeOptions {
    MCPProbeOptions(timeoutMs: 8_000)
}

@Suite("MCPUpstreamRegistry")
struct MCPUpstreamRegistryTests: Sendable {
    // MARK: - Transport selection

    @Test("explicit preferences resolve to one transport; auto tries modern first")
    func transportCandidates() {
        #expect(MCPUpstreamTransportSelection.candidates(for: .streamableHttp) == [.streamableHTTP])
        #expect(MCPUpstreamTransportSelection.candidates(for: .sse) == [.sse])
        #expect(MCPUpstreamTransportSelection.candidates(for: .auto) == [.streamableHTTP, .sse])
    }

    // MARK: - Shape classifier: 2xx

    @Test("2xx POST with a JSON-RPC envelope is unauth-OK MCP")
    func classifyPostJSONRPC() async {
        let verdict = await MCPProbeClassifier.classify(
            response: probeResponse(status: 200, headers: ["content-type": "application/json"], body: jsonRPCResult),
            method: .post,
            protectedResource: { true }
        )
        #expect(verdict == .mcp(requiresAuth: false))
    }

    @Test("2xx POST with an SSE body is MCP without reading the stream")
    func classifyPostSSE() async {
        let verdict = await MCPProbeClassifier.classify(
            response: probeResponse(status: 200, headers: ["content-type": "text/event-stream"], body: "anything"),
            method: .post,
            protectedResource: { false }
        )
        #expect(verdict == .mcp(requiresAuth: false))
    }

    @Test("2xx POST with HTML is wrong-shape")
    func classifyPostHTML() async {
        let verdict = await MCPProbeClassifier.classify(
            response: probeResponse(status: 200, headers: ["content-type": "text/html"], body: "<html></html>"),
            method: .post,
            protectedResource: { false }
        )
        #expect(verdict == .notMCP(category: .wrongShape, reason: "2xx POST body is not a JSON-RPC envelope"))
    }

    @Test("2xx POST with GraphQL-shape JSON is wrong-shape")
    func classifyPostGraphQL() async {
        let verdict = await MCPProbeClassifier.classify(
            response: probeResponse(status: 200, headers: ["content-type": "application/json"], body: graphqlBody),
            method: .post,
            protectedResource: { false }
        )
        #expect(verdict?.isWrongShape == true)
    }

    @Test("201 and 204 ride the same 2xx gate as 200")
    func classifyOther2xx() async {
        for status in [201, 204] {
            let verdict = await MCPProbeClassifier.classify(
                response: probeResponse(status: status, headers: ["content-type": "application/json"], body: jsonRPCResult),
                method: .post,
                protectedResource: { false }
            )
            #expect(verdict == .mcp(requiresAuth: false))
        }
    }

    @Test("legacy GET accepts an SSE stream and rejects anything else")
    func classifyLegacyGET() async {
        let sse = await MCPProbeClassifier.classify(
            response: probeResponse(status: 200, headers: ["content-type": "text/event-stream; charset=utf-8"], body: ""),
            method: .get,
            protectedResource: { false }
        )
        #expect(sse == .mcp(requiresAuth: false))
        let json = await MCPProbeClassifier.classify(
            response: probeResponse(status: 200, headers: ["content-type": "application/json"], body: jsonRPCResult),
            method: .get,
            protectedResource: { false }
        )
        #expect(json == .notMCP(category: .wrongShape, reason: "GET response is not an SSE stream"))
    }

    @Test("non-2xx non-auth statuses fall through to nil")
    func classifyFallthrough() async {
        for status in [0, 199, 300, 302, 400, 404, 405, 406, 415, 500] {
            let verdict = await MCPProbeClassifier.classify(
                response: probeResponse(status: status, headers: [:], body: ""),
                method: .post,
                protectedResource: { true }
            )
            #expect(verdict == nil)
        }
    }

    // MARK: - Shape classifier: auth challenges

    @Test("401 with resource_metadata is MCP+auth without reading the body")
    func classifyResourceMetadata() async {
        var metadataCalls = 0
        let verdict = await MCPProbeClassifier.classify(
            response: probeResponse(
                status: 401,
                headers: ["WWW-Authenticate": #"Bearer resource_metadata="https://h/.well-known/x""#],
                body: "unread garbage {{{"
            ),
            method: .post,
            protectedResource: {
                metadataCalls += 1
                return false
            }
        )
        #expect(verdict == .mcp(requiresAuth: true))
        #expect(metadataCalls == 0)
    }

    @Test("401 with an error auth-param is MCP+auth")
    func classifyErrorParam() async {
        let verdict = await MCPProbeClassifier.classify(
            response: probeResponse(
                status: 401,
                headers: ["www-authenticate": #"Bearer error="invalid_token", error_description="gone""#],
                body: #"{"message":"Unauthorized"}"#
            ),
            method: .post,
            protectedResource: { false }
        )
        #expect(verdict == .mcp(requiresAuth: true))
    }

    @Test("401 with a bare Bearer [REDACTED] a JSON-RPC error body is MCP+auth")
    func classifyBareBearerJSONRPC() async {
        for body in [jsonRPCRemoteError, jsonRPCResult, jsonRPCMethod] {
            let verdict = await MCPProbeClassifier.classify(
                response: probeResponse(status: 401, headers: ["WWW-Authenticate": "Bearer"], body: body),
                method: .post,
                protectedResource: { false }
            )
            #expect(verdict == .mcp(requiresAuth: true))
        }
    }

    @Test("401 with a bare Bearer [REDACTED] OAuth error body is MCP+auth")
    func classifyBareBearerOAuthBody() async {
        let verdict = await MCPProbeClassifier.classify(
            response: probeResponse(status: 401, headers: ["WWW-Authenticate": "Bearer realm=\"mcp\""], body: oauthErrorBody),
            method: .post,
            protectedResource: { false }
        )
        #expect(verdict == .mcp(requiresAuth: true))
    }

    @Test("401 with a bare Bearer challenge and a GraphQL body stays auth-required")
    func classifyBareBearerGraphQL() async {
        let verdict = await MCPProbeClassifier.classify(
            response: probeResponse(status: 401, headers: ["WWW-Authenticate": "Bearer"], body: graphqlBody),
            method: .post,
            protectedResource: { false }
        )
        #expect(verdict?.isAuthRequired == true)
    }

    @Test("401 with a bare Bearer [REDACTED] empty body stays auth-required")
    func classifyBareBearerEmptyBody() async {
        let verdict = await MCPProbeClassifier.classify(
            response: probeResponse(status: 401, headers: ["WWW-Authenticate": "Bearer"], body: ""),
            method: .post,
            protectedResource: { false }
        )
        #expect(verdict == .notMCP(
            category: .authRequired,
            reason: "401 + Bearer [REDACTED] resource_metadata, JSON-RPC body, or OAuth error body"
        ))
    }

    @Test("401 without any challenge consults metadata, then stays auth-required")
    func classifyNoChallenge() async {
        let upgrade = await MCPProbeClassifier.classify(
            response: probeResponse(status: 401, headers: [:], body: graphqlBody),
            method: .post,
            protectedResource: { true }
        )
        #expect(upgrade == .mcp(requiresAuth: true))
        let kept = await MCPProbeClassifier.classify(
            response: probeResponse(status: 401, headers: [:], body: graphqlBody),
            method: .post,
            protectedResource: { false }
        )
        #expect(kept == .notMCP(
            category: .authRequired,
            reason: "401 without Bearer [REDACTED] — not an MCP auth challenge"
        ))
    }

    @Test("401 with a non-Bearer [REDACTED] consults metadata, then stays auth-required")
    func classifyNonBearerChallenge() async {
        let verdict = await MCPProbeClassifier.classify(
            response: probeResponse(status: 401, headers: ["WWW-Authenticate": "Basic realm=\"x\""], body: ""),
            method: .post,
            protectedResource: { false }
        )
        #expect(verdict?.isAuthRequired == true)
    }

    @Test("403 travels the auth path: Bearer [REDACTED] is MCP+auth, HTML is auth-required")
    func classify403() async {
        let mcp = await MCPProbeClassifier.classify(
            response: probeResponse(status: 403, headers: ["WWW-Authenticate": "Bearer"], body: jsonRPCRemoteError),
            method: .post,
            protectedResource: { false }
        )
        #expect(mcp == .mcp(requiresAuth: true))
        let edge = await MCPProbeClassifier.classify(
            response: probeResponse(status: 403, headers: ["content-type": "text/html"], body: "<html>edge</html>"),
            method: .post,
            protectedResource: { false }
        )
        #expect(edge?.isAuthRequired == true)
    }

    @Test("403 with a Bearer [REDACTED] GraphQL body stays auth-required")
    func classify403BearerGraphQL() async {
        let verdict = await MCPProbeClassifier.classify(
            response: probeResponse(status: 403, headers: ["WWW-Authenticate": "Bearer"], body: graphqlBody),
            method: .post,
            protectedResource: { false }
        )
        #expect(verdict?.isAuthRequired == true)
    }

    @Test("bare Bearer [REDACTED] signal upgrades via metadata when the document matches")
    func classifyBareBearerMetadataUpgrade() async {
        var metadataCalls = 0
        let verdict = await MCPProbeClassifier.classify(
            response: probeResponse(status: 401, headers: ["WWW-Authenticate": "Bearer"], body: "nope"),
            method: .post,
            protectedResource: {
                metadataCalls += 1
                return true
            }
        )
        #expect(verdict == .mcp(requiresAuth: true))
        #expect(metadataCalls == 1)
    }

    @Test("SSE 401 accepts the Bearer [REDACTED] alone")
    func classifySSE401() async {
        let verdict = await MCPProbeClassifier.classify(
            response: probeResponse(
                status: 401,
                headers: ["WWW-Authenticate": "Bearer", "content-type": "text/event-stream"],
                body: "not-json"
            ),
            method: .post,
            protectedResource: { false }
        )
        #expect(verdict == .mcp(requiresAuth: true))
    }

    @Test("oversized bodies are unread, so body gates fail closed")
    func classifyOversizedBody() async {
        let padding = String(repeating: " ", count: MCPProbeClassifier.maximumBodyBytes + 1)
        let verdict = await MCPProbeClassifier.classify(
            response: probeResponse(
                status: 200,
                headers: ["content-type": "application/json"],
                body: jsonRPCResult + padding
            ),
            method: .post,
            protectedResource: { false }
        )
        #expect(verdict?.isWrongShape == true)
        let auth = await MCPProbeClassifier.classify(
            response: probeResponse(
                status: 401,
                headers: ["WWW-Authenticate": "Bearer"],
                body: jsonRPCRemoteError + padding
            ),
            method: .post,
            protectedResource: { false }
        )
        #expect(auth?.isAuthRequired == true)
    }

    // MARK: - Classifier atoms

    @Test("header lookup is case-insensitive and misses cleanly")
    func headerLookup() {
        #expect(MCPProbeClassifier.header(["Content-Type": "x"], name: "Content-Type") == "x")
        #expect(MCPProbeClassifier.header(["X-A": "1", "Content-Type": "x"], name: "content-type") == "x")
        #expect(MCPProbeClassifier.header(["X-A": "1"], name: "content-type") == nil)
        #expect(MCPProbeClassifier.header([:], name: "content-type") == nil)
    }

    @Test("Bearer [REDACTED] matching follows the anchored token rule")
    func bearerMatching() {
        #expect(MCPProbeClassifier.isBearerChallenge("Bearer") == true)
        #expect(MCPProbeClassifier.isBearerChallenge("  bearer realm=\"x\"") == true)
        #expect(MCPProbeClassifier.isBearerChallenge("BEARER,") == true)
        #expect(MCPProbeClassifier.isBearerChallenge("bearers") == false)
        #expect(MCPProbeClassifier.isBearerChallenge("bearerX") == false)
        #expect(MCPProbeClassifier.isBearerChallenge("bearer5") == false)
        #expect(MCPProbeClassifier.isBearerChallenge("bearer_") == false)
        #expect(MCPProbeClassifier.isBearerChallenge("beareré") == true)
        #expect(MCPProbeClassifier.isBearerChallenge("beareré") == false)
        #expect(MCPProbeClassifier.isBearerChallenge("Basic xyz") == false)
        #expect(MCPProbeClassifier.isBearerChallenge("bea") == false)
        #expect(MCPProbeClassifier.isBearerChallenge("") == false)
    }

    @Test("SSE content-type matching tolerates parameters and case")
    func sseMatching() {
        #expect(MCPProbeClassifier.isSSEContentType("text/event-stream") == true)
        #expect(MCPProbeClassifier.isSSEContentType("  Text/Event-Stream; charset=utf-8") == true)
        #expect(MCPProbeClassifier.isSSEContentType("text/event-streaming") == false)
        #expect(MCPProbeClassifier.isSSEContentType("application/json") == false)
        #expect(MCPProbeClassifier.isSSEContentType("") == false)
    }

    @Test("auth-param matching requires a boundary and an equals sign")
    func authParamMatching() {
        #expect(MCPProbeClassifier.hasAuthParam("resource_metadata=\"u\"", name: "resource_metadata") == true)
        #expect(MCPProbeClassifier.hasAuthParam("Bearer resource_metadata = \"u\"", name: "resource_metadata") == true)
        #expect(MCPProbeClassifier.hasAuthParam("Bearer a=b,error=\"x\"", name: "error") == true)
        #expect(MCPProbeClassifier.hasAuthParam("Bearer Error=\"x\"", name: "error") == true)
        #expect(MCPProbeClassifier.hasAuthParam("Bearer x-error=\"x\"", name: "error") == false)
        #expect(MCPProbeClassifier.hasAuthParam("Bearer error now", name: "error") == false)
        #expect(MCPProbeClassifier.hasAuthParam("Bearer realm", name: "error") == false)
        #expect(MCPProbeClassifier.hasAuthParam("err", name: "resource_metadata") == false)
    }

    @Test("JSON-RPC envelope detection pins the three shapes and the rejects")
    func jsonRPCEnvelope() {
        #expect(MCPProbeClassifier.isJSONRPCEnvelope(jsonRPCResult) == true)
        #expect(MCPProbeClassifier.isJSONRPCEnvelope(jsonRPCRemoteError) == true)
        #expect(MCPProbeClassifier.isJSONRPCEnvelope(jsonRPCMethod) == true)
        #expect(MCPProbeClassifier.isJSONRPCEnvelope(#"{"jsonrpc":"1.0","result":1}"#) == false)
        #expect(MCPProbeClassifier.isJSONRPCEnvelope(#"{"jsonrpc":"2.0"}"#) == false)
        #expect(MCPProbeClassifier.isJSONRPCEnvelope(graphqlBody) == false)
        #expect(MCPProbeClassifier.isJSONRPCEnvelope("[1,2]") == false)
        #expect(MCPProbeClassifier.isJSONRPCEnvelope("{{{") == false)
        #expect(MCPProbeClassifier.isJSONRPCEnvelope("") == false)
    }

    @Test("OAuth error-body detection excludes the GraphQL shape")
    func oauthErrorBodyDetection() {
        #expect(MCPProbeClassifier.isOAuthErrorBody(oauthErrorBody) == true)
        #expect(MCPProbeClassifier.isOAuthErrorBody(#"{"error":"x","errors":[]}"#) == false)
        #expect(MCPProbeClassifier.isOAuthErrorBody(#"{"error":1}"#) == false)
        #expect(MCPProbeClassifier.isOAuthErrorBody(graphqlBody) == false)
        #expect(MCPProbeClassifier.isOAuthErrorBody("nope") == false)
        #expect(MCPProbeClassifier.isOAuthErrorBody("") == false)
    }

    // MARK: - Endpoint telemetry

    @Test("telemetry strips credentials and keeps scheme, host, and path")
    func telemetryStripsCredentials() {
        let attributes = MCPUpstreamEndpointTelemetry.attributes(
            endpoint: "https://User:Pass@Example.COM:8443/a/b?token=x#f"
        )
        #expect(attributes.sanitized == "https://example.com:8443/a/b")
        #expect(attributes.origin == "https://example.com:8443")
        #expect(attributes.hasQuery == true)
        #expect(attributes.hasFragment == true)
        #expect(attributes.hasUserinfo == true)
        #expect(attributes.sanitized.contains("User") == false)
        #expect(attributes.sanitized.contains("token") == false)
    }

    @Test("telemetry passes clean endpoints through with honest flags")
    func telemetryCleanEndpoint() {
        let attributes = MCPUpstreamEndpointTelemetry.attributes(endpoint: "http://h:8080/mcp")
        #expect(attributes.sanitized == "http://h:8080/mcp")
        #expect(attributes.origin == "http://h:8080")
        #expect(attributes.hasQuery == false)
        #expect(attributes.hasFragment == false)
        #expect(attributes.hasUserinfo == false)
        #expect(MCPUpstreamEndpointTelemetry.sanitized(endpoint: "http://h:8080/mcp") == "http://h:8080/mcp")
    }

    @Test("telemetry normalizes scheme and host case but keeps path case")
    func telemetryCaseNormalization() {
        let attributes = MCPUpstreamEndpointTelemetry.attributes(endpoint: "HTTP://E.COM/X")
        #expect(attributes.sanitized == "http://e.com/X")
        #expect(attributes.origin == "http://e.com")
    }

    @Test("telemetry keeps IPv6 authorities bracketed")
    func telemetryIPv6() {
        let attributes = MCPUpstreamEndpointTelemetry.attributes(endpoint: "http://[::1]:9000/mcp?x=1")
        #expect(attributes.sanitized == "http://[::1]:9000/mcp")
        #expect(attributes.origin == "http://[::1]:9000")
        #expect(attributes.hasQuery == true)
    }

    @Test("telemetry percent-encodes the kept path")
    func telemetryEncodedPath() {
        let attributes = MCPUpstreamEndpointTelemetry.attributes(endpoint: "http://h/a b")
        #expect(attributes.sanitized == "http://h/a%20b")
    }

    @Test("unparseable input degrades through truncation, never verbatim")
    func telemetryOpaqueFallback() {
        let garbage = MCPUpstreamEndpointTelemetry.attributes(endpoint: "ht tp://[::1")
        #expect(garbage.origin == nil)
        let paste = MCPUpstreamEndpointTelemetry.attributes(endpoint: "user:pass@host/x?token=abc#frag")
        #expect(paste.sanitized == "host/x")
        #expect(paste.origin == nil)
        #expect(paste.hasQuery == true)
        #expect(paste.hasFragment == true)
        #expect(paste.hasUserinfo == true)
        let queryOnly = MCPUpstreamEndpointTelemetry.attributes(endpoint: "notes?token=abc")
        #expect(queryOnly.sanitized == "notes")
        #expect(queryOnly.hasQuery == true)
        #expect(queryOnly.hasFragment == false)
        let fragmentOnly = MCPUpstreamEndpointTelemetry.attributes(endpoint: "notes#frag")
        #expect(fragmentOnly.sanitized == "notes")
        #expect(fragmentOnly.hasQuery == false)
        #expect(fragmentOnly.hasFragment == true)
        let fragmentQuery = MCPUpstreamEndpointTelemetry.attributes(endpoint: "notes#frag?notquery")
        #expect(fragmentQuery.hasQuery == false)
        #expect(fragmentQuery.hasFragment == true)
        let plain = MCPUpstreamEndpointTelemetry.attributes(endpoint: "notes")
        #expect(plain.sanitized == "notes")
        #expect(plain.hasQuery == false)
        #expect(plain.hasFragment == false)
        #expect(plain.hasUserinfo == false)
        let userinfoOnly = MCPUpstreamEndpointTelemetry.attributes(endpoint: "u@h")
        #expect(userinfoOnly.sanitized == "h")
        #expect(userinfoOnly.hasUserinfo == true)
    }

    @Test("schemeless, hostless, and empty-host endpoints all degrade to opaque")
    func telemetryDegenerateURLs() {
        #expect(MCPUpstreamEndpointTelemetry.attributes(endpoint: "//h/x").origin == nil)
        #expect(MCPUpstreamEndpointTelemetry.attributes(endpoint: "http:/x").origin == nil)
        #expect(MCPUpstreamEndpointTelemetry.attributes(endpoint: "http://").origin == nil)
    }

    @Test("authority bracketing covers v6, ports, and plain hosts")
    func authorityOf() {
        #expect(MCPUpstreamEndpointTelemetry.authorityOf(host: "::1", port: 9000) == "[::1]:9000")
        #expect(MCPUpstreamEndpointTelemetry.authorityOf(host: "::1", port: nil) == "[::1]")
        #expect(MCPUpstreamEndpointTelemetry.authorityOf(host: "[::1]", port: 9000) == "[::1]:9000")
        #expect(MCPUpstreamEndpointTelemetry.authorityOf(host: "[::1]", port: nil) == "[::1]")
        #expect(MCPUpstreamEndpointTelemetry.authorityOf(host: "Example.COM", port: 1) == "example.com:1")
        #expect(MCPUpstreamEndpointTelemetry.authorityOf(host: "h", port: nil) == "h")
    }

    @Test("userinfo detection covers both halves")
    func userinfoPresent() {
        #expect(MCPUpstreamEndpointTelemetry.userinfoPresent(user: nil, password: nil) == false)
        #expect(MCPUpstreamEndpointTelemetry.userinfoPresent(user: "u", password: nil) == true)
        #expect(MCPUpstreamEndpointTelemetry.userinfoPresent(user: nil, password: "p") == true)
        #expect(MCPUpstreamEndpointTelemetry.userinfoPresent(user: "u", password: "p") == true)
        #expect(MCPUpstreamEndpointTelemetry.userinfoPresent(user: "", password: nil) == false)
        #expect(MCPUpstreamEndpointTelemetry.userinfoPresent(user: nil, password: "") == false)
        #expect(MCPUpstreamEndpointTelemetry.userinfoPresent(user: "", password: "") == false)
    }

    @Test("bare delimiters report no credential components")
    func telemetryBareDelimiters() {
        let query = MCPUpstreamEndpointTelemetry.attributes(endpoint: "https://h/x?")
        #expect(query.sanitized == "https://h/x")
        #expect(query.hasQuery == false)
        #expect(query.hasFragment == false)
        let fragment = MCPUpstreamEndpointTelemetry.attributes(endpoint: "https://h/x#")
        #expect(fragment.hasQuery == false)
        #expect(fragment.hasFragment == false)
        let userinfo = MCPUpstreamEndpointTelemetry.attributes(endpoint: "https://@h/x")
        #expect(userinfo.sanitized == "https://h/x")
        #expect(userinfo.hasUserinfo == false)
    }

    // MARK: - Messages and options

    @Test("probe messages are fixed and never surface the raw reason")
    func probeMessages() {
        let secret = "Bearer hunter2-in-" + String(repeating: "reason", count: 4)
        #expect(MCPProbeMessages.message(for: .mcp(requiresAuth: false)) == nil)
        #expect(MCPProbeMessages.message(for: .mcp(requiresAuth: true)) == nil)
        let wrong = MCPProbeMessages.message(
            for: .notMCP(category: .wrongShape, reason: secret)
        )
        #expect(wrong == MCPProbeMessages.notMCP)
        #expect(wrong?.contains("hunter2") == false)
        let auth = MCPProbeMessages.message(
            for: .notMCP(category: .authRequired, reason: secret)
        )
        #expect(auth == MCPProbeMessages.notMCP)
        #expect(auth?.contains("hunter2") == false)
        let down = MCPProbeMessages.message(for: .unreachable(reason: secret))
        #expect(down == MCPProbeMessages.unreachable)
        #expect(down?.contains("hunter2") == false)
        for message in [
            MCPProbeMessages.unreachable, MCPProbeMessages.notMCP, MCPProbeMessages.missingEndpoint,
            MCPProbeMessages.undiscoverable, MCPProbeMessages.stdioStartFailure,
        ] {
            #expect(message.isEmpty == false)
            #expect(OperatorText.containsDisallowedTextScalar(message) == false)
        }
    }

    @Test("probe timeout clamps to 1 through 60000")
    func probeOptionsClamp() {
        #expect(MCPProbeOptions(timeoutMs: 0).timeoutMs == 1)
        #expect(MCPProbeOptions(timeoutMs: -50).timeoutMs == 1)
        #expect(MCPProbeOptions(timeoutMs: 8_000).timeoutMs == 8_000)
        #expect(MCPProbeOptions(timeoutMs: 60_000).timeoutMs == 60_000)
        #expect(MCPProbeOptions(timeoutMs: 60_001).timeoutMs == 60_000)
        #expect(MCPProbeOptions.default.timeoutMs == 8_000)
    }

    // MARK: - Wire details: headers

    @Test("POST headers carry JSON defaults under configured headers")
    func postHeaders() {
        let headers = MCPUpstreamProber.postHeaders(configured: [:])
        #expect(headers == [
            "content-type": "application/json",
            "accept": "application/json, text/event-stream",
            "user-agent": HTTPEgressLimits.userAgent,
        ])
        let custom = MCPUpstreamProber.postHeaders(configured: ["X-Tenant": "acme"])
        #expect(custom["X-Tenant"] == "acme")
        #expect(custom["accept"] == "application/json, text/event-stream")
        let override = MCPUpstreamProber.postHeaders(configured: ["Accept": "application/json"])
        #expect(override["Accept"] == "application/json")
        #expect(override["accept"] == nil)
    }

    @Test("GET headers accept only the event stream")
    func getHeaders() {
        let headers = MCPUpstreamProber.getHeaders(configured: [:])
        #expect(headers == ["accept": "text/event-stream", "user-agent": HTTPEgressLimits.userAgent])
    }

    @Test("discover headers pin the protocol version above configured headers")
    func discoverHeaders() {
        let headers = MCPUpstreamProber.discoverHeaders(configured: [:])
        #expect(headers["MCP-Protocol-Version"] == "2026-07-28")
        #expect(headers["content-type"] == "application/json")
        let hostile = MCPUpstreamProber.discoverHeaders(configured: ["mcp-protocol-version": "evil"])
        #expect(hostile["MCP-Protocol-Version"] == "2026-07-28")
        #expect(hostile["mcp-protocol-version"] == nil)
    }

    @Test("configured User-Agent wins in any casing; otherwise the shared default")
    func userAgentSelection() {
        #expect(MCPUpstreamProber.userAgent(configured: [:]) == HTTPEgressLimits.userAgent)
        #expect(MCPUpstreamProber.userAgent(configured: ["User-Agent": "custom/2"]) == "custom/2")
        #expect(MCPUpstreamProber.userAgent(configured: ["user-agent": "lower/1"]) == "lower/1")
        let headers = MCPUpstreamProber.postHeaders(configured: ["User-Agent": "custom/2"])
        #expect(headers["User-Agent"] == "custom/2")
        #expect(headers["user-agent"] == nil)
    }

    // MARK: - Wire details: URLs and metadata

    @Test("probe URL appends percent-encoded query pairs")
    func probeURL() {
        #expect(MCPUpstreamProber.probeURL(endpoint: "https://h/mcp", query: []) == "https://h/mcp")
        #expect(MCPUpstreamProber.probeURL(
            endpoint: "https://h/mcp",
            query: [(key: "token", value: "a&b=c?d#f g+t")]
        ) == "https://h/mcp?token=a%26b%3Dc%3Fd%23f%20g%2Bt")
        #expect(MCPUpstreamProber.probeURL(
            endpoint: "https://h/mcp?old=1",
            query: [(key: "n", value: "v")]
        ) == "https://h/mcp?old=1&n=v")
        #expect(MCPUpstreamProber.probeURL(endpoint: "notaurl", query: []) == nil)
        #expect(MCPUpstreamProber.probeURL(endpoint: "//h/x", query: []) == nil)
        #expect(MCPUpstreamProber.probeURL(endpoint: "ht tp://x", query: []) == nil)
    }

    @Test("probe gate admits http(s) with a host and rejects everything else")
    func probeableEndpoint() {
        #expect(MCPUpstreamProber.probeableEndpoint("https://h/mcp") == true)
        #expect(MCPUpstreamProber.probeableEndpoint("http://h/mcp") == true)
        #expect(MCPUpstreamProber.probeableEndpoint("HTTPS://H/MCP") == true)
        #expect(MCPUpstreamProber.probeableEndpoint("http://127.0.0.1:9/mcp") == true)
        #expect(MCPUpstreamProber.probeableEndpoint("http://[::1]/mcp") == true)
        #expect(MCPUpstreamProber.probeableEndpoint("http://169.254.169.254/mcp") == true)
        #expect(MCPUpstreamProber.probeableEndpoint("https://u:p@h/mcp") == true)
        #expect(MCPUpstreamProber.probeableEndpoint("file://host/etc/passwd") == false)
        #expect(MCPUpstreamProber.probeableEndpoint("file:///etc/passwd") == false)
        #expect(MCPUpstreamProber.probeableEndpoint("ftp://h/x") == false)
        #expect(MCPUpstreamProber.probeableEndpoint("javascript:alert(1)") == false)
        #expect(MCPUpstreamProber.probeableEndpoint("https:notslashed") == false)
        #expect(MCPUpstreamProber.probeableEndpoint("notaurl") == false)
        #expect(MCPUpstreamProber.probeableEndpoint("//h/x") == false)
        #expect(MCPUpstreamProber.probeableEndpoint("http://") == false)
        #expect(MCPUpstreamProber.probeableEndpoint("") == false)
    }

    @Test("probe URL rejects undialable schemes without sending")
    func probeURLSchemes() {
        #expect(MCPUpstreamProber.probeURL(endpoint: "file://host/etc/passwd", query: []) == nil)
        #expect(MCPUpstreamProber.probeURL(endpoint: "file:///etc/passwd", query: []) == nil)
        #expect(MCPUpstreamProber.probeURL(endpoint: "ftp://h/x", query: []) == nil)
        #expect(MCPUpstreamProber.probeURL(endpoint: "HTTPS://H/MCP", query: []) == "HTTPS://H/MCP")
        #expect(MCPUpstreamProber.probeURL(endpoint: "http://h:9/mcp", query: []) == "http://h:9/mcp")
        #expect(MCPUpstreamProber.probeURL(
            endpoint: "https://u:p@h/mcp", query: [(key: "q", value: "v")]
        ) == "https://u:p@h/mcp?q=v")
    }

    @Test("query escaping leaves unreserved bytes and encodes the rest")
    func queryEscaped() {
        #expect(MCPUpstreamProber.queryEscaped("abcXYZ019-_.~") == "abcXYZ019-_.~")
        #expect(MCPUpstreamProber.queryEscaped("") == "")
        #expect(MCPUpstreamProber.queryEscaped("a+b") == "a%2Bb")
        #expect(MCPUpstreamProber.queryEscaped("a b?c&d=e#f") == "a%20b%3Fc%26d%3De%23f")
        #expect(MCPUpstreamProber.queryEscaped("a/b:c@d") == "a%2Fb%3Ac%40d")
        #expect(MCPUpstreamProber.queryEscaped("é") == "%C3%A9")
        #expect(MCPUpstreamProber.isQueryUnreservedByte(65) == true)
        #expect(MCPUpstreamProber.isQueryUnreservedByte(122) == true)
        #expect(MCPUpstreamProber.isQueryUnreservedByte(57) == true)
        #expect(MCPUpstreamProber.isQueryUnreservedByte(45) == true)
        #expect(MCPUpstreamProber.isQueryUnreservedByte(95) == true)
        #expect(MCPUpstreamProber.isQueryUnreservedByte(46) == true)
        #expect(MCPUpstreamProber.isQueryUnreservedByte(126) == true)
        #expect(MCPUpstreamProber.isQueryUnreservedByte(43) == false)
        #expect(MCPUpstreamProber.isQueryUnreservedByte(32) == false)
        #expect(MCPUpstreamProber.isQueryUnreservedByte(47) == false)
    }

    @Test("probe URL keeps the pasted query byte-identical and the fragment in place")
    func probeURLExistingQuery() {
        #expect(MCPUpstreamProber.probeURL(
            endpoint: "https://h/mcp?old=a+b",
            query: [(key: "n", value: "x+y")]
        ) == "https://h/mcp?old=a+b&n=x%2By")
        #expect(MCPUpstreamProber.probeURL(
            endpoint: "https://h/mcp#f",
            query: [(key: "n", value: "v")]
        ) == "https://h/mcp?n=v#f")
        #expect(MCPUpstreamProber.probeURL(
            endpoint: "https://h/x?",
            query: [(key: "n", value: "v")]
        ) == "https://h/x?n=v")
    }

    @Test("rendered query pairs overwrite colliding pasted pairs")
    func probeURLCollision() {
        #expect(MCPUpstreamProber.probeURL(
            endpoint: "https://h/mcp?token=old&keep=1",
            query: [(key: "token", value: "new secret")]
        ) == "https://h/mcp?keep=1&token=new%20secret")
        #expect(MCPUpstreamProber.probeURL(
            endpoint: "https://h/mcp?token=old",
            query: [(key: "token", value: "new")]
        ) == "https://h/mcp?token=new")
        #expect(MCPUpstreamProber.probeURL(
            endpoint: "https://h/mcp?tok%65n=pasted",
            query: [(key: "token", value: "rendered")]
        ) == "https://h/mcp?token=rendered")
    }

    @Test("colliding-pair stripping keeps the rest byte-identical")
    func stripCollidingPairs() {
        #expect(MCPUpstreamProber.stripCollidingQueryPairs("a=1&b=2", renderedKeys: ["b"]) == "a=1")
        #expect(MCPUpstreamProber.stripCollidingQueryPairs("b=1&a=2", renderedKeys: ["b"]) == "a=2")
        #expect(MCPUpstreamProber.stripCollidingQueryPairs("a=1", renderedKeys: ["b"]) == "a=1")
        #expect(MCPUpstreamProber.stripCollidingQueryPairs("flag&b=2", renderedKeys: ["flag"]) == "b=2")
        #expect(MCPUpstreamProber.stripCollidingQueryPairs("a=1&&b=2", renderedKeys: ["zzz"]) == "a=1&&b=2")
        #expect(MCPUpstreamProber.stripCollidingQueryPairs("tok%zz=1&b=2", renderedKeys: ["b"]) == "tok%zz=1")
        #expect(MCPUpstreamProber.stripCollidingQueryPairs("", renderedKeys: ["a"]) == "")
        #expect(MCPUpstreamProber.stripCollidingQueryPairs("a+b=1&c=2", renderedKeys: ["a+b"]) == "a+b=1&c=2")
        #expect(MCPUpstreamProber.stripCollidingQueryPairs("a%2Bb=1&c=2", renderedKeys: ["a+b"]) == "c=2")
    }

    @Test("metadata URL inserts the well-known path and drops userinfo and query")
    func metadataURL() {
        #expect(MCPUpstreamProber.protectedResourceMetadataURL(endpoint: "https://host/api/mcp")
            == "https://host/.well-known/oauth-protected-resource/api/mcp")
        #expect(MCPUpstreamProber.protectedResourceMetadataURL(endpoint: "https://host/")
            == "https://host/.well-known/oauth-protected-resource")
        #expect(MCPUpstreamProber.protectedResourceMetadataURL(endpoint: "https://host")
            == "https://host/.well-known/oauth-protected-resource")
        #expect(MCPUpstreamProber.protectedResourceMetadataURL(endpoint: "http://h:8080/a/")
            == "http://h:8080/.well-known/oauth-protected-resource/a/")
        #expect(MCPUpstreamProber.protectedResourceMetadataURL(endpoint: "http://[::1]/x")
            == "http://[::1]/.well-known/oauth-protected-resource/x")
        let dropped = MCPUpstreamProber.protectedResourceMetadataURL(
            endpoint: "https://u:p@host/a?token=x#f"
        )
        #expect(dropped == "https://host/.well-known/oauth-protected-resource/a")
        #expect(MCPUpstreamProber.protectedResourceMetadataURL(endpoint: "ht tp://x") == nil)
        #expect(MCPUpstreamProber.protectedResourceMetadataURL(endpoint: "//h/x") == nil)
        #expect(MCPUpstreamProber.protectedResourceMetadataURL(endpoint: "notaurl") == nil)
        #expect(MCPUpstreamProber.protectedResourceMetadataURL(endpoint: "http://") == nil)
        #expect(MCPUpstreamProber.protectedResourceMetadataURL(endpoint: "file://host/x") == nil)
        #expect(MCPUpstreamProber.protectedResourceMetadataURL(endpoint: "file:///x") == nil)
        #expect(MCPUpstreamProber.protectedResourceMetadataURL(endpoint: "ftp://h/x") == nil)
    }

    @Test("metadata URL keeps the encoded path and lowercases the scheme")
    func metadataURLEncoded() {
        #expect(MCPUpstreamProber.protectedResourceMetadataURL(endpoint: "https://host/a%20b/c")
            == "https://host/.well-known/oauth-protected-resource/a%20b/c")
        #expect(MCPUpstreamProber.protectedResourceMetadataURL(endpoint: "HTTPS://HOST/Api/Mcp")
            == "https://host/.well-known/oauth-protected-resource/Api/Mcp")
    }

    @Test("resource match requires same origin plus exact or parent path")
    func resourceMatch() {
        #expect(MCPUpstreamProber.resourceMatchesEndpoint(
            resource: "https://h/api", endpoint: "https://h/api/mcp"
        ) == true)
        #expect(MCPUpstreamProber.resourceMatchesEndpoint(
            resource: "https://h/api/", endpoint: "https://h/api"
        ) == true)
        #expect(MCPUpstreamProber.resourceMatchesEndpoint(
            resource: "https://h/api", endpoint: "https://h/api"
        ) == true)
        #expect(MCPUpstreamProber.resourceMatchesEndpoint(
            resource: "https://h/api", endpoint: "https://h/other"
        ) == false)
        #expect(MCPUpstreamProber.resourceMatchesEndpoint(
            resource: "https://h/api", endpoint: "https://h/apimap"
        ) == false)
        #expect(MCPUpstreamProber.resourceMatchesEndpoint(
            resource: "https://h/api", endpoint: "http://h/api"
        ) == false)
        #expect(MCPUpstreamProber.resourceMatchesEndpoint(
            resource: "https://a/api", endpoint: "https://b/api"
        ) == false)
        #expect(MCPUpstreamProber.resourceMatchesEndpoint(
            resource: "https://h:1/api", endpoint: "https://h:2/api"
        ) == false)
        #expect(MCPUpstreamProber.resourceMatchesEndpoint(
            resource: "https://h/api", endpoint: "https://h:443/api"
        ) == true)
        #expect(MCPUpstreamProber.resourceMatchesEndpoint(
            resource: "notaurl", endpoint: "https://h/api"
        ) == false)
        #expect(MCPUpstreamProber.resourceMatchesEndpoint(
            resource: "https://h/api", endpoint: "notaurl"
        ) == false)
        #expect(MCPUpstreamProber.resourceMatchesEndpoint(
            resource: "custom://h/a", endpoint: "custom://h/a/b"
        ) == true)
    }

    @Test("resource match compares encoded paths, so %2F is not a separator")
    func resourceMatchEncoded() {
        #expect(MCPUpstreamProber.resourceMatchesEndpoint(
            resource: "https://h/a%2Fb", endpoint: "https://h/a/b/c"
        ) == false)
        #expect(MCPUpstreamProber.resourceMatchesEndpoint(
            resource: "https://h/a/b", endpoint: "https://h/a%2Fb/c"
        ) == false)
        #expect(MCPUpstreamProber.resourceMatchesEndpoint(
            resource: "https://h/a%2fb", endpoint: "https://h/a%2Fb"
        ) == true)
        #expect(MCPUpstreamProber.resourceMatchesEndpoint(
            resource: "https://h/a%20b", endpoint: "https://h/a%20b/c"
        ) == true)
        #expect(MCPUpstreamProber.originParts("https://h/a%20b")?.path == "/a%20b")
        #expect(MCPUpstreamProber.originParts("https://h/a%2fb")?.path == "/a%2fb")
    }

    @Test("encoded-path normalization uppercases hex and leaves the rest")
    func normalizedEncodedPath() {
        #expect(MCPUpstreamProber.normalizedEncodedPath("/a/b") == "/a/b")
        #expect(MCPUpstreamProber.normalizedEncodedPath("") == "")
        #expect(MCPUpstreamProber.normalizedEncodedPath("/a%2fb") == "/a%2Fb")
        #expect(MCPUpstreamProber.normalizedEncodedPath("/a%2Fb") == "/a%2Fb")
        #expect(MCPUpstreamProber.normalizedEncodedPath("/a%zz") == "/a%zz")
        #expect(MCPUpstreamProber.normalizedEncodedPath("/a%") == "/a%")
        #expect(MCPUpstreamProber.normalizedEncodedPath("/a%2") == "/a%2")
        #expect(MCPUpstreamProber.normalizedEncodedPath("%%41") == "%%41")
    }

    @Test("origin parts lowercase and default ports")
    func originParts() {
        #expect(MCPUpstreamProber.originParts("HTTPS://EXAMPLE.com:443/X") == MCPProbeOriginParts(
            scheme: "https", host: "example.com", port: 443, path: "/X"
        ))
        #expect(MCPUpstreamProber.originParts("http://h/x")?.port == 80)
        #expect(MCPUpstreamProber.originParts("https://h/x")?.port == 443)
        #expect(MCPUpstreamProber.originParts("custom://h/x")?.port == nil)
        #expect(MCPUpstreamProber.originParts("notaurl") == nil)
        #expect(MCPUpstreamProber.originParts("//h/x") == nil)
        #expect(MCPUpstreamProber.originParts("http://") == nil)
    }

    @Test("path trimming drops trailing slashes only")
    func trimmedPath() {
        #expect(MCPUpstreamProber.trimmedPath("/a/b") == "/a/b")
        #expect(MCPUpstreamProber.trimmedPath("/a/b//") == "/a/b")
        #expect(MCPUpstreamProber.trimmedPath("/") == "")
        #expect(MCPUpstreamProber.trimmedPath("") == "")
    }

    @Test("metadata decode pins the two trusted fields and every reject")
    func metadataDecode() {
        let valid = MCPUpstreamProber.decodeProtectedResourceMetadata(
            #"{"resource":"https://h/a","authorization_servers":["https://auth"]}"#
        )
        #expect(valid == MCPProtectedResourceMetadata(
            resource: "https://h/a", authorizationServers: ["https://auth"]
        ))
        #expect(MCPUpstreamProber.decodeProtectedResourceMetadata("") == nil)
        #expect(MCPUpstreamProber.decodeProtectedResourceMetadata("{oops") == nil)
        #expect(MCPUpstreamProber.decodeProtectedResourceMetadata("[1]") == nil)
        #expect(MCPUpstreamProber.decodeProtectedResourceMetadata("{}") == nil)
        #expect(MCPUpstreamProber.decodeProtectedResourceMetadata(
            #"{"resource":1,"authorization_servers":[]}"#
        ) == nil)
        #expect(MCPUpstreamProber.decodeProtectedResourceMetadata(#"{"resource":"x"}"#) == nil)
        #expect(MCPUpstreamProber.decodeProtectedResourceMetadata(
            #"{"resource":"x","authorization_servers":[1]}"#
        ) == nil)
    }

    // MARK: - Wire details: paste, names, reasons

    @Test("paste gate caps bytes and rejects disallowed scalars")
    func validProbePaste() {
        #expect(MCPUpstreamProber.validProbePaste("https://h/mcp") == true)
        #expect(MCPUpstreamProber.validProbePaste(String(repeating: "a", count: 2_049)) == false)
        #expect(MCPUpstreamProber.validProbePaste("https://h/a\u{07}b") == false)
        #expect(MCPUpstreamProber.validProbePaste("https://h/a\nb") == false)
    }

    @Test("host gate requires a clean bounded label")
    func validProbeHost() {
        #expect(MCPUpstreamProber.validProbeHost("example.com") == true)
        #expect(MCPUpstreamProber.validProbeHost("") == false)
        #expect(MCPUpstreamProber.validProbeHost(String(repeating: "a", count: 257)) == false)
        #expect(MCPUpstreamProber.validProbeHost("a\u{07}b") == false)
    }

    @Test("display name is the hostname, else mcp")
    func displayName() {
        #expect(MCPUpstreamProber.displayName(endpoint: "https://api.example.com/mcp") == "api.example.com")
        #expect(MCPUpstreamProber.displayName(endpoint: "https://API.EXAMPLE.com/mcp") == "api.example.com")
        #expect(MCPUpstreamProber.displayName(endpoint: "notaurl") == "mcp")
        let longHost = "http://" + String(repeating: "a", count: 300)
        #expect(URLComponents(string: longHost)?.host == nil ? false : true)
        #expect(MCPUpstreamProber.displayName(endpoint: longHost) == "mcp")
    }

    @Test("connected name prefers a clean manifest name")
    func connectedName() {
        #expect(MCPUpstreamProber.connectedName(manifestName: "Acme MCP", hostName: "h") == "Acme MCP")
        #expect(MCPUpstreamProber.connectedName(manifestName: nil, hostName: "h") == "h")
        #expect(MCPUpstreamProber.connectedName(manifestName: "a\u{07}b", hostName: "h") == "h")
    }

    @Test("stdio display name falls back twice before mcp")
    func displayStdioName() {
        #expect(MCPUpstreamProber.displayStdioName(manifestName: "Server", configName: "Cfg") == "Server")
        #expect(MCPUpstreamProber.displayStdioName(manifestName: nil, configName: "Cfg") == "Cfg")
        #expect(MCPUpstreamProber.displayStdioName(manifestName: "a\u{07}b", configName: "Cfg") == "Cfg")
        #expect(MCPUpstreamProber.displayStdioName(manifestName: nil, configName: "") == "mcp")
        #expect(MCPUpstreamProber.displayStdioName(manifestName: "a\u{07}b", configName: "c\u{07}d") == "mcp")
    }

    @Test("seam reasons stay fixed labels with timeouts distinguished")
    func seamReason() {
        #expect(MCPUpstreamProber.seamReason(MCPProbeSeamError.timeout) == "timeout")
        #expect(MCPUpstreamProber.seamReason(MCPProbeSeamError.connectionFailed) == "connection-failed")
        #expect(MCPUpstreamProber.seamReason(DummyError()) == "transport-failure")
    }

    // MARK: - Input rendering

    @Test("rendered inputs pass literals verbatim and resolve secrets with prefixes")
    func renderProbeInputs() async {
        let log = RequestLog()
        let prober = makeProber(
            exchange: scriptedExchange(log: log, handler: { _ in probeResponse(status: 500, headers: [:], body: "") }),
            discovery: .unavailable,
            oauth: .unavailable,
            secrets: MCPProbeSecretResolver(resolve: { _ in "tok" })
        )
        let rendered = await prober.renderProbeInputs(
            headers: [
                "X-Literal": .literal("plain & stuff"),
                "X-Embedded": .literal("prefix secret-public-ref:file/x is literal"),
                "X-Secret": .secret(testSelector(), prefix: "Bearer "),
                "X-Bare": .secret(testSelector(), prefix: nil),
            ],
            queryParams: ["q": .literal("v"), "s": .secret(testSelector(), prefix: nil)],
            auth: .none
        )
        guard case .success(let inputs) = rendered else {
            Issue.record("expected rendered inputs")
            return
        }
        #expect(inputs.headers["X-Literal"] == "plain & stuff")
        #expect(inputs.headers["X-Embedded"] == "prefix secret-public-ref:file/x is literal")
        #expect(inputs.headers["X-Secret"] == "Bearer tok")
        #expect(inputs.headers["X-Bare"] == "tok")
        #expect(inputs == MCPProbeRenderedInputs(
            headers: inputs.headers,
            query: [(key: "q", value: "v"), (key: "s", value: "tok")]
        ))
    }

    @Test("rendered inputs fail on the first unresolvable ref in sorted order")
    func renderProbeInputsUnresolved() async {
        let log = RequestLog()
        let prober = makeProber(
            exchange: scriptedExchange(log: log, handler: { _ in probeResponse(status: 500, headers: [:], body: "") }),
            discovery: .unavailable,
            oauth: .unavailable,
            secrets: .unavailable
        )
        let headers = await prober.renderProbeInputs(
            headers: ["Z-Last": .secret(testSelector(), prefix: nil), "A-First": .secret(testSelector(), prefix: nil)],
            queryParams: [:],
            auth: .none
        )
        #expect(headers == .failure(.unresolvedSecret(label: "A-First")))
        let query = await prober.renderProbeInputs(
            headers: [:],
            queryParams: ["qq": .secret(testSelector(), prefix: nil)],
            auth: .none
        )
        #expect(query == .failure(.unresolvedSecret(label: "qq")))
        let empty = await prober.renderProbeInputs(headers: [:], queryParams: [:], auth: .none)
        #expect(empty == .success(MCPProbeRenderedInputs(headers: [:], query: [])))
    }

    @Test("header auth renders over declared headers; oauth2 renders nothing")
    func renderProbeAuth() async {
        let log = RequestLog()
        let resolving = makeProber(
            exchange: scriptedExchange(log: log, handler: { _ in probeResponse(status: 500, headers: [:], body: "") }),
            discovery: .unavailable,
            oauth: .unavailable,
            secrets: MCPProbeSecretResolver(resolve: { _ in "tok" })
        )
        let prefixed = await resolving.renderProbeInputs(
            headers: ["Authorization": .literal("declared")],
            queryParams: [:],
            auth: .header(headerName: "Authorization", secret: testSelector(), prefix: "Bearer ")
        )
        guard case .success(let inputs) = prefixed else {
            Issue.record("expected rendered auth")
            return
        }
        #expect(inputs.headers["Authorization"] == "Bearer tok")
        let twisted = await resolving.renderProbeInputs(
            headers: ["authorization": .literal("declared-lower")],
            queryParams: [:],
            auth: .header(headerName: "Authorization", secret: testSelector(), prefix: "Bearer ")
        )
        guard case .success(let twistedInputs) = twisted else {
            Issue.record("expected rendered twisted auth")
            return
        }
        #expect(twistedInputs.headers == ["Authorization": "Bearer tok"])
        let bare = await resolving.renderProbeInputs(
            headers: [:],
            queryParams: [:],
            auth: .header(headerName: "X-Key", secret: testSelector(), prefix: nil)
        )
        guard case .success(let bareInputs) = bare else {
            Issue.record("expected rendered bare auth")
            return
        }
        #expect(bareInputs.headers["X-Key"] == "tok")
        let oauth = await resolving.renderProbeInputs(
            headers: ["X-Keep": .literal("v")],
            queryParams: [:],
            auth: .oauth2(connectionId: "x.y.z")
        )
        #expect(oauth == .success(MCPProbeRenderedInputs(headers: ["X-Keep": "v"], query: [])))
        let failing = makeProber(
            exchange: resolving.exchange,
            discovery: .unavailable,
            oauth: .unavailable,
            secrets: .unavailable
        )
        let unresolved = await failing.renderProbeInputs(
            headers: [:],
            queryParams: [:],
            auth: .header(headerName: "Authorization", secret: testSelector(), prefix: "Bearer ")
        )
        #expect(unresolved == .failure(.unresolvedSecret(label: "auth")))
    }

    @Test("header values render literally, resolved, or not at all")
    func renderHeaderValue() async {
        let log = RequestLog()
        let prober = makeProber(
            exchange: scriptedExchange(log: log, handler: { _ in probeResponse(status: 500, headers: [:], body: "") }),
            discovery: .unavailable,
            oauth: .unavailable,
            secrets: MCPProbeSecretResolver(resolve: { _ in "v" })
        )
        #expect(await prober.renderHeaderValue(.literal("x")) == "x")
        #expect(await prober.renderHeaderValue(.literal("secret-public-ref:file/x")) == "secret-public-ref:file/x")
        #expect(await prober.renderHeaderValue(.secret(testSelector(), prefix: "P ")) == "P v")
        #expect(await prober.renderHeaderValue(.secret(testSelector(), prefix: nil)) == "v")
        let failing = makeProber(
            exchange: prober.exchange,
            discovery: .unavailable,
            oauth: .unavailable,
            secrets: .unavailable
        )
        #expect(await failing.renderHeaderValue(.secret(testSelector(), prefix: nil)) == nil)
        #expect(await failing.renderHeaderValue(.literal("secret-public-ref:file/x")) == "secret-public-ref:file/x")
    }

    @Test("rendered-input equality compares headers and ordered pairs")
    func renderedInputsEquality() {
        let base = MCPProbeRenderedInputs(headers: ["a": "1"], query: [(key: "q", value: "v")])
        #expect(base == MCPProbeRenderedInputs(headers: ["a": "1"], query: [(key: "q", value: "v")]))
        #expect(base == MCPProbeRenderedInputs(headers: ["a": "2"], query: [(key: "q", value: "v")]) ? false : true)
        #expect(base == MCPProbeRenderedInputs(headers: ["a": "1"], query: [(key: "q", value: "w")]) ? false : true)
        #expect(base == MCPProbeRenderedInputs(headers: ["a": "1"], query: [(key: "z", value: "v")]) ? false : true)
        #expect(MCPProbeRenderedInputs(headers: [:], query: []) == MCPProbeRenderedInputs(headers: [:], query: []))
    }

    // MARK: - Shape flow

    @Test("shape probe sends the initialize contract and reads unauth-OK")
    func shapeProbeUnauthOK() async {
        let log = RequestLog()
        let prober = makeProber(
            exchange: scriptedExchange(log: log, handler: { _ in
                probeResponse(status: 200, headers: ["content-type": "application/json"], body: jsonRPCResult)
            }),
            discovery: .unavailable,
            oauth: .unavailable,
            secrets: .unavailable
        )
        let verdict = await prober.shapeProbe(
            endpoint: probeEndpoint, headers: [:], query: [], options: probeOptions()
        )
        #expect(verdict == .mcp(requiresAuth: false))
        #expect(log.requests.count == 1)
        let request = log.requests[0]
        #expect(request.method == .post)
        #expect(request.url == probeEndpoint)
        #expect(request.body == MCPUpstreamProber.initializeBody)
        #expect(request.headers["content-type"] == "application/json")
        #expect(request.timeoutMs == 8_000)
    }

    @Test("shape probe falls back to GET for SSE-only servers")
    func shapeProbeLegacyGET() async {
        let log = RequestLog()
        let prober = makeProber(
            exchange: scriptedExchange(log: log, handler: { request in
                if request.method == .get {
                    return probeResponse(status: 200, headers: ["content-type": "text/event-stream"], body: "")
                }
                return probeResponse(status: 404, headers: [:], body: "not here")
            }),
            discovery: .unavailable,
            oauth: .unavailable,
            secrets: .unavailable
        )
        let verdict = await prober.shapeProbe(
            endpoint: probeEndpoint, headers: [:], query: [], options: probeOptions()
        )
        #expect(verdict == .mcp(requiresAuth: false))
        #expect(log.requests.count == 2)
        #expect(log.requests[1].method == .get)
        #expect(log.requests[1].headers["accept"] == "text/event-stream")
    }

    @Test("shape probe retries GET on 405 and keeps the GET verdict")
    func shapeProbeGET405() async {
        let log = RequestLog()
        let prober = makeProber(
            exchange: scriptedExchange(log: log, handler: { request in
                if request.method == .get {
                    return probeResponse(status: 200, headers: ["content-type": "text/html"], body: "<html/>")
                }
                return probeResponse(status: 405, headers: [:], body: "")
            }),
            discovery: .unavailable,
            oauth: .unavailable,
            secrets: .unavailable
        )
        let verdict = await prober.shapeProbe(
            endpoint: "https://h/mcp", headers: [:], query: [], options: probeOptions()
        )
        #expect(verdict.isWrongShape == true)
        #expect(log.requests.count == 3)
        #expect(log.requests[2].body == MCPUpstreamProber.discoverBody)
        #expect(log.requests[2].headers["MCP-Protocol-Version"] == "2026-07-28")
    }

    @Test("shape probe reports a GET transport failure as unreachable")
    func shapeProbeGETFailure() async {
        let log = RequestLog()
        let prober = makeProber(
            exchange: scriptedExchange(log: log, handler: { request in
                if request.method == .get {
                    throw MCPProbeSeamError.timeout
                }
                return probeResponse(status: 406, headers: [:], body: "")
            }),
            discovery: .unavailable,
            oauth: .unavailable,
            secrets: .unavailable
        )
        let verdict = await prober.shapeProbe(
            endpoint: "https://h/mcp", headers: [:], query: [], options: probeOptions()
        )
        #expect(verdict == .unreachable(reason: "timeout"))
    }

    @Test("unexpected statuses skip GET and keep the initialize verdict on discover failure")
    func shapeProbeUnexpectedStatus() async {
        let log = RequestLog()
        let prober = makeProber(
            exchange: scriptedExchange(log: log, handler: { request in
                if request.body == MCPUpstreamProber.discoverBody {
                    throw MCPProbeSeamError.connectionFailed
                }
                return probeResponse(status: 500, headers: [:], body: "boom")
            }),
            discovery: .unavailable,
            oauth: .unavailable,
            secrets: .unavailable
        )
        let verdict = await prober.shapeProbe(
            endpoint: "https://h/mcp", headers: [:], query: [], options: probeOptions()
        )
        #expect(verdict == .notMCP(category: .wrongShape, reason: "unexpected status 500 for initialize"))
        #expect(log.requests.count == 2)
        #expect(log.requests.allSatisfy { $0.method == .post })
    }

    @Test("a modern discover answer overwrites the wrong-shape initialize verdict")
    func shapeProbeDiscoverOverwrite() async {
        let log = RequestLog()
        let prober = makeProber(
            exchange: scriptedExchange(log: log, handler: { request in
                if request.body == MCPUpstreamProber.discoverBody {
                    return probeResponse(status: 200, headers: ["content-type": "application/json"], body: jsonRPCResult)
                }
                return probeResponse(status: 200, headers: ["content-type": "text/html"], body: "<html/>")
            }),
            discovery: .unavailable,
            oauth: .unavailable,
            secrets: .unavailable
        )
        let verdict = await prober.shapeProbe(
            endpoint: "https://h/mcp", headers: [:], query: [], options: probeOptions()
        )
        #expect(verdict == .mcp(requiresAuth: false))
        #expect(log.requests.count == 2)
    }

    @Test("discover can also surface an auth challenge the initialize probe missed")
    func shapeProbeDiscoverAuth() async {
        let prober = makeProber(
            exchange: scriptedExchange(log: RequestLog(), handler: { request in
                if request.body == MCPUpstreamProber.discoverBody {
                    return probeResponse(status: 401, headers: ["WWW-Authenticate": "Bearer"], body: jsonRPCRemoteError)
                }
                return probeResponse(status: 200, headers: ["content-type": "text/html"], body: "<html/>")
            }),
            discovery: .unavailable,
            oauth: .unavailable,
            secrets: .unavailable
        )
        let verdict = await prober.shapeProbe(
            endpoint: "https://h/mcp", headers: [:], query: [], options: probeOptions()
        )
        #expect(verdict == .mcp(requiresAuth: true))
    }

    @Test("discover fallthrough keeps the initialize verdict")
    func shapeProbeDiscoverFallthrough() async {
        let prober = makeProber(
            exchange: scriptedExchange(log: RequestLog(), handler: { request in
                if request.body == MCPUpstreamProber.discoverBody {
                    return probeResponse(status: 500, headers: [:], body: "")
                }
                return probeResponse(status: 200, headers: ["content-type": "text/html"], body: "<html/>")
            }),
            discovery: .unavailable,
            oauth: .unavailable,
            secrets: .unavailable
        )
        let verdict = await prober.shapeProbe(
            endpoint: "https://h/mcp", headers: [:], query: [], options: probeOptions()
        )
        #expect(verdict.isWrongShape == true)
    }

    @Test("shape probe maps seam failures to unreachable reasons")
    func shapeProbeSeamFailures() async {
        for (error, reason): (Error, String) in [
            (MCPProbeSeamError.timeout, "timeout"),
            (MCPProbeSeamError.connectionFailed, "connection-failed"),
            (DummyError(), "transport-failure"),
        ] {
            let prober = makeProber(
                exchange: scriptedExchange(log: RequestLog(), handler: { _ in throw error }),
                discovery: .unavailable,
                oauth: .unavailable,
                secrets: .unavailable
            )
            let verdict = await prober.shapeProbe(
                endpoint: "https://h/mcp", headers: [:], query: [], options: probeOptions()
            )
            #expect(verdict == .unreachable(reason: reason))
        }
    }

    @Test("shape probe rejects malformed endpoints without sending")
    func shapeProbeMalformedEndpoint() async {
        let log = RequestLog()
        let prober = makeProber(
            exchange: scriptedExchange(log: log, handler: { _ in
                probeResponse(status: 200, headers: [:], body: jsonRPCResult)
            }),
            discovery: .unavailable,
            oauth: .unavailable,
            secrets: .unavailable
        )
        let verdict = await prober.shapeProbe(
            endpoint: "notaurl", headers: [:], query: [], options: probeOptions()
        )
        #expect(verdict == .unreachable(reason: "malformed-endpoint"))
        #expect(log.requests.isEmpty)
    }

    @Test("shape probe sends configured headers and query on every request")
    func shapeProbeConfiguredInputs() async {
        let log = RequestLog()
        let prober = makeProber(
            exchange: scriptedExchange(log: log, handler: { request in
                if request.method == .get, request.url.contains(".well-known") == false {
                    return probeResponse(status: 200, headers: ["content-type": "text/event-stream"], body: "")
                }
                return probeResponse(status: 404, headers: [:], body: "")
            }),
            discovery: .unavailable,
            oauth: .unavailable,
            secrets: .unavailable
        )
        let verdict = await prober.shapeProbe(
            endpoint: "https://h/mcp",
            headers: ["X-Tenant": "acme"],
            query: [(key: "q", value: "v")],
            options: probeOptions()
        )
        #expect(verdict == .mcp(requiresAuth: false))
        #expect(log.requests.count == 2)
        for request in log.requests {
            #expect(request.headers["X-Tenant"] == "acme")
            #expect(request.url == "https://h/mcp?q=v")
        }
    }

    // MARK: - Metadata fallback

    @Test("metadata fallback upgrades on a matching document")
    func metadataMatch() async {
        let log = RequestLog()
        let endpoint = "https://h/api/mcp"
        let prober = makeProber(
            exchange: scriptedExchange(log: log, handler: { request in
                probeResponse(
                    status: 200,
                    headers: ["content-type": "application/json"],
                    body: #"{"resource":"https://h/api","authorization_servers":["https://auth"]}"#
                )
            }),
            discovery: .unavailable,
            oauth: .unavailable,
            secrets: .unavailable
        )
        let match = await prober.protectedResourceMatch(
            endpoint: endpoint, headers: ["User-Agent": "custom/2"], options: probeOptions()
        )
        #expect(match == true)
        #expect(log.requests.count == 1)
        #expect(log.requests[0].url == "https://h/.well-known/oauth-protected-resource/api/mcp")
        #expect(log.requests[0].headers["accept"] == "application/json")
        #expect(log.requests[0].headers["user-agent"] == "custom/2")
    }

    @Test("metadata fallback fails closed on every bad shape")
    func metadataRejects() async {
        let cases: [(String, MCPProbeHTTPResponse)] = [
            ("non-2xx", probeResponse(status: 404, headers: [:], body: "")),
            ("bad body", probeResponse(status: 200, headers: [:], body: "nope")),
            ("empty servers", probeResponse(
                status: 200, headers: [:],
                body: #"{"resource":"https://h/api","authorization_servers":[]}"#
            )),
            ("mismatch", probeResponse(
                status: 200, headers: [:],
                body: #"{"resource":"https://other/api","authorization_servers":["https://auth"]}"#
            )),
        ]
        for (_, stub) in cases {
            let prober = makeProber(
                exchange: scriptedExchange(log: RequestLog(), handler: { _ in stub }),
                discovery: .unavailable,
                oauth: .unavailable,
                secrets: .unavailable
            )
            let match = await prober.protectedResourceMatch(
                endpoint: "https://h/api/mcp", headers: [:], options: probeOptions()
            )
            #expect(match == false)
        }
        let throwing = makeProber(
            exchange: scriptedExchange(log: RequestLog(), handler: { _ in throw MCPProbeSeamError.timeout }),
            discovery: .unavailable,
            oauth: .unavailable,
            secrets: .unavailable
        )
        #expect(await throwing.protectedResourceMatch(
            endpoint: "https://h/api/mcp", headers: [:], options: probeOptions()
        ) == false)
        let unparseable = makeProber(
            exchange: scriptedExchange(log: RequestLog(), handler: { _ in
                probeResponse(status: 200, headers: [:], body: "{}")
            }),
            discovery: .unavailable,
            oauth: .unavailable,
            secrets: .unavailable
        )
        #expect(await unparseable.protectedResourceMatch(
            endpoint: "notaurl", headers: [:], options: probeOptions()
        ) == false)
    }

    @Test("legacy GET consults metadata on a challengeless 401")
    func metadataThroughLegacyGET() async {
        let log = RequestLog()
        let prober = makeProber(
            exchange: scriptedExchange(log: log, handler: { request in
                if request.url.contains(".well-known") {
                    return probeResponse(status: 404, headers: [:], body: "")
                }
                if request.method == .get {
                    return probeResponse(status: 401, headers: [:], body: graphqlBody)
                }
                return probeResponse(status: 404, headers: [:], body: "")
            }),
            discovery: .unavailable,
            oauth: .unavailable,
            secrets: .unavailable
        )
        let verdict = await prober.shapeProbe(
            endpoint: "https://h/api/mcp", headers: [:], query: [], options: probeOptions()
        )
        #expect(verdict.isAuthRequired == true)
        #expect(log.requests.count == 3)
    }

    @Test("discover consults metadata on a challengeless 401")
    func metadataThroughDiscover() async {
        let matching = makeProber(
            exchange: scriptedExchange(log: RequestLog(), handler: { request in
                if request.url.contains(".well-known") {
                    return probeResponse(
                        status: 200,
                        headers: ["content-type": "application/json"],
                        body: #"{"resource":"https://h/api","authorization_servers":["https://auth"]}"#
                    )
                }
                if request.body == MCPUpstreamProber.discoverBody {
                    return probeResponse(status: 401, headers: [:], body: graphqlBody)
                }
                return probeResponse(status: 200, headers: ["content-type": "text/html"], body: "<html/>")
            }),
            discovery: .unavailable,
            oauth: .unavailable,
            secrets: .unavailable
        )
        #expect(await matching.shapeProbe(
            endpoint: "https://h/api/mcp", headers: [:], query: [], options: probeOptions()
        ) == .mcp(requiresAuth: true))
        let missing = makeProber(
            exchange: scriptedExchange(log: RequestLog(), handler: { request in
                if request.url.contains(".well-known") {
                    return probeResponse(status: 404, headers: [:], body: "")
                }
                if request.body == MCPUpstreamProber.discoverBody {
                    return probeResponse(status: 401, headers: [:], body: graphqlBody)
                }
                return probeResponse(status: 200, headers: ["content-type": "text/html"], body: "<html/>")
            }),
            discovery: .unavailable,
            oauth: .unavailable,
            secrets: .unavailable
        )
        let verdict = await missing.shapeProbe(
            endpoint: "https://h/api/mcp", headers: [:], query: [], options: probeOptions()
        )
        #expect(verdict.isAuthRequired == true)
    }

    @Test("metadata upgrade flows end to end through a 401 without challenge")
    func metadataEndToEnd() async {
        let log = RequestLog()
        let prober = makeProber(
            exchange: scriptedExchange(log: log, handler: { request in
                if request.url.contains(".well-known") {
                    return probeResponse(
                        status: 200,
                        headers: ["content-type": "application/json"],
                        body: #"{"resource":"https://h/api","authorization_servers":["https://auth"]}"#
                    )
                }
                return probeResponse(status: 401, headers: [:], body: graphqlBody)
            }),
            discovery: .unavailable,
            oauth: .unavailable,
            secrets: .unavailable
        )
        let verdict = await prober.shapeProbe(
            endpoint: "https://h/api/mcp", headers: [:], query: [], options: probeOptions()
        )
        #expect(verdict == .mcp(requiresAuth: true))
        #expect(log.requests.count == 2)
    }

    // MARK: - Remote probe flow

    @Test("empty pastes fail before any seam runs")
    func probeRemoteEmpty() async {
        let log = RequestLog()
        let prober = makeProber(
            exchange: scriptedExchange(log: log, handler: { _ in
                probeResponse(status: 200, headers: [:], body: jsonRPCResult)
            }),
            discovery: MCPProbeDiscovery(run: { _, _ in
                MCPDiscoveredManifest(toolCount: 1, serverName: nil, instructions: nil)
            }),
            oauth: .unavailable,
            secrets: .unavailable
        )
        for paste in ["", "   \n  "] {
            let result = await prober.probeRemote(
                endpoint: paste, headers: [:], queryParams: [:], auth: .none, options: probeOptions()
            )
            #expect(result == .failure(.missingEndpoint))
        }
        #expect(log.requests.isEmpty)
    }

    @Test("overlong and control-bearing pastes fail closed as unreachable")
    func probeRemoteBadPaste() async {
        let log = RequestLog()
        let prober = makeProber(
            exchange: scriptedExchange(log: log, handler: { _ in
                probeResponse(status: 200, headers: [:], body: jsonRPCResult)
            }),
            discovery: .unavailable,
            oauth: .unavailable,
            secrets: .unavailable
        )
        let long = "https://h/" + String(repeating: "a", count: 2_100)
        #expect(await prober.probeRemote(
            endpoint: long, headers: [:], queryParams: [:], auth: .none, options: probeOptions()
        ) == .failure(.endpointFailed(message: MCPProbeMessages.unreachable)))
        #expect(await prober.probeRemote(
            endpoint: "https://h/a\u{07}b", headers: [:], queryParams: [:], auth: .none, options: probeOptions()
        ) == .failure(.endpointFailed(message: MCPProbeMessages.unreachable)))
        #expect(log.requests.isEmpty)
    }

    @Test("discovery success connects with the manifest and the derived slug")
    func probeRemoteDiscovery() async {
        let log = RequestLog()
        let prober = makeProber(
            exchange: scriptedExchange(log: log, handler: { _ in
                probeResponse(status: 500, headers: [:], body: "")
            }),
            discovery: MCPProbeDiscovery(run: { _, _ in
                MCPDiscoveredManifest(toolCount: 7, serverName: "Acme MCP", instructions: "Do things.")
            }),
            oauth: .unavailable,
            secrets: .unavailable
        )
        let result = await prober.probeRemote(
            endpoint: "https://api.example.com/mcp",
            headers: [:],
            queryParams: [:],
            auth: .none,
            options: probeOptions()
        )
        #expect(result == .success(MCPProbeResult(
            connected: true,
            requiresAuthentication: false,
            requiresOAuth: false,
            supportsDynamicRegistration: false,
            name: "Acme MCP",
            slug: "api_example_com",
            toolCount: 7,
            serverName: "Acme MCP",
            instructions: "Do things."
        )))
        #expect(log.requests.isEmpty)
    }

    @Test("discovery without a server name falls back to the hostname")
    func probeRemoteDiscoveryNoName() async {
        let prober = makeProber(
            exchange: scriptedExchange(log: RequestLog(), handler: { _ in
                probeResponse(status: 500, headers: [:], body: "")
            }),
            discovery: MCPProbeDiscovery(run: { _, _ in
                MCPDiscoveredManifest(toolCount: 0, serverName: nil, instructions: nil)
            }),
            oauth: .unavailable,
            secrets: .unavailable
        )
        let result = await prober.probeRemote(
            endpoint: "https://api.example.com/mcp",
            headers: [:],
            queryParams: [:],
            auth: .none,
            options: probeOptions()
        )
        guard case .success(let probe) = result else {
            Issue.record("expected connected probe")
            return
        }
        #expect(probe.name == "api.example.com")
        #expect(probe.toolCount == 0)
    }

    @Test("discovery with a dirty server name falls back to the hostname")
    func probeRemoteDiscoveryDirtyName() async {
        let prober = makeProber(
            exchange: scriptedExchange(log: RequestLog(), handler: { _ in
                probeResponse(status: 500, headers: [:], body: "")
            }),
            discovery: MCPProbeDiscovery(run: { _, _ in
                MCPDiscoveredManifest(toolCount: 3, serverName: "a\u{07}b", instructions: nil)
            }),
            oauth: .unavailable,
            secrets: .unavailable
        )
        let result = await prober.probeRemote(
            endpoint: "https://api.example.com/mcp",
            headers: [:],
            queryParams: [:],
            auth: .none,
            options: probeOptions()
        )
        guard case .success(let probe) = result else {
            Issue.record("expected connected probe")
            return
        }
        #expect(probe.name == "api.example.com")
    }

    @Test("discovery receives the endpoint with its rendered inputs")
    func probeRemoteDiscoveryInputs() async {
        final class DiscoveryLog: @unchecked Sendable {
            private let lock = NSLock()
            private var entries: [(String, MCPProbeRenderedInputs)] = []
            func record(_ endpoint: String, _ inputs: MCPProbeRenderedInputs) {
                lock.lock()
                defer { lock.unlock() }
                entries.append((endpoint, inputs))
            }
            var calls: [(String, MCPProbeRenderedInputs)] {
                lock.lock()
                defer { lock.unlock() }
                return entries
            }
        }
        let seen = DiscoveryLog()
        let prober = makeProber(
            exchange: scriptedExchange(log: RequestLog(), handler: { _ in
                probeResponse(status: 500, headers: [:], body: "")
            }),
            discovery: MCPProbeDiscovery(run: { endpoint, inputs in
                seen.record(endpoint, inputs)
                return MCPDiscoveredManifest(toolCount: 2, serverName: "D", instructions: nil)
            }),
            oauth: .unavailable,
            secrets: MCPProbeSecretResolver(resolve: { _ in "tok" })
        )
        let result = await prober.probeRemote(
            endpoint: "https://api.example.com/mcp",
            headers: ["X-Key": .secret(testSelector(), prefix: "Bearer "), "X-Plain": .literal("v")],
            queryParams: ["q": .secret(testSelector(), prefix: nil)],
            auth: .none,
            options: probeOptions()
        )
        guard case .success = result else {
            Issue.record("expected connected probe")
            return
        }
        #expect(seen.calls.count == 1)
        #expect(seen.calls[0].0 == "https://api.example.com/mcp")
        #expect(seen.calls[0].1.headers == ["X-Key": "Bearer tok", "X-Plain": "v"])
        #expect(seen.calls[0].1 == MCPProbeRenderedInputs(
            headers: ["X-Key": "Bearer tok", "X-Plain": "v"],
            query: [(key: "q", value: "tok")]
        ))
    }

    @Test("undialable pastes fail closed before any seam runs")
    func probeRemoteUndialable() async {
        let log = RequestLog()
        let prober = makeProber(
            exchange: scriptedExchange(log: log, handler: { _ in
                probeResponse(status: 200, headers: ["content-type": "application/json"], body: jsonRPCResult)
            }),
            discovery: MCPProbeDiscovery(run: { _, _ in
                MCPDiscoveredManifest(toolCount: 1, serverName: nil, instructions: nil)
            }),
            oauth: MCPProbeOAuth(run: { _ in MCPProbeOAuthSignal(supportsDynamicRegistration: true) }),
            secrets: MCPProbeSecretResolver(resolve: { _ in "tok" })
        )
        for paste in [
            "file://host/etc/passwd",
            "file:///etc/passwd",
            "ftp://h/x",
            "javascript:alert(1)",
            "notaurl",
            "//h/x",
            "http://",
        ] {
            let result = await prober.probeRemote(
                endpoint: paste,
                headers: ["X-Key": .secret(testSelector(), prefix: nil)],
                queryParams: [:],
                auth: .none,
                options: probeOptions()
            )
            #expect(result == .failure(.endpointFailed(message: MCPProbeMessages.unreachable)))
        }
        #expect(log.requests.isEmpty)
    }

    @Test("internal hosts, ports, and userinfo stay probeable by design")
    func probeRemoteIntranetTargets() async {
        let log = RequestLog()
        let prober = makeProber(
            exchange: scriptedExchange(log: log, handler: { _ in
                probeResponse(status: 200, headers: ["content-type": "application/json"], body: jsonRPCResult)
            }),
            discovery: .unavailable,
            oauth: .unavailable,
            secrets: .unavailable
        )
        for endpoint in [
            "http://127.0.0.1:9/mcp",
            "http://[::1]/mcp",
            "http://169.254.169.254/mcp",
            "http://intranet:8080/mcp",
            "https://u:p@h/mcp",
        ] {
            let result = await prober.probeRemote(
                endpoint: endpoint, headers: [:], queryParams: [:], auth: .none, options: probeOptions()
            )
            #expect(result == .failure(.undiscoverable(message: MCPProbeMessages.undiscoverable)))
        }
        #expect(log.requests.count == 5)
        #expect(log.requests[4].url == "https://u:p@h/mcp")
    }

    @Test("unreachable and wrong-shape verdicts fail with fixed messages")
    func probeRemoteFailures() async {
        let down = makeProber(
            exchange: scriptedExchange(log: RequestLog(), handler: { _ in throw MCPProbeSeamError.timeout }),
            discovery: .unavailable,
            oauth: .unavailable,
            secrets: .unavailable
        )
        #expect(await down.probeRemote(
            endpoint: probeEndpoint, headers: [:], queryParams: [:], auth: .none, options: probeOptions()
        ) == .failure(.endpointFailed(message: MCPProbeMessages.unreachable)))
        let html = makeProber(
            exchange: scriptedExchange(log: RequestLog(), handler: { _ in
                probeResponse(status: 200, headers: ["content-type": "text/html"], body: "<html/>")
            }),
            discovery: .unavailable,
            oauth: .unavailable,
            secrets: .unavailable
        )
        #expect(await html.probeRemote(
            endpoint: probeEndpoint, headers: [:], queryParams: [:], auth: .none, options: probeOptions()
        ) == .failure(.endpointFailed(message: MCPProbeMessages.notMCP)))
        #expect(await html.probeRemote(
            endpoint: "notaurl", headers: [:], queryParams: [:], auth: .none, options: probeOptions()
        ) == .failure(.endpointFailed(message: MCPProbeMessages.unreachable)))
    }

    @Test("auth-required verdicts report manual auth without OAuth")
    func probeRemoteManualAuth() async {
        let log = RequestLog()
        let prober = makeProber(
            exchange: scriptedExchange(log: log, handler: { _ in
                probeResponse(status: 401, headers: [:], body: graphqlBody)
            }),
            discovery: .unavailable,
            oauth: .unavailable,
            secrets: .unavailable
        )
        let result = await prober.probeRemote(
            endpoint: probeEndpoint, headers: [:], queryParams: [:], auth: .none, options: probeOptions()
        )
        #expect(result == .success(MCPProbeResult(
            connected: false,
            requiresAuthentication: true,
            requiresOAuth: false,
            supportsDynamicRegistration: false,
            name: "mcp.example.com",
            slug: "mcp_example_com",
            toolCount: nil,
            serverName: nil,
            instructions: nil
        )))
    }

    @Test("MCP+auth with OAuth metadata reports the OAuth fork")
    func probeRemoteOAuth() async {
        let prober = makeProber(
            exchange: scriptedExchange(log: RequestLog(), handler: { _ in
                probeResponse(status: 401, headers: ["WWW-Authenticate": "Bearer"], body: jsonRPCRemoteError)
            }),
            discovery: .unavailable,
            oauth: MCPProbeOAuth(run: { _ in MCPProbeOAuthSignal(supportsDynamicRegistration: true) }),
            secrets: .unavailable
        )
        let result = await prober.probeRemote(
            endpoint: probeEndpoint, headers: [:], queryParams: [:], auth: .none, options: probeOptions()
        )
        guard case .success(let probe) = result else {
            Issue.record("expected OAuth probe")
            return
        }
        #expect(probe.requiresOAuth == true)
        #expect(probe.supportsDynamicRegistration == true)
        #expect(probe.requiresAuthentication == true)
        #expect(probe.connected == false)
    }

    @Test("MCP+auth without OAuth metadata reports manual auth")
    func probeRemoteManualAfterOAuthMiss() async {
        let prober = makeProber(
            exchange: scriptedExchange(log: RequestLog(), handler: { _ in
                probeResponse(status: 401, headers: ["WWW-Authenticate": "Bearer"], body: jsonRPCRemoteError)
            }),
            discovery: .unavailable,
            oauth: .unavailable,
            secrets: .unavailable
        )
        let result = await prober.probeRemote(
            endpoint: probeEndpoint, headers: [:], queryParams: [:], auth: .none, options: probeOptions()
        )
        guard case .success(let probe) = result else {
            Issue.record("expected manual-auth probe")
            return
        }
        #expect(probe.requiresAuthentication == true)
        #expect(probe.requiresOAuth == false)
    }

    @Test("MCP without auth and without discovery fails as undiscoverable")
    func probeRemoteUndiscoverable() async {
        let prober = makeProber(
            exchange: scriptedExchange(log: RequestLog(), handler: { _ in
                probeResponse(status: 200, headers: ["content-type": "application/json"], body: jsonRPCResult)
            }),
            discovery: .unavailable,
            oauth: .unavailable,
            secrets: .unavailable
        )
        #expect(await prober.probeRemote(
            endpoint: probeEndpoint, headers: [:], queryParams: [:], auth: .none, options: probeOptions()
        ) == .failure(.undiscoverable(message: MCPProbeMessages.undiscoverable)))
    }

    @Test("MCP without auth but with OAuth metadata still reports the OAuth fork")
    func probeRemoteOAuthWithoutChallenge() async {
        let prober = makeProber(
            exchange: scriptedExchange(log: RequestLog(), handler: { _ in
                probeResponse(status: 200, headers: ["content-type": "application/json"], body: jsonRPCResult)
            }),
            discovery: .unavailable,
            oauth: MCPProbeOAuth(run: { _ in MCPProbeOAuthSignal(supportsDynamicRegistration: false) }),
            secrets: .unavailable
        )
        let result = await prober.probeRemote(
            endpoint: probeEndpoint, headers: [:], queryParams: [:], auth: .none, options: probeOptions()
        )
        guard case .success(let probe) = result else {
            Issue.record("expected OAuth probe")
            return
        }
        #expect(probe.requiresOAuth == true)
        #expect(probe.supportsDynamicRegistration == false)
    }

    @Test("unresolved declared secrets fail the probe before any request")
    func probeRemoteUnresolvedSecrets() async {
        let log = RequestLog()
        let prober = makeProber(
            exchange: scriptedExchange(log: log, handler: { _ in
                probeResponse(status: 200, headers: [:], body: jsonRPCResult)
            }),
            discovery: .unavailable,
            oauth: .unavailable,
            secrets: .unavailable
        )
        #expect(await prober.probeRemote(
            endpoint: probeEndpoint,
            headers: ["X-Key": .secret(testSelector(), prefix: nil)],
            queryParams: [:],
            auth: .none,
            options: probeOptions()
        ) == .failure(.unresolvedSecret(label: "X-Key")))
        #expect(await prober.probeRemote(
            endpoint: probeEndpoint,
            headers: [:],
            queryParams: [:],
            auth: .header(headerName: "Authorization", secret: testSelector(), prefix: nil),
            options: probeOptions()
        ) == .failure(.unresolvedSecret(label: "auth")))
        #expect(log.requests.isEmpty)
    }

    @Test("resolved secrets and literals ride the wire; oauth2 adds nothing")
    func probeRemoteResolvedSecrets() async {
        let log = RequestLog()
        let prober = makeProber(
            exchange: scriptedExchange(log: log, handler: { _ in
                probeResponse(status: 200, headers: ["content-type": "application/json"], body: jsonRPCResult)
            }),
            discovery: .unavailable,
            oauth: .unavailable,
            secrets: MCPProbeSecretResolver(resolve: { _ in "tok" })
        )
        let result = await prober.probeRemote(
            endpoint: probeEndpoint,
            headers: ["X-Key": .secret(testSelector(), prefix: "Bearer "), "X-Plain": .literal("v")],
            queryParams: ["q": .secret(testSelector(), prefix: nil)],
            auth: .oauth2(connectionId: "x.y.z"),
            options: probeOptions()
        )
        guard case .failure(let error) = result else {
            Issue.record("expected undiscoverable")
            return
        }
        #expect(error == .undiscoverable(message: MCPProbeMessages.undiscoverable))
        #expect(log.requests.count == 1)
        #expect(log.requests[0].headers["X-Key"] == "Bearer tok")
        #expect(log.requests[0].headers["X-Plain"] == "v")
        #expect(log.requests[0].url == probeEndpoint + "?q=tok")
    }

    @Test("concurrent probes stay isolated and correct")
    func probeRemoteConcurrent() async {
        let prober = makeProber(
            exchange: scriptedExchange(log: RequestLog(), handler: { request in
                if request.url.contains("good") {
                    return probeResponse(status: 200, headers: ["content-type": "application/json"], body: jsonRPCResult)
                }
                return probeResponse(status: 200, headers: ["content-type": "text/html"], body: "<html/>")
            }),
            discovery: .unavailable,
            oauth: .unavailable,
            secrets: .unavailable
        )
        await withTaskGroup(of: Bool.self) { group in
            for index in 0..<20 {
                group.addTask {
                    let endpoint = index % 2 == 0 ? "https://good-\(index).example/mcp" : "https://bad-\(index).example/"
                    let result = await prober.probeRemote(
                        endpoint: endpoint, headers: [:], queryParams: [:], auth: .none, options: probeOptions()
                    )
                    switch result {
                    case .failure(.undiscoverable):
                        return index % 2 == 0
                    case .failure(.endpointFailed):
                        return index % 2 == 1
                    case .success, .failure:
                        return false
                    }
                }
            }
            for await ok in group {
                #expect(ok)
            }
        }
    }

    // MARK: - Stdio probe flow

    @Test("stdio probe connects undiscovered when the spawn surface checks out")
    func probeStdioUndiscovered() async throws {
        let config = try makeStdio(
            name: "Echo", command: "/bin/echo", args: ["hi"], env: ["LANG": "C"], cwd: "/tmp", namespace: nil
        )
        guard case .stdio(let stdio) = config else {
            Issue.record("expected stdio config")
            return
        }
        let server = MCPUpstreamStdioServer(config: stdio)
        let log = RequestLog()
        let prober = makeProber(
            exchange: scriptedExchange(log: log, handler: { _ in probeResponse(status: 500, headers: [:], body: "") }),
            discovery: .unavailable,
            oauth: .unavailable,
            secrets: .unavailable
        )
        let result = await prober.probeStdio(
            server: server, hostEnvironment: [:], spawn: .executableCheck
        )
        #expect(result == .success(MCPProbeResult(
            connected: true,
            requiresAuthentication: false,
            requiresOAuth: false,
            supportsDynamicRegistration: false,
            name: "Echo",
            slug: "echo",
            toolCount: nil,
            serverName: nil,
            instructions: nil
        )))
    }

    @Test("stdio probe surfaces discovered manifests")
    func probeStdioDiscovered() async throws {
        let config = try makeStdio(
            name: "Echo", command: "/bin/echo", args: nil, env: nil, cwd: nil, namespace: "echo"
        )
        guard case .stdio(let stdio) = config else {
            Issue.record("expected stdio config")
            return
        }
        let server = MCPUpstreamStdioServer(config: stdio)
        let prober = makeProber(
            exchange: scriptedExchange(log: RequestLog(), handler: { _ in probeResponse(status: 500, headers: [:], body: "") }),
            discovery: .unavailable,
            oauth: .unavailable,
            secrets: .unavailable
        )
        let result = await prober.probeStdio(
            server: server,
            hostEnvironment: [:],
            spawn: MCPProbeStdioSpawn(run: { _ in
                MCPDiscoveredManifest(toolCount: 4, serverName: "Echo Server", instructions: "Echoes.")
            })
        )
        #expect(result == .success(MCPProbeResult(
            connected: true,
            requiresAuthentication: false,
            requiresOAuth: false,
            supportsDynamicRegistration: false,
            name: "Echo Server",
            slug: "echo",
            toolCount: 4,
            serverName: "Echo Server",
            instructions: "Echoes."
        )))
    }

    @Test("stdio probe fails closed when the command cannot start")
    func probeStdioStartFailure() async throws {
        let missing = try makeStdio(
            name: "Missing", command: "/nonexistent-tool-xyz", args: nil, env: nil, cwd: nil, namespace: nil
        )
        guard case .stdio(let stdio) = missing else {
            Issue.record("expected stdio config")
            return
        }
        let prober = makeProber(
            exchange: scriptedExchange(log: RequestLog(), handler: { _ in probeResponse(status: 500, headers: [:], body: "") }),
            discovery: .unavailable,
            oauth: .unavailable,
            secrets: .unavailable
        )
        #expect(await prober.probeStdio(
            server: MCPUpstreamStdioServer(config: stdio), hostEnvironment: [:], spawn: .executableCheck
        ) == .failure(.stdioStartFailed(message: MCPProbeMessages.stdioStartFailure)))
        let throwing = MCPProbeStdioSpawn(run: { _ in throw MCPProbeSeamError.timeout })
        #expect(await prober.probeStdio(
            server: MCPUpstreamStdioServer(config: stdio), hostEnvironment: [:], spawn: throwing
        ) == .failure(.stdioStartFailed(message: MCPProbeMessages.stdioStartFailure)))
    }

    @Test("stdio probe hands the seam argv elements, chdir, and opaque env")
    func probeStdioSeamContract() async throws {
        let config = try makeStdio(
            name: "Tool",
            command: "/bin/echo",
            args: ["a b", "c;d", "-x"],
            env: ["MARKER": "has secret-public-ref:file/x inside", "PLAIN": "v"],
            cwd: "/tmp",
            namespace: nil
        )
        guard case .stdio(let stdio) = config else {
            Issue.record("expected stdio config")
            return
        }
        var seen: MCPUpstreamSpawnSpec?
        let box = SpawnBox()
        let prober = makeProber(
            exchange: scriptedExchange(log: RequestLog(), handler: { _ in probeResponse(status: 500, headers: [:], body: "") }),
            discovery: .unavailable,
            oauth: .unavailable,
            secrets: .unavailable
        )
        _ = await prober.probeStdio(
            server: MCPUpstreamStdioServer(config: stdio),
            hostEnvironment: ["HTTP_PROXY": "http://proxy:8080", "EVIL": "nope"],
            spawn: MCPProbeStdioSpawn(run: { spec in
                box.store(spec)
                return nil
            })
        )
        seen = box.value
        guard let spec = seen else {
            Issue.record("expected the seam to run")
            return
        }
        #expect(spec.executablePath == "/bin/echo")
        #expect(spec.arguments == ["a b", "c;d", "-x"])
        #expect(spec.workingDirectory == "/tmp")
        #expect(spec.environment["MARKER"] == "has secret-public-ref:file/x inside")
        #expect(spec.environment["HTTP_PROXY"] == "http://proxy:8080")
        #expect(spec.environment["EVIL"] == nil)
    }

    // MARK: - Spawn spec

    @Test("merged environment layers safe-list, allowlist, and declared-wins")
    func mergedEnvironment() {
        let merged = MCPUpstreamSpawnSpec.mergedEnvironment(
            host: [
                "HTTP_PROXY": "http://proxy:8080",
                "SSL_CERT_FILE": "/ca.pem",
                "SECRET_KEY": "nope",
                "PATH": "/evil",
            ],
            declared: ["SSL_CERT_FILE": "/declared.pem", "TOKEN": "t"]
        )
        #expect(merged["PATH"] == "/usr/bin:/bin")
        #expect(merged["LANG"] == "C")
        #expect(merged["LC_ALL"] == "C")
        #expect(merged["HTTP_PROXY"] == "http://proxy:8080")
        #expect(merged["SSL_CERT_FILE"] == "/declared.pem")
        #expect(merged["TOKEN"] == "t")
        #expect(merged["SECRET_KEY"] == nil)
        #expect(merged["HTTPS_PROXY"] == nil)
        let bare = MCPUpstreamSpawnSpec.mergedEnvironment(host: [:], declared: nil)
        #expect(bare == MCPStdioProcessSpawn.minimalEnvironment)
        let emptyDeclared = MCPUpstreamSpawnSpec.mergedEnvironment(host: [:], declared: [:])
        #expect(emptyDeclared == MCPStdioProcessSpawn.minimalEnvironment)
    }

    @Test("set-but-empty host values are not inherited")
    func mergedEnvironmentSkipsEmpty() {
        let merged = MCPUpstreamSpawnSpec.mergedEnvironment(
            host: ["HTTP_PROXY": "", "NO_PROXY": "localhost"],
            declared: nil
        )
        #expect(merged["HTTP_PROXY"] == nil)
        #expect(merged["NO_PROXY"] == "localhost")
        #expect(merged["PATH"] == "/usr/bin:/bin")
    }

    @Test("executable checks reject missing, directory, and non-executable paths")
    func executableUsable() throws {
        #expect(MCPUpstreamSpawnSpec(
            executablePath: "/bin/echo", arguments: [], environment: [:], workingDirectory: nil
        ).executableUsable() == true)
        #expect(MCPUpstreamSpawnSpec(
            executablePath: "/nonexistent-tool-xyz", arguments: [], environment: [:], workingDirectory: nil
        ).executableUsable() == false)
        #expect(MCPUpstreamSpawnSpec(
            executablePath: "/tmp", arguments: [], environment: [:], workingDirectory: nil
        ).executableUsable() == false)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rv-probe-\(UUID().uuidString)")
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(MCPUpstreamSpawnSpec(
            executablePath: url.path, arguments: [], environment: [:], workingDirectory: nil
        ).executableUsable() == false)
        try FileManager.default.removeItem(at: url)
    }

    @Test("working-directory checks accept absent and require directories")
    func workingDirectoryUsable() {
        #expect(MCPUpstreamSpawnSpec(
            executablePath: "/bin/echo", arguments: [], environment: [:], workingDirectory: nil
        ).workingDirectoryUsable() == true)
        #expect(MCPUpstreamSpawnSpec(
            executablePath: "/bin/echo", arguments: [], environment: [:], workingDirectory: "/tmp"
        ).workingDirectoryUsable() == true)
        #expect(MCPUpstreamSpawnSpec(
            executablePath: "/bin/echo", arguments: [], environment: [:], workingDirectory: "/nonexistent-dir-xyz"
        ).workingDirectoryUsable() == false)
        #expect(MCPUpstreamSpawnSpec(
            executablePath: "/bin/echo", arguments: [], environment: [:], workingDirectory: "/bin/echo"
        ).workingDirectoryUsable() == false)
    }

    @Test("executable-check seam gates on both surface checks")
    func executableCheckSeam() async throws {
        let ok = MCPUpstreamSpawnSpec(
            executablePath: "/bin/echo", arguments: [], environment: [:], workingDirectory: "/tmp"
        )
        #expect(try await MCPProbeStdioSpawn.executableCheck.run(ok) == nil)
        let badExe = MCPUpstreamSpawnSpec(
            executablePath: "/nonexistent-tool-xyz", arguments: [], environment: [:], workingDirectory: "/tmp"
        )
        await #expect(throws: MCPProbeSeamError.self) {
            try await MCPProbeStdioSpawn.executableCheck.run(badExe)
        }
        let badCwd = MCPUpstreamSpawnSpec(
            executablePath: "/bin/echo", arguments: [], environment: [:], workingDirectory: "/nonexistent-dir-xyz"
        )
        await #expect(throws: MCPProbeSeamError.self) {
            try await MCPProbeStdioSpawn.executableCheck.run(badCwd)
        }
    }

    // MARK: - Servers

    @Test("remote servers resolve namespaces and transport candidates")
    func remoteServer() async throws {
        let explicit = try makeRemote(
            name: "GitHub", endpoint: "https://api.github.com/mcp", transport: .sse, namespace: "gh"
        )
        guard case .remote(let remote) = explicit else {
            Issue.record("expected remote config")
            return
        }
        let server = MCPUpstreamRemoteServer(config: remote)
        #expect(server.namespace == "gh")
        #expect(server.transportCandidates == [.sse])
        let derived = try makeRemote(
            name: "GitHub", endpoint: "https://api.github.com/mcp", transport: .auto, namespace: nil
        )
        guard case .remote(let auto) = derived else {
            Issue.record("expected remote config")
            return
        }
        #expect(MCPUpstreamRemoteServer(config: auto).namespace == "github")
        #expect(MCPUpstreamRemoteServer(config: auto).transportCandidates == [.streamableHTTP, .sse])
        let pinned = try makeRemote(
            name: "GitHub", endpoint: "https://api.github.com/mcp", transport: .streamableHttp, namespace: nil
        )
        guard case .remote(let modern) = pinned else {
            Issue.record("expected remote config")
            return
        }
        #expect(MCPUpstreamRemoteServer(config: modern).transportCandidates == [.streamableHTTP])
        #expect(server.toolAddress(owner: "o", connection: "c", tool: "t")?.literal == "tools.gh.o.c.t")
    }

    @Test("stdio servers build exact spawn specs")
    func stdioServer() async throws {
        let config = try makeStdio(
            name: "Tool", command: "/bin/echo", args: ["a"], env: ["K": "V"], cwd: "/tmp", namespace: "tool"
        )
        guard case .stdio(let stdio) = config else {
            Issue.record("expected stdio config")
            return
        }
        let server = MCPUpstreamStdioServer(config: stdio)
        #expect(server.namespace == "tool")
        #expect(server.transportCandidates == [.stdio])
        let spec = server.spawnSpec(hostEnvironment: ["HTTP_PROXY": "p", "NOPE": "n"])
        #expect(spec.executablePath == "/bin/echo")
        #expect(spec.arguments == ["a"])
        #expect(spec.workingDirectory == "/tmp")
        #expect(spec.environment["K"] == "V")
        #expect(spec.environment["HTTP_PROXY"] == "p")
        #expect(spec.environment["NOPE"] == nil)
        let bare = try makeStdio(
            name: "Bare", command: "/bin/echo", args: nil, env: nil, cwd: nil, namespace: nil
        )
        guard case .stdio(let bareStdio) = bare else {
            Issue.record("expected stdio config")
            return
        }
        let bareSpec = MCPUpstreamStdioServer(config: bareStdio).spawnSpec(hostEnvironment: [:])
        #expect(bareSpec.arguments == [])
        #expect(bareSpec.workingDirectory == nil)
        #expect(bareSpec.environment == MCPStdioProcessSpawn.minimalEnvironment)
        #expect(server.toolAddress(owner: "o", connection: "c", tool: "t")?.literal == "tools.tool.o.c.t")
    }

    @Test("upstream servers forward config, namespace, candidates, and addresses")
    func upstreamServer() async throws {
        let remote = MCPUpstreamServer(try makeRemote(
            name: "R", endpoint: "https://h/mcp", transport: .sse, namespace: "r"
        ))
        #expect(remote.namespace == "r")
        #expect(remote.transportCandidates == [.sse])
        #expect(remote.toolAddress(owner: "o", connection: "c", tool: "t")?.literal == "tools.r.o.c.t")
        guard case .remote(let remoteConfig) = remote.config else {
            Issue.record("expected remote config")
            return
        }
        #expect(remoteConfig.namespace == "r")
        let stdio = MCPUpstreamServer(try makeStdio(
            name: "S", command: "/bin/echo", args: nil, env: nil, cwd: nil, namespace: "s"
        ))
        #expect(stdio.namespace == "s")
        #expect(stdio.transportCandidates == [.stdio])
        #expect(stdio.toolAddress(owner: "o", connection: "c", tool: "t")?.literal == "tools.s.o.c.t")
        guard case .stdio(let stdioConfig) = stdio.config else {
            Issue.record("expected stdio config")
            return
        }
        #expect(stdioConfig.namespace == "s")
    }

    // MARK: - Renderer watch

    @Test("renderable namespaces are dot-free clean segments")
    func renderableNamespace() {
        #expect(MCPUpstreamToolLiteral.renderable(namespace: "github") == true)
        #expect(MCPUpstreamToolLiteral.renderable(namespace: "a-b_c9") == true)
        #expect(MCPUpstreamToolLiteral.renderable(namespace: "") == false)
        #expect(MCPUpstreamToolLiteral.renderable(namespace: String(repeating: "a", count: 129)) == false)
        #expect(MCPUpstreamToolLiteral.renderable(namespace: "a.b") == false)
        #expect(MCPUpstreamToolLiteral.renderable(namespace: "a b") == false)
        #expect(MCPUpstreamToolLiteral.renderable(namespace: "a\nb") == false)
        #expect(MCPUpstreamToolLiteral.renderable(namespace: "a\u{01}b") == false)
        #expect(MCPUpstreamToolLiteral.renderable(namespace: "a\u{7F}b") == false)
        #expect(MCPUpstreamToolLiteral.renderable(namespace: "a\u{80}b") == false)
        #expect(MCPUpstreamToolLiteral.renderable(namespace: "a\u{200D}b") == false)
    }

    @Test("address rendering refuses dotted namespaces before interpolating")
    func toolAddressWatch() {
        #expect(MCPUpstreamToolLiteral.address(
            namespace: "gh", owner: "o", connection: "c", tool: "t.u"
        )?.literal == "tools.gh.o.c.t.u")
        #expect(MCPUpstreamToolLiteral.address(
            namespace: "g.h", owner: "o", connection: "c", tool: "t"
        ) == nil)
        #expect(MCPUpstreamToolLiteral.address(
            namespace: "gh", owner: "o.o", connection: "c", tool: "t"
        ) == nil)
        #expect(MCPUpstreamToolLiteral.address(
            namespace: "", owner: "o", connection: "c", tool: "t"
        ) == nil)
    }

    // MARK: - Registry

    @Test("registration keys servers by resolved namespace")
    func registryRegister() async throws {
        let registry = MCPUpstreamRegistry()
        let remote = try makeRemote(
            name: "GitHub", endpoint: "https://api.github.com/mcp", transport: .auto, namespace: nil
        )
        try await registry.register(remote)
        let stdio = try makeStdio(
            name: "Echo", command: "/bin/echo", args: nil, env: nil, cwd: nil, namespace: nil
        )
        try await registry.register(stdio)
        #expect(await registry.namespaces() == ["echo", "github"])
        #expect(await registry.server(namespace: "github")?.namespace == "github")
        #expect(await registry.server(namespace: "missing") == nil)
        #expect(await registry.unrenderableNamespaces() == [])
    }

    @Test("registration rejects taken namespaces without clobbering")
    func registryDuplicate() async throws {
        let registry = MCPUpstreamRegistry()
        let first = try makeRemote(
            name: "GitHub", endpoint: "https://a.example/mcp", transport: .auto, namespace: nil
        )
        try await registry.register(first)
        let derivedCollision = try makeRemote(
            name: "GitHub", endpoint: "https://b.example/mcp", transport: .sse, namespace: nil
        )
        await #expect(throws: MCPUpstreamRegistryError.self) {
            try await registry.register(derivedCollision)
        }
        let explicitCollision = try makeStdio(
            name: "Other", command: "/bin/echo", args: nil, env: nil, cwd: nil, namespace: "github"
        )
        await #expect(throws: MCPUpstreamRegistryError.self) {
            try await registry.register(explicitCollision)
        }
        #expect(await registry.namespaces() == ["github"])
        let stored = try await registry.server(for: first)
        #expect(stored.config == first)
    }

    @Test("set registration is atomic across existing and within-set duplicates")
    func registryRegisterAll() async throws {
        let registry = MCPUpstreamRegistry()
        let first = try makeRemote(
            name: "A", endpoint: "https://a.example/mcp", transport: .auto, namespace: nil
        )
        try await registry.register(first)
        let againstExisting = MCPIntegrationSet(integrations: [
            try makeRemote(name: "B", endpoint: "https://b.example/mcp", transport: .auto, namespace: nil),
            try makeRemote(name: "A", endpoint: "https://a2.example/mcp", transport: .auto, namespace: nil),
        ])
        await #expect(throws: MCPUpstreamRegistryError.self) {
            try await registry.registerAll(againstExisting)
        }
        #expect(await registry.namespaces() == ["a"])
        let withinSet = MCPIntegrationSet(integrations: [
            try makeRemote(name: "C", endpoint: "https://c.example/mcp", transport: .auto, namespace: nil),
            try makeRemote(name: "C", endpoint: "https://c2.example/mcp", transport: .auto, namespace: nil),
        ])
        await #expect(throws: MCPUpstreamRegistryError.self) {
            try await registry.registerAll(withinSet)
        }
        #expect(await registry.namespaces() == ["a"])
        let clean = MCPIntegrationSet(integrations: [
            try makeRemote(name: "B", endpoint: "https://b.example/mcp", transport: .auto, namespace: nil),
            try makeStdio(name: "D", command: "/bin/echo", args: nil, env: nil, cwd: nil, namespace: nil),
        ])
        try await registry.registerAll(clean)
        #expect(await registry.namespaces() == ["a", "b", "d"])
        try await registry.registerAll(MCPIntegrationSet(integrations: []))
        #expect(await registry.namespaces() == ["a", "b", "d"])
    }

    @Test("convenience init registers a set or throws atomically")
    func registryInitRegistering() async throws {
        let clean = MCPIntegrationSet(integrations: [
            try makeRemote(name: "A", endpoint: "https://a.example/mcp", transport: .auto, namespace: nil),
        ])
        let registry = try MCPUpstreamRegistry(registering: clean)
        #expect(await registry.namespaces() == ["a"])
        let dirty = MCPIntegrationSet(integrations: [
            try makeRemote(name: "A", endpoint: "https://a.example/mcp", transport: .auto, namespace: nil),
            try makeRemote(name: "A", endpoint: "https://a2.example/mcp", transport: .auto, namespace: nil),
        ])
        #expect(throws: MCPUpstreamRegistryError.self) {
            try MCPUpstreamRegistry(registering: dirty)
        }
    }

    @Test("lookup by config rejects unknown namespaces and drifted configs")
    func registryDrift() async throws {
        let registry = MCPUpstreamRegistry()
        let registered = try makeRemote(
            name: "GitHub", endpoint: "https://a.example/mcp", transport: .auto, namespace: nil
        )
        try await registry.register(registered)
        let unknown = try makeRemote(
            name: "Other", endpoint: "https://o.example/mcp", transport: .auto, namespace: nil
        )
        await #expect(throws: MCPUpstreamRegistryError.self) {
            try await registry.server(for: unknown)
        }
        let driftedEndpoint = try makeRemote(
            name: "GitHub", endpoint: "https://b.example/mcp", transport: .auto, namespace: nil
        )
        await #expect(throws: MCPUpstreamRegistryError.self) {
            try await registry.server(for: driftedEndpoint)
        }
        let driftedTransport = try makeRemote(
            name: "GitHub", endpoint: "https://a.example/mcp", transport: .sse, namespace: nil
        )
        await #expect(throws: MCPUpstreamRegistryError.self) {
            try await registry.server(for: driftedTransport)
        }
        let driftedKind = try makeStdio(
            name: "GitHub", command: "/bin/echo", args: nil, env: nil, cwd: nil, namespace: "github"
        )
        await #expect(throws: MCPUpstreamRegistryError.self) {
            try await registry.server(for: driftedKind)
        }
        let driftedHeaders = try MCPIntegrationConfig.remote(MCPRemoteIntegration(
            name: "GitHub",
            endpoint: "https://a.example/mcp",
            headers: ["X-Extra": .literal("v")]
        ))
        await #expect(throws: MCPUpstreamRegistryError.self) {
            try await registry.server(for: driftedHeaders)
        }
        let driftedAuth = try MCPIntegrationConfig.remote(MCPRemoteIntegration(
            name: "GitHub",
            endpoint: "https://a.example/mcp",
            auth: .header(headerName: "Authorization", secret: testSelector(), prefix: nil)
        ))
        await #expect(throws: MCPUpstreamRegistryError.self) {
            try await registry.server(for: driftedAuth)
        }
        #expect(try await registry.server(for: registered).config == registered)
    }

    @Test("the watch lists dotted namespaces and only those")
    func registryWatch() async throws {
        let registry = MCPUpstreamRegistry()
        try await registry.register(makeRemote(
            name: "Clean", endpoint: "https://c.example/mcp", transport: .auto, namespace: "clean"
        ))
        try await registry.register(makeRemote(
            name: "Dotted One", endpoint: "https://d.example/mcp", transport: .auto, namespace: "dot.ted"
        ))
        try await registry.register(makeStdio(
            name: "Also Dotted", command: "/bin/echo", args: nil, env: nil, cwd: nil, namespace: "a.b.c"
        ))
        #expect(await registry.unrenderableNamespaces() == ["a.b.c", "dot.ted"])
        #expect(await registry.server(namespace: "dot.ted")?.toolAddress(
            owner: "o", connection: "c", tool: "t"
        ) == nil)
    }

    @Test("registry accepts a set decoded from X1-I document bytes")
    func registryFromDocument() async throws {
        let document = """
            {"version":1,"integrations":[
            {"kind":"mcp-remote","name":"GitHub","endpoint":"https://api.github.com/mcp"},
            {"kind":"mcp-stdio","name":"Echo","command":"/bin/echo","args":["hi"]}
            ]}
            """
        let decoded = MCPIntegrationStore.decode(Data(document.utf8))
        guard case .success(let set) = decoded else {
            Issue.record("expected a decoded set")
            return
        }
        let registry = try MCPUpstreamRegistry(registering: set)
        #expect(await registry.namespaces() == ["echo", "github"])
        #expect(await registry.server(namespace: "github")?.transportCandidates == [.streamableHTTP, .sse])
        #expect(await registry.server(namespace: "echo")?.transportCandidates == [.stdio])
    }

    // MARK: - Probe diagnostics

    @Test("valid documents produce no diagnostics")
    func diagnosticsClean() {
        let document = #"{"version":1,"integrations":[{"kind":"mcp-remote","name":"A","endpoint":"https://a.example/mcp"}]}"#
        #expect(MCPUpstreamRegistry.probeDiagnostics(Data(document.utf8)) == [])
    }

    @Test("field failures surface per-integration labels and messages")
    func diagnosticsFields() {
        let document = #"{"version":1,"integrations":[{"kind":"mcp-remote","name":"A","endpoint":"notaurl"}]}"#
        #expect(MCPUpstreamRegistry.probeDiagnostics(Data(document.utf8)) == [
            MCPUpstreamProbeDiagnostic(
                index: 0,
                reason: "endpoint",
                message: "Integration 0 has an invalid endpoint."
            ),
        ])
        let two = """
            {"version":1,"integrations":[
            {"kind":"mcp-remote","name":"A","endpoint":"https://a.example/mcp"},
            {"kind":"mcp-stdio","name":"B","command":"relative/path"}
            ]}
            """
        #expect(MCPUpstreamRegistry.probeDiagnostics(Data(two.utf8)) == [
            MCPUpstreamProbeDiagnostic(
                index: 1,
                reason: "command",
                message: "Integration 1 has an invalid command."
            ),
        ])
    }

    @Test("document failures surface fixed document messages")
    func diagnosticsDocument() {
        #expect(MCPUpstreamRegistry.probeDiagnostics(Data(repeating: 0, count: 70_000)) == [
            MCPUpstreamProbeDiagnostic(
                index: -1, reason: "oversized", message: "The integrations document exceeds the size limit."
            ),
        ])
        #expect(MCPUpstreamRegistry.probeDiagnostics(Data("{oops".utf8)) == [
            MCPUpstreamProbeDiagnostic(
                index: -1, reason: "invalidDocument", message: "The integrations document is invalid."
            ),
        ])
        #expect(MCPUpstreamRegistry.probeDiagnostics(Data(#"{"version":2,"integrations":[]}"#.utf8)) == [
            MCPUpstreamProbeDiagnostic(
                index: -1,
                reason: "unsupportedVersion",
                message: "The integrations document version is not supported."
            ),
        ])
        let entries = (0..<33).map { index in
            #"{"kind":"mcp-remote","name":"S\#(index)","endpoint":"https://h\#(index).example/mcp"}"#
        }.joined(separator: ",")
        #expect(MCPUpstreamRegistry.probeDiagnostics(
            Data(#"{"version":1,"integrations":[\#(entries)]}"#.utf8)
        ) == [
            MCPUpstreamProbeDiagnostic(
                index: -1,
                reason: "tooManyIntegrations",
                message: "The integrations document holds too many integrations."
            ),
        ])
    }
}

private final class SpawnBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: MCPUpstreamSpawnSpec?

    func store(_ spec: MCPUpstreamSpawnSpec) {
        lock.lock()
        defer { lock.unlock() }
        stored = spec
    }

    var value: MCPUpstreamSpawnSpec? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private extension MCPProbeVerdict {
    var isWrongShape: Bool {
        if case .notMCP(let category, _) = self, category == .wrongShape {
            return true
        }
        return false
    }

    var isAuthRequired: Bool {
        if case .notMCP(let category, _) = self, category == .authRequired {
            return true
        }
        return false
    }
}
