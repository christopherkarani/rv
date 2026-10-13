#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RVDomain
import RVIsolation
import Synchronization

/// What `rv mcp connect` stored for one server, including what a refresh needs.
public struct MCPOAuthTokens: Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var tokenEndpoint: URL
    public var clientID: String
    public var clientSecret: String?
    public var resource: String
    public var scope: String?

    public init(
        accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil, tokenEndpoint: URL, clientID: String,
        clientSecret: String? = nil, resource: String, scope: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.tokenEndpoint = tokenEndpoint
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.resource = resource
        self.scope = scope
    }

    /// Refresh a minute early so a request does not race the expiry.
    func expiresSoon(_ now: Date) -> Bool {
        expiresAt.map { $0.timeIntervalSince(now) < 60 } ?? false
    }

    public func encoded() -> Data {
        var object = JSONObject()
        object["version"] = .int(1)
        object["accessToken"] = .string(accessToken)
        if let refreshToken { object["refreshToken"] = .string(refreshToken) }
        if let expiresAt { object["expiresAt"] = .int(Int(expiresAt.timeIntervalSince1970)) }
        object["tokenEndpoint"] = .string(tokenEndpoint.absoluteString)
        object["clientID"] = .string(clientID)
        if let clientSecret { object["clientSecret"] = .string(clientSecret) }
        object["resource"] = .string(resource)
        if let scope { object["scope"] = .string(scope) }
        return Data(JSONValue.object(object).compactText.utf8)
    }

    public static func decode(_ data: Data) -> MCPOAuthTokens? {
        guard let root = try? JSONValue.parse(data), root["version"]?.intValue == 1,
            let access = root["accessToken"]?.stringValue, let endpoint = root["tokenEndpoint"]?.stringValue.flatMap(URL.init(string:)),
            let clientID = root["clientID"]?.stringValue, let resource = root["resource"]?.stringValue
        else { return nil }
        return MCPOAuthTokens(
            accessToken: access, refreshToken: root["refreshToken"]?.stringValue,
            expiresAt: root["expiresAt"]?.intValue.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            tokenEndpoint: endpoint, clientID: clientID, clientSecret: root["clientSecret"]?.stringValue, resource: resource,
            scope: root["scope"]?.stringValue)
    }
}

public struct MCPOAuthError: Error, Sendable, Equatable {
    public var message: String

    public init(_ message: String) { self.message = message }
}

public struct MCPHTTPResponse: Sendable, Equatable {
    public var status: Int
    /// Lowercased names.
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        self.body = body
    }
}

public typealias MCPHTTPClient = @Sendable (URLRequest) -> MCPHTTPResponse?

public enum MCPOAuthHTTP {
    static let maximumBodyBytes = 1024 * 1024

    /// No cookies, cache, or redirects; nil on a network error, timeout, or a body over 1 MiB.
    public static let live: MCPHTTPClient = { request in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let delegate = NoRedirects()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let done = DispatchSemaphore(value: 0)
        let result = Mutex<MCPHTTPResponse?>(nil)
        session.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse, (data?.count ?? 0) <= maximumBodyBytes {
                var headers: [String: String] = [:]
                for (key, value) in http.allHeaderFields {
                    if let key = key as? String, let value = value as? String { headers[key] = value }
                }
                result.withLock { $0 = MCPHTTPResponse(status: http.statusCode, headers: headers, body: data ?? Data()) }
            }
            done.signal()
        }.resume()
        let timeout = request.timeoutInterval > 0 ? request.timeoutInterval : 30
        guard done.wait(timeout: .now() + timeout + 1) == .success else { return nil }
        return result.withLock { $0 }
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}

/// OAuth 2.1 pieces the MCP authorization spec uses: protected-resource
/// metadata (RFC 9728), authorization-server metadata (RFC 8414), PKCE S256
/// (RFC 7636), dynamic client registration (RFC 7591), resource indicators
/// (RFC 8707).
public enum MCPOAuth {
    static let timeout: TimeInterval = 30

    /// `resource_metadata` from a `WWW-Authenticate: Bearer ...` challenge.
    public static func challengeParameter(_ name: String, in header: String) -> String? {
        var rest = Substring(header)
        while let range = rest.range(of: name + "=", options: .caseInsensitive) {
            let before = rest[..<range.lowerBound].last
            rest = rest[range.upperBound...]
            guard before == nil || before == " " || before == "," else { continue }
            if rest.first == "\"" {
                let body = rest.dropFirst()
                guard let end = body.firstIndex(of: "\"") else { return nil }
                return String(body[..<end])
            }
            return String(rest.prefix { $0 != "," && $0 != " " })
        }
        return nil
    }

