#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation
import RVDomain
import Testing
@testable import RVIsolation

/// T3 cutover: the bound proxy's binary gate verifies against the
/// admission-time pin and never TOFU-pins at first CONNECT (REQ-1-1).
///
/// The golden is established when the bound instance is constructed
/// (the admission moment for a per-runtime proxy) via `admit`, and every
/// request is judged by `verifyAdmitted`, which denies unknown paths
/// without pinning. A swap between bind and first CONNECT therefore
/// denies instead of canonizing attacker bytes.
///
/// Borrowed shape: OpenShell `BinaryIdentityCache::verify_or_cache`
/// (fingerprint-gated rehash, mismatch-without-update)
/// https://raw.githubusercontent.com/NVIDIA/OpenShell/f88aecfd92e02cb1b5388041f09930d78065979a/crates/navigator-sandbox/src/identity.rs
/// with trust fixed at creation per
/// https://docs.nvidia.com/openshell/latest/how-it-works/policies/manage-policies
/// ("take effect only when the sandbox starts").
@Suite("Bound proxy admission pin")
struct EgressProxyAdmissionPinTests {
    private static let path = "/opt/rv/bin/agent"

    @Test func boundProxyPinsAtBindNotFirstConnect() throws {
        let script = AdmitPinScript(fingerprint: AdmitPinScript.print(inode: 7), digest: "golden")
        let pins = EgressBinaryPinCache(
            fingerprint: { script.capture($0) },
            hashFile: { script.hash($0) }
        )
        let proxy = EgressProxy(
            binaryPolicy: EgressBinaryPolicy(canonicalPaths: [Self.path]),
            attribution: EgressRuntimeAttribution(binaryPath: Self.path),
            pins: pins,
            record: { _ in }
        )
        // Admission hashes once, before any request exists.
        #expect(script.hashCalls == 1)
        let stub = try #require(AdmitPinStubServer(reply: "PONG\n"))
        let port = try proxy.start().get()
        defer { proxy.stop() }
        let client = try #require(admitPinConnect(port: port))
        defer { close(client) }
        #expect(admitPinSend(client, text: "CONNECT 127.0.0.1:\(stub.port) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"))
        #expect(admitPinSend(client, text: "PING\n"))
        var response = ""
        for _ in 0..<10 {
            response += admitPinRead(client)
            if response.contains("PONG") { break }
        }
        #expect(response.contains("HTTP/1.1 200"))
        #expect(response.contains("PONG"))
        // First CONNECT verifies via the fingerprint fast-path: no rehash.
        #expect(script.hashCalls == 1)
    }

    @Test func boundProxyDeniesSwapBeforeFirstConnect() throws {
        let script = AdmitPinScript(fingerprint: AdmitPinScript.print(inode: 7), digest: "golden")
        let pins = EgressBinaryPinCache(
            fingerprint: { script.capture($0) },
            hashFile: { script.hash($0) }
        )
        let collector = AdmitPinDenialCollector()
        let proxy = EgressProxy(
            binaryPolicy: EgressBinaryPolicy(canonicalPaths: [Self.path]),
            attribution: EgressRuntimeAttribution(binaryPath: Self.path),
            pins: pins,
            record: { collector.record($0) }
        )
        let stub = try #require(AdmitPinStubServer(reply: "PONG\n"))
        let port = try proxy.start().get()
        defer { proxy.stop() }
        // Attacker swaps the binary after admission, before first CONNECT.
        script.retarget(fingerprint: AdmitPinScript.print(inode: 9), digest: "tampered")
        let first = try #require(admitPinConnect(port: port))
        defer { close(first) }
        #expect(admitPinSend(first, text: "CONNECT 127.0.0.1:\(stub.port) HTTP/1.1\r\n\r\n"))
        let denied = admitPinReadUntil403(first)
        #expect(denied.contains("HTTP/1.1 403"))
        admitPinAwaitDenials(collector, count: 1)
        #expect(collector.all.count == 1)
        #expect(collector.all.first?.reason == .binaryMismatch)
        #expect(collector.all.first?.binaryPath == Self.path)
        // The golden survived: restoring the admitted bytes re-admits, so
        // the swapped bytes were never canonized as a new golden.
        script.retarget(fingerprint: AdmitPinScript.print(inode: 7), digest: "golden")
        let second = try #require(admitPinConnect(port: port))
        defer { close(second) }
        #expect(admitPinSend(second, text: "CONNECT 127.0.0.1:\(stub.port) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"))
        #expect(admitPinSend(second, text: "PING\n"))
        var relayed = ""
        for _ in 0..<10 {
            relayed += admitPinRead(second)
            if relayed.contains("PONG") { break }
        }
        #expect(relayed.contains("HTTP/1.1 200"))
        #expect(relayed.contains("PONG"))
    }

