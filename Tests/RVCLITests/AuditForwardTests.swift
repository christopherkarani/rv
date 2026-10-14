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

        let sentence = "ok: every MCP server is governed by rv, allowed direct, or disabled"
        let raw = "\u{1B}[2J\u{1B}[H" + sentence + "\u{2028}" + sentence + "\u{202E}" + sentence
        guard case .failure(let header) = AuditForwardRun.parseHeaders([raw]) else {
            Issue.record("header without '=' was accepted")
            return
        }
        #expect(header.message.unicodeScalars.contains { $0.value == 0x1B } == false)
        #expect(header.message.unicodeScalars.contains { $0.value == 0x2028 } == false)
        #expect(header.message.unicodeScalars.contains { $0.value == 0x202E } == false)
        #expect(header.message.contains("got "))
        #expect(header.message.contains("\\u001b[2J"))
        #expect(header.message.contains("\\u2028"))
        #expect(header.message.contains("\\u202e"))
        #expect(header.message.contains("\\\\u001b") == false)
        guard case .failure(let secret) = AuditForwardRun.resolveHeaders(
            ["A": "${secret:\(raw)}"], secrets: { .success(secrets) }, resolver: resolver)
        else {
            Issue.record("unknown header secret was accepted")
            return
        }
        #expect(secret.message.unicodeScalars.contains { $0.value == 0x1B } == false)
        #expect(secret.message.unicodeScalars.contains { $0.value == 0x2028 } == false)
        #expect(secret.message.unicodeScalars.contains { $0.value == 0x202E } == false)
        #expect(secret.message.contains("header secret "))
        #expect(secret.message.contains("\\u001b[2J"))
        #expect(secret.message.contains("\\u202e"))
        #expect(secret.message.contains("\\\\u001b") == false)
    }

    @Test func cursorPathEscapesControlsFromHome() throws {
        let sentence = "ok: every MCP server is governed by rv, allowed direct, or disabled"
        let home = URL(fileURLWithPath: "/tmp/h\u{1B}[2J\u{1B}[H\u{2028}\(sentence)\u{202E}\(sentence)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent(".config/rv", isDirectory: true)
        let url = try AuditForwardRun.destination("https://example.com").get()
        let cursor = AuditForwardRun.cursorURL(config, destination: url)
        try FileManager.default.createDirectory(at: cursor.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not-a-cursor".utf8).write(to: cursor)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cursor.path)

        let receiver = Receiver()
        let failed = AuditForwardRun.forward(
            options: AuditForwardRun.Options(url: url), configDirectory: config, hostName: "h", transport: receiver.transport)
        guard case .failure(let failure) = failed else {
            Issue.record("a non-cursor file must fail")
            return
        }
        func spelled(_ text: String) {
            #expect(text.unicodeScalars.contains { $0.value == 0x1B } == false)
            #expect(text.unicodeScalars.contains { $0.value == 0x2028 } == false)
            #expect(text.unicodeScalars.contains { $0.value == 0x202E } == false)
            #expect(text.contains("\\u001b[2J"))
            #expect(text.contains("\\u2028"))
            #expect(text.contains("\\u202e"))
            #expect(text.contains("\\\\u001b") == false)
            let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\u{2028}" || $0 == "\u{2029}" }).map(String.init)
            #expect(lines.contains(sentence) == false)
        }
        #expect(failure.message.contains("is not a forward cursor"))
        spelled(failure.message)

        try FileManager.default.removeItem(at: cursor)
        try FileManager.default.createDirectory(at: cursor, withIntermediateDirectories: true)
        let blocked = AuditForwardRun.startFromNow(options: AuditForwardRun.Options(url: url), configDirectory: config)
        guard case .failure(let write) = blocked else {
            Issue.record("a directory at the cursor path must fail")
            return
        }
        #expect(write.message.contains("could not write "))
        spelled(write.message)
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
