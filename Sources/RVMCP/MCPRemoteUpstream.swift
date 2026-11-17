import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization

/// How to reach one remote upstream; header secrets are already substituted.
public struct MCPRemoteLaunch: Sendable, Equatable {
    public var server: String
    public var url: URL
    public var headers: [String: String]
    public var transport: MCPRemoteTransport
    /// From `rv mcp connect`; only for servers without an Authorization header.
    public var oauth: MCPOAuthTokens?
    /// How long a request may go without a byte of its reply before the
    /// HTTP layer gives up on it; see `answerTimeout(callTimeoutSeconds:startTimeoutSeconds:)`.
    public var answerTimeout: TimeInterval

    public init(
        server: String, url: URL, headers: [String: String] = [:], transport: MCPRemoteTransport = .http,
        oauth: MCPOAuthTokens? = nil,
        answerTimeout: TimeInterval = MCPRemoteLaunch.answerTimeout(
            callTimeoutSeconds: MCPServerDefinition.defaultCallTimeoutSeconds,
            startTimeoutSeconds: MCPServerDefinition.defaultStartTimeoutSeconds)
    ) {
        self.server = server
        self.url = url
        self.headers = headers
        self.transport = transport
        self.oauth = oauth
        self.answerTimeout = answerTimeout
    }

    /// Past every limit the gateway core sets for this server (a call's
    /// total limit, `initialize`, a `tools/list` page) by a minute, so the
    /// core's deadline is the one that fires: it records the call as timed
    /// out, tells the client why and asks the server to cancel.
    public static func answerTimeout(callTimeoutSeconds: Int, startTimeoutSeconds: Int) -> TimeInterval {
        let core = max(
            TimeInterval(callTimeoutSeconds) * MCPGatewayCore.callTimeoutCeilingFactor,
            TimeInterval(startTimeoutSeconds), MCPGatewayDeadlines.standardList)
        return core + 60
    }
}

public enum MCPUpstreamConnection: Sendable, Equatable {
    case process(MCPUpstreamLaunch)
    /// Started suspended in its own process group, its lease bound to that
    /// group, then resumed; it holds placeholders, not those secrets' values.
    case placeholderBound(MCPUpstreamLaunch, MCPPlaceholderBinding)
    /// Not started; the reason is logged and the server reported exited.
    case refused(server: String, MCPPlaceholderRefusal)
    case remote(MCPRemoteLaunch)

