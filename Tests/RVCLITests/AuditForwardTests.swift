#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVHistory
import RVIsolation
import Synchronization
import Testing
@testable import RVCLI

@Suite("rv audit forward")
struct AuditForwardTests {
    final class Receiver: Sendable {
        let payloads = Mutex<[Data]>([])
        let statuses = Mutex<[Int]>([])

        var transport: AuditForwardTransport {
            AuditForwardTransport { _, _, body in
                let status = self.statuses.withLock { $0.isEmpty ? 200 : $0.removeFirst() }
                if (200..<300).contains(status) { self.payloads.withLock { $0.append(body) } }
                return .success(status)
            }
        }

        var bodies: [[Any]] {
            payloads.withLock { $0 }.map { (try? JSONSerialization.jsonObject(with: $0) as? [Any]) ?? [] }
        }

        var received: Int { bodies.reduce(0) { $0 + $1.count } }
    }

    final class Config {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rv-forward-\(UUID().uuidString)")

        func record(_ count: Int, from start: Int = 0) {
            for index in start..<(start + count) {
                _ = AuditLog.append(
                    AuditEvent(
                        time: Date(timeIntervalSince1970: TimeInterval(1_000 + index)), kind: .mcpCall, decision: .allowed,
                        subject: "s/tool\(index)", source: "mcp-gateway"),
                    configDirectory: directory)
            }
        }

        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    private func options(batch: Int = 2, format: AuditForwardRun.Format = .ocsf) throws -> AuditForwardRun.Options {
        AuditForwardRun.Options(url: try AuditForwardRun.destination("https://siem.example.com/rv").get(), format: format, batchSize: batch)
    }

    @Test func sendsHistoryInBatchesThenOnlyNewEvents() throws {
        let config = Config()
        config.record(5)
        let receiver = Receiver()
        let first = try AuditForwardRun.forward(
            options: options(), configDirectory: config.directory, hostName: "h", transport: receiver.transport
        ).get()
        #expect(first == "forwarded 5 events in 3 batches to https://siem.example.com/rv\n")
        #expect(receiver.bodies.map(\.count) == [2, 2, 1])
        let firstEvent = receiver.bodies.first?.first as? [String: Any]
        #expect(firstEvent?["class_uid"] as? Int == 6003)
        let lastUnmapped = (receiver.bodies.last?.last as? [String: Any])?["unmapped"] as? [String: Any]
        #expect(lastUnmapped?["rv_chain_head"] as? String
            == AuditChain.head(fileURL: AuditLog.fileURL(configDirectory: config.directory)))

