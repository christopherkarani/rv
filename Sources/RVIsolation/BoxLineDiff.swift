import Foundation

/// Lines added and removed between two versions of a file: the numbers a
/// box review shows (`+38 −4`).
public struct BoxLineCount: Equatable, Sendable {
    public var added: Int
    public var removed: Int

    public init(added: Int, removed: Int) {
        self.added = added
        self.removed = removed
    }

    public static let zero = BoxLineCount(added: 0, removed: 0)

    public static func + (lhs: BoxLineCount, rhs: BoxLineCount) -> BoxLineCount {
        BoxLineCount(added: lhs.added + rhs.added, removed: lhs.removed + rhs.removed)
    }

    /// How much changed, for ordering a review: biggest first.
    var weight: Int { added + removed }
}

/// Counts changed lines the way `git diff --numstat` does: the fewest
/// lines added and removed that turn one text into the other (Myers'
/// O((N+M)D) shortest edit script, lengths only). Pure.
public enum BoxLineDiff {
    /// The largest file rv counts lines for. A bigger one is "changed"
    /// with no numbers rather than slow to review.
    public static let maxBytes = 4 * 1024 * 1024

    /// The most edits the exact count tries before it settles for the
    /// multiset count, which can only be lower.
    static let maxEdits = 4_000

    /// Text is what holds no NUL byte in its first 8 KiB, as git decides.
    public static func isText(_ data: Data) -> Bool {
        data.prefix(8_192).contains(0) == false
    }

    /// The counts from `old` to `new`, where nil is a file that is not
    /// there. Nil when either side is binary or too big to count.
    public static func count(old: Data?, new: Data?) -> BoxLineCount? {
        let before = old ?? Data()
        let after = new ?? Data()
        guard before.count <= maxBytes, after.count <= maxBytes,
            isText(before), isText(after)
        else { return nil }
        return count(lines(before), lines(after))
    }

    /// The lines of `data`: split on `\n`, with no empty last line after a
    /// final newline.
    static func lines(_ data: Data) -> [Data] {
        guard data.isEmpty == false else { return [] }
        var parts = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        if parts.last?.isEmpty == true { parts.removeLast() }
        return parts.map { Data($0) }
    }

    static func count(_ old: [Data], _ new: [Data]) -> BoxLineCount {
        // Lines shared at both ends never change the count.
        var start = 0
        while start < old.count, start < new.count, old[start] == new[start] { start += 1 }
        var oldEnd = old.count
        var newEnd = new.count
        while oldEnd > start, newEnd > start, old[oldEnd - 1] == new[newEnd - 1] {
            oldEnd -= 1
            newEnd -= 1
        }
        var ids: [Data: Int] = [:]
        func id(_ line: Data) -> Int {
            if let known = ids[line] { return known }
            let next = ids.count
            ids[line] = next
            return next
        }
        let a = old[start..<oldEnd].map(id)
        let b = new[start..<newEnd].map(id)
        // The multiset count bounds the edits from below: past the limit
        // already, the exact count is not worth the time.
        let shared = multisetCommon(a, b)
        var common = shared
        if a.count + b.count - 2 * shared <= maxEdits, let edits = shortestEdit(a, b, limit: maxEdits) {
            common = (a.count + b.count - edits) / 2
        }
        return BoxLineCount(added: b.count - common, removed: a.count - common)
    }

    /// Myers' D: the fewest insertions and deletions from `a` to `b`, or
    /// nil past `limit`.
    static func shortestEdit(_ a: [Int], _ b: [Int], limit: Int) -> Int? {
        let n = a.count
        let m = b.count
        if n == 0 || m == 0 { return n + m }
        let bound = min(n + m, limit)
        let offset = bound + 1
        var furthest = [Int](repeating: 0, count: 2 * bound + 3)
        for d in 0...bound {
            var k = -d
            while k <= d {
                var x: Int
                if k == -d || (k != d && furthest[offset + k - 1] < furthest[offset + k + 1]) {
                    x = furthest[offset + k + 1]
                } else {
                    x = furthest[offset + k - 1] + 1
                }
                var y = x - k
                while x < n, y < m, y >= 0, a[x] == b[y] {
                    x += 1
                    y += 1
                }
                furthest[offset + k] = x
                if x >= n, y >= m { return d }
                k += 2
            }
        }
        return nil
    }

    /// Lines both sides hold, order ignored: an upper bound on the common
    /// subsequence, so the counts it gives are never too high.
    static func multisetCommon(_ a: [Int], _ b: [Int]) -> Int {
        var counts: [Int: Int] = [:]
        for line in a { counts[line, default: 0] += 1 }
        var common = 0
        for line in b {
            if let left = counts[line], left > 0 {
                counts[line] = left - 1
                common += 1
            }
        }
        return common
    }
}
