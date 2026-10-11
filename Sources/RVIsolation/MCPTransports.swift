import Foundation
import RVDomain

// MARK: - Session binding

/// Opaque MCP transport session id. Rendered as a UUID string on the wire.
public struct MCPSessionID: Hashable, Sendable, Equatable, Codable {
    /// Minted identifier value.
    public var rawValue: UUID

    /// Mints a fresh session id.
    public init() {
        rawValue = UUID()
    }

    /// Names an id RV already minted. Naming one grants nothing.
    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

/// One bindable MCP resource: the connection segment an HTTP session locks to.
///
/// A session binds exactly one resource at registration; every request on
/// that session must name the same resource or the edge answers 403
/// (REQ-013). Resource names are operator labels, never secret material.
public struct MCPResourceID: Hashable, Sendable, Equatable, Codable {
    /// Operator connection label. Non-empty, dot-free, at most 128 chars.
    public var rawValue: String

    /// Validates the label. Anything else fails closed to nil.
    public init?(rawValue: String) {
        guard rawValue.isEmpty == false,
            rawValue.count <= 128,
            rawValue.contains(".") == false,
            rawValue.contains(where: { $0.isWhitespace || $0.isNewline }) == false
        else {
            return nil
        }
        self.rawValue = rawValue
    }
}

/// Loopback caller credential. Authenticates WHO calls, complementing the
/// session binding, which only checks WHICH resource is named (plan risk:
/// resource binding alone is not authentication).
///
/// The token never appears in logs: `description` is a fixed placeholder,
/// and every log seam redacts the `Authorization` header that carries it.
public struct MCPCallerToken: Hashable, Sendable, Equatable, Codable {
    /// Opaque bearer value. Unforgeable 122-bit randomness; never logged.
    public var rawValue: String

    /// Wraps a minted token value.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Mints a fresh unguessable token.
    public static func random() -> MCPCallerToken {
        MCPCallerToken(rawValue: UUID().uuidString + "-" + UUID().uuidString)
    }
}

extension MCPCallerToken: CustomStringConvertible {
    /// Fixed placeholder: interpolating a token never leaks the bearer.
    public var description: String {
        "[redacted-caller-token]"
    }
}

/// One bound transport session: identity, locked resource, caller token.
public struct MCPTransportSession: Hashable, Sendable, Equatable {
    /// Session identity presented on every request.
    public var id: MCPSessionID
    /// The single resource this session may touch.
    public var resource: MCPResourceID
    /// Caller credential presented beside the session id.
    public var callerToken: MCPCallerToken
    /// Transport this session speaks.
    public var kind: MCPTransportKind

    /// Binds one session to one resource with its caller token.
    public init(id: MCPSessionID, resource: MCPResourceID, callerToken: MCPCallerToken, kind: MCPTransportKind) {
        self.id = id
        self.resource = resource
        self.callerToken = callerToken
        self.kind = kind
    }

    /// True when the request names this session's bound resource.
    public func binds(_ resource: MCPResourceID) -> Bool {
        resource == self.resource
    }
}

/// Transports the scoped invoker speaks (REQ-013).
public enum MCPTransportKind: String, Hashable, Sendable, Equatable, Codable {
    /// Single-server newline-delimited JSON over pipes.
    case stdio
    /// Per-session loopback HTTP with SSE elicitation.
    case streamableHTTP = "streamable-http"
}

// MARK: - HTTP shapes

/// Closed HTTP verb vocabulary for the loopback transport.
public enum MCPHTTPMethod: String, Hashable, Sendable, Equatable, Codable {
    /// Message posts (tool calls, elicitation answers).
    case post = "POST"
    /// SSE stream reads (in-call elicitation prompts).
    case get = "GET"
}

/// One loopback HTTP request value. Pure data; sending is a caller seam.
public struct MCPHTTPRequest: Hashable, Sendable, Equatable {
    /// Request verb.
    public var method: MCPHTTPMethod
    /// Absolute request URL. Must be plaintext loopback (see `validatedLoopback`).
    public var url: String
    /// Request headers. Auth values are redacted at every log seam.
    public var headers: [String: String]
    /// Request body bytes.
    public var body: Data

