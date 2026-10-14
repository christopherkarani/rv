#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RVIsolation
import Synchronization
import Testing
@testable import RVMCP

/// Acts as the browser: follows the authorization URL (and its redirect to
/// rv's loopback listener) off the calling thread, like a real browser would.
@Sendable func followInBrowser(_ url: URL) {
    Thread.detachNewThread {
        let done = DispatchSemaphore(value: 0)
        URLSession(configuration: .ephemeral).dataTask(with: url) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 15)
    }
}

@Suite("MCP OAuth")
struct MCPOAuthTests {
    @Test func challengesMetadataURLsAndPKCE() throws {
        let header = #"Bearer error="invalid_token", resource_metadata="https://a.example/.well-known/oauth-protected-resource/mcp", scope="files:read files:write""#
        #expect(MCPOAuth.challengeParameter("resource_metadata", in: header)
            == "https://a.example/.well-known/oauth-protected-resource/mcp")
        #expect(MCPOAuth.challengeParameter("scope", in: header) == "files:read files:write")
        #expect(MCPOAuth.challengeParameter("scope", in: "Bearer realm=x,scope=tools") == "tools")
        #expect(MCPOAuth.challengeParameter("resource_metadata", in: "Bearer realm=\"x\"") == nil)
        #expect(MCPOAuth.challengeParameter("scope", in: "Bearer xscope=nope") == nil)

