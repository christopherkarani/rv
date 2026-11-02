#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What happened to one gateway request.
public enum SecretGatewayActivity: String, Sendable, Equatable {
    /// The value was placed and the request forwarded upstream.
    case brokered
    /// Refused by the secret's own policy before any value was placed: a misuse signal.
    case blocked
    /// Refused before forwarding for any other reason.
    case refused
    /// Forwarded, but no upstream response arrived.
    case error
    /// A refresh swapped in a new value from the provider.
    case refreshed
    /// A refresh could not read the provider; the previous value stays until its grace ends.
    case refreshFailed
}

/// What one gateway request did. Carries names and a fingerprint, never a
/// value or a placeholder.
public struct SecretUseRecord: Sendable, Equatable {
    /// A brokered request is recorded once before forwarding, so a failed
    /// append stops it, and once with its outcome.
    public enum Stage: String, Sendable, Equatable {
        case forward
        case complete
    }

    public var secret: String?
    public var runtime: String?
    public var upstreamHost: String?
    public var method: String
    /// Path only, placeholders redacted; the query string is never recorded.
    public var path: String
    /// What the agent received.
    public var status: Int
    /// What the upstream answered, when it answered.
    public var upstreamStatus: Int?
    public var activity: SecretGatewayActivity
    /// `GatewayRefusal` case name for blocked and refused requests.
    public var refusal: String?
    public var reason: String?
    /// Request surfaces the value was placed on.
    public var surfaces: [String]
    public var fingerprint: String?
    public var responseBytes: Int
    public var durationMilliseconds: Int
    public var stage: Stage

    public var allowed: Bool { activity == .brokered || activity == .error }
}

public struct SecretUpstreamRequest: Sendable {
    public var method: String
    public var url: URL
    public var headers: [(name: String, value: String)]
    public var body: Data
}

/// Receives one upstream response. `body` returns false once the client is gone.
public protocol SecretResponseSink: AnyObject, Sendable {
    func head(status: Int, headers: [(name: String, value: String)])
    func body(_ data: Data) -> Bool
    func finish()
    func fail(_ reason: String)
}

/// Performs one upstream exchange and blocks until the sink is finished or failed.
public struct SecretUpstreamTransport: Sendable {
    public var send: @Sendable (SecretUpstreamRequest, SecretResponseSink) -> Void

    public init(send: @escaping @Sendable (SecretUpstreamRequest, SecretResponseSink) -> Void) {
        self.send = send
    }

    public static var urlSession: SecretUpstreamTransport {
        let transport = URLSessionStreamingTransport()
        return SecretUpstreamTransport { request, sink in transport.send(request, sink: sink) }
    }
}

/// Loopback reverse proxy that swaps per-launch placeholders for real
/// secret values, only toward the secret's bound upstream origin.
public final class SecretGateway: @unchecked Sendable {
    public struct Entry: Sendable {
        public var secret: String
        public var prefix: String
        public var value: SecretValue
        public var upstream: URL
        public var fingerprint: String?
        public var runtime: String?
        public var surfaces: Set<GatewaySurface> = GatewaySurface.defaults
        /// Expanded allow rules; empty allows any method and path.
        public var rules: [GatewayAccessRule] = []
        /// The runtime leader's process group, set once it is spawned. Only
        /// a connection from that runtime may spend the value; nil refuses all.
        var processGroup: ProcessGroupFact?
        /// From this instant requests are refused.
        public var expires: Date?
        /// How the value is re-resolved while the runtime lives; nil keeps the launch value.
        public var refresh: SecretRefreshPolicy?
        /// Set for AWS SigV4 delivery: `value` is a credential set, and the
        /// gateway re-signs instead of substituting.
        var signing: AWSSigningBinding?
        /// Expanded `approve` rules; a matching request needs a human's yes.
        var approvals: [GatewayAccessRule] = []
        /// Set at bind when the runtime has an admission channel that can ask.
        var approver: SecretRequestApprover?
        /// Bumped each time a refresh swaps the value.
        var generation = 0
        /// Values this entry held before, newest first, still scrubbed from responses.
        var previous: [SecretValue] = []
        var rotation: SecretRotationState?
    }

