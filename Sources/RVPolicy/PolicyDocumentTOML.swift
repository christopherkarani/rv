import Foundation
import RVDomain

public enum PolicyDocumentError: Error, Sendable, Equatable {
    /// The file could not be read at all.
    case invalidFile
    /// The file was read but does not parse: line, key and fix.
    case invalid(PolicyDocumentProblem)

    /// The located problem, when the file was read.
    public var problem: PolicyDocumentProblem? {
        if case .invalid(let problem) = self { return problem }
        return nil
    }
}

/// Narrow TOML dialect for `policy.toml`. Same family as `AllowlistTOML`.
/// Every refusal names the line, the key and the fix.
public enum PolicyDocumentTOML {
    static let rootKeys = ["schema_version", "safety.level", "secret.allow_paths"]
    static let ruleKeys = [
        "id", "verdict", "predicate", "force", "branch", "pathspec", "mode", "recursive", "directories",
        "flag_force", "english",
    ]
    static let predicates = [
        "gitPush", "gitDiscardWorktree", "gitReset", "gitClean", "filesystemDelete", "filesystemMove",
    ]

    /// One physical line of the file, numbered from 1.
    private struct Line {
        var number: Int
        var text: String
        var trimmed: String { text.trimmingCharacters(in: .whitespaces) }
    }

    public static func parse(_ text: String) throws -> PolicyDocument {
        let all = text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map {
            Line(number: $0.offset + 1, text: String($0.element))
        }
        let firstRule = all.firstIndex { $0.trimmed == "[[rule]]" } ?? all.endIndex
        var schemaVersion: Int?
        var safetyLevel: SafetyLevel?
        var allowPaths: [String] = []
        var seenRootKeys: [String: Int] = [:]
        for line in all[..<firstRule] {
            let trimmed = line.trimmed
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let (key, raw) = try keyValue(line)
            if let first = seenRootKeys[key] {
                throw problem(line, key, "\(key) is set twice (first on line \(first))", "keep one \(key) line")
            }
            seenRootKeys[key] = line.number
            switch key {
            case "schema_version":
                guard let value = Int(parseTOMLString(raw)), value == PolicyDocument.currentSchemaVersion else {
                    throw problem(
                        line, key, "schema_version \(shown(raw)) is not one rv reads",
                        "use schema_version = \(PolicyDocument.currentSchemaVersion)")
                }
                schemaVersion = value
            case "safety.level":
                let value = parseTOMLString(raw)
                guard let level = SafetyLevel(rawValue: value) else {
                    throw problem(
                        line, key, "safety.level \(shown(value)) is not a level",
                        choices(value, SafetyLevel.allCases.map(\.rawValue)))
                }
                safetyLevel = level
            case "secret.allow_paths":
                do {
                    allowPaths = try parseTOMLStringArray(raw)
                } catch {
                    throw problem(
                        line, key, "secret.allow_paths is not a list of quoted paths",
                        "write it as secret.allow_paths = [\"path\", \"path\"]")
                }
            default:
                throw problem(line, key, "\(shown(key)) is not a key", choices(key, rootKeys))
            }
        }
        guard schemaVersion == PolicyDocument.currentSchemaVersion else {
            throw PolicyDocumentError.invalid(PolicyDocumentProblem(
                line: nil, key: "schema_version", problem: "schema_version is missing",
                fix: "add schema_version = \(PolicyDocument.currentSchemaVersion) as the first line"))
        }
        var rules: [PolicyDocumentRule] = []
        var ids: [String: Int] = [:]
        var predicates: [(PolicyPredicate, Int)] = []
        for block in ruleBlocks(Array(all[firstRule...])) {
            let header = block[0]
            let rule = try parseRule(block)
            if let first = ids[rule.id.rawValue] {
                throw problem(
                    header, "id", "rule id \(shown(rule.id.rawValue)) is used twice (first rule on line \(first))",
                    "give each [[rule]] its own id")
            }
            if let first = predicates.first(where: { $0.0 == rule.predicate }) {
                throw problem(
                    header, "predicate", "this rule matches the same commands as the rule on line \(first.1)",
                    "merge the two rules into one")
            }
            ids[rule.id.rawValue] = header.number
            predicates.append((rule.predicate, header.number))
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
                .map { "\"\(escapeTOMLDisplayed($0))\"" }
                .joined(separator: ", ")
            parts.append("secret.allow_paths = [\(quoted)]")
        }
        for rule in document.rules {
            var lines = ["[[rule]]"]
            lines.append("id = \"\(escapeTOMLDisplayed(rule.id.rawValue))\"")
            lines.append("verdict = \"\(rule.verdict.rawValue)\"")
            switch rule.predicate {
            case .gitPush(let force, let branch):
                lines.append("predicate = \"gitPush\"")
                if case .exactly(let value) = force {
                    lines.append("force = \"\(value.rawValue)\"")
                }
                if let branch {
                    lines.append("branch = \"\(escapeTOMLDisplayed(branch))\"")
                }
            case .gitDiscardWorktree(let pathspec):
                lines.append("predicate = \"gitDiscardWorktree\"")
                if let pathspec {
                    lines.append("pathspec = \"\(escapeTOMLDisplayed(pathspec))\"")
                }
            case .gitReset(let mode):
                lines.append("predicate = \"gitReset\"")
                if let mode {
                    lines.append("mode = \"\(mode.rawValue)\"")
                }
            case .gitClean(let force, let directories):
                lines.append("predicate = \"gitClean\"")
                if let force {
                    lines.append("flag_force = \"\(force)\"")
                }
                if let directories {
                    lines.append("directories = \"\(directories)\"")
                }
            case .filesystemDelete(let recursive, let force):
                lines.append("predicate = \"filesystemDelete\"")
                if let recursive {
                    lines.append("recursive = \"\(recursive)\"")
                }
                if let force {
                    lines.append("flag_force = \"\(force)\"")
                }
            case .filesystemMove:
                lines.append("predicate = \"filesystemMove\"")
            }
            if let english = rule.english {
                lines.append("english = \"\(escapeTOMLDisplayed(english))\"")
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
                if PolicyDiffRisk.restrictionRank(rule.verdict) > PolicyDiffRisk.restrictionRank(merged[index].verdict) {
                    merged[index] = rule
                }
            } else {
                merged.append(rule)
            }
        }
        return merged
    }

