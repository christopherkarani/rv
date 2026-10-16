#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation
import RVDomain
import RVPolicy
import Testing
@testable import RVIsolation

private func reviewTempConfig(named: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-review-\(named)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func reviewWorkspace() throws -> (WorkspaceSessionID, WorkingDirectory) {
    let directory = try #require(WorkingDirectory(validating: "/tmp/rv-review-ws"))
    return (WorkspaceSessionID(), directory)
}

private final class ReviewDenialCollector: @unchecked Sendable {
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

    func waitFor(count: Int, timeoutSeconds: Int = 15) -> [EgressProxyDenial] {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            let current = all
            if current.count >= count { return current }
            usleep(50_000)
        }
        return all
    }
}

private func reviewSocket() -> Int32 {
    #if canImport(Darwin)
    return socket(AF_INET, SOCK_STREAM, 0)
    #else
    return socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #endif
}

private func reviewConnect(port: Int) -> Int32? {
    let fd = reviewSocket()
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

private func reviewConnectAndClose(port: Int, host: String, targetPort: Int) -> Bool {
    guard let fd = reviewConnect(port: port) else { return false }
    defer { close(fd) }
    let bytes = Array("CONNECT \(host):\(targetPort) HTTP/1.1\r\nHost: \(host)\r\n\r\n".utf8)
    var offset = 0
    while offset < bytes.count {
        let written = bytes.withUnsafeBytes { pointer -> Int in
            guard let base = pointer.baseAddress else { return -1 }
            return send(fd, base.advanced(by: offset), bytes.count - offset, 0)
        }
        if written <= 0 { return false }
        offset += written
    }
    var buffer = [UInt8](repeating: 0, count: 1024)
    var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    if poll(&item, 1, 15_000) > 0 {
        _ = recv(fd, &buffer, buffer.count, 0)
    }
    return true
}

struct NetworkReviewQueueTests {
    @Test func denialCreatesScopedProposal() async throws {
        let config = try reviewTempConfig(named: "intake")
        let queue = NetworkReviewQueue(configDirectory: config)
        let (workspace, directory) = try reviewWorkspace()
        let now = Date()
        await queue.noteDenial(
            EgressProxyDenial(host: "blocked.invalid", port: 8443, reason: .deniedPolicy, recordedAt: now),
            workspace: workspace,
            workspaceDirectory: directory,
            now: now
        )
        let store = PendingApprovalStore(baseDirectory: config)
        let rows = try await store.list(now: now)
        let proposals = rows.filter(EgressProposal.isNetworkProposal)
        #expect(proposals.count == 1)
        let proposal = try #require(proposals.first)
        #expect(proposal.fingerprint.rawValue == "egress:blocked.invalid:8443")
        #expect(proposal.reason == .mandatoryHuman)
        #expect(proposal.timeoutPolicy == .autoDeny)
        guard case .awaitingHuman = proposal.state else {
            Issue.record("proposal must await a human")
            return
        }
    }

    @Test func intakeIgnoresNonPolicyDenials() async throws {
        let config = try reviewTempConfig(named: "nonpolicy")
        let queue = NetworkReviewQueue(configDirectory: config)
        let (workspace, directory) = try reviewWorkspace()
        let now = Date()
        for reason in [
            EgressDenialReason.dnsFailed, .addressFiltered, .dialFailed,
            .headerTooLarge, .malformed,
        ] {
            await queue.noteDenial(
                EgressProxyDenial(
                    host: "blocked.invalid", port: 443, reason: reason, recordedAt: now),
                workspace: workspace,
                workspaceDirectory: directory,
                now: now
            )
        }
        await queue.noteDenial(
            EgressProxyDenial(host: "not a host!!", port: 443, reason: .deniedPolicy, recordedAt: now),
            workspace: workspace,
            workspaceDirectory: directory,
            now: now
        )
        let store = PendingApprovalStore(baseDirectory: config)
        #expect(try await store.list(now: now).isEmpty)
    }

    @Test func intakeDedupesRetryStorms() async throws {
        let config = try reviewTempConfig(named: "dedupe")
        let queue = NetworkReviewQueue(configDirectory: config)
        let (workspace, directory) = try reviewWorkspace()
        let now = Date()
        for _ in 0..<5 {
            await queue.noteDenial(
                EgressProxyDenial(
                    host: "blocked.invalid", port: 443, reason: .deniedPolicy, recordedAt: now),
                workspace: workspace,
                workspaceDirectory: directory,
                now: now
            )
        }
        let store = PendingApprovalStore(baseDirectory: config)
        #expect(try await store.list(now: now).count == 1)
    }

    @Test func intakeSkipsLiveRules() async throws {
        let config = try reviewTempConfig(named: "live-skip")
        let queue = NetworkReviewQueue(configDirectory: config)
        let (workspace, directory) = try reviewWorkspace()
        let rule = LiveNetworkRule(host: "blocked.invalid", port: 443)!
        let channel = await queue.liveChannel
        _ = channel.append(rule)
        let now = Date()
        await queue.noteDenial(
            EgressProxyDenial(host: rule.host, port: rule.port, reason: .deniedPolicy, recordedAt: now),
            workspace: workspace,
            workspaceDirectory: directory,
            now: now
        )
        let store = PendingApprovalStore(baseDirectory: config)
        #expect(try await store.list(now: now).isEmpty)
    }

    @Test func approvalAppliesOnce() async throws {
        let config = try reviewTempConfig(named: "apply")
        let queue = NetworkReviewQueue(configDirectory: config)
        let (workspace, directory) = try reviewWorkspace()
        let now = Date()
        await queue.noteDenial(
            EgressProxyDenial(
                host: "blocked.invalid", port: 443, reason: .deniedPolicy, recordedAt: now),
            workspace: workspace,
            workspaceDirectory: directory,
            now: now
        )
        #expect(await queue.applyResolved(now: now) == nil)
        let store = PendingApprovalStore(baseDirectory: config)
        let created = try #require(try await store.list(now: now).first)
        _ = try await store.resolve(
            id: created.id,
            decision: .allowOnce,
            fingerprint: created.fingerprint,
            identity: created.identity,
            now: now
        )
        let update = try #require(await queue.applyResolved(now: now))
        #expect(update.rules == [LiveNetworkRule(host: "blocked.invalid", port: 443)!])
        #expect(update.generation == 1)
        #expect(update.approvalIDs == [created.id.rawValue])
        #expect(await queue.applyResolved(now: now) == nil)
    }

    @Test func denialAppliesNothing() async throws {
        let config = try reviewTempConfig(named: "deny-apply")
        let queue = NetworkReviewQueue(configDirectory: config)
        let (workspace, directory) = try reviewWorkspace()
        let now = Date()
        await queue.noteDenial(
            EgressProxyDenial(
                host: "blocked.invalid", port: 443, reason: .deniedPolicy, recordedAt: now),
            workspace: workspace,
            workspaceDirectory: directory,
            now: now
        )
        let store = PendingApprovalStore(baseDirectory: config)
        let created = try #require(try await store.list(now: now).first)
        _ = try await store.resolveWithReason(
            id: created.id,
            decision: .deny,
            fingerprint: created.fingerprint,
            identity: created.identity,
            reason: "do not exfil",
            now: now
        )
        #expect(await queue.applyResolved(now: now) == nil)
        let channel = await queue.liveChannel
        #expect(channel.snapshot().rules.isEmpty)
    }

    @Test func driftedRowFailsClosed() async throws {
        let config = try reviewTempConfig(named: "drift")
        let queue = NetworkReviewQueue(configDirectory: config)
        let (workspace, directory) = try reviewWorkspace()
        let now = Date()
        await queue.noteDenial(
            EgressProxyDenial(
                host: "blocked.invalid", port: 443, reason: .deniedPolicy, recordedAt: now),
            workspace: workspace,
            workspaceDirectory: directory,
            now: now
        )
        let store = PendingApprovalStore(baseDirectory: config)
        let created = try #require(try await store.list(now: now).first)
        _ = try await store.resolve(
            id: created.id,
            decision: .allowOnce,
            fingerprint: created.fingerprint,
            identity: created.identity,
            now: now
        )
        // Same-user file swap after approval: rewrite the stored
        // fingerprint to a host the human never reviewed.
        let file = config.appendingPathComponent("pending-approvals.jsonl", isDirectory: false)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("egress:blocked.invalid:443"))
        let swapped = text.replacingOccurrences(
            of: "egress:blocked.invalid:443", with: "egress:evil.invalid:443")
        try swapped.write(to: file, atomically: true, encoding: .utf8)
        #expect(await queue.applyResolved(now: now) == nil)
        let channel = await queue.liveChannel
        #expect(channel.snapshot().rules.isEmpty)
    }

    @Test func approvalLoadsLiveIntoRunningProxy() async throws {
        let config = try reviewTempConfig(named: "live")
        let queue = NetworkReviewQueue(configDirectory: config)
        let collector = ReviewDenialCollector()
        let proxy = EgressProxy(policy: .agentAPIs, record: { collector.record($0) })
        let port: Int
        switch proxy.start() {
        case .success(let bound):
            port = bound
        case .failure(let error):
            Issue.record("proxy must bind: \(error)")
            return
        }
        defer { proxy.stop() }
        #expect(proxy.currentSupplementGeneration == 0)
        #expect(reviewConnectAndClose(port: port, host: "blocked.invalid", targetPort: 443))
        var denials = collector.waitFor(count: 1)
        #expect(denials.first?.reason == .deniedPolicy)
        let (workspace, directory) = try reviewWorkspace()
        let now = Date()
        await queue.noteDenial(
            denials[0],
            workspace: workspace,
            workspaceDirectory: directory,
            now: now
        )
        let store = PendingApprovalStore(baseDirectory: config)
        let created = try #require(try await store.list(now: now).first)
        _ = try await store.resolve(
            id: created.id,
            decision: .allowOnce,
            fingerprint: created.fingerprint,
            identity: created.identity,
            now: now
        )
        let update = try #require(await queue.applyResolved(now: now))
        #expect(proxy.updateSupplement(update.rules, generation: update.generation) == 1)
        #expect(proxy.currentSupplementGeneration == 1)
        // Retry without restart: policy admits (the .invalid name fails
        // DNS, which proves admission — a policy refusal would repeat).
        #expect(reviewConnectAndClose(port: port, host: "blocked.invalid", targetPort: 443))
        denials = collector.waitFor(count: 2)
        #expect(denials.count == 2)
        #expect(denials[1].reason != .deniedPolicy)
    }

    @Test func staleSupplementPushesAreIgnored() async throws {
        let collector = ReviewDenialCollector()
        let proxy = EgressProxy(policy: .agentAPIs, record: { collector.record($0) })
        let port: Int
        switch proxy.start() {
        case .success(let bound):
            port = bound
        case .failure(let error):
            Issue.record("proxy must bind: \(error)")
            return
        }
        defer { proxy.stop() }
        let ruleA = LiveNetworkRule(host: "a.invalid", port: 443)!
        let ruleB = LiveNetworkRule(host: "b.invalid", port: 443)!
        #expect(proxy.updateSupplement([ruleA], generation: 1) == 1)
        #expect(reviewConnectAndClose(port: port, host: "a.invalid", targetPort: 443))
        var denials = collector.waitFor(count: 1)
        #expect(denials.first?.reason != .deniedPolicy)
        // Stale push (same generation, different set) must not apply.
        #expect(proxy.updateSupplement([ruleB], generation: 1) == 1)
        #expect(proxy.currentSupplementGeneration == 1)
        #expect(reviewConnectAndClose(port: port, host: "b.invalid", targetPort: 443))
        denials = collector.waitFor(count: 2)
        #expect(denials.count == 2)
        #expect(denials[1].reason == .deniedPolicy)
        // Newer generation applies.
        #expect(proxy.updateSupplement([ruleA, ruleB], generation: 2) == 2)
        #expect(reviewConnectAndClose(port: port, host: "b.invalid", targetPort: 443))
        denials = collector.waitFor(count: 3)
        #expect(denials.count == 3)
        #expect(denials[2].reason != .deniedPolicy)
    }

    @Test func recordLoadedWritesSnapshotFile() async throws {
        let config = try reviewTempConfig(named: "loaded")
        let queue = NetworkReviewQueue(configDirectory: config)
        let ruleB = try #require(LiveNetworkRule(host: "b.example.com", port: 443))
        let ruleA = try #require(LiveNetworkRule(host: "a.example.com", port: 80))
        await queue.recordLoaded(
            rules: [ruleB, ruleA], generation: 3, approvalIDs: ["id-1"],
            now: Date(timeIntervalSince1970: 2_000_000))
        let url = RVPolicyPaths.egressLoadedSnapshotFile(inConfigDir: config)
        let data = try #require(FileManager.default.contents(atPath: url.path))
        let snapshot = try #require(EgressLoadedSnapshot.parse(data))
        #expect(snapshot.generation == 3)
        #expect(snapshot.rules == [ruleA, ruleB])
        #expect(snapshot.approvalIDs == ["id-1"])
        // Newer record overwrites; the file always shows the latest push.
        await queue.recordLoaded(
            rules: [ruleA], generation: 4, approvalIDs: ["id-1", "id-2"],
            now: Date(timeIntervalSince1970: 2_000_001))
        let againData = try #require(FileManager.default.contents(atPath: url.path))
        let again = try #require(EgressLoadedSnapshot.parse(againData))
        #expect(again.generation == 4)
        #expect(again.rules == [ruleA])
    }
}
