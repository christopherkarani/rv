import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(SQLite3)
import SQLite3
#endif
import RVDomain
import RVFileStore

// MARK: - Item ownership (executor provider-item-owner.ts)

// Oracle: provider-item-owner.ts — `connection:`/`oauth:`/`oauth-client:`
// ids embed their owning partition in the second colon segment; every
// other id (legacy random `secret_*`) carries none.

/// Credential partition a provider item id embeds, if any.
///
/// Alias for the shared `MCPSecretsOwner` (RVDomain); the encrypted
/// and WorkOS Vault providers file under one partition type with one
/// `embeddedOwner`.
public typealias WorkOSVaultOwner = MCPSecretsOwner

/// Request binding: which tenant (and whose subject) an operation runs as.
///
/// The connection row that references an id owns the (tenant, owner,
/// subject) partition; the binding scopes vault object names and KEK
/// contexts so partitions never collide. A nil subject is an automation
/// context: org rows stay visible, user rows do not. Mirrors executor
/// `OwnerBinding`.
public struct WorkOSVaultOwnerBinding: Sendable, Equatable {
    /// Tenant slug. Never empty; validated at provider init.
    public let tenant: String
    /// Subject slug, or nil for automation contexts.
    public let subject: String?

    public init(tenant: String, subject: String? = nil) {
        self.tenant = tenant
        self.subject = subject
    }
}

/// Item-id prefixes whose second colon segment is the owning partition.
///
/// Binding-shaped projections over the shared `MCPSecretsOwner`: the
/// partition rule lives in RVDomain; this namespace keeps the
/// binding-fallback spelling (`embedded(in:)`/`ownerForItem(id:binding:)`)
/// the provider and its tests call.
public enum WorkOSVaultItemOwner: Sendable {
    /// Prefixes from provider-item-owner.ts, pinned verbatim.
    public static let scopedPrefixes: Set<String> = MCPSecretsOwner.scopedPrefixes

    /// The owner a logical item id embeds, or nil for legacy ids.
    /// Delegates to the shared rule.
    public static func embedded(in id: String) -> WorkOSVaultOwner? {
        MCPSecretsOwner.embeddedOwner(itemID: id)
    }

    /// The partition a credential belongs to: the credential's owner
    /// (embedded in the id), not the acting caller's binding. Ids without
    /// an embedded owner fall back to the caller binding: a bound subject
    /// writes the user's own partition, otherwise the org-shared one.
    public static func ownerForItem(id: String, binding: WorkOSVaultOwnerBinding) -> WorkOSVaultOwner {
        MCPSecretsOwner.embeddedOwner(itemID: id) ?? (binding.subject == nil ? .org : .user)
    }
}

// MARK: - Configuration

/// WorkOS Vault client misconfiguration. Fixed labels only, never
/// endpoints, tenants, subjects, or key material.
public enum WorkOSVaultConfigurationError: Error, Sendable, Equatable {
    /// Endpoint is not an http(s) URL with a host and empty path.
    case invalidEndpoint
    /// Plain http targets a non-loopback host.
    case httpNotAllowedForNonLoopback
    /// API key is empty.
    case emptyAPIKey
    /// Timeout is nonpositive, nonfinite, or above 60 seconds.
    case invalidTimeout
    /// Object prefix is empty or carries a slash or whitespace.
    case invalidPrefix
    /// Tenant binding is empty.
    case emptyTenant
    /// Subject binding is present but empty. An empty subject would file
    /// a phantom partition no binding ever reads.
    case emptySubject
}

/// One HTTP round trip: request to response body plus status.
///
/// Production wraps a URLSession; tests inject a stub-session closure so
/// every test runs deterministically with no network. Mirrors
/// `VaultTransport` deliberately.
typealias WorkOSVaultTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

/// Typed WorkOS Vault KV client over REST (executor client.ts port).
///
/// Speaks the `/vault/v1/kv` shape the generated SDKs use: Bearer auth,
/// `POST /vault/v1/kv` create with `key_context`, `GET
/// /vault/v1/kv/name/{name}` read, `PUT /vault/v1/kv/{id}` update with an
/// optional `version_check`, `DELETE /vault/v1/kv/{id}` delete, and `GET
/// /vault/v1/kv` list. Every non-2xx response throws a
/// `WorkOSVaultClientError` carrying the operation label, the status, and
/// the KEK retry kind — never server text, names, ids, or values. Read
/// 400/404 mapping to "missing" lives one layer up
/// (`WorkOSVaultSecretsProvider.loadObject`), exactly like executor's
/// `loadSecretObject` over the throwing client.
public struct WorkOSVaultHTTPClient: Sendable {
    /// WorkOS API base URL (scheme, host, port only; no path).
    public let endpoint: URL
    /// API key sent as `Authorization: Bearer`. Internal: only the request
    /// builder reads it, so no caller can leak or log it.
    let apiKey: String
    /// Per-request timeout in seconds.
    public let timeoutSeconds: Double

    private let transport: WorkOSVaultTransport

    /// Default WorkOS API base URL.
    public static let defaultEndpoint = "https://api.workos.com"
    /// Default per-request timeout.
    public static let defaultTimeoutSeconds = 10.0
    /// Largest single HTTP body accepted (1 MiB). Larger fails as oversized.
    public static let maximumResponseBytes = 1_048_576

    /// Live client over URLSession. Validates endpoint, key, and timeout.
    public init(
        endpoint: URL,
        apiKey: String,
        timeoutSeconds: Double = WorkOSVaultHTTPClient.defaultTimeoutSeconds
    ) throws(WorkOSVaultConfigurationError) {
        try Self.validate(endpoint: endpoint)
        try Self.validate(apiKey: apiKey)
        try Self.validate(timeoutSeconds: timeoutSeconds)
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.timeoutSeconds = timeoutSeconds
        self.transport = Self.liveTransport()
    }

    /// Test client over an injected stub transport. Same validation as
    /// the live init; the stub never performs a handshake.
    init(
        endpoint: URL,
        apiKey: String,
        timeoutSeconds: Double,
        transport: @escaping WorkOSVaultTransport
    ) throws(WorkOSVaultConfigurationError) {
        try Self.validate(endpoint: endpoint)
        try Self.validate(apiKey: apiKey)
        try Self.validate(timeoutSeconds: timeoutSeconds)
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.timeoutSeconds = timeoutSeconds
        self.transport = transport
    }
}

// MARK: - Client redaction

/// Key material never prints: a fixed placeholder in both `description`
/// and `debugDescription`, so crash reports, debug logs, and test-failure
/// output cannot carry the API key (the `MCPCallerToken` precedent).
extension WorkOSVaultHTTPClient: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "WorkOSVaultHTTPClient(<redacted>)"
    }

    public var debugDescription: String {
        description
    }
}

// MARK: - Client validation

extension WorkOSVaultHTTPClient {
    static func validate(endpoint: URL) throws(WorkOSVaultConfigurationError) {
        guard let scheme = endpoint.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = endpoint.host, host.isEmpty == false,
            endpoint.user == nil, endpoint.password == nil,
            endpoint.query == nil, endpoint.fragment == nil,
            endpoint.path.isEmpty || endpoint.path == "/"
        else {
            throw WorkOSVaultConfigurationError.invalidEndpoint
        }
        if scheme == "http" {
            let loopback = host.lowercased() == "127.0.0.1"
                || host.lowercased() == "localhost"
                || host == "::1"
                || host == "[::1]"
            if loopback == false {
                throw WorkOSVaultConfigurationError.httpNotAllowedForNonLoopback
            }
        }
    }

    static func validate(apiKey: String) throws(WorkOSVaultConfigurationError) {
        if apiKey.isEmpty {
            throw WorkOSVaultConfigurationError.emptyAPIKey
        }
    }

    static func validate(timeoutSeconds: Double) throws(WorkOSVaultConfigurationError) {
        guard timeoutSeconds.isFinite, timeoutSeconds > 0, timeoutSeconds <= 60 else {
            throw WorkOSVaultConfigurationError.invalidTimeout
        }
    }
}

// MARK: - Client operations

extension WorkOSVaultHTTPClient {
    /// Creates one object. 2xx decodes the id-bearing answer; anything
    /// else throws, including 409 (a peer won the create race; the
    /// provider loop treats it as contention, never an error).
    public func createObject(
        name: String, value: String, context: [String: String]
    ) async throws -> WorkOSVaultObjectMetadata {
        let payload = WorkOSVaultCreateRequest(name: name, value: value, keyContext: context)
        guard let encoded = try? JSONEncoder().encode(payload) else {
            throw WorkOSVaultClientError(operation: "create_object", kind: .decode, retryKind: nil)
        }
        let (body, response) = try await send(postJSON(url: joining("/vault/v1/kv"), body: encoded), operation: "create_object")
        let status = response.statusCode
        guard status >= 200 && status <= 299 else {
            throw Self.statusError(operation: "create_object", status: status, body: body)
        }
        guard let decoded = try? JSONDecoder().decode(WorkOSVaultCreateResponse.self, from: body),
            decoded.id.isEmpty == false,
            let versionID = decoded.metadata?.versionID, versionID.isEmpty == false
        else {
            throw WorkOSVaultClientError(operation: "create_object", kind: .decode, retryKind: nil)
        }
        return WorkOSVaultObjectMetadata(id: decoded.id, versionID: versionID)
    }