    @Test func boundProxyDeniesWhenUnadmittedAtBind() throws {
        // Unmeasurable at admission: no golden is established.
        let script = AdmitPinScript(fingerprint: nil, digest: "golden")
        let pins = EgressBinaryPinCache(
            fingerprint: { script.capture($0) },
            hashFile: { script.hash($0) }
        )
        let collector = AdmitPinDenialCollector()
        let proxy = EgressProxy(
            binaryPolicy: EgressBinaryPolicy(canonicalPaths: [Self.path]),
            attribution: EgressRuntimeAttribution(binaryPath: Self.path),
            pins: pins,
            record: { collector.record($0) }
        )
        #expect(script.hashCalls == 0)
        let stub = try #require(AdmitPinStubServer(reply: "PONG\n"))
        let port = try proxy.start().get()
        defer { proxy.stop() }
        // Bytes appear only after admission: first CONNECT must not pin them.
        script.retarget(fingerprint: AdmitPinScript.print(inode: 7), digest: "late-bytes")
        for _ in 0..<2 {
            let client = try #require(admitPinConnect(port: port))
            #expect(admitPinSend(client, text: "CONNECT 127.0.0.1:\(stub.port) HTTP/1.1\r\n\r\n"))
            let denied = admitPinReadUntil403(client)
            close(client)
            #expect(denied.contains("HTTP/1.1 403"))
        }
        admitPinAwaitDenials(collector, count: 2)
        #expect(collector.all.count == 2)
        #expect(collector.all.allSatisfy { $0.reason == .binaryMismatch })
        // Unknown paths deny before any hash: nothing was pinned, twice.
        #expect(script.hashCalls == 0)
    }

    @Test func credentialedBoundProxyDeniesSwapBeforeFirstConnect() throws {
        let script = AdmitPinScript(fingerprint: AdmitPinScript.print(inode: 7), digest: "golden")
        let pins = EgressBinaryPinCache(
            fingerprint: { script.capture($0) },
            hashFile: { script.hash($0) }
        )
        let collector = AdmitPinDenialCollector()
        let credential = EgressProxyCredential()
        let proxy = EgressProxy(
            grants: [
                credential: EgressGrant(
                    principal: EgressPrincipal(rawValue: "runtime-a"),
                    policy: .publicHTTPS
                )
            ],
            binaryPolicy: EgressBinaryPolicy(canonicalPaths: [Self.path]),
            attribution: EgressRuntimeAttribution(binaryPath: Self.path),
            pins: pins,
            record: { collector.record($0) }
        )
        #expect(script.hashCalls == 1)
        let stub = try #require(AdmitPinStubServer(reply: "PONG\n"))
        let port = try proxy.start().get()
        defer { proxy.stop() }
        script.retarget(fingerprint: AdmitPinScript.print(inode: 9), digest: "tampered")
        let client = try #require(admitPinConnect(port: port))
        defer { close(client) }
        #expect(
            admitPinSend(
                client,
                text: "CONNECT 127.0.0.1:\(stub.port) HTTP/1.1\r\nProxy-Authorization: Bearer \(credential.rawValue)\r\n\r\n"
            )
        )
        let denied = admitPinReadUntil403(client)
        #expect(denied.contains("HTTP/1.1 403"))
        admitPinAwaitDenials(collector, count: 1)
        #expect(collector.all.count == 1)
        #expect(collector.all.first?.reason == .binaryMismatch)
        #expect(collector.all.first?.binaryPath == Self.path)
    }
}

/// Scripted `stat`/hash backend: no filesystem, deterministic pin
/// transitions driven by the test.
private final class AdmitPinScript: @unchecked Sendable {
    private let lock = NSLock()
    private var fingerprint: EgressBinaryFingerprint?
    private var digest: String?
    private var calls = 0

    init(fingerprint: EgressBinaryFingerprint?, digest: String?) {
        self.fingerprint = fingerprint
        self.digest = digest
    }

