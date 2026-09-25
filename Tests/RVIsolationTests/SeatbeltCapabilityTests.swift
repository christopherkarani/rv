#if os(macOS)
import Darwin
import Foundation
import RVDomain
import Synchronization
import Testing
@testable import RVIsolation

/// Kernel effects of the deny-default Seatbelt profile. Payloads must run.
/// A tool that exits before the operation is not a denial.
@Suite("SeatbeltCapability", .serialized)
struct SeatbeltCapabilityTests {
    @Test func containedProcessCannotConnectOrResolve() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let binary = try compileConnectClient(in: tree.workspaceURL)
        let tcp4 = try BoundSocket.tcp(family: AF_INET)
        let udp4 = try BoundSocket.udp()
        let tcp6 = try BoundSocket.tcp(family: AF_INET6)
        let unix = try BoundSocket.unix()
        defer {
            tcp4.close()
            udp4.close()
            tcp6.close()
            unix.close()
        }

        let unsandboxed = try runDirect(
            binary,
            arguments: [tcp4.port, udp4.port, tcp6.port, unix.path]
        )
        #expect(unsandboxed.output.contains("tcp4 ok"))
        #expect(unsandboxed.output.contains("udp4 ok"))
        #expect(unsandboxed.output.contains("tcp6 ok"))
        #expect(unsandboxed.output.contains("public ok"))
        #expect(unsandboxed.output.contains("unix ok"))
        #expect(unsandboxed.output.contains("dns ok"))
        #expect(tcp4.received == "c-tcp")
        tcp4.reset()
        udp4.reset()
        tcp6.reset()
        unix.reset()

        let netOut = tree.workspaceURL.appendingPathComponent("net.out")
        let command = try #require(
            IsolatedCommand(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "\(quote(binary.path)) \(tcp4.port) \(udp4.port) \(tcp6.port) \(quote(unix.path)) > \(quote(netOut.path))",
                ]
            )
        )
        let sandboxed = try await IsolationBackends.applyOffPool(tree.contained, command: command).get()
        let captured = try String(contentsOf: netOut, encoding: .utf8)
        #expect(sandboxed.exitStatus == 0)
        #expect(captured.contains("tcp4 errno=1"))
        #expect(captured.contains("udp4 errno=1"))
        #expect(captured.contains("tcp6 errno=1"))
        #expect(captured.contains("public errno=1"))
        #expect(captured.contains("unix errno=1"))
        #expect(captured.contains("dns rc="))
        #expect(captured.contains("dns ok") == false)
        #expect(tcp4.received == nil)
        #expect(udp4.received == nil)
        #expect(tcp6.received == nil)
        #expect(unix.received == nil)

        let child = try #require(
            IsolatedCommand(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "\(quote(binary.path)) \(tcp4.port) \(udp4.port) \(tcp6.port) \(quote(unix.path)) > \(quote(tree.workspaceURL.appendingPathComponent("child.out").path))",
                ]
            )
        )
        _ = try await IsolationBackends.applyOffPool(tree.contained, command: child).get()
        let childOut = try String(
            contentsOf: tree.workspaceURL.appendingPathComponent("child.out"),
            encoding: .utf8
        )
        #expect(childOut.contains("tcp4 errno=1"))
        #expect(tcp4.received == nil)
    }

    @Test func containedProcessCannotReadSiblingFile() async throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let secret = tree.siblingURL.appendingPathComponent("secret.txt")
        try Data("synthetic-secret\n".utf8).write(to: secret)
        let copy = tree.workspaceURL.appendingPathComponent("copy.txt")
        let command = try #require(
            IsolatedCommand(
                executable: "/bin/sh",
                arguments: ["-c", "/bin/cat \(quote(secret.path)) > \(quote(copy.path))"]
            )
        )
        let run = try await IsolationBackends.applyOffPool(tree.contained, command: command).get()
        #expect(run.exitStatus != 0)
        let copied = (try? String(contentsOf: copy, encoding: .utf8)) ?? ""
        #expect(copied.contains("synthetic-secret") == false)
        #expect(try String(contentsOf: secret, encoding: .utf8) == "synthetic-secret\n")
    }
}

