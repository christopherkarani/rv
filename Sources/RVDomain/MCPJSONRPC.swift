import Foundation

/// MCP serving envelope: JSON-RPC 2.0 codec, canonical error renderer, method
/// gate, pre-initialize guard, ToolError vocabulary, and ToolResult contract.
///
/// Pure values; no IO. Mirrors Executor `packages/hosts/mcp/src/envelope.ts`
/// (method gate, canonical renderer, auth/dispatch error sites, session-less
/// short-circuits, pre-initialize -32601 guard), `packages/core/sdk/src/
/// tool-result.ts` (ToolError/ToolHttpMeta/ToolFile/ToolResult),
/// `auth-tool-failure.ts` (recovery hints, refresh trigger), and the failure
/// mapping in `packages/core/execution/src/tool-invoker.ts`.
///
/// Error strings carry labels only (paths, integration names, connection
/// labels, OAuth codes) — never secret values. Every API below takes at most
/// a label; there is no parameter into which a credential value fits.

// MARK: - Bounds

/// Decodes an optional member: a missing key reads as nil, an explicit null
/// fails closed, otherwise the value decodes as `T`. Mirrors Effect's
/// `optional`, where only a missing key is absent.
private func decodeStrictOptional<T: Decodable>(
    _ type: T.Type, forKey key: StrictJSONKey,
    in container: KeyedDecodingContainer<StrictJSONKey>
) throws -> T? {
    guard container.contains(key) else { return nil }
    if try container.decodeNil(forKey: key) {
        throw DecodingError.dataCorruptedError(
            forKey: key, in: container, debugDescription: "null is not absent"
        )
    }
    return try container.decode(T.self, forKey: key)
}

/// Byte and count bounds for the serving envelope. Fixed constants (no caller
/// tuning): the caps are part of the wire contract, mirroring how
/// `RuntimeAdmissionCodec` fixes `maxBodyBytes`/`maxResponseBytes`.
public enum MCPJSONRPCLimits {
    /// Largest inbound JSON-RPC body the codec accepts.
    public static let maxBodyBytes = 262_144
    /// Longest method name, in characters.
    public static let maxMethodCharacters = 256
    /// Longest string request id, in characters.
    public static let maxIDCharacters = 256
    /// Longest error message in a decoded response, in characters.
    public static let maxErrorMessageCharacters = 4_096
    /// Most items in a decoded batch.
    public static let maxBatchItems = 128
    /// Deepest `{`/`[` nesting an inbound body may carry, counted outside
    /// strings. Past this the recursive decode risks stack exhaustion on the
    /// 512 KB stacks serving threads use (measured crash near depth 200 in
    /// debug, near 250 in release); legitimate traffic nests a handful deep.
    public static let maxJSONDepth = 100
    /// Most headers in tool HTTP metadata.
    public static let maxHTTPHeaderCount = 64
    /// Longest base64 payload of a tool file, in characters.
    public static let maxFileBase64Characters = 262_144
    /// `Retry-After` on transient-auth 503s. Short: upstream auth-infra blips
    /// are typically sub-second. Mirrors `UNAVAILABLE_RETRY_AFTER_SECONDS`.
    public static let unavailableRetryAfterSeconds = 2
}

// MARK: - Request id

/// JSON-RPC request id: an integer or a string. Mirrors the SDK's request-id
/// schema (string | integer): fractional numbers, booleans, null, and missing
/// ids are not request ids. An integral double (`1.0`) reads as its integer,
/// matching `Number.isInteger`; ids outside `Int64` do not decode.
public enum MCPJSONRPCID: Sendable, Equatable {
    /// Integer id.
    case number(Int64)
    /// String id, at most `maxIDCharacters` characters.
    case string(String)

    /// JSON fragment for id echo: the bare integer or the quoted string.
    var jsonFragment: String {
        switch self {
        case .number(let value):
            return String(value)
        case .string(let value):
            return "\"\(MCPJSONRPCErrorRenderer.escape(value))\""
        }
    }
}

extension MCPJSONRPCID: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            guard string.count <= MCPJSONRPCLimits.maxIDCharacters else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "id exceeds 256 characters"
                )
            }
            self = .string(string)
            return
        }
        self = .number(try container.decode(Int64.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        }
    }
}

// MARK: - Request, notification, response

/// Strict JSON-RPC 2.0 request. Allowed top-level keys: `jsonrpc`, `id`,
/// `method`, `params`. `params`, when present, must be an object — the MCP
/// SDK transport answers non-object params with a 400 parse error, so the
/// codec refuses them the same way.
public struct MCPJSONRPCRequest: Sendable, Equatable {
    /// Request id echoed by the response.
    public let id: MCPJSONRPCID
    /// Method name, at most `maxMethodCharacters` characters.
    public let method: String
    /// Object params, when present.
    public let params: [String: JSONValue]?

    /// Assembles a request from validated parts.
    public init(id: MCPJSONRPCID, method: String, params: [String: JSONValue]? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }
}

extension MCPJSONRPCRequest: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StrictJSONKey.self)
        try rejectUnknownKeys(container, allowed: ["jsonrpc", "id", "method", "params"])
        let version = try container.decode(String.self, forKey: StrictJSONKey("jsonrpc"))
        guard version == "2.0" else {
            throw DecodingError.dataCorruptedError(
                forKey: StrictJSONKey("jsonrpc"), in: container,
                debugDescription: "jsonrpc must be \"2.0\""
            )
        }
        let id = try container.decode(MCPJSONRPCID.self, forKey: StrictJSONKey("id"))
        let method = try container.decode(String.self, forKey: StrictJSONKey("method"))
        guard method.count <= MCPJSONRPCLimits.maxMethodCharacters else {
            throw DecodingError.dataCorruptedError(
                forKey: StrictJSONKey("method"), in: container,
                debugDescription: "method exceeds 256 characters"
            )
        }
        let params = try decodeStrictOptional([String: JSONValue].self, forKey: StrictJSONKey("params"), in: container)
        self.init(id: id, method: method, params: params)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StrictJSONKey.self)
        try container.encode("2.0", forKey: StrictJSONKey("jsonrpc"))
        try container.encode(id, forKey: StrictJSONKey("id"))
        try container.encode(method, forKey: StrictJSONKey("method"))
        try container.encodeIfPresent(params, forKey: StrictJSONKey("params"))
    }
}

/// Strict JSON-RPC 2.0 notification: a request without an id, so no response
/// is owed. Allowed top-level keys: `jsonrpc`, `method`, `params`.
public struct MCPJSONRPCNotification: Sendable, Equatable {
    /// Method name, at most `maxMethodCharacters` characters.
    public let method: String
    /// Object params, when present.
    public let params: [String: JSONValue]?

    /// Assembles a notification from validated parts.
    public init(method: String, params: [String: JSONValue]? = nil) {
        self.method = method
        self.params = params
    }
}

extension MCPJSONRPCNotification: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StrictJSONKey.self)
        try rejectUnknownKeys(container, allowed: ["jsonrpc", "method", "params"])
        let version = try container.decode(String.self, forKey: StrictJSONKey("jsonrpc"))
        guard version == "2.0" else {
            throw DecodingError.dataCorruptedError(
                forKey: StrictJSONKey("jsonrpc"), in: container,
                debugDescription: "jsonrpc must be \"2.0\""
            )
        }
        let method = try container.decode(String.self, forKey: StrictJSONKey("method"))
        guard method.count <= MCPJSONRPCLimits.maxMethodCharacters else {
            throw DecodingError.dataCorruptedError(
                forKey: StrictJSONKey("method"), in: container,
                debugDescription: "method exceeds 256 characters"
            )
        }
        let params = try decodeStrictOptional([String: JSONValue].self, forKey: StrictJSONKey("params"), in: container)
        self.init(method: method, params: params)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StrictJSONKey.self)
        try container.encode("2.0", forKey: StrictJSONKey("jsonrpc"))
        try container.encode(method, forKey: StrictJSONKey("method"))
        try container.encodeIfPresent(params, forKey: StrictJSONKey("params"))
    }
}

/// Strict JSON-RPC error object. Allowed keys: `code`, `message`.
public struct MCPJSONRPCResponseError: Sendable, Equatable {
    /// JSON-RPC error code.
    public let code: Int
    /// Human-readable message, at most `maxErrorMessageCharacters` characters.
    public let message: String

    /// Assembles an error object from validated parts.
    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
}