    /// Assembles one request value from validated parts.
    public init(method: MCPHTTPMethod, url: String, headers: [String: String], body: Data) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }

    /// Loopback host rule shared by client and router: `http` scheme plus
    /// `EgressHostPolicy.allowsLoopbackTarget` on the parsed host/port.
    /// Anything else (external hosts, https, bad ports, unparseable URLs)
    /// fails closed to nil without sending.
    public func validatedLoopback() -> MCPHTTPRequest? {
        guard let parts = MCPHTTPRequest.splitLoopbackURL(url) else { return nil }
        let policy = EgressHostPolicy(allowedHosts: [])
        guard policy.allowsLoopbackTarget(host: parts.host, port: parts.port) else { return nil }
        return self
    }

    /// Log-safe one-line preview: redacted URL plus redacted headers.
    /// Query values, fragments, userinfo, and auth headers never appear.
    public var redactedPreview: String {
        let redactedURL = ReviewSanitizer.redactURL(url)
        let redactedHeaders = ReviewSanitizer.redactHeaders(headers)
        let names = redactedHeaders.keys.sorted().map { "\($0)=\(redactedHeaders[$0] ?? "")" }
        return "\(method.rawValue) \(redactedURL) [\(names.joined(separator: "; "))]"
    }

    /// Splits an `http://host:port/...` URL into host and port. Returns nil
    /// unless the scheme is exactly `http` and the authority carries an
    /// explicit numeric port: loopback MCP is plaintext on fixed ports, and
    /// an absent or smuggled port fails closed.
    static func splitLoopbackURL(_ url: String) -> (host: String, port: Int)? {
        guard url.hasPrefix("http://") else { return nil }
        let rest = url.dropFirst("http://".count)
        let authorityEnd = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? rest.endIndex
        let authority = String(rest[..<authorityEnd])
        guard let colon = authority.lastIndex(of: ":") else { return nil }
        let host = String(authority[..<colon])
        let portText = String(authority[authority.index(after: colon)...])
        guard host.isEmpty == false, let port = Int(portText) else { return nil }
        return (host, port)
    }
}

/// One loopback HTTP response value.
public struct MCPHTTPResponse: Hashable, Sendable, Equatable {
    /// Numeric status code.
    public var status: Int
    /// Response headers.
    public var headers: [String: String]
    /// Response body bytes.
    public var body: Data

    /// Assembles one response value from validated parts.
    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// 200 with a JSON body.
    public static func ok(_ body: Data) -> MCPHTTPResponse {
        MCPHTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: body)
    }

    /// 400 for a malformed envelope. The reason is a fixed label, never echoed input.
    public static func badRequest() -> MCPHTTPResponse {
        MCPHTTPResponse(
            status: 400,
            headers: ["Content-Type": "application/json"],
            body: Data(MCPHTTPErrorBody.internalError(traceID: UUID()).utf8)
        )
    }

    /// 401 for a missing or wrong caller token.
    public static func unauthorized(traceID: UUID) -> MCPHTTPResponse {
        MCPHTTPResponse(
            status: 401,
            headers: ["Content-Type": "application/json"],
            body: Data(MCPHTTPErrorBody.internalError(traceID: traceID).utf8)
        )
    }

    /// 403 for a cross-resource request (AC-009).
    public static func forbidden(traceID: UUID) -> MCPHTTPResponse {
        MCPHTTPResponse(
            status: 403,
            headers: ["Content-Type": "application/json"],
            body: Data(MCPHTTPErrorBody.internalError(traceID: traceID).utf8)
        )
    }

    /// 404 for an unknown session id.
    public static func unknownSession(traceID: UUID) -> MCPHTTPResponse {
        MCPHTTPResponse(
            status: 404,
            headers: ["Content-Type": "application/json"],
            body: Data(MCPHTTPErrorBody.internalError(traceID: traceID).utf8)
        )
    }

    /// Log-safe one-line preview: status plus redacted headers. Bodies never appear.
    public var redactedPreview: String {
        let redactedHeaders = ReviewSanitizer.redactHeaders(headers)
        let names = redactedHeaders.keys.sorted().map { "\($0)=\(redactedHeaders[$0] ?? "")" }
        return "HTTP \(status) [\(names.joined(separator: "; "))]"
    }
}

