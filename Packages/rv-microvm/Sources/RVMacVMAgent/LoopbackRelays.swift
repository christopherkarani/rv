import Darwin
import Foundation
import RVMicroVMCore
import Synchronization

/// Guest `127.0.0.1:P` listeners, each connection bridged to the host
/// through `connect(P)` (vsock to the host in a guest). The guest has no
/// network interface, so these are its only way out.
final class LoopbackRelays: Sendable {
    private let stopped = Atomic<Bool>(false)
    private let budget = BridgeBudget()
    private let finished = DispatchGroup()

    private init() {}

    static func start(ports: [Int], connect: @escaping @Sendable (Int) -> Int32?) -> Result<LoopbackRelays, AgentError> {
        var listeners: [Int32] = []
        for port in ports {
            switch listen(port: port) {
            case .failure(let error):
                listeners.forEach { close($0) }
                return .failure(error)
            case .success(let fd):
                listeners.append(fd)
            }
        }
        let relays = LoopbackRelays()
        for (fd, port) in zip(listeners, ports) {
            relays.finished.enter()
            Thread.detachNewThread { [relays] in
                relays.acceptLoop(listener: fd, port: port, connect: connect)
                relays.finished.leave()
            }
        }
        return .success(relays)
    }

    /// Stops accepting and waits for the listeners to close. Bridges already
    /// running end with their connections.
    func stop() {
        stopped.store(true, ordering: .releasing)
        finished.wait()
    }

    private func acceptLoop(listener: Int32, port: Int, connect: @escaping @Sendable (Int) -> Int32?) {
        defer { close(listener) }
        while stopped.load(ordering: .acquiring) == false {
            var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 100) > 0 else { continue }
            let client = accept(listener, nil, nil)
            guard client >= 0 else { continue }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            guard budget.tryAcquire() else {
                close(client)
                continue
            }
            Thread.detachNewThread { [budget] in
                if let upstream = connect(port) {
                    _ = fcntl(upstream, F_SETFD, FD_CLOEXEC)
                    SocketBridge.run(client, upstream)
                } else {
                    close(client)
                }
                budget.release()
            }
        }
    }

    private static func listen(port: Int) -> Result<Int32, AgentError> {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(AgentError("cannot create relay socket: \(String(cString: strerror(errno)))")) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 64) == 0 else {
            let message = "cannot listen on guest 127.0.0.1:\(port): \(String(cString: strerror(errno)))"
            close(fd)
            return .failure(AgentError(message))
        }
        return .success(fd)
    }
}