    /// RFC 9728 §3.1: the well-known segment goes between the host and the
    /// path; the root form follows as a fallback.
    public static func protectedResourceMetadataURLs(for server: URL) -> [URL] {
        wellKnown("oauth-protected-resource", for: server)
    }

    /// RFC 8414 §3.1 for path issuers, then OpenID Connect discovery.
    public static func authorizationServerMetadataURLs(issuer: URL) -> [URL] {
        var urls = wellKnown("oauth-authorization-server", for: issuer).prefix(1) + wellKnown("openid-configuration", for: issuer).prefix(1)
        let path = trimmedPath(issuer)
        if path.isEmpty == false, var components = URLComponents(url: issuer, resolvingAgainstBaseURL: false) {
            components.path = path + "/.well-known/openid-configuration"
            components.query = nil
            if let url = components.url { urls.append(url) }
        }
        return Array(urls)
    }

    static func wellKnown(_ name: String, for url: URL) -> [URL] {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [] }
        components.query = nil
        components.fragment = nil
        let path = trimmedPath(url)
        var urls: [URL] = []
        components.path = "/.well-known/\(name)" + path
        if let first = components.url { urls.append(first) }
        if path.isEmpty == false {
            components.path = "/.well-known/\(name)"
            if let root = components.url { urls.append(root) }
        }
        return urls
    }

    static func trimmedPath(_ url: URL) -> String {
        var path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path ?? ""
        while path.hasSuffix("/") { path.removeLast() }
        return path
    }

    public static func base64URL(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func random(_ count: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL((0..<count).map { _ in generator.next() })
    }

    public static func challenge(verifier: String) -> String {
        base64URL(RVDigest.sha256(Array(verifier.utf8)))
    }

    static let queryValue: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()

    static func encode(_ pairs: [(String, String)]) -> String {
        pairs.map { name, value in
            "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: queryValue) ?? "")"
        }.joined(separator: "&")
    }

    public static func authorizationURL(
        endpoint: URL, clientID: String, redirectURI: String, state: String, challenge: String, resource: String,
        scope: String?
    ) -> URL? {
        var pairs = [
            ("response_type", "code"), ("client_id", clientID), ("redirect_uri", redirectURI), ("state", state),
            ("code_challenge", challenge), ("code_challenge_method", "S256"), ("resource", resource),
        ]
        if let scope, scope.isEmpty == false { pairs.append(("scope", scope)) }
        let query = encode(pairs)
        let base = endpoint.absoluteString
        return URL(string: base + (base.contains("?") ? "&" : "?") + query)
    }

    static func jsonRequest(_ url: URL, method: String = "GET", body: JSONValue? = nil) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.compactText.utf8)
        }
        return request
    }

    static func tokenRequest(_ endpoint: URL, _ pairs: [(String, String)], clientID: String, clientSecret: String?) -> URLRequest {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var all = pairs + [("client_id", clientID)]
        if let clientSecret { all.append(("client_secret", clientSecret)) }
        request.httpBody = Data(encode(all).utf8)
        return request
    }

    /// RFC 6749 §5.1 success, or the `error` code from §5.2 (never the description, which servers may fill with anything).
    static func tokens(
        _ response: MCPHTTPResponse?, endpoint: URL, clientID: String, clientSecret: String?, resource: String, scope: String?,
        previous: MCPOAuthTokens?, now: Date
    ) -> Result<MCPOAuthTokens, MCPOAuthError> {
        guard let response else { return .failure(MCPOAuthError("the token endpoint did not answer")) }
        let json = try? JSONValue.parse(response.body)
        guard response.status == 200, let access = json?["access_token"]?.stringValue, access.isEmpty == false else {
            let code = json?["error"]?.stringValue.map(safeCode) ?? "HTTP \(response.status)"
            return .failure(MCPOAuthError("the token endpoint refused (\(code))"))
        }
        guard json?["token_type"]?.stringValue?.lowercased() == "bearer" else {
            return .failure(MCPOAuthError("the token endpoint returned a token that is not a bearer token"))
        }
        guard access.utf8.count <= 16 * 1024, access.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else {
            return .failure(MCPOAuthError("the token endpoint returned an unusable access token"))
        }
        let lifetime = json?["expires_in"]?.intValue
        return .success(MCPOAuthTokens(
            accessToken: access, refreshToken: json?["refresh_token"]?.stringValue ?? previous?.refreshToken,
            expiresAt: lifetime.map { now.addingTimeInterval(TimeInterval($0)) }, tokenEndpoint: endpoint, clientID: clientID,
            clientSecret: clientSecret, resource: resource, scope: json?["scope"]?.stringValue ?? scope))
    }

    static func safeCode(_ text: String) -> String {
        String(text.prefix(64).filter { $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) })
    }

    public static func refresh(_ tokens: MCPOAuthTokens, http: MCPHTTPClient, now: Date) -> Result<MCPOAuthTokens, MCPOAuthError> {
        guard let refreshToken = tokens.refreshToken else { return .failure(MCPOAuthError("no refresh token; run `rv mcp connect` again")) }
        var pairs = [("grant_type", "refresh_token"), ("refresh_token", refreshToken), ("resource", tokens.resource)]
        if let scope = tokens.scope { pairs.append(("scope", scope)) }
        let request = tokenRequest(tokens.tokenEndpoint, pairs, clientID: tokens.clientID, clientSecret: tokens.clientSecret)
        return Self.tokens(
            http(request), endpoint: tokens.tokenEndpoint, clientID: tokens.clientID, clientSecret: tokens.clientSecret,
            resource: tokens.resource, scope: tokens.scope, previous: tokens, now: now)
    }
}

