#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
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
/// insertions, and reordering that do not recompute every later `prev`
/// break it; cutting lines off the end does not, which is why the head is
/// forwarded off the machine. The chain is unkeyed: anyone who can write
/// the file can recompute it, so local verification catches careless and
/// partial tampering — the off-machine head is what anchors trust.
public enum AuditChain {
    public static let genesis = String(repeating: "0", count: 64)
    /// A line longer than this is a break, not a line to buffer whole.
    public static let maximumLineBytes = 1 << 20

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

    /// Streams the file; a missing file is an empty, intact chain. The open
    /// refuses symlinks and non-regular files: a verifier that can be
    /// pointed at a FIFO or a device is a verifier that can be hung.
    public static func verify(fileURL: URL) -> Result<AuditChainReport, AuditChainError> {
        let fd = open(fileURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            return errno == ENOENT
                ? .success(verify(Data()))
                : .failure(AuditChainError("cannot read \(fileURL.path)"))
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            return .failure(AuditChainError("cannot read \(fileURL.path)"))
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
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
                if pending.count > maximumLineBytes {
                    verifier.refuseOversizedLine()
                    return .success(verifier.report)
                }
            }
        } catch {
            return .failure(AuditChainError("cannot read \(fileURL.path)"))
        }
        if pending.isEmpty == false { verifier.consume(pending) }
        return .success(verifier.report)
    }

    /// Hash of the file's last line, or nil when there is no line yet.
    public static func head(fileURL: URL) -> String? {
        guard case .success(let report) = verify(fileURL: fileURL), report.lines > 0, report.isIntact else { return nil }
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

        mutating func refuseOversizedLine() {
            lines += 1
            if firstBreak == nil {
                firstBreak = .init(line: lines, reason: "line larger than \(AuditChain.maximumLineBytes) bytes")
            }
        }

        mutating func consume(_ line: Data) {
            lines += 1
            let expected = lines == 1 ? AuditChain.genesis : previous
            previous = RVDigest.sha256Hex([UInt8](line))
            guard firstBreak == nil else { return }
            if line.count > AuditChain.maximumLineBytes {
                firstBreak = .init(line: lines, reason: "line larger than \(AuditChain.maximumLineBytes) bytes")
                return
            }
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                firstBreak = .init(line: lines, reason: "not a JSON object")
                return
            }
            // JSONSerialization keeps the last of duplicate keys; a stricter
            // downstream parser would read the line differently (a fork).
            if AuditChain.hasDuplicateTopLevelKey(line) {
                firstBreak = .init(line: lines, reason: "duplicate key")
                return
            }
            guard let rawPrev = object["prev"] else {
                if started {
                    firstBreak = .init(line: lines, reason: "no prev after the chain started")
                } else {
                    unchained += 1
                }
                return
            }
            guard let prev = rawPrev as? String else {
                firstBreak = .init(line: lines, reason: "prev is not a string")
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

    /// True when a JSON object line repeats a top-level key. Keys are
    /// compared after unescaping, so `"prev"` and `"\u0070rev"` collide.
    static func hasDuplicateTopLevelKey(_ line: Data) -> Bool {
        let bytes = [UInt8](line)
        var index = 0
        var depth = 0
        var keys = Set<String>()
        var expectingKey = false
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "\""):
                guard let (value, next) = jsonString(bytes, from: index) else { return false }
                if depth == 1, expectingKey {
                    if keys.insert(value).inserted == false { return true }
                    expectingKey = false
                }
                index = next
                continue
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                depth += 1
                if depth == 1 { expectingKey = true }
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth -= 1
            case UInt8(ascii: ","):
                if depth == 1 { expectingKey = true }
            default:
                break
            }
            index += 1
        }
        return false
    }

    /// The JSON string at `start` (a quote), and the index just past its
    /// closing quote. Nil when unterminated or malformed.
    private static func jsonString(_ bytes: [UInt8], from start: Int) -> (String, Int)? {
        var index = start + 1
        var output = ""
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") { return (output, index + 1) }
            if byte == UInt8(ascii: "\\") {
                guard index + 1 < bytes.count else { return nil }
                let escaped = bytes[index + 1]
                switch escaped {
                case UInt8(ascii: "u"):
                    // Combine surrogate pairs; a lone or malformed escape
                    // decodes deterministically to U+FFFD so key comparison
                    // never bails open on valid JSON.
                    func hex4(_ at: Int) -> UInt32? {
                        guard at + 3 < bytes.count,
                            let hex = String(bytes: bytes[at...(at + 3)], encoding: .utf8)
                        else { return nil }
                        return UInt32(hex, radix: 16)
                    }
                    guard let first = hex4(index + 2) else {
                        output.unicodeScalars.append("\u{FFFD}")
                        index += 2
                        continue
                    }
                    index += 6
                    if (0xD800...0xDBFF).contains(first),
                        index + 5 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u"),
                        let second = hex4(index + 2), (0xDC00...0xDFFF).contains(second),
                        let scalar = Unicode.Scalar(0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00))
                    {
                        output.unicodeScalars.append(scalar)
                        index += 6
                    } else if let scalar = Unicode.Scalar(first) {
                        output.unicodeScalars.append(scalar)
                    } else {
                        output.unicodeScalars.append("\u{FFFD}")
                    }
                case UInt8(ascii: "n"): output += "\n"; index += 2
                case UInt8(ascii: "r"): output += "\r"; index += 2
                case UInt8(ascii: "t"): output += "\t"; index += 2
                case UInt8(ascii: "b"): output += "\u{08}"; index += 2
                case UInt8(ascii: "f"): output += "\u{0C}"; index += 2
                default:
                    output += String(decoding: [escaped], as: UTF8.self)
                    index += 2
                }
                continue
            }
            // Copy one UTF-8 sequence verbatim.
            let width = byte < 0x80 ? 1 : byte < 0xE0 ? 2 : byte < 0xF0 ? 3 : 4
            guard index + width <= bytes.count else { return nil }
            output += String(decoding: bytes[index..<(index + width)], as: UTF8.self)
            index += width
        }
        return nil
    }
}

public struct AuditChainError: Error, Sendable, Equatable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }
}