    /// Reads one object by name. Non-2xx throws, including the 400/404
    /// the provider maps to missing.
    public func readObjectByName(_ name: String) async throws -> WorkOSVaultObject {
        let path = "/vault/v1/kv/name/\(Self.encodePathSegment(name))"
        let (body, response) = try await send(
            authedGet(url: joining(path)), operation: "read_object_by_name"
        )
        let status = response.statusCode
        guard status >= 200 && status <= 299 else {
            throw Self.statusError(operation: "read_object_by_name", status: status, body: body)
        }
        guard let decoded = try? JSONDecoder().decode(WorkOSVaultObjectResponse.self, from: body),
            let object = WorkOSVaultObject(validating: decoded)
        else {
            throw WorkOSVaultClientError(operation: "read_object_by_name", kind: .decode, retryKind: nil)
        }
        return object
    }

    /// Updates one object by id, optionally against an expected version.
    /// 409 (or a stale-version 400) throws for the provider loop to
    /// treat as contention.
    public func updateObject(
        id: String, value: String, versionCheck: String? = nil
    ) async throws -> WorkOSVaultObject {
        let payload = WorkOSVaultUpdateRequest(value: value, versionCheck: versionCheck)
        guard let encoded = try? JSONEncoder().encode(payload) else {
            throw WorkOSVaultClientError(operation: "update_object", kind: .decode, retryKind: nil)
        }
        let path = "/vault/v1/kv/\(Self.encodePathSegment(id))"
        let (body, response) = try await send(putJSON(url: joining(path), body: encoded), operation: "update_object")
        let status = response.statusCode
        guard status >= 200 && status <= 299 else {
            throw Self.statusError(operation: "update_object", status: status, body: body)
        }
        guard let decoded = try? JSONDecoder().decode(WorkOSVaultObjectResponse.self, from: body),
            let object = WorkOSVaultObject(validating: decoded)
        else {
            throw WorkOSVaultClientError(operation: "update_object", kind: .decode, retryKind: nil)
        }
        return object
    }

    /// Deletes one object by id. 2xx is done; the answer body is ignored.
    /// A raced 404 throws: like executor, delete-after-read is not
    /// idempotent against a peer deleter.
    public func deleteObject(id: String) async throws {
        let path = "/vault/v1/kv/\(Self.encodePathSegment(id))"
        var request = authedGet(url: joining(path))
        request.httpMethod = "DELETE"
        let (body, response) = try await send(request, operation: "delete_object")
        let status = response.statusCode
        guard status >= 200 && status <= 299 else {
            throw Self.statusError(operation: "delete_object", status: status, body: body)
        }
    }

    /// Lists objects, newest cursor default. The envelope (`{data:[...]}`)
    /// and a bare array both decode; anything else is a decode error.
    /// Health probes through here with `limit: 1`.
    public func listObjects(limit: Int = 10) async throws -> [WorkOSVaultObject] {
        let clamped = min(max(limit, 1), 100)
        let (body, response) = try await send(
            authedGet(url: joining("/vault/v1/kv?limit=\(clamped)")), operation: "list_objects")
        let status = response.statusCode
        guard status >= 200 && status <= 299 else {
            throw Self.statusError(operation: "list_objects", status: status, body: body)
        }
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(WorkOSVaultListResponse.self, from: body) {
            let objects = envelope.data.compactMap(WorkOSVaultObject.init(validating:))
            guard objects.count == envelope.data.count else {
                throw WorkOSVaultClientError(operation: "list_objects", kind: .decode, retryKind: nil)
            }
            return objects
        }
        if let bare = try? decoder.decode([WorkOSVaultObjectResponse].self, from: body) {
            let objects = bare.compactMap(WorkOSVaultObject.init(validating:))
            guard objects.count == bare.count else {
                throw WorkOSVaultClientError(operation: "list_objects", kind: .decode, retryKind: nil)
            }
            return objects
        }
        throw WorkOSVaultClientError(operation: "list_objects", kind: .decode, retryKind: nil)
    }
}

// MARK: - Requests and transport

extension WorkOSVaultHTTPClient {
    /// Shared system-trust session. Redirects are refused, so the Bearer
    /// key never follows a 3xx off-origin; sharing keeps keep-alive
    /// across calls. Reuses the Vault delegate: same shape, same reason.
    private static let sharedSession = URLSession(
        configuration: .ephemeral, delegate: VaultNoRedirectDelegate(), delegateQueue: nil
    )

    static func liveTransport() -> WorkOSVaultTransport {
        { request in
            let (data, response) = try await Self.sharedSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            return (data, http)
        }
    }

    func joining(_ path: String) -> URL {
        var base = endpoint.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + path) ?? endpoint
    }

    func authedGet(url: URL) -> URLRequest {
        var request = URLRequest(
            url: url, cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeoutSeconds
        )
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpShouldHandleCookies = false
        return request
    }

    func postJSON(url: URL, body: Data) -> URLRequest {
        var request = URLRequest(
            url: url, cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeoutSeconds
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        request.httpShouldHandleCookies = false
        return request
    }

    func putJSON(url: URL, body: Data) -> URLRequest {
        var request = postJSON(url: url, body: body)
        request.httpMethod = "PUT"
        return request
    }

    /// Encodes one path segment (object name or id): unreserved
    /// characters pass through, everything else (including `/` and `%`)
    /// percent-encodes as UTF-8 with uppercase hex, so a scoped name
    /// travels as a single segment. Total over all inputs.
    static func encodePathSegment(_ segment: String) -> String {
        WorkOSVaultObjectNaming.percentEncode(segment, allowing: .rfc3986Unreserved)
    }

    /// Sends one request: a thrown `SecretsError` passes through (stub
    /// flexibility, mirroring `VaultHTTPClient.send`), cancellation
    /// rethrows, anything else maps to a transport kind. An over-cap
    /// body fails as oversized before status handling.
    func send(_ request: URLRequest, operation: String) async throws -> (Data, HTTPURLResponse) {
        let body: Data
        let response: HTTPURLResponse
        do {
            let (data, raw) = try await transport(request)
            body = data
            response = raw
        } catch let error as SecretsError {
            throw error
        } catch {
            if error is CancellationError {
                throw error
            }
            throw Self.mapTransportError(error, operation: operation)
        }
        guard body.count <= Self.maximumResponseBytes else {
            throw WorkOSVaultClientError(
                operation: operation, kind: .oversized, retryKind: nil
            )
        }
        return (body, response)
    }

    static func statusError(
        operation: String, status: Int, body: Data
    ) -> WorkOSVaultClientError {
        WorkOSVaultClientError(
            operation: operation, kind: .httpStatus(status),
            retryKind: Self.retryKind(forBody: body)
        )
    }

    static func mapTransportError(_ error: Error, operation: String) -> WorkOSVaultClientError {
        let kind: WorkOSVaultClientError.Kind
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                kind = .timeout
            case .serverCertificateHasBadDate, .serverCertificateUntrusted,
                .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
                .clientCertificateRejected, .clientCertificateRequired,
                .secureConnectionFailed:
                kind = .tls
            default:
                kind = .unreachable
            }
        } else {
            kind = .unreachable
        }
        return WorkOSVaultClientError(operation: operation, kind: kind, retryKind: nil)
    }

    /// KEK retry kind from an error body: the WorkOS message ends with
    /// the pinned suffix (executor `isKekNotReadyWorkOSCause`). Only the
    /// decoded `message` field is consulted; non-JSON bodies, missing
    /// messages, and near-miss suffixes are not KEK errors. The text
    /// itself is never retained: detection only.
    static func retryKind(forBody body: Data) -> WorkOSVaultClientError.RetryKind? {
        guard let envelope = try? JSONDecoder().decode(
            WorkOSVaultErrorResponse.self, from: body
        ),
            let message = envelope.message,
            message.hasSuffix(WorkOSVaultClientError.kekNotReadySuffix)
        else {
            return nil
        }
        return .kekNotReady
    }
}

// MARK: - Client errors and payloads

/// Typed WorkOS Vault failure (executor `WorkOSVaultClientError` port).
///
/// Carries the operation label, the failure kind, and the KEK retry
/// kind — never server text, object names, ids, values, or key
/// material. Opacity is structural: there is no field for any of it.
public struct WorkOSVaultClientError: Error, Sendable, Equatable {
    /// Failure kind. HTTP statuses stay numeric so the provider layer
    /// can apply executor's status rules (400/404 missing, 409/400
    /// contention) without parsing text.
    public enum Kind: Sendable, Equatable {
        /// HTTP error status.
        case httpStatus(Int)
        /// Request timed out.
        case timeout
        /// Host unreachable or connection refused.
        case unreachable
        /// TLS verification failed.
        case tls
        /// Response exceeded the body cap.
        case oversized
        /// Request encode or response decode failed.
        case decode
    }

    /// Retryable Vault condition, executor `retryKind` port.
    public enum RetryKind: Sendable, Equatable {
        /// The per-context KEK exists but is not usable yet; the whole
        /// attempt (read + write) may be retried.
        case kekNotReady
    }

    /// Operation label (`create_object`, `read_object_by_name`,
    /// `update_object`, `delete_object`, `list_objects`).
    public let operation: String
    /// Failure kind.
    public let kind: Kind
    /// Retryable condition, if detected.
    public let retryKind: RetryKind?

