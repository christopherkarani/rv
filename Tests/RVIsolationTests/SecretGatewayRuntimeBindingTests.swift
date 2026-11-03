#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Synchronization
import Testing
@testable import RVIsolation

/// A stand-in runtime group; the stub checks below never query the kernel.
let testProcessGroup = ProcessGroupFact(pgid: ValidatedPGID(4242)!, startSeconds: 1, startMicroseconds: 2)

extension GatewayPeerCheck {
    static func fixed(_ verdict: GatewayPeerVerdict) -> GatewayPeerCheck {
        GatewayPeerCheck { _, _ in verdict }
    }
}

final class PeerChecks: Sendable {
    let seen = Mutex<[(peer: GatewayPeer, group: ProcessGroupFact)]>([])
    let answer: @Sendable (ProcessGroupFact) -> GatewayPeerVerdict

    init(answer: @escaping @Sendable (ProcessGroupFact) -> GatewayPeerVerdict = { _ in .member }) {
        self.answer = answer
    }

    var check: GatewayPeerCheck {
        GatewayPeerCheck { peer, group in
            self.seen.withLock { $0.append((peer, group)) }
            return self.answer(group)
        }
    }
}

@Suite("SecretGatewayRuntimeBinding")
struct SecretGatewayRuntimeBindingTests {
    private func gateway(
        _ check: GatewayPeerCheck, upstream: RecordingUpstream, audit: AuditRecords,
        group: ProcessGroupFact? = testProcessGroup, surfaces: Set<GatewaySurface> = [.header]
    ) throws -> (SecretGateway, Int, SecretPlaceholder) {
        let gateway = SecretGateway(transport: upstream.transport, peers: check, audit: audit.record)
        let port = try gateway.start().get()
        let placeholder = SecretPlaceholder.mint(prefix: "sk-")
        gateway.register(placeholder, entry: try entry(runtime: "R1", group: group, surfaces: surfaces))
        return (gateway, port, placeholder)
    }

