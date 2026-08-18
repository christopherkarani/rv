import Darwin
import Foundation
import RVService

enum UnixFrameError: Error {
    case socket
    case bind
    case listen
    case connect
    case eof
    case pathTooLong
}

enum UnixFrameIO {
    static func writeFrame(fd: Int32, body: Data) throws {
        try writeAll(fd: fd, data: try ServiceFrames.encode(body: body))
    }

    static func readFrame(fd: Int32) throws -> Data {
        let header = try readExact(fd: fd, count: 4)
        var frame = header
        let length = header.withUnsafeBytes { raw in
            raw.loadUnaligned(as: UInt32.self).bigEndian
        }
        let body = try readExact(fd: fd, count: Int(length))
        frame.append(body)
        return try ServiceFrames.decode(frame)
    }

    static func readExact(fd: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let n = data.withUnsafeMutableBytes { buf -> Int in
                guard let base = buf.baseAddress else { return -1 }
                return Darwin.read(fd, base + offset, count - offset)
            }
            if n <= 0 { throw UnixFrameError.eof }
            offset += n
        }
        return data
    }

    static func writeAll(fd: Int32, data: Data) throws {
        var offset = 0
        try data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { throw UnixFrameError.eof }
            while offset < data.count {
                let n = Darwin.write(fd, base + offset, data.count - offset)
                if n <= 0 { throw UnixFrameError.eof }
                offset += n
            }
        }
    }

    static func sockaddr(path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.stride)
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count + 1 <= maxPath else {
            throw UnixFrameError.pathTooLong
        }
        path.withCString { cString in
            withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
                let dest = UnsafeMutableRawPointer(sunPath).assumingMemoryBound(to: CChar.self)
                _ = strncpy(dest, cString, maxPath - 1)
            }
        }
        return addr
    }
}

final class FakeXPCServer: @unchecked Sendable {
    let path: String
    let runtime: ServiceRuntime
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "rv.fake-xpc")

    init(runtime: ServiceRuntime, path: String) {
        self.runtime = runtime
        self.path = path
    }

    func start() throws {
        unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixFrameError.socket }
        var nosig = Int32(1)
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
        var addr = try UnixFrameIO.sockaddr(path: path)
        let bindOK = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.stride))
            }
        }
        guard bindOK == 0 else {
            Darwin.close(fd)
            throw UnixFrameError.bind
        }
        guard Darwin.listen(fd, 8) == 0 else {
            Darwin.close(fd)
            throw UnixFrameError.listen
        }
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptOne()
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        self.source = source
        source.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
        listenFD = -1
        unlink(path)
    }

    private func acceptOne() {
        let client = Darwin.accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        queue.async { self.serve(client) }
    }

    private func serve(_ fd: Int32) {
        var handshakeOK = false
        defer { Darwin.close(fd) }
        while true {
            guard let body = try? UnixFrameIO.readFrame(fd: fd) else { return }
            let gate = ReplyGate()
            let runtime = self.runtime
            let accepted = handshakeOK
            Task {
                let pair = await runtime.handleIncoming(body, handshakeOK: accepted)
                gate.finish(pair)
            }
            let pair = gate.wait()
            handshakeOK = pair.1
            try? UnixFrameIO.writeFrame(fd: fd, body: pair.0)
        }
    }
}

final class FakeXPCClient {
    let path: String
    private var fd: Int32 = -1

    init(path: String) {
        self.path = path
    }

    func connect() throws {
        let sock = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { throw UnixFrameError.socket }
        var addr = try UnixFrameIO.sockaddr(path: path)
        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.stride))
            }
        }
        guard ok == 0 else {
            Darwin.close(sock)
            throw UnixFrameError.connect
        }
        fd = sock
    }

    func hello() throws -> [String: Any] {
        let body = Data(#"{"protocol":"rv.ipc.v1","clientSemver":"1.0.0"}"#.utf8)
        try UnixFrameIO.writeFrame(fd: fd, body: body)
        let reply = try UnixFrameIO.readFrame(fd: fd)
        return try JSONSerialization.jsonObject(with: reply) as? [String: Any] ?? [:]
    }

    func sendJSON(_ object: [String: Any]) throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: object)
        try UnixFrameIO.writeFrame(fd: fd, body: body)
        let reply = try UnixFrameIO.readFrame(fd: fd)
        return try JSONSerialization.jsonObject(with: reply) as? [String: Any] ?? [:]
    }

    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }
}

final class ReplyGate: @unchecked Sendable {
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

func retryConnect(path: String, attempts: Int = 40) throws -> FakeXPCClient {
    var last: Error = UnixFrameError.connect
    for _ in 0..<attempts {
        let client = FakeXPCClient(path: path)
        do {
            try client.connect()
            return client
        } catch {
            last = error
            usleep(50_000)
        }
    }
    throw last
}
