#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain

/// Read-side join of every append-only rv ledger into `AuditEvent`s.
///
/// Each ledger keeps its own writer and format; this maps lines as they are
/// and skips lines it cannot read, so an older or newer writer never hides
/// the rest of the history.
public struct AuditLedger: Sendable {
    public enum Source: String, Sendable, CaseIterable {
        case audit = "audit.jsonl"
        case blocks = "blocks.jsonl"
        case egressDenials = "egress-denials.jsonl"
        case runtimeAdmission = "runtime-admission.jsonl"
        case workspaceSessions = "workspace-sessions.jsonl"
        case runtimeSessions = "runtime-sessions.jsonl"
        case agentInstances = "agent-instances.jsonl"
    }

    /// Per-file read cap; larger files contribute their newest lines.
    public static let maxBytesPerSource = 16 * 1024 * 1024

    public let configDirectory: URL

    public init(configDirectory: URL) {
        self.configDirectory = configDirectory
    }

    /// Matching events, oldest first. `limit` keeps the newest N.
    public func events(_ filter: AuditFilter = AuditFilter()) -> [AuditEvent] {
        var merged: [AuditEvent] = []
        for source in Source.allCases {
            let url = configDirectory.appendingPathComponent(source.rawValue, isDirectory: false)
            for line in Self.tailLines(of: url) {
                guard let event = Self.event(fromLine: line, source: source),
                    filter.admits(event)
                else { continue }
                merged.append(event)
            }
        }
        merged.sort { $0.time < $1.time }
        if let limit = filter.limit, limit >= 0, merged.count > limit {
            return Array(merged.suffix(limit))
        }
        return merged
    }

