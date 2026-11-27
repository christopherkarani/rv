import Foundation
import RVDomain
import RVFileStore
import Synchronization

/// What the door answered an agent.
public enum DecisionVerdict: String, Sendable, Equatable, Codable {
    /// The command or file action went ahead. Under observe this includes
    /// would-be denies; the chained `command.observed` event names those.
    case allowed
    /// A rule stopped it.
    case denied
    /// rv could not finish deciding (an indeterminate verdict) and refused.
    case refused
}

/// One decision the hook door made, as `decisions/<day>.jsonl` keeps it.
/// The command is redacted (`DecisionRedaction`); file actions carry only
/// their redacted path.
public struct DecisionRecord: Sendable, Equatable, Codable {
    public var time: Date
    public var verdict: DecisionVerdict
    public var host: LedgerHost
    public var tool: LedgerTool
    /// Shell only: the command after `DecisionRedaction.command`.
    public var command: String?
    /// File tools only: the path after `DecisionRedaction.path`.
    public var path: String?
    /// The working directory, home shown as `~`.
    public var cwd: String?
    /// The rule that denied or the `rv.indeterminate:` reason; nil for an allow.
    public var rule: String?
    /// The host's session id, when it is an opaque token
    /// (`DenialLedgerRecord.attributableSession`).
    public var session: String?
    /// The call's id (`DecisionStamp`), shared with its denial-ledger row.
    /// Nil on rows written before it existed.
    public var id: String?
    /// An allowed row that watch mode let run: what guarding would have
    /// done. Nil for every other row, and on rows written before it existed.
    public var wouldBe: DecisionWouldBe?

    enum CodingKeys: String, CodingKey {
        case time, verdict, host, tool, command, path, cwd, rule, session, id
        case wouldBe = "would_be"
    }

    public init(
        time: Date,
        verdict: DecisionVerdict,
        host: LedgerHost,
        tool: LedgerTool,
        command: String? = nil,
        path: String? = nil,
        cwd: String? = nil,
        rule: String? = nil,
        session: String? = nil,
        id: String? = nil,
        wouldBe: DecisionWouldBe? = nil
    ) {
        self.time = time
        self.verdict = verdict
        self.host = host
        self.tool = tool
        self.command = command
        self.path = path
        self.cwd = cwd
        self.rule = rule
        self.session = session
        self.id = id
        self.wouldBe = wouldBe
    }
}

/// How a decision row hides what it must not keep: credentials in the
/// forms a command line carries them (`CommandLineRedaction`: `KEY=value`,
/// token prefixes, `Bearer x`, URL userinfo, `-u name:pw`, `--password x`,
/// per-program password flags, secret-shaped headers), the home directory,
/// control characters, and anything past `maxCommandBytes`. rvd's live
/// events use the same recipe (`LiveEventRedaction`), and `rv log` runs it
/// again on read, so rows written by an older redactor are held to today's.
public enum DecisionRedaction {
    /// Longest command a row keeps, in UTF-8 bytes, before the ellipsis.
    public static let maxCommandBytes = 512
    /// Bytes of a command the redactor reads. Only `maxCommandBytes` are
    /// kept, so the rest is cut first, keeping the redactor cheap inside the
    /// hook-local evaluator's write budget.
    static let maxScannedBytes = 4 * maxCommandBytes