    private func entry(
        runtime: String, group: ProcessGroupFact?, surfaces: Set<GatewaySurface> = [.header]
    ) throws -> SecretGateway.Entry {
        SecretGateway.Entry(
            secret: "OPENAI_API_KEY", prefix: "sk-", credential: .substituted(try #require(SecretValue("sk-live-REAL-0123456789"))),
            upstream: try #require(URL(string: "https://api.example.com/v1")), fingerprint: "abcd", runtime: runtime,
            surfaces: surfaces, processGroup: group)
    }

    private func bearer(_ placeholder: SecretPlaceholder) -> String {
        "GET /s/OPENAI_API_KEY/models HTTP/1.1\r\nAuthorization: Bearer \(placeholder.text)\r\n\r\n"
    }

    @Test func aPlaceholderFromOutsideItsRuntimeIsRefusedAsMisuseNamingTheRuntime() throws {
        let upstream = RecordingUpstream(status: 200)
        let audit = AuditRecords()
        let (gateway, port, placeholder) = try gateway(.fixed(.outsider), upstream: upstream, audit: audit)
        defer { gateway.stop() }

        let response = try gatewayExchange(port: port, bearer(placeholder))
        #expect(response.status == 403)
        #expect(response.body.contains("outside the runtime"))
        #expect(upstream.requests.isEmpty)
        let record = try #require(audit.items.withLock { $0.last })
        #expect(audit.items.withLock { $0.count } == 1)
        #expect(record.refusal?.code == "runtimeMismatch")
        #expect(record.activity == .blocked)
        #expect(record.runtime == "R1")
        #expect(record.secret == "OPENAI_API_KEY")
    }

    @Test func anUnverifiablePeerIsRefusedWithoutAMisuseFinding() throws {
        let upstream = RecordingUpstream(status: 200)
        let audit = AuditRecords()
        let (gateway, port, placeholder) = try gateway(.fixed(.unverifiable), upstream: upstream, audit: audit)
        defer { gateway.stop() }

        #expect(try gatewayExchange(port: port, bearer(placeholder)).status == 403)
        #expect(upstream.requests.isEmpty)
        let record = try #require(audit.items.withLock { $0.last })
        #expect(record.refusal?.code == "runtimeUnverified")
        #expect(record.activity == .refused)
        #expect(record.runtime == "R1")
    }

    @Test func anEntryWithoutAProcessGroupIsRefusedBeforeAnyCheck() throws {
        let upstream = RecordingUpstream(status: 200)
        let audit = AuditRecords()
        let checks = PeerChecks()
        let (gateway, port, placeholder) = try gateway(checks.check, upstream: upstream, audit: audit, group: nil)
        defer { gateway.stop() }

        #expect(try gatewayExchange(port: port, bearer(placeholder)).status == 403)
        #expect(upstream.requests.isEmpty)
        #expect(checks.seen.withLock { $0.isEmpty })
        #expect(audit.items.withLock { $0.last?.refusal?.code } == "runtimeUnverified")
    }

    @Test func theCheckSeesThisConnectionsPortPairAndTheEntrysGroup() throws {
        let upstream = RecordingUpstream(status: 200)
        let audit = AuditRecords()
        let checks = PeerChecks()
        let (gateway, port, placeholder) = try gateway(checks.check, upstream: upstream, audit: audit)
        defer { gateway.stop() }

        #expect(try gatewayExchange(port: port, bearer(placeholder)).status == 200)
        let seen = try #require(checks.seen.withLock { $0.first })
        #expect(seen.peer.gatewayPort == UInt16(port))
        #expect(seen.peer.port != 0 && seen.peer.port != UInt16(port))
        #expect(seen.group == testProcessGroup)
        #expect(upstream.requests.count == 1)
    }

    @Test(arguments: [true, false])
    func everyPlaceholderInTheRequestMustBelongToThePeersRuntime(stolenInQuery: Bool) throws {
        let other = ProcessGroupFact(pgid: ValidatedPGID(5353)!, startSeconds: 3, startMicroseconds: 4)
        let upstream = RecordingUpstream(status: 200)
        let audit = AuditRecords()
        let checks = PeerChecks { $0 == testProcessGroup ? .member : .outsider }
        let (gateway, port, own) = try gateway(
            checks.check, upstream: upstream, audit: audit, surfaces: [.header, .query])
        defer { gateway.stop() }
        let stolen = SecretPlaceholder.mint(prefix: "sk-")
        gateway.register(stolen, entry: try entry(runtime: "R2", group: other, surfaces: [.header, .query]))

        // The query is read before the headers, so the order decides which
        // entry comes first; the record names the failing one either way.
        let (query, header) = stolenInQuery ? (stolen, own) : (own, stolen)
        let response = try gatewayExchange(port: port,
            "GET /s/OPENAI_API_KEY/models?key=\(query.text) HTTP/1.1\r\nAuthorization: Bearer \(header.text)\r\n\r\n")
        #expect(response.status == 403)
        #expect(upstream.requests.isEmpty)
        let record = try #require(audit.items.withLock { $0.last })
        #expect(record.refusal?.code == "runtimeMismatch")
        #expect(record.runtime == "R2")
    }

    @Test func policyRefusalsNameTheRuntimeThePlaceholderWasLeasedTo() throws {
        let upstream = RecordingUpstream(status: 200)
        let audit = AuditRecords()
        let (gateway, port, placeholder) = try gateway(.fixed(.member), upstream: upstream, audit: audit)
        defer { gateway.stop() }

        let response = try gatewayExchange(port: port,
            "GET /s/OPENAI_API_KEY/models?key=\(placeholder.text) HTTP/1.1\r\n\r\n")
        #expect(response.status == 403)
        let record = try #require(audit.items.withLock { $0.last })
        #expect(record.refusal?.code == "surfaceNotAllowed")
        #expect(record.runtime == "R1")
        // No live placeholder, so no runtime to name.
        _ = try gatewayExchange(port: port, "GET /s/OPENAI_API_KEY/models HTTP/1.1\r\n\r\n")
        #expect(audit.items.withLock { $0.last?.runtime } == nil)
    }

    #if os(macOS)
    /// The real libproc scan against this test process's own group: the
    /// connection the gateway accepted is found; any other port pair is not.
    @Test func processGroupScanFindsTheClientSocketInItsGroupAndNothingElse() throws {
        let group = try #require(ProcessGroupRecovery.capture(pid: getpgrp()))
        let verdicts = Mutex<[GatewayPeerVerdict]>([])
        let live = GatewayPeerCheck { peer, group in
            let verdict = GatewayPeerCheck.runtime.verify(peer, group)
            verdicts.withLock { $0.append(verdict) }
            return verdict
        }
        let upstream = RecordingUpstream(status: 200)
        let audit = AuditRecords()
        let (gateway, port, placeholder) = try gateway(live, upstream: upstream, audit: audit, group: group)
        defer { gateway.stop() }

        #expect(try gatewayExchange(port: port, bearer(placeholder)).status == 200)
        #expect(verdicts.withLock { $0 } == [.member])
        #expect(GatewayPeerCheck.runtime.verify(GatewayPeer(port: 9, gatewayPort: UInt16(port)), group) == .outsider)
        var stale = group
        stale.startMicroseconds += 1
        #expect(GatewayPeerCheck.runtime.verify(GatewayPeer(port: 9, gatewayPort: UInt16(port)), stale)
            == .unverifiable)
    }

