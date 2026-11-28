import Foundation
import RVFileStore

/// The rows of rvd's decision log that `rv log` lists, read in one bounded
/// pass: only the day files from `since` on, and only the lines that are
/// stops (`denied`, `refused`) or would-stops (`allowed` with a would-be).
public struct DecisionLogStops: Sendable, Equatable {
    /// Oldest first, each at or after `since`.
    public var records: [DecisionRecord]
    /// Day files in the window not read because they were past
    /// `DecisionLog.maxFileBytes`.
    public var skippedDays: [String]
    /// When the log began, if that was inside the window: the time of the
    /// first row of its oldest day file. Nil when the log is older than
    /// `since`, or holds no readable row.
    public var startedAt: Date?

    public init(records: [DecisionRecord], skippedDays: [String] = [], startedAt: Date? = nil) {
        self.records = records
        self.skippedDays = skippedDays
        self.startedAt = startedAt
    }
}

extension DecisionLog {
    /// Stops and would-stops from `since` to `now`. An allowed row with no
    /// would-be (most of the log) is skipped on its bytes, before it is
    /// decoded: the log is written with sorted keys and no spaces, and a
    /// quote inside a JSON string is escaped, so `"verdict":"allowed"` and
    /// `"would_be"` can only be keys and values.
    public func stops(since: Date, now: Date) -> DecisionLogStops {
        let present = dayFiles()
        let first = Self.day(of: since)
        let last = Self.day(of: now)
        let decoder = Self.decoder
        var records: [DecisionRecord] = []
        var skipped: [String] = []
        var startedAt: Date?
        for day in present where day >= first && day <= last {
            let read = OwnerOnlyFile.read(fileURL(day: day), maximumBytes: Self.maxFileBytes, confidential: true)
            guard case .success(let data?) = read else {
                if case .failure(.oversized) = read { skipped.append(day) }
                continue
            }
            if day == present.first {
                startedAt = DecisionLogScan.firstTime(in: data, decoder: decoder)
            }
            DecisionLogScan.eachListedLine(in: data) { line in
                if let record = try? decoder.decode(DecisionRecord.self, from: line), record.time >= since {
                    records.append(record)
                }
            }
        }
        records.sort { $0.time < $1.time }
        return DecisionLogStops(records: records, skippedDays: skipped, startedAt: startedAt)
    }
}

/// Byte-level line filter for `DecisionLog.stops`.
enum DecisionLogScan {
    static let allowed = Array(#""verdict":"allowed""#.utf8)
    static let wouldBe = Array(#""would_be""#.utf8)

    /// Calls `body` with each whole line of `data` that is not an allowed
    /// row without a would-be. A trailing line with no newline is still
    /// being written and is left for the next read.
    static func eachListedLine(in data: Data, _ body: (Data) -> Void) {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var start = 0
            let count = buffer.count
            while start < count {
                guard let newline = memchr(base + start, Int32(UInt8(ascii: "\n")), count - start) else { return }
                let end = base.distance(to: UnsafeRawPointer(newline))
                let line = UnsafeRawBufferPointer(rebasing: buffer[start..<end])
                if line.isEmpty == false, listed(line) {
                    body(Data(line))
                }
                start = end + 1
            }
        }
    }

    /// The time of the first row that decodes, among the first few lines.
    static func firstTime(in data: Data, decoder: JSONDecoder) -> Date? {
        for line in data.prefix(64 * 1024).split(separator: UInt8(ascii: "\n")).prefix(16) {
            if let record = try? decoder.decode(DecisionRecord.self, from: Data(line)) { return record.time }
        }
        return nil
    }

    /// False only for an allowed row with no would-be.
    static func listed(_ line: UnsafeRawBufferPointer) -> Bool {
        contains(line, allowed) == false || contains(line, wouldBe)
    }

    static func contains(_ line: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Bool {
        guard let base = line.baseAddress else { return false }
        return needle.withUnsafeBytes { pattern in
            guard let first = pattern.first, let tail = pattern.baseAddress else { return false }
            var offset = 0
            // memchr for the first byte, then memcmp: portable, and fast
            // even in a debug build.
            while line.count - offset >= pattern.count,
                  let hit = memchr(base + offset, Int32(first), line.count - offset - pattern.count + 1) {
                if memcmp(hit, tail, pattern.count) == 0 { return true }
                offset = base.distance(to: UnsafeRawPointer(hit)) + 1
            }
            return false
        }
    }
}