    public static func command(_ raw: String, home: HomePath?, maxBytes: Int = maxCommandBytes) -> String {
        let scanned = raw.utf8.count > maxScannedBytes ? cut(raw, bytes: maxScannedBytes) : raw
        let flattened = String(String.UnicodeScalarView(scanned.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? " " : $0
        }))
        let redacted = homeShown(in: CommandLineRedaction.redact(flattened), home: home)
        let shown = capped(redacted.trimmingCharacters(in: .whitespaces), bytes: maxBytes)
        return scanned.utf8.count < raw.utf8.count && shown.hasSuffix("…") == false ? shown + "…" : shown
    }

    public static func path(_ raw: String, home: HomePath?, maxBytes: Int = maxCommandBytes) -> String {
        capped(DenialPathRedaction.redact(raw, home: home), bytes: maxBytes)
    }

    /// The first whole characters of `text` that fit in `bytes`.
    static func cut(_ text: String, bytes limit: Int) -> String {
        var kept = ""
        var used = 0
        for character in text {
            let size = character.utf8.count
            guard used + size <= limit else { break }
            kept.append(character)
            used += size
        }
        return kept
    }

    /// Every whole occurrence of the home path becomes `~`: followed by the
    /// end, a separator or punctuation, never by more of a longer name
    /// (`/Users/ann` stays in `/Users/anna`).
    static func homeShown(in text: String, home: HomePath?) -> String {
        guard let home, home.rawValue.count > 1 else { return text }
        let homePath = home.rawValue.hasSuffix("/") ? String(home.rawValue.dropLast()) : home.rawValue
        var result = ""
        var rest = Substring(text)
        while let range = rest.range(of: homePath) {
            let next = rest[range.upperBound...].first
            let continuesName = next.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." } ?? false
            result += rest[..<range.lowerBound]
            result += continuesName ? rest[range] : "~"
            rest = rest[range.upperBound...]
        }
        return result + rest
    }

    static func capped(_ text: String, bytes limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        var kept = ""
        var used = 0
        for character in text {
            let size = character.utf8.count
            guard used + size <= limit else { break }
            kept.append(character)
            used += size
        }
        return kept + "…"
    }
}

/// Where a reader of the decision log got to: a day file and the byte
/// offset of the first line not yet read.
public struct DecisionLogCursor: Sendable, Equatable, Hashable {
    public var day: String
    public var offset: Int

    public init(day: String, offset: Int) {
        self.day = day
        self.offset = offset
    }
}

/// Every hook decision, allowed ones too, for `rv term`. One owner-only
/// JSONL file per UTC day under `<config>/decisions/`, kept `maxAge`.
///
/// Local only: never forwarded, never in the hash-chained audit log. Writes
/// are best-effort and happen after the reply (`DecisionLogRecorder` in
/// RVService); a lost row never changes a decision. `decisions.enabled:
/// false` in `config.json` turns it off.
public struct DecisionLog: Sendable {
    public static let directoryName = "decisions"
    public static let maxAge: TimeInterval = RVHistory.maxAge
    /// A day file larger than this is not read (and would mean something
    /// other than rvd wrote it).
    public static let maxFileBytes = 64 * 1024 * 1024

    public var directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public init(configDirectory: URL) {
        self.init(directory: configDirectory.appendingPathComponent(Self.directoryName, isDirectory: true))
    }

    /// `decisions.enabled` in `config.json`. A missing key is on.
    public static func isEnabled(inConfigDirectory directory: URL) -> Bool {
        let file = directory.appendingPathComponent("config.json", isDirectory: false)
        // Never `Data(contentsOf:)`: a FIFO planted at config.json must
        // not hang the hook-local evaluator, which reads this per call.
        guard let data = readRegularFile(file),
              let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              let enabled = root["decisions"]?["enabled"]?.bool
        else {
            return true
        }
        return enabled
    }