    static func print(inode: UInt64) -> EgressBinaryFingerprint {
        EgressBinaryFingerprint(
            size: 128,
            mtimeSeconds: 1_700_000_000,
            mtimeNanoseconds: 0,
            ctimeSeconds: 1_700_000_000,
            ctimeNanoseconds: 0,
            device: 1,
            inode: inode
        )
    }

    func retarget(fingerprint: EgressBinaryFingerprint?, digest: String?) {
        lock.lock()
        self.fingerprint = fingerprint
        self.digest = digest
        lock.unlock()
    }

    func capture(_ path: String) -> EgressBinaryFingerprint? {
        lock.lock()
        defer { lock.unlock() }
        return fingerprint
    }

    func hash(_ path: String) -> String? {
        lock.lock()
        calls += 1
        let digest = digest
        lock.unlock()
        return digest
    }

    var hashCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

private final class AdmitPinDenialCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var denials: [EgressProxyDenial] = []

    func record(_ denial: EgressProxyDenial) {
        lock.lock()
        denials.append(denial)
        lock.unlock()
    }

    var all: [EgressProxyDenial] {
        lock.lock()
        defer { lock.unlock() }
        return denials
    }
}

private final class AdmitPinStubServer: @unchecked Sendable {
    let port: Int
    private let listenFD: Int32
    private let reply: [UInt8]

    init?(reply: String) {
        let fd = admitPinStreamSocket()
        guard fd >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound: Int32 = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                bind(fd, address, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            close(fd)
            return nil
        }
        var name = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let fetched: Int32 = withUnsafeMutablePointer(to: &name) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                getsockname(fd, address, &length)
            }
        }
        guard fetched == 0 else {
            close(fd)
            return nil
        }
        listenFD = fd
        port = Int(UInt16(bigEndian: name.sin_port))
        self.reply = Array(reply.utf8)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.acceptOnce() }
    }

    deinit {
        shutdown(listenFD, Int32(SHUT_RDWR))
        close(listenFD)
    }

    private func acceptOnce() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        _ = buffer.withUnsafeMutableBytes { pointer -> Int in
            guard let base = pointer.baseAddress else { return -1 }
            return recv(fd, base, pointer.count, 0)
        }
        _ = reply.withUnsafeBytes { pointer -> Int in
            guard let base = pointer.baseAddress else { return -1 }
            return send(fd, base, pointer.count, 0)
        }
    }
}

private func admitPinStreamSocket() -> Int32 {
    #if canImport(Darwin)
    return socket(AF_INET, SOCK_STREAM, 0)
    #else
    return socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #endif
}

private func admitPinConnect(port: Int) -> Int32? {
    let fd = admitPinStreamSocket()
    guard fd >= 0 else { return nil }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(port)).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let result: Int32 = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
            connect(fd, address, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard result == 0 else {
        close(fd)
        return nil
    }
    return fd
}

private func admitPinSend(_ fd: Int32, text: String) -> Bool {
    let bytes = Array(text.utf8)
    var offset = 0
    while offset < bytes.count {
        let written = bytes.withUnsafeBytes { pointer -> Int in
            guard let base = pointer.baseAddress else { return -1 }
            return send(fd, base.advanced(by: offset), bytes.count - offset, 0)
        }
        if written <= 0 { return false }
        offset += written
    }
    return true
}

private func admitPinRead(_ fd: Int32, timeoutSeconds: Int = 10) -> String {
    var collected = [UInt8]()
    var buffer = [UInt8](repeating: 0, count: 4096)
    let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
    while Date() < deadline {
        var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&item, 1, 200)
        if ready <= 0 { continue }
        let count = buffer.withUnsafeMutableBytes { pointer -> Int in
            guard let base = pointer.baseAddress else { return -1 }
            return recv(fd, base, pointer.count, 0)
        }
        if count <= 0 { break }
        collected.append(contentsOf: buffer[..<count])
        if String(bytes: collected, encoding: .utf8) != nil, collected.count >= 12 {
            var probe = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&probe, 1, 200) <= 0 { break }
        }
    }
    return String(bytes: collected, encoding: .utf8) ?? ""
}

private func admitPinReadUntil403(_ fd: Int32, tries: Int = 6) -> String {
    var response = ""
    for _ in 0..<tries {
        response += admitPinRead(fd)
        if response.contains("HTTP/1.1 403") { break }
    }
    return response
}

private func admitPinAwaitDenials(_ collector: AdmitPinDenialCollector, count: Int, tries: Int = 100) {
    for _ in 0..<tries {
        if collector.all.count >= count { break }
        usleep(100_000)
    }
}
