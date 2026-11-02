#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Synchronization
import Testing
@testable import RVIsolation

/// `binaries`: a secret is spent only by connections whose holders run, or
/// descend from, a binary pinned when the lease was made.
@Suite("Secret gateway binary binding")
struct SecretGatewayBinaryTests {
    final class PinLog: Sendable {
        let items = Mutex<[[GatewayBinaryPin]]>([])
        var all: [[GatewayBinaryPin]] { items.withLock { $0 } }
    }

    static func json(binaries: String, delivery: String? = nil) -> String {
        let gateway = #"{"gateway":{"upstream":"https://api.example.com","baseURLEnv":"GH_API"}}"#
        return """
            {"version":1,"secrets":[
              {"name":"GH","source":{"hostEnvironment":{"variable":"FAKE_GH"}},"binaries":\(binaries),
               "delivery":\(delivery ?? gateway)}
            ]}
            """
    }

    private func binaryCheck(_ verdict: GatewayBinaryVerdict, seen: PinLog? = nil)
        -> GatewayPeerCheck
    {
        GatewayPeerCheck(verify: { _, _ in .member }, binaries: { _, _, pins in
            seen?.items.withLock { $0.append(pins) }
            return verdict
        })
    }

    private func gateway(_ check: GatewayPeerCheck, pins: [GatewayBinaryPin], upstream: RecordingUpstream,
        audit: AuditRecords, group: ProcessGroupFact = testProcessGroup
    ) throws -> (SecretGateway, Int, SecretPlaceholder) {
        let gateway = SecretGateway(transport: upstream.transport, peers: check, audit: audit.record)
        let port = try gateway.start().get()
        let placeholder = SecretPlaceholder.mint(prefix: "sk-")
        gateway.register(placeholder, entry: SecretGateway.Entry(
            secret: "OPENAI_API_KEY", prefix: "sk-", value: try #require(SecretValue("sk-live-REAL-0123456789")),
            upstream: try #require(URL(string: "https://api.example.com/v1")), fingerprint: "abcd", runtime: "R1",
            surfaces: [.header], processGroup: group, binaries: pins))
        return (gateway, port, placeholder)
    }

    private func bearer(_ placeholder: SecretPlaceholder) -> String {
        "GET /s/OPENAI_API_KEY/models HTTP/1.1\r\nAuthorization: Bearer \(placeholder.text)\r\n\r\n"
    }

    private func pin(_ path: String) throws -> GatewayBinaryPin {
        try #require(GatewayBinaryPin.pin(path))
    }