    public static let maximumBodyBytes = 32 * 1024 * 1024
    static let maximumConnections = 64
    /// Above the spawn floors (8 and 16). Gateway sockets must not remain
    /// on a descriptor `relocateDescriptor` has just closed.
    static let socketFloor: Int32 = 64

    private let transport: SecretUpstreamTransport
    private let peers: GatewayPeerCheck
    /// Returns false when the record did not land; a forward record that
    /// does not land stops the request.
    let audit: @Sendable (SecretUseRecord) -> Bool
    let now: @Sendable () -> Date
    let approvalTiming: GatewayApprovalTiming
    let lock = NSLock()
    var entries: [String: Entry] = [:]
    /// Approvals filed and not yet resolved, by placeholder and the action digest they bind.
    var parkedApprovals: [ParkedApprovalKey: ParkedApproval] = [:]
    /// Requests currently held open waiting for a human.
    var waitingApprovals = 0
    /// Every listener `start` handed to an accept loop. `stop` closes all of them.
    private var listenFDs: [Int32] = []
    /// Signaled when that fd's accept loop has left the socket, so `stop`
    /// can close it after Darwin would otherwise keep the port accepting.
    private var acceptExited: [Int32: DispatchSemaphore] = [:]
    private var boundPort: Int?
    /// Bumped by `stop`. A `start` that was binding while `stop` ran must
    /// not publish its listener afterwards.
    private var lifecycleGeneration = 0
    private let slots = DispatchSemaphore(value: SecretGateway.maximumConnections)
    private let acceptQueue = DispatchQueue(label: "rv.secret-gateway.accept", qos: .userInitiated)
    /// Test seam, nil in production. Runs after the fast-path check and before
    /// the listener is published, so two `start` calls can overlap that window.
    var beforeListenerPublish: (@Sendable () -> Void)?

    public convenience init(
        transport: SecretUpstreamTransport = .urlSession,
        audit: @escaping @Sendable (SecretUseRecord) -> Bool,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(transport: transport, peers: .runtime, audit: audit, now: now)
    }

    init(
        transport: SecretUpstreamTransport,
        peers: GatewayPeerCheck,
        audit: @escaping @Sendable (SecretUseRecord) -> Bool,
        now: @escaping @Sendable () -> Date = { Date() },
        approvalTiming: GatewayApprovalTiming = .standard
    ) {
        self.transport = transport
        self.peers = peers
        self.audit = audit
        self.now = now
        self.approvalTiming = approvalTiming
    }

    deinit {
        stop()
    }

    public var port: Int? {
        lock.lock()
        defer { lock.unlock() }
        return boundPort
    }

    public func baseURL(secret: String) -> String? {
        port.map { "http://127.0.0.1:\($0)/s/\(secret)" }
    }

    public func register(_ placeholder: SecretPlaceholder, entry: Entry) {
        var entry = entry
        if let refresh = entry.refresh {
            entry.rotation = SecretRotationState(resolvedAt: now(), marker: refresh.marker)
        }
        lock.lock()
        entries[placeholder.token] = entry
        lock.unlock()
    }

    public func bind(_ placeholders: [SecretPlaceholder], runtime: String) {
        lock.lock()
        for placeholder in placeholders { entries[placeholder.token]?.runtime = runtime }
        lock.unlock()
    }

    func bind(_ placeholders: [SecretPlaceholder], processGroup: ProcessGroupFact) {
        lock.lock()
        for placeholder in placeholders { entries[placeholder.token]?.processGroup = processGroup }
        lock.unlock()
    }

    func bind(_ placeholders: [SecretPlaceholder], approver: SecretRequestApprover) {
        lock.lock()
        for placeholder in placeholders { entries[placeholder.token]?.approver = approver }
        lock.unlock()
    }

    public func revoke(_ placeholders: [SecretPlaceholder]) {
        lock.lock()
        for placeholder in placeholders { entries[placeholder.token] = nil }
        lock.unlock()
        cancelApprovals(for: Set(placeholders.map(\.token)))
    }

