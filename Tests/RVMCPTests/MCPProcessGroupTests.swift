#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVIsolation
import Synchronization
import Testing
@testable import RVMCP

/// Prints the descriptors it has open, by number: what it lists in
/// `/proc/self/fd` (or `/dev/fd`) and can still `fstat` once the listing's
/// own descriptor is closed.
private let descriptorLister = #"""
    import os
    d = "/proc/self/fd" if os.path.isdir("/proc/self/fd") else "/dev/fd"
    seen = []
    for fd in [int(n) for n in os.listdir(d)]:
        try:
            os.fstat(fd)
        except OSError:
            continue
        seen.append(fd)
    print(" ".join(str(fd) for fd in sorted(seen)), flush=True)
    """#

/// Opens and closes descriptors without close-on-exec, one after the
/// other, so one opened a moment ago is always open, until `stop`.
private final class DescriptorChurn: Sendable {
    private let stopping = Atomic(false)
    private let done = DispatchSemaphore(value: 0)

    init() {
        Thread.detachNewThread { [self] in
            var held: Int32 = -1
            while stopping.load(ordering: .relaxed) == false {
                let fd = open("/dev/null", O_RDONLY)
                if held >= 0 { close(held) }
                held = fd
            }
            if held >= 0 { close(held) }
            done.signal()
        }
    }

    func stop() {
        stopping.store(true, ordering: .relaxed)
        done.wait()
    }
}

@Suite("MCPProcessGroup", .serialized)
struct MCPProcessGroupTests {
    /// What a server started by `MCPProcessGroup.spawn` has open: its
    /// output, or why there is none. Bounded: gives up after 30 s.
    static func descriptorsSeen() -> String {
        guard let pipes = MCPPipe.make(3) else { return "no pipes" }
        let (input, output, errors) = (pipes[0], pipes[1], pipes[2])
        let launch = MCPUpstreamLaunch(
            server: "fds", executable: "/usr/bin/env", arguments: ["python3", "-c", descriptorLister],
            environment: ["PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"])
        let reaped = DispatchSemaphore(value: 0)
        let spawned = MCPProcessGroup.spawn(
            launch, descriptors: [STDIN_FILENO: input.read, STDOUT_FILENO: output.write, STDERR_FILENO: errors.write]
        ) { _ in reaped.signal() }
        close(input.read)
        close(output.write)
        close(errors.write)
        close(input.write)
        defer {
            close(output.read)
            close(errors.read)
        }
        if case .failure(let failure) = spawned { return "not started: \(failure.reason)" }
        var text = Data()
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            var poller = pollfd(fd: output.read, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 200) > 0 else { continue }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = read(output.read, &chunk, chunk.count)
            guard count > 0 else { break }
            text.append(contentsOf: chunk[0..<count])
        }
        _ = reaped.wait(timeout: .now() + 30)
        return String(decoding: text, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A server has only its three standard descriptors, whatever else rv
    /// holds open without close-on-exec when it starts, and while it opens
    /// more on another thread: a plain socket, an egress proxy and one of
    /// its connections, and a descriptor opened a moment before each spawn.
    @Test(.timeLimit(.minutes(5)), .enabled(if: python3Available))
    func aServerHasOnlyItsStandardDescriptors() async throws {
        let plain = socket(AF_INET, Self.streamType, 0)
        #expect(plain >= 0)
        defer { if plain >= 0 { close(plain) } }
        let proxy = EgressProxy(policy: .publicHTTPS)
        guard case .success(let port) = proxy.start() else {
            Issue.record("the proxy did not start")
            return
        }
        defer { proxy.stop() }
        let connection = Self.connect(port)
        #expect(connection >= 0)
        defer { if connection >= 0 { close(connection) } }
        let churn = DescriptorChurn()
        var seen: [String] = []
        for _ in 0..<20 { seen.append(await offThePool { Self.descriptorsSeen() }) }
        churn.stop()
        #expect(seen.allSatisfy { $0 == "0 1 2" }, "\(seen)")
    }

    /// A set of pipes that cannot be finished (no descriptors left) closes
    /// the ones it made: a failed start must not use up more of them.
    @Test func pipesThatCannotAllBeMadeAreClosed() {
        var made: [(pipe: MCPPipe, ends: [FileIdentity])] = []
        let pipes = MCPPipe.make(3) {
            guard made.count < 2, let pipe = MCPPipe.make() else { return nil }
            made.append((pipe, [FileIdentity(pipe.read), FileIdentity(pipe.write)].compactMap { $0 }))
            return pipe
        }
        #expect(pipes == nil)
        #expect(made.count == 2)
        for (pipe, ends) in made {
            #expect(ends.count == 2)
            // Closed, or by now another file of the process's.
            let still = [pipe.read, pipe.write].compactMap { FileIdentity($0) }.filter { ends.contains($0) }
            #expect(still.isEmpty, "a pipe made for a failed start is still open")
        }
    }

    #if os(Linux)
    /// The egress proxy's listening and accepted sockets are close-on-exec
    /// from the start: a process another thread spawns meanwhile does not
    /// get them.
    @Test(.timeLimit(.minutes(1)))
    func theEgressProxysSocketsAreCloseOnExec() async throws {
        let proxy = EgressProxy(policy: .publicHTTPS)
        guard case .success(let port) = proxy.start() else {
            Issue.record("the proxy did not start")
            return
        }
        defer { proxy.stop() }
        let connection = Self.connect(port)
        #expect(connection >= 0)
        defer { if connection >= 0 { close(connection) } }
        // Its listener and the connection it accepted.
        let found = await offThePool {
            let deadline = Date().addingTimeInterval(30)
            while Self.sockets(boundTo: port).count < 2, Date() < deadline { usleep(20_000) }
            return Self.sockets(boundTo: port)
        }
        #expect(found.count >= 2, "\(found)")
        for fd in found {
            #expect(fcntl(fd, F_GETFD) & FD_CLOEXEC != 0, "descriptor \(fd) is inherited by an exec")
        }
    }

    /// This process's IPv4 sockets whose own port is `port`.
    static func sockets(boundTo port: Int) -> [Int32] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd")) ?? []
        return names.compactMap { Int32($0) }.filter { fd in
            var address = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
            }
            return named == 0 && address.sin_family == sa_family_t(AF_INET) && Int(UInt16(bigEndian: address.sin_port)) == port
        }
    }
    #endif

    #if canImport(Darwin)
    static let streamType = SOCK_STREAM
    #else
    static let streamType = Int32(SOCK_STREAM.rawValue)
    #endif

    /// A blocking IPv4 connection to `127.0.0.1:port`, or -1.
    static func connect(_ port: Int) -> Int32 {
        let fd = socket(AF_INET, streamType, 0)
        guard fd >= 0 else { return -1 }
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                #if canImport(Darwin)
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                #else
                Glibc.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                #endif
            }
        }
        guard connected == 0 else {
            close(fd)
            return -1
        }
        return fd
    }
}

/// Which file a descriptor is, so a closed number reused for another file
/// does not count as the same one.
struct FileIdentity: Equatable {
    let device: UInt64
    let inode: UInt64

    init?(_ fd: Int32) {
        var status = stat()
        guard fstat(fd, &status) == 0 else { return nil }
        device = UInt64(status.st_dev)
        inode = UInt64(status.st_ino)
    }
}