    /// An orphan that left the leader's group still belongs to the runtime
    /// when the leader leads its session, as a terminal runtime's does.
    @Test func anOrphanInTheLeadersSessionIsServedAndOneOutsideItIsRefused() throws {
        #expect(try orphanStatus(leaderFlags: Int32(POSIX_SPAWN_SETSID)) == "200")
        #expect(try orphanStatus(leaderFlags: Int32(POSIX_SPAWN_SETPGROUP)) == "403")
    }

    /// Spawns `/bin/sh` as a runtime leader with `leaderFlags`. It starts a
    /// curl in a new process group, orphaned before it connects, and the
    /// gateway judges it against the leader. Returns curl's status code.
    private func orphanStatus(leaderFlags: Int32) throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rv-orphan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let go = directory.appendingPathComponent("go").path
        let out = directory.appendingPathComponent("out").path
        let done = directory.appendingPathComponent("done").path
        let upstream = RecordingUpstream(status: 200)
        let audit = AuditRecords()
        let gateway = SecretGateway(transport: upstream.transport, peers: .runtime, audit: audit.record)
        defer { gateway.stop() }
        let port = try gateway.start().get()
        let script = """
            while [ ! -f "$1" ]; do /bin/sleep 0.05; done
            ( /usr/bin/perl -e 'setpgrp(0, 0); select(undef, undef, undef, 0.05) until getppid() == 1; exec @ARGV' \
                /usr/bin/curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $2" "$3" > "$4" & )
            while [ ! -f "$5" ]; do /bin/sleep 0.05; done
            """
        let placeholder = SecretPlaceholder.mint(prefix: "sk-")
        let leader = try spawnShell(script, flags: leaderFlags, arguments: [
            go, placeholder.text, "http://127.0.0.1:\(port)/s/OPENAI_API_KEY/models", out, done])
        defer {
            FileManager.default.createFile(atPath: done, contents: nil)
            var status: Int32 = 0
            waitpid(leader, &status, 0)
        }
        let group = try #require(ProcessGroupRecovery.capture(pid: leader))
        gateway.register(placeholder, entry: try entry(runtime: "R1", group: group))
        FileManager.default.createFile(atPath: go, contents: nil)
        let deadline = Date().addingTimeInterval(20)
        var status = ""
        while Date() < deadline {
            status = (try? String(contentsOfFile: out, encoding: .utf8)) ?? ""
            if status.count == 3 { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return status
    }

    /// A process that joins another runtime's group with
    /// `POSIX_SPAWN_SETPGROUP` shares its pgid but is neither the leader nor
    /// a descendant of it, and the leader leads no session. It is not that
    /// runtime, even though the kernel lets a same-session process join.
    @Test func aSiblingThatJoinedTheRuntimesGroupIsRefused() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rv-join-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let done = directory.appendingPathComponent("done").path
        let out = directory.appendingPathComponent("out").path
        let upstream = RecordingUpstream(status: 200)
        let audit = AuditRecords()
        let gateway = SecretGateway(transport: upstream.transport, peers: .runtime, audit: audit.record)
        defer { gateway.stop() }
        let port = try gateway.start().get()
        let leader = try spawnShell(
            "while [ ! -f \"$1\" ]; do /bin/sleep 0.05; done", flags: Int32(POSIX_SPAWN_SETPGROUP), arguments: [done])
        defer {
            FileManager.default.createFile(atPath: done, contents: nil)
            var status: Int32 = 0
            waitpid(leader, &status, 0)
        }
        let group = try #require(ProcessGroupRecovery.capture(pid: leader))
        let placeholder = SecretPlaceholder.mint(prefix: "sk-")
        gateway.register(placeholder, entry: try entry(runtime: "R1", group: group))

        let sibling = try spawnShell(
            "/usr/bin/curl -sS -o /dev/null -w '%{http_code}' -H \"Authorization: Bearer $1\" \"$2\" > \"$3\"",
            flags: Int32(POSIX_SPAWN_SETPGROUP), joining: leader,
            arguments: [placeholder.text, "http://127.0.0.1:\(port)/s/OPENAI_API_KEY/models", out])
        var status: Int32 = 0
        waitpid(sibling, &status, 0)
        #expect(try String(contentsOfFile: out, encoding: .utf8) == "403")
        #expect(upstream.requests.isEmpty)
        #expect(audit.items.withLock { $0.last?.refusal?.code } == "runtimeMismatch")
    }

    private func spawnShell(
        _ script: String, flags: Int32, joining group: pid_t = 0, arguments: [String]
    ) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(flags))
        if flags & Int32(POSIX_SPAWN_SETPGROUP) != 0 { posix_spawnattr_setpgroup(&attributes, group) }
        let argv = (["/bin/sh", "-c", script, "sh"] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        try #require(posix_spawn(&pid, "/bin/sh", nil, &attributes, argv, environ) == 0)
        return pid
    }
    #endif
}
