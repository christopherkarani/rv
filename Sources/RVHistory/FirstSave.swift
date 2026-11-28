#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain

/// The counted receipt for a save: what the stop kept, measured when it
/// happened. Nil fields were not counted; rv never guesses them.
public struct FirstSaveReceipt: Sendable, Equatable, Codable {
    public var files: Int
    public var lines: Int?

    public init(files: Int, lines: Int? = nil) {
        self.files = files
        self.lines = lines
    }

    /// `kept 14 files · 2,314 lines`.
    public var text: String {
        var parts = ["kept \(Self.grouped(files)) \(files == 1 ? "file" : "files")"]
        if let lines { parts.append("\(Self.grouped(lines)) \(lines == 1 ? "line" : "lines")") }
        return parts.joined(separator: " · ")
    }

    /// `2,314`, in the same digits whatever the locale.
    static func grouped(_ value: Int) -> String {
        let digits = String(abs(value))
        var out = ""
        for (index, character) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { out.append(",") }
            out.append(character)
        }
        return value < 0 ? "-" + out : out
    }
}

/// The first time rv stepped in for real: a guarding stop by a pack rule.
/// Written once, by whichever rvd decision claims it first, so the
/// notification fires once and `rv log` stars that one row. Holds the
/// redacted command the decision log kept, never argv.
public struct FirstSaveRecord: Sendable, Equatable, Codable {
    public var time: Date
    /// The call's full id (12 hex digits): the one row `rv log` stars.
    public var id: String
    /// The row's code (`a7c-835`), as `rv log` prints it.
    public var code: String
    public var rule: String
    public var host: String
    /// The redacted command, or the tool and redacted path.
    public var what: String?
    public var receipt: FirstSaveReceipt?

    public init(
        time: Date, id: String, rule: String, host: String, what: String? = nil, receipt: FirstSaveReceipt? = nil
    ) {
        self.time = time
        self.id = id
        self.code = DecisionStamp.code(forID: id)
        self.rule = rule
        self.host = host
        self.what = what
        self.receipt = receipt
    }

    /// Whether `record` is a first save: a real stop (guarding denied it)
    /// by a pack rule. A judge note, a self-protection refusal, a command
    /// rv could not check and a watch-mode would-stop are not saves.
    public static func qualifies(_ record: DecisionRecord) -> Bool {
        guard record.verdict == .denied, record.id != nil, let rule = record.rule,
              let id = RuleID(rawValue: rule)
        else { return false }
        let pack = id.pack.rawValue
        return id.pack != .coreJudge && pack.hasPrefix("rv.") == false && pack != "observe.floor"
            && id.pattern != "home-rv-config"
    }

    /// The record for a qualifying decision row; nil for a row that does
    /// not qualify (`qualifies`).
    public init?(_ record: DecisionRecord) {
        guard Self.qualifies(record), let id = record.id else { return nil }
        // Rows arrive redacted; redacting again costs nothing and keeps a
        // secret out of this file even if one did not.
        let command = record.command.map { DecisionRedaction.command($0, home: nil) }
        let path = record.path.map { DecisionRedaction.path($0, home: nil) }
        let what = command ?? path.map { "\(record.tool.rawValue) \($0)" }
        self.init(time: record.time, id: id, rule: record.rule ?? "", host: record.host.rawValue, what: what)
    }

    /// `First save. rv stopped claude's git reset --hard and kept 14 files.`
    public var notificationText: String {
        var text = "First save. rv stopped \(host)'s \(what.map { Self.clipped($0) } ?? rule)"
        if let receipt { text += " and \(receipt.text.replacingOccurrences(of: " · ", with: ", "))" }
        return text + "."
    }

    static func clipped(_ text: String, max: Int = 60) -> String {
        text.count <= max ? text : String(text.prefix(max - 1)) + "…"
    }
}

/// `first-save.json` in rv's config directory: created once, never
/// overwritten. Only rvd writes it; `rv log` reads it.
public struct FirstSaveStore: Sendable {
    public let fileURL: URL

    public init(configDirectory: URL) {
        self.fileURL = configDirectory.appendingPathComponent("first-save.json")
    }

    public func load() -> FirstSaveRecord? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(FirstSaveRecord.self, from: data)
    }

    /// Writes `record` when no first save exists. True when this call made
    /// it, so exactly one caller notifies. The whole record goes to a
    /// private temp file first (owner-only, `O_EXCL | O_NOFOLLOW`), then
    /// `link(2)` puts it in place, which fails when a first save exists:
    /// a short write never leaves a partial file that blocks every later
    /// claim. The temp file is always removed.
    public func claim(_ record: FirstSaveRecord) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(record) else { return false }
        let temp = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".first-save.\(getpid()).\(UInt32.random(in: .min ... .max)).tmp").path
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return false }
        defer { unlink(temp) }
        let whole = Self.writeAll(data, to: fd) && fsync(fd) == 0
        guard close(fd) == 0, whole else { return false }
        return link(temp, fileURL.path) == 0
    }

    /// Writes every byte, retrying short writes and `EINTR`.
    static func writeAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return buffer.isEmpty }
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, base + offset, buffer.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }
}