/// Opaque HTTP edge body: `InternalError{traceId}` per REQ-015.
public enum MCPHTTPErrorBody {
    /// Renders the fixed-shape error body for one trace id.
    public static func internalError(traceID: UUID) -> String {
        "{\"error\":\"InternalError\",\"traceId\":\"\(traceID.uuidString)\"}"
    }

    /// Recovers the trace id from an edge body. Nil on any shape drift.
    public static func traceID(from body: String) -> UUID? {
        let prefix = "{\"error\":\"InternalError\",\"traceId\":\""
        let suffix = "\"}"
        guard body.hasPrefix(prefix), body.hasSuffix(suffix) else { return nil }
        let inner = String(body.dropFirst(prefix.count).dropLast(suffix.count))
        return UUID(uuidString: inner)
    }
}

// MARK: - Message envelope

/// One tool-call message carried identically over stdio lines and HTTP bodies.
///
/// The envelope names labels only (resource, address, arguments, idempotency
/// key). Credentials travel beside it: the caller token in `Authorization`
/// and the resolved connection credential in `X-RV-Connection-Auth`, both
/// redacted at every log seam. Unknown JSON fields fail closed.
public struct MCPMessageEnvelope: Hashable, Sendable, Equatable, Codable {
    /// Resource the request targets. Must equal the session binding.
    public var resource: String
    /// Canonical tool address literal.
    public var address: String
    /// Arguments JSON object text.
    public var arguments: String
    /// Client-minted idempotency key, one per execution.
    public var idempotencyKey: String

    /// Largest envelope accepted on decode, matching the sibling store caps.
    public static let maximumBytes = 65_536

    /// Assembles one envelope from validated parts.
    public init(resource: String, address: String, arguments: String, idempotencyKey: String) {
        self.resource = resource
        self.address = address
        self.arguments = arguments
        self.idempotencyKey = idempotencyKey
    }

    /// Decodes strictly: unknown fields fail closed so a smuggled member
    /// can never ride beside the validated shape. The key type accepts any
    /// string (a `String` enum would silently drop unknowns from `allKeys`).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StrictJSONKey.self)
        let known: Set<String> = ["resource", "address", "arguments", "idempotencyKey"]
        for key in container.allKeys where known.contains(key.stringValue) == false {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: container, debugDescription: "unknown envelope field"
            )
        }
        resource = try container.decode(String.self, forKey: StrictJSONKey("resource"))
        address = try container.decode(String.self, forKey: StrictJSONKey("address"))
        arguments = try container.decode(String.self, forKey: StrictJSONKey("arguments"))
        idempotencyKey = try container.decode(String.self, forKey: StrictJSONKey("idempotencyKey"))
    }

    /// Encodes to canonical JSON. Nil only when the shape cannot encode.
    public func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(self)
    }

    /// Decodes one envelope, enforcing the byte cap first.
    public static func decoded(_ data: Data) -> MCPMessageEnvelope? {
        guard data.count <= maximumBytes else { return nil }
        return try? JSONDecoder().decode(MCPMessageEnvelope.self, from: data)
    }
}

/// Temporary alias: tests pin the historical name; new code uses `StrictJSONKey`.
/// The envelope key type stays open by design: every JSON member must
/// survive into `allKeys` so the unknown-field check above can see it.
typealias MCPEnvelopeKey = StrictJSONKey

// MARK: - Server-sent events

/// One server-sent event frame: in-call elicitation over streamable HTTP.
///
/// Rendering escapes embedded newlines in `data` into multi-line `data:`
/// fields per the SSE grammar; parsing accepts comments, an optional `id:`
/// field, and multi-line data, joining data lines with `\n`.
public struct MCPServerSentEvent: Hashable, Sendable, Equatable {
    /// Event name (`elicitation`, `elicitation-decision`, `message`).
    public var event: String
    /// Event payload, usually JSON text.
    public var data: String
    /// Optional stream id for replay.
    public var id: String?

    /// Assembles one event frame from validated parts.
    public init(event: String, data: String, id: String? = nil) {
        self.event = event
        self.data = data
        self.id = id
    }