extension MCPJSONRPCResponseError: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StrictJSONKey.self)
        try rejectUnknownKeys(container, allowed: ["code", "message"])
        let code = try container.decode(Int.self, forKey: StrictJSONKey("code"))
        let message = try container.decode(String.self, forKey: StrictJSONKey("message"))
        guard message.count <= MCPJSONRPCLimits.maxErrorMessageCharacters else {
            throw DecodingError.dataCorruptedError(
                forKey: StrictJSONKey("message"), in: container,
                debugDescription: "error message exceeds 4096 characters"
            )
        }
        self.init(code: code, message: message)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StrictJSONKey.self)
        try container.encode(code, forKey: StrictJSONKey("code"))
        try container.encode(message, forKey: StrictJSONKey("message"))
    }
}

/// Strict JSON-RPC 2.0 response: exactly one of `result` or `error`. Allowed
/// top-level keys: `jsonrpc`, `id`, `result`, `error`. A success always
/// carries the request id; a failure may carry null when the request id is
/// unknown, mirroring the SDK.
public enum MCPJSONRPCResponse: Sendable, Equatable {
    /// Successful response answering `id`.
    case success(id: MCPJSONRPCID, result: JSONValue)
    /// Failed response; null id when the request id is unknown.
    case failure(id: MCPJSONRPCID?, error: MCPJSONRPCResponseError)
}

extension MCPJSONRPCResponse: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StrictJSONKey.self)
        try rejectUnknownKeys(container, allowed: ["jsonrpc", "id", "result", "error"])
        let version = try container.decode(String.self, forKey: StrictJSONKey("jsonrpc"))
        guard version == "2.0" else {
            throw DecodingError.dataCorruptedError(
                forKey: StrictJSONKey("jsonrpc"), in: container,
                debugDescription: "jsonrpc must be \"2.0\""
            )
        }
        guard container.contains(StrictJSONKey("id")) else {
            throw DecodingError.dataCorruptedError(
                forKey: StrictJSONKey("id"), in: container,
                debugDescription: "response id is required"
            )
        }
        let id: MCPJSONRPCID?
        if try container.decodeNil(forKey: StrictJSONKey("id")) {
            id = nil
        } else {
            id = try container.decode(MCPJSONRPCID.self, forKey: StrictJSONKey("id"))
        }
        let hasResult = container.contains(StrictJSONKey("result"))
        let hasError = container.contains(StrictJSONKey("error"))
        guard hasResult != hasError else {
            throw DecodingError.dataCorruptedError(
                forKey: StrictJSONKey("result"), in: container,
                debugDescription: "response carries exactly one of result, error"
            )
        }
        if hasResult {
            guard let id else {
                throw DecodingError.dataCorruptedError(
                    forKey: StrictJSONKey("id"), in: container,
                    debugDescription: "success id must not be null"
                )
            }
            let result = try container.decode(JSONValue.self, forKey: StrictJSONKey("result"))
            self = .success(id: id, result: result)
        } else {
            let error = try container.decode(
                MCPJSONRPCResponseError.self, forKey: StrictJSONKey("error")
            )
            self = .failure(id: id, error: error)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StrictJSONKey.self)
        try container.encode("2.0", forKey: StrictJSONKey("jsonrpc"))
        switch self {
        case .success(let id, let result):
            try container.encode(id, forKey: StrictJSONKey("id"))
            try container.encode(result, forKey: StrictJSONKey("result"))
        case .failure(let id, let error):
            if let id {
                try container.encode(id, forKey: StrictJSONKey("id"))
            } else {
                try container.encodeNil(forKey: StrictJSONKey("id"))
            }
            try container.encode(error, forKey: StrictJSONKey("error"))
        }
    }
}

// MARK: - Inbound codec

/// Inbound-body decode failures. Never echoes the body.
public enum MCPJSONRPCDecodeError: Error, Sendable, Equatable {
    /// The body is empty.
    case empty
    /// The body exceeds `maxBodyBytes`.
    case oversized
    /// The body is not a strict request, notification, response, or batch.
    case malformed
}

/// One classified inbound body.
public enum MCPJSONRPCInbound: Sendable, Equatable {
    /// A strict single request.
    case request(MCPJSONRPCRequest)
    /// A strict notification.
    case notification(MCPJSONRPCNotification)
    /// A strict response.
    case response(MCPJSONRPCResponse)
    /// A batch: 1 to `maxBatchItems` JSON objects. Items stay unshaped (the
    /// serving edge answers batches through the transport, never here); the
    /// object check keeps primitives and nesting out.
    case batch([JSONValue])
}

/// Single entry point for inbound bodies: size checks, then strict
/// classification. Attempts run request → notification → response → batch;
/// anything else is malformed.
public enum MCPJSONRPCCodec {
    /// Decodes and classifies one inbound body.
    public static func decode(_ data: Data) -> Result<MCPJSONRPCInbound, MCPJSONRPCDecodeError> {
        guard data.isEmpty == false else { return .failure(.empty) }
        guard data.count <= MCPJSONRPCLimits.maxBodyBytes else { return .failure(.oversized) }
        guard hasBOMPrefix(data) == false else { return .failure(.malformed) }
        guard exceedsMaxDepth(data) == false else { return .failure(.malformed) }
        if let request = try? JSONDecoder().decode(MCPJSONRPCRequest.self, from: data) {
            return .success(.request(request))
        }
        if let notification = try? JSONDecoder().decode(MCPJSONRPCNotification.self, from: data) {
            return .success(.notification(notification))
        }
        if let response = try? JSONDecoder().decode(MCPJSONRPCResponse.self, from: data) {
            return .success(.response(response))
        }
        if let batch = try? decodeBatch(data) {
            return .success(.batch(batch))
        }
        return .failure(.malformed)
    }

    /// True when the body opens with a UTF-8 BOM. Strict parsers (Node,
    /// Go, Python) reject a BOM-prefixed document; Foundation would silently
    /// accept it, so the codec refuses it first to hold the strict contract.
    private static func hasBOMPrefix(_ data: Data) -> Bool {
        data.prefix(3).elementsEqual([0xEF, 0xBB, 0xBF])
    }

    /// True when structural `{`/`[` nesting outside strings passes
    /// `maxJSONDepth`. One linear byte pass with early exit; UTF-8 multibyte
    /// sequences never collide with the ASCII bytes scanned, so no decoding
    /// is needed. Unbalanced closers floor at zero — full validation happens
    /// in the decode attempts that follow.
    private static func exceedsMaxDepth(_ data: Data) -> Bool {
        var depth = 0
        var inString = false
        var index = data.startIndex
        while index < data.endIndex {
            let byte = data[index]
            let next = data.index(after: index)
            if inString {
                if byte == 0x5C {
                    index = next < data.endIndex ? data.index(after: next) : next
                    continue
                }
                if byte == 0x22 {
                    inString = false
                }
                index = next
                continue
            }
            switch byte {
            case 0x22:
                inString = true
            case 0x7B, 0x5B:
                depth += 1
                if depth > MCPJSONRPCLimits.maxJSONDepth {
                    return true
                }
            case 0x7D, 0x5D:
                if depth > 0 {
                    depth -= 1
                }
            default:
                break
            }
            index = next
        }
        return false
    }

    private static func decodeBatch(_ data: Data) throws -> [JSONValue] {
        let items = try JSONDecoder().decode([JSONValue].self, from: data)
        guard items.isEmpty == false else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: [], debugDescription: "batch must not be empty")
            )
        }
        guard items.count <= MCPJSONRPCLimits.maxBatchItems else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: [], debugDescription: "batch exceeds 128 items")
            )
        }
        guard items.allSatisfy({ item in
            if case .object = item { return true }
            return false
        }) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [], debugDescription: "batch items must be objects"
                )
            )
        }
        return items
    }
}

// MARK: - Error codes and renderer

/// Serving-envelope JSON-RPC codes. Exact Executor vocabulary (envelope.ts);
/// `-32001` is the shared auth/session envelope code across 401/403/404/405.
public enum MCPJSONRPCErrorCode: Int, Sendable, Equatable {
    /// Transport/session precondition failed.
    case sessionIDRequired = -32000
    /// Auth/session envelope error.
    case authSession = -32001
    /// Session ownership mismatch.
    case sessionOwnership = -32003
    /// Unknown method.
    case methodNotFound = -32601
    /// Orchestration defect.
    case internalError = -32603
}

/// Handshake name for the serving-envelope codes, as the X1 brief names it.
public typealias MCPJSONRPCCodes = MCPJSONRPCErrorCode

/// One rendered serving response: HTTP status, headers, and body text. The
/// body is empty for the 204 answers (preflight, session-less DELETE).
public struct MCPEnvelopeResponse: Sendable, Equatable {
    /// HTTP status.
    public let httpStatus: Int
    /// Lowercase header names to values.
    public let headers: [String: String]
    /// Body text: the canonical JSON-RPC error document, or "" for 204s.
    public let body: String

