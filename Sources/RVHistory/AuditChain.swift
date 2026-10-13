import Foundation
import RVDomain

public struct AuditChainReport: Sendable, Equatable, Encodable {
    public struct Break: Sendable, Equatable, Encodable {
        public var line: Int
        public var reason: String

        public init(line: Int, reason: String) {
            self.line = line
            self.reason = reason
        }
    }

    public var lines: Int
    /// Lines before the first one with `prev` (written before the chain existed).
    public var unchained: Int
    /// SHA-256 of the last line: the `prev` the next append will carry.
    public var head: String
    public var firstBreak: Break?

    public var isIntact: Bool { firstBreak == nil }

    public init(lines: Int, unchained: Int, head: String, firstBreak: Break?) {
        self.lines = lines
        self.unchained = unchained
        self.head = head
        self.firstBreak = firstBreak
    }
}

/// `audit.jsonl` as a hash chain: line N's `prev` is the SHA-256 of line
/// N-1's bytes, and the first line's is 64 zeros. Edits, deletions,
/// insertions, and reordering break it; cutting lines off the end does not,
/// which is why the head is forwarded off the machine.
public enum AuditChain {
    public static let genesis = String(repeating: "0", count: 64)

    public static func verify(_ data: Data) -> AuditChainReport {
        var verifier = Verifier()
        var start = data.startIndex
        while let newline = data[start...].firstIndex(of: UInt8(ascii: "\n")) {
            verifier.consume(data[start..<newline])
            start = data.index(after: newline)
        }
        if start < data.endIndex { verifier.consume(data[start...]) }
        return verifier.report
    }

    /// Streams the file; a missing file is an empty, intact chain.
    public static func verify(fileURL: URL) -> Result<AuditChainReport, AuditChainError> {
        guard let handle = FileHandle(forReadingAtPath: fileURL.path) else {
            return FileManager.default.fileExists(atPath: fileURL.path)
                ? .failure(AuditChainError("cannot read \(fileURL.path)"))
                : .success(verify(Data()))
        }
        defer { try? handle.close() }
        var verifier = Verifier()
        var pending = Data()
        do {
            while let chunk = try handle.read(upToCount: 1 << 20), chunk.isEmpty == false {
                pending.append(chunk)
                var start = pending.startIndex
                while let newline = pending[start...].firstIndex(of: UInt8(ascii: "\n")) {
                    verifier.consume(pending[start..<newline])
                    start = pending.index(after: newline)
                }
                pending = Data(pending[start...])
            }
        } catch {
            return .failure(AuditChainError("cannot read \(fileURL.path)"))
        }
        if pending.isEmpty == false { verifier.consume(pending) }
        return .success(verifier.report)
    }

    /// Hash of the file's last line, or nil when there is no line yet.
    public static func head(fileURL: URL) -> String? {
        guard case .success(let report) = verify(fileURL: fileURL), report.lines > 0 else { return nil }
        return report.head
    }

    struct Verifier {
        private(set) var lines = 0
        private var unchained = 0
        private var started = false
        private var previous = AuditChain.genesis
        private var firstBreak: AuditChainReport.Break?

        var report: AuditChainReport {
            let stripped = lines > 0 && started == false && firstBreak == nil
                ? AuditChainReport.Break(line: 1, reason: "no prev on any line")
                : firstBreak
            return AuditChainReport(lines: lines, unchained: unchained, head: previous, firstBreak: stripped)
        }

        mutating func consume(_ line: Data) {
            lines += 1
            let expected = lines == 1 ? AuditChain.genesis : previous
            previous = RVDigest.sha256Hex([UInt8](line))
            guard firstBreak == nil else { return }
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                firstBreak = .init(line: lines, reason: "not a JSON object")
                return
            }
            guard let prev = object["prev"] as? String else {
                if started {
                    firstBreak = .init(line: lines, reason: "no prev after the chain started")
                } else {
                    unchained += 1
                }
                return
            }
            started = true
            if prev != expected {
                firstBreak = .init(
                    line: lines,
                    reason: lines == 1 ? "prev is not the start of the chain" : "prev does not match line \(lines - 1)")
            }
        }
    }
}

public struct AuditChainError: Error, Sendable, Equatable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }
}