    public static func event(fromLine line: Substring, source: Source) -> AuditEvent? {
        guard let data = line.data(using: .utf8), data.isEmpty == false else { return nil }
        if source == .audit {
            var event = try? decoder.decode(AuditEvent.self, from: data)
            event?.chainHead = RVDigest.sha256Hex([UInt8](data))
            return event
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let fields = Fields(object)
        switch source {
        case .audit:
            return nil
        case .blocks:
            return blocks(fields, source: source)
        case .egressDenials:
            return egressDenial(fields, source: source)
        case .runtimeAdmission:
            return admission(fields, source: source)
        case .workspaceSessions:
            return workspaceLifecycle(fields, source: source)
        case .runtimeSessions:
            return runtimeSession(fields, source: source)
        case .agentInstances:
            return agentInstance(fields, source: source)
        }
    }

    // MARK: - Ledger mappings

    private static func blocks(_ f: Fields, source: Source) -> AuditEvent? {
        guard let time = f.isoDate("timestamp"), let rule = f.string("rule_id") else { return nil }
        let host = f.string("host")
        return AuditEvent(
            time: time,
            kind: .commandDenied,
            decision: .denied,
            subject: rule,
            agent: host == "tty" ? nil : host,
            source: source.rawValue,
            detail: f.compact(["tool": "tool", "host": "host", "category": "category", "path": "path"])
        )
    }

    private static func egressDenial(_ f: Fields, source: Source) -> AuditEvent? {
        guard let time = f.epochDate("recordedAt"), let host = f.string("host") else { return nil }
        let port = f.string("port").map { ":\($0)" } ?? ""
        return AuditEvent(
            time: time,
            kind: .egressDenied,
            decision: .denied,
            subject: host + port,
            reason: f.string("reason"),
            source: source.rawValue
        )
    }

    private static func admission(_ f: Fields, source: Source) -> AuditEvent? {
        guard let authorization = f.string("authorization") else { return nil }
        let decision: AuditDecision
        switch authorization {
        case "allowed": decision = .allowed
        case "pending": decision = .pending
        case "denied", "rejected": decision = .denied
        default: decision = .failed
        }
        var detail = f.compact([
            "authorization": "authorization",
            "method": "httpMethod",
            "status": "httpStatus",
            "executionAttempted": "executionAttempted",
            "agentInstance": "agentInstance",
            "requestID": "requestID",
        ])
        let time = f.epochDate("recordedAt")
        if time == nil { detail["timeUnknown"] = "true" }
        return AuditEvent(
            time: time ?? Date(timeIntervalSince1970: 0),
            kind: .admission,
            decision: decision,
            subject: f.string("httpDestination") ?? f.string("fingerprint") ?? "action",
            reason: f.string("result"),
            workspace: f.string("workspace"),
            runtime: f.string("session"),
            agent: f.string("agentDefinition"),
            source: source.rawValue,
            detail: detail
        )
    }

    private static func workspaceLifecycle(_ f: Fields, source: Source) -> AuditEvent? {
        guard let time = f.epochDate("recordedAt"), let phase = f.string("kind") else { return nil }
        let kind: AuditEventKind
        switch phase {
        case "runtimeStarted": kind = .runtimeStarted
        case "runtimeEnded": kind = .runtimeEnded
        default: kind = .workspace(phase)
        }
        let blocked = f.string("blockReason")
        return AuditEvent(
            time: time,
            kind: kind,
            decision: blocked == nil ? .info : .failed,
            subject: f.string("originalPath") ?? "workspace",
            reason: blocked,
            workspace: f.string("workspace"),
            runtime: f.string("runtime"),
            source: source.rawValue,
            detail: f.compact(["disk": "disk", "processGroup": "processGroup", "host": "host"])
        )
    }

    private static func runtimeSession(_ f: Fields, source: Source) -> AuditEvent? {
        guard let time = f.epochDate("startedAt"), let id = f.string("id") else { return nil }
        return AuditEvent(
            time: time,
            kind: .runtimeSession,
            decision: .info,
            subject: f.string("workspace") ?? "runtime",
            workspace: f.string("workspaceSession"),
            runtime: id,
            source: source.rawValue,
            detail: f.compact(["backend": "backend", "host": "host"])
        )
    }

    private static func agentInstance(_ f: Fields, source: Source) -> AuditEvent? {
        guard let time = f.epochDate("recordedAt"), let phase = f.string("kind"),
            let definition = f.string("definition")
        else { return nil }
        let outcome = f.string("detail")
        let decision: AuditDecision =
            outcome.map { $0.hasPrefix("refused") ? .denied : .info } ?? .info
        return AuditEvent(
            time: time,
            kind: .agent(phase),
            decision: decision,
            subject: definition,
            reason: outcome,
            workspace: f.string("workspace"),
            runtime: f.string("runtime"),
            agent: definition,
            source: source.rawValue,
            detail: f.compact([
                "instance": "instance", "revision": "revision",
                "assurance": "assurance", "parent": "parent",
            ])
        )
    }

    // MARK: - IO

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func tailLines(of url: URL) -> [Substring] {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return [] }
        let size = Int(info.st_size)
        let start = max(0, size - maxBytesPerSource)
        guard lseek(fd, off_t(start), SEEK_SET) >= 0 else { return [] }
        var bytes = [UInt8](repeating: 0, count: size - start)
        var filled = 0
        while filled < bytes.count {
            let n = bytes.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return read(fd, base + filled, raw.count - filled)
            }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { break }
            filled += n
        }
        let text = String(decoding: bytes.prefix(filled), as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if start > 0, lines.isEmpty == false {
            lines.removeFirst()
        }
        return lines
    }
}

/// Loosely typed view of one JSON object line.
private struct Fields {
    let object: [String: Any]

    init(_ object: [String: Any]) {
        self.object = object
    }

    func string(_ key: String) -> String? {
        switch object[key] {
        case let value as String:
            return value.isEmpty ? nil : value
        case let value as NSNumber:
            return String(cString: value.objCType) == "c"
                ? (value.boolValue ? "true" : "false") : value.stringValue
        default:
            return nil
        }
    }

    func epochDate(_ key: String) -> Date? {
        switch object[key] {
        case let value as NSNumber:
            return Date(timeIntervalSince1970: value.doubleValue)
        case let value as String:
            return Double(value).map(Date.init(timeIntervalSince1970:))
        default:
            return nil
        }
    }

    func isoDate(_ key: String) -> Date? {
        guard let text = string(key) else { return nil }
        return ISO8601DateFormatter().date(from: text)
    }

    /// `[outputKey: inputKey]` for the present, non-empty fields.
    func compact(_ mapping: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for (outputKey, inputKey) in mapping {
            if let value = string(inputKey) { out[outputKey] = value }
        }
        return out
    }
}