    /// Assembles a rendered response.
    public init(httpStatus: Int, headers: [String: String], body: String) {
        self.httpStatus = httpStatus
        self.headers = headers
        self.body = body
    }
}

/// Canonical JSON-RPC error renderer. Emits the exact body every host renders
/// — `{"jsonrpc":"2.0","error":{"code":…,"message":"…"},"id":…}` with
/// `content-type: application/json` — via hand encoding, since keyed encoding
/// cannot promise the byte-identical key order. Two header policies, mirroring
/// `jsonRpcErrorBody`: `cors: true` (default) adds
/// `access-control-allow-origin: *` for responses that cross the browser
/// boundary; `cors: false` omits CORS for inner responses the outer envelope
/// re-wraps. A `challenge` adds `www-authenticate` plus its expose header;
/// `retryAfterSeconds` adds `retry-after`.
public enum MCPJSONRPCErrorRenderer {
    /// Exact Executor messages (envelope.ts).
    public static let methodNotAllowedMessage = "Method not allowed"
    /// Exact Executor message (envelope.ts).
    public static let unauthorizedMessage = "Unauthorized"
    /// Exact Executor message (envelope.ts).
    public static let sessionNotFoundMessage = "Session not found"
    /// Exact Executor message (envelope.ts).
    public static let sessionOwnershipMessage = "MCP session does not belong to the current bearer"
    /// Exact Executor message (envelope.ts).
    public static let sessionIDRequiredMessage = "mcp-session-id header required for SSE"
    /// Exact Executor message (envelope.ts).
    public static let methodNotFoundMessage = "Method not found"
    /// Exact Executor message (envelope.ts).
    public static let internalErrorMessage = "Internal server error"

    /// Renders one canonical error response. A nil or empty challenge omits
    /// the header, mirroring the renderer's falsy check (with no fallback to
    /// the default challenge — the outcome already chose).
    public static func render(
        status: Int,
        code: Int,
        message: String,
        cors: Bool = true,
        challenge: String? = nil,
        retryAfterSeconds: Int? = nil,
        id: MCPJSONRPCID? = nil
    ) -> MCPEnvelopeResponse {
        var headers = ["content-type": "application/json"]
        if cors {
            headers["access-control-allow-origin"] = "*"
        }
        if let challenge, challenge.isEmpty == false {
            headers["www-authenticate"] = challenge
            headers["access-control-expose-headers"] = "WWW-Authenticate"
        }
        if let retryAfterSeconds {
            headers["retry-after"] = String(retryAfterSeconds)
        }
        return MCPEnvelopeResponse(
            httpStatus: status, headers: headers,
            body: bodyText(code: code, message: message, id: id)
        )
    }

    /// Canonical error body with byte-identical key order.
    static func bodyText(code: Int, message: String, id: MCPJSONRPCID?) -> String {
        "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":\(code),\"message\":\"\(escape(message))\"},\"id\":\(id.map(\.jsonFragment) ?? "null")}"
    }

    /// JSON string escaping: quotes, backslash, the short control escapes,
    /// `\u00xx` for other C0 controls, everything else raw (UTF-8).
    static func escape(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22:
                out += "\\\""
            case 0x5C:
                out += "\\\\"
            case 0x0A:
                out += "\\n"
            case 0x0D:
                out += "\\r"
            case 0x09:
                out += "\\t"
            case 0x08:
                out += "\\b"
            case 0x0C:
                out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    /// 405 for a method the transport does not serve, answered before auth.
    public static func methodNotAllowed() -> MCPEnvelopeResponse {
        render(
            status: 405, code: MCPJSONRPCErrorCode.authSession.rawValue,
            message: methodNotAllowedMessage
        )
    }

    /// 401 plus the RFC 9728 challenge.
    public static func unauthorized(challenge: String) -> MCPEnvelopeResponse {
        render(
            status: 401, code: MCPJSONRPCErrorCode.authSession.rawValue,
            message: unauthorizedMessage, challenge: challenge
        )
    }

    /// Default challenge built from the provider's resource-metadata URL.
    public static func defaultChallenge(resourceMetadataURL: String) -> String {
        "Bearer realm=\"mcp\", resource_metadata=\"\(resourceMetadataURL)\""
    }

    /// 403 with the provider's message; default code -32001.
    public static func forbidden(
        message: String, code: Int = MCPJSONRPCErrorCode.authSession.rawValue
    ) -> MCPEnvelopeResponse {
        render(status: 403, code: code, message: message)
    }

    /// 503 for a transient auth outage, plus `Retry-After`.
    public static func unavailable(message: String) -> MCPEnvelopeResponse {
        render(
            status: 503, code: MCPJSONRPCErrorCode.authSession.rawValue,
            message: message, retryAfterSeconds: MCPJSONRPCLimits.unavailableRetryAfterSeconds
        )
    }

    /// 403 when the session belongs to another bearer.
    public static func sessionOwnership() -> MCPEnvelopeResponse {
        render(
            status: 403, code: MCPJSONRPCErrorCode.sessionOwnership.rawValue,
            message: sessionOwnershipMessage
        )
    }

    /// Dead-session answer by method: POST/DELETE keep the 404 that drives
    /// client re-initialization; a standalone GET gets 405 with
    /// `Allow: POST, DELETE` — no SSE stream offered — which stops SDK
    /// reconnect loops. The GET arm carries no CORS, mirroring the
    /// hand-rolled `renderDispatchError` response.
    public static func sessionNotFound(method: String) -> MCPEnvelopeResponse {
        if method == "GET" {
            return MCPEnvelopeResponse(
                httpStatus: 405,
                headers: ["content-type": "application/json", "allow": "POST, DELETE"],
                body: bodyText(
                    code: MCPJSONRPCErrorCode.authSession.rawValue,
                    message: sessionNotFoundMessage, id: nil
                )
            )
        }
        return render(
            status: 404, code: MCPJSONRPCErrorCode.authSession.rawValue,
            message: sessionNotFoundMessage
        )
    }

    /// 400 when a session-less GET has no id to stream.
    public static func sessionIDRequiredForSSE() -> MCPEnvelopeResponse {
        render(
            status: 400, code: MCPJSONRPCErrorCode.sessionIDRequired.rawValue,
            message: sessionIDRequiredMessage
        )
    }

    /// Per-request -32601 answering one identified request: HTTP 200, echoed
    /// id, inner (no CORS) — the outer envelope owns CORS on the way out.
    public static func methodNotFound(id: MCPJSONRPCID) -> MCPEnvelopeResponse {
        render(
            status: 200, code: MCPJSONRPCErrorCode.methodNotFound.rawValue,
            message: methodNotFoundMessage, cors: false, id: id
        )
    }

    /// Stable 500 for a request-orchestration defect.
    public static func internalError() -> MCPEnvelopeResponse {
        render(
            status: 500, code: MCPJSONRPCErrorCode.internalError.rawValue,
            message: internalErrorMessage
        )
    }

    /// CORS preflight answered before auth, on `/mcp` and every discovery
    /// path. Exact Executor headers.
    public static func corsPreflight() -> MCPEnvelopeResponse {
        MCPEnvelopeResponse(
            httpStatus: 204,
            headers: [
                "access-control-allow-origin": "*",
                "access-control-allow-methods": "GET, POST, DELETE, OPTIONS",
                "access-control-allow-headers":
                    "content-type, authorization, mcp-session-id, accept, mcp-protocol-version",
                "access-control-expose-headers": "mcp-session-id, WWW-Authenticate",
            ],
            body: ""
        )
    }

    /// Session-less DELETE is a no-op 204 with CORS.
    public static func sessionlessDelete() -> MCPEnvelopeResponse {
        MCPEnvelopeResponse(
            httpStatus: 204, headers: ["access-control-allow-origin": "*"], body: ""
        )
    }
}

// MARK: - Method gate and pipeline

/// Pre-auth method gate for the serving endpoint. Only GET/POST/DELETE reach
/// auth and dispatch; OPTIONS answers the CORS preflight; anything else is a
/// JSON-RPC 405 before auth/dispatch so no session engine spins up for a
/// method the transport cannot serve. Matching is case-sensitive, mirroring
/// the Executor's method set.
public enum MCPHTTPMethodGate {
    /// Methods the streamable-HTTP transport serves.
    public static let allowedMethods: Set<String> = ["GET", "POST", "DELETE", "OPTIONS"]