    var liveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    func entry(_ token: String) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[token]
    }

    /// A TCP stream socket that is close-on-exec before the caller uses it.
    /// Linux passes `SOCK_CLOEXEC` to `socket`. Darwin does not define that
    /// flag, so the descriptor that survives is the one `F_DUPFD_CLOEXEC`
    /// creates. The original is closed once, including when `socket`
    /// returned 0, 1, or 2, because that slot was free and the number is
    /// this socket. `close` is not retried.
    private static func openStreamSocket() -> Int32 {
        #if canImport(Darwin)
        return publishCloexecSocket(raw: socket(AF_INET, SOCK_STREAM, 0), above: socketFloor)
        #else
        return socket(
            AF_INET,
            Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue),
            0
        )
        #endif
    }

    public func start() -> Result<Int, EgressStartError> {
        lock.lock()
        if let boundPort {
            lock.unlock()
            return .success(boundPort)
        }
        let generation = lifecycleGeneration
        let overlap = beforeListenerPublish
        lock.unlock()
        overlap?()
        var fd = Self.openStreamSocket()
        guard fd >= 0 else { return .failure(.socketFailed(errno: errno)) }
        // A listener that stays below the spawn floor occupies a number
        // relocate just closed. Move it up before bind. The owned-socket
        // form also closes a stdio-slot original, which `socket` may
        // have returned on Linux when that slot was free.
        guard relocateOwnedSocket(&fd, above: Self.socketFloor) else {
            // The failed move already closed the original once.
            return .failure(.socketFailed(errno: errno))
        }
        let listener = fd
        _ = fcntl(listener, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        _ = setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer -> Int32 in
                #if canImport(Darwin)
                Darwin.bind(listener, pointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                #else
                Glibc.bind(listener, pointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                #endif
            }
        }
        guard bound == 0 else {
            let code = errno
            close(listener)
            return .failure(.bindFailed(errno: code))
        }
        guard listen(listener, 64) == 0 else {
            let code = errno
            close(listener)
            return .failure(.listenFailed(errno: code))
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        guard named == 0 else {
            let code = errno
            close(listener)
            return .failure(.addressFailed(errno: code))
        }
        let port = Int(UInt16(bigEndian: actual.sin_port))
        lock.lock()
        // A stop ran while this socket was binding. Do not publish a
        // listener after stop returned.
        if lifecycleGeneration != generation {
            lock.unlock()
            close(listener)
            return .failure(.socketFailed(errno: ECANCELED))
        }
        // Another start published while this socket was binding. Close the
        // extra listener; callers must use the port that was already published.
        if let published = boundPort {
            lock.unlock()
            close(listener)
            return .success(published)
        }
        let exited = DispatchSemaphore(value: 0)
        acceptExited[listener] = exited
        listenFDs.append(listener)
        boundPort = port
        let flags = fcntl(listener, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(listener, F_SETFL, flags | O_NONBLOCK)
        }
        acceptQueue.async { [weak self] in
            self?.acceptLoop(listener)
            exited.signal()
        }
        lock.unlock()
        return .success(port)
    }

    public func stop() {
        lock.lock()
        lifecycleGeneration += 1
        let fds = listenFDs
        let port = boundPort
        let waits = fds.compactMap { acceptExited[$0] }
        listenFDs.removeAll()
        acceptExited.removeAll()
        boundPort = nil
        entries.removeAll()
        lock.unlock()
        cancelApprovals(for: nil)
        if let port {
            wakeListeningPort(port)
        }
        for fd in fds where fd >= 0 {
            shutdown(fd, Int32(SHUT_RDWR))
        }
        for wait in waits {
            _ = wait.wait(timeout: .now() + 2)
        }
        for fd in fds where fd >= 0 {
            close(fd)
        }
    }

    /// A loopback connect makes `poll` see the listener so the accept loop
    /// can leave the fd. `close` before that leaves the port accepting on Darwin.
    /// The connect runs on a high fd: a non-blocking `EINPROGRESS` socket must
    /// not remain on a number below the spawn floor.
    private func wakeListeningPort(_ port: Int) {
        var fd = Self.openStreamSocket()
        guard fd >= 0 else { return }
        // Owned-socket form: a failed move already closed the original.
        if relocateOwnedSocket(&fd, above: Self.socketFloor) == false {
            return
        }
        defer { close(fd) }
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            lock.lock()
            let live = listenFDs.contains(fd)
            lock.unlock()
            if live == false { return }
            var state = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let polled = poll(&state, 1, 200)
            if polled < 0 {
                if errno == EINTR { continue }
                return
            }
            lock.lock()
            let still = listenFDs.contains(fd)
            lock.unlock()
            if still == false { return }
            if polled == 0 { continue }
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                return
            }
            lock.lock()
            let serve = listenFDs.contains(fd)
            lock.unlock()
            if serve == false {
                close(client)
                return
            }
            // Darwin inherits `O_NONBLOCK` from the listener. A read that
            // races the client's write is `EAGAIN`, and that is not a
            // malformed request. The accepted number is closed once before
            // the handler blocks, including when `accept` returned 0, 1, or
            // 2. `F_SETFD` on the duplicate does not cover that original.
            var held = client
            guard relocateOwnedSocket(&held, above: Self.socketFloor) else {
                continue
            }
            let flags = fcntl(held, F_GETFL, 0)
            if flags >= 0 {
                _ = fcntl(held, F_SETFL, flags & ~O_NONBLOCK)
            }
            _ = fcntl(held, F_SETFD, FD_CLOEXEC)
            #if canImport(Darwin)
            var one: Int32 = 1
            _ = setsockopt(held, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            #endif
            var timeout = timeval(tv_sec: 30, tv_usec: 0)
            _ = setsockopt(held, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            guard slots.wait(timeout: .now()) == .success else {
                GatewaySocket.writeAll(held, GatewaySocket.plainResponse(status: 503, reason: "gateway busy"))
                close(held)
                continue
            }
            let clientFD = held
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                defer { close(clientFD) }
                guard let self else { return }
                defer { self.slots.signal() }
                self.handle(clientFD)
            }
        }
    }

    func handle(_ client: Int32) {
        let started = DispatchTime.now()
        let reader = GatewaySocket.Reader(fd: client)
        guard let headBytes = reader.readHead(limit: GatewayRequestHead.maximumBytes),
            let head = GatewayRequestHead.parse(headBytes)
        else {
            refuse(client, .malformed, method: "?", path: "?", secret: nil, started: started)
            return
        }
        let path = SecretPlaceholder.redactedPath(head.target)
        guard let route = GatewayRoute(target: head.target) else {
            refuse(client, .unknownRoute, method: head.method, path: path, secret: nil, started: started)
            return
        }
        // Every live entry the request names, so a refusal can name the
        // runtime the placeholder was leased to.
        var presented: [Entry] = []
        func deny(_ refusal: GatewayRefusal) {
            refuse(
                client, refusal, method: head.method, path: path, secret: route.secret,
                runtime: presented.first?.runtime, started: started)
        }
        guard GatewayHeaders.echoMethods.contains(head.method) == false else {
            deny(.echoMethod)
            return
        }
        var forwarded = head
        forwarded.headers = GatewayHeaders.forwardable(head.headers)
        func substitute() -> Result<
            (head: GatewayRequestHead, used: GatewaySubstitution.Live, surfaces: Set<GatewaySurface>), GatewayRefusal
        > {
            presented = []
            if let authorization = forwarded.header("Authorization"), AWSSigV4.isSigV4(authorization) {
                return admitAWS(forwarded, route: route, authorization: authorization, presented: &presented)
            }
            return GatewaySubstitution.apply(forwarded, route: route) { token in
                let found = entry(token)
                if let found { presented.append(found) }
                return found.map { Self.live($0, token: token) }
            }
        }
        var substituted = substitute()
        // Expiry and refresh apply once the placeholder has passed its own
        // policy, so a misuse is never reported as an expiry.
        if case .success(let result) = substituted {
            // Only the placeholder's own runtime may trigger a refresh.
            if let refusal = verifyPeer(client, presented) {
                deny(refusal)
                return
            }
            if let refusal = prepare(result.used.token) {
                deny(refusal)
                return
            }
            if entry(result.used.token)?.value != result.used.value { substituted = substitute() }
        }
        var rewritten: GatewayRequestHead
        let token: String
        let surfaces: [String]
        switch substituted {
        case .failure(let refusal):
            deny(refusal)
            return
        case .success(let result):
            rewritten = result.head
            token = result.used.token
            surfaces = GatewaySurface.ordered(result.surfaces).map(\.rawValue)
        }
        guard var live = entry(token),
            let upstreamRoute = GatewayRoute(target: rewritten.target),
            var url = upstreamRoute.upstreamURL(base: live.upstream)
        else {
            deny(.unknownPlaceholder)
            return
        }
        if head.header("Expect")?.lowercased() == "100-continue" {
            GatewaySocket.writeAll(client, Array("HTTP/1.1 100 Continue\r\n\r\n".utf8))
        }
        guard let body = readBody(reader, head: head) else {
            deny(.tooLarge)
            return
        }
        if let refusal = approval(
            live, token: token, method: head.method, route: route, basePath: Self.live(live, token: token).basePath,
            url: url, target: head.target, headers: forwarded.headers, body: body)
        {
            deny(refusal)
            return
        }
        // The hold can last seconds: what the human approved is the request,
        // not the entry as it was then. Revoked, expired or refreshed since
        // is checked again, and a changed value is substituted afresh.
        if live.approvals.isEmpty == false {
            if let refusal = prepare(token) {
                deny(refusal)
                return
            }
            guard let current = entry(token) else {
                deny(.unknownPlaceholder)
                return
            }
            if current.value != live.value {
                switch substitute() {
                case .failure(let refusal):
                    deny(refusal)
                    return
                case .success(let again):
                    rewritten = again.head
                }
                guard let upstream = GatewayRoute(target: rewritten.target),
                    let fresh = upstream.upstreamURL(base: current.upstream)
                else {
                    deny(.unknownPlaceholder)
                    return
                }
                url = fresh
            }
            live = current
        }
        var headers = rewritten.headers
        if let signing = live.signing {
            switch awsSigned(
                live, binding: signing, method: head.method, url: url, headers: headers, body: body,
                payloadMode: forwarded.header("X-Amz-Content-Sha256"))
            {
            case .failure(let refusal):
                deny(refusal)
                return
            case .success(let signed): headers = signed
            }
        }
        var record = SecretUseRecord(
            secret: live.secret, runtime: live.runtime, upstreamHost: url.host, method: head.method, path: path,
            status: 0, upstreamStatus: nil, activity: .brokered, refusal: nil, reason: nil, surfaces: surfaces,
            fingerprint: live.fingerprint, responseBytes: 0, durationMilliseconds: 0, stage: .forward)
        // Fail closed: a request the audit log cannot hold does not leave.
        guard audit(record) else {
            deny(.auditUnavailable)
            return
        }
        let sink = GatewayResponseWriter(
            fd: client,
            method: head.method,
            // Earlier generations too: an upstream may still echo a value it held before rotation.
            scrub: live.scrubbed.map {
                ($0.bytes, Array(SecretPlaceholder(token: token, prefix: live.prefix).text.utf8))
            },
            // A call that mints credentials answers with a new key the scrubber has never seen.
            tripwires: live.signing?.isS3 == false ? [GatewayResponseWriter.mintedCredentialsField] : []
        )
        // Identity encoding so the scrubber sees the bytes the agent will get.
        headers.append(GatewayHeaders.identityEncoding)
        transport.send(SecretUpstreamRequest(method: head.method, url: url, headers: headers, body: body), sink)
        record.stage = .complete
        record.status = sink.status
        record.upstreamStatus = sink.upstreamStatus
        record.activity = sink.upstreamStatus == nil ? .error : .brokered
        if let refusal = sink.refusal {
            record.activity = .refused
            record.refusal = refusal.code
        }
        record.reason = sink.failure
        record.responseBytes = sink.bytesWritten
        record.durationMilliseconds = Self.milliseconds(since: started)
        _ = audit(record)
    }

    private static func milliseconds(since start: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
    }

    private func readBody(_ reader: GatewaySocket.Reader, head: GatewayRequestHead) -> Data? {
        // The same framing limits apply to HEAD. An illegal or oversized
        // body is refused before the placeholder is treated as empty.
        // Missing `Content-Length` is not a malformed request and must not
        // wait for bytes that will not arrive.
        let framed: Data?
        switch gatewayBodyFraming(
            transferEncodings: head.headerValues("Transfer-Encoding"),
            contentLengths: head.headerValues("Content-Length"),
            maximum: Self.maximumBodyBytes
        ) {
        case .refused:
            return nil
        case .chunked:
            framed = reader.readChunked(limit: Self.maximumBodyBytes)
        case .empty:
            framed = Data()
        case .fixed(let length):
            framed = reader.readExactly(length)
        }
        guard let framed else { return nil }
        if head.method == "HEAD" { return Data() }
        return framed
    }

    /// Loopback is open to every process on the host, so a placeholder alone
    /// is not enough: the connection must come from each named entry's
    /// runtime. Fails closed when that cannot be shown.
    private func verifyPeer(_ client: Int32, _ presented: [Entry]) -> GatewayRefusal? {
        guard let peer = GatewayPeer.of(client) else { return .runtimeUnverified }
        var checked: [ProcessGroupFact] = []
        for entry in presented {
            guard let group = entry.processGroup else { return .runtimeUnverified }
            guard checked.contains(group) == false else { continue }
            checked.append(group)
            switch peers.verify(peer, group) {
            case .member: continue
            case .outsider: return .runtimeMismatch
            case .unverifiable: return .runtimeUnverified
            }
        }
        return nil
    }

    private func refuse(
        _ client: Int32, _ refusal: GatewayRefusal, method: String, path: String, secret: String?,
        runtime: String? = nil, started: DispatchTime
    ) {
        GatewaySocket.writeAll(
            client,
            GatewaySocket.plainResponse(status: refusal.status, reason: refusal.reason, retryAfter: refusal.retryAfter))
        _ = audit(SecretUseRecord(
            secret: secret, runtime: runtime, upstreamHost: nil, method: method, path: path, status: refusal.status,
            upstreamStatus: nil, activity: refusal.isMisuse ? .blocked : .refused, refusal: refusal.code,
            reason: refusal.reason, surfaces: [], fingerprint: nil, responseBytes: 0,
            durationMilliseconds: Self.milliseconds(since: started), stage: .complete
        ))
    }
}

