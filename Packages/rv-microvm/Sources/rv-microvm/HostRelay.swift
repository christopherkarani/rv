import Darwin
import Foundation
import RVMicroVMCore
import Synchronization

/// Host half of the loopback relays: one unix listener per relayed port,
/// each accepted connection bridged to host `127.0.0.1:<port>`.
/// Containerization connects to these sockets for every guest connection.
final class HostRelay: Sendable {
    private let listeners: [Int32]
    private let paths: [String]
    private let stopped = Atomic<Bool>(false)
    private let budget = BridgeBudget()

    private init(listeners: [Int32], paths: [String]) {
        self.listeners = listeners
        self.paths = paths
    }

    /// Binds every listener before returning. On failure nothing is left bound.
    static func start(_ plan: RelayPlan) -> Result<HostRelay, RelayError> {
        var listeners: [Int32] = []
        var paths: [String] = []
        for entry in plan.entries {
            switch bindListener(path: entry.hostSocket) {
            case .failure(let error):
                listeners.forEach { close($0) }
                paths.forEach { unlink($0) }
                return .failure(error)
            case .success(let fd):
                listeners.append(fd)
                paths.append(entry.hostSocket)
            }
        }
        let relay = HostRelay(listeners: listeners, paths: paths)
        for (fd, entry) in zip(listeners, plan.entries) {
            let port = entry.port
            Thread.detachNewThread { [relay] in relay.acceptLoop(listener: fd, port: port) }
        }
        return .success(relay)
    }

    func stop() {
        guard stopped.exchange(true, ordering: .acquiringAndReleasing) == false else { return }
        paths.forEach { unlink($0) }
    }

    private func acceptLoop(listener: Int32, port: Int) {
        defer { close(listener) }
        while stopped.load(ordering: .acquiring) == false {
            var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 250)
            if ready <= 0 { continue }
            let client = accept(listener, nil, nil)
            if client < 0 { continue }
            // Over budget: refuse this connection; the guest sees a reset.
            guard budget.tryAcquire() else {
                close(client)
                continue
            }
            Thread.detachNewThread { [budget] in
                Self.bridge(client: client, port: port)
                budget.release()
            }
        }
    }

    private static func bridge(client: Int32, port: Int) {
        guard let upstream = connectLoopback(port: port) else {
            close(client)
            return
        }
        let group = DispatchGroup()
        group.enter()
        Thread.detachNewThread {
            copy(from: client, to: upstream)
            group.leave()
        }
        copy(from: upstream, to: client)
        group.wait()
        close(client)
        close(upstream)
    }

    /// One direction, blocking. EOF half-closes the peer; the other
    /// direction keeps flowing on its own thread.
    private static func copy(from source: Int32, to destination: Int32) {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        outer: while true {
            let count = buffer.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            if count <= 0 { break }
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes { write(destination, $0.baseAddress! + offset, count - offset) }
                if written < 0, errno == EINTR { continue }
                if written <= 0 { break outer }
                offset += written
            }
        }
        shutdown(destination, SHUT_WR)
    }

    private static func connectLoopback(port: Int) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    private static func bindListener(path: String) -> Result<Int32, RelayError> {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(.socket(errno)) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else {
            close(fd)
            return .failure(.pathTooLong(path))
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: path.utf8)
            raw[path.utf8.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 64) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            return .failure(.bind(path, code))
        }
        return .success(fd)
    }
}

enum RelayError: Error, CustomStringConvertible {
    case socket(Int32)
    case pathTooLong(String)
    case bind(String, Int32)

    var description: String {
        switch self {
        case .socket(let code): "cannot create relay socket: \(String(cString: strerror(code)))"
        case .pathTooLong(let path): "relay socket path is too long: \(path)"
        case .bind(let path, let code): "cannot listen on \(path): \(String(cString: strerror(code)))"
        }
    }
}