    /// Gate verdict.
    public enum Verdict: Sendable, Equatable {
        /// OPTIONS preflight answer.
        case preflight(MCPEnvelopeResponse)
        /// Reach auth, then dispatch.
        case allowed
        /// 405 answer; auth and dispatch never run.
        case rejected(MCPEnvelopeResponse)
    }

    /// Evaluates one method. Pure: no auth, no dispatch.
    public static func evaluate(method: String) -> Verdict {
        if method == "OPTIONS" {
            return .preflight(MCPJSONRPCErrorRenderer.corsPreflight())
        }
        if allowedMethods.contains(method) {
            return .allowed
        }
        return .rejected(MCPJSONRPCErrorRenderer.methodNotAllowed())
    }
}

/// Per-request auth outcome, mirroring the Executor's 4-way `AuthOutcome`.
/// Never failing: providers return a value, never throw.
public enum MCPAuthOutcome: Sendable, Equatable {
    /// Authenticated; continue to the session short-circuit, then dispatch.
    case authenticated
    /// 401 with the outcome's own challenge, else the default challenge.
    case unauthorized(challenge: String?)
    /// 403 with the provider's message and optional code (default -32001).
    case forbidden(code: Int?, message: String)
    /// 503 with `Retry-After` for a transient auth outage.
    case unavailable(message: String)
}

/// Session-store dispatch discriminant. A handled request passes through to
/// the transport (no envelope rendering); the other arms render here.
public enum MCPDispatchVerdict: Sendable, Equatable {
    /// The store handled the request; its response passes through untouched.
    case handled
    /// Unknown or expired session id.
    case notFound
    /// Session belongs to another bearer or resource.
    case forbidden
}

/// Envelope decision: answer now or dispatch to the session store.
public enum MCPEnvelopeDecision: Sendable, Equatable {
    /// Answer with this rendered response.
    case respond(MCPEnvelopeResponse)
    /// Forward to the session store / transport.
    case dispatch
}

/// Pure serving pipeline: method → auth → session short-circuit → dispatch.
/// `auth` and `dispatch` are autoclosures so each stage runs only when every
/// earlier stage passed — the gate order the envelope guarantees.
public enum MCPEnvelopePipeline {
    /// Decides one request. `sessionID` is the `mcp-session-id` header value,
    /// when present; `resourceMetadataURL` feeds the default 401 challenge.
    public static func decide(
        method: String,
        sessionID: String?,
        resourceMetadataURL: String,
        auth: @autoclosure () -> MCPAuthOutcome,
        dispatch: @autoclosure () -> MCPDispatchVerdict
    ) -> MCPEnvelopeDecision {
        switch MCPHTTPMethodGate.evaluate(method: method) {
        case .preflight(let response):
            return .respond(response)
        case .rejected(let response):
            return .respond(response)
        case .allowed:
            break
        }
        switch auth() {
        case .authenticated:
            break
        case .unauthorized(let challenge):
            return .respond(
                MCPJSONRPCErrorRenderer.unauthorized(
                    challenge: challenge
                        ?? MCPJSONRPCErrorRenderer.defaultChallenge(
                            resourceMetadataURL: resourceMetadataURL
                        )
                )
            )
        case .forbidden(let code, let message):
            return .respond(
                MCPJSONRPCErrorRenderer.forbidden(
                    message: message, code: code ?? MCPJSONRPCErrorCode.authSession.rawValue
                )
            )
        case .unavailable(let message):
            return .respond(MCPJSONRPCErrorRenderer.unavailable(message: message))
        }
        // No session id: only POST opens a session. A GET needs an existing
        // id (400); a DELETE on nothing is a no-op (204). Both short-circuit
        // before dispatch so the store never spins up an engine. Absent and
        // empty both count as missing, mirroring the envelope's falsy check.
        let hasSessionID = sessionID.map({ $0.isEmpty == false }) ?? false
        if hasSessionID == false {
            if method == "GET" {
                return .respond(MCPJSONRPCErrorRenderer.sessionIDRequiredForSSE())
            }
            if method == "DELETE" {
                return .respond(MCPJSONRPCErrorRenderer.sessionlessDelete())
            }
        }
        switch dispatch() {
        case .handled:
            return .dispatch
        case .notFound:
            return .respond(MCPJSONRPCErrorRenderer.sessionNotFound(method: method))
        case .forbidden:
            return .respond(MCPJSONRPCErrorRenderer.sessionOwnership())
        }
    }
}

// MARK: - Pre-initialize guard

/// Pre-initialize dispatch guard. Only `initialize` can open a session, and
/// the transport answers every other pre-session method with a
/// connection-killing HTTP 400 — so a client leading with an optional probe
/// is disconnected before it can fall back. JSON-RPC already has the right
/// answer: -32601 on a normal HTTP 200, a per-request error the connection
/// survives.
///
/// The guard replaces that one transport answer and must not shadow any
/// other, so it fires only where it is the whole story: a POST that clears
/// the transport's content negotiation AND carries a structurally valid
/// single JSON-RPC request for a method other than `initialize`. Everything
/// else — non-POST, bad negotiation, unparseable or oversized bodies,
/// batches, notifications, responses, structurally invalid requests,
/// `initialize` itself — falls through untouched (nil).
public enum MCPPreInitializeGuard {
    /// The only method that opens a session.
    public static let initializeMethod = "initialize"

    /// The transport's POST content negotiation, mirrored: `Accept` must list
    /// both `application/json` and `text/event-stream` (else its 406), and
    /// `Content-Type` must include `application/json` (else its 415). These
    /// are the SDK's own substring tests; matching is case-sensitive.
    public static func passesContentNegotiation(accept: String?, contentType: String?) -> Bool {
        guard let accept, accept.contains("application/json"),
            accept.contains("text/event-stream")
        else {
            return false
        }
        guard let contentType, contentType.contains("application/json") else {
            return false
        }
        return true
    }

    /// Evaluates one session-less POST body, returning the inner -32601 answer
    /// when the guard fires, else nil. Never throws: bodies outside the
    /// guard's story fall through to the transport.
    public static func evaluate(
        method: String, accept: String?, contentType: String?, body: Data
    ) -> MCPEnvelopeResponse? {
        guard method == "POST" else { return nil }
        guard passesContentNegotiation(accept: accept, contentType: contentType) else { return nil }
        guard case .success(.request(let request)) = MCPJSONRPCCodec.decode(body) else { return nil }
        guard request.method != initializeMethod else { return nil }
        return MCPJSONRPCErrorRenderer.methodNotFound(id: request.id)
    }
}

// MARK: - ToolError vocabulary

/// Caller-visible expected-failure codes. Mirrors the Executor's
/// `expectedToolFailure` mapping (tool-invoker.ts) plus the
/// `AuthToolFailureCode` union (auth-tool-failure.ts): dispatch misses,
/// policy blocks, argument mismatches, binding failures, and the six
/// credential/OAuth failures. Unknown codes never decode: the vocabulary is
/// closed, so callers can switch exhaustively.
public enum MCPToolErrorCode: String, Sendable, Equatable, Codable, CaseIterable {
    /// No tool at the path. Details carry the path plus suggestions.
    case toolNotFound = "tool_not_found"
    /// Policy blocked the tool. Details carry the path plus the pattern.
    case toolBlocked = "tool_blocked"
    /// Arguments missed the input schema (or the OpenAPI pre-flight message).
    case invalidToolArguments = "invalid_tool_arguments"
    /// Role/connection binding failed. Details name role/integration/connection.
    case bindingError = "binding_error"
    /// The connection holds no credential value.
    case connectionValueMissing = "connection_value_missing"
    /// The upstream rejected the credential (a 401 is a refresh trigger).
    case connectionRejected = "connection_rejected"
    /// The referenced OAuth connection does not exist.
    case oauthConnectionMissing = "oauth_connection_missing"
    /// Minting or refreshing the OAuth grant failed.
    case oauthRefreshFailed = "oauth_refresh_failed"
    /// The grant is dead; the user must reauthorize.
    case oauthReauthRequired = "oauth_reauth_required"
    /// The grant lacks the scope the operation needs; re-running the same
    /// grant returns the same error, so recovery reconnects, never retries.
    case oauthScopeInsufficient = "oauth_scope_insufficient"

    /// Whether blind retry can succeed. False for every code: misses, blocks,
    /// mismatches, and auth walls need a changed input, a policy edit, or a
    /// user action — never a bare re-send. (A 401 `connection_rejected` still
    /// triggers one token refresh via `isUnauthorizedRefreshTrigger`, which
    /// is a re-mint, not a retry.)
    public var retryable: Bool { false }