/// Writes one upstream response to the agent: chunked framing, real values
/// replaced by the placeholder in headers and body.
final class GatewayResponseWriter: SecretResponseSink, @unchecked Sendable {
    private let fd: Int32
    private let method: String
    private let lock = NSLock()
    /// Unused copy for header values; `scrubber` carries the body's held-back bytes.
    private let headerScrubber: SecretScrubber
    private var scrubber: SecretScrubber
    private var wroteHead = false
    private var framed = true
    private var closed = false
    /// The field name that marks a response carrying new credentials.
    static let mintedCredentialsField = Array("SecretAccessKey".utf8)
    /// Bytes held back, head first, while a tripwire could still fire before
    /// anything has been sent. Credential responses are far smaller.
    static let holdLimit = 64 * 1024
    private var held: [UInt8]?
    private let watching: Bool
    private(set) var refusal: GatewayRefusal?
    private(set) var status = 502
    /// The upstream's own status, before any rewrite. Nil when none arrived.
    private(set) var upstreamStatus: Int?
    private(set) var bytesWritten = 0
    private(set) var failure: String?

    init(
        fd: Int32, method: String, scrub pairs: [(needle: [UInt8], replacement: [UInt8])], tripwires: [[UInt8]] = []
    ) {
        self.fd = fd
        self.method = method
        let watching = tripwires.isEmpty == false
        self.watching = watching
        scrubber = SecretScrubber(pairs, tripwires: tripwires)
        headerScrubber = SecretScrubber(pairs)
    }