    /// SSE frame name carrying an elicitation prompt from server to client.
    public static let elicitation = "elicitation"
    /// SSE frame name carrying the elicitation answer from client to server.
    public static let elicitationDecision = "elicitation-decision"

    /// Renders the wire frame terminated by a blank line.
    public func rendered() -> String {
        var lines: [String] = []
        if let id {
            lines.append("id: \(id)")
        }
        lines.append("event: \(event)")
        for line in data.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            lines.append("data: \(line)")
        }
        return lines.joined(separator: "\n") + "\n\n"
    }

    /// Parses one frame. Nil unless exactly one `event:` line and at least
    /// one `data:` line are present; comments and blank lines are skipped.
    public static func parsed(_ text: String) -> MCPServerSentEvent? {
        var event: String?
        var dataLines: [String] = []
        var id: String?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if raw.isEmpty || raw.hasPrefix(":") {
                continue
            }
            if raw.hasPrefix("event:") {
                guard event == nil else { return nil }
                event = String(raw.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
            } else if raw.hasPrefix("data:") {
                dataLines.append(String(raw.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces))
            } else if raw.hasPrefix("id:") {
                guard id == nil else { return nil }
                id = String(raw.dropFirst("id:".count)).trimmingCharacters(in: .whitespaces)
            } else {
                return nil
            }
        }
        guard let event, event.isEmpty == false, dataLines.isEmpty == false else { return nil }
        return MCPServerSentEvent(event: event, data: dataLines.joined(separator: "\n"), id: id)
    }
}

// MARK: - OAuth refresh seam

/// One refreshed OAuth access token for a connection.
///
/// SEAM (recorded per ticket): this type plus `MCPOAuthRefresher` is the
/// reactive-refresh seam the invoker calls on a 401. Full OAuth connection
/// management (token storage, provider flows, expiry watchers) lands in X1;
/// T8 ships the seam, the unavailable default, and scripted test doubles.
public struct MCPOAuthToken: Hashable, Sendable, Equatable {
    /// Bearer value. Never logged: `description` is a fixed placeholder.
    public var accessToken: String
    /// When the token lapses.
    public var expiresAt: Date
    /// Connection the token authorizes.
    public var connection: String

    /// Assembles one refreshed token from validated parts.
    public init(accessToken: String, expiresAt: Date, connection: String) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.connection = connection
    }
}

extension MCPOAuthToken: CustomStringConvertible {
    /// Fixed placeholder: interpolating a token never leaks the bearer.
    public var description: String {
        "[redacted-oauth-token connection=\(connection)]"
    }
}

/// Reactive OAuth refresh seam. Called at most once per invocation, only on
/// the invoke path after a 401, and only for idempotent calls.
public struct MCPOAuthRefresher: Sendable {
    /// Refreshes the access token for one connection.
    public let refresh: @Sendable (String) async throws -> MCPOAuthToken

    /// Refreshes through `refresh`.
    public init(refresh: @escaping @Sendable (String) async throws -> MCPOAuthToken) {
        self.refresh = refresh
    }

    /// Default refresher: every refresh throws `.unavailable`. Production
    /// wiring replaces this when X1 lands full OAuth connections.
    public static var unavailable: MCPOAuthRefresher {
        MCPOAuthRefresher(refresh: { _ in throw MCPOAuthRefreshError.unavailable })
    }
}

/// Refresh failures. Labels only; no token material.
public enum MCPOAuthRefreshError: Error, Hashable, Sendable, Equatable {
    /// No OAuth connection is configured (the X1 backlog owns it).
    case unavailable
    /// The connection is not an OAuth connection.
    case deniedConnection
    /// The provider refused the refresh.
    case refreshFailed
}

// MARK: - Transport core

/// Connection credential attached to one transport request. Built from
/// broker-resolved values after approval; never constructed earlier.
public enum MCPTransportAuthorization: Hashable, Sendable, Equatable {
    /// Bearer credential for the target connection.
    case bearer(String)
}

extension MCPTransportAuthorization: CustomStringConvertible {
    /// Fixed placeholder: the bearer never appears in interpolated logs.
    public var description: String {
        "[redacted-connection-credential]"
    }
}