    /// Pinned KEK suffix, executor `WORKOS_KEK_NOT_READY_MESSAGE` verbatim.
    public static let kekNotReadySuffix =
        "KEK was created but is not yet ready. This request can be retried."

    public init(operation: String, kind: Kind, retryKind: RetryKind?) {
        self.operation = operation
        self.kind = kind
        self.retryKind = retryKind
    }

    /// HTTP status when the kind carries one.
    public var status: Int? {
        if case .httpStatus(let status) = kind {
            return status
        }
        return nil
    }
}

/// One Vault object: id, validated metadata, name, optional value.
public struct WorkOSVaultObject: Sendable, Equatable {
    public let id: String
    public let metadata: WorkOSVaultObjectMetadata
    public let name: String
    public let value: String?

    public init(id: String, metadata: WorkOSVaultObjectMetadata, name: String, value: String?) {
        self.id = id
        self.metadata = metadata
        self.name = name
        self.value = value
    }

    /// Validates a decoded answer: non-empty id and version. Lenient
    /// about everything else (the API carries far more than writes need).
    init?(validating decoded: WorkOSVaultObjectResponse) {
        guard decoded.id.isEmpty == false,
            let versionID = decoded.metadata?.versionID, versionID.isEmpty == false
        else {
            return nil
        }
        self.init(
            id: decoded.id,
            metadata: WorkOSVaultObjectMetadata(id: decoded.id, versionID: versionID),
            name: decoded.name ?? "",
            value: decoded.value
        )
    }
}

/// Object metadata the provider needs: id plus the version id that
/// anchors optimistic-locking writes.
public struct WorkOSVaultObjectMetadata: Sendable, Equatable {
    public let id: String
    public let versionID: String

    public init(id: String, versionID: String) {
        self.id = id
        self.versionID = versionID
    }
}

/// Create request: the REST field is `key_context` (the SDK names the
/// same input `context`).
private struct WorkOSVaultCreateRequest: Encodable, Sendable {
    var name: String
    var value: String
    var keyContext: [String: String]

    private enum CodingKeys: String, CodingKey {
        case name
        case value
        case keyContext = "key_context"
    }
}

/// Update request: new value plus an optional expected version.
private struct WorkOSVaultUpdateRequest: Encodable, Sendable {
    var value: String
    var versionCheck: String?

    private enum CodingKeys: String, CodingKey {
        case value
        case versionCheck = "version_check"
    }
}

/// Decoded object answer. Only id, name, value, and the version id are
/// read; the API's remaining metadata is ignored.
struct WorkOSVaultObjectResponse: Decodable, Sendable {
    var id: String
    var name: String?
    var value: String?
    var metadata: WorkOSVaultMetadataResponse?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case value
        case metadata
    }
}

/// Decoded metadata answer: the version id only.
struct WorkOSVaultMetadataResponse: Decodable, Sendable {
    var versionID: String?

    private enum CodingKeys: String, CodingKey {
        case versionID = "version_id"
    }
}

/// Decoded create answer: id plus metadata. Both the full-object and
/// the metadata-only answer shapes carry these.
private struct WorkOSVaultCreateResponse: Decodable, Sendable {
    var id: String
    var metadata: WorkOSVaultMetadataResponse?

    private enum CodingKeys: String, CodingKey {
        case id
        case metadata
    }
}

/// Decoded list envelope.
private struct WorkOSVaultListResponse: Decodable, Sendable {
    var data: [WorkOSVaultObjectResponse]

    private enum CodingKeys: String, CodingKey {
        case data
    }
}

/// Decoded error envelope: the message only, for KEK detection.
private struct WorkOSVaultErrorResponse: Decodable, Sendable {
    var message: String?

    private enum CodingKeys: String, CodingKey {
        case message
    }
}

// MARK: - Object naming (executor secret-store.ts naming port)

/// Partition-scoped Vault object naming.
///
/// A logical item id carries no tenant and no subject, so the name
/// encodes the partition: `{prefix}/user/{tenant}/{subject}/secrets/{id}`
/// for user credentials, `{prefix}/org/{tenant}/secrets/{id}` for org
/// ones (mirroring `ownerForItemId`), and the flat
/// `{prefix}/secrets/{id}` for legacy ids that embed no owner. Segments
/// are `encodeURIComponent`-encoded because ids carry `/` and `:`.
///
/// Names past 200 characters swap the encoded-id tail for a sha256
/// digest (`h~` + base64url, unpadded): WorkOS accepts longer names on
/// create but every read of one fails with 400, by name and by id
/// (executor comment: verified against the live API 2026-06-10). The
/// partition head stays literal so the name remains attributable, and
/// `h~` cannot collide with an encoded literal id (scoped ids start
/// with their `connection`/`oauth`/`oauth-client` prefix).
public enum WorkOSVaultObjectNaming: Sendable {
    /// Default object prefix, executor `DEFAULT_OBJECT_PREFIX`.
    public static let defaultPrefix = "executor"
    /// Longest readable object name, executor `MAX_OBJECT_NAME_LENGTH`.
    public static let maximumNameLength = 200

    /// Validates an object prefix: non-empty, no slash (it is the name
    /// head, joined with `/`), no whitespace or control characters.
    public static func validate(prefix: String) throws(WorkOSVaultConfigurationError) {
        guard prefix.isEmpty == false,
            prefix.contains("/") == false,
            prefix.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) == false }),
            prefix.unicodeScalars.allSatisfy({ $0.properties.generalCategory != .control })
        else {
            throw WorkOSVaultConfigurationError.invalidPrefix
        }
    }

    /// `encodeURIComponent` over one segment: `[A-Za-z0-9]` plus
    /// `-_.!~*'()` pass through, everything else percent-encodes as
    /// UTF-8 with uppercase hex. Pinned against the JS builtin's table
    /// (notably the unescaped `'`).
    public static func encodeSegment(_ segment: String) -> String {
        percentEncode(segment, allowing: .encodeURIComponent)
    }

    /// Byte sets for `percentEncode`.
    enum AllowedBytes: Sendable {
        /// JS `encodeURIComponent` survivors (note the unescaped `'`).
        case encodeURIComponent
        /// RFC 3986 unreserved set.
        case rfc3986Unreserved
    }

    /// Total percent-encoder: allowed bytes pass through, every other
    /// UTF-8 byte becomes `%XX` with uppercase hex. Manual rather than
    /// Foundation's failable API so the function is total.
    static func percentEncode(_ text: String, allowing set: AllowedBytes) -> String {
        var encoded = ""
        encoded.reserveCapacity(text.utf8.count)
        for byte in text.utf8 {
            if isAllowed(byte, in: set) {
                encoded.append(Character(Unicode.Scalar(byte)))
            } else {
                encoded.append("%")
                encoded.append(nibbleChar(byte >> 4))
                encoded.append(nibbleChar(byte & 0x0F))
            }
        }
        return encoded
    }

    /// Whether one byte survives unescaped under a set.
    static func isAllowed(_ byte: UInt8, in set: AllowedBytes) -> Bool {
        if byte >= 0x30 && byte <= 0x39 { return true }
        if byte >= 0x41 && byte <= 0x5A { return true }
        if byte >= 0x61 && byte <= 0x7A { return true }
        switch byte {
        case 0x2D, 0x5F, 0x2E, 0x7E:
            return true
        case 0x21, 0x27, 0x28, 0x29, 0x2A:
            return set == .encodeURIComponent
        default:
            return false
        }
    }

    /// Uppercase hex character for one nibble.
    static func nibbleChar(_ nibble: UInt8) -> Character {
        nibble < 10 ? Character(Unicode.Scalar(0x30 + nibble)) : Character(Unicode.Scalar(0x37 + nibble))
    }

    /// Partition path segments for an id, or nil for legacy ids that
    /// carry no embedded owner (those keep the flat, unscoped name).
    /// Ports executor `objectScopeSegments`.
    public static func scopeSegments(
        id: String, binding: WorkOSVaultOwnerBinding
    ) -> [String]? {
        guard let owner = MCPSecretsOwner.embeddedOwner(itemID: id) else {
            return nil
        }
        let tenant = encodeSegment(binding.tenant)
        switch owner {
        case .user:
            return ["user", tenant, encodeSegment(binding.subject ?? "")]
        case .org:
            return ["org", tenant]
        }
    }

    /// Vault object name for one id under one binding. Total: hashing
    /// cannot fail (the hex decoder below is total over nibbles). The
    /// cap counts UTF-16 units, exactly like executor's JS `.length`:
    /// "201 never reads" was measured in those units, and mixed
    /// implementations sharing one vault must hash identically.
    public static func objectName(
        prefix: String, id: String, binding: WorkOSVaultOwnerBinding
    ) -> String {
        let head: String
        if let scope = scopeSegments(id: id, binding: binding) {
            head = "\(prefix)/\(scope.joined(separator: "/"))"
        } else {
            head = prefix
        }
        let name = "\(head)/secrets/\(encodeSegment(id))"
        if name.utf16.count <= maximumNameLength {
            return name
        }
        return "\(head)/secrets/h~\(sha256Base64URL(id))"
    }

    /// KEK-matching context for a credential. Logical ids get a
    /// per-tenant (and per-user) context so WorkOS provisions an
    /// isolated KEK per partition; legacy ids keep the original shared
    /// context so existing objects stay decryptable. Ports executor
    /// `vaultContextFor`. Values stay colon-free by construction.
    public static func contextFor(
        id: String, binding: WorkOSVaultOwnerBinding
    ) -> [String: String] {
        guard let owner = MCPSecretsOwner.embeddedOwner(itemID: id) else {
            return ["app": "executor"]
        }
        var context = ["app": "executor", "organization_id": binding.tenant]
        if owner == .user {
            context["user_id"] = binding.subject ?? ""
        }
        return context
    }

    /// sha256 of UTF-8 text as unpadded base64url, via the audited
    /// project core (`RVDigest`). Total over all inputs.
    public static func sha256Base64URL(_ text: String) -> String {
        let bytes = hexBytes(RVDigest.sha256Hex(Array(text.utf8)))
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Total hex decode: each pair of nibbles becomes one byte;
    /// non-nibble characters decode as zero. The only production input
    /// is `RVDigest` output (always 64 lowercase nibbles), so the
    /// zero rule never fires there; it keeps the function total.
    static func hexBytes(_ hex: String) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        let scalars = Array(hex.unicodeScalars)
        var index = 0
        while index + 1 < scalars.count {
            bytes.append(nibbleValue(scalars[index]) << 4 | nibbleValue(scalars[index + 1]))
            index += 2
        }
        return bytes
    }

    /// Total nibble value: hex digits decode, anything else is zero.
    static func nibbleValue(_ scalar: Unicode.Scalar) -> UInt8 {
        let value = scalar.value
        if value >= 48 && value <= 57 {
            return UInt8(value - 48)
        }
        if value >= 97 && value <= 102 {
            return UInt8(value - 87)
        }
        if value >= 65 && value <= 70 {
            return UInt8(value - 55)
        }
        return 0
    }
}