private func quote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func compileConnectClient(in workspace: URL) throws -> URL {
    let source = workspace.appendingPathComponent("connect.c")
    let binary = workspace.appendingPathComponent("connect")
    try Data(connectSource.utf8).write(to: source)
    let compile = Process()
    compile.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
    compile.arguments = ["-O2", "-o", binary.path, source.path]
    compile.standardOutput = FileHandle.nullDevice
    compile.standardError = FileHandle.nullDevice
    try compile.run()
    compile.waitUntilExit()
    try #require(compile.terminationStatus == 0)
    return binary
}

private func runDirect(_ binary: URL, arguments: [String]) throws -> (status: Int32, output: String) {
    let output = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-seatbelt-direct-\(UUID().uuidString)")
    let process = Process()
    process.executableURL = binary
    process.arguments = arguments
    process.standardOutput = try FileHandle(forWritingTo: {
        FileManager.default.createFile(atPath: output.path, contents: nil)
        return output
    }())
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    let text = try String(contentsOf: output, encoding: .utf8)
    try? FileManager.default.removeItem(at: output)
    return (process.terminationStatus, text)
}

private final class BoundSocket: Sendable {
    let fd: Int32
    let port: String
    let path: String
    private let state = Mutex<SocketState>(SocketState())

    private struct SocketState: Sendable {
        var payload: String?
        var running = true
    }

    private init(fd: Int32, port: String, path: String) {
        self.fd = fd
        self.port = port
        self.path = path
    }

    var received: String? {
        state.withLock { $0.payload }
    }

    private var isRunning: Bool {
        state.withLock { $0.running }
    }

    func reset() {
        state.withLock { $0.payload = nil }
    }

    func close() {
        state.withLock { $0.running = false }
        Darwin.close(fd)
        if path.isEmpty == false {
            unlink(path)
        }
    }

    static func tcp(family: Int32) throws -> BoundSocket {
        let fd = socket(family, SOCK_STREAM, 0)
        try #require(fd >= 0)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        if family == AF_INET6 {
            var only: Int32 = 1
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &only, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_addr = in6addr_loopback
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
            try #require(bound == 0)
        } else {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            try #require(bound == 0)
        }
        try #require(listen(fd, 4) == 0)
        var length = socklen_t(family == AF_INET6 ? MemoryLayout<sockaddr_in6>.size : MemoryLayout<sockaddr_in>.size)
        var storage = sockaddr_storage()
        let got = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        try #require(got == 0)
        let portNumber: UInt16
        if family == AF_INET6 {
            portNumber = storage.withSockAddr { $0.pointee.sin6_port }
        } else {
            portNumber = storage.withSockAddr4 { $0.pointee.sin_port }
        }
        let socket = BoundSocket(fd: fd, port: String(Int(UInt16(bigEndian: portNumber))), path: "")
        socket.acceptLoop()
        return socket
    }

    static func udp() throws -> BoundSocket {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        try #require(fd >= 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try #require(bound == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        var storage = sockaddr_storage()
        _ = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        let portNumber = storage.withSockAddr4 { $0.pointee.sin_port }
        let socket = BoundSocket(fd: fd, port: String(Int(UInt16(bigEndian: portNumber))), path: "")
        socket.receiveDatagram()
        return socket
    }

    static func unix() throws -> BoundSocket {
        let path = "/tmp/rv-cap-\(UUID().uuidString.prefix(8)).sock"
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(fd >= 0)
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8
        try #require(bytes.count < MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: bytes.count + 1) { raw in
                for (index, byte) in bytes.enumerated() { raw[index] = byte }
                raw[bytes.count] = 0
            }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(bound == 0)
        try #require(listen(fd, 2) == 0)
        let socket = BoundSocket(fd: fd, port: "0", path: path)
        socket.acceptLoop()
        return socket
    }

    private func acceptLoop() {
        let fd = self.fd
        Thread.detachNewThread { [weak self] in
            while self?.isRunning == true {
                var buffer = [UInt8](repeating: 0, count: 16)
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                let count = read(client, &buffer, buffer.count)
                Darwin.close(client)
                guard let self, count > 0 else { continue }
                let text = String(decoding: buffer.prefix(count), as: UTF8.self)
                self.state.withLock { $0.payload = text }
            }
        }
    }

    private func receiveDatagram() {
        let fd = self.fd
        Thread.detachNewThread { [weak self] in
            while self?.isRunning == true {
                var buffer = [UInt8](repeating: 0, count: 16)
                let count = recvfrom(fd, &buffer, buffer.count, 0, nil, nil)
                guard let self, count > 0 else { return }
                let text = String(decoding: buffer.prefix(count), as: UTF8.self)
                self.state.withLock { $0.payload = text }
            }
        }
    }
}

