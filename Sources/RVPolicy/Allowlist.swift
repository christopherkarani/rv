import Foundation
import RVDomain

public enum AllowlistSelector: Equatable, Sendable {
    case rule(RuleID)
    case exactCommand(MatchingView)
}

public struct AllowlistEntry: Equatable, Sendable {
    public var selector: AllowlistSelector
    public var reason: String
    public var addedAt: Date
    public var expiresAt: Date?

    public init(
        selector: AllowlistSelector,
        reason: String,
        addedAt: Date,
        expiresAt: Date? = nil
    ) {
        self.selector = selector
        self.reason = reason
        self.addedAt = addedAt
        self.expiresAt = expiresAt
    }

    public func isActive(at now: Date) -> Bool {
        guard let expiresAt else { return true }
        return expiresAt >= now
    }
}

public struct AllowlistSnapshot: Equatable, Sendable {
    public var entries: [AllowlistEntry]
    public var blocked: DenylistSnapshot

    public init(entries: [AllowlistEntry], blocked: DenylistSnapshot = .empty) {
        self.entries = entries
        self.blocked = blocked
    }

    public static let empty = AllowlistSnapshot(entries: [])

    public func matches(
        ruleID: RuleID?,
        matchingView: MatchingView,
        now: Date
    ) -> Bool {
        if blocked.matches(matchingView) {
            return false
        }
        return entries.contains { entry in
            guard entry.isActive(at: now) else { return false }
            switch entry.selector {
            case .rule(let allowed):
                return ruleID == allowed
            case .exactCommand(let allowed):
                return matchingView == allowed
            }
        }
    }
}

public enum AllowlistParseError: Error, Sendable, Equatable {
    case invalidTOML
    case missingReason
    case emptyReason
    case missingSelector
    case bothSelectors
    case invalidRule(String)
    case invalidDate(String)
}

/// Accepts T1 colon form or display slash form; stores canonical `RuleID`.
public func parseAllowlistRuleID(_ text: String) -> RuleID? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let colon = RuleID(rawValue: trimmed) {
        return colon
    }
    let parts = trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2, parts[0].isEmpty == false, parts[1].isEmpty == false else {
        return nil
    }
    return RuleID(rawValue: "\(parts[0]):\(parts[1])")
}

public enum AllowlistTOML {
    public static func parse(_ text: String) throws -> [AllowlistEntry] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        let blocks = splitAllowBlocks(text)
        if blocks.isEmpty {
            throw AllowlistParseError.invalidTOML
        }
        return try blocks.map(parseBlock)
    }

    public static func render(_ entries: [AllowlistEntry]) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        var parts: [String] = []
        for entry in entries {
            var lines = ["[[allow]]"]
            switch entry.selector {
            case .rule(let ruleID):
                lines.append("rule = \"\(ruleID.rawValue)\"")
            case .exactCommand(let command):
                lines.append("exact_command = \"\(escapeTOMLString(command.rawValue))\"")
            }
            lines.append("reason = \"\(escapeTOMLString(entry.reason))\"")
            lines.append("added_at = \"\(formatter.string(from: entry.addedAt))\"")
            if let expiresAt = entry.expiresAt {
                lines.append("expires_at = \"\(formatter.string(from: expiresAt))\"")
            }
            parts.append(lines.joined(separator: "\n"))
        }
        return parts.isEmpty ? "" : parts.joined(separator: "\n\n") + "\n"
    }

    private static func splitAllowBlocks(_ text: String) -> [String] {
        var blocks: [String] = []
        var current: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "[[allow]]" {
                if current.isEmpty == false {
                    blocks.append(current.joined(separator: "\n"))
                }
                current = [line]
                continue
            }
            if current.isEmpty == false {
                current.append(line)
            } else if trimmed.isEmpty == false, trimmed.hasPrefix("#") == false {
                // stray content outside tables
                current = [line]
            }
        }
        if current.isEmpty == false {
            blocks.append(current.joined(separator: "\n"))
        }
        return blocks.filter { $0.contains("[[allow]]") }
    }

    private static func parseBlock(_ block: String) throws -> AllowlistEntry {
        var rule: String?
        var exact: String?
        var reason: String?
        var addedAtRaw: String?
        var expiresAtRaw: String?
        for rawLine in block.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line == "[[allow]]" { continue }
            guard let eq = line.firstIndex(of: "=") else { throw AllowlistParseError.invalidTOML }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = parseTOMLString(String(line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)))
            switch key {
            case "rule": rule = value
            case "exact_command": exact = value
            case "reason": reason = value
            case "added_at": addedAtRaw = value
            case "expires_at": expiresAtRaw = value
            default:
                throw AllowlistParseError.invalidTOML
            }
        }
        guard let reason else { throw AllowlistParseError.missingReason }
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedReason.isEmpty == false else { throw AllowlistParseError.emptyReason }
        let selector: AllowlistSelector
        switch (rule, exact) {
        case (let rule?, nil):
            guard let ruleID = parseAllowlistRuleID(rule) else {
                throw AllowlistParseError.invalidRule(rule)
            }
            selector = .rule(ruleID)
        case (nil, let exact?):
            selector = .exactCommand(MatchingView(exact))
        case (nil, nil):
            throw AllowlistParseError.missingSelector
        case (.some, .some):
            throw AllowlistParseError.bothSelectors
        }
        let addedAt: Date
        if let addedAtRaw {
            guard let parsed = parseISO8601(addedAtRaw) else {
                throw AllowlistParseError.invalidDate(addedAtRaw)
            }
            addedAt = parsed
        } else {
            addedAt = Date(timeIntervalSince1970: 0)
        }
        let expiresAt: Date?
        if let expiresAtRaw {
            guard let parsed = parseISO8601(expiresAtRaw) else {
                throw AllowlistParseError.invalidDate(expiresAtRaw)
            }
            expiresAt = parsed
        } else {
            expiresAt = nil
        }
        return AllowlistEntry(
            selector: selector,
            reason: trimmedReason,
            addedAt: addedAt,
            expiresAt: expiresAt
        )
    }
}

func parseTOMLString(_ raw: String) -> String {
    var text = raw.trimmingCharacters(in: .whitespaces)
    if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 {
        text.removeFirst()
        text.removeLast()
        return text
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
    return text
}

func escapeTOMLString(_ text: String) -> String {
    text
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

func parseISO8601(_ text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    if let date = formatter.date(from: text) { return date }
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: text)
}