    /// True for the six credential/OAuth codes, whose details carry the
    /// `authentication` category plus recovery hints.
    public var isAuthentication: Bool {
        switch self {
        case .connectionValueMissing, .connectionRejected, .oauthConnectionMissing,
            .oauthRefreshFailed, .oauthReauthRequired, .oauthScopeInsufficient:
            return true
        case .toolNotFound, .toolBlocked, .invalidToolArguments, .bindingError:
            return false
        }
    }
}

/// `tool_not_found` details: the sandbox path plus up-to-five suggestions.
/// Strict keys: `path`, `suggestions`.
public struct MCPToolNotFoundDetails: Sendable, Equatable {
    /// Sandbox path (the `tools.` prefix stripped), a label, never a value.
    public let path: String
    /// Alternate paths, closest first. Absent reads as empty.
    public let suggestions: [String]

    /// Assembles not-found details.
    public init(path: String, suggestions: [String]) {
        self.path = path
        self.suggestions = suggestions
    }
}

extension MCPToolNotFoundDetails: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StrictJSONKey.self)
        try rejectUnknownKeys(container, allowed: ["path", "suggestions"])
        let path = try container.decode(String.self, forKey: StrictJSONKey("path"))
        let suggestions = try decodeStrictOptional([String].self, forKey: StrictJSONKey("suggestions"), in: container) ?? []
        self.init(path: path, suggestions: suggestions)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StrictJSONKey.self)
        try container.encode(path, forKey: StrictJSONKey("path"))
        try container.encode(suggestions, forKey: StrictJSONKey("suggestions"))
    }
}

/// `tool_blocked` details: the path plus the blocking pattern label, which
/// the policy always names (mirroring the Executor, whose blocked details
/// carry the whole `{address, pattern}` value).
/// Strict keys: `path`, `pattern`.
public struct MCPToolBlockedDetails: Sendable, Equatable {
    /// Sandbox path of the blocked tool.
    public let path: String
    /// Blocking pattern label.
    public let pattern: String

    /// Assembles blocked details.
    public init(path: String, pattern: String) {
        self.path = path
        self.pattern = pattern
    }
}

extension MCPToolBlockedDetails: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StrictJSONKey.self)
        try rejectUnknownKeys(container, allowed: ["path", "pattern"])
        let path = try container.decode(String.self, forKey: StrictJSONKey("path"))
        let pattern = try container.decode(String.self, forKey: StrictJSONKey("pattern"))
        self.init(path: path, pattern: pattern)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StrictJSONKey.self)
        try container.encode(path, forKey: StrictJSONKey("path"))
        try container.encode(pattern, forKey: StrictJSONKey("pattern"))
    }
}

/// `invalid_tool_arguments` details: schema issues from schema validation.
/// (An OpenAPI pre-flight message stands alone with nil details instead.)
/// The key is always present, so the shape never collapses to `{}` and
/// re-decodes as empty binding details. Strict keys: `issues`.
public struct MCPInvalidArgumentsDetails: Sendable, Equatable {
    /// Schema issues (`{path, message}` shapes). Absent reads as empty.
    public let issues: [JSONValue]

    /// Assembles invalid-arguments details.
    public init(issues: [JSONValue] = []) {
        self.issues = issues
    }
}

extension MCPInvalidArgumentsDetails: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StrictJSONKey.self)
        try rejectUnknownKeys(container, allowed: ["issues"])
        let issues = try decodeStrictOptional([JSONValue].self, forKey: StrictJSONKey("issues"), in: container) ?? []
        self.init(issues: issues)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StrictJSONKey.self)
        try container.encode(issues, forKey: StrictJSONKey("issues"))
    }
}

/// `binding_error` details: the role/integration/requested-connection labels.
/// Strict keys: `role`, `integration`, `requestedConnection`.
public struct MCPBindingDetails: Sendable, Equatable {
    /// Role label, when known.
    public let role: String?
    /// Integration label, when known.
    public let integration: String?
    /// Requested connection label, when known.
    public let requestedConnection: String?

    /// Assembles binding details.
    public init(role: String? = nil, integration: String? = nil, requestedConnection: String? = nil) {
        self.role = role
        self.integration = integration
        self.requestedConnection = requestedConnection
    }
}

extension MCPBindingDetails: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StrictJSONKey.self)
        try rejectUnknownKeys(container, allowed: ["role", "integration", "requestedConnection"])
        let role = try decodeStrictOptional(String.self, forKey: StrictJSONKey("role"), in: container)
        let integration = try decodeStrictOptional(String.self, forKey: StrictJSONKey("integration"), in: container)
        let requestedConnection = try decodeStrictOptional(String.self, forKey: StrictJSONKey("requestedConnection"), in: container)
        self.init(role: role, integration: integration, requestedConnection: requestedConnection)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StrictJSONKey.self)
        try container.encodeIfPresent(role, forKey: StrictJSONKey("role"))
        try container.encodeIfPresent(integration, forKey: StrictJSONKey("integration"))
        try container.encodeIfPresent(
            requestedConnection, forKey: StrictJSONKey("requestedConnection")
        )
    }
}

/// Integration half of auth-failure details: labels only.
/// Strict keys: `id`, `scope`.
public struct MCPAuthIntegration: Sendable, Equatable {
    /// Integration id label.
    public let id: String
    /// Scope label, when the failure names one.
    public let scope: String?

    /// Assembles the integration half.
    public init(id: String, scope: String? = nil) {
        self.id = id
        self.scope = scope
    }
}

extension MCPAuthIntegration: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StrictJSONKey.self)
        try rejectUnknownKeys(container, allowed: ["id", "scope"])
        let id = try container.decode(String.self, forKey: StrictJSONKey("id"))
        let scope = try decodeStrictOptional(String.self, forKey: StrictJSONKey("scope"), in: container)
        self.init(id: id, scope: scope)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StrictJSONKey.self)
        try container.encode(id, forKey: StrictJSONKey("id"))
        try container.encodeIfPresent(scope, forKey: StrictJSONKey("scope"))
    }
}

/// Credential kind: which mint the failure concerns. Labels only — no value
/// fits this shape.
public enum MCPAuthCredentialKind: String, Sendable, Equatable, Codable {
    /// Pasted secret / API key credential.
    case secret
    /// OAuth grant credential.
    case oauth
    /// Upstream-issued credential.
    case upstream
}

/// Credential half of auth-failure details: identifiers, never values.
/// Strict keys: `kind`, `label`, `slotKey`, `secretId`, `connectionId`.
public struct MCPAuthCredential: Sendable, Equatable {
    /// Which mint the failure concerns.
    public let kind: MCPAuthCredentialKind
    /// Connection label (`<integration>.<owner>.<name>`), when known.
    public let label: String?
    /// Credential slot key, when known.
    public let slotKey: String?
    /// Secret id, when known.
    public let secretId: String?
    /// Connection id, when known.
    public let connectionId: String?

    /// Assembles the credential half.
    public init(
        kind: MCPAuthCredentialKind, label: String? = nil, slotKey: String? = nil,
        secretId: String? = nil, connectionId: String? = nil
    ) {
        self.kind = kind
        self.label = label
        self.slotKey = slotKey
        self.secretId = secretId
        self.connectionId = connectionId
    }
}

extension MCPAuthCredential: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StrictJSONKey.self)
        try rejectUnknownKeys(
            container, allowed: ["kind", "label", "slotKey", "secretId", "connectionId"]
        )
        let kind = try container.decode(MCPAuthCredentialKind.self, forKey: StrictJSONKey("kind"))
        let label = try decodeStrictOptional(String.self, forKey: StrictJSONKey("label"), in: container)
        let slotKey = try decodeStrictOptional(String.self, forKey: StrictJSONKey("slotKey"), in: container)
        let secretId = try decodeStrictOptional(String.self, forKey: StrictJSONKey("secretId"), in: container)
        let connectionId = try decodeStrictOptional(String.self, forKey: StrictJSONKey("connectionId"), in: container)
        self.init(
            kind: kind, label: label, slotKey: slotKey, secretId: secretId,
            connectionId: connectionId
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StrictJSONKey.self)
        try container.encode(kind, forKey: StrictJSONKey("kind"))
        try container.encodeIfPresent(label, forKey: StrictJSONKey("label"))
        try container.encodeIfPresent(slotKey, forKey: StrictJSONKey("slotKey"))
        try container.encodeIfPresent(secretId, forKey: StrictJSONKey("secretId"))
        try container.encodeIfPresent(connectionId, forKey: StrictJSONKey("connectionId"))
    }
}

