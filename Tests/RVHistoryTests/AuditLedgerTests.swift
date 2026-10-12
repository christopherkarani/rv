import Foundation
import Testing
@testable import RVHistory

/// Fixture lines copy the exact shapes each production writer emits.
private enum Lines {
    static let block =
        #"{"category":"core.git","host":"claude","path":"","rule_id":"core.git:reset-hard","timestamp":"2026-10-12T17:00:16Z","tool":"Bash"}"#
    static let ttyBlock =
        #"{"category":"core.git","host":"tty","path":"","rule_id":"core.git:reset-hard","timestamp":"2026-10-12T17:00:20Z","tool":"Bash"}"#
    static let egress =
        #"{"host":"evil.example","port":"443","reason":"denied-policy","recordedAt":"1791826700.5"}"#
    static let admission =
        #"{"authorization":"denied","executionAttempted":false,"httpDestination":"https://api.example.com/","httpMethod":"GET","recordedAt":1791826701,"result":"denied","session":"R1","workspace":"W1"}"#
    static let legacyAdmission =
        #"{"authorization":"allowed","executionAttempted":true,"result":"executed:0","session":"R1"}"#
    static let workspaceStarted =
        #"{"disk":"\/dev\/disk136s1","kind":"runtimeStarted","originalPath":"\/repo","processGroup":91274,"protectedPath":"\/repo","recordedAt":1791826702.25,"runtime":"R1","volumeDevice":1,"workspace":"W1"}"#
    static let workspaceBlocked =
        #"{"blockReason":"busy","kind":"recoveryBlocked","originalPath":"\/repo","protectedPath":"\/repo","recordedAt":1791826703,"workspace":"W1"}"#
    static let runtimeSession =
        #"{"backend":"seatbelt","id":"R1","startedAt":1791826704,"workspace":"\/repo","workspaceSession":"W1"}"#
    static let agentRefused =
        #"{"assurance":"verified","definition":"claude","detail":"refused:permit","instance":"I1","kind":"finished","ownerUID":501,"recordedAt":1791826705,"revision":"r1","runtime":"R1","workspace":"W1"}"#
}

struct AuditLedgerTests {
    @Test func blocksLineMapsToCommandDenied() throws {
        let event = try #require(AuditLedger.event(fromLine: Substring(Lines.block), source: .blocks))
        #expect(event.kind == .commandDenied)
        #expect(event.decision == .denied)
        #expect(event.subject == "core.git:reset-hard")
        #expect(event.agent == "claude")
        #expect(event.detail["tool"] == "Bash")
        #expect(event.detail["path"] == nil)
        #expect(event.time == ISO8601DateFormatter().date(from: "2026-10-12T17:00:16Z"))
    }

    @Test func ttyBlockHasNoAgent() throws {
        let event = try #require(AuditLedger.event(fromLine: Substring(Lines.ttyBlock), source: .blocks))
        #expect(event.agent == nil)
        #expect(event.detail["host"] == "tty")
    }

    @Test func egressDenialMapsHostPortAndReason() throws {
        let event = try #require(AuditLedger.event(fromLine: Substring(Lines.egress), source: .egressDenials))
        #expect(event.kind == .egressDenied)
        #expect(event.subject == "evil.example:443")
        #expect(event.reason == "denied-policy")
        #expect(event.time == Date(timeIntervalSince1970: 1_791_826_700.5))
    }

    @Test func admissionMapsDecisionDestinationAndBooleans() throws {
        let event = try #require(AuditLedger.event(fromLine: Substring(Lines.admission), source: .runtimeAdmission))
        #expect(event.kind == .admission)
        #expect(event.decision == .denied)
        #expect(event.subject == "https://api.example.com/")
        #expect(event.runtime == "R1")
        #expect(event.workspace == "W1")
        #expect(event.detail["executionAttempted"] == "false")
        #expect(event.detail["method"] == "GET")
        #expect(event.detail["timeUnknown"] == nil)
    }