        #expect(try AuditForwardRun.forward(
            options: options(), configDirectory: config.directory, hostName: "h", transport: receiver.transport
        ).get().hasPrefix("nothing new"))

        config.record(1, from: 5)
        _ = try AuditForwardRun.forward(
            options: options(format: .rv), configDirectory: config.directory, hostName: "h", transport: receiver.transport
        ).get()
        let last = receiver.bodies.last?.first as? [String: Any]
        #expect(last?["subject"] as? String == "s/tool5")
        #expect(receiver.received == 6)
    }

    @Test func failedPostKeepsTheCursorSoTheBatchIsResent() throws {
        let config = Config()
        config.record(3)
        let receiver = Receiver()
        receiver.statuses.withLock { $0 = [200, 503] }
        let failed = AuditForwardRun.forward(
            options: try options(), configDirectory: config.directory, hostName: "h", transport: receiver.transport)
        guard case .failure(let failure) = failed else {
            Issue.record("a 503 must fail the pass")
            return
        }
        #expect(failure.message == "sent 2 events, then HTTP 503; the cursor is kept, rerun to retry")
        #expect(receiver.received == 2)

        _ = try AuditForwardRun.forward(
            options: options(), configDirectory: config.directory, hostName: "h", transport: receiver.transport
        ).get()
        #expect(receiver.received == 3)
        let subjects = receiver.bodies.flatMap { $0 }
            .compactMap { (($0 as? [String: Any])?["unmapped"] as? [String: Any])?["rv_subject"] as? String }
        #expect(subjects == ["s/tool0", "s/tool1", "s/tool2"])
    }

    @Test func redirectIsNotFollowedAndDoesNotAdvanceTheCursor() throws {
        let config = Config()
        config.record(2)
        let redirect = try RedirectSink.start()
        defer { redirect.stop() }
        let options = AuditForwardRun.Options(url: redirect.url, batchSize: 10)
        let failed = AuditForwardRun.forward(
            options: options, configDirectory: config.directory, hostName: "h", transport: .live)
        guard case .failure(let failure) = failed else {
            Issue.record("a 307 must fail the pass")
            return
        }
        #expect(failure.message.contains("HTTP 307"))
        #expect(redirect.requests == 1)

        let receiver = Receiver()
        _ = try AuditForwardRun.forward(
            options: options, configDirectory: config.directory, hostName: "h", transport: receiver.transport
        ).get()
        #expect(receiver.received == 2)
    }

    @Test func fromNowSkipsHistoryAndALockedRunRefuses() throws {
        let config = Config()
        config.record(4)
        let receiver = Receiver()
        _ = try AuditForwardRun.startFromNow(options: options(), configDirectory: config.directory).get()
        #expect(try AuditForwardRun.forward(
            options: options(), configDirectory: config.directory, hostName: "h", transport: receiver.transport
        ).get().hasPrefix("nothing new"))

        let cursor = AuditForwardRun.cursorURL(config.directory, destination: try options().url)
        let lock = try #require(FileLock(cursor.deletingLastPathComponent().appendingPathComponent(cursor.lastPathComponent + ".lock")))
        defer { lock.release() }
        let refused = AuditForwardRun.forward(
            options: try options(), configDirectory: config.directory, hostName: "h", transport: receiver.transport)
        if case .failure(let failure) = refused {
            #expect(failure.message.contains("another `rv audit forward`"))
        } else {
            Issue.record("a concurrent run must refuse")
        }
    }

    @Test func destinationsHeadersAndSecretHeaders() throws {
        #expect((try? AuditForwardRun.destination("https://siem.example.com").get()) != nil)
        #expect((try? AuditForwardRun.destination("http://127.0.0.1:9000/x").get()) != nil)
        #expect((try? AuditForwardRun.destination("http://siem.example.com").get()) == nil)
        #expect((try? AuditForwardRun.destination("not a url").get()) == nil)
        #expect((try? AuditForwardRun.destination("https://siem.example/hook?v=1").get()) != nil)
        let userinfo = AuditForwardRun.destination("https://user:pass@siem.example/ingest")
        guard case .failure(let userinfoFailure) = userinfo else {
            Issue.record("userinfo must be refused")
            return
        }
        #expect(userinfoFailure.message.contains("username or password"))
        #expect(userinfoFailure.message.contains("user:pass") == false)
        let query = AuditForwardRun.destination("https://siem.example/hook?token=abc123")
        guard case .failure(let queryFailure) = query else {
            Issue.record("a query secret must be refused")
            return
        }
        #expect(queryFailure.message.contains("secret in its query"))
        #expect(queryFailure.message.contains("abc123") == false)
        let pathSecret = "ghp_1234567890abcdefghij"
        let nestedSecret = "supersecretpassword"
        let secretDestinations = [
            ("https://siem.example/ingest/\(pathSecret)", "secret in its path"),
            ("https://siem.example/ingest#\(pathSecret)", "fragment"),
            ("https://siem.example/hook?next=https://user:\(nestedSecret)@collector.example", "secret in its query"),
        ]
        for (text, fragment) in secretDestinations {
            guard case .failure(let failure) = AuditForwardRun.destination(text) else {
                Issue.record("refused \(fragment)")
                continue
            }
            #expect(failure.message.contains(fragment), "\(fragment)")
            #expect(failure.message.contains(pathSecret) == false)
            #expect(failure.message.contains(nestedSecret) == false)
            #expect(failure.message.contains("user:\(nestedSecret)") == false)
        }
        #expect((try? AuditForwardRun.destination("https://siem.example/hook?next=https://collector.example/v1").get()) != nil)
        #expect(try AuditForwardRun.parseHeaders(["Authorization=Bearer x=y"]).get() == ["Authorization": "Bearer x=y"])
        #expect((try? AuditForwardRun.parseHeaders(["=x"]).get()) == nil)

        let secrets = SecretsConfiguration(secrets: [
            SecretDefinition(name: "SIEM", source: .hostEnvironment(variable: "SIEM"), delivery: .environment)
        ])
        let resolver = SecretResolver { _ in .success(SecretValue("tok123")!) }
        let resolved = try AuditForwardRun.resolveHeaders(
            ["Authorization": "Bearer ${secret:SIEM}", "X-Plain": "p"], secrets: { .success(secrets) }, resolver: resolver
        ).get()
        #expect(resolved == ["Authorization": "Bearer tok123", "X-Plain": "p"])
        #expect((try? AuditForwardRun.resolveHeaders(
            ["A": "${secret:NOPE}"], secrets: { .success(secrets) }, resolver: resolver).get()) == nil)
    }
}

