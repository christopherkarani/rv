#if os(Linux)
#if canImport(Glibc)
import Glibc
#endif
import Foundation
import RVIPC
import RVIsolation
import Synchronization

enum UnixFrameError: Error, Sendable, Equatable {
    case socket
    case bind
    case listen
    case connect
    case eof
    case pathTooLong
}

/// Linux AF_UNIX frames. Pathname sockets only. `send` uses `MSG_NOSIGNAL`.
enum UnixFrameIO {
    static func openStream() throws -> Int32 {
        let flags = Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue)
        let fd = Glibc.socket(AF_UNIX, flags, 0)
        guard fd >= 0 else { throw UnixFrameError.socket }
        return fd
    }

    static func writeFrame(fd: Int32, body: Data) throws {
        try sendAll(fd: fd, data: try ServiceFrames.encode(body: body))
    }

    static func readFrame(fd: Int32) throws -> Data {
        let header = try recvExact(fd: fd, count: 4)
        let length = try FrameCodec.bodyCount(fromHeader: header)
        let body = try recvExact(fd: fd, count: length)
        return try FrameCodec.decode(header: header, body: body)
    }

    static func recvExact(fd: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let n = data.withUnsafeMutableBytes { buf -> Int in
                guard let base = buf.baseAddress else { return -1 }
                return Glibc.recv(fd, base + offset, count - offset, 0)
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw UnixFrameError.eof
            }
            if n == 0 { throw UnixFrameError.eof }
            offset += n
        }
        return data
    }

    static func sendAll(fd: Int32, data: Data) throws {
        var offset = 0
        try data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { throw UnixFrameError.eof }
            while offset < data.count {
                let n = Glibc.send(fd, base + offset, data.count - offset, Int32(MSG_NOSIGNAL))
                if n < 0 {
                    if errno == EINTR { continue }
                    throw UnixFrameError.eof
                }
                if n == 0 { throw UnixFrameError.eof }
                offset += n
            }
        }
    }

    static func sockaddr(path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count + 1 <= maxPath else {
            throw UnixFrameError.pathTooLong
        }
        path.withCString { cString in
            withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
                let dest = UnsafeMutableRawPointer(sunPath).assumingMemoryBound(to: CChar.self)
                _ = Glibc.strncpy(dest, cString, maxPath - 1)
            }
        }
        return addr
    }
}

/// AF_UNIX listener for Linux `rvd --socket`. Same `FrameCodec` algebra as tests.
public final class UnixEvaluateListener: Sendable {
    private let runtime: ServiceRuntime
    private let watchdog: IdleWatchdog
    public let socketURL: URL
    private let limits: UnixConnectionLimits
    private let slots: UnixConnectionSlots
    private let state = Mutex<ListenerState>(ListenerState())
    private let queue = DispatchQueue(label: "rv.unix-evaluate")

    private struct ListenerState {
        var listenFD: Int32 = -1
        var source: ReadSource?
        /// True once `start` bound and is listening. `stop` unlinks the
        /// socket file only then: a never-started listener must not remove a
        /// path it does not own.
        var ownsSocket: Bool = false
        /// True once `startAccepting` resumed the accept source.
        var accepting: Bool = false
    }

    /// Dispatch sources are thread-safe handles. Only the listener touches
    /// the source, and only under `state`, so sharing it there is sound.
    private struct ReadSource: @unchecked Sendable {
        let source: DispatchSourceRead
    }

    public init(
        runtime: ServiceRuntime,
        watchdog: IdleWatchdog,
        socketURL: URL,
        limits: UnixConnectionLimits = .standard
    ) {
        self.runtime = runtime
        self.watchdog = watchdog
        self.socketURL = socketURL
        self.limits = limits
        self.slots = UnixConnectionSlots(limit: limits.maxConnections)
    }

    /// `bind` then `startAccepting`.
    public func start() throws {
        try bind()
        startAccepting()
    }