    @Test func theDecoderRoundTripsBinariesAndRefusesBadLists() throws {
        let decoded = try SecretsConfiguration.decode(Data(Self.json(binaries: #"["/usr/bin/git","/opt/gh"]"#).utf8))
            .get()
        #expect(decoded.secret(named: "GH")?.binaries == ["/usr/bin/git", "/opt/gh"])
        #expect(try SecretsConfiguration.decode(decoded.encoded()).get() == decoded)
        let refused = [
            #"[]"#, #"["git"]"#, #"["/usr/bin/../bin/git"]"#, #"["/usr/./git"]"#, #"["/a","/a"]"#,
            #"["/usr/bin/git\n"]"#, #""/usr/bin/git""#,
        ]
        for binaries in refused {
            guard case .failure(let error) = SecretsConfiguration.decode(Data(Self.json(binaries: binaries).utf8))
            else {
                Issue.record("accepted binaries \(binaries)")
                continue
            }
            #expect(error.message.contains("GH.binaries"))
        }
        let environment = Self.json(binaries: #"["/usr/bin/git"]"#, delivery: #"{"environment":{}}"#)
        guard case .failure(let error) = SecretsConfiguration.decode(Data(environment.utf8)) else {
            Issue.record("binaries accepted with environment delivery")
            return
        }
        #expect(error.message.contains("applies to gateway delivery"))
    }

    @Test func aPinFollowsSymlinksAndBreaksWhenTheFileIsReplacedOrRewritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rv-pin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // The temporary directory is itself under a symlink (/var -> /private/var).
        let real = try #require(realpath(directory.path, nil).map { path in
            defer { free(path) }
            return String(decoding: UnsafeRawBufferPointer(start: path, count: strlen(path)), as: UTF8.self)
        }) + "/tool"
        let link = directory.appendingPathComponent("link").path
        try Data("v1".utf8).write(to: URL(fileURLWithPath: real))
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)

        let pinned = try pin(link)
        #expect(pinned.path == real)
        #expect(pinned.matches(real))
        #expect(pinned.matches(link) == false)

        // Rewritten in place, same size, mtime restored: ctime still moves.
        Thread.sleep(forTimeInterval: 0.01)
        var original = stat()
        stat(real, &original)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: real))
        try handle.write(contentsOf: Data("v2".utf8))
        try handle.close()
        var times = [original.st_atimespec, original.st_mtimespec]
        #expect(utimensat(AT_FDCWD, real, &times, 0) == 0)
        #expect(pinned.matches(real) == false)

        // A different file moved over the path is a different inode.
        let fresh = try pin(real)
        let swap = directory.appendingPathComponent("swap").path
        try Data("v2".utf8).write(to: URL(fileURLWithPath: swap))
        #expect(rename(swap, real) == 0)
        #expect(fresh.matches(real) == false)

        #expect(GatewayBinaryPin.pin(directory.path) == nil)
        #expect(GatewayBinaryPin.pin(directory.appendingPathComponent("absent").path) == nil)
    }

    @Test func aMismatchIsRefusedAsMisuseBeforeAnythingIsForwarded() throws {
        let upstream = RecordingUpstream(status: 200)
        let audit = AuditRecords()
        let (gateway, port, placeholder) = try gateway(
            binaryCheck(.mismatch), pins: [try pin("/usr/bin/true")], upstream: upstream, audit: audit)
        defer { gateway.stop() }

        let response = try gatewayExchange(port: port, bearer(placeholder))
        #expect(response.status == 403)
        #expect(response.body.contains("binaries its definition lists"))
        #expect(upstream.requests.isEmpty)
        let record = try #require(audit.items.withLock { $0.last })
        #expect(audit.items.withLock { $0.count } == 1)
        #expect(record.refusal == "binaryMismatch")
        #expect(record.activity == .blocked)
        #expect(record.secret == "OPENAI_API_KEY")
        #expect(GatewayRefusal.binaryMismatch.isMisuse)
        #expect(GatewayRefusal.binaryMismatch.status == 403)
    }

    @Test func anAllowedHolderIsServedAndAnUnreadableOneIsUnverified() throws {
        let upstream = RecordingUpstream(status: 200)
        let audit = AuditRecords()
        let seen = PinLog()
        let pins = [try pin("/usr/bin/true")]
        let (allowed, port, placeholder) = try gateway(
            binaryCheck(.allowed, seen: seen), pins: pins, upstream: upstream, audit: audit)
        #expect(try gatewayExchange(port: port, bearer(placeholder)).status == 200)
        allowed.stop()
        #expect(seen.all == [pins])

        let (unverified, port2, placeholder2) = try gateway(
            binaryCheck(.unverifiable), pins: pins, upstream: upstream, audit: audit)
        defer { unverified.stop() }
        #expect(try gatewayExchange(port: port2, bearer(placeholder2)).status == 403)
        let record = try #require(audit.items.withLock { $0.last })
        #expect(record.refusal == "runtimeUnverified")
        #expect(record.activity == .refused)
        #expect(upstream.requests.count == 1)
    }

    @Test func aSecretWithoutBinariesNeverAsksWhichBinaryHoldsTheConnection() throws {
        let upstream = RecordingUpstream(status: 200)
        let audit = AuditRecords()
        let seen = PinLog()
        let (gateway, port, placeholder) = try gateway(
            binaryCheck(.mismatch, seen: seen), pins: [], upstream: upstream, audit: audit)
        defer { gateway.stop() }
        #expect(try gatewayExchange(port: port, bearer(placeholder)).status == 200)
        #expect(seen.all.isEmpty)
    }

    @Test func theLeasePinsEachBinaryAndFailsOnOneThatIsNotAFile() throws {
        let fixture = try SecretsFixture(Self.json(binaries: #"["/usr/bin/true","/rv-absent/tool"]"#))
        defer { fixture.tearDown() }
        let resolver = SecretResolver { _ in .success(SecretValue("ghp_realtoken_binary")!) }
        let broker = SecretLaunchBroker(
            configDirectory: fixture.directory, resolver: resolver, transport: RecordingUpstream().transport,
            peers: .fixed(.member), workspace: "W1")
        defer { broker.stop() }
        guard case .failure(let error) = broker.lease(names: ["GH"], agent: nil) else {
            Issue.record("a lease pinned a binary that does not exist")
            return
        }
        #expect(error == .binaryUnavailable(secret: "GH", path: "/rv-absent/tool"))
        #expect(error.message.contains("/rv-absent/tool"))
        #expect(error.message.contains("ghp_") == false)

        let seen = PinLog()
        let upstream = RecordingUpstream()
        let fixture2 = try SecretsFixture(Self.json(binaries: #"["/usr/bin/true"]"#))
        defer { fixture2.tearDown() }
        let broker2 = SecretLaunchBroker(
            configDirectory: fixture2.directory, resolver: resolver, transport: upstream.transport,
            peers: binaryCheck(.allowed, seen: seen), workspace: "W1")
        defer { broker2.stop() }
        let lease = try broker2.lease(names: ["GH"], agent: nil).get()
        broker2.bind(lease, processGroup: testProcessGroup)
        let placeholder = try #require(lease.environment.first { $0.name == "GH" }?.value)
        let port = try #require(broker2.gatewayPort)
        #expect(try gatewayExchange(
            port: port, "GET /s/GH/user HTTP/1.1\r\nAuthorization: Bearer \(placeholder)\r\n\r\n").status == 200)
        #expect(seen.all == [[try pin("/usr/bin/true")]])

        // Through the broker's audit sink, a mismatch is a misuse finding.
        let fixture3 = try SecretsFixture(Self.json(binaries: #"["/usr/bin/true"]"#))
        defer { fixture3.tearDown() }
        let broker3 = SecretLaunchBroker(
            configDirectory: fixture3.directory, resolver: resolver, transport: upstream.transport,
            peers: binaryCheck(.mismatch), workspace: "W1")
        defer { broker3.stop() }
        let lease3 = try broker3.lease(names: ["GH"], agent: nil).get()
        broker3.bind(lease3, processGroup: testProcessGroup)
        let placeholder3 = try #require(lease3.environment.first { $0.name == "GH" }?.value)
        #expect(try gatewayExchange(port: try #require(broker3.gatewayPort),
            "GET /s/GH/user HTTP/1.1\r\nAuthorization: Bearer \(placeholder3)\r\n\r\n").status == 403)
        let misuse = fixture3.auditLines.filter { $0["kind"] as? String == "secret.misuse" }
        #expect(misuse.count == 1)
        #expect((misuse.first?["detail"] as? [String: String])?["refusal"] == "binaryMismatch")
        #expect(upstream.requests.count == 1)
    }

    #if os(macOS)
    /// The real scan: this test process holding the connection runs no
    /// pinned binary; a curl it spawns does, and so does a curl whose
    /// parent shell is pinned. (`/bin/sh` is a trampoline into another
    /// shell, so bash is pinned and run directly.)
    @Test func theRealScanAdmitsAPinnedHolderOrAncestorAndRefusesOthers() throws {
        let group = try #require(ProcessGroupRecovery.capture(pid: getpgrp()))
        let upstream = RecordingUpstream(status: 200)
        let audit = AuditRecords()

        let (curlOnly, port, placeholder) = try gateway(
            .runtime, pins: [try pin("/usr/bin/curl")], upstream: upstream, audit: audit, group: group)
        defer { curlOnly.stop() }
        #expect(try gatewayExchange(port: port, bearer(placeholder)).status == 403)
        #expect(audit.items.withLock { $0.last?.refusal } == "binaryMismatch")
        #expect(try curl(port: port, placeholder: placeholder, viaShell: false) == "200")

        let (shellOnly, port2, placeholder2) = try gateway(
            .runtime, pins: [try pin("/bin/bash")], upstream: upstream, audit: audit, group: group)
        defer { shellOnly.stop() }
        #expect(try curl(port: port2, placeholder: placeholder2, viaShell: true) == "200")
        #expect(try curl(port: port2, placeholder: placeholder2, viaShell: false) == "403")
        #expect(upstream.requests.count == 2)
    }

    /// Runs curl in this process group, directly or under bash (which stays
    /// its parent: the trailing `true` stops bash from exec'ing curl).
    private func curl(port: Int, placeholder: SecretPlaceholder, viaShell: Bool) throws -> String {
        let curl = ["/usr/bin/curl", "-sS", "-o", "/dev/null", "-w", "%{http_code}",
            "-H", "Authorization: Bearer \(placeholder.text)", "http://127.0.0.1:\(port)/s/OPENAI_API_KEY/models"]
        let process = Process()
        let output = Pipe()
        if viaShell {
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", "\"$@\"; true", "sh"] + curl
        } else {
            process.executableURL = URL(fileURLWithPath: curl[0])
            process.arguments = Array(curl.dropFirst())
        }
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
    #endif
}