/// Loopback POST sink that answers 307 to a host that is not this process.
/// A client that follows the redirect never gets status 307 from here.
private final class RedirectSink: @unchecked Sendable {
    let url: URL
    private let listenFD: Int32
    private let hits = Mutex(0)

    var requests: Int { hits.withLock { $0 } }

    private init(url: URL, listenFD: Int32) {
        self.url = url
        self.listenFD = listenFD
    }

    static func start() throws -> RedirectSink {
#if canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
#else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
#endif
        guard fd >= 0 else { throw RedirectSinkError() }
        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                bind(fd, sock, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 1) == 0 else {
            close(fd)
            throw RedirectSinkError()
        }
        var named = sockaddr_in()
        var namedLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let namedOK = withUnsafeMutablePointer(to: &named) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                getsockname(fd, sock, &namedLength)
            }
        }
        guard namedOK == 0 else {
            close(fd)
            throw RedirectSinkError()
        }
        let port = Int(UInt16(bigEndian: named.sin_port))
        guard let url = URL(string: "http://127.0.0.1:\(port)/rv") else {
            close(fd)
            throw RedirectSinkError()
        }
        let sink = RedirectSink(url: url, listenFD: fd)
        DispatchQueue.global().async {
            let client = accept(fd, nil, nil)
            if client < 0 { return }
            sink.hits.withLock { $0 += 1 }
            Self.reply(client)
            close(client)
        }
        return sink
    }

    func stop() { close(listenFD) }

    private static func reply(_ client: Int32) {
        var gathered = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while gathered.count < 65_536 {
            let readCount = read(client, &buffer, buffer.count)
            if readCount <= 0 { break }
            gathered.append(contentsOf: buffer.prefix(readCount))
            guard let headerEnd = gathered.range(of: Data("\r\n\r\n".utf8)) else { continue }
            let headerText = String(data: gathered[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
            let length = contentLength(in: headerText)
            if gathered.count - headerEnd.upperBound >= length { break }
        }
        let header = [
            "HTTP/1.1 307 Temporary Redirect",
            "Location: http://127.0.0.1:1/stolen",
            "Content-Length: 0",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        let response = Array(header.utf8)
        var written = 0
        response.withUnsafeBytes { raw in
            while written < response.count {
                let n = write(client, raw.baseAddress?.advanced(by: written), response.count - written)
                if n <= 0 { break }
                written += n
            }
        }
    }

    private static func contentLength(in headerText: String) -> Int {
        for line in headerText.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = "Content-Length:"
            guard trimmed.lowercased().hasPrefix(prefix.lowercased()) else { continue }
            return Int(trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)) ?? 0
        }
        return 0
    }
}

private struct RedirectSinkError: Error {}

@Suite("rv audit forward --install")
struct AuditForwardInstallTests {
    final class Home {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rv-install-\(UUID().uuidString)")
        deinit { try? FileManager.default.removeItem(at: url) }
    }

    private func plan(_ arguments: [String] = [], home: Home) -> AuditForwardInstall.Plan {
        AuditForwardInstall.Plan(
            home: home.url, rvExecutable: "/usr/local/bin/rv", userID: 501, userName: "alice", forwardArguments: arguments)
    }

    private func plist(_ data: Data) throws -> [String: Any] {
        try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test func writesAUserAgentEveryFiveMinutesAndPrintsTheDaemonTemplate() throws {
        let home = Home()
        let plan = plan(["--to", "https://siem.example.com/rv", "--header", "Authorization=Bearer ${secret:SIEM}"], home: home)
        let text = try AuditForwardInstall.install(plan).get()

        let agentURL = home.url.appendingPathComponent("Library/LaunchAgents/dev.rv.audit-forward.plist")
        let agent = try plist(try Data(contentsOf: agentURL))
        #expect(agent["Label"] as? String == "dev.rv.audit-forward")
        #expect(agent["StartInterval"] as? Int == 300)
        #expect(agent["RunAtLoad"] as? Bool == true)
        #expect(agent["ProgramArguments"] as? [String] == [
            "/usr/local/bin/rv", "audit", "forward", "--to", "https://siem.example.com/rv",
            "--header", "Authorization=Bearer ${secret:SIEM}",
        ])
        #expect(agent["StandardErrorPath"] as? String == home.url.path + "/.config/rv/audit-forward/launchd.log")
        var info = stat()
        #expect(stat(agentURL.path, &info) == 0 && info.st_mode & 0o022 == 0)