/// One tool-call request handed to a transport after approval and
/// credential resolution.
public struct MCPTransportRequest: Hashable, Sendable, Equatable {
    /// Validated tool address.
    public var address: MCPToolAddress
    /// Validated arguments JSON object text.
    public var argumentsJSON: String
    /// Client-minted idempotency key, one per execution.
    public var idempotencyKey: String
    /// Resolved connection credential, when the connection needs one.
    public var authorization: MCPTransportAuthorization?

    /// Assembles one transport request from validated parts.
    public init(
        address: MCPToolAddress,
        argumentsJSON: String,
        idempotencyKey: String,
        authorization: MCPTransportAuthorization? = nil
    ) {
        self.address = address
        self.argumentsJSON = argumentsJSON
        self.idempotencyKey = idempotencyKey
        self.authorization = authorization
    }
}

/// One tool-call response from a transport.
public struct MCPTransportResponse: Hashable, Sendable, Equatable {
    /// Tool result body text.
    public var body: String

    /// Assembles one transport response.
    public init(body: String) {
        self.body = body
    }
}

/// Typed transport failures. Labels only; envelopes and credentials never echo.
public enum MCPTransportError: Error, Hashable, Sendable, Equatable {
    /// The target URL is not plaintext loopback with an explicit port.
    case nonLoopbackTarget
    /// The session id names no registered session.
    case unknownSession
    /// The caller token is missing or wrong.
    case unauthenticated
    /// The request names a resource outside the session binding (HTTP 403).
    case crossResource
    /// The envelope is malformed, oversized, or misaddressed.
    case malformedEnvelope
    /// The far end answered an unexpected status.
    case remoteFailed(status: Int)
    /// The roundtrip exceeded its budget.
    case requestTimeout
    /// The channel is closed or was never started.
    case transportClosed
    /// The channel lifecycle rejects this transition (double start).
    case lifecycleViolation

    /// True for failures worth the single retry: timeouts and 5xx edges.
    /// Auth, binding, envelope, and lifecycle failures never retry: a retry
    /// would repeat a decision, not ride out a blip.
    public var isRetryable: Bool {
        switch self {
        case .requestTimeout:
            return true
        case .remoteFailed(let status):
            return (500...599).contains(status)
        case .nonLoopbackTarget, .unknownSession, .unauthenticated,
            .crossResource, .malformedEnvelope, .transportClosed, .lifecycleViolation:
            return false
        }
    }
}

/// One-shot tool-call delivery over a bound session.
public protocol MCPTransport: Sendable {
    /// Delivers one request on one session and returns the tool result.
    func roundtrip(_ request: MCPTransportRequest, session: MCPTransportSession) async throws -> MCPTransportResponse
}

/// Redacting transport logger. Every record path scrubs through the
/// four-seam rulebook first, so URLs, headers, and free-text lines never
/// carry secret material to the sink.
public struct MCPTransportLog: Sendable {
    /// Receives one redacted line. Tests inject a capturing closure.
    public var sink: @Sendable (String) -> Void

    /// Logs through `sink`.
    public init(sink: @escaping @Sendable (String) -> Void) {
        self.sink = sink
    }

    /// Discards every line. Default for contexts without a log drain.
    public static var discarded: MCPTransportLog {
        MCPTransportLog(sink: { _ in })
    }

    /// Records one request via its redacted preview.
    public func recordRequest(_ request: MCPHTTPRequest) {
        sink(ReviewSanitizer.redactLog(request.redactedPreview))
    }

    /// Records one response via its redacted preview.
    public func recordResponse(_ response: MCPHTTPResponse) {
        sink(ReviewSanitizer.redactLog(response.redactedPreview))
    }

    /// Records one free-text line after log scrubbing.
    public func recordLine(_ line: String) {
        sink(ReviewSanitizer.redactLog(line))
    }
}

// MARK: - Stdio transport

/// Defined stdio channel lifecycle: spawn, serve while ready, drain, close.
/// Sends are accepted only in `ready`; every other state throws
/// `.transportClosed` without touching the pipe seam.
public enum MCPStdioLifecycle: Hashable, Sendable, Equatable {
    /// Constructed; the pipe seam is not serving yet.
    case spawned
    /// Serving roundtrips.
    case ready
    /// Draining: close requested, in-flight sends finish, new sends refused.
    case draining
    /// Terminal. Sends and restarts are refused.
    case closed
}

