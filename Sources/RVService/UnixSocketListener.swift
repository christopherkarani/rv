#if canImport(Darwin)
import Darwin
import Foundation
import RVIPC
import Synchronization

enum DarwinFrameError: Error, Sendable, Equatable {
    case socket
    case bind
    case listen
    case connect
    case eof
    case pathTooLong
}

/// Darwin AF_UNIX frames. Same algebra as Linux `UnixFrameIO`: pathname
/// sockets only, `FD_CLOEXEC`, `SO_NOSIGPIPE`, `EINTR`-retrying exact reads.
enum DarwinFrameIO {
    static func openStream() throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DarwinFrameError.socket }
        guard Darwin.fcntl(fd, F_SETFD, FD_CLOEXEC) >= 0 else {
            Darwin.close(fd)
            throw DarwinFrameError.socket
        }
        ignorePipe(fd)
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
                return Darwin.recv(fd, base + offset, count - offset, 0)
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw DarwinFrameError.eof
            }
            if n == 0 { throw DarwinFrameError.eof }
            offset += n
        }
        return data
    }

    static func sendAll(fd: Int32, data: Data) throws {
        var offset = 0
        try data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { throw DarwinFrameError.eof }
            while offset < data.count {
                let n = Darwin.send(fd, base + offset, data.count - offset, 0)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw DarwinFrameError.eof
                }
                if n == 0 { throw DarwinFrameError.eof }
                offset += n
            }
        }
    }

    static func sockaddr(path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count + 1 <= maxPath else {
            throw DarwinFrameError.pathTooLong
        }
        path.withCString { cString in
            withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
                let dest = UnsafeMutableRawPointer(sunPath).assumingMemoryBound(to: CChar.self)
                _ = Darwin.strncpy(dest, cString, maxPath - 1)
            }
        }
        return addr
    }

    /// Same-UID peer check. Anything else is dropped before any byte is read.
    static func peerUID(fd: Int32) -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard Darwin.getpeereid(fd, &uid, &gid) == 0 else { return nil }
        return uid
    }

    static func ignorePipe(_ fd: Int32) {
        var one: Int32 = 1
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }
}

/// AF_UNIX listener for macOS `rvd`. Serves `sdk/WIRE.md` over the socket from
/// `UnixSocketPath.production()` through the same `ServiceRuntime` seam as XPC.
public final class UnixSocketListener: Sendable {
    private let runtime: ServiceRuntime
    private let watchdog: IdleWatchdog
    public let socketURL: URL
    private let state = Mutex<ListenerState>(ListenerState())
    private let queue = DispatchQueue(label: "rv.unix-socket")

    private struct ListenerState {
        var listenFD: Int32 = -1
        var source: ReadSource?
    }

    /// Dispatch sources are thread-safe handles. Only the listener touches
    /// the source, and only under `state`, so sharing it there is sound.
    private struct ReadSource: @unchecked Sendable {
        let source: DispatchSourceRead
    }

    public init(runtime: ServiceRuntime, watchdog: IdleWatchdog, socketURL: URL) {
        self.runtime = runtime
        self.watchdog = watchdog
        self.socketURL = socketURL
    }

    public func start() throws {
        try UnixSocketPath.prepareRuntime(for: socketURL)
        let fd = try DarwinFrameIO.openStream()
        var addr = try DarwinFrameIO.sockaddr(path: socketURL.path)
        let bindOK = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindOK == 0 else {
            Darwin.close(fd)
            throw DarwinFrameError.bind
        }
        do {
            try UnixSocketPath.applyOwnerOnlySocketMode(to: socketURL)
        } catch {
            Darwin.close(fd)
            throw error
        }
        guard Darwin.listen(fd, 8) == 0 else {
            Darwin.close(fd)
            throw DarwinFrameError.listen
        }
        state.withLock { $0.listenFD = fd }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptOne()
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        source.resume()
        let held = ReadSource(source: source)
        state.withLock { $0.source = held }
    }

    public func stop() {
        let held = state.withLock { state -> ReadSource? in
            let current = state.source
            state.source = nil
            state.listenFD = -1
            return current
        }
        held?.source.cancel()
        try? FileManager.default.removeItem(at: socketURL)
    }

    private func acceptOne() {
        let listenFD = state.withLock { $0.listenFD }
        let client = Darwin.accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        guard DarwinFrameIO.peerUID(fd: client) == Darwin.getuid() else {
            Darwin.close(client)
            return
        }
        DarwinFrameIO.ignorePipe(client)
        queue.async { self.serve(client) }
    }

    private func serve(_ fd: Int32) {
        var handshakeOK = false
        defer { Darwin.close(fd) }
        while true {
            guard let body = try? DarwinFrameIO.readFrame(fd: fd) else { return }
            let gate = DarwinReplyGate()
            let runtime = self.runtime
            let watchdog = self.watchdog
            let accepted = handshakeOK
            Task {
                await watchdog.ping()
                let incoming = await runtime.handleIncoming(body, handshakeOK: accepted)
                gate.finish(incoming)
            }
            let incoming = gate.wait()
            handshakeOK = incoming.handshakeAccepted
            try? DarwinFrameIO.writeFrame(fd: fd, body: incoming.frame)
        }
    }
}

final class DarwinEvaluateClient {
    let path: String
    private var fd: Int32 = -1

    init(path: String) {
        self.path = path
    }

    func connect() throws {
        let sock = try DarwinFrameIO.openStream()
        var addr = try DarwinFrameIO.sockaddr(path: path)
        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else {
            Darwin.close(sock)
            throw DarwinFrameError.connect
        }
        fd = sock
    }

    func send(body: Data) throws -> Data {
        try DarwinFrameIO.writeFrame(fd: fd, body: body)
        return try DarwinFrameIO.readFrame(fd: fd)
    }

    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }
}

final class DarwinReplyGate: Sendable {
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

func retryDarwinConnect(path: String, attempts: Int = 40) throws -> DarwinEvaluateClient {
    var last: Error = DarwinFrameError.connect
    for _ in 0..<attempts {
        let client = DarwinEvaluateClient(path: path)
        do {
            try client.connect()
            return client
        } catch {
            last = error
            Darwin.usleep(50_000)
        }
    }
    throw last
}
#endif