// MARK: - Retry policy and seams

/// Clock source for metadata timestamps. Production uses `Date.init`;
/// tests inject a fixed date.
public typealias WorkOSVaultClock = @Sendable () -> Date

/// Jitter draw in [0, 1) for conflict backoff. Production passes a
/// random draw; tests inject fixed values. Out-of-range draws clamp.
public typealias WorkOSVaultJitterSource = @Sendable () -> Double

/// Backoff sleep in seconds. Production sleeps the wall clock; tests
/// inject a recording no-op. Cancellation propagates; any other
/// failure aborts the retry as `providerDown("workos-vault:retry")`.
public typealias WorkOSVaultSleeper = @Sendable (Double) async throws -> Void

/// Write-retry scheduling policy: bounded attempts, bounded backoff
/// (executor `upsertSecretValue` constants, pinned verbatim).
public struct WorkOSVaultRetryPolicy: Sendable, Equatable {
    /// Version-checked write attempts before the last-resort
    /// un-versioned write.
    public static let defaultMaxWriteAttempts = 5
    /// Conflict backoff base: first ceiling is 50 ms.
    public static let defaultConflictBackoffBaseMs = 50.0
    /// Conflict backoff ceiling cap.
    public static let defaultConflictBackoffCapMs = 800.0
    /// Whole-attempt retries while the KEK is not ready.
    public static let defaultMaxKEKAttempts = 20
    /// Fixed delay between KEK retries.
    public static let defaultKEKBackoffMs = 1_000.0

    /// Version-checked write attempts before the blind write.
    public let maxWriteAttempts: Int
    /// Conflict backoff base in milliseconds.
    public let conflictBackoffBaseMs: Double
    /// Conflict backoff ceiling cap in milliseconds.
    public let conflictBackoffCapMs: Double
    /// Whole-attempt retries while the KEK is not ready.
    public let maxKEKAttempts: Int
    /// Fixed KEK retry delay in milliseconds.
    public let kekBackoffMs: Double

    public init(
        maxWriteAttempts: Int = defaultMaxWriteAttempts,
        conflictBackoffBaseMs: Double = defaultConflictBackoffBaseMs,
        conflictBackoffCapMs: Double = defaultConflictBackoffCapMs,
        maxKEKAttempts: Int = defaultMaxKEKAttempts,
        kekBackoffMs: Double = defaultKEKBackoffMs
    ) {
        self.maxWriteAttempts = max(1, maxWriteAttempts)
        self.conflictBackoffBaseMs = max(0, conflictBackoffBaseMs)
        self.conflictBackoffCapMs = max(0, conflictBackoffCapMs)
        self.maxKEKAttempts = max(1, maxKEKAttempts)
        self.kekBackoffMs = max(0, kekBackoffMs)
    }

    /// Half-jittered exponential backoff for attempt `n` (1-based) in
    /// seconds: a wait drawn from [d/2, d) where d =
    /// base * 2^(n-1), capped. The jitter matters more than the delay —
    /// two writers that back off by the same amount simply collide
    /// again one beat later. Ports `writeConflictBackoffMillis`.
    public func conflictBackoffSeconds(attempt: Int, jitterUnit: Double) -> Double {
        let unit = min(max(jitterUnit, 0), 1)
        let shift = max(attempt - 1, 0)
        let ceiling = min(conflictBackoffBaseMs * pow(2, Double(shift)), conflictBackoffCapMs)
        return (ceiling / 2 + unit * (ceiling / 2)) / 1_000
    }

    /// Fixed KEK retry delay in seconds.
    public var kekBackoffSeconds: Double { kekBackoffMs / 1_000 }
}

// MARK: - Metadata store (executor makeWorkosVaultStore port)

/// One metadata row: what the provider knows about an id. Values live
/// in Vault; this tracks names, purposes, and creation order for
/// enumeration. Ports executor `MetadataRow`.
public struct WorkOSVaultMetadataRow: Sendable, Equatable {
    /// Opaque provider item id.
    public let id: String
    /// Display name (defaults to the id at first write).
    public let name: String
    /// Purpose label, if recorded.
    public let purpose: String?
    /// Creation time; list order.
    public let createdAt: Date

    public init(id: String, name: String, purpose: String?, createdAt: Date) {
        self.id = id
        self.name = name
        self.purpose = purpose
        self.createdAt = createdAt
    }
}

/// Metadata-store failure. One fixed label: rows, tenants, subjects,
/// and SQLite diagnostics never surface.
public enum WorkOSVaultStoreError: Error, Sendable, Equatable {
    /// The store could not open, read, or write.
    case storeFailure
}

/// Metadata storage over (tenant, owner, subject, id).
///
/// Writes file under the credential's partition (`ownerForItemId`);
/// reads and lists apply executor's visibility (`org` rows plus the
/// caller's own `user` rows for bound subjects; `org` rows only for
/// automation contexts). Lists sort by creation time, oldest first.
/// The production backend is `WorkOSVaultMetadataStore` (SQLite);
/// tests inject scripted fakes for failure mapping.
public protocol WorkOSVaultMetadata: Sendable {
    /// Visible row for one id, if any.
    func get(id: String, tenant: String, subject: String?) async throws -> WorkOSVaultMetadataRow?
    /// Files one row under its credential partition.
    func upsert(
        _ row: WorkOSVaultMetadataRow, tenant: String, owner: WorkOSVaultOwner, subject: String?
    ) async throws
    /// Removes the visible row for one id: the same row `get` would
    /// return (first visible partition in `get` order). Reports whether
    /// a visible row existed. Unlike executor's `remove` (which deletes
    /// the caller-computed partition and can orphan a row filed under a
    /// different binding), this deletes the row actually found, so a
    /// cross-context delete never leaves a ghost row behind.
    func remove(
        id: String, tenant: String, subject: String?
    ) async throws -> Bool
    /// Visible rows, oldest first.
    func list(tenant: String, subject: String?) async throws -> [WorkOSVaultMetadataRow]
}