/// One bound stdio channel over an injected pipe seam.
///
/// The `send` closure is the process-pipe seam: production passes a
/// `Process`-backed stdin/stdout frame exchange (X1 wires full stdio
/// server connections); tests pass an echo or scripted closure. The
/// channel adds lifecycle plus session binding only.
public actor MCPStdioChannel {
    /// Current lifecycle state.
    public private(set) var lifecycle: MCPStdioLifecycle
    /// Session this channel serves. Requests naming another resource are refused.
    public let session: MCPTransportSession

    private let send: @Sendable (Data) async throws -> Data
    private let log: MCPTransportLog

    /// Binds a channel to one session over the pipe seam. Starts `spawned`.
    public init(
        session: MCPTransportSession,
        send: @escaping @Sendable (Data) async throws -> Data,
        log: MCPTransportLog = .discarded
    ) {
        self.lifecycle = .spawned
        self.session = session
        self.send = send
        self.log = log
    }

    /// Moves `spawned` to `ready`. Any other state throws `.lifecycleViolation`.
    public func start() throws(MCPTransportError) {
        guard lifecycle == .spawned else {
            throw MCPTransportError.lifecycleViolation
        }
        lifecycle = .ready
    }

    /// Moves to `closed` via `draining`. Idempotent: closing twice is a no-op.
    public func close() {
        if lifecycle != .closed {
            lifecycle = .draining
        }
        lifecycle = .closed
    }

    /// Sends one envelope and returns the raw reply. Refuses cross-resource
    /// envelopes and non-`ready` states before touching the pipe seam.
    public func exchange(_ envelope: MCPMessageEnvelope) async throws -> Data {
        guard lifecycle == .ready else {
            throw MCPTransportError.transportClosed
        }
        guard envelope.resource == session.resource.rawValue else {
            throw MCPTransportError.crossResource
        }
        guard let bytes = envelope.encoded() else {
            throw MCPTransportError.malformedEnvelope
        }
        log.recordLine("stdio exchange address=\(envelope.address)")
        do {
            return try await send(bytes)
        } catch let error as MCPTransportError {
            throw error
        } catch {
            throw MCPTransportError.remoteFailed(status: 0)
        }
    }
}

/// `MCPTransport` over one stdio channel. Replies must be UTF-8 tool-result
/// text within the envelope cap; anything else is `.malformedEnvelope`.
public struct MCPStdioTransport: MCPTransport, Sendable {
    /// Channel carrying the roundtrips.
    public var channel: MCPStdioChannel

    /// Serves roundtrips over `channel`.
    public init(channel: MCPStdioChannel) {
        self.channel = channel
    }

    /// Encodes the request as an envelope, exchanges it, and decodes the
    /// UTF-8 reply. Session-id mismatch against the channel binding is
    /// refused, and so is a wrong caller token, mirroring the HTTP edge.
    public func roundtrip(_ request: MCPTransportRequest, session: MCPTransportSession) async throws -> MCPTransportResponse {
        guard session.id == channel.session.id else {
            throw MCPTransportError.unknownSession
        }
        guard session.callerToken == channel.session.callerToken else {
            throw MCPTransportError.unauthenticated
        }
        let envelope = MCPMessageEnvelope(
            resource: session.resource.rawValue,
            address: request.address.literal,
            arguments: request.argumentsJSON,
            idempotencyKey: request.idempotencyKey
        )
        let reply = try await channel.exchange(envelope)
        guard reply.count <= MCPMessageEnvelope.maximumBytes,
            let body = String(data: reply, encoding: .utf8)
        else {
            throw MCPTransportError.malformedEnvelope
        }
        return MCPTransportResponse(body: body)
    }
}

// MARK: - Streamable HTTP transport

