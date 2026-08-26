#if os(Linux)
#if canImport(Glibc)
import Glibc
#endif
import Foundation
import RVIPC

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
        let length = header.withUnsafeBytes { raw in
            raw.loadUnaligned(as: UInt32.self).bigEndian
        }
        let body = try recvExact(fd: fd, count: Int(length))
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
public final class UnixEvaluateListener: @unchecked Sendable {
    private let runtime: ServiceRuntime
    private let watchdog: IdleWatchdog
    public let socketURL: URL
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "rv.unix-evaluate")

    public init(runtime: ServiceRuntime, watchdog: IdleWatchdog, socketURL: URL) {
        self.runtime = runtime
        self.watchdog = watchdog
        self.socketURL = socketURL
    }

    public func start() throws {
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
            try UnixSocketPath.assertSocketMode(socketURL)
        } catch {
            _ = Glibc.close(fd)
            throw error
        }
        guard Glibc.listen(fd, 8) == 0 else {
            _ = Glibc.close(fd)
            throw UnixFrameError.listen
        }
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptOne()
        }
        source.setCancelHandler {
            _ = Glibc.close(fd)
        }
        self.source = source
        source.resume()
    }

    public func stop() {
        source?.cancel()
        source = nil
        listenFD = -1
        try? FileManager.default.removeItem(at: socketURL)
    }

    private func acceptOne() {
        let client = Glibc.accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        queue.async { self.serve(client) }
    }

    private func serve(_ fd: Int32) {
        var handshakeOK = false
        defer { _ = Glibc.close(fd) }
        while true {
            guard let body = try? UnixFrameIO.readFrame(fd: fd) else { return }
            let gate = UnixReplyGate()
            let runtime = self.runtime
            let watchdog = self.watchdog
            let accepted = handshakeOK
            Task {
                await watchdog.ping()
                let pair = await runtime.handleIncoming(body, handshakeOK: accepted)
                gate.finish(pair)
            }
            let pair = gate.wait()
            handshakeOK = pair.1
            try? UnixFrameIO.writeFrame(fd: fd, body: pair.0)
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

final class UnixReplyGate: @unchecked Sendable {
    private let sem = DispatchSemaphore(value: 0)
    private var pair: (Data, Bool) = (Data(), false)

    func finish(_ pair: (Data, Bool)) {
        self.pair = pair
        sem.signal()
    }

    func wait() -> (Data, Bool) {
        sem.wait()
        return pair
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