    @Test func admissionWithoutTimestampIsKeptAndMarked() throws {
        let event = try #require(
            AuditLedger.event(fromLine: Substring(Lines.legacyAdmission), source: .runtimeAdmission))
        #expect(event.decision == .allowed)
        #expect(event.detail["timeUnknown"] == "true")
        #expect(event.time == Date(timeIntervalSince1970: 0))
    }

    @Test func workspaceLifecycleMapsRuntimeAndBlockedRecovery() throws {
        let started = try #require(
            AuditLedger.event(fromLine: Substring(Lines.workspaceStarted), source: .workspaceSessions))
        #expect(started.kind == .runtimeStarted)
        #expect(started.decision == .info)
        #expect(started.detail["processGroup"] == "91274")
        let blocked = try #require(
            AuditLedger.event(fromLine: Substring(Lines.workspaceBlocked), source: .workspaceSessions))
        #expect(blocked.kind.rawValue == "workspace.recoveryBlocked")
        #expect(blocked.decision == .failed)
        #expect(blocked.reason == "busy")
    }

    @Test func runtimeSessionAndAgentInstanceMap() throws {
        let session = try #require(
            AuditLedger.event(fromLine: Substring(Lines.runtimeSession), source: .runtimeSessions))
        #expect(session.kind == .runtimeSession)
        #expect(session.runtime == "R1")
        #expect(session.detail["backend"] == "seatbelt")
        let agent = try #require(
            AuditLedger.event(fromLine: Substring(Lines.agentRefused), source: .agentInstances))
        #expect(agent.kind.rawValue == "agent.finished")
        #expect(agent.decision == .denied)
        #expect(agent.agent == "claude")
        #expect(agent.reason == "refused:permit")
    }

    @Test(arguments: [
        ("", AuditLedger.Source.blocks),
        ("not json", .egressDenials),
        (#"{"host":"x"}"#, .egressDenials),
        (#"["array"]"#, .workspaceSessions),
        (#"{"kind":"closed"}"#, .workspaceSessions),
        (#"{"schema":"rv.audit.v1"}"#, .audit),
    ])
    func unreadableLinesAreSkipped(line: String, source: AuditLedger.Source) {
        #expect(AuditLedger.event(fromLine: Substring(line), source: source) == nil)
    }

    @Test func mergesAllLedgersByTimeAndFilters() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write([Lines.egress, "garbage"], to: dir, source: .egressDenials)
        try write([Lines.admission], to: dir, source: .runtimeAdmission)
        try write([Lines.workspaceStarted, Lines.workspaceBlocked], to: dir, source: .workspaceSessions)
        try write([Lines.runtimeSession], to: dir, source: .runtimeSessions)
        try write([Lines.agentRefused], to: dir, source: .agentInstances)
        try write([Lines.block], to: dir, source: .blocks)

        let ledger = AuditLedger(configDirectory: dir)
        let all = ledger.events()
        #expect(all.count == 7)
        #expect(all == all.sorted { $0.time < $1.time })
        #expect(all.map(\.source).contains("blocks.jsonl"))

        let egress = ledger.events(AuditFilter(kinds: ["egress"]))
        #expect(egress.map(\.subject) == ["evil.example:443"])

        let runtime = ledger.events(AuditFilter(kinds: ["runtime"]))
        #expect(Set(runtime.map(\.kind)) == [.runtimeStarted, .runtimeSession])

        let recent = ledger.events(AuditFilter(since: Date(timeIntervalSince1970: 1_791_826_703)))
        #expect(recent.allSatisfy { $0.time >= Date(timeIntervalSince1970: 1_791_826_703) })
        #expect(recent.count == 3)
        #expect(all.first?.kind == .commandDenied)

        let newest = ledger.events(AuditFilter(limit: 2))
        #expect(newest == Array(all.suffix(2)))
    }

    @Test func kindPrefixDoesNotMatchPartialWords() {
        #expect(AuditEventKind.egressDenied.matches("egress"))
        #expect(AuditEventKind.egressDenied.matches("egress.denied"))
        #expect(AuditEventKind.egressDenied.matches("egr") == false)
        #expect(AuditEventKind.admission.matches("admission.x") == false)
    }

    @Test func nativeWriterRoundTripsThroughTheLedger() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let event = AuditEvent(
            time: Date(timeIntervalSince1970: 1_791_900_000),
            kind: .secretUse,
            decision: .allowed,
            subject: "STRIPE_SECRET_KEY",
            runtime: "R9",
            source: AuditLedger.Source.audit.rawValue,
            detail: ["upstream": "api.stripe.com", "fingerprint": "0123456789abcdef"]
        )
        #expect(AuditLog.append(event, configDirectory: dir))
        #expect(AuditLog.append(event, configDirectory: dir))
        let read = AuditLedger(configDirectory: dir).events(AuditFilter(kinds: ["secret"]))
        #expect(read == [event, event])

        let attributes = try FileManager.default.attributesOfItem(
            atPath: AuditLog.fileURL(configDirectory: dir).path)
        let mode = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(mode.intValue & 0o777 == 0o600)
    }

    @Test func oversizedLedgerKeepsOnlyCompleteNewestLines() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(AuditLedger.Source.egressDenials.rawValue)
        var text = ""
        var index = 0
        while text.utf8.count <= AuditLedger.maxBytesPerSource + 4_096 {
            text += #"{"host":"h\#(index).example","port":"443","reason":"denied-policy","recordedAt":"\#(1_791_000_000 + index)"}"# + "\n"
            index += 1
        }
        try Data(text.utf8).write(to: url)
        let events = AuditLedger(configDirectory: dir).events()
        #expect(events.isEmpty == false)
        #expect(events.count < index)
        #expect(events.last?.subject == "h\(index - 1).example:443")
        #expect(events.allSatisfy { $0.subject.hasPrefix("h") })
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-audit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ lines: [String], to dir: URL, source: AuditLedger.Source) throws {
        let text = lines.joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: dir.appendingPathComponent(source.rawValue))
    }
}