/// `MCPTransport` over loopback streamable HTTP.
///
/// The `send` closure is the socket seam: production passes a URLSession
/// exchange; tests pass the in-memory router. Loopback validation runs
/// before every send, and the caller token plus connection secret travel
/// in headers that are redacted at every log seam.
public struct MCPStreamableHTTPClient: MCPTransport, Sendable {
    /// Fixed invoke path served by the loopback edge.
    public static let invokePath = "/mcp/invoke"
    /// Header carrying the session id.
    public static let sessionHeader = "X-RV-Session"
    /// Header carrying the resolved connection secret.
    public static let connectionAuthHeader = "X-RV-Connection-Auth"
    /// Header carrying the caller token as a bearer.
    public static let authorizationHeader = "Authorization"

    /// Base URL including scheme, loopback host, and explicit port.
    public var baseURL: String
    /// Socket seam: one HTTP exchange.
    public var send: @Sendable (MCPHTTPRequest) async throws -> MCPHTTPResponse
    /// Redacting logger.
    public var log: MCPTransportLog

    /// Serves roundtrips against `baseURL` through the socket seam.
    public init(
        baseURL: String,
        send: @escaping @Sendable (MCPHTTPRequest) async throws -> MCPHTTPResponse,
        log: MCPTransportLog = .discarded
    ) {
        self.baseURL = baseURL
        self.send = send
        self.log = log
    }

    /// Builds the POST, validates loopback, sends, and maps the status.
    /// Non-loopback targets throw before the seam is touched.
    public func roundtrip(_ request: MCPTransportRequest, session: MCPTransportSession) async throws -> MCPTransportResponse {
        var headers = [
            Self.sessionHeader: session.id.rawValue.uuidString,
            Self.authorizationHeader: "Bearer \(session.callerToken.rawValue)",
        ]
        if case .bearer(let secret) = request.authorization {
            headers[Self.connectionAuthHeader] = secret
        }
        let envelope = MCPMessageEnvelope(
            resource: session.resource.rawValue,
            address: request.address.literal,
            arguments: request.argumentsJSON,
            idempotencyKey: request.idempotencyKey
        )
        guard let body = envelope.encoded() else {
            throw MCPTransportError.malformedEnvelope
        }
        let http = MCPHTTPRequest(
            method: .post,
            url: baseURL + Self.invokePath,
            headers: headers,
            body: body
        )
        guard http.validatedLoopback() != nil else {
            throw MCPTransportError.nonLoopbackTarget
        }
        log.recordRequest(http)
        let response: MCPHTTPResponse
        do {
            response = try await send(http)
        } catch let error as MCPTransportError {
            throw error
        } catch {
            throw MCPTransportError.remoteFailed(status: 0)
        }
        log.recordResponse(response)
        switch response.status {
        case 200:
            guard response.body.count <= MCPMessageEnvelope.maximumBytes,
                let text = String(data: response.body, encoding: .utf8)
            else {
                throw MCPTransportError.malformedEnvelope
            }
            return MCPTransportResponse(body: text)
        case 401:
            throw MCPTransportError.unauthenticated
        case 403:
            throw MCPTransportError.crossResource
        case 404:
            throw MCPTransportError.unknownSession
        case 400:
            throw MCPTransportError.malformedEnvelope
        case 408:
            throw MCPTransportError.requestTimeout
        default:
            throw MCPTransportError.remoteFailed(status: response.status)
        }
    }
}

// MARK: - In-memory loopback edge

/// One validated edge request after session, caller, and binding checks.
/// The scripted handler receives this; raw headers never reach it.
public struct MCPRouterRequest: Hashable, Sendable, Equatable {
    /// Session the call arrived on.
    public var sessionID: MCPSessionID
    /// Bound resource, already proven equal to the envelope resource.
    public var resource: MCPResourceID
    /// Canonical tool address literal from the envelope.
    public var address: String
    /// Arguments JSON object text from the envelope.
    public var argumentsJSON: String
    /// Idempotency key from the envelope.
    public var idempotencyKey: String
    /// Connection secret from `X-RV-Connection-Auth`, when present.
    /// Handlers must not log it; the edge log seam never sees it.
    public var connectionSecret: String?

