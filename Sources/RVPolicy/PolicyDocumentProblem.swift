import Foundation
import RVDomain

/// Why a `policy.toml` did not parse: where, which key, what is wrong, and
/// the fix. Values quoted from the file are escaped for display and capped.
public struct PolicyDocumentProblem: Error, Sendable, Equatable {
    /// 1-based line in the file, or nil when the problem is the whole file
    /// (for example a missing `schema_version`).
    public var line: Int?
    /// The key the problem is about, when there is one.
    public var key: String?
    /// What is wrong, in one short clause.
    public var problem: String
    /// What to change, in one short clause.
    public var fix: String

    public init(line: Int?, key: String?, problem: String, fix: String) {
        self.line = line
        self.key = key
        self.problem = problem
        self.fix = fix
    }

    /// `<file>:<line>  <problem>` then `→ <fix>`, two lines. The file name is
    /// the caller's to escape.
    public func lines(file: String) -> [String] {
        let location = line.map { "\(file):\($0)" } ?? file
        return ["✕ \(location)  \(problem)", "→ \(fix)"]
    }
}

/// Nearest spelling from a closed list, for "did you mean". Case-insensitive
/// match first, then edit distance of at most two.
enum PolicyDocumentSpelling {
    static func suggestion(for word: String, in candidates: [String]) -> String? {
        let lowered = word.lowercased()
        if let exact = candidates.first(where: { $0.lowercased() == lowered }) {
            return exact
        }
        guard word.count <= 64 else { return nil }
        var best: (String, Int)?
        for candidate in candidates {
            let distance = editDistance(Array(lowered), Array(candidate.lowercased()))
            if distance <= 2, distance < (best?.1 ?? Int.max) {
                best = (candidate, distance)
            }
        }
        return best?.0
    }

    private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            previous = current
        }
        return previous[b.count]
    }
}

/// A policy layer file that does not load, and why.
public struct PolicyFileFailure: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        /// Read, but a line does not parse.
        case parse(PolicyDocumentProblem)
        /// Not read, or not a document at all (legacy JSON).
        case load(PolicyLoadStatus.Problem)
    }

    public var file: URL
    public var reason: Reason

    public init(file: URL, reason: Reason) {
        self.file = file
        self.reason = reason
    }
}