/// SQLite-backed metadata store. One store per provider; providers
/// that share a path share partitions (cross-member resolution).
///
/// Schema: `metadata(tenant, owner, subject, id, name, purpose,
/// created_at_ms)` with the four-way primary key. Every SQLite
/// failure maps to `.storeFailure` with no payload. The connection is
/// actor-confined; statements never outlive one call. On platforms
/// without the SQLite module the same API runs over an in-memory map.
public actor WorkOSVaultMetadataStore: WorkOSVaultMetadata {
    /// Metadata database file name beside the sibling operator stores.
    public static let fileName = "workos-vault-metadata.sqlite"

    #if canImport(SQLite3)
    private let handle: WorkOSVaultDBHandle
    #else
    private var rows: [WorkOSVaultPartitionKey: WorkOSVaultMetadataRow] = [:]
    /// Insertion sequence per key, mirroring SQLite's rowid tiebreak:
    /// every upsert (including a replace, like INSERT OR REPLACE's new
    /// rowid) takes the next sequence, so equal-timestamp lists keep
    /// insertion order instead of dictionary order.
    private var insertionSequence: [WorkOSVaultPartitionKey: Int] = [:]
    private var nextSequence = 0
    #endif

    /// Opens (creating) the database at `path`, or an ephemeral store
    /// for `:memory:`. Parent directories are the caller's job. The file
    /// is pre-created owner-only (0600) and pre-existing files are
    /// tightened to 0600: the database carries secret ids, names, and
    /// purposes, so it joins the owner-only discipline instead of
    /// inheriting umask perms from `sqlite3_open(CREATE)`.
    public init(path: String) throws(WorkOSVaultStoreError) {
        #if canImport(SQLite3)
        if path != ":memory:" {
            try Self.ensureOwnerOnlyFile(path: path)
        }
        var raw: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let status = path.withCString { cPath in
            sqlite3_open_v2(cPath, &raw, flags, nil)
        }
        guard status == SQLITE_OK, let opened = raw else {
            // sqlite3_close tolerates NULL; the handle is usually set
            // even on failure and must not leak.
            _ = sqlite3_close(raw)
            throw WorkOSVaultStoreError.storeFailure
        }
        guard Self.execute("CREATE TABLE IF NOT EXISTS metadata (" +
            "tenant TEXT NOT NULL, owner TEXT NOT NULL, subject TEXT NOT NULL, " +
            "id TEXT NOT NULL, name TEXT NOT NULL, purpose TEXT, " +
            "created_at_ms INTEGER NOT NULL, " +
            "PRIMARY KEY (tenant, owner, subject, id))", on: opened)
        else {
            _ = sqlite3_close(opened)
            throw WorkOSVaultStoreError.storeFailure
        }
        self.handle = WorkOSVaultDBHandle(opened)
        #endif
    }

    #if canImport(SQLite3)
    /// Pre-creates the database file at `path` with mode 0600
    /// (`O_CREAT|O_EXCL`, so no umask-permissioned window exists) and
    /// tightens any pre-existing regular file to 0600. Non-regular paths
    /// (notably a directory squatting the path) skip tightening — the
    /// `sqlite3_open` below fails closed on them anyway.
    static func ensureOwnerOnlyFile(path: String) throws(WorkOSVaultStoreError) {
        let created = path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        }
        if created >= 0 {
            close(created)
            return
        }
        guard errno == EEXIST else {
            throw WorkOSVaultStoreError.storeFailure
        }
        var status = stat()
        guard stat(path, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
            return
        }
        guard chmod(path, 0o600) == 0 else {
            throw WorkOSVaultStoreError.storeFailure
        }
    }
    #endif

    public func get(
        id: String, tenant: String, subject: String?
    ) async throws -> WorkOSVaultMetadataRow? {
        #if canImport(SQLite3)
        for partition in Self.visibleOwners(subject: subject) {
            if let row = Self.select(
                id: id, tenant: tenant, owner: partition.owner, subject: partition.subject, on: handle.db
            ) {
                return row
            }
        }
        return nil
        #else
        for partition in Self.visibleOwners(subject: subject) {
            let key = WorkOSVaultPartitionKey(
                tenant: tenant, owner: partition.owner, subject: partition.subject, id: id
            )
            if let row = rows[key] {
                return row
            }
        }
        return nil
        #endif
    }

    public func upsert(
        _ row: WorkOSVaultMetadataRow, tenant: String, owner: WorkOSVaultOwner, subject: String?
    ) async throws {
        #if canImport(SQLite3)
        let ok = Self.executeBound(
            "INSERT OR REPLACE INTO metadata " +
                "(tenant, owner, subject, id, name, purpose, created_at_ms) " +
                "VALUES (?, ?, ?, ?, ?, ?, ?)",
            on: handle.db,
            bindings: [
                .text(tenant), .text(owner.rawValue),
                .text(Self.storedSubject(owner: owner, subject: subject)), .text(row.id),
                .text(row.name), .text(row.purpose),
                .int(Int64(row.createdAt.timeIntervalSince1970 * 1_000)),
            ]
        )
        guard ok else { throw WorkOSVaultStoreError.storeFailure }
        #else
        let key = WorkOSVaultPartitionKey(
            tenant: tenant, owner: owner,
            subject: Self.storedSubject(owner: owner, subject: subject), id: row.id
        )
        rows[key] = row
        insertionSequence[key] = nextSequence
        nextSequence += 1
        #endif
    }

    public func remove(
        id: String, tenant: String, subject: String?
    ) async throws -> Bool {
        #if canImport(SQLite3)
        for partition in Self.visibleOwners(subject: subject) {
            guard Self.select(
                id: id, tenant: tenant, owner: partition.owner, subject: partition.subject,
                on: handle.db
            ) != nil else {
                continue
            }
            let ok = Self.executeBound(
                "DELETE FROM metadata WHERE tenant = ? AND owner = ? AND subject = ? AND id = ?",
                on: handle.db,
                bindings: [
                    .text(tenant), .text(partition.owner.rawValue),
                    .text(partition.subject), .text(id),
                ]
            )
            guard ok else { throw WorkOSVaultStoreError.storeFailure }
            return true
        }
        return false
        #else
        for partition in Self.visibleOwners(subject: subject) {
            let key = WorkOSVaultPartitionKey(
                tenant: tenant, owner: partition.owner, subject: partition.subject, id: id
            )
            guard rows[key] != nil else {
                continue
            }
            rows.removeValue(forKey: key)
            insertionSequence.removeValue(forKey: key)
            return true
        }
        return false
        #endif
    }

    public func list(
        tenant: String, subject: String?
    ) async throws -> [WorkOSVaultMetadataRow] {
        #if canImport(SQLite3)
        return Self.selectVisible(tenant: tenant, subject: subject, on: handle.db)
        #else
        let partitions = Self.visibleOwners(subject: subject)
        return rows
            .filter { entry in
                entry.key.tenant == tenant
                    && partitions.contains {
                        $0.owner == entry.key.owner && $0.subject == entry.key.subject
                    }
            }
            .sorted { left, right in
                if left.value.createdAt != right.value.createdAt {
                    return left.value.createdAt < right.value.createdAt
                }
                return (insertionSequence[left.key] ?? 0) < (insertionSequence[right.key] ?? 0)
            }
            .map(\.value)
        #endif
    }

    /// Visible partitions for a caller: a bound subject sees its own
    /// user rows plus org rows (user first); an automation context
    /// sees org rows only. Ports the executor visibility rule.
    static func visibleOwners(subject: String?) -> [(owner: WorkOSVaultOwner, subject: String)] {
        if let subject {
            return [(.user, subject), (.org, "")]
        }
        return [(.org, "")]
    }

    /// Stored subject for a partition: org rows file under the empty
    /// subject, user rows under the caller's. Ports `subjectFor`.
    static func storedSubject(owner: WorkOSVaultOwner, subject: String?) -> String {
        owner == .org ? "" : (subject ?? "")
    }

    /// Decodes one selected tuple into a row, or nil when corrupt
    /// (executor `entryToMetadataRow` parity: undecodable rows are
    /// skipped by list and read as missing by get). NULL ids or names
    /// are corrupt, even though the schema forbids them.
    static func decodeSelectedRow(
        id: String?, name: String?, purpose: String?, createdAtMs: Int64
    ) -> WorkOSVaultMetadataRow? {
        guard let id, id.isEmpty == false, let name, name.isEmpty == false,
            createdAtMs >= 0
        else {
            return nil
        }
        return WorkOSVaultMetadataRow(
            id: id, name: name, purpose: purpose,
            createdAt: Date(timeIntervalSince1970: Double(createdAtMs) / 1_000)
        )
    }

    #if canImport(SQLite3)
    /// One bound value: text (nil binds NULL) or an integer.
    enum Binding: Sendable {
        case text(String?)
        case int(Int64)
    }

    /// Runs one statement with no rows. False on any SQLite failure.
    static func execute(_ sql: String, on db: OpaquePointer) -> Bool {
        sql.withCString { cSQL in
            sqlite3_exec(db, cSQL, nil, nil, nil) == SQLITE_OK
        }
    }

    /// Runs one bound statement with no rows. False on any failure;
    /// the statement is always finalized.
    static func executeBound(
        _ sql: String, on db: OpaquePointer, bindings: [Binding]
    ) -> Bool {
        var statement: OpaquePointer?
        let prepared = sql.withCString { cSQL in
            sqlite3_prepare_v2(db, cSQL, -1, &statement, nil)
        }
        guard prepared == SQLITE_OK, let statement else {
            // sqlite3_finalize tolerates NULL.
            _ = sqlite3_finalize(statement)
            return false
        }
        defer { _ = sqlite3_finalize(statement) }
        for (offset, binding) in bindings.enumerated() {
            guard bind(binding, at: Int32(offset + 1), on: statement) else {
                return false
            }
        }
        return sqlite3_step(statement) == SQLITE_DONE
    }

    /// Binds one value. False on any SQLite failure. Text binds
    /// with an explicit byte length (never `-1`): ids and names may
    /// carry NUL bytes, which a NUL-terminated bind would truncate,
    /// silently colliding distinct keys.
    static func bind(
        _ binding: Binding, at index: Int32, on statement: OpaquePointer
    ) -> Bool {
        switch binding {
        case .text(let value):
            guard let value else {
                return sqlite3_bind_null(statement, index) == SQLITE_OK
            }
            return value.withCString { cString in
                sqlite3_bind_text(
                    statement, index, cString, Int32(value.utf8.count), Self.transient
                ) == SQLITE_OK
            }
        case .int(let value):
            return sqlite3_bind_int64(statement, index, value) == SQLITE_OK
        }
    }

    /// `SQLITE_TRANSIENT`: SQLite copies bound text before returning.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Selects one row by full key. Nil when absent, corrupt, or on
    /// any SQLite failure (callers treat all three as missing).
    static func select(
        id: String, tenant: String, owner: WorkOSVaultOwner, subject: String, on db: OpaquePointer
    ) -> WorkOSVaultMetadataRow? {
        let sql = "SELECT id, name, purpose, created_at_ms FROM metadata " +
            "WHERE tenant = ? AND owner = ? AND subject = ? AND id = ? LIMIT 1"
        var statement: OpaquePointer?
        let prepared = sql.withCString { cSQL in
            sqlite3_prepare_v2(db, cSQL, -1, &statement, nil)
        }
        guard prepared == SQLITE_OK, let statement else {
            // sqlite3_finalize tolerates NULL.
            _ = sqlite3_finalize(statement)
            return nil
        }
        defer { _ = sqlite3_finalize(statement) }
        let bindings: [Binding] = [.text(tenant), .text(owner.rawValue), .text(subject), .text(id)]
        for (offset, binding) in bindings.enumerated() {
            guard bind(binding, at: Int32(offset + 1), on: statement) else {
                return nil
            }
        }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        return decodeSelectedRow(
            id: columnText(statement, 0),
            name: columnText(statement, 1),
            purpose: columnText(statement, 2),
            createdAtMs: sqlite3_column_int64(statement, 3)
        )
    }

    /// Selects visible rows oldest first, skipping corrupt ones.
    /// Statement shape follows the caller: bound subjects add their
    /// user partition; automation contexts read org rows only. An
    /// empty result and a failed statement both read as no rows.
    static func selectVisible(
        tenant: String, subject: String?, on db: OpaquePointer
    ) -> [WorkOSVaultMetadataRow] {
        let sql: String
        let bindings: [Binding]
        if let subject {
            sql = "SELECT id, name, purpose, created_at_ms FROM metadata " +
                "WHERE tenant = ? AND ((owner = 'org' AND subject = '') " +
                "OR (owner = 'user' AND subject = ?)) " +
                "ORDER BY created_at_ms ASC, rowid ASC"
            bindings = [.text(tenant), .text(subject)]
        } else {
            sql = "SELECT id, name, purpose, created_at_ms FROM metadata " +
                "WHERE tenant = ? AND owner = 'org' AND subject = '' " +
                "ORDER BY created_at_ms ASC, rowid ASC"
            bindings = [.text(tenant)]
        }
        var statement: OpaquePointer?
        let prepared = sql.withCString { cSQL in
            sqlite3_prepare_v2(db, cSQL, -1, &statement, nil)
        }
        guard prepared == SQLITE_OK, let statement else {
            // sqlite3_finalize tolerates NULL.
            _ = sqlite3_finalize(statement)
            return []
        }
        defer { _ = sqlite3_finalize(statement) }
        for (offset, binding) in bindings.enumerated() {
            guard bind(binding, at: Int32(offset + 1), on: statement) else {
                return []
            }
        }
        var rows: [WorkOSVaultMetadataRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let row = decodeSelectedRow(
                id: columnText(statement, 0),
                name: columnText(statement, 1),
                purpose: columnText(statement, 2),
                createdAtMs: sqlite3_column_int64(statement, 3)
            ) {
                rows.append(row)
            }
        }
        return rows
    }

    /// Reads one TEXT column: nil for NULL or undecodable bytes,
    /// the exact string otherwise. Length-delimited (never C-string):
    /// values may carry NUL bytes, which a NUL-terminated read would
    /// truncate. Undecodable bytes read as corrupt (callers skip them).
    static func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, index) else {
            return nil
        }
        let count = Int(sqlite3_column_bytes(statement, index))
        return String(bytes: UnsafeBufferPointer(start: raw, count: count), encoding: .utf8)
    }
    #endif
}

