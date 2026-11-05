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
        try GatewayBinaryPin.pin(path).get()
    }

    @Test func theDecoderRoundTripsBinariesAndRefusesBadLists() throws {
        let decoded = try SecretsConfiguration.decode(Data(Self.json(binaries: #"["/opt/homebrew/bin/gh","/opt/gh"]"#).utf8))
            .get()
        #expect(decoded.secret(named: "GH")?.binaries == ["/opt/homebrew/bin/gh", "/opt/gh"])
        #expect(try SecretsConfiguration.decode(decoded.encoded()).get() == decoded)
        let refused = [
            #"[]"#, #"["git"]"#, #"["/usr/bin/../bin/git"]"#, #"["/usr/./git"]"#, #"["/a","/a"]"#,
            #"["/opt/gh\n"]"#, #""/opt/gh""#,
        ]
        for binaries in refused {
            guard case .failure(let error) = SecretsConfiguration.decode(Data(Self.json(binaries: binaries).utf8))
            else {
                Issue.record("accepted binaries \(binaries)")
                continue
            }
            #expect(error.message.contains("GH.binaries"))
        }
        let environment = Self.json(binaries: #"["/opt/homebrew/bin/gh"]"#, delivery: #"{"environment":{}}"#)
        guard case .failure(let error) = SecretsConfiguration.decode(Data(environment.utf8)) else {
            Issue.record("binaries accepted with environment delivery")
            return
        }
        #expect(error.message.contains("applies to gateway delivery"))
        guard case .failure(let listError) = SecretsConfiguration.decode(Data(Self.json(binaries: "[]").utf8)) else {
            Issue.record("an empty binaries list was accepted")
            return
        }
        #expect(listError.message.contains("/opt/homebrew/bin/gh"))
        #expect(listError.message.contains("/usr/bin/git") == false)
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
        #if canImport(Darwin)
        var times = [original.st_atimespec, original.st_mtimespec]
        #else
        var times = [original.st_atim, original.st_mtim]
        #endif
        #expect(utimensat(AT_FDCWD, real, &times, 0) == 0)
        #expect(pinned.matches(real) == false)

        // A different file moved over the path is a different inode.
        let fresh = try pin(real)
        let swap = directory.appendingPathComponent("swap").path
        try Data("v2".utf8).write(to: URL(fileURLWithPath: swap))
        #expect(rename(swap, real) == 0)
        #expect(fresh.matches(real) == false)

        #expect(GatewayBinaryPin.pin(directory.path) == .failure(.notAFile))
        #expect(GatewayBinaryPin.pin(directory.appendingPathComponent("absent").path) == .failure(.notAFile))
    }

    /// The kernel reports a script's interpreter, never the script, so a
    /// pinned script would 403 every request.
    @Test func aScriptCannotBePinned() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rv-script-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("tool").path
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: URL(fileURLWithPath: script))
        #expect(GatewayBinaryPin.pin(script) == .failure(.script))
        let binary = directory.appendingPathComponent("binary").path
        try Data([0xCF, 0xFA, 0xED, 0xFE]).write(to: URL(fileURLWithPath: binary))
        #expect(throws: Never.self) { _ = try GatewayBinaryPin.pin(binary).get() }
    }

    /// `/usr/bin/git`, `python3`, `make` and `clang` are xcrun trampolines:
    /// they exec the real tool in the same process, so nothing runs as them.
    @Test func aDeveloperShimCannotBePinnedAndNamesTheRealTool() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rv-shim-\(UUID().uuidString)")
        let shims = directory.appendingPathComponent("shims")
        let developer = directory.appendingPathComponent("developer")
        try FileManager.default.createDirectory(at: shims, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: developer.appendingPathComponent("usr/bin"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for path in [shims.appendingPathComponent("tool"), shims.appendingPathComponent("own"),
            developer.appendingPathComponent("usr/bin/tool")]
        {
            try Data([0xCF, 0xFA, 0xED, 0xFE]).write(to: path)
            #expect(chmod(path.path, 0o755) == 0)
        }
        let shimDirectory = try #require(realpath(shims.path, nil).map { path in
            defer { free(path) }
            return String(cString: path)
        })
        let developerDirectory = try #require(realpath(developer.path, nil).map { path in
            defer { free(path) }
            return String(cString: path)
        })
        let refused = GatewayBinaryPin.pin(
            shimDirectory + "/tool", shimDirectory: shimDirectory, developerDirectories: [developerDirectory])
        #expect(refused == .failure(.developerShim(real: developerDirectory + "/usr/bin/tool")))
        // A tool the developer directory does not carry is a real binary.
        #expect(throws: Never.self) {
            _ = try GatewayBinaryPin.pin(
                shimDirectory + "/own", shimDirectory: shimDirectory, developerDirectories: [developerDirectory]).get()
        }
        // Outside the shim directory the name is irrelevant.
        #expect(throws: Never.self) {
            _ = try GatewayBinaryPin.pin(
                developerDirectory + "/usr/bin/tool", shimDirectory: shimDirectory,
                developerDirectories: [developerDirectory]).get()
        }
        // On a host with the Command Line Tools, the documented trap is real.
        if FileManager.default.isExecutableFile(atPath: "/Library/Developer/CommandLineTools/usr/bin/git") {
            guard case .failure(.developerShim(let real)) = GatewayBinaryPin.pin("/usr/bin/git") else {
                Issue.record("/usr/bin/git was pinnable")
                return
            }
            #expect(real.hasSuffix("/usr/bin/git"))
        }
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
        #expect(record.refusal?.code == "binaryMismatch")
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
        #expect(record.refusal?.code == "runtimeUnverified")
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
        #expect(error == .binaryUnavailable(secret: "GH", path: "/rv-absent/tool", reason: .notAFile))
        #expect(error.message.contains("/rv-absent/tool"))
        #expect(error.message.contains("ghp_") == false)

        let script = FileManager.default.temporaryDirectory.appendingPathComponent("rv-lease-\(UUID().uuidString).sh")
        try Data("#!/bin/sh\n".utf8).write(to: script)
        defer { try? FileManager.default.removeItem(at: script) }
        let scripted = try SecretsFixture(Self.json(binaries: "[\"\(script.path)\"]"))
        defer { scripted.tearDown() }
        let scriptBroker = SecretLaunchBroker(
            configDirectory: scripted.directory, resolver: resolver, transport: RecordingUpstream().transport,
            peers: .fixed(.member), workspace: "W1")
        defer { scriptBroker.stop() }
        guard case .failure(let scriptError) = scriptBroker.lease(names: ["GH"], agent: nil) else {
            Issue.record("a lease pinned a script")
            return
        }
        #expect(scriptError == .binaryUnavailable(secret: "GH", path: script.path, reason: .script))
        #expect(scriptError.message.contains("list the interpreter"))

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
    private func holder(_ pid: pid_t) throws -> GatewayHolder {
        guard case .found(let info) = ProcessGroupRecovery.lookup(pid) else { throw Unreadable() }
        return GatewayHolder(pid: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
    }

    struct Unreadable: Error {}

    @Test func aHolderWhoseStartTimeChangedBeforeTheWalkIsUnverifiable() throws {
        let pins = [try pin("/usr/bin/true")]
        let me = try holder(getpid())
        #expect(GatewayBinaryScan.verdict(holder: me, leader: 1, pins: pins) == .mismatch)
        var reused = me
        reused.startMicroseconds += 1
        #expect(GatewayBinaryScan.verdict(holder: reused, leader: 1, pins: pins) == .unverifiable)
    }

    @Test func aWalkThatRunsOutOfAncestorsIsUnverifiableNotAMismatch() throws {
        let pins = [try pin("/usr/bin/true")]
        let me = try holder(getpid())
        // The test process has more than one ancestor and the leader is none of them.
        #expect(GatewayBinaryScan.verdict(holder: me, leader: 1, pins: pins, limit: 1) == .unverifiable)
        #expect(GatewayBinaryScan.verdict(holder: me, leader: 1, pins: pins) == .mismatch)
    }

    @Test func aParentThatStartedAfterItsChildIsAReusedPid() {
        let child = GatewayBinaryScan.Link(pid: 20, parent: 10, seconds: 100, microseconds: 5)
        let parent = GatewayBinaryScan.Link(pid: 10, parent: 1, seconds: 90, microseconds: 0)
        #expect(GatewayBinaryScan.ordered([child, parent]))
        let sameSecond = GatewayBinaryScan.Link(pid: 10, parent: 1, seconds: 100, microseconds: 4)
        #expect(GatewayBinaryScan.ordered([child, sameSecond]))
        let reused = GatewayBinaryScan.Link(pid: 10, parent: 1, seconds: 100, microseconds: 6)
        #expect(GatewayBinaryScan.ordered([child, reused]) == false)
        #expect(GatewayBinaryScan.ordered([child]))
    }

    /// The real scan, in a fresh process group led by a perl process the
    /// test knows: nothing between the connection holders and the leader
    /// is a stray shell. The leader runs `mode`:
    /// - `direct`: curl is its child.
    /// - `shell`: curl is the child of a bash that stays its parent (the
    ///   trailing `true` stops bash from exec'ing curl).
    /// - `shared`: the leader opens the connection and a bash child, which
    ///   inherits the socket, sends the request; both hold it.
    /// Returns the status code, and the audit refusal code of the last record.
    private func scan(mode: String, pins: (pid_t) throws -> [GatewayBinaryPin]) throws
        -> (status: String, refusal: String?)
    {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rv-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let go = directory.appendingPathComponent("go").path
        let out = directory.appendingPathComponent("out").path
        let upstream = RecordingUpstream(status: 200)
        let audit = AuditRecords()
        let gateway = SecretGateway(transport: upstream.transport, peers: .runtime, audit: audit.record)
        defer { gateway.stop() }
        let port = try gateway.start().get()
        let script = """
            use IO::Socket::INET;
            my ($go, $out, $mode) = @ARGV;
            select(undef, undef, undef, 0.05) until -s $go;
            open(my $g, '<', $go) or die; my ($port, $placeholder) = split(' ', <$g>); close $g;
            my @curl = ('/usr/bin/curl', '-sS', '-o', '/dev/null', '-w', '%{http_code}',
                '-H', "Authorization: Bearer $placeholder", "http://127.0.0.1:$port/s/OPENAI_API_KEY/models");
            my $result = '';
            if ($mode eq 'direct') {
                open(my $h, '-|', @curl) or die; $result = <$h>; close $h;
            } elsif ($mode eq 'shell') {
                open(my $h, '-|', '/bin/bash', '-c', '"$@"; true', 'sh', @curl) or die; $result = <$h>; close $h;
            } else {
                $^F = 1000;
                my $socket = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port") or die;
                my $fd = fileno($socket);
                open(my $h, '-|', '/bin/bash', '-c',
                    'printf "GET /s/OPENAI_API_KEY/models HTTP/1.1\\r\\nAuthorization: Bearer %s\\r\\n\\r\\n" "$1" >&$2; '
                    . 'IFS= read -r line <&$2; echo "${line:9:3}"', 'sh', $placeholder, $fd) or die;
                $result = <$h>; close $h;
            }
            open(my $o, '>', "$out.tmp") or die; print $o $result; close $o; rename("$out.tmp", $out);
            """
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        let argv = ["/usr/bin/perl", "-e", script, go, out, mode].map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var leader: pid_t = 0
        try #require(posix_spawn(&leader, "/usr/bin/perl", nil, &attributes, argv, environ) == 0)
        defer {
            kill(-leader, SIGKILL)
            var status: Int32 = 0
            waitpid(leader, &status, 0)
        }
        let group = try #require(ProcessGroupRecovery.capture(pid: leader))
        let placeholder = SecretPlaceholder.mint(prefix: "sk-")
        gateway.register(placeholder, entry: SecretGateway.Entry(
            secret: "OPENAI_API_KEY", prefix: "sk-", value: try #require(SecretValue("sk-live-REAL-0123456789")),
            upstream: try #require(URL(string: "https://api.example.com/v1")), fingerprint: "abcd", runtime: "R1",
            surfaces: [.header], processGroup: group, binaries: try pins(leader)))
        try Data("\(port) \(placeholder.text)".utf8).write(to: URL(fileURLWithPath: go))
        let deadline = Date().addingTimeInterval(20)
        var status = ""
        while Date() < deadline {
            status = ((try? String(contentsOfFile: out, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if status.isEmpty == false { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return (status, audit.items.withLock { $0.last?.refusal?.code })
    }

    @Test func theRealScanAdmitsAPinnedHolderOrAncestorAndRefusesOthers() throws {
        let curl = try pin("/usr/bin/curl")
        let bash = try pin("/bin/bash")
        // A pinned holder is served.
        #expect(try scan(mode: "direct", pins: { _ in [curl] }).status == "200")
        // An unpinned holder whose parent (the leader) is unpinned too is refused as misuse.
        let direct = try scan(mode: "direct", pins: { _ in [bash] })
        #expect(direct.status == "403")
        #expect(direct.refusal == "binaryMismatch")
        // A pinned ancestor between the holder and the leader admits it.
        #expect(try scan(mode: "shell", pins: { _ in [bash] }).status == "200")
    }

    /// A forked child inherits the socket, so the parent holds it too: every
    /// holder must pass, not just one.
    @Test func everyHolderOfASharedSocketMustPass() throws {
        let bash = try pin("/bin/bash")
        let refused = try scan(mode: "shared", pins: { _ in [bash] })
        #expect(refused.status == "403")
        #expect(refused.refusal == "binaryMismatch")
        let admitted = try scan(mode: "shared", pins: { leader in
            [bash, try GatewayBinaryPin.pin(try #require(GatewayBinaryScan.executablePath(leader))).get()]
        })
        #expect(admitted.status == "200")
    }
    #endif
}