        func urls(_ list: [URL]) -> [String] { list.map(\.absoluteString) }
        #expect(urls(MCPOAuth.protectedResourceMetadataURLs(for: URL(string: "https://a.example/v1/mcp/")!)) == [
            "https://a.example/.well-known/oauth-protected-resource/v1/mcp",
            "https://a.example/.well-known/oauth-protected-resource",
        ])
        #expect(urls(MCPOAuth.protectedResourceMetadataURLs(for: URL(string: "https://a.example")!))
            == ["https://a.example/.well-known/oauth-protected-resource"])
        #expect(urls(MCPOAuth.authorizationServerMetadataURLs(issuer: URL(string: "https://auth.example/tenant1")!)) == [
            "https://auth.example/.well-known/oauth-authorization-server/tenant1",
            "https://auth.example/.well-known/openid-configuration/tenant1",
            "https://auth.example/tenant1/.well-known/openid-configuration",
        ])
        #expect(urls(MCPOAuth.authorizationServerMetadataURLs(issuer: URL(string: "https://auth.example")!)) == [
            "https://auth.example/.well-known/oauth-authorization-server",
            "https://auth.example/.well-known/openid-configuration",
        ])
        // Python: base64.urlsafe_b64encode(hashlib.sha256(verifier).digest()).rstrip(b"=")
        #expect(MCPOAuth.challenge(verifier: "dBjftJeZ4CVP-mJ92K9qX1ihnC2hr1eKZQ_e7Kt5wQY") == "q2dJjJ3XcetiEHWQP_RbXByhE9yMiwW0Df5f2GFYyd4")
        #expect(MCPOAuth.random(32).count == 43)

        let url = try #require(MCPOAuth.authorizationURL(
            endpoint: URL(string: "https://auth.example/authorize?tenant=a")!, clientID: "c 1", redirectURI: "http://127.0.0.1:5/callback",
            state: "s", challenge: "ch", resource: "https://a.example/mcp", scope: "a b"))
        let items = Dictionary(
            uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["tenant"] == "a")
        #expect(items["client_id"] == "c 1")
        #expect(items["redirect_uri"] == "http://127.0.0.1:5/callback")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["resource"] == "https://a.example/mcp")
        #expect(items["scope"] == "a b")
    }

    @Test func tokenResponsesRefusalsAndStorage() throws {
        let endpoint = try #require(URL(string: "https://auth.example/token"))
        let now = Date(timeIntervalSince1970: 1_000_000)
        func parse(_ status: Int, _ body: String, previous: MCPOAuthTokens? = nil) -> Result<MCPOAuthTokens, MCPOAuthError> {
            MCPOAuth.tokens(
                MCPHTTPResponse(status: status, body: Data(body.utf8)), endpoint: endpoint, clientID: "c", clientSecret: nil,
                resource: "https://a.example/mcp", scope: "s", previous: previous, now: now)
        }
        let tokens = try parse(200, #"{"access_token":"at-1","token_type":"bearer","expires_in":30,"refresh_token":"rt-1"}"#).get()
        #expect(tokens.expiresAt == now.addingTimeInterval(30))
        #expect(tokens.expiresSoon(now))
        #expect(tokens.expiresSoon(now.addingTimeInterval(-10)))
        let rotated = try parse(200, #"{"access_token":"at-2","token_type":"Bearer"}"#, previous: tokens).get()
        #expect(rotated.refreshToken == "rt-1")
        #expect(rotated.expiresSoon(now) == false)
        guard case .failure(let refused) = parse(400, #"{"error":"invalid_grant","error_description":"token rt-1 leaked"}"#),
            case .failure(let mac) = parse(200, #"{"access_token":"at","token_type":"mac"}"#),
            case .failure(let spaced) = parse(200, #"{"access_token":"a b","token_type":"Bearer"}"#)
        else {
            Issue.record("accepted a refusal, a non-bearer token, or an unusable token")
            return
        }
        #expect(refused.message == "the token endpoint refused (invalid_grant)")
        #expect(mac.message.contains("not a bearer token"))
        #expect(spaced.message.contains("unusable access token"))

        #expect(MCPOAuthTokens.decode(tokens.encoded()) == MCPOAuthTokens(
            accessToken: "at-1", refreshToken: "rt-1", expiresAt: now.addingTimeInterval(30), tokenEndpoint: endpoint,
            clientID: "c", resource: "https://a.example/mcp", scope: "s"))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rv-oauth-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MCPOAuthTokenStore.file(configDirectory: directory)
        #expect(store.load("linear") == nil)
        #expect(store.save("linear", tokens))
        #expect(store.load("linear") == MCPOAuthTokens.decode(tokens.encoded()))
        var info = stat()
        #expect(stat(directory.appendingPathComponent("mcp-oauth/linear.json").path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        #expect(store.remove("linear"))
        #expect(store.remove("linear"))
        #expect(store.load("linear") == nil)
    }

    /// Canned answers by path; the authorization URL goes to `browse`.
    private func flow(_ answers: [String: MCPHTTPResponse], browse: @escaping @Sendable (URL) -> Void = { _ in }) -> MCPOAuthFlow {
        MCPOAuthFlow(http: { request in answers[request.url?.path ?? ""] }, present: browse, timeout: 5)
    }

    private func json(_ status: Int, _ text: String, headers: [String: String] = [:]) -> MCPHTTPResponse {
        MCPHTTPResponse(status: status, headers: headers, body: Data(text.utf8))
    }

    private var protected: [String: MCPHTTPResponse] {
        [
            "/mcp": json(401, "{}", headers: ["WWW-Authenticate": #"Bearer resource_metadata="https://a.example/.well-known/oauth-protected-resource/mcp""#]),
            "/.well-known/oauth-protected-resource/mcp": json(200, #"{"resource":"https://a.example/mcp","authorization_servers":["https://auth.example"]}"#),
            "/.well-known/oauth-authorization-server": json(200, #"{"issuer":"https://auth.example","authorization_endpoint":"https://auth.example/authorize","token_endpoint":"https://auth.example/token","registration_endpoint":"https://auth.example/register","code_challenge_methods_supported":["S256"]}"#),
            "/register": json(201, #"{"client_id":"c-1"}"#),
        ]
    }

    private func connect(_ flow: MCPOAuthFlow) -> String? {
        let launch = MCPRemoteLaunch(server: "a", url: URL(string: "https://a.example/mcp")!)
        guard case .failure(let error) = flow.connect(server: "a", launch: launch, clientID: nil, scope: nil) else { return nil }
        return error.message
    }

    @Test func flowRefusesWhatTheSpecForbids() {
        var answers = protected
        answers["/mcp"] = json(200, "{}")
        #expect(connect(flow(answers))?.contains("answered HTTP 200 without asking for authorization") == true)

        answers = protected
        answers["/.well-known/oauth-protected-resource/mcp"] = json(200, #"{"resource":"https://evil.example/mcp","authorization_servers":["https://auth.example"]}"#)
        #expect(connect(flow(answers))?.contains("resource on another origin") == true)

        answers = protected
        answers["/.well-known/oauth-protected-resource/mcp"] = json(200, #"{"resource":"https://a.example/api","authorization_servers":["https://auth.example"]}"#)
        #expect(connect(flow(answers))?.contains("different URL than this MCP server") == true)

        for resource in ["https://a.example/mcp/", "https://a.example/mcp%2F", "https://a.example/%6Dcp"] {
            answers = protected
            answers["/.well-known/oauth-protected-resource/mcp"] = json(
                200, #"{"resource":"\#(resource)","authorization_servers":["https://auth.example"]}"#)
            #expect(connect(flow(answers))?.contains("different URL than this MCP server") == true, "\(resource)")
        }

        answers = protected
        answers["/.well-known/oauth-protected-resource/mcp"] = json(200, #"{"authorization_servers":["https://auth.example"]}"#)
        let presentedOmission = Mutex(false)
        #expect(connect(flow(answers) { _ in presentedOmission.withLock { $0 = true } })?.contains("does not name") == true)
        #expect(presentedOmission.withLock { $0 } == false)

        answers = protected
        answers["/.well-known/oauth-protected-resource/mcp"] = json(200, #"{"resource":1,"authorization_servers":["https://auth.example"]}"#)
        #expect(connect(flow(answers))?.contains("does not name") == true)

        answers = protected
        answers["/.well-known/oauth-protected-resource/mcp"] = json(404, "")
        let presentedFallback = Mutex(false)
        #expect(connect(flow(answers) { _ in presentedFallback.withLock { $0 = true } })?.contains("no protected resource metadata") == true)
        #expect(presentedFallback.withLock { $0 } == false)

        answers = protected
        answers["/.well-known/oauth-authorization-server"] = json(200, #"{"issuer":"https://auth.example","authorization_endpoint":"https://auth.example/authorize","token_endpoint":"https://auth.example/token","registration_endpoint":"https://auth.example/register"}"#)
        #expect(connect(flow(answers))?.contains("does not offer PKCE S256") == true)

        answers = protected
        answers["/.well-known/oauth-authorization-server"] = json(200, #"{"issuer":"https://auth.example","authorization_endpoint":"https://auth.example/authorize","token_endpoint":"http://auth.example/token","code_challenge_methods_supported":["S256"]}"#)
        #expect(connect(flow(answers))?.contains("token endpoint must be https") == true)

        answers = protected
        answers["/register"] = nil
        answers["/.well-known/oauth-authorization-server"] = json(200, #"{"issuer":"https://auth.example","authorization_endpoint":"https://auth.example/authorize","token_endpoint":"https://auth.example/token","code_challenge_methods_supported":["S256"]}"#)
        #expect(connect(flow(answers))?.contains("pass --client-id") == true)

        answers = protected
        answers["/.well-known/oauth-authorization-server"] = json(200, #"{"issuer":"https://evil.example","authorization_endpoint":"https://auth.example/authorize","token_endpoint":"https://auth.example/token","code_challenge_methods_supported":["S256"]}"#)
        #expect(connect(flow(answers))?.contains("issuer does not match https://auth.example") == true)

        answers = protected
        answers["/.well-known/oauth-authorization-server"] = json(200, #"{"issuer":"https://auth.example","authorization_endpoint":"https://auth.example/authorize","token_endpoint":"https://evil.example/token","registration_endpoint":"https://evil.example/register","code_challenge_methods_supported":["S256"]}"#)
        #expect(connect(flow(answers))?.contains("token endpoint is not on the authorization server's origin") == true)

        answers = protected
        answers["/.well-known/oauth-protected-resource/mcp"] = json(200, #"{"resource":"https://a.example/mcp","authorization_servers":["http://127.0.0.1:9"]}"#)
        #expect(connect(flow(answers))?.contains("loopback but the MCP server is not") == true)

        answers = protected
        answers["/mcp"] = json(401, "{}", headers: ["WWW-Authenticate": #"Bearer resource_metadata="http://127.0.0.1:9/meta""#])
        #expect(connect(flow(answers))?.contains("not the MCP server's origin") == true)

        answers = protected
        answers["/mcp"] = json(401, "{}", headers: ["WWW-Authenticate": #"Bearer resource_metadata="https://evil.example/meta""#])
        #expect(connect(flow(answers))?.contains("not the MCP server's origin") == true)

        let forged = flow(protected) { url in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let redirect = items.first { $0.name == "redirect_uri" }?.value ?? ""
            followInBrowser(URL(string: redirect + "?code=stolen&state=not-the-state")!)
        }
        #expect(connect(forged) == "the sign-in redirect carried the wrong state; nothing stored")

        let refused = flow(protected) { url in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let redirect = items.first { $0.name == "redirect_uri" }?.value ?? ""
            followInBrowser(URL(string: redirect + "?error=access_denied%3Cscript%3E")!)
        }
        #expect(connect(refused) == "the authorization server refused (access_deniedscript)")
    }
}

@Suite("MCP OAuth against the fixture", .enabled(if: python3Available))
struct MCPOAuthFixtureTests {
    @Test func connectThenServeRefreshesAfterA401AndScrubsEveryToken() throws {
        let fixture = try RemoteFixture(["--oauth"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rv-oauth-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MCPOAuthTokenStore.file(configDirectory: directory)
        let url = fixture.url("/mcp")
        let flow = MCPOAuthFlow(present: followInBrowser, timeout: 15)
        let tokens = try flow.connect(server: "remote", launch: MCPRemoteLaunch(server: "remote", url: url), clientID: nil, scope: nil).get()
        #expect(tokens.resource == url.absoluteString)
        #expect(tokens.scope == "mcp:tools")
        #expect(tokens.refreshToken != nil)
        #expect(store.save("remote", tokens))

        let configuration = MCPConfiguration(defaultDecision: .allow, servers: [
            MCPServerDefinition(name: "remote", remote: MCPRemoteServer(url: url))
        ])
        let planned = try MCPLaunchPlanner.plan(
            servers: ["remote"], configuration: configuration, secrets: SecretsConfiguration(),
            resolver: SecretResolver { _ in .failure(.notFound("x")) }, baseEnvironment: [:], oauthTokens: store.load
        ).get()
        #expect(planned[0].1.remote?.oauth == store.load("remote"))
        let client = LineClient()
        let logs = RecordedLogs()
        let runtime = MCPGatewayRuntime(
            core: MCPGatewayCore(
                configuration: configuration, upstreams: planned.map { $0.0 },
                approvals: MCPApprovalGate(consumeGrant: { _, _, _ in .none }, request: { _, _, _, _ in nil })),
            connections: planned.map { $0.1 }, oauthStore: store,
            input: client.toGateway.fileHandleForReading.fileDescriptor,
            output: client.fromGateway.fileHandleForWriting.fileDescriptor,
            audit: { _ in }, log: { line in logs.lines.withLock { $0.append(line) } })
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            runtime.run()
            done.signal()
        }
        client.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
        _ = client.receive()
        func whoami(_ id: Int) -> String? {
            client.send(#"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"whoami","arguments":{}}}"#)
            return client.receive()?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue
        }
        #expect(whoami(2) == "authorization=Bearer [redacted:OAUTH_ACCESS_TOKEN] team=none")
        var expire = URLRequest(url: fixture.url("/auth/expire"))
        expire.httpMethod = "POST"
        #expect(MCPOAuthHTTP.live(expire)?.status == 200)
        #expect(whoami(3) == "authorization=Bearer [redacted:OAUTH_ACCESS_TOKEN] team=none", "\(logs.text)")
        try client.toGateway.fileHandleForWriting.close()
        #expect(done.wait(timeout: .now() + 10) == .success)

        let requests = fixture.stop()
        let refreshed = try #require(store.load("remote"))
        #expect(refreshed.accessToken != tokens.accessToken)
        #expect(refreshed.refreshToken != tokens.refreshToken)
        for fragment in ["OAUTH register", "OAUTH authorize ok scope=mcp:tools", "OAUTH token authorization_code ok",
                         "OAUTH token refresh_token ok"] {
            #expect(requests.contains(fragment), "\(fragment) in \(requests)")
        }
        #expect(logs.text.contains("at-") == false && logs.text.contains("rt-") == false, "\(logs.text)")
    }
}