private extension sockaddr_storage {
    func withSockAddr<T>(_ body: (UnsafePointer<sockaddr_in6>) -> T) -> T {
        withUnsafePointer(to: self) {
            $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1, body)
        }
    }

    func withSockAddr4<T>(_ body: (UnsafePointer<sockaddr_in>) -> T) -> T {
        withUnsafePointer(to: self) {
            $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1, body)
        }
    }
}

private let connectSource = #"""
#include <arpa/inet.h>
#include <errno.h>
#include <netdb.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
static void report(const char *name, int rc) {
    if (rc == 0) printf("%s ok\n", name);
    else printf("%s errno=%d\n", name, errno);
}
int main(int argc, char **argv) {
    if (argc < 5) return 64;
    int tcp_port = atoi(argv[1]);
    int udp_port = atoi(argv[2]);
    int tcp6_port = atoi(argv[3]);
    const char *unix_path = argv[4];
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in in4;
    memset(&in4, 0, sizeof(in4));
    in4.sin_family = AF_INET;
    in4.sin_port = htons((unsigned short)tcp_port);
    in4.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    int rc = connect(fd, (struct sockaddr *)&in4, sizeof(in4));
    if (rc == 0) write(fd, "c-tcp", 5);
    report("tcp4", rc);
    close(fd);
    fd = socket(AF_INET, SOCK_DGRAM, 0);
    memset(&in4, 0, sizeof(in4));
    in4.sin_family = AF_INET;
    in4.sin_port = htons((unsigned short)udp_port);
    in4.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    rc = sendto(fd, "c-udp", 5, 0, (struct sockaddr *)&in4, sizeof(in4));
    report("udp4", rc < 0 ? -1 : 0);
    close(fd);
    fd = socket(AF_INET6, SOCK_STREAM, 0);
    struct sockaddr_in6 in6;
    memset(&in6, 0, sizeof(in6));
    in6.sin6_family = AF_INET6;
    in6.sin6_port = htons((unsigned short)tcp6_port);
    in6.sin6_addr = in6addr_loopback;
    rc = connect(fd, (struct sockaddr *)&in6, sizeof(in6));
    if (rc == 0) write(fd, "c-tcp6", 6);
    report("tcp6", rc);
    close(fd);
    fd = socket(AF_INET, SOCK_STREAM, 0);
    memset(&in4, 0, sizeof(in4));
    in4.sin_family = AF_INET;
    in4.sin_port = htons(443);
    inet_pton(AF_INET, "1.1.1.1", &in4.sin_addr);
    rc = connect(fd, (struct sockaddr *)&in4, sizeof(in4));
    report("public", rc);
    close(fd);
    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un un;
    memset(&un, 0, sizeof(un));
    un.sun_family = AF_UNIX;
    strncpy(un.sun_path, unix_path, sizeof(un.sun_path) - 1);
    rc = connect(fd, (struct sockaddr *)&un, sizeof(un));
    if (rc == 0) write(fd, "c-unix", 6);
    report("unix", rc);
    close(fd);
    struct addrinfo *info = 0;
    int dns = getaddrinfo("example.com", "80", 0, &info);
    if (dns == 0) { printf("dns ok\n"); freeaddrinfo(info); }
    else printf("dns rc=%d\n", dns);
    return 0;
}
"""#
#endif
