import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// How to reach one remote upstream; header secrets are already substituted.
public struct MCPRemoteLaunch: Sendable, Equatable {
    public var server: String
    public var url: URL
    public var headers: [String: String]
    public var transport: MCPRemoteTransport
    /// From `rv mcp connect`; only for servers without an Authorization header.
    public var oauth: MCPOAuthTokens?

    public init(
        server: String, url: URL, headers: [String: String] = [:], transport: MCPRemoteTransport = .http,
        oauth: MCPOAuthTokens? = nil
    ) {
        self.server = server
        self.url = url
        self.headers = headers
        self.transport = transport
        self.oauth = oauth
    }
}

public enum MCPUpstreamConnection: Sendable, Equatable {
    case process(MCPUpstreamLaunch)
    case remote(MCPRemoteLaunch)

    public var server: String {
        switch self {
        case .process(let launch): launch.server
        case .remote(let launch): launch.server
        }
    }

    public var process: MCPUpstreamLaunch? {
        if case .process(let launch) = self { return launch }
        return nil
    }

    public var remote: MCPRemoteLaunch? {
        if case .remote(let launch) = self { return launch }
        return nil
    }
}

/// Bearer tokens for a remote upstream (OAuth). `refresh` gets the token a
/// 401 rejected and is true when a newer one is ready (refreshed now, or
/// already by another request).
public struct MCPRemoteAuthorizer: Sendable {
    public var token: @Sendable () -> String?
    public var refresh: @Sendable (_ rejected: String?) -> Bool

    public init(token: @escaping @Sendable () -> String?, refresh: @escaping @Sendable (_ rejected: String?) -> Bool) {
        self.token = token
        self.refresh = refresh
    }
}

/// One remote MCP server over streamable HTTP or legacy HTTP+SSE. Messages
/// from the server go to `deliver`; a request that gets no answer (network
/// error, HTTP error, closed stream) is answered with a JSON-RPC error, so the
/// gateway core needs no transport knowledge. Redirects are never followed.
final class MCPRemoteUpstream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Exchange {
        enum Kind {
            case post(JSONValue, retried: Bool)
            case stream
        }