/// `rv mcp connect`: discovery, registration, the browser round trip on a
/// loopback redirect, and the code exchange. Every endpoint must pass D22.
public struct MCPOAuthFlow: Sendable {
    public var http: MCPHTTPClient
    /// Shows (and may open) the authorization URL.
    public var present: @Sendable (URL) -> Void
    public var timeout: TimeInterval
    public var clock: @Sendable () -> Date

    public init(
        http: @escaping MCPHTTPClient = MCPOAuthHTTP.live, present: @escaping @Sendable (URL) -> Void,
        timeout: TimeInterval = 300, clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.http = http
        self.present = present
        self.timeout = timeout
        self.clock = clock
    }

    struct ServerMetadata {
        var authorizationEndpoint: URL
        var tokenEndpoint: URL
        var registrationEndpoint: URL?
    }

    public func connect(
        server: String, launch: MCPRemoteLaunch, clientID: String?, scope requested: String?
    ) -> Result<MCPOAuthTokens, MCPOAuthError> {
        var challenge: (metadata: URL?, scope: String?) = (nil, nil)
        if launch.transport == .http {
            switch probe(launch) {
            case .failure(let error): return .failure(error)
            case .success(let found): challenge = found
            }
        }
        let resourceMetadata: (resource: String, issuer: URL, scopes: String?)
        switch protectedResource(server: launch.url, hinted: challenge.metadata) {
        case .failure(let error): return .failure(error)
        case .success(let found): resourceMetadata = found
        }
        let metadata: ServerMetadata
        switch authorizationServer(resourceMetadata.issuer) {
        case .failure(let error): return .failure(error)
        case .success(let found): metadata = found
        }
        guard let listener = MCPLoopbackRedirect.open() else {
            return .failure(MCPOAuthError("could not listen on 127.0.0.1 for the sign-in redirect"))
        }
        let redirectURI = "http://127.0.0.1:\(listener.port)/callback"
        let client: (id: String, secret: String?)
        if let clientID {
            client = (clientID, nil)
        } else {
            switch register(metadata.registrationEndpoint, redirectURI: redirectURI) {
            case .failure(let error): return .failure(error)
            case .success(let registered): client = registered
            }
        }
        let scope = requested ?? challenge.scope ?? resourceMetadata.scopes
        let verifier = MCPOAuth.random(32)
        let state = MCPOAuth.random(16)
        guard let url = MCPOAuth.authorizationURL(
            endpoint: metadata.authorizationEndpoint, clientID: client.id, redirectURI: redirectURI, state: state,
            challenge: MCPOAuth.challenge(verifier: verifier), resource: resourceMetadata.resource, scope: scope)
        else { return .failure(MCPOAuthError("could not build the authorization URL")) }
        present(url)
        guard let callback = listener.wait(timeout: timeout) else {
            return .failure(MCPOAuthError("no sign-in arrived within \(Int(timeout)) seconds"))
        }
        if let error = callback["error"] {
            return .failure(MCPOAuthError("the authorization server refused (\(MCPOAuth.safeCode(error)))"))
        }
        guard callback["state"] == state else {
            return .failure(MCPOAuthError("the sign-in redirect carried the wrong state; nothing stored"))
        }
        guard let code = callback["code"], code.isEmpty == false else {
            return .failure(MCPOAuthError("the sign-in redirect carried no code"))
        }
        let request = MCPOAuth.tokenRequest(
            metadata.tokenEndpoint,
            [
                ("grant_type", "authorization_code"), ("code", code), ("redirect_uri", redirectURI), ("code_verifier", verifier),
                ("resource", resourceMetadata.resource),
            ],
            clientID: client.id, clientSecret: client.secret)
        return MCPOAuth.tokens(
            http(request), endpoint: metadata.tokenEndpoint, clientID: client.id, clientSecret: client.secret,
            resource: resourceMetadata.resource, scope: scope, previous: nil, now: clock())
    }