    func head(status: Int, headers: [(name: String, value: String)]) {
        lock.lock()
        defer { lock.unlock() }
        guard wroteHead == false else { return }
        wroteHead = true
        upstreamStatus = status
        // Every forwarded request carries a brokered credential. Passing the
        // 401 and its challenge on would start the agent's own auth flow
        // for a credential only the operator can replace.
        if status == 401 {
            self.status = 502
            failure = "upstream returned 401 for the brokered credential"
            closed = true
            GatewaySocket.writeAll(fd, GatewaySocket.plainResponse(
                status: 502, reason: "the brokered credential was rejected upstream; update it with `rv secrets set`"))
            return
        }
        framed = method != "HEAD" && status != 204 && status != 304 && (status < 100 || status >= 200)
        // Fail closed: a body rv cannot decode is a body it cannot scrub.
        if framed, GatewayHeaders.isIdentityEncoded(headers) == false {
            self.status = 502
            failure = "upstream response is compressed and cannot be scanned for the secret"
            closed = true
            GatewaySocket.writeAll(fd, GatewaySocket.plainResponse(
                status: 502, reason: "upstream response is compressed and cannot be scanned for the secret"))
            return
        }
        self.status = status
        var text = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status).capitalized)\r\n"
        for header in headers where GatewayHeaders.dropOnResponse.contains(header.name.lowercased()) == false {
            var scrubber = headerScrubber
            let value = String(
                decoding: scrubber.process(Array(header.value.utf8)) + scrubber.finish(), as: UTF8.self)
            guard value.contains("\r") == false, value.contains("\n") == false else { continue }
            text += "\(header.name): \(value)\r\n"
        }
        if framed { text += "Transfer-Encoding: chunked\r\n" }
        text += "Connection: close\r\n\r\n"
        if watching { held = [] }
        closed = write(Array(text.utf8)) == false
    }

    func body(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard closed == false, framed else { return closed == false }
        let clean = scrubber.process(Array(data))
        if scrubber.tripped { return trip(sending: clean) }
        return writeChunk(clean)
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard closed == false else { return }
        if wroteHead == false {
            closed = true
            failure = "upstream sent no response"
            GatewaySocket.writeAll(fd, GatewaySocket.plainResponse(status: 502, reason: "upstream sent no response"))
            return
        }
        if framed {
            let rest = scrubber.finish()
            if scrubber.tripped {
                _ = trip(sending: rest)
                return
            }
            _ = writeChunk(rest)
            _ = write(Array("0\r\n\r\n".utf8))
        }
        flushHeld()
        closed = true
    }

    func fail(_ reason: String) {
        lock.lock()
        defer { lock.unlock() }
        if failure == nil { failure = reason }
        guard closed == false else { return }
        closed = true
        flushHeld()
        if wroteHead == false {
            status = 502
            GatewaySocket.writeAll(fd, GatewaySocket.plainResponse(status: 502, reason: "upstream failed: \(reason)"))
        }
    }

    private static func chunk(_ bytes: [UInt8]) -> [UInt8] {
        bytes.isEmpty ? [] : Array(String(bytes.count, radix: 16).utf8) + [13, 10] + bytes + [13, 10]
    }

    private func writeChunk(_ bytes: [UInt8]) -> Bool {
        guard bytes.isEmpty == false else { return true }
        bytesWritten += bytes.count
        let frame = Self.chunk(bytes)
        if write(frame) == false { closed = true }
        return closed == false
    }

    /// Sends, or while a tripwire could still fire before anything has left,
    /// holds the bytes; past `holdLimit` the hold is released.
    private func write(_ bytes: [UInt8]) -> Bool {
        guard held != nil else { return GatewaySocket.writeAll(fd, bytes) }
        held?.append(contentsOf: bytes)
        guard (held?.count ?? 0) > Self.holdLimit else { return true }
        return flushHeld()
    }

    @discardableResult
    private func flushHeld() -> Bool {
        guard let bytes = held else { return true }
        held = nil
        return GatewaySocket.writeAll(fd, bytes)
    }

    /// A tripwire matched. While nothing has been sent the agent gets a plain
    /// 502 in place of the response; after that the stream is cut short at
    /// the field name, before the value.
    private func trip(sending clean: [UInt8]) -> Bool {
        let refused = GatewayRefusal.awsCredentialsInResponse
        refusal = refused
        failure = refused.reason
        closed = true
        if held != nil {
            held = nil
            status = refused.status
            GatewaySocket.writeAll(fd, GatewaySocket.plainResponse(status: refused.status, reason: refused.reason))
        } else if framed {
            bytesWritten += clean.count
            _ = GatewaySocket.writeAll(fd, Self.chunk(clean))
        }
        return false
    }
}

