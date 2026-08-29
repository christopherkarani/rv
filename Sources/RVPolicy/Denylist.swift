import Foundation
import RVDomain

public struct DenylistEntry: Equatable, Sendable {
    public var matchingView: MatchingView
    public var reason: String
    public var addedAt: Date

    public init(matchingView: MatchingView, reason: String, addedAt: Date) {
        self.matchingView = matchingView
        self.reason = reason
        self.addedAt = addedAt
    }
}

public struct DenylistSnapshot: Equatable, Sendable {
    public var entries: [DenylistEntry]

    public init(entries: [DenylistEntry]) {
        self.entries = entries
    }

    public static let empty = DenylistSnapshot(entries: [])

    public func matches(_ matchingView: MatchingView) -> Bool {
        entries.contains { $0.matchingView == matchingView }
    }
}

public enum DenylistParseError: Error, Sendable, Equatable {
    case invalidTOML
    case missingReason
    case emptyReason
    case missingCommand
    case invalidDate(String)
}

enum DenylistTOML {
    static func parse(_ text: String) throws -> [DenylistEntry] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        let blocks = splitBlock(text, header: "[[block]]")
        if blocks.isEmpty {
            throw DenylistParseError.invalidTOML
        }
        return try blocks.map(parseBlock)
    }

    static func render(_ entries: [DenylistEntry]) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        var parts: [String] = []
        for entry in entries {
            var lines = ["[[block]]"]
            lines.append("exact_command = \"\(escapeTOMLString(entry.matchingView.rawValue))\"")
            lines.append("reason = \"\(escapeTOMLString(entry.reason))\"")
            lines.append("added_at = \"\(formatter.string(from: entry.addedAt))\"")
            parts.append(lines.joined(separator: "\n"))
        }
        return parts.isEmpty ? "" : parts.joined(separator: "\n\n") + "\n"
    }

    private static func parseBlock(_ block: String) throws -> DenylistEntry {
        var exact: String?
        var reason: String?
        var addedAtRaw: String?
        for rawLine in block.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line == "[[block]]" { continue }
            guard let eq = line.firstIndex(of: "=") else { throw DenylistParseError.invalidTOML }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = parseTOMLString(String(line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)))
            switch key {
            case "exact_command": exact = value
            case "reason": reason = value
            case "added_at": addedAtRaw = value
            default:
                throw DenylistParseError.invalidTOML
            }
        }
        guard let reason else { throw DenylistParseError.missingReason }
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedReason.isEmpty == false else { throw DenylistParseError.emptyReason }
        guard let exact, exact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw DenylistParseError.missingCommand
        }
        let addedAt: Date
        if let addedAtRaw {
            guard let parsed = parseISO8601(addedAtRaw) else {
                throw DenylistParseError.invalidDate(addedAtRaw)
            }
            addedAt = parsed
        } else {
            addedAt = Date(timeIntervalSince1970: 0)
        }
        return DenylistEntry(
            matchingView: MatchingView(exact),
            reason: trimmedReason,
            addedAt: addedAt
        )
    }
}

func splitBlock(_ text: String, header: String) -> [String] {
    var blocks: [String] = []
    var current: [String] = []
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(rawLine)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed == header {
            if current.isEmpty == false {
                blocks.append(current.joined(separator: "\n"))
            }
            current = [line]
            continue
        }
        if current.isEmpty == false {
            current.append(line)
        } else if trimmed.isEmpty == false, trimmed.hasPrefix("#") == false {
            current = [line]
        }
    }
    if current.isEmpty == false {
        blocks.append(current.joined(separator: "\n"))
    }
    return blocks.filter { $0.contains(header) }
}