    /// An unauthenticated initialize: the 401 names the metadata and scope.
    func probe(_ launch: MCPRemoteLaunch) -> Result<(metadata: URL?, scope: String?), MCPOAuthError> {
        let body = JSONValue.object([
            "jsonrpc": .string("2.0"), "id": .int(1), "method": .string("initialize"),
            "params": .object([
                "protocolVersion": .string(MCPGatewayCore.upstreamVersion), "capabilities": .object([:]),
                "clientInfo": .object(["name": .string("rv"), "version": .string("1")]),
            ]),
        ])
        var headers = launch.headers
        headers["Authorization"] = nil
        var request = MCPHTTPExchange.request(
            url: launch.url, method: "POST", headers: headers, sessionID: nil, protocolVersion: nil, body: Data(body.compactText.utf8))
        request.timeoutInterval = MCPOAuth.timeout
        guard let response = http(request) else { return .failure(MCPOAuthError("\(launch.url.absoluteString) did not answer")) }
        guard response.status == 401 else {
            return .failure(MCPOAuthError(
                "\(launch.server) answered HTTP \(response.status) without asking for authorization; it does not need `rv mcp connect`"))
        }
        let header = response.headers["www-authenticate"] ?? ""
        let metadata = MCPOAuth.challengeParameter("resource_metadata", in: header).flatMap(URL.init(string:))
        return .success((metadata, MCPOAuth.challengeParameter("scope", in: header)))
    }

    func protectedResource(server: URL, hinted: URL?) -> Result<(resource: String, issuer: URL, scopes: String?), MCPOAuthError> {
        let candidates = hinted.map { [$0] } ?? MCPOAuth.protectedResourceMetadataURLs(for: server)
        for url in candidates {
            if let problem = MCPRemoteServer.endpointProblem(url) {
                return .failure(MCPOAuthError("resource metadata URL \(problem)"))
            }
            guard let response = http(MCPOAuth.jsonRequest(url)), response.status == 200,
                let json = try? JSONValue.parse(response.body), let issuers = json["authorization_servers"]?.stringArray,
                let first = issuers.first, let issuer = URL(string: first)
            else { continue }
            let resource = json["resource"]?.stringValue ?? server.absoluteString
            guard let resourceURL = URL(string: resource), MCPHTTPExchange.sameOrigin(resourceURL, server) else {
                return .failure(MCPOAuthError("resource metadata names a resource on another origin (\(resource))"))
            }
            return .success((resource, issuer, json["scopes_supported"]?.stringArray?.joined(separator: " ")))
        }
        guard var origin = URLComponents(url: server, resolvingAgainstBaseURL: false) else {
            return .failure(MCPOAuthError("no protected resource metadata found"))
        }
        origin.path = ""
        origin.query = nil
        guard let issuer = origin.url else { return .failure(MCPOAuthError("no protected resource metadata found")) }
        return .success((server.absoluteString, issuer, nil))
    }