/// Upstream half of auth-failure details: the status plus structured upstream
/// facts (such as the authorization server's RFC 6749 verdict).
/// Strict keys: `status`, `details`.
public struct MCPAuthUpstream: Sendable, Equatable {
    /// Upstream HTTP status, when the failure carries one.
    public let status: Int?
    /// Structured upstream facts, when the failure carries any.
    public let details: JSONValue?

    /// Assembles the upstream half.
    public init(status: Int? = nil, details: JSONValue? = nil) {
        self.status = status
        self.details = details
    }
}

extension MCPAuthUpstream: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StrictJSONKey.self)
        try rejectUnknownKeys(container, allowed: ["status", "details"])
        let status = try decodeStrictOptional(Int.self, forKey: StrictJSONKey("status"), in: container)
        let details = try decodeStrictOptional(JSONValue.self, forKey: StrictJSONKey("details"), in: container)
        self.init(status: status, details: details)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StrictJSONKey.self)
        try container.encodeIfPresent(status, forKey: StrictJSONKey("status"))
        try container.encodeIfPresent(details, forKey: StrictJSONKey("details"))
    }
}

/// Recovery hints for auth failures. Exact Executor vocabulary
/// (auth-tool-failure.ts): tool names the agent can call plus the
/// instructions for guiding the user through the fix. Two builders: the
/// standard branch (re-mint or re-authorize, then retry) and the
/// scope-insufficient branch (reconnect with broader access — deliberately no
/// re-authenticate tools, since re-running the same grant loops on the same
/// 403). Strict keys: the seven hint fields.
public struct MCPToolErrorRecovery: Sendable, Equatable {
    /// Connection-handoff tool for API keys and tokens.
    public let createConnectionTool: String?
    /// OAuth start tool.
    public let startOAuthTool: String?
    /// Connections list tool.
    public let listConnectionsTool: String?
    /// Integration configuration tool, when the caller names one.
    public let configureIntegrationTool: String?
    /// How to fix key/token failures.
    public let connectionInstructions: String?
    /// How to fix OAuth failures.
    public let oauthInstructions: String?
    /// How to fix scope-insufficient failures (scope branch only).
    public let scopeInstructions: String?

    /// Exact Executor tool name.
    public static let createConnectionToolName = "executor.coreTools.connections.createHandoff"
    /// Exact Executor tool name.
    public static let startOAuthToolName = "executor.coreTools.oauth.start"
    /// Exact Executor tool name.
    public static let listConnectionsToolName = "executor.coreTools.connections.list"
    /// Exact Executor instructions.
    public static let connectionInstructionsText =
        "For API keys and tokens, call createConnectionTool for the integration to get a browser URL; the user enters the credential there, which creates the bound connection. Do not ask the user to paste secrets into chat. Then call listConnectionsTool to confirm the connection exists before retrying this tool."
    /// Exact Executor instructions.
    public static let oauthInstructionsText =
        "For OAuth credentials, call startOAuthTool and give the returned authorizationUrl to the user. The completed connection binds automatically, then retry the tool."
    /// Exact Executor instructions.
    public static let scopeInstructionsText =
        "The connection's OAuth grant does not cover the scope this operation requires; re-authenticating with the same grant will return the same error. Tell the user which operation was denied and ask them to reconnect the integration with broader access (or use a connection that already has it). Call listConnectionsTool to see the available connections and their scopes."

    /// Assembles recovery hints from validated parts.
    public init(
        createConnectionTool: String? = nil, startOAuthTool: String? = nil,
        listConnectionsTool: String? = nil, configureIntegrationTool: String? = nil,
        connectionInstructions: String? = nil, oauthInstructions: String? = nil,
        scopeInstructions: String? = nil
    ) {
        self.createConnectionTool = createConnectionTool
        self.startOAuthTool = startOAuthTool
        self.listConnectionsTool = listConnectionsTool
        self.configureIntegrationTool = configureIntegrationTool
        self.connectionInstructions = connectionInstructions
        self.oauthInstructions = oauthInstructions
        self.scopeInstructions = scopeInstructions
    }

    /// Standard branch: re-mint or re-authorize, then retry.
    public static func standard(configureIntegrationTool: String? = nil) -> MCPToolErrorRecovery {
        MCPToolErrorRecovery(
            createConnectionTool: createConnectionToolName, startOAuthTool: startOAuthToolName,
            listConnectionsTool: listConnectionsToolName,
            configureIntegrationTool: configureIntegrationTool,
            connectionInstructions: connectionInstructionsText,
            oauthInstructions: oauthInstructionsText, scopeInstructions: nil
        )
    }

    /// Scope-insufficient branch: reconnect with broader access. No
    /// re-authenticate tools: the same grant returns the same error.
    public static func scopeInsufficient(
        configureIntegrationTool: String? = nil
    ) -> MCPToolErrorRecovery {
        MCPToolErrorRecovery(
            createConnectionTool: nil, startOAuthTool: nil,
            listConnectionsTool: listConnectionsToolName,
            configureIntegrationTool: configureIntegrationTool,
            connectionInstructions: nil, oauthInstructions: nil,
            scopeInstructions: scopeInstructionsText
        )
    }
}

extension MCPToolErrorRecovery: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StrictJSONKey.self)
        try rejectUnknownKeys(
            container,
            allowed: [
                "createConnectionTool", "startOAuthTool", "listConnectionsTool",
                "configureIntegrationTool", "connectionInstructions", "oauthInstructions",
                "scopeInstructions",
            ]
        )
        self.init(
            createConnectionTool: try decodeStrictOptional(String.self, forKey: StrictJSONKey("createConnectionTool"), in: container),
            startOAuthTool: try decodeStrictOptional(String.self, forKey: StrictJSONKey("startOAuthTool"), in: container),
            listConnectionsTool: try decodeStrictOptional(String.self, forKey: StrictJSONKey("listConnectionsTool"), in: container),
            configureIntegrationTool: try decodeStrictOptional(String.self, forKey: StrictJSONKey("configureIntegrationTool"), in: container),
            connectionInstructions: try decodeStrictOptional(String.self, forKey: StrictJSONKey("connectionInstructions"), in: container),
            oauthInstructions: try decodeStrictOptional(String.self, forKey: StrictJSONKey("oauthInstructions"), in: container),
            scopeInstructions: try decodeStrictOptional(String.self, forKey: StrictJSONKey("scopeInstructions"), in: container)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StrictJSONKey.self)
        try container.encodeIfPresent(
            createConnectionTool, forKey: StrictJSONKey("createConnectionTool")
        )
        try container.encodeIfPresent(startOAuthTool, forKey: StrictJSONKey("startOAuthTool"))
        try container.encodeIfPresent(
            listConnectionsTool, forKey: StrictJSONKey("listConnectionsTool")
        )
        try container.encodeIfPresent(
            configureIntegrationTool, forKey: StrictJSONKey("configureIntegrationTool")
        )
        try container.encodeIfPresent(
            connectionInstructions, forKey: StrictJSONKey("connectionInstructions")
        )
        try container.encodeIfPresent(oauthInstructions, forKey: StrictJSONKey("oauthInstructions"))
        try container.encodeIfPresent(scopeInstructions, forKey: StrictJSONKey("scopeInstructions"))
    }
}

/// Auth-failure details: the `authentication` category plus the integration,
/// credential, and upstream halves and the recovery hints.
/// Strict keys: `category`, `integration`, `credential`, `upstream`, `recovery`.
public struct MCPAuthFailureDetails: Sendable, Equatable {
    /// Always `authentication`.
    public let category: String
    /// Integration half, when the failure names one.
    public let integration: MCPAuthIntegration?
    /// Credential half, when the failure names one.
    public let credential: MCPAuthCredential?
    /// Upstream half, when the failure carries one.
    public let upstream: MCPAuthUpstream?
    /// Recovery hints for the agent.
    public let recovery: MCPToolErrorRecovery

    /// Category constant.
    public static let authenticationCategory = "authentication"

    /// Assembles auth-failure details.
    public init(
        integration: MCPAuthIntegration? = nil, credential: MCPAuthCredential? = nil,
        upstream: MCPAuthUpstream? = nil, recovery: MCPToolErrorRecovery
    ) {
        self.category = Self.authenticationCategory
        self.integration = integration
        self.credential = credential
        self.upstream = upstream
        self.recovery = recovery
    }
}