    public var server: String {
        switch self {
        case .process(let launch): launch.server
        case .placeholderBound(let launch, _): launch.server
        case .refused(let server, _): server
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
///
/// On Linux each POST has a session of its own, invalidated once the POST is
/// over, so none goes out on a reused connection: libcurl sends a request
/// again, on a new connection, when a reused connection drops before an
/// answer, and without its body, so a `tools/call` would reach the server a
/// second time (or hang until `answerTimeout`). The event stream and the
/// session DELETE keep the shared session. On Darwin every request shares
/// it, connections and all. Exchanges are keyed by their task object, which
/// no other session could share; task identifiers are numbered per session.
///
/// What the server sends goes to `deliver`, and its going away to `exited`,
/// in the order it came, from a thread of their own: `deliver` may wait for
/// the gateway, and the delegate queue never waits with it, so a POST is
/// let go of and its bytes stop counting however far behind the gateway
/// is. The server is never slowed down (a waiting delegate queue does not
/// stop corelibs from reading, and no task is suspended): once more than
/// `deliveryLimit` bytes of what it sent wait for `deliver`, nothing more
/// is delivered and `overflowed` is told, once.
package final class MCPRemoteUpstream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Exchange {
        enum Kind {
            case post(JSONValue, retried: Bool)
            case stream(retried: Bool)
        }

        var kind: Kind
        var status = 0
        var isEventStream = false
        var body = Data()
        var events = MCPEventStream()
        var answered = false
        var token: String?
        var task: URLSessionDataTask?
        /// rv cancelled the request and closed this POST itself.
        var closed = false
        /// rv cut the reply off itself: it passed `maximumBodyBytes`.
        var oversized = false
        /// Told once, when this POST's body has all gone out or the POST
        /// is over, whichever is first (a 401 retry takes it over if it is
        /// not told yet).
        var completed: (@Sendable () -> Void)?
        /// The size of this POST's body.
        var bodyBytes = 0
        /// This POST's own session, on Linux; invalidated when it is over.
        var ownSession: URLSession?
    }

    #if canImport(Darwin)
    static let sessionPerPost = false
    #else
    static let sessionPerPost = true
    #endif

    let launch: MCPRemoteLaunch
    private let authorizer: MCPRemoteAuthorizer?
    private let deliver: @Sendable (JSONValue) -> Void
    private let exited: @Sendable () -> Void
    private let log: @Sendable (String) -> Void
    private let overflowed: @Sendable () -> Void
    /// What waits for `deliver`, by the bytes it came in.
    private let deliveries: MCPOutbox
    private let lock = NSLock()
    private var session: URLSession?
    private let delegateQueue = MCPHTTPExchange.delegateQueue("rv.mcp.remote")
    private var exchanges: [ObjectIdentifier: Exchange] = [:]
    /// POST sessions made and not yet invalidated (a test seam).
    private var liveSessions = 0
    private var sessionID: String?
    private var protocolVersion: String?
    private var initializeID: JSONValue?
    private var endpoint: URL?
    private var held: [(message: JSONValue, completed: (@Sendable () -> Void)?)] = []
    private var stopped = false
    /// Requests rv cancelled lately, so one between a 401 and its retry is
    /// not sent again. The most recent `cancelledMemory`.
    private var cancelledIDs: [JSONValue] = []
    static let cancelledMemory = 256

    package init(
        launch: MCPRemoteLaunch,
        authorizer: MCPRemoteAuthorizer? = nil,
        deliver: @escaping @Sendable (JSONValue) -> Void,
        exited: @escaping @Sendable () -> Void,
        log: @escaping @Sendable (String) -> Void,
        deliveryLimit: Int = MCPGatewayRuntime.writeBufferBytes,
        overflowed: @escaping @Sendable () -> Void = {}
    ) {
        self.launch = launch
        self.authorizer = authorizer
        self.deliver = deliver
        self.exited = exited
        self.log = log
        self.overflowed = overflowed
        self.deliveries = MCPOutbox(limit: deliveryLimit)
        super.init()
    }

    deinit {
        deliveries.close()
    }

    private var name: String { launch.server }

    /// Queued for the delivery thread, after everything the server sent
    /// before. Past the limit nothing more is taken.
    private func hand(cost: Int, _ work: @escaping @Sendable () -> Void) {
        guard deliveries.submit(cost: cost, work) == .overflow else { return }
        deliveries.abandon()
        overflowed()
    }

    private func hand(_ message: JSONValue, cost: Int) {
        let deliver = deliver
        hand(cost: cost) { deliver(message) }
    }

    /// `exited`, after what the server sent before it went away.
    private func exit() {
        let exited = exited
        hand(cost: 0) { exited() }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    package func start() {
        let session = makeSession()
        locked { self.session = session }
        guard launch.transport == .sse else { return }
        openStream(session: session, retried: false)
    }

    /// Every session of this upstream calls back on one serial queue.
    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = launch.answerTimeout
        return URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }

    /// Test seam: POST sessions made and not yet invalidated.
    var postSessionsLive: Int { locked { liveSessions } }

    private func openStream(session: URLSession, retried: Bool) {
        let (sent, token) = headers()
        var request = MCPHTTPExchange.request(
            url: launch.url, method: "GET", headers: sent, sessionID: nil, protocolVersion: nil, body: nil)
        request.timeoutInterval = 24 * 60 * 60
        // Create under the lock, after checking `stopped`: stop() sets it
        // under this lock before it invalidates the session, so a task made
        // here comes first. One made on an invalidated session raises
        // instead of failing.
        let task: URLSessionDataTask? = locked {
            guard stopped == false, self.session === session else { return nil }
            let task = session.dataTask(with: request)
            exchanges[ObjectIdentifier(task)] = Exchange(kind: .stream(retried: retried), token: token, task: task)
            return task
        }
        task?.resume()
    }

    /// Sends `message`; `completed` is told once its body has all gone out,
    /// or its POST is over (answered, failed, or closed) before that, so
    /// what waits in the HTTP layer for the server to take it can be bounded.
    package func send(_ message: JSONValue, completed: (@Sendable () -> Void)? = nil) {
        let target: URL? = locked {
            if MCPHTTPExchange.isRequest(message), message["method"]?.stringValue == "initialize" { initializeID = message["id"] }
            guard launch.transport == .sse else { return launch.url }
            guard let endpoint else {
                held.append((message, completed))
                return nil
            }
            return endpoint
        }
        if let target { post(message, to: target, retried: false, completed: completed) }
        closeCancelled(message)
    }

    /// A request rv cancelled gets no more of its reply, so its POST, if it
    /// is still open, is closed: a quiet one would otherwise hold a
    /// connection until `answerTimeout`.
    private func closeCancelled(_ message: JSONValue) {
        guard message["method"]?.stringValue == "notifications/cancelled", let target = message["params"]?["requestId"] else {
            return
        }
        let tasks: [URLSessionDataTask] = locked {
            cancelledIDs.append(target)
            if cancelledIDs.count > Self.cancelledMemory { cancelledIDs.removeFirst() }
            var tasks: [URLSessionDataTask] = []
            for (id, exchange) in exchanges {
                guard case .post(let request, _) = exchange.kind, Self.closes(request, cancelling: target),
                    let task = exchange.task
                else { continue }
                exchanges[id]?.closed = true
                tasks.append(task)
            }
            return tasks
        }
        tasks.forEach { $0.cancel() }
    }

    /// Whether a cancel of `target` closes the POST that carried `request`.
    static func closes(_ request: JSONValue, cancelling target: JSONValue) -> Bool {
        MCPHTTPExchange.isRequest(request) && request["id"] == target
    }

    package func stop() {
        let (session, closing, posts): (URLSession?, String?, [URLSession]) = locked {
            stopped = true
            // Taken out, so the completions that follow do not invalidate them again.
            var posts: [URLSession] = []
            for key in Array(exchanges.keys) {
                if let own = exchanges[key]?.ownSession { posts.append(own) }
                exchanges[key]?.ownSession = nil
            }
            return (self.session, launch.transport == .http ? sessionID : nil, posts)
        }
        // What still waits for the gateway is for nobody now.
        deliveries.abandon()
        posts.forEach { $0.invalidateAndCancel() }
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

    /// Also called from the delegate queue (a 401 retry, the SSE endpoint
    /// flush), so it can race `stop()`: the task is created under the lock,
    /// as `openStream` does. A retry of a request rv cancelled is not sent
    /// (its cancel was): checked under that same lock, which
    /// `closeCancelled` takes too, so a cancel either comes first and is
    /// seen here, or finds the retry's exchange and closes it.
    private func post(_ message: JSONValue, to url: URL, retried: Bool, completed: (@Sendable () -> Void)?) {
        let (sent, token) = headers()
        let body = Data(message.compactText.utf8)
        let task: URLSessionDataTask? = locked {
            guard stopped == false, let shared = self.session else { return nil }
            if retried, MCPHTTPExchange.isRequest(message), cancelledIDs.contains(message["id"] ?? .null) { return nil }
            var request = MCPHTTPExchange.request(
                url: url, method: "POST", headers: sent, sessionID: launch.transport == .http ? sessionID : nil,
                protocolVersion: protocolVersion, body: body)
            request.timeoutInterval = launch.answerTimeout
            // An upload task: corelibs reports a body's progress only for one.
            request.httpBody = nil
            let own = Self.sessionPerPost ? makeSession() : nil
            if own != nil { liveSessions += 1 }
            let task = (own ?? shared).uploadTask(with: request, from: body)
            exchanges[ObjectIdentifier(task)] = Exchange(
                kind: .post(message, retried: retried), token: token, task: task, completed: completed,
                bodyBytes: body.count, ownSession: own)
            return task
        }
        guard let task else {
            completed?()
            return
        }
        task.resume()
    }

    // MARK: URLSessionDataDelegate (serial delegate queue)

    package func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        locked {
            if session !== self.session { liveSessions -= 1 }
        }
    }

    package func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    /// A POST whose body has all gone out no longer counts against the
    /// bound, answered or not.
    package func urlSession(
        _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        let id = ObjectIdentifier(task)
        let taken: (@Sendable () -> Void)? = locked {
            guard let exchange = exchanges[id], totalBytesSent >= Int64(exchange.bodyBytes) else { return nil }
            exchanges[id]?.completed = nil
            return exchange.completed
        }
        taken?()
    }

    package func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        let contentType = MCPHTTPExchange.header(http, "Content-Type")?.lowercased() ?? ""
        locked {
            exchanges[ObjectIdentifier(dataTask)]?.status = http.statusCode
            exchanges[ObjectIdentifier(dataTask)]?.isEventStream = contentType.hasPrefix("text/event-stream")
            if launch.transport == .http, (200..<300).contains(http.statusCode),
                let assigned = MCPHTTPExchange.header(http, "Mcp-Session-Id"), MCPHTTPExchange.isSessionID(assigned)
            {
                sessionID = assigned
            }
        }
        completionHandler(.allow)
    }

    package func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let id = ObjectIdentifier(dataTask)
        guard var exchange = locked({ exchanges[id] }) else { return }
        var incoming: [(message: JSONValue, cost: Int)] = []
        var endpointEvent: String?
        if exchange.isEventStream, (200..<300).contains(exchange.status) {
            for event in exchange.events.feed(data) {
                if event.name == "endpoint" {
                    endpointEvent = event.data
                } else if event.name == "message", let message = try? JSONValue.parse(Data(event.data.utf8)) {
                    incoming.append((message, event.data.utf8.count))
                }
            }
            if exchange.events.overflowed {
                log("MCP server \(name) sent an event larger than \(MCPEventStream.maximumEventBytes) bytes; closing the stream")
                exchange.oversized = true
                dataTask.cancel()
            }
        } else if exchange.body.count + data.count <= MCPHTTPExchange.maximumBodyBytes {
            exchange.body.append(data)
        } else {
            log("MCP server \(name) sent a reply larger than \(MCPHTTPExchange.maximumBodyBytes) bytes; dropped")
            exchange.body = Data()
            exchange.oversized = true
            dataTask.cancel()
        }
        for item in incoming { note(item.message, answering: &exchange) }
        locked { exchanges[id] = exchange }
        if let endpointEvent { useEndpoint(endpointEvent, stream: dataTask) }
        for item in incoming { hand(item.message, cost: item.cost) }
    }