    /// Binds and listens without accepting. rvd does this before its
    /// startup backoff wait: a client meanwhile connects into the backlog
    /// and waits for a reply, which hooks read as a slow rvd (TIMEOUT,
    /// ask/deny), never as an absent one (ENOENT/ECONNREFUSED, the only
    /// failure observe mode steps aside for).
    public func bind() throws {
        try UnixSocketPath.prepareRuntime(for: socketURL)
        let fd = try UnixFrameIO.openStream()
        var addr = try UnixFrameIO.sockaddr(path: socketURL.path)
        let bindOK = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Glibc.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindOK == 0 else {
            _ = Glibc.close(fd)
            throw UnixFrameError.bind
        }
        do {
            try UnixSocketPath.applyOwnerOnlySocketMode(to: socketURL)
        } catch {
            _ = Glibc.close(fd)
            throw error
        }
        guard Glibc.listen(fd, 8) == 0 else {
            _ = Glibc.close(fd)
            throw UnixFrameError.listen
        }
        state.withLock { $0.listenFD = fd }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptOne()
        }
        source.setCancelHandler {
            _ = Glibc.close(fd)
        }
        let held = ReadSource(source: source)
        state.withLock {
            $0.source = held
            $0.ownsSocket = true
        }
    }

    /// Starts serving the connections `bind` queued and every later one.
    /// No-op before `bind` or after the first call.
    public func startAccepting() {
        let source = state.withLock { state -> ReadSource? in
            guard state.accepting == false, let source = state.source else { return nil }
            state.accepting = true
            return source
        }
        source?.source.resume()
    }

    /// Accepts and closes every connection that queued while bound but not
    /// accepting (rvd's backoff wait). Those hooks have likely given up;
    /// one still waiting reads EOF or a reset, which hooks treat as a
    /// connection failure (ask/deny), never as an absent rvd. A request
    /// nobody waits for is never evaluated. No-op once accepting. Bounded,
    /// so a stream of new clients cannot hold rvd here.
    public func dropQueued() {
        let fd = state.withLock { $0.accepting ? -1 : $0.listenFD }
        guard fd >= 0 else { return }
        let flags = Glibc.fcntl(fd, F_GETFL)
        guard flags >= 0, Glibc.fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return }
        defer { _ = Glibc.fcntl(fd, F_SETFL, flags) }
        var dropped = 0
        while dropped < 64 {
            let client = Glibc.accept(fd, nil, nil)
            if client >= 0 {
                Glibc.close(client)
                dropped += 1
            } else if errno != EINTR {
                return
            }
        }
    }

    public func stop() {
        let held = state.withLock { state -> (ReadSource?, Bool, Bool) in
            let current = state.source
            let owned = state.ownsSocket
            let accepting = state.accepting
            state.source = nil
            state.listenFD = -1
            state.ownsSocket = false
            state.accepting = false
            return (current, owned, accepting)
        }
        held.0?.source.cancel()
        // A source created by `bind` stays suspended until `startAccepting`;
        // resuming it after cancel runs the cancel handler (which closes the
        // descriptor) and never delivers an accept.
        if held.2 == false { held.0?.source.resume() }
        guard held.1 else { return }
        UnixSocketPath.removeSocketFileIfSocket(at: socketURL)
    }

    private func acceptOne() {
        let listenFD = state.withLock { $0.listenFD }
        let client = Glibc.accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        guard limits.applyReceiveTimeout(to: client), slots.acquire() else {
            _ = Glibc.close(client)
            return
        }
        // Each connection gets its own thread, never a dispatch worker:
        // `serve` blocks in `recv` for the life of the connection and blocks
        // again on each request's evaluation `Task`. On Linux, dispatch
        // workers and the Swift concurrency pool share libdispatch's small
        // root-queue pool and it does not add threads for blocked ones, so a
        // cold burst parked every worker on a reply gate with none left to
        // run the evaluations: every hook timed out. `slots` caps the count.
        let thread = Thread { [self] in
            defer { slots.release() }
            serve(client)
        }
        thread.name = "rv.unix-evaluate-connection"
        thread.start()
    }

    private func serve(_ fd: Int32) {
        var handshakeOK = false
        defer { _ = Glibc.close(fd) }
        // Kernel-attested peer credentials, captured once per connection
        // (SO_PEERCRED is fixed at connect time). Same-user socket peers get
        // a role-less context so hook consult works; anything else — capture
        // failure, cross-user peer — stays unauthenticated and fails closed.
        let connectionID = UUID()
        let context: AuthenticatedRequestContext
        if let creds = try? LinuxSocketPeerCapture.capture(fd: fd) {
            let peer = AuthenticatedPeer.socketPeer(
                processID: creds.processID, effectiveUserID: creds.effectiveUserID,
                connectionID: connectionID)
            context = .captured(peer: peer, connectionID: connectionID)
        } else {
            context = .unauthenticated
        }
        while true {
            guard let body = try? UnixFrameIO.readFrame(fd: fd) else { return }
            let receivedAt = ContinuousClock.now
            // Refused once rvd decided to exit: closing the connection sends
            // the client to the relaunched daemon.
            guard watchdog.beginRequest() else { return }
            let gate = UnixReplyGate()
            let runtime = self.runtime
            let accepted = handshakeOK
            Task {
                let incoming = await runtime.handleIncoming(
                    body, handshakeOK: accepted, context: context,
                    sameUIDSocket: context.peer != nil, receivedAt: receivedAt)
                gate.finish(incoming)
            }
            let incoming = gate.wait()
            handshakeOK = incoming.handshakeAccepted
            try? UnixFrameIO.writeFrame(fd: fd, body: incoming.frame)
            watchdog.endRequest()
        }
    }
}

final class UnixEvaluateClient {
    let path: String
    private var fd: Int32 = -1

    init(path: String) {
        self.path = path
    }

    func connect() throws {
        let sock = try UnixFrameIO.openStream()
        var addr = try UnixFrameIO.sockaddr(path: path)
        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Glibc.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else {
            _ = Glibc.close(sock)
            throw UnixFrameError.connect
        }
        fd = sock
    }

    func send(body: Data) throws -> Data {
        try UnixFrameIO.writeFrame(fd: fd, body: body)
        return try UnixFrameIO.readFrame(fd: fd)
    }

    func close() {
        if fd >= 0 {
            Glibc.close(fd)
            fd = -1
        }
    }
}

final class UnixReplyGate: Sendable {
    private let sem = DispatchSemaphore(value: 0)
    private let box = Mutex<IncomingReply?>(nil)

    func finish(_ reply: IncomingReply) {
        box.withLock { $0 = reply }
        sem.signal()
    }

    func wait() -> IncomingReply {
        sem.wait()
        return box.withLock { $0 } ?? IncomingReply(frame: Data(), handshakeAccepted: false)
    }
}

func retryUnixConnect(path: String, attempts: Int = 40) throws -> UnixEvaluateClient {
    var last: Error = UnixFrameError.connect
    for _ in 0..<attempts {
        let client = UnixEvaluateClient(path: path)
        do {
            try client.connect()
            return client
        } catch {
            last = error
            Glibc.usleep(50_000)
        }
    }
    throw last
}
#endif