    func authorizationServer(_ issuer: URL) -> Result<ServerMetadata, MCPOAuthError> {
        if let problem = MCPRemoteServer.endpointProblem(issuer) {
            return .failure(MCPOAuthError("authorization server \(problem)"))
        }
        for url in MCPOAuth.authorizationServerMetadataURLs(issuer: issuer) {
            guard let response = http(MCPOAuth.jsonRequest(url)), response.status == 200,
                let json = try? JSONValue.parse(response.body)
            else { continue }
            guard let authorize = json["authorization_endpoint"]?.stringValue.flatMap(URL.init(string:)),
                let token = json["token_endpoint"]?.stringValue.flatMap(URL.init(string:))
            else { return .failure(MCPOAuthError("authorization server metadata lacks its endpoints")) }
            let registration = json["registration_endpoint"]?.stringValue.flatMap(URL.init(string:))
            for (label, endpoint) in [("authorization", authorize), ("token", token)] + (registration.map { [("registration", $0)] } ?? []) {
                if let problem = MCPRemoteServer.endpointProblem(endpoint) {
                    return .failure(MCPOAuthError("\(label) endpoint \(problem)"))
                }
            }
            guard json["code_challenge_methods_supported"]?.stringArray?.contains("S256") == true else {
                return .failure(MCPOAuthError("the authorization server does not offer PKCE S256; rv will not sign in without it"))
            }
            return .success(ServerMetadata(authorizationEndpoint: authorize, tokenEndpoint: token, registrationEndpoint: registration))
        }
        return .failure(MCPOAuthError("no authorization server metadata at \(issuer.absoluteString)"))
    }

    func register(_ endpoint: URL?, redirectURI: String) -> Result<(id: String, secret: String?), MCPOAuthError> {
        guard let endpoint else {
            return .failure(MCPOAuthError("the authorization server has no client registration; pass --client-id"))
        }
        let body = JSONValue.object([
            "client_name": .string("rv"), "redirect_uris": .array([.string(redirectURI)]),
            "grant_types": .array([.string("authorization_code"), .string("refresh_token")]),
            "response_types": .array([.string("code")]), "token_endpoint_auth_method": .string("none"),
        ])
        guard let response = http(MCPOAuth.jsonRequest(endpoint, method: "POST", body: body)),
            response.status == 200 || response.status == 201, let json = try? JSONValue.parse(response.body),
            let id = json["client_id"]?.stringValue, id.isEmpty == false
        else { return .failure(MCPOAuthError("client registration failed")) }
        return .success((id, json["client_secret"]?.stringValue))
    }
}

/// One-shot HTTP listener on 127.0.0.1 for the OAuth redirect.
final class MCPLoopbackRedirect {
    let fd: Int32
    let port: Int

    private init(fd: Int32, port: Int) {
        self.fd = fd
        self.port = port
    }

    deinit { close(fd) }

    static func open() -> MCPLoopbackRedirect? {
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { return nil }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard bound == 0, listen(fd, 8) == 0, named == 0 else {
            close(fd)
            return nil
        }
        return MCPLoopbackRedirect(fd: fd, port: Int(UInt16(bigEndian: actual.sin_port)))
    }

    /// Query parameters of the first `GET /callback`; other requests get 404.
    func wait(timeout: TimeInterval) -> [String: String]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let remaining = Int32(max(1, min(1000, deadline.timeIntervalSinceNow * 1000)))
            guard poll(&poller, 1, remaining) > 0 else { continue }
            let connection = accept(fd, nil, nil)
            guard connection >= 0 else { continue }
            defer { close(connection) }
            guard let target = Self.requestTarget(connection), let components = URLComponents(string: target),
                components.path == "/callback"
            else {
                Self.respond(connection, status: "404 Not Found", text: "Not found")
                continue
            }
            var parameters: [String: String] = [:]
            for item in components.queryItems ?? [] where parameters[item.name] == nil { parameters[item.name] = item.value ?? "" }
            let failed = parameters["error"] != nil
            Self.respond(
                connection, status: "200 OK",
                text: failed ? "rv: sign-in was refused. You can close this window." : "rv: signed in. You can close this window.")
            return parameters
        }
        return nil
    }

    /// The target of a `GET` request line, read within 5 seconds and 8 KiB.
    static func requestTarget(_ connection: Int32) -> String? {
        var bytes: [UInt8] = []
        let deadline = Date().addingTimeInterval(5)
        while bytes.count < 8192, bytes.firstIndex(of: 0x0A) == nil, Date() < deadline {
            var poller = pollfd(fd: connection, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 200) > 0 else { continue }
            var chunk = [UInt8](repeating: 0, count: 2048)
            let n = read(connection, &chunk, chunk.count)
            guard n > 0 else { break }
            bytes += chunk[0..<n]
        }
        guard let end = bytes.firstIndex(of: 0x0A) else { return nil }
        let parts = String(decoding: bytes[..<end], as: UTF8.self).split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        return String(parts[1])
    }

    static func respond(_ connection: Int32, status: String, text: String) {
        let body = Array("<!doctype html><title>rv</title><p>\(text)</p>\n".utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        let bytes = Array(head.utf8) + body
        _ = bytes.withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
    }
}