#if canImport(SQLite3)
/// Sole owner of one SQLite connection. The store actor is the only
/// holder and touches the handle actor-isolated, so the unchecked
/// Sendable is sound; deinit closes (no statement ever outlives its
/// call, so the close cannot hit BUSY).
final class WorkOSVaultDBHandle: @unchecked Sendable {
    let db: OpaquePointer

    init(_ db: OpaquePointer) {
        self.db = db
    }

    deinit {
        _ = sqlite3_close(db)
    }
}
#endif

/// Partition key for the non-SQLite fallback backend.
struct WorkOSVaultPartitionKey: Hashable, Sendable {
    var tenant: String
    var owner: WorkOSVaultOwner
    var subject: String
    var id: String
}

// MARK: - Provider

/// Listed secret: id plus display name (executor `list` parity).
public struct WorkOSVaultSecretSummary: Sendable, Equatable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// WorkOS Vault secrets provider (executor workos-vault port).
///
/// Values live in WorkOS Vault under partition-scoped object names;
/// the metadata store tracks what this provider knows about and gates
/// every read. Writable like the executor credential provider (`set`
/// / `delete` / `list` / `has`); the `SecretsProvider` surface
/// (`resolve` / `health`) reads through the same path.
///
/// Fail-closed mapping: unknown ids and invalid names read as
/// missing (`.notFound`); auth failures throw
/// `providerDown("workos-vault:forbidden")`; rate limits
/// `...:rateLimited`; server failures `...:server`; KEK exhaustion
/// `...:kekNotReady`; store failures `...:store`; timeouts `.timeout`;
/// oversized bodies `.oversized`. Labels name the provider and cause
/// only: ids, names, values, and key material never appear in errors.
///
/// No silent fallback: a Vault failure never consults another
/// provider, and a blind write is the only un-versioned write (after
/// every version-checked attempt lost its race, exactly like
/// executor). Task cancellation propagates unmapped.
public struct WorkOSVaultSecretsProvider: SecretsProvider, Sendable {
    /// Provider id. Admitted by `SecretRef.allowedProviders`.
    public var id: String { "workos-vault" }

    private let client: WorkOSVaultHTTPClient
    private let store: any WorkOSVaultMetadata
    private let binding: WorkOSVaultOwnerBinding
    private let objectPrefix: String
    private let retryPolicy: WorkOSVaultRetryPolicy
    private let jitter: WorkOSVaultJitterSource
    private let sleeper: WorkOSVaultSleeper
    private let now: WorkOSVaultClock

