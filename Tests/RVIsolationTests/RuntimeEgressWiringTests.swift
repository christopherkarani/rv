#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation
import RVDomain
import RVPolicy
import Synchronization
import Testing
@testable import RVIsolation

#if os(macOS)
/// T3c supervisor wiring: per-runtime proxy construction + lifecycle (Item 2:
/// REQ-2-1, SEC-2-2, CON-2-4; AC-2 grant isolation).
///
/// Each runtime gets its own supervisor-owned proxy instance (credentialed:
/// one supervisor-minted credential mapped to that runtime's grant only),
/// constructed at the spawn seam and stopped with its child. Borrowed shape:
/// OpenShell's two-container model — the workload holds no network of its
/// own and the supervisor authorizes before opening upstream
/// (https://raw.githubusercontent.com/NVIDIA/OpenShell/main/crates/openshell-driver-docker/README.md).
///
/// Hermetic: denials land in an injected in-memory collector (never the real
/// `~/.config`) and every workspace opens with a nil review queue, so no
/// test writes proposals. Serialized: the tests spawn real runtimes.
@Suite("Per-runtime egress wiring", .serialized)
struct RuntimeEgressWiringTests {
    @Test func twoRuntimesGetDistinctProxies() throws {
        let collector = WiringDenialCollector()
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let opened = try openWiringWorkspace(tree, collector: collector)
        let supervisor = opened.supervisor
        defer { _ = supervisor.close() }
        let first = try launchWiringRuntime(
            supervisor, log: opened.runtimeLog, script: "printf held > held-a.txt; /bin/sleep 30"
        )
        let second = try launchWiringRuntime(
            supervisor, log: opened.runtimeLog, script: "printf held > held-b.txt; /bin/sleep 30"
        )
        #expect(
            wiringFileAppears(
                tree.workspaceURL.appendingPathComponent("held-a.txt"))
        )
        #expect(
            wiringFileAppears(
                tree.workspaceURL.appendingPathComponent("held-b.txt"))
        )
        let proxyA = try #require(supervisor.egressProxy(for: first.session.id))
        let proxyB = try #require(supervisor.egressProxy(for: second.session.id))
        let credentialA = try #require(supervisor.egressCredential(for: first.session.id))
        let credentialB = try #require(supervisor.egressCredential(for: second.session.id))
        #expect(proxyA !== proxyB)
        #expect(proxyA.port != 0)
        #expect(proxyB.port != 0)
        #expect(proxyA.port != proxyB.port)
        #expect(credentialA.rawValue != credentialB.rawValue)
        // Live state is per instance: a rule set loaded into A is not
        // visible on B.
        let rule = try #require(LiveNetworkRule(host: "example.com", port: 443))
        #expect(proxyA.updateSupplement([rule], generation: 7) == 7)
        #expect(proxyA.currentSupplementGeneration == 7)
        #expect(proxyB.currentSupplementGeneration == 0)
    }

    @Test func runtimeAGrantDoesNotAuthorizeRuntimeB() throws {
        let stub = try #require(WiringStubServer(reply: "PONG\n"))
        let collector = WiringDenialCollector()
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let opened = try openWiringWorkspace(tree, collector: collector)
        let supervisor = opened.supervisor
        defer { _ = supervisor.close() }
        let first = try launchWiringRuntime(
            supervisor, log: opened.runtimeLog, script: "/bin/sleep 30"
        )
        let second = try launchWiringRuntime(
            supervisor, log: opened.runtimeLog, script: "/bin/sleep 30"
        )
        let proxyA = try #require(supervisor.egressProxy(for: first.session.id))
        let proxyB = try #require(supervisor.egressProxy(for: second.session.id))
        let credentialA = try #require(supervisor.egressCredential(for: first.session.id))
        let credentialB = try #require(supervisor.egressCredential(for: second.session.id))
        let portA = proxyA.port
        let portB = proxyB.port
        try #require(portA != 0 && portB != 0 && portA != portB)
        // Each runtime relays through its own proxy with its own grant.
        #expect(try wiringRelay(port: portA, credential: credentialA, stubPort: stub.port))
        #expect(try wiringRelay(port: portB, credential: credentialB, stubPort: stub.port))
        // Cross-presentation authorizes nothing: A's grant is unknown on
        // B's proxy and vice versa.
        #expect(
            wiringStatus(
                port: portB, credential: credentialA, host: "127.0.0.1", port: stub.port
            ).contains("HTTP/1.1 407")
        )
        #expect(
            wiringStatus(
                port: portA, credential: credentialB, host: "127.0.0.1", port: stub.port
            ).contains("HTTP/1.1 407")
        )
        // Policy still enforced per instance: non-web port denies.
        #expect(
            wiringStatus(
                port: portB, credential: credentialB, host: "denied.example", port: 22
            ).contains("HTTP/1.1 403")
        )
        // Denials pin the reasons: two cross-grant authentications plus one
        // policy refusal; relays record nothing.
        wiringAwaitDenials(collector, count: 3)
        let reasons = collector.all.map(\.reason)
        #expect(reasons.count == 3)
        #expect(reasons.filter({ $0 == .deniedCredential }).count == 2)
        #expect(reasons.filter({ $0 == .deniedPolicy }).count == 1)
    }

    @Test func unauthenticatedLoopbackGetsNothing() throws {
        // SEC-2-2: the per-runtime ports are loopback-reachable like any
        // local listener, but without a supervisor-minted credential they
        // authorize nothing — no open cross-runtime authority remains.
        let collector = WiringDenialCollector()
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let opened = try openWiringWorkspace(tree, collector: collector)
        let supervisor = opened.supervisor
        defer { _ = supervisor.close() }
        let running = try launchWiringRuntime(
            supervisor, log: opened.runtimeLog, script: "/bin/sleep 30"
        )
        let proxy = try #require(supervisor.egressProxy(for: running.session.id))
        let port = proxy.port
        try #require(port != 0)
        #expect(
            wiringStatus(port: port, credential: nil, host: "denied.example", port: 443)
                .contains("HTTP/1.1 407")
        )
        #expect(
            wiringStatus(
                port: port, credential: EgressProxyCredential(rawValue: "wrong"),
                host: "127.0.0.1", port: 1
            ).contains("HTTP/1.1 407")
        )
        wiringAwaitDenials(collector, count: 2)
        #expect(collector.all.count == 2)
        #expect(collector.all.allSatisfy({ $0.reason == .deniedCredential }))
    }

    @Test func cancelStopsOnlyCancelledRuntimeProxy() throws {
        let stub = try #require(WiringStubServer(reply: "PONG\n"))
        let collector = WiringDenialCollector()
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let opened = try openWiringWorkspace(tree, collector: collector)
        let supervisor = opened.supervisor
        defer { _ = supervisor.close() }
        let first = try launchWiringRuntime(
            supervisor, log: opened.runtimeLog, script: "/bin/sleep 30"
        )
        let second = try launchWiringRuntime(
            supervisor, log: opened.runtimeLog, script: "/bin/sleep 30"
        )
        let proxyA = try #require(supervisor.egressProxy(for: first.session.id))
        let proxyB = try #require(supervisor.egressProxy(for: second.session.id))
        let credentialB = try #require(supervisor.egressCredential(for: second.session.id))
        let portA = proxyA.port
        let portB = proxyB.port
        try #require(portA != 0 && portB != 0)
        guard case .success = supervisor.cancel(first.session.id) else {
            Issue.record("cancel must stop the runtime")
            return
        }
        #expect(proxyA.port == 0)
        #expect(wiringConnect(port: portA) == nil)
        #expect(proxyB.port == portB)
        #expect(try wiringRelay(port: portB, credential: credentialB, stubPort: stub.port))
    }

    @Test func closeStopsEveryRuntimeProxy() throws {
        let collector = WiringDenialCollector()
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let opened = try openWiringWorkspace(tree, collector: collector)
        let supervisor = opened.supervisor
        let first = try launchWiringRuntime(
            supervisor, log: opened.runtimeLog, script: "/bin/sleep 30"
        )
        let second = try launchWiringRuntime(
            supervisor, log: opened.runtimeLog, script: "/bin/sleep 30"
        )
        let proxyA = try #require(supervisor.egressProxy(for: first.session.id))
        let proxyB = try #require(supervisor.egressProxy(for: second.session.id))
        let portA = proxyA.port
        let portB = proxyB.port
        try #require(portA != 0 && portB != 0)
        guard case .success = supervisor.close() else {
            Issue.record("close must succeed")
            return
        }
        #expect(proxyA.port == 0)
        #expect(proxyB.port == 0)
        #expect(wiringConnect(port: portA) == nil)
        #expect(wiringConnect(port: portB) == nil)
    }

    @Test func retireUnrecordedStopsRuntimeProxy() throws {
        let collector = WiringDenialCollector()
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let opened = try openWiringWorkspace(tree, collector: collector)
        let supervisor = opened.supervisor
        defer { _ = supervisor.close() }
        let seen = WiringProxyBox()
        supervisor.setEgressConstructionHook { seen.append($0) }
        defer { supervisor.setEgressConstructionHook(nil) }
        let outcome = try supervisor.launch(
            host: .opencode,
            command: wiringShell("/bin/sleep 30"),
            plan: compileContainedPlan(workspace: supervisor.snapshot.policyWorkspace),
            io: .discard,
            admission: .failClosed,
            sessionStore: .file(opened.runtimeLog),
            spawnFault: .register
        )
        guard case .failure(.apply(.lifetimeBoundaryFailed)) = outcome else {
            Issue.record("register fault must fail record, got \(outcome)")
            return
        }
        let proxies = seen.all
        #expect(proxies.count == 1)
        let proxy = try #require(proxies.first)
        #expect(proxy.port == 0)
    }

    @Test func endedRuntimeStopsItsProxy() throws {
        let collector = WiringDenialCollector()
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let opened = try openWiringWorkspace(tree, collector: collector)
        let supervisor = opened.supervisor
        defer { _ = supervisor.close() }
        let running = try launchWiringRuntime(
            supervisor, log: opened.runtimeLog,
            script: "printf done > done.txt; /bin/sleep 2"
        )
        let proxy = try #require(supervisor.egressProxy(for: running.session.id))
        let port = proxy.port
        try #require(port != 0)
        let pid = try #require(running.session.child?.pid)
        // Alive: the proxy serves (407 without a credential proves the
        // listener, not the policy).
        #expect(kill(pid, 0) == 0)
        #expect(
            wiringStatus(port: port, credential: nil, host: "denied.example", port: 443)
                .contains("HTTP/1.1 407")
        )
        #expect(wiringFileAppears(tree.workspaceURL.appendingPathComponent("done.txt")))
        #expect(wiringProcessGone(pid))
        #expect(wiringPortClosed(proxy: proxy, port: port))
        wiringAwaitDenials(collector, count: 1)
        #expect(collector.all.count == 1)
        #expect(collector.all.allSatisfy({ $0.reason == .deniedCredential }))
    }
}