extension MCPAuthFailureDetails: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StrictJSONKey.self)
        try rejectUnknownKeys(
            container, allowed: ["category", "integration", "credential", "upstream", "recovery"]
        )
        let category = try container.decode(String.self, forKey: StrictJSONKey("category"))
        guard category == Self.authenticationCategory else {
            throw DecodingError.dataCorruptedError(
                forKey: StrictJSONKey("category"), in: container,
                debugDescription: "category must be \"authentication\""
            )
        }
        self.init(
            integration: try decodeStrictOptional(MCPAuthIntegration.self, forKey: StrictJSONKey("integration"), in: container),
            credential: try decodeStrictOptional(MCPAuthCredential.self, forKey: StrictJSONKey("credential"), in: container),
            upstream: try decodeStrictOptional(MCPAuthUpstream.self, forKey: StrictJSONKey("upstream"), in: container),
            recovery: try container.decode(
                MCPToolErrorRecovery.self, forKey: StrictJSONKey("recovery")
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StrictJSONKey.self)
        try container.encode(category, forKey: StrictJSONKey("category"))
        try container.encodeIfPresent(integration, forKey: StrictJSONKey("integration"))
        try container.encodeIfPresent(credential, forKey: StrictJSONKey("credential"))
        try container.encodeIfPresent(upstream, forKey: StrictJSONKey("upstream"))
        try container.encode(recovery, forKey: StrictJSONKey("recovery"))
    }
}

/// Per-code details shapes. Decoding tries each shape in order — not-found,
/// blocked, authentication, binding, invalid-arguments — and the strict keys
/// keep the shapes disjoint, except that a bare `{}` reads as empty binding
/// details and a path-only object reads as not-found (both deterministic).
public enum MCPToolErrorDetails: Sendable, Equatable {
    /// `tool_not_found` details.
    case toolNotFound(MCPToolNotFoundDetails)
    /// `tool_blocked` details.
    case toolBlocked(MCPToolBlockedDetails)
    /// `invalid_tool_arguments` details.
    case invalidArguments(MCPInvalidArgumentsDetails)
    /// `binding_error` details.
    case binding(MCPBindingDetails)
    /// Auth-code details.
    case authentication(MCPAuthFailureDetails)
}

extension MCPToolErrorDetails: Codable {
    public init(from decoder: Decoder) throws {
        if let value = try? MCPToolNotFoundDetails(from: decoder) {
            self = .toolNotFound(value)
            return
        }
        if let value = try? MCPToolBlockedDetails(from: decoder) {
            self = .toolBlocked(value)
            return
        }
        if let value = try? MCPAuthFailureDetails(from: decoder) {
            self = .authentication(value)
            return
        }
        if let value = try? MCPBindingDetails(from: decoder) {
            self = .binding(value)
            return
        }
        if let value = try? MCPInvalidArgumentsDetails(from: decoder) {
            self = .invalidArguments(value)
            return
        }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "unknown ToolError details shape"
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .toolNotFound(let value):
            try value.encode(to: encoder)
        case .toolBlocked(let value):
            try value.encode(to: encoder)
        case .invalidArguments(let value):
            try value.encode(to: encoder)
        case .binding(let value):
            try value.encode(to: encoder)
        case .authentication(let value):
            try value.encode(to: encoder)
        }
    }
}

/// Caller-visible expected failure: `{code, message, status?, details?,
/// retryable}`. Expected failures are values (the `fail` arm of
/// `MCPToolResult`), never defects. Strict keys.
public struct MCPToolError: Sendable, Equatable {
    /// Closed code vocabulary.
    public let code: MCPToolErrorCode
    /// Caller-safe message: labels only, never secret values.
    public let message: String
    /// Upstream HTTP status, when the failure carries one.
    public let status: Int?
    /// Per-code details, when the failure carries any.
    public let details: MCPToolErrorDetails?
    /// Whether blind retry can succeed. Absent reads as the code default.
    public let retryable: Bool

    /// Assembles a tool error from validated parts.
    public init(
        code: MCPToolErrorCode, message: String, status: Int? = nil,
        details: MCPToolErrorDetails? = nil, retryable: Bool = false
    ) {
        self.code = code
        self.message = message
        self.status = status
        self.details = details
        self.retryable = retryable
    }
}

extension MCPToolError: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StrictJSONKey.self)
        try rejectUnknownKeys(
            container, allowed: ["code", "message", "status", "details", "retryable"]
        )
        let code = try container.decode(MCPToolErrorCode.self, forKey: StrictJSONKey("code"))
        let message = try container.decode(String.self, forKey: StrictJSONKey("message"))
        let status = try decodeStrictOptional(Int.self, forKey: StrictJSONKey("status"), in: container)
        let details = try decodeStrictOptional(MCPToolErrorDetails.self, forKey: StrictJSONKey("details"), in: container)
        let retryable = try decodeStrictOptional(Bool.self, forKey: StrictJSONKey("retryable"), in: container) ?? code.retryable
        self.init(code: code, message: message, status: status, details: details, retryable: retryable)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StrictJSONKey.self)
        try container.encode(code, forKey: StrictJSONKey("code"))
        try container.encode(message, forKey: StrictJSONKey("message"))
        try container.encodeIfPresent(status, forKey: StrictJSONKey("status"))
        try container.encodeIfPresent(details, forKey: StrictJSONKey("details"))
        try container.encode(retryable, forKey: StrictJSONKey("retryable"))
    }
}

extension MCPToolError {
    /// `tool_not_found` with the exact Executor message and details.
    public static func toolNotFound(path: String, suggestions: [String]) -> MCPToolError {
        MCPToolError(
            code: .toolNotFound, message: "Tool not found: \(path)",
            details: .toolNotFound(MCPToolNotFoundDetails(path: path, suggestions: suggestions))
        )
    }

    /// `tool_blocked` with the exact Executor message and details.
    public static func toolBlocked(path: String, pattern: String) -> MCPToolError {
        MCPToolError(
            code: .toolBlocked, message: "Tool blocked by policy: \(path)",
            details: .toolBlocked(MCPToolBlockedDetails(path: path, pattern: pattern))
        )
    }

    /// `invalid_tool_arguments` for schema validation, with the exact
    /// Executor message and issues.
    public static func invalidArguments(issues: [JSONValue]) -> MCPToolError {
        MCPToolError(
            code: .invalidToolArguments,
            message: "Tool arguments did not match the input schema.",
            details: .invalidArguments(MCPInvalidArgumentsDetails(issues: issues))
        )
    }

    /// `invalid_tool_arguments` for an OpenAPI pre-flight message: locally
    /// generated from the spec (no upstream data), safe to surface, with nil
    /// details.
    public static func invalidArgumentsPreflight(message: String) -> MCPToolError {
        MCPToolError(code: .invalidToolArguments, message: message, details: nil)
    }

    /// `binding_error`. Details stay nil when no label is known, mirroring
    /// the Executor (which omits empty details); the default message covers
    /// a missing locally generated one.
    public static func binding(
        message: String?, role: String? = nil, integration: String? = nil,
        requestedConnection: String? = nil
    ) -> MCPToolError {
        let details: MCPToolErrorDetails?
        if role == nil, integration == nil, requestedConnection == nil {
            details = nil
        } else {
            details = .binding(
                MCPBindingDetails(
                    role: role, integration: integration,
                    requestedConnection: requestedConnection
                )
            )
        }
        return MCPToolError(
            code: .bindingError, message: message ?? "Tool binding failed.", details: details
        )
    }

    /// Auth-code failure with the `authentication` category, the halves the
    /// caller names, and the recovery hints for the code: the standard branch
    /// for every auth code except `oauth_scope_insufficient`, which takes the
    /// reconnect branch. Documented precondition: `code.isAuthentication`;
    /// other codes still build a well-formed value.
    public static func authentication(
        code: MCPToolErrorCode, message: String, status: Int? = nil,
        integration: MCPAuthIntegration? = nil, credential: MCPAuthCredential? = nil,
        upstream: MCPAuthUpstream? = nil, configureIntegrationTool: String? = nil
    ) -> MCPToolError {
        let recovery: MCPToolErrorRecovery
        if code == .oauthScopeInsufficient {
            recovery = .scopeInsufficient(configureIntegrationTool: configureIntegrationTool)
        } else {
            recovery = .standard(configureIntegrationTool: configureIntegrationTool)
        }
        return MCPToolError(
            code: code, message: message, status: status,
            details: .authentication(
                MCPAuthFailureDetails(
                    integration: integration, credential: credential, upstream: upstream,
                    recovery: recovery
                )
            )
        )
    }

    /// `oauth_reauth_required` with the exact Executor message shape. The
    /// authorization server's RFC 6749 verdict rides structured in
    /// `upstream.details.oauthErrorCode` when the caller names one.
    public static func oauthReauthRequired(
        label: String, message: String, oauthErrorCode: String? = nil
    ) -> MCPToolError {
        authentication(
            code: .oauthReauthRequired,
            message: "OAuth connection \"\(label)\" requires reauthorization: \(message)",
            credential: MCPAuthCredential(kind: .oauth, label: label),
            upstream: upstreamForOAuthCode(oauthErrorCode)
        )
    }