enum GatewaySocket {
    #if canImport(Darwin)
    static let sendFlags: Int32 = 0
    #else
    static let sendFlags = Int32(MSG_NOSIGNAL)
    #endif

    @discardableResult
    static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var written = 0
        while written < bytes.count {
            let n = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return send(fd, base + written, raw.count - written, sendFlags)
            }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return false }
            written += n
        }
        return true
    }

    static func plainResponse(status: Int, reason: String, retryAfter: Int? = nil) -> [UInt8] {
        let body = "rv secret gateway: \(reason)\n"
        let phrase = HTTPURLResponse.localizedString(forStatusCode: status).capitalized
        let retry = retryAfter.map { "Retry-After: \($0)\r\n" } ?? ""
        return Array(
            ("HTTP/1.1 \(status) \(phrase)\r\nContent-Type: text/plain; charset=utf-8\r\n" + retry
                + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body).utf8)
    }

    final class Reader {
        private let fd: Int32
        private var buffer: [UInt8] = []

        init(fd: Int32) {
            self.fd = fd
        }

        private func fill() -> Bool {
            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if n < 0, errno == EINTR { continue }
                if n < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    // A not-yet-arrived HEAD is not the end of the request.
                    var state = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    let waited = poll(&state, 1, 30_000)
                    if waited < 0, errno == EINTR { continue }
                    if waited > 0 { continue }
                    return false
                }
                guard n > 0 else { return false }
                buffer += chunk.prefix(n)
                return true
            }
        }

        func readHead(limit: Int) -> [UInt8]? {
            let terminator: [UInt8] = [13, 10, 13, 10]
            var searchFrom = 0
            while true {
                if buffer.count >= 4 {
                    var index = max(0, searchFrom - 3)
                    while index <= buffer.count - 4 {
                        if buffer[index] == 13, Array(buffer[index..<index + 4]) == terminator {
                            let head = Array(buffer[..<index])
                            buffer.removeFirst(index + 4)
                            return head
                        }
                        index += 1
                    }
                    searchFrom = buffer.count
                }
                guard buffer.count <= limit, fill() else { return nil }
            }
        }

        func readExactly(_ count: Int) -> Data? {
            while buffer.count < count {
                guard fill() else { return nil }
            }
            let data = Data(buffer[..<count])
            buffer.removeFirst(count)
            return data
        }

        func readLine(limit: Int = 4_096) -> String? {
            while true {
                if let index = buffer.firstIndex(of: 10), index > 0, buffer[index - 1] == 13 {
                    let line = String(decoding: buffer[..<(index - 1)], as: UTF8.self)
                    buffer.removeFirst(index + 1)
                    return line
                }
                guard buffer.count <= limit, fill() else { return nil }
            }
        }

        func readChunked(limit: Int) -> Data? {
            var body = Data()
            while true {
                guard let line = readLine() else { return nil }
                let sizeText = line.split(separator: ";").first.map(String.init) ?? ""
                guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else {
                    return nil
                }
                if size == 0 {
                    while let trailer = readLine() {
                        if trailer.isEmpty { return body }
                    }
                    return nil
                }
                // `body.count + size` traps when size is Int.max. Reject first.
                guard size <= limit else { return nil }
                guard body.count <= limit - size else { return nil }
                guard let chunk = readExactly(size), readExactly(2) == Data([13, 10]) else { return nil }
                body.append(chunk)
            }
        }
    }
}