private struct WiringOpened {
    var supervisor: WorkspaceSessionSupervisor
    var runtimeLog: URL
}

private func openWiringWorkspace(
    _ tree: ContainmentTree,
    collector: WiringDenialCollector
) throws -> WiringOpened {
    let runtimeLog = tree.rootURL.appendingPathComponent("runtime-\(UUID().uuidString).jsonl")
    let lifeLog = tree.rootURL.appendingPathComponent("workspace-\(UUID().uuidString).jsonl")
    let directory = try #require(WorkingDirectory(validating: tree.workspaceURL.path))
    let supervisor = try WorkspaceSessionSupervisor.open(
        directory,
        lifecycleLog: .file(lifeLog),
        reviewConfigDirectory: nil,
        denialRecorder: { collector.record($0) }
    ).get()
    return WiringOpened(supervisor: supervisor, runtimeLog: runtimeLog)
}

private func launchWiringRuntime(
    _ supervisor: WorkspaceSessionSupervisor,
    log: URL,
    script: String
) throws -> RunningRuntime {
    try supervisor.launch(
        host: .opencode,
        command: wiringShell(script),
        plan: compileContainedPlan(workspace: supervisor.snapshot.policyWorkspace),
        io: .discard,
        admission: .failClosed,
        sessionStore: .file(log)
    ).get()
}