    /// Composes a provider over an explicit client and store. The
    /// factory builds both; tests inject stub transports and ephemeral
    /// stores. Validates the binding tenant and object prefix.
    init(
        client: WorkOSVaultHTTPClient,
        store: any WorkOSVaultMetadata,
        binding: WorkOSVaultOwnerBinding,
        objectPrefix: String = WorkOSVaultObjectNaming.defaultPrefix,
        retryPolicy: WorkOSVaultRetryPolicy = WorkOSVaultRetryPolicy(),
        jitter: WorkOSVaultJitterSource? = nil,
        sleeper: WorkOSVaultSleeper? = nil,
        now: WorkOSVaultClock? = nil
    ) throws(WorkOSVaultConfigurationError) {
        guard binding.tenant.isEmpty == false else {
            throw WorkOSVaultConfigurationError.emptyTenant
        }
        if let subject = binding.subject, subject.isEmpty {
            throw WorkOSVaultConfigurationError.emptySubject
        }
        try WorkOSVaultObjectNaming.validate(prefix: objectPrefix)
        self.client = client
        self.store = store
        self.binding = binding
        self.objectPrefix = objectPrefix
        self.retryPolicy = retryPolicy
        self.jitter = jitter ?? { Double.random(in: 0..<1) }
        self.sleeper = sleeper ?? { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
        self.now = now ?? { Date() }
    }

    /// Resolves one workos-vault ref through the metadata-gated read.
    /// Values are opaque strings, so a field-carrying ref can never
    /// resolve and fails closed as `.notFound` (env-provider rule).
    public func resolve(_ ref: SecretRef) async throws -> SecretValue {
        guard ref.provider == id else {
            throw SecretsError.invalidRef(id)
        }
        guard ref.field == nil else {
            throw SecretsError.notFound(id)
        }
        guard let value = try await value(forItem: ref.item) else {
            throw SecretsError.notFound(id)
        }
        return .text(value)
    }

    /// Reachable when the Vault list probe succeeds. Never throws:
    /// every failure (including cancellation) reports unhealthy.
    /// Identity is always nil: the API key names no user.
    public func health() async -> ProviderHealth {
        do {
            _ = try await client.listObjects(limit: 1)
            return ProviderHealth(ok: true)
        } catch {
            return ProviderHealth(ok: false)
        }
    }

    /// Rejects user-partition ids in automation (subject-less) contexts.
    /// Without a subject there is no private partition to read or file:
    /// writing would mint a tenant-global object under an empty-subject
    /// name and a metadata row no binding ever reads (invisible and
    /// undeletable through RV), so every user-scoped access fails closed
    /// as denied instead of degrading to missing.
    private func requireUserScopeVisible(for id: String) throws {
        if binding.subject == nil, MCPSecretsOwner.embeddedOwner(itemID: id) == .user {
            throw SecretsError.denied("workos-vault")
        }
    }

    /// Reads one value: nil when the metadata store knows nothing
    /// about the id, when Vault holds no object under its name, or
    /// when the object carries no (or an empty) value. Executor `get`
    /// parity, including the empty-value-reads-missing rule.
    public func value(forItem id: String) async throws -> String? {
        try requireUserScopeVisible(for: id)
        let row = try await storedRow(forItem: id)
        guard row != nil else { return nil }
        let object = try await loadObject(nameFor(id: id))
        guard let value = object?.value, value.isEmpty == false else {
            return nil
        }
        return value
    }

    /// Presence from the metadata store alone: Vault is not touched.
    /// Executor `has` parity.
    public func has(_ id: String) async throws -> Bool {
        try requireUserScopeVisible(for: id)
        return try await storedRow(forItem: id) != nil
    }

    /// Lists visible secrets oldest first. Executor `list` parity.
    public func list() async throws -> [WorkOSVaultSecretSummary] {
        do {
            return try await store.list(tenant: binding.tenant, subject: binding.subject).map {
                WorkOSVaultSecretSummary(id: $0.id, name: $0.name)
            }
        } catch {
            throw try Self.mapStoreError(error)
        }
    }

    /// Writes one value: Vault first (version-checked with
    /// contention and KEK retries), then the metadata row — preserving
    /// an existing name, purpose, and creation time, or defaulting to
    /// the id, no purpose, and now. Executor `set` parity.
    public func set(_ id: String, value: String) async throws {
        try requireUserScopeVisible(for: id)
        let existing = try await storedRow(forItem: id)
        try await upsertValue(
            name: nameFor(id: id), value: value,
            context: WorkOSVaultObjectNaming.contextFor(id: id, binding: binding)
        )
        do {
            try await store.upsert(
                WorkOSVaultMetadataRow(
                    id: id, name: existing?.name ?? id,
                    purpose: existing?.purpose ?? nil,
                    createdAt: existing?.createdAt ?? now()
                ),
                tenant: binding.tenant,
                owner: WorkOSVaultItemOwner.ownerForItem(id: id, binding: binding),
                subject: binding.subject
            )
        } catch {
            throw try Self.mapStoreError(error)
        }
    }

    /// Deletes one value from Vault and the metadata store. Absence
    /// is a no-op returning void; executor `delete` parity.
    public func delete(_ id: String) async throws {
        try requireUserScopeVisible(for: id)
        let row = try await storedRow(forItem: id)
        guard row != nil else { return }
        _ = try await deleteValue(name: nameFor(id: id))
        do {
            _ = try await store.remove(
                id: id, tenant: binding.tenant, subject: binding.subject
            )
        } catch {
            throw try Self.mapStoreError(error)
        }
    }

    /// Visible metadata row for one id, with store failures mapped.
    func storedRow(forItem id: String) async throws -> WorkOSVaultMetadataRow? {
        do {
            return try await store.get(id: id, tenant: binding.tenant, subject: binding.subject)
        } catch {
            throw try Self.mapStoreError(error)
        }
    }

    /// Vault object name for one id under this provider's binding.
    func nameFor(id: String) -> String {
        WorkOSVaultObjectNaming.objectName(prefix: objectPrefix, id: id, binding: binding)
    }

    /// Reads one object by name: 400 (invalid name) and 404 (absent)
    /// both mean "no value here". Every other failure maps and
    /// throws. Ports executor `loadSecretObject`.
    func loadObject(_ name: String) async throws -> WorkOSVaultObject? {
        do {
            return try await client.readObjectByName(name)
        } catch let error as WorkOSVaultClientError {
            if error.status == 400 || error.status == 404 {
                return nil
            }
            throw Self.mapClientError(error)
        }
    }

    /// Deletes one object by name: false when no object exists, true
    /// after a delete call. A raced delete failure throws mapped.
    /// Ports executor `deleteSecretValue`.
    func deleteValue(name: String) async throws -> Bool {
        guard let existing = try await loadObject(name) else {
            return false
        }
        do {
            try await client.deleteObject(id: existing.id)
        } catch let error as WorkOSVaultClientError {
            throw Self.mapClientError(error)
        }
        return true
    }

    /// Maps a metadata-store failure: cancellation rethrows, and
    /// everything else collapses to the store label (a defective
    /// injected fake reads as a store failure too, failing closed
    /// rather than leaking its internals).
    static func mapStoreError(_ error: Error) throws -> SecretsError {
        if error is CancellationError {
            throw error
        }
        return SecretsError.providerDown("workos-vault:store")
    }

    /// Maps a client failure to the labels-only `SecretsError`: KEK
    /// conditions (read-path or exhausted) surface the KEK label, auth
    /// failures the forbidden label, rate limits their own, and every
    /// other HTTP status the server label. Executor's StorageError
    /// messages ("WorkOS Vault secret read/write/delete failed")
    /// collapse to these labels: same opacity, RV shape.
    static func mapClientError(_ error: WorkOSVaultClientError) -> SecretsError {
        if error.retryKind == .kekNotReady {
            return SecretsError.providerDown("workos-vault:kekNotReady")
        }
        switch error.kind {
        case .httpStatus(401), .httpStatus(403):
            return SecretsError.providerDown("workos-vault:forbidden")
        case .httpStatus(429):
            return SecretsError.providerDown("workos-vault:rateLimited")
        case .httpStatus:
            return SecretsError.providerDown("workos-vault:server")
        case .timeout:
            return SecretsError.timeout("workos-vault")
        case .tls:
            return SecretsError.providerDown("workos-vault:tls")
        case .unreachable:
            return SecretsError.providerDown("workos-vault:unreachable")
        case .oversized:
            return SecretsError.oversized("workos-vault")
        case .decode:
            return SecretsError.providerDown("workos-vault:decode")
        }
    }

    /// A version-checked write either landed or lost the race to a
    /// peer writer. Ports executor `WriteOutcome`.
    enum WriteOutcome: Sendable, Equatable {
        case written
        case contended
    }

    /// Did this update failure mean "someone else wrote first"? 409
    /// is the documented answer. WorkOS also answers 400 when the
    /// checked version is several generations behind, and an update
    /// carries no name and no context — the only inputs are the id,
    /// the value, and the version — so a 400 here is contention too,
    /// not a malformed request. Ports `isWriteContention` verbatim,
    /// rationale included.
    static func isWriteContention(_ error: WorkOSVaultClientError) -> Bool {
        error.status == 409 || error.status == 400
    }

    /// One write attempt: read, then version-checked update when the
    /// object exists, else create. A peer create between the read and
    /// the create 409s into contention; the next attempt re-reads and
    /// takes the update path.
    func attemptOnce(name: String, value: String, context: [String: String]) async throws
        -> WriteOutcome
    {
        let existing = try await loadObjectRaw(name)
        if let existing {
            do {
                _ = try await client.updateObject(
                    id: existing.id, value: value, versionCheck: existing.metadata.versionID
                )
                return .written
            } catch let error as WorkOSVaultClientError {
                if Self.isWriteContention(error) {
                    return .contended
                }
                throw error
            }
        } else {
            do {
                _ = try await client.createObject(name: name, value: value, context: context)
                return .written
            } catch let error as WorkOSVaultClientError {
                if error.status == 409 {
                    return .contended
                }
                throw error
            }
        }
    }

    /// Read for the write path: like `loadObject`, except failures
    /// propagate as raw client errors so the retry loop can apply its
    /// own rules. 400/404 mask to nil without consulting the KEK
    /// kind, exactly like executor's `loadSecretObject` (real KEK
    /// errors are 500s, so the mask never hides one; a KEK 400 on
    /// read falls through to the create path, whose own KEK error
    /// then drives the retry).
    func loadObjectRaw(_ name: String) async throws -> WorkOSVaultObject? {
        do {
            return try await client.readObjectByName(name)
        } catch let error as WorkOSVaultClientError {
            if error.status == 400 || error.status == 404 {
                return nil
            }
            throw error
        }
    }

    /// Last resort once every version-checked attempt lost: write
    /// without a version check. Both racers are persisting a
    /// credential they just minted, so last-writer-wins keeps a usable
    /// value; failing instead discards a freshly minted, often
    /// single-use credential. Ports executor `blindWrite`.
    func blindWrite(name: String, value: String, context: [String: String]) async throws {
        let existing = try await loadObjectRaw(name)
        if let existing {
            _ = try await client.updateObject(id: existing.id, value: value)
        } else {
            _ = try await client.createObject(name: name, value: value, context: context)
        }
    }

    /// Writes one value with contention and KEK retries (executor
    /// `upsertSecretValue` port, iterative rather than recursive).
    ///
    /// Each attempt reads then version-checked-writes; contention
    /// backs off half-jittered and retries until the policy's write
    /// cap, then falls back to the blind write. Any KEK error —
    /// from the read, the write, or the blind write — sleeps the
    /// fixed KEK delay and retries the whole attempt without
    /// consuming a contention attempt, until the KEK cap; past it
    /// the write fails as KEK-not-ready. Cancellation propagates;
    /// every other client error maps and throws.
    func upsertValue(name: String, value: String, context: [String: String]) async throws {
        var attempt = 1
        var kekRemaining = retryPolicy.maxKEKAttempts
        while true {
            do {
                let outcome = try await attemptOnce(name: name, value: value, context: context)
                if outcome == .written {
                    return
                }
                if attempt >= retryPolicy.maxWriteAttempts {
                    try await blindWrite(name: name, value: value, context: context)
                    return
                }
                try await backoff(
                    retryPolicy.conflictBackoffSeconds(attempt: attempt, jitterUnit: jitter())
                )
                attempt += 1
            } catch let error as WorkOSVaultClientError {
                if kekRemaining > 1 && error.retryKind == .kekNotReady {
                    try await backoff(retryPolicy.kekBackoffSeconds)
                    kekRemaining -= 1
                    continue
                }
                if error.retryKind == .kekNotReady {
                    throw SecretsError.providerDown("workos-vault:kekNotReady")
                }
                throw Self.mapClientError(error)
            }
        }
    }

    /// Sleeps one backoff: cancellation propagates; any other sleeper
    /// failure aborts the retry as the retry label.
    func backoff(_ seconds: Double) async throws {
        do {
            try await sleeper(seconds)
        } catch {
            if error is CancellationError {
                throw error
            }
            throw SecretsError.providerDown("workos-vault:retry")
        }
    }
}

// MARK: - Operator config (factory wiring)

/// API-key load failure. Fixed labels only, never key material.
public enum WorkOSVaultAPIKeyError: Error, Sendable, Equatable {
    /// Directory or file failed the owner-only, no-symlink checks.
    case unsafeLocation
    /// File could not be read.
    case unreadable
    /// File exceeds the size cap.
    case oversized
    /// File is not a strict v1 key document.
    case invalidDocument
    /// Document version is not 1.
    case unsupportedVersion
}

/// Loads the WorkOS API key from owner-only `workos-vault-apikey.json`.
///
/// Document shape: `{"version":1,"api_key":"..."}` with a closed key
/// set. The directory must be owner-owned without group or other
/// write; the file must be a regular owner-only file reached without
/// following symlinks; the document is capped at 4 KiB and the key at
/// 2 KiB. Missing files fail closed as `.unreadable`: there is no
/// empty default. The decoded key is trimmed and must be non-empty.
/// Mirrors `VaultAppRoleStore`.
public enum WorkOSVaultAPIKeyStore {
    /// Key file name beside the sibling operator stores.
    public static let fileName = "workos-vault-apikey.json"
    /// Largest key document accepted.
    public static let maximumBytes = 4_096
    /// Largest key accepted after trimming.
    public static let maximumKeyBytes = 2_048