    /// Each block starts at its `[[rule]]` line and runs to the next one.
    private static func ruleBlocks(_ lines: [Line]) -> [[Line]] {
        var blocks: [[Line]] = []
        for line in lines {
            if line.trimmed == "[[rule]]" {
                blocks.append([line])
            } else if blocks.isEmpty == false {
                blocks[blocks.count - 1].append(line)
            }
        }
        return blocks
    }

    /// `key = value` with a trailing `# comment` removed. Throws a located
    /// problem for anything else.
    private static func keyValue(_ line: Line) throws -> (String, String) {
        let trimmed = line.trimmed
        if trimmed.hasPrefix("[") {
            let fix = trimmed.lowercased().contains("rule")
                ? "write the table header as [[rule]]"
                : "only [[rule]] tables are read; put settings above the first [[rule]]"
            throw problem(line, nil, "\(shown(trimmed)) is not a table rv reads", fix)
        }
        guard let eq = trimmed.firstIndex(of: "=") else {
            throw problem(line, nil, "\(shown(trimmed)) is not key = value", "write it as key = \"value\", or start it with #")
        }
        let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
        let raw = withoutTrailingComment(String(trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)))
        if raw.hasPrefix("\"\"\"") {
            throw problem(line, key, "multi-line strings are not supported", "put the value on one line in \"quotes\"")
        }
        return (key, raw)
    }

    /// `"value"   # note` → `"value"`; `1 # note` → `1`. A `#` inside quotes
    /// stays. Anything else after a closing quote is left for the value
    /// check to refuse.
    static func withoutTrailingComment(_ raw: String) -> String {
        let characters = Array(raw)
        if characters.first == "\"" {
            var index = 1
            var escaped = false
            while index < characters.count {
                let character = characters[index]
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    break
                }
                index += 1
            }
            guard index < characters.count else { return raw }
            let rest = String(characters[(index + 1)...]).trimmingCharacters(in: .whitespaces)
            return rest.hasPrefix("#") ? String(characters[...index]) : raw
        }
        if characters.first == "[" {
            guard let close = characters.lastIndex(of: "]") else { return raw }
            let rest = String(characters[(close + 1)...]).trimmingCharacters(in: .whitespaces)
            return rest.hasPrefix("#") ? String(characters[...close]) : raw
        }
        for (index, character) in characters.enumerated()
        where character == "#" && index > 0 && characters[index - 1].isWhitespace {
            return String(characters[..<index]).trimmingCharacters(in: .whitespaces)
        }
        return raw
    }

    private static func parseRule(_ block: [Line]) throws -> PolicyDocumentRule {
        let header = block[0]
        var values: [String: (value: String, line: Line)] = [:]
        for line in block.dropFirst() {
            let trimmed = line.trimmed
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let (key, raw) = try keyValue(line)
            guard ruleKeys.contains(key) else {
                throw problem(line, key, "\(shown(key)) is not a rule key", choices(key, ruleKeys))
            }
            if let first = values[key] {
                throw problem(line, key, "\(key) is set twice in this rule (first on line \(first.line.number))", "keep one \(key) line")
            }
            values[key] = (parseTOMLString(raw), line)
        }
        func required(_ key: String, _ fix: String) throws -> (value: String, line: Line) {
            guard let found = values[key] else {
                throw problem(header, key, "this [[rule]] has no \(key)", fix)
            }
            return found
        }
        let idEntry = try required("id", "add id = \"typed.git:my-rule\"")
        guard let id = RuleID(rawValue: idEntry.value) else {
            throw problem(
                idEntry.line, "id", "id \(shown(idEntry.value)) is not pack:name",
                "use a pack and a name, like id = \"typed.git:my-rule\"")
        }
        let verdictEntry = try required("verdict", "add verdict = \"deny\", \"ask\" or \"allow\"")
        guard let verdict = TypedRuleVerdict(rawValue: verdictEntry.value) else {
            throw problem(
                verdictEntry.line, "verdict", "verdict \(shown(verdictEntry.value)) is not a verdict",
                choices(verdictEntry.value, ["deny", "ask", "allow"]))
        }
        let predicateEntry = try required("predicate", "add predicate = \"gitPush\" (or another predicate)")
        func flag(_ key: String) throws -> Bool? {
            guard let entry = values[key] else { return nil }
            switch entry.value {
            case "true": return true
            case "false": return false
            default:
                throw problem(entry.line, key, "\(key) \(shown(entry.value)) is not true or false", "use \(key) = \"true\" or \"false\"")
            }
        }
        func nonEmpty(_ key: String) throws -> String? {
            guard let entry = values[key] else { return nil }
            let trimmed = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else {
                throw problem(entry.line, key, "\(key) is empty", "name one, or remove the \(key) line to match any")
            }
            return trimmed
        }
        let predicate: PolicyPredicate
        switch predicateEntry.value {
        case "gitPush":
            let force: GitPushForceConstraint
            if let entry = values["force"] {
                guard let parsed = GitPushForce(rawValue: entry.value) else {
                    throw problem(
                        entry.line, "force", "force \(shown(entry.value)) is not a push kind",
                        choices(entry.value, ["force", "forceWithLease", "none"]))
                }
                force = .exactly(parsed)
            } else {
                force = .any
            }
            predicate = .gitPush(force: force, branch: try nonEmpty("branch"))
        case "gitDiscardWorktree":
            predicate = .gitDiscardWorktree(pathspec: try nonEmpty("pathspec"))
        case "gitReset":
            if let entry = values["mode"] {
                guard let mode = GitResetMode(rawValue: entry.value) else {
                    throw problem(
                        entry.line, "mode", "mode \(shown(entry.value)) is not a reset mode",
                        choices(entry.value, ["hard", "soft", "mixed", "merge", "keep"]))
                }
                predicate = .gitReset(mode: mode)
            } else {
                predicate = .gitReset(mode: nil)
            }
        case "gitClean":
            predicate = .gitClean(force: try flag("flag_force"), directories: try flag("directories"))
        case "filesystemDelete":
            predicate = .filesystemDelete(recursive: try flag("recursive"), force: try flag("flag_force"))
        case "filesystemMove":
            predicate = .filesystemMove
        default:
            throw problem(
                predicateEntry.line, "predicate", "predicate \(shown(predicateEntry.value)) is not one rv knows",
                choices(predicateEntry.value, Self.predicates))
        }
        return PolicyDocumentRule(
            id: id,
            verdict: verdict,
            predicate: predicate,
            english: values["english"]?.value
        )
    }

    private static func problem(_ line: Line, _ key: String?, _ problem: String, _ fix: String) -> PolicyDocumentError {
        .invalid(PolicyDocumentProblem(line: line.number, key: key, problem: problem, fix: fix))
    }

    /// "did you mean X?" when one is close, else the whole list.
    private static func choices(_ word: String, _ candidates: [String]) -> String {
        if let near = PolicyDocumentSpelling.suggestion(for: word, in: candidates) {
            return "did you mean \(near)?"
        }
        return "use one of: " + candidates.joined(separator: ", ")
    }

    /// A value from the file, quoted, escaped for display, at most 40 characters.
    private static func shown(_ value: String) -> String {
        let capped = value.count > 40 ? String(value.prefix(39)) + "…" : value
        return "\"" + DisplayedText.field(capped) + "\""
    }

    static func parseTOMLStringArray(_ raw: String) throws -> [String] {
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