        var kind: Kind
        var status = 0
        var isEventStream = false
        var body = Data()
        var events = MCPEventStream()
        var answered = false
        var token: String?
    }

    let launch: MCPRemoteLaunch
    private let authorizer: MCPRemoteAuthorizer?
    private let deliver: @Sendable (JSONValue) -> Void
    private let exited: @Sendable () -> Void
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var session: URLSession?
    private var exchanges: [Int: Exchange] = [:]
    private var sessionID: String?
    private var protocolVersion: String?
    private var initializeID: JSONValue?
    private var endpoint: URL?
    private var held: [JSONValue] = []
    private var stopped = false

    init(
        launch: MCPRemoteLaunch,
        authorizer: MCPRemoteAuthorizer? = nil,
        deliver: @escaping @Sendable (JSONValue) -> Void,
        exited: @escaping @Sendable () -> Void,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.launch = launch
        self.authorizer = authorizer
        self.deliver = deliver
        self.exited = exited
        self.log = log
        super.init()
    }

    private var name: String { launch.server }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func start() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = MCPHTTPExchange.requestTimeout
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        locked { self.session = session }
        guard launch.transport == .sse else { return }
        var request = MCPHTTPExchange.request(
            url: launch.url, method: "GET", headers: headers().headers, sessionID: nil, protocolVersion: nil, body: nil)
        request.timeoutInterval = 24 * 60 * 60
        let task = session.dataTask(with: request)
        locked { exchanges[task.taskIdentifier] = Exchange(kind: .stream) }
        task.resume()
    }

    func send(_ message: JSONValue) {
        let target: URL? = locked {
            if MCPHTTPExchange.isRequest(message), message["method"]?.stringValue == "initialize" { initializeID = message["id"] }
            guard launch.transport == .sse else { return launch.url }
            guard let endpoint else {
                held.append(message)
                return nil
            }
            return endpoint
        }
        if let target { post(message, to: target, retried: false) }
    }

    func stop() {
        let (session, closing): (URLSession?, String?) = locked {
            stopped = true
            return (self.session, launch.transport == .http ? sessionID : nil)
        }
        guard let session else { return }
        if let closing {
            let request = MCPHTTPExchange.request(
                url: launch.url, method: "DELETE", headers: headers().headers, sessionID: closing, protocolVersion: protocolVersionNow(),
                body: nil)
            let done = DispatchSemaphore(value: 0)
            session.dataTask(with: request) { _, _, _ in done.signal() }.resume()
            _ = done.wait(timeout: .now() + 2)
        }
        session.invalidateAndCancel()
    }

    private func protocolVersionNow() -> String? { locked { protocolVersion } }

    private func headers() -> (headers: [String: String], token: String?) {
        var headers = launch.headers
        let token = authorizer?.token()
        if let token { headers["Authorization"] = "Bearer \(token)" }
        return (headers, token)
    }

    private func post(_ message: JSONValue, to url: URL, retried: Bool) {
        let (session, sessionID, version): (URLSession?, String?, String?) = locked {
            (stopped ? nil : self.session, launch.transport == .http ? self.sessionID : nil, protocolVersion)
        }
        guard let session else { return }
        let (sent, token) = headers()
        let request = MCPHTTPExchange.request(
            url: url, method: "POST", headers: sent, sessionID: sessionID, protocolVersion: version,
            body: Data(message.compactText.utf8))
        let task = session.dataTask(with: request)
        locked { exchanges[task.taskIdentifier] = Exchange(kind: .post(message, retried: retried), token: token) }
        task.resume()
    }

    // MARK: URLSessionDataDelegate (serial delegate queue)

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        let contentType = MCPHTTPExchange.header(http, "Content-Type")?.lowercased() ?? ""
        locked {
            exchanges[dataTask.taskIdentifier]?.status = http.statusCode
            exchanges[dataTask.taskIdentifier]?.isEventStream = contentType.hasPrefix("text/event-stream")
            if launch.transport == .http, (200..<300).contains(http.statusCode),
                let assigned = MCPHTTPExchange.header(http, "Mcp-Session-Id"), MCPHTTPExchange.isSessionID(assigned)
            {
                sessionID = assigned
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let id = dataTask.taskIdentifier
        guard var exchange = locked({ exchanges[id] }) else { return }
        var incoming: [JSONValue] = []
        var endpointEvent: String?
        if exchange.isEventStream, (200..<300).contains(exchange.status) {
            for event in exchange.events.feed(data) {
                if event.name == "endpoint" {
                    endpointEvent = event.data
                } else if event.name == "message", let message = try? JSONValue.parse(Data(event.data.utf8)) {
                    incoming.append(message)
                }
            }
            if exchange.events.overflowed {
                log("MCP server \(name) sent an event larger than \(MCPEventStream.maximumEventBytes) bytes; closing the stream")
                dataTask.cancel()
            }
        } else if exchange.body.count + data.count <= MCPHTTPExchange.maximumBodyBytes {
            exchange.body.append(data)
        } else {
            log("MCP server \(name) sent a reply larger than \(MCPHTTPExchange.maximumBodyBytes) bytes; dropped")
            exchange.body = Data()
            dataTask.cancel()
        }
        for message in incoming { note(message, answering: &exchange) }
        locked { exchanges[id] = exchange }
        if let endpointEvent { useEndpoint(endpointEvent, stream: dataTask) }
        incoming.forEach(deliver)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskIdentifier
        guard let exchange = locked({ exchanges.removeValue(forKey: id) }), locked({ stopped }) == false else {
            return
        }
        switch exchange.kind {
        case .stream:
            let reason = exchange.status == 200 || exchange.status == 0
                ? (error.map { "event stream failed: \($0.localizedDescription)" } ?? "event stream closed")
                : "event stream refused (HTTP \(exchange.status))"
            log("MCP server \(name) \(reason)")
            exited()
        case .post(let message, let retried):
            completePost(message, exchange: exchange, error: error, retried: retried)
        }
    }

    private func completePost(_ message: JSONValue, exchange: Exchange, error: Error?, retried: Bool) {
        var exchange = exchange
        func fail(_ text: String) {
            if let reply = MCPHTTPExchange.failure(for: message, text) {
                deliver(reply)
            } else {
                log(text)
            }
        }
        if let error, exchange.answered == false {
            fail("could not reach MCP server \(name): \(error.localizedDescription)")
            return
        }
        let status = exchange.status
        if status == 401, retried == false, let authorizer, authorizer.refresh(exchange.token) {
            if let target = locked({ launch.transport == .sse ? endpoint : launch.url }) {
                post(message, to: target, retried: true)
            }
            return
        }
        var incoming: [JSONValue] = []
        if exchange.isEventStream == false, exchange.body.isEmpty == false {
            incoming = MCPHTTPExchange.messages(inJSON: exchange.body) ?? []
        }
        incoming = incoming.filter { $0["jsonrpc"]?.stringValue == "2.0" }
        for item in incoming { note(item, answering: &exchange) }
        incoming.forEach(deliver)
        guard exchange.answered == false, MCPHTTPExchange.isRequest(message) else { return }
        switch status {
        case 200..<300:
            if launch.transport == .http {
                fail("MCP server \(name) closed its reply without answering")
            }
        case 401, 403:
            let hint = authorizer == nil ? "check its headers in mcp.json" : "run `rv mcp connect \(name)`"
            fail("MCP server \(name) refused the credentials (HTTP \(status)); \(hint)")
        case 404 where locked({ sessionID }) != nil:
            locked { sessionID = nil }
            fail("MCP server \(name) ended the session (HTTP 404); restart the MCP client")
        default:
            fail("MCP server \(name) returned HTTP \(status)")
        }
    }

    /// Marks the exchange answered and learns the negotiated protocol version.
    private func note(_ message: JSONValue, answering exchange: inout Exchange) {
        guard message["method"] == nil, let id = message["id"] else { return }
        if case .post(let request, _) = exchange.kind, request["id"] == id { exchange.answered = true }
        locked {
            if id == initializeID, let version = message["result"]?["protocolVersion"]?.stringValue,
                version.isEmpty == false, version.utf8.count <= 64
            {
                protocolVersion = version
            }
        }
    }

    /// Legacy SSE: the stream names where to POST. It must be same-origin
    /// and pass the same URL checks as `mcp.json`, or headers and tokens
    /// would go to a host, userinfo, or query secret the user never reviewed.
    private func useEndpoint(_ text: String, stream: URLSessionDataTask) {
        if let problem = Self.messageEndpointRefusal(text, relativeTo: launch.url) {
            log("MCP server \(name) named a message endpoint \(problem); refused")
            stream.cancel()
            return
        }
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces), relativeTo: launch.url)?.absoluteURL else {
            return
        }
        let flushed: [JSONValue] = locked {
            guard endpoint == nil else { return [] }
            endpoint = url
            defer { held = [] }
            return held
        }
        for message in flushed { post(message, to: url, retried: false) }
    }

    /// Nil when `text` may receive the bearer token. The refusal is a phrase
    /// that finishes "named a message endpoint …".
    static func messageEndpointRefusal(_ text: String, relativeTo base: URL) -> String? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces), relativeTo: base)?.absoluteURL else {
            return "that is not a URL"
        }
        // Origin first: a foreign URL is refused even when it also fails the
        // https check, which is the log the legacy SSE stream already emits.
        if MCPHTTPExchange.sameOrigin(url, base) == false { return "on another origin" }
        if let problem = MCPRemoteServer.endpointProblem(url) { return "that \(problem)" }
        return nil
    }
}

/// Refuses every redirect (D22) for one-shot OAuth requests.
final class MCPNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