/// URLSession upstream with streaming delivery, no cookies, cache, or redirects.
final class URLSessionStreamingTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var sinks: [Int: (sink: SecretResponseSink, done: DispatchSemaphore)] = [:]
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 3_600
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }()

    func send(_ request: SecretUpstreamRequest, sink: SecretResponseSink) {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        for header in request.headers {
            urlRequest.addValue(header.value, forHTTPHeaderField: header.name)
        }
        if request.body.isEmpty == false || ["POST", "PUT", "PATCH"].contains(request.method) {
            urlRequest.httpBody = request.body
        }
        let done = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: urlRequest)
        lock.lock()
        sinks[task.taskIdentifier] = (sink, done)
        lock.unlock()
        task.resume()
        done.wait()
    }

    private func sink(for task: URLSessionTask) -> SecretResponseSink? {
        lock.lock()
        defer { lock.unlock() }
        return sinks[task.taskIdentifier]?.sink
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse, let sink = sink(for: dataTask) else {
            completionHandler(.cancel)
            return
        }
        let headers = http.allHeaderFields.compactMap { key, value -> (name: String, value: String)? in
            guard let name = key as? String, let text = value as? String else { return nil }
            return (name, text)
        }
        sink.head(status: http.statusCode, headers: headers)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let sink = sink(for: dataTask) else { return }
        if sink.body(data) == false { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let entry = sinks.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let entry else { return }
        if let error {
            entry.sink.fail(error.localizedDescription)
        } else {
            entry.sink.finish()
        }
        entry.done.signal()
    }
}