    /// `oauth_refresh_failed` with the exact Executor message shape.
    public static func oauthRefreshFailed(
        label: String, message: String, oauthErrorCode: String? = nil
    ) -> MCPToolError {
        authentication(
            code: .oauthRefreshFailed,
            message: "OAuth connection \"\(label)\" could not be resolved: \(message)",
            credential: MCPAuthCredential(kind: .oauth, label: label),
            upstream: upstreamForOAuthCode(oauthErrorCode)
        )
    }

    private static func upstreamForOAuthCode(_ oauthErrorCode: String?) -> MCPAuthUpstream? {
        if let oauthErrorCode {
            return MCPAuthUpstream(
                details: .object(["oauthErrorCode": .string(oauthErrorCode)])
            )
        }
        return nil
    }

    /// Whether this failure triggers one reactive token refresh: exactly
    /// `connection_rejected` plus HTTP 401 — the upstream saying "this
    /// credential is not valid". Deliberately exact: 403s and
    /// `oauth_scope_insufficient` mean authenticated-but-not-permitted (a
    /// re-mint returns the identical answer), and the refresh path's own
    /// failures must not refresh in response to a failed refresh.
    public static func isUnauthorizedRefreshTrigger(_ error: MCPToolError) -> Bool {
        error.code == .connectionRejected && error.status == 401
    }
}

// MARK: - ToolResult contract

/// Transport metadata for HTTP-backed tools: beside `data`, never wrapped
/// around it, so pagination and rate-limit headers stay reachable.
/// Strict keys: `status`, `headers`.
public struct MCPToolHTTPMeta: Sendable, Equatable {
    /// Upstream HTTP status.
    public let status: Int
    /// Upstream headers, at most `maxHTTPHeaderCount`.
    public let headers: [String: String]

    /// Assembles HTTP metadata from validated parts.
    public init(status: Int, headers: [String: String]) {
        self.status = status
        self.headers = headers
    }
}

extension MCPToolHTTPMeta: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StrictJSONKey.self)
        try rejectUnknownKeys(container, allowed: ["status", "headers"])
        let status = try container.decode(Int.self, forKey: StrictJSONKey("status"))
        let headers = try container.decode([String: String].self, forKey: StrictJSONKey("headers"))
        guard headers.count <= MCPJSONRPCLimits.maxHTTPHeaderCount else {
            throw DecodingError.dataCorruptedError(
                forKey: StrictJSONKey("headers"), in: container,
                debugDescription: "headers exceed 64 entries"
            )
        }
        self.init(status: status, headers: headers)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StrictJSONKey.self)
        try container.encode(status, forKey: StrictJSONKey("status"))
        try container.encode(headers, forKey: StrictJSONKey("headers"))
    }
}

/// Typed file value: `{_tag: "ToolFile", name?, mimeType, encoding: "base64",
/// data, byteLength}`. Decoding checks the tag, the encoding, the base64, the
/// non-negative length, and that the decoded bytes match `byteLength`.
/// Strict keys.
public struct MCPToolFile: Sendable, Equatable {
    /// File name, when the tool names one.
    public let name: String?
    /// MIME type. Never empty.
    public let mimeType: String
    /// Base64-encoded file bytes, at most `maxFileBase64Characters`.
    public let data: String
    /// Raw file size in bytes before base64 encoding.
    public let byteLength: Int

    /// Assembles a file value from validated parts.
    public init(name: String?, mimeType: String, data: String, byteLength: Int) {
        self.name = name
        self.mimeType = mimeType
        self.data = data
        self.byteLength = byteLength
    }
}

extension MCPToolFile: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StrictJSONKey.self)
        try rejectUnknownKeys(
            container, allowed: ["_tag", "name", "mimeType", "encoding", "data", "byteLength"]
        )
        let tag = try container.decode(String.self, forKey: StrictJSONKey("_tag"))
        guard tag == "ToolFile" else {
            throw DecodingError.dataCorruptedError(
                forKey: StrictJSONKey("_tag"), in: container,
                debugDescription: "_tag must be \"ToolFile\""
            )
        }
        let encoding = try container.decode(String.self, forKey: StrictJSONKey("encoding"))
        guard encoding == "base64" else {
            throw DecodingError.dataCorruptedError(
                forKey: StrictJSONKey("encoding"), in: container,
                debugDescription: "encoding must be \"base64\""
            )
        }
        let name = try decodeStrictOptional(String.self, forKey: StrictJSONKey("name"), in: container)
        let mimeType = try container.decode(String.self, forKey: StrictJSONKey("mimeType"))
        guard mimeType.isEmpty == false else {
            throw DecodingError.dataCorruptedError(
                forKey: StrictJSONKey("mimeType"), in: container,
                debugDescription: "mimeType must not be empty"
            )
        }
        let data = try container.decode(String.self, forKey: StrictJSONKey("data"))
        guard data.count <= MCPJSONRPCLimits.maxFileBase64Characters else {
            throw DecodingError.dataCorruptedError(
                forKey: StrictJSONKey("data"), in: container,
                debugDescription: "file data exceeds 262144 characters"
            )
        }
        let byteLength = try container.decode(Int.self, forKey: StrictJSONKey("byteLength"))
        guard byteLength >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: StrictJSONKey("byteLength"), in: container,
                debugDescription: "byteLength must not be negative"
            )
        }
        guard let decoded = Data(base64Encoded: data) else {
            throw DecodingError.dataCorruptedError(
                forKey: StrictJSONKey("data"), in: container,
                debugDescription: "file data is not base64"
            )
        }
        guard decoded.count == byteLength else {
            throw DecodingError.dataCorruptedError(
                forKey: StrictJSONKey("byteLength"), in: container,
                debugDescription: "byteLength does not match decoded data"
            )
        }
        self.init(name: name, mimeType: mimeType, data: data, byteLength: byteLength)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StrictJSONKey.self)
        try container.encode("ToolFile", forKey: StrictJSONKey("_tag"))
        try container.encodeIfPresent(name, forKey: StrictJSONKey("name"))
        try container.encode(mimeType, forKey: StrictJSONKey("mimeType"))
        try container.encode("base64", forKey: StrictJSONKey("encoding"))
        try container.encode(data, forKey: StrictJSONKey("data"))
        try container.encode(byteLength, forKey: StrictJSONKey("byteLength"))
    }
}

/// Typed invocation outcome: `{ok: true, data, http?} | {ok: false, error}`.
/// Domain success and expected failure both ride the success channel; only
/// true infra defects throw. Strict keys; each arm rejects the other's keys.
public enum MCPToolResult: Sendable, Equatable {
    /// Success with data plus optional HTTP metadata.
    case ok(data: JSONValue, http: MCPToolHTTPMeta?)
    /// Expected failure value.
    case fail(error: MCPToolError)
}

extension MCPToolResult: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StrictJSONKey.self)
        try rejectUnknownKeys(container, allowed: ["ok", "data", "http", "error"])
        let ok = try container.decode(Bool.self, forKey: StrictJSONKey("ok"))
        if ok {
            guard container.contains(StrictJSONKey("error")) == false else {
                throw DecodingError.dataCorruptedError(
                    forKey: StrictJSONKey("error"), in: container,
                    debugDescription: "ok result must not carry error"
                )
            }
            let data = try container.decode(JSONValue.self, forKey: StrictJSONKey("data"))
            let http = try decodeStrictOptional(MCPToolHTTPMeta.self, forKey: StrictJSONKey("http"), in: container)
            self = .ok(data: data, http: http)
        } else {
            guard container.contains(StrictJSONKey("data")) == false,
                container.contains(StrictJSONKey("http")) == false
            else {
                throw DecodingError.dataCorruptedError(
                    forKey: StrictJSONKey("data"), in: container,
                    debugDescription: "fail result must not carry data"
                )
            }
            let error = try container.decode(MCPToolError.self, forKey: StrictJSONKey("error"))
            self = .fail(error: error)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StrictJSONKey.self)
        switch self {
        case .ok(let data, let http):
            try container.encode(true, forKey: StrictJSONKey("ok"))
            try container.encode(data, forKey: StrictJSONKey("data"))
            try container.encodeIfPresent(http, forKey: StrictJSONKey("http"))
        case .fail(let error):
            try container.encode(false, forKey: StrictJSONKey("ok"))
            try container.encode(error, forKey: StrictJSONKey("error"))
        }
    }
}