    /// The UTC day a time's row is filed under, `yyyy-MM-dd`.
    public static func day(of time: Date) -> String {
        let parts = utc.dateComponents([.year, .month, .day], from: time)
        let year = parts.year ?? 1970, month = parts.month ?? 1, day = parts.day ?? 1
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    public func fileURL(day: String) -> URL {
        directory.appendingPathComponent("\(day).jsonl", isDirectory: false)
    }

    /// How long `append` waits for the day file's lock by default.
    public static let lockTimeout: Duration = .milliseconds(200)

    /// Appends one row to its day's file, waiting at most `lockTimeout` for
    /// its lock, then, when `prunes` is set, once per day per process,
    /// drops day files past `maxAge`. A short-lived writer (the hook-local
    /// evaluator, one process per call) passes `prunes: false` and leaves
    /// pruning to rvd. Returns whether the row landed.
    @discardableResult
    public func append(
        _ record: DecisionRecord, now: Date, lockTimeout: Duration = DecisionLog.lockTimeout, prunes: Bool = true
    ) -> Bool {
        guard let line = try? Self.encoder.encode(record) else { return false }
        let landed: Bool
        do {
            try JSONLAppendLog.append(
                line, to: fileURL(day: Self.day(of: record.time)), sync: false, lockTimeout: lockTimeout
            )
            landed = true
        } catch {
            landed = false
        }
        if prunes { pruneOncePerDay(now: now) }
        return landed
    }

    /// Rows from `since` on, oldest first. Unreadable lines are skipped.
    public func records(since: Date, now: Date) -> [DecisionRecord] {
        read(after: nil, now: now).records.filter { $0.time >= since }
    }

    /// Rows written after `cursor` (from the start of the kept days when
    /// nil), oldest file first, and where to read from next. Only whole
    /// lines are consumed, so a row still being written is read next time.
    public func read(after cursor: DecisionLogCursor?, now: Date) -> (records: [DecisionRecord], cursor: DecisionLogCursor) {
        let oldestKept = Self.day(of: now.addingTimeInterval(-Self.maxAge))
        let days = dayFiles().filter { day in
            guard day >= oldestKept else { return false }
            guard let cursor else { return true }
            return day >= cursor.day
        }
        let decoder = Self.decoder
        var records: [DecisionRecord] = []
        var next = cursor ?? DecisionLogCursor(day: Self.day(of: now), offset: 0)
        for day in days {
            let start = (cursor?.day == day) ? cursor?.offset ?? 0 : 0
            guard case .success(let data?) = OwnerOnlyFile.read(
                fileURL(day: day), maximumBytes: Self.maxFileBytes, confidential: true
            ) else { continue }
            guard start <= data.count, let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")),
                  lastNewline >= start
            else {
                next = DecisionLogCursor(day: day, offset: min(start, data.count))
                continue
            }
            for line in data[start...lastNewline].split(separator: UInt8(ascii: "\n")) {
                if let record = try? decoder.decode(DecisionRecord.self, from: Data(line)) {
                    records.append(record)
                }
            }
            next = DecisionLogCursor(day: day, offset: lastNewline + 1)
        }
        records.sort { $0.time < $1.time }
        return (records, next)
    }

    /// Removes day files (and their lock sidecars) older than `maxAge`.
    public func prune(now: Date) {
        let oldestKept = Self.day(of: now.addingTimeInterval(-Self.maxAge))
        for day in dayFiles() where day < oldestKept {
            let file = fileURL(day: day)
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: file.appendingPathExtension("lock"))
        }
    }

    /// Day names of the `yyyy-MM-dd.jsonl` files present, sorted.
    func dayFiles() -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.compactMap { name -> String? in
            guard name.hasSuffix(".jsonl") else { return nil }
            let day = String(name.dropLast(6))
            guard day.count == 10, day.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "-") }) else { return nil }
            return day
        }.sorted()
    }

    private func pruneOncePerDay(now: Date) {
        let today = Self.day(of: now)
        let key = directory.path
        let due = Self.lastPruned.withLock { pruned -> Bool in
            guard pruned[key] != today else { return false }
            pruned[key] = today
            return true
        }
        if due { prune(now: now) }
    }

    /// Directory path → the day it was last pruned, in this process.
    private static let lastPruned = Mutex<[String: String]>([:])

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }()

    private static let timeStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(timeStyle))
        }
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = try? Date(text, strategy: timeStyle) { return date }
            if let date = try? Date(text, strategy: Date.ISO8601FormatStyle()) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not an ISO 8601 time")
        }
        return decoder
    }
}