    /// Assembles one validated edge request.
    public init(
        sessionID: MCPSessionID,
        resource: MCPResourceID,
        address: String,
        argumentsJSON: String,
        idempotencyKey: String,
        connectionSecret: String? = nil
    ) {
        self.sessionID = sessionID
        self.resource = resource
        self.address = address
        self.argumentsJSON = argumentsJSON
        self.idempotencyKey = idempotencyKey
        self.connectionSecret = connectionSecret
    }
}

/// Server-side loopback edge with per-session resource binding (REQ-013).
///
/// `handleHTTP` is total: every input yields a status, never a throw.
/// Checks run caller-before-resource: unknown session answers 404, a wrong
/// caller token answers 401, and a resource outside the session binding
/// answers 403 with an `InternalError{traceId}` body (AC-009). Only a
/// fully validated request reaches the scripted handler. Handler failures
/// answer 500 with an opaque body; the cause goes to the cause log only.
public actor MCPInMemoryRouter {
    private var sessions: [MCPSessionID: MCPTransportSession] = [:]
    private let handler: @Sendable (MCPRouterRequest) async throws -> MCPTransportResponse
    private let log: MCPTransportLog
    private let causeLog: @Sendable (String) -> Void

    /// Serves registered sessions through the scripted handler.
    /// Handler failures are cause-logged after redaction.
    public init(
        handler: @escaping @Sendable (MCPRouterRequest) async throws -> MCPTransportResponse,
        log: MCPTransportLog = .discarded,
        causeLog: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.handler = handler
        self.log = log
        self.causeLog = causeLog
    }

    /// Registers one bound session. Re-registering an id replaces it.
    public func register(_ session: MCPTransportSession) {
        sessions[session.id] = session
    }

    /// Drops one session. Later requests on it answer 404.
    public func unregister(_ id: MCPSessionID) {
        sessions.removeValue(forKey: id)
    }

    /// Handles one HTTP exchange end to end. Total: always a response.
    public func handleHTTP(_ http: MCPHTTPRequest) async -> MCPHTTPResponse {
        log.recordRequest(http)
        guard http.method == .post, http.url.hasSuffix(MCPStreamableHTTPClient.invokePath) else {
            return .badRequest()
        }
        guard let sessionID = Self.sessionID(from: http),
            let session = sessions[sessionID]
        else {
            return .unknownSession(traceID: UUID())
        }
        guard Self.callerToken(from: http) == session.callerToken.rawValue else {
            return .unauthorized(traceID: UUID())
        }
        guard let envelope = MCPMessageEnvelope.decoded(http.body),
            let resource = MCPResourceID(rawValue: envelope.resource)
        else {
            return .badRequest()
        }
        guard session.binds(resource) else {
            return .forbidden(traceID: UUID())
        }
        let request = MCPRouterRequest(
            sessionID: sessionID,
            resource: resource,
            address: envelope.address,
            argumentsJSON: envelope.arguments,
            idempotencyKey: envelope.idempotencyKey,
            connectionSecret: http.headers[MCPStreamableHTTPClient.connectionAuthHeader]
        )
        do {
            let result = try await handler(request)
            let body = Data(result.body.utf8)
            guard body.count <= MCPMessageEnvelope.maximumBytes else {
                return .badRequest()
            }
            let response = MCPHTTPResponse.ok(body)
            log.recordResponse(response)
            return response
        } catch {
            let traceID = UUID()
            causeLog("mcp-edge trace=\(traceID.uuidString) cause=\(ReviewSanitizer.redactLog(String(describing: error)))")
            return MCPHTTPResponse(
                status: 500,
                headers: ["Content-Type": "application/json"],
                body: Data(MCPHTTPErrorBody.internalError(traceID: traceID).utf8)
            )
        }
    }

    private static func sessionID(from http: MCPHTTPRequest) -> MCPSessionID? {
        guard let raw = http.headers[MCPStreamableHTTPClient.sessionHeader],
            let id = UUID(uuidString: raw)
        else {
            return nil
        }
        return MCPSessionID(rawValue: id)
    }

    private static func callerToken(from http: MCPHTTPRequest) -> String? {
        guard let raw = http.headers[MCPStreamableHTTPClient.authorizationHeader],
            raw.hasPrefix("Bearer ")
        else {
            return nil
        }
        return String(raw.dropFirst("Bearer ".count))
    }
}