/// Where `rv mcp connect` keeps tokens: the login Keychain on macOS
/// (`rv.mcp.oauth`, account = server name), an owner-only file per server
/// under `mcp-oauth/` in the rv config directory elsewhere.
public struct MCPOAuthTokenStore: Sendable {
    public static let keychainService = "rv.mcp.oauth"
    public static let directoryName = "mcp-oauth"

    public var load: @Sendable (String) -> MCPOAuthTokens?
    public var save: @Sendable (String, MCPOAuthTokens) -> Bool
    /// True when nothing is stored afterwards.
    public var remove: @Sendable (String) -> Bool

    public init(
        load: @escaping @Sendable (String) -> MCPOAuthTokens?, save: @escaping @Sendable (String, MCPOAuthTokens) -> Bool,
        remove: @escaping @Sendable (String) -> Bool
    ) {
        self.load = load
        self.save = save
        self.remove = remove
    }

    public static let none = MCPOAuthTokenStore(load: { _ in nil }, save: { _, _ in false }, remove: { _ in true })

    public static func live(configDirectory: URL, home: String) -> MCPOAuthTokenStore {
        #if os(macOS)
        let resolver = SecretResolver.live(environment: [:], home: home)
        let writer = SecretKeychainWriter.live
        return MCPOAuthTokenStore(
            load: { server in
                guard case .success(let value) = resolver.resolve(.keychain(service: keychainService, account: server)) else {
                    return nil
                }
                return MCPOAuthTokens.decode(Data(value.revealed()))
            },
            save: { server, tokens in writer.store(keychainService, server, tokens.encoded()) },
            remove: { server in writer.delete(keychainService, server) })
        #else
        return file(configDirectory: configDirectory)
        #endif
    }

    public static func file(configDirectory: URL) -> MCPOAuthTokenStore {
        let directory = configDirectory.appendingPathComponent(directoryName, isDirectory: true)
        @Sendable func url(_ server: String) -> URL { directory.appendingPathComponent("\(server).json", isDirectory: false) }
        return MCPOAuthTokenStore(
            load: { server in
                guard case .success(let data?) = OwnerOnlyFile.read(url(server), maximumBytes: 256 * 1024) else { return nil }
                return MCPOAuthTokens.decode(data)
            },
            save: { server, tokens in
                try? FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                return OwnerOnlyFile.write(tokens.encoded(), to: url(server))
            },
            remove: { server in unlink(url(server).path) == 0 || errno == ENOENT })
    }
}

extension MCPRemoteAuthorizer {
    /// Serves the stored token, refreshes it when it is about to expire or
    /// after a 401, saves the result, and reports each new token so the
    /// gateway can scrub it.
    public static func oauth(
        server: String, tokens: MCPOAuthTokens, store: MCPOAuthTokenStore, http: @escaping MCPHTTPClient = MCPOAuthHTTP.live,
        clock: @escaping @Sendable () -> Date = { Date() }, log: @escaping @Sendable (String) -> Void,
        refreshed: @escaping @Sendable (MCPOAuthTokens) -> Void
    ) -> MCPRemoteAuthorizer {
        let current = Mutex(tokens)
        let gate = Mutex(0)
        let refresh: @Sendable (String?) -> Bool = { rejected in
            gate.withLock { _ in
                let held = current.withLock { $0 }
                if let rejected, held.accessToken != rejected { return true }
                switch MCPOAuth.refresh(held, http: http, now: clock()) {
                case .failure(let error):
                    log("MCP server \(server): could not refresh its OAuth token: \(error.message)")
                    return false
                case .success(let next):
                    current.withLock { $0 = next }
                    if store.save(server, next) == false { log("MCP server \(server): could not save its refreshed OAuth token") }
                    refreshed(next)
                    return true
                }
            }
        }
        return MCPRemoteAuthorizer(
            token: {
                let (token, stale) = current.withLock { ($0.accessToken, $0.expiresSoon(clock()) && $0.refreshToken != nil) }
                if stale { _ = refresh(token) }
                return current.withLock { $0.accessToken }
            },
            refresh: refresh)
    }
}