    /// Loads the key from `fileName` under `configDirectory`.
    public static func load(from configDirectory: URL) -> Result<String, WorkOSVaultAPIKeyError> {
        switch OwnerOnlyFile.loadBytes(
            fileName: fileName, from: configDirectory, maximumBytes: maximumBytes
        ) {
        case .success(let data):
            return decode(data)
        case .failure(.missing), .failure(.inaccessible):
            return .failure(.unreadable)
        case .failure(.unsafeLocation):
            return .failure(.unsafeLocation)
        case .failure(.unreadable):
            return .failure(.unreadable)
        case .failure(.oversized):
            return .failure(.oversized)
        }
    }

    /// Decodes one key document. Strict keys, version 1, trimmed
    /// non-empty key capped at 2 KiB.
    public static func decode(_ data: Data) -> Result<String, WorkOSVaultAPIKeyError> {
        guard data.count <= maximumBytes else { return .failure(.oversized) }
        guard let document = try? JSONDecoder().decode(WorkOSVaultAPIKeyDocument.self, from: data)
        else {
            return .failure(.invalidDocument)
        }
        guard document.version == 1 else { return .failure(.unsupportedVersion) }
        let key = document.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.isEmpty == false, key.utf8.count <= maximumKeyBytes else {
            return .failure(.invalidDocument)
        }
        return .success(key)
    }
}

/// Versioned API-key document: the key only, never metadata.
struct WorkOSVaultAPIKeyDocument: Decodable {
    let version: Int
    let apiKey: String

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StrictJSONKey.self)
        try rejectUnknownKeys(container, allowed: ["version", "api_key"])
        version = try container.decode(Int.self, forKey: StrictJSONKey("version"))
        apiKey = try container.decode(String.self, forKey: StrictJSONKey("api_key"))
    }
}

/// Validated WorkOS Vault endpoint config loaded from
/// `workos-vault.json`.
///
/// Shape: `{"version":1,"endpoint":"https://api.workos.com",
/// "timeoutSeconds":10,"objectPrefix":"executor","tenant":"...",
/// "subject":"..."}`. Only `tenant` is required: the endpoint
/// defaults to the WorkOS API, and timeout, prefix, and subject
/// default to the matching client constants (subject defaults to
/// nil, the automation context). Key sets are closed and every
/// member validates through the client's own validators. Mirrors
/// `VaultEndpointConfig`.
struct WorkOSVaultEndpointConfig: Sendable, Equatable {
    /// WorkOS API base URL.
    let endpoint: URL
    /// Per-request timeout in seconds.
    let timeoutSeconds: Double
    /// Vault object-name prefix.
    let objectPrefix: String
    /// Tenant binding.
    let tenant: String
    /// Subject binding, or nil for automation contexts.
    let subject: String?
}

/// Loads validated endpoint config from `workos-vault.json`.
///
/// Missing files (or a missing directory) load as nil: WorkOS Vault
/// is opt-in, and absence omits the provider. Every other failure
/// fails closed as `.configInvalid`, never as absent. Mirrors
/// `VaultEndpointStore`.
enum WorkOSVaultEndpointStore {
    /// Endpoint config file name beside the sibling operator stores.
    static let fileName = "workos-vault.json"
    /// Largest config document accepted.
    static let maximumBytes = 4_096

    /// Config load failure. Fixed labels only.
    enum LoadError: Error, Sendable, Equatable {
        /// The config is present but unusable.
        case configInvalid
    }

    /// Loads config from `fileName` under `configDirectory`, or nil
    /// when no WorkOS Vault config is present.
    static func load(from configDirectory: URL) -> Result<WorkOSVaultEndpointConfig?, LoadError> {
        switch OwnerOnlyFile.loadBytes(
            fileName: fileName, from: configDirectory, maximumBytes: maximumBytes
        ) {
        case .success(let data):
            return decode(data).map { .some($0) }
        case .failure(.missing):
            return .success(nil)
        case .failure(.inaccessible), .failure(.unsafeLocation),
            .failure(.unreadable), .failure(.oversized):
            return .failure(.configInvalid)
        }
    }

    /// Decodes plus validates one config document.
    static func decode(_ data: Data) -> Result<WorkOSVaultEndpointConfig, LoadError> {
        guard data.count <= maximumBytes else {
            return .failure(.configInvalid)
        }
        guard let document = try? JSONDecoder().decode(
            WorkOSVaultEndpointDocument.self, from: data
        ),
            let config = try? validated(document)
        else {
            return .failure(.configInvalid)
        }
        return .success(config)
    }

    /// Defaults plus client validation. Throws on any structural or
    /// validation failure; the caller collapses every throw with no
    /// payload.
    private static func validated(
        _ document: WorkOSVaultEndpointDocument
    ) throws -> WorkOSVaultEndpointConfig {
        guard document.version == 1 else {
            throw WorkOSVaultConfigurationError.invalidEndpoint
        }
        let endpointText = document.endpoint ?? WorkOSVaultHTTPClient.defaultEndpoint
        guard let endpoint = URL(string: endpointText) else {
            throw WorkOSVaultConfigurationError.invalidEndpoint
        }
        try WorkOSVaultHTTPClient.validate(endpoint: endpoint)
        let timeout = document.timeoutSeconds ?? WorkOSVaultHTTPClient.defaultTimeoutSeconds
        try WorkOSVaultHTTPClient.validate(timeoutSeconds: timeout)
        let prefix = document.objectPrefix ?? WorkOSVaultObjectNaming.defaultPrefix
        try WorkOSVaultObjectNaming.validate(prefix: prefix)
        guard let tenant = document.tenant, tenant.isEmpty == false else {
            throw WorkOSVaultConfigurationError.emptyTenant
        }
        if let subject = document.subject, subject.isEmpty {
            throw WorkOSVaultConfigurationError.emptySubject
        }
        return WorkOSVaultEndpointConfig(
            endpoint: endpoint, timeoutSeconds: timeout, objectPrefix: prefix,
            tenant: tenant, subject: document.subject
        )
    }
}

/// Versioned endpoint config document. Closed key set; only `tenant`
/// is required.
private struct WorkOSVaultEndpointDocument: Decodable {
    let version: Int
    let endpoint: String?
    let timeoutSeconds: Double?
    let objectPrefix: String?
    let tenant: String?
    let subject: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StrictJSONKey.self)
        try rejectUnknownKeys(
            container,
            allowed: ["version", "endpoint", "timeoutSeconds", "objectPrefix", "tenant", "subject"]
        )
        version = try container.decode(Int.self, forKey: StrictJSONKey("version"))
        endpoint = try container.decodeIfPresent(String.self, forKey: StrictJSONKey("endpoint"))
        timeoutSeconds = try container.decodeIfPresent(
            Double.self, forKey: StrictJSONKey("timeoutSeconds")
        )
        objectPrefix = try container.decodeIfPresent(
            String.self, forKey: StrictJSONKey("objectPrefix")
        )
        tenant = try container.decodeIfPresent(String.self, forKey: StrictJSONKey("tenant"))
        subject = try container.decodeIfPresent(String.self, forKey: StrictJSONKey("subject"))
    }
}