private func wiringShell(_ script: String) throws -> IsolatedCommand {
    try #require(IsolatedCommand(executable: "/bin/sh", arguments: ["-c", script]))
}

private func wiringFileAppears(_ url: URL) -> Bool {
    wiringWait(seconds: 20) { FileManager.default.fileExists(atPath: url.path) }
}

private func wiringProcessGone(_ pid: pid_t) -> Bool {
    wiringWait(seconds: 30) {
        if kill(pid, 0) == 0 { return false }
        return errno == ESRCH
    }
}

private func wiringPortClosed(proxy: EgressProxy, port: Int) -> Bool {
    wiringWait(seconds: 10) {
        proxy.port == 0 && wiringConnect(port: port) == nil
    }
}

private func wiringWait(seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return condition()
}

/// One CONNECT through `port`, optionally authenticated. Returns the raw
/// status line (plus any relayed bytes).
private func wiringStatus(
    port: Int,
    credential: EgressProxyCredential?,
    host: String,
    port targetPort: Int
) -> String {
    guard let client = wiringConnect(port: port) else { return "connect-refused" }
    defer { close(client) }
    var request = "CONNECT \(host):\(targetPort) HTTP/1.1\r\n"
    if let credential {
        request += "Proxy-Authorization: Bearer \(credential.rawValue)\r\n"
    }
    request += "\r\n"
    guard wiringSend(client, text: request) else { return "send-failed" }
    return wiringRead(client)
}