        #expect(text.contains("wrote \(agentURL.path)"))
        #expect(text.contains("launchctl bootstrap gui/501 \(AuditForwardInstall.shellQuote(agentURL.path))"))
        #expect(text.contains("<key>UserName</key>\n\t<string>alice</string>"))
        #expect(text.contains(
            "sudo launchctl bootstrap system \(AuditForwardInstall.shellQuote("/Library/LaunchDaemons/dev.rv.audit-forward.alice.plist"))"))

        let daemon = try plist(AuditForwardInstall.daemonPlist(plan))
        #expect(daemon["Label"] as? String == "dev.rv.audit-forward.alice")
        #expect(daemon["UserName"] as? String == "alice")
        #expect((daemon["EnvironmentVariables"] as? [String: String])?["HOME"] == home.url.path)
        #expect(daemon["ProgramArguments"] as? [String] == agent["ProgramArguments"] as? [String])
    }

    @Test func refusesPlaintextHeadersSoThePlistHoldsNoCredential() {
        let home = Home()
        let result = AuditForwardInstall.install(plan(["--header", "Authorization=Bearer abc123"], home: home))
        guard case .failure(let failure) = result else {
            Issue.record("a plaintext header must be refused")
            return
        }
        #expect(failure.message.contains("${secret:NAME}"))
        #expect(failure.message.contains("abc123") == false)
        #expect(FileManager.default.fileExists(atPath: home.url.appendingPathComponent("Library").path) == false)

        let mixed = AuditForwardInstall.install(
            plan(["--header", "Authorization=Bearer real-token ${secret:PLACEHOLDER}"], home: home))
        guard case .failure(let mixedFailure) = mixed else {
            Issue.record("a literal beside a secret reference must be refused")
            return
        }
        #expect(mixedFailure.message.contains("${secret:NAME}"))
        #expect(mixedFailure.message.contains("real-token") == false)
        #expect(FileManager.default.fileExists(atPath: home.url.appendingPathComponent("Library").path) == false)

        let pathSecret = "ghp_1234567890abcdefghij"
        let nestedSecret = "supersecretpassword"
        for text in [
            "https://siem.example/ingest/\(pathSecret)",
            "https://siem.example/ingest#\(pathSecret)",
            "https://siem.example/hook?next=https://user:\(nestedSecret)@collector.example",
        ] {
            let installed = AuditForwardInstall.install(plan(["--to", text], home: home))
            guard case .failure(let failure) = installed else {
                Issue.record("install must refuse a secret destination")
                continue
            }
            #expect(failure.message.contains(pathSecret) == false)
            #expect(failure.message.contains(nestedSecret) == false)
            #expect(failure.message.contains("user:\(nestedSecret)") == false)
        }
        #expect(FileManager.default.fileExists(atPath: home.url.appendingPathComponent("Library").path) == false)
    }

    @Test func shellMetacharactersInTheAccountNameAreQuoted() throws {
        let home = Home()
        var hostile = plan(["--to", "https://siem.example.com/rv"], home: home)
        hostile.userName = "alice';touch /tmp/pwned"
        let text = try AuditForwardInstall.install(hostile).get()
        let path = "/Library/LaunchDaemons/dev.rv.audit-forward.alice';touch /tmp/pwned.plist"
        #expect(text.contains("sudo launchctl bootstrap system \(AuditForwardInstall.shellQuote(path))"))
        #expect(text.contains("sudo launchctl bootstrap system \(path)") == false)
        let saved = ProcessInfo.processInfo.environment["USER"]
        setenv("USER", "alice;rm -rf /", 1)
        defer { if let saved { setenv("USER", saved, 1) } else { unsetenv("USER") } }
        #expect(AuditForwardInstall.accountName() != "alice;rm -rf /")
        #expect(AuditForwardInstall.accountName()?.isEmpty == false)
    }

    @Test func linuxGetsACronLineInsteadOfAnInstall() {
        let text = AuditForwardInstall.cronHint(plan(["--to", "https://siem.example.com/rv"], home: Home()))
        #expect(text.contains("*/5 * * * * '/usr/local/bin/rv' 'audit' 'forward' '--to' 'https://siem.example.com/rv'"))
    }
}
