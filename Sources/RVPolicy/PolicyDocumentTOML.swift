import Foundation
import RVDomain

public enum PolicyDocumentError: Error, Sendable, Equatable {
    case invalidFile
}

/// Narrow TOML dialect for `policy.toml`. Same family as `AllowlistTOML`.
public enum PolicyDocumentTOML {
    public static func parse(_ text: String) throws -> PolicyDocument {
        let blocks = splitRuleBlocks(text)
        var schemaVersion: Int?
        var safetyLevel: SafetyLevel?
        var allowPaths: [String] = []
        var seenRootKeys: Set<String> = []
        for line in preambleLines(text) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let eq = trimmed.firstIndex(of: "=") else {
                throw PolicyDocumentError.invalidFile
            }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            let raw = String(trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces))
            if seenRootKeys.contains(key) {
                throw PolicyDocumentError.invalidFile
            }
            switch key {
            case "schema_version":
                seenRootKeys.insert(key)
                guard let value = Int(parseTOMLString(raw)), value == PolicyDocument.currentSchemaVersion else {
                    throw PolicyDocumentError.invalidFile
                }
                schemaVersion = value
            case "safety.level":
                seenRootKeys.insert(key)
                guard let level = SafetyLevel(rawValue: parseTOMLString(raw)) else {
                    throw PolicyDocumentError.invalidFile
                }
                safetyLevel = level
            case "secret.allow_paths":
                seenRootKeys.insert(key)
                allowPaths = try parseTOMLStringArray(raw)
            default:
                throw PolicyDocumentError.invalidFile
            }
        }
        guard schemaVersion == PolicyDocument.currentSchemaVersion else {
            throw PolicyDocumentError.invalidFile
        }
        var rules: [PolicyDocumentRule] = []
        var ids: Set<String> = []
        var predicates: [PolicyPredicate] = []
        for block in blocks {
            let rule = try parseRule(block)
            if ids.contains(rule.id.rawValue) {
                throw PolicyDocumentError.invalidFile
            }
            if predicates.contains(rule.predicate) {
                throw PolicyDocumentError.invalidFile
            }
            ids.insert(rule.id.rawValue)
            predicates.append(rule.predicate)
            rules.append(rule)
        }
        return PolicyDocument(
            schemaVersion: PolicyDocument.currentSchemaVersion,
            rules: rules,
            safetyLevel: safetyLevel,
            allowPaths: allowPaths
        )
    }

    public static func render(_ document: PolicyDocument) -> String {
        var parts = ["schema_version = \(document.schemaVersion)"]
        if let safety = document.safetyLevel {
            parts.append("safety.level = \"\(safety.rawValue)\"")
        }
        if document.allowPaths.isEmpty == false {
            let quoted = document.allowPaths
                .map { "\"\(escapeTOMLString($0))\"" }
                .joined(separator: ", ")
            parts.append("secret.allow_paths = [\(quoted)]")
        }
        for rule in document.rules {
            var lines = ["[[rule]]"]
            lines.append("id = \"\(escapeTOMLString(rule.id.rawValue))\"")
            lines.append("verdict = \"\(rule.verdict.rawValue)\"")
            lines.append("predicate = \"gitPush\"")
            switch rule.predicate {
            case .gitPush(let force, let branch):
                if let force {
                    lines.append("force = \"\(force.rawValue)\"")
                }
                if let branch {
                    lines.append("branch = \"\(escapeTOMLString(branch))\"")
                }
            }
            if let english = rule.english {
                lines.append("english = \"\(escapeTOMLString(english))\"")
            }
            parts.append(lines.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n") + "\n"
    }

    public static func mergeLayer(
        existing: [PolicyDocumentRule],
        incoming: [PolicyDocumentRule]
    ) -> [PolicyDocumentRule] {
        var merged = existing
        for rule in incoming {
            if let index = merged.firstIndex(where: { $0.predicate == rule.predicate }) {
                if restrictionRank(rule.verdict) > restrictionRank(merged[index].verdict) {
                    merged[index] = rule
                }
            } else {
                merged.append(rule)
            }
        }
        return merged
    }

    private static func restrictionRank(_ verdict: TypedRuleVerdict) -> Int {
        switch verdict {
        case .allow: 0
        case .ask: 1
        case .deny: 2
        }
    }

    private static func preambleLines(_ text: String) -> [String] {
        var lines: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed == "[[rule]]" { break }
            lines.append(String(raw))
        }
        return lines
    }

    private static func splitRuleBlocks(_ text: String) -> [String] {
        var blocks: [String] = []
        var current: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "[[rule]]" {
                if current.isEmpty == false {
                    blocks.append(current.joined(separator: "\n"))
                }
                current = [line]
                continue
            }
            if current.isEmpty == false {
                current.append(line)
            }
        }
        if current.isEmpty == false {
            blocks.append(current.joined(separator: "\n"))
        }
        return blocks.filter { $0.contains("[[rule]]") }
    }

    private static func parseRule(_ block: String) throws -> PolicyDocumentRule {
        var idRaw: String?
        var verdictRaw: String?
        var predicateRaw: String?
        var forceRaw: String?
        var branchRaw: String?
        var englishRaw: String?
        for rawLine in block.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line == "[[rule]]" { continue }
            if line.hasPrefix("[") {
                throw PolicyDocumentError.invalidFile
            }
            guard let eq = line.firstIndex(of: "=") else {
                throw PolicyDocumentError.invalidFile
            }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let raw = String(line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces))
            if raw.hasPrefix("\"\"\"") {
                throw PolicyDocumentError.invalidFile
            }
            let value = parseTOMLString(raw)
            switch key {
            case "id":
                if idRaw != nil { throw PolicyDocumentError.invalidFile }
                idRaw = value
            case "verdict":
                if verdictRaw != nil { throw PolicyDocumentError.invalidFile }
                verdictRaw = value
            case "predicate":
                if predicateRaw != nil { throw PolicyDocumentError.invalidFile }
                predicateRaw = value
            case "force":
                if forceRaw != nil { throw PolicyDocumentError.invalidFile }
                forceRaw = value
            case "branch":
                if branchRaw != nil { throw PolicyDocumentError.invalidFile }
                branchRaw = value
            case "english":
                if englishRaw != nil { throw PolicyDocumentError.invalidFile }
                englishRaw = value
            default:
                throw PolicyDocumentError.invalidFile
            }
        }
        guard let idRaw, let id = RuleID(rawValue: idRaw) else {
            throw PolicyDocumentError.invalidFile
        }
        guard let verdictRaw, let verdict = TypedRuleVerdict(rawValue: verdictRaw) else {
            throw PolicyDocumentError.invalidFile
        }
        guard let predicateRaw else {
            throw PolicyDocumentError.invalidFile
        }
        guard predicateRaw == "gitPush" else {
            throw PolicyDocumentError.invalidFile
        }
        let force: GitPushForce?
        if let forceRaw {
            guard let parsed = GitPushForce(rawValue: forceRaw) else {
                throw PolicyDocumentError.invalidFile
            }
            force = parsed
        } else {
            force = nil
        }
        let branch: String?
        if let branchRaw {
            let trimmed = branchRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else {
                throw PolicyDocumentError.invalidFile
            }
            branch = trimmed
        } else {
            branch = nil
        }
        return PolicyDocumentRule(
            id: id,
            verdict: verdict,
            predicate: .gitPush(force: force, branch: branch),
            english: englishRaw
        )
    }

    private static func parseTOMLStringArray(_ raw: String) throws -> [String] {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("["), text.hasSuffix("]") else {
            throw PolicyDocumentError.invalidFile
        }
        let inner = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        if inner.isEmpty { return [] }
        var items: [String] = []
        var current = ""
        var inQuote = false
        var escape = false
        for character in inner {
            if escape {
                current.append(character)
                escape = false
                continue
            }
            if character == "\\", inQuote {
                escape = true
                continue
            }
            if character == "\"" {
                inQuote.toggle()
                current.append(character)
                continue
            }
            if character == ",", inQuote == false {
                let piece = current.trimmingCharacters(in: .whitespaces)
                guard piece.isEmpty == false else {
                    throw PolicyDocumentError.invalidFile
                }
                items.append(parseTOMLString(piece))
                current = ""
                continue
            }
            current.append(character)
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        guard last.isEmpty == false else {
            throw PolicyDocumentError.invalidFile
        }
        items.append(parseTOMLString(last))
        return items
    }
}