    package func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = ObjectIdentifier(task)
        guard let exchange = locked({ exchanges.removeValue(forKey: id) }) else { return }
        // Its connection goes with it; a retry gets a session of its own.
        exchange.ownSession?.finishTasksAndInvalidate()
        guard locked({ stopped }) == false else {
            exchange.completed?()
            return
        }
        switch exchange.kind {
        case .stream(let retried):
            // The GET stream gets the same one-shot 401 refresh as a POST:
            // an expired token at startup must not kill the connection.
            if exchange.status == 401, retried == false, let authorizer, authorizer.refresh(exchange.token),
                locked({ stopped }) == false
            {
                openStream(session: session, retried: true)
                return
            }
            let reason = exchange.status == 200 || exchange.status == 0
                ? (error.map { "event stream failed: \($0.localizedDescription)" } ?? "event stream closed")
                : "event stream refused (HTTP \(exchange.status))"
            log("MCP server \(name) \(reason)")
            exit()
        case .post(let message, let retried):
            // A retry takes the completion over; otherwise this POST is over.
            if completePost(message, exchange: exchange, error: error, retried: retried) == false {
                exchange.completed?()
            }
        }
    }

    /// True when a 401 retry took the completion over.
    private func completePost(_ message: JSONValue, exchange: Exchange, error: Error?, retried: Bool) -> Bool {
        var exchange = exchange
        func fail(_ text: String) {
            if let reply = MCPHTTPExchange.failure(for: message, text) {
                hand(reply, cost: text.utf8.count)
            } else {
                log(text)
            }
        }
        if let error, exchange.answered == false {
            // Neither is the server's answer. rv closed this one after
            // cancelling it; the HTTP layer gives up only after the core's
            // own deadline has ended the request, and a failure delivered
            // for it would be recorded as the tool having run.
            if exchange.closed { return false }
            // The server answered, too large to pass on: this request ends
            // with that error, and the session is left as it is.
            if exchange.oversized {
                fail("MCP server \(name) sent a reply larger than \(MCPHTTPExchange.maximumBodyBytes) bytes, "
                    + "which rv does not pass on")
                return false
            }
            if MCPHTTPExchange.isRequest(message), (error as? URLError)?.code == .timedOut {
                log("MCP server \(name) sent nothing on a request for \(Int(launch.answerTimeout)) s; "
                    + "rv stopped waiting at the HTTP level")
                return false
            }
            // Whether the server took the request is unknown, so it is not
            // its answer: the connection to it is gone, and so is it (a call
            // on it may have run).
            log("could not reach MCP server \(name): \(error.localizedDescription)")
            if MCPHTTPExchange.isRequest(message) { exit() }
            return false
        }
        let status = exchange.status
        if status == 401, retried == false, let authorizer, authorizer.refresh(exchange.token) {
            // `post` sends nothing for a request cancelled meanwhile.
            guard let target = locked({ launch.transport == .sse ? endpoint : launch.url }) else { return false }
            post(message, to: target, retried: true, completed: exchange.completed)
            return true
        }
        // The server ended the session: it is gone for rv, which starts a
        // new one (an answer still owed on it may have run).
        if status == 404, launch.transport == .http, locked({ sessionID }) != nil {
            locked { sessionID = nil }
            log("MCP server \(name) ended the session (HTTP 404)")
            exit()
            return false
        }
        var incoming: [JSONValue] = []
        if exchange.isEventStream == false, exchange.body.isEmpty == false {
            incoming = MCPHTTPExchange.messages(inJSON: exchange.body) ?? []
        }
        incoming = incoming.filter { $0["jsonrpc"]?.stringValue == "2.0" }
        for item in incoming { note(item, answering: &exchange) }
        // A batch is counted at its share of the body.
        let cost = exchange.body.count / max(incoming.count, 1)
        for item in incoming { hand(item, cost: cost) }
        guard exchange.answered == false, MCPHTTPExchange.isRequest(message) else { return false }
        switch status {
        case 200..<300:
            if launch.transport == .http {
                fail("MCP server \(name) closed its reply without answering")
            }
        case 401, 403:
            let hint = authorizer == nil ? "check its headers in mcp.json" : "run `rv mcp connect \(name)`"
            fail("MCP server \(name) refused the credentials (HTTP \(status)); \(hint)")
        default:
            fail("MCP server \(name) returned HTTP \(status)")
        }
        return false
    }

    /// Marks the exchange answered and learns the negotiated protocol version.
    private func note(_ message: JSONValue, answering exchange: inout Exchange) {
        guard message["method"] == nil, let id = message["id"] else { return }
        if case .post(let request, _) = exchange.kind, request["id"] == id { exchange.answered = true }
        locked {
            // The version goes back out as a header value, so it gets the
            // same visible-ASCII rule as a session ID.
            if id == initializeID, let version = message["result"]?["protocolVersion"]?.stringValue,
                MCPHTTPExchange.isSessionID(version)
            {
                protocolVersion = version
            }
        }
    }

    /// Legacy SSE: the stream names where to POST. The bearer stays on this
    /// server's exact URL. A different path or query, a foreign origin, or a
    /// URL `mcp.json` would refuse is not a place to send it.
    private func useEndpoint(_ text: String, stream: URLSessionDataTask) {
        if let problem = Self.messageEndpointRefusal(text, relativeTo: launch.url) {
            log("MCP server \(name) named a message endpoint \(problem); refused")
            stream.cancel()
            return
        }
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces), relativeTo: launch.url)?.absoluteURL else {
            return
        }
        let flushed: [(message: JSONValue, completed: (@Sendable () -> Void)?)] = locked {
            guard endpoint == nil else { return [] }
            endpoint = url
            defer { held = [] }
            return held
        }
        for item in flushed { post(item.message, to: url, retried: false, completed: item.completed) }
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
        if MCPOAuth.sameResource(url, base) == false { return "other than this MCP server's URL" }
        return nil
    }
}

/// One-shot response accumulator: refuses redirects and aborts past `limit`.
final class MCPBoundedOneShot: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let limit: Int
    let done = DispatchSemaphore(value: 0)
    let result = Mutex<MCPHTTPResponse?>(nil)
    private let state = Mutex<(status: Int, headers: [String: String], body: Data, overflow: Bool)>((0, [:], Data(), false))

    init(limit: Int) { self.limit = limit }

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
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        state.withLock { $0.status = http.statusCode; $0.headers = headers }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let overflow = state.withLock { current -> Bool in
            if current.body.count + data.count > limit {
                current.overflow = true
                return true
            }
            current.body.append(data)
            return false
        }
        if overflow { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let finished = state.withLock { $0 }
        if error == nil, finished.overflow == false, finished.status > 0 {
            result.withLock { $0 = MCPHTTPResponse(status: finished.status, headers: finished.headers, body: finished.body) }
        }
        done.signal()
    }
}
