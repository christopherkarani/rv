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
    }
}