/// Authenticated CONNECT to a loopback stub through `port`: true only when
/// the proxy relays the stub reply end to end.
private func wiringRelay(port: Int, credential: EgressProxyCredential, stubPort: Int) throws -> Bool {
    guard let client = wiringConnect(port: port) else { return false }
    defer { close(client) }
    guard
        wiringSend(
            client,
            text:
                "CONNECT 127.0.0.1:\(stubPort) HTTP/1.1\r\nProxy-Authorization: Bearer \(credential.rawValue)\r\n\r\n"
        )
    else {
        return false
    }
    guard wiringSend(client, text: "PING\n") else { return false }
    var response = ""
    for _ in 0..<10 {
        response += wiringRead(client)
        if response.contains("PONG") { break }
    }
    return response.contains("HTTP/1.1 200") && response.contains("PONG")
}

private final class WiringDenialCollector: @unchecked Sendable {
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

/// Denials are recorded on the proxy's relay queue after the reply is
/// written; wait for the callback to land instead of asserting immediately.
private func wiringAwaitDenials(_ collector: WiringDenialCollector, count: Int, tries: Int = 100) {
    for _ in 0..<tries {
        if collector.all.count >= count { break }
        usleep(100_000)
    }
}

private final class WiringProxyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var proxies: [EgressProxy] = []

    func append(_ proxy: EgressProxy) {
        lock.lock()
        proxies.append(proxy)
        lock.unlock()
    }

    var all: [EgressProxy] {
        lock.lock()
        defer { lock.unlock() }
        return proxies
    }
}

/// Loopback stub that answers every connection with `reply`, so relay
/// assertions need no external network.
private final class WiringStubServer: @unchecked Sendable {
    let port: Int
    private let listenFD: Int32
    private let reply: [UInt8]

    init?(reply: String) {
        let fd = wiringStreamSocket()
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
        guard bound == 0, listen(fd, 16) == 0 else {
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
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.acceptLoop() }
    }

    deinit {
        shutdown(listenFD, Int32(SHUT_RDWR))
        close(listenFD)
    }

    private func acceptLoop() {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            _ = buffer.withUnsafeMutableBytes { pointer -> Int in
                guard let base = pointer.baseAddress else { return -1 }
                return recv(fd, base, pointer.count, 0)
            }
            _ = reply.withUnsafeBytes { pointer -> Int in
                guard let base = pointer.baseAddress else { return -1 }
                return send(fd, base, pointer.count, 0)
            }
            close(fd)
        }
    }
}

private func wiringStreamSocket() -> Int32 {
    #if canImport(Darwin)
    return socket(AF_INET, SOCK_STREAM, 0)
    #else
    return socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #endif
}

private func wiringConnect(port: Int) -> Int32? {
    let fd = wiringStreamSocket()
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

private func wiringSend(_ fd: Int32, text: String) -> Bool {
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

private func wiringRead(_ fd: Int32, timeoutSeconds: Int = 10) -> String {
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
#endif
