#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import RVFileStore
import RVHistory

/// Persisted `[packs]` section under `$HOME/.config/rv/config.toml`.
public struct PacksConfig: Equatable, Sendable {
    public var enabled: [String]
    public var disabled: [String]

    public init(enabled: [String] = [], disabled: [String] = []) {
        self.enabled = enabled
        self.disabled = disabled
    }

    public static let empty = PacksConfig()
}

public enum PacksConfigError: Error, Equatable, Sendable {
    case unreadable
}

public enum PacksConfigStore {
    public static func configURL(home: HomeDirectory) -> URL {
        URL(fileURLWithPath: home.rawValue, isDirectory: true)
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("rv", isDirectory: true)
            .appendingPathComponent("config.toml", isDirectory: false)
    }

    /// True only when `config.toml` is definitely absent (`stat` fails with
    /// ENOENT). Any other failure, such as EACCES on a parent directory,
    /// means the file may exist but cannot be read; callers must fail closed.
    /// (`FileManager.fileExists` returns false for both.)
    public static func isAbsent(home: HomeDirectory) -> Bool {
        var status = stat()
        if stat(configURL(home: home).path, &status) == 0 {
            return false
        }
        return errno == ENOENT
    }

    public static func load(home: HomeDirectory) throws -> PacksConfig {
        try loadText(home: home).map(parse) ?? .empty
    }

    /// The whole `config.toml`, or nil when it is absent. Throws
    /// `unreadable` when it exists but cannot be read as UTF-8.
    public static func loadText(home: HomeDirectory) throws -> String? {
        if isAbsent(home: home) {
            return nil
        }
        guard let data = readRegularFile(configURL(home: home)), let text = String(data: data, encoding: .utf8) else {
            throw PacksConfigError.unreadable
        }
        return text
    }

    /// The nearest real selection to a misspelt one (`databse.redis` →
    /// `database.redis`), or nil.
    public static func nearestSelection(to word: String, in known: [String]) -> String? {
        PolicyDocumentSpelling.suggestion(for: word, in: known)
    }

    /// Replaces `[packs]` and keeps every other section, through
    /// `OwnerConfigFile`: an existing file that cannot be read or is not
    /// UTF-8 throws `OwnerConfigWriteError.unreadable` and nothing is
    /// written (merging into "" would discard its other sections and the
    /// owner's pack choices). Records `config.changed` (`packs`) write-ahead.
    public static func save(_ config: PacksConfig, home: HomeDirectory) throws {
        let file = OwnerConfigFile<String>(
            url: configURL(home: home), empty: "",
            parse: { String(data: $0, encoding: .utf8) }, render: { Data($0.utf8) })
        try file.update(
            audit: { before, _ in changeEvent(from: parse(before), to: config) },
            mutate: { text in text = mergePacksSection(existing: text, config: config) })
    }

    /// `config.changed` (`packs`) with the enabled and disabled lists before
    /// and after; nil when neither changed. Pack ids, never file contents.
    /// Only enabling more and disabling fewer tightens.
    static func changeEvent(from prior: PacksConfig, to new: PacksConfig) -> AuditEvent? {
        guard prior != new else { return nil }
        func summary(_ config: PacksConfig) -> String {
            "enabled=[\(config.enabled.joined(separator: ","))] disabled=[\(config.disabled.joined(separator: ","))]"
        }
        let tightens = Set(new.enabled).isSuperset(of: prior.enabled) && Set(new.disabled).isSubset(of: prior.disabled)
        return ConfigChangeAudit.setting(
            "packs", from: summary(prior), to: summary(new), direction: tightens ? .tightening : .loosening,
            detail: [
                "enabled": ConfigChangeAudit.list(Set(new.enabled).subtracting(prior.enabled)),
                "disabled": ConfigChangeAudit.list(Set(new.disabled).subtracting(prior.disabled)),
            ].filter { $0.value.isEmpty == false })
    }

    /// Replace or append `[packs]` while leaving other TOML sections intact.
    public static func mergePacksSection(existing: String, config: PacksConfig) -> String {
        let packsBlock = render(config)
        if existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return packsBlock
        }

        var kept: [String] = []
        var inPacks = false
        for rawLine in existing.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                if trimmed == "[packs]" {
                    inPacks = true
                    continue
                }
                inPacks = false
            }
            if inPacks { continue }
            kept.append(line)
        }

        while kept.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            kept.removeLast()
        }

        if kept.isEmpty {
            return packsBlock
        }
        return kept.joined(separator: "\n") + "\n\n" + packsBlock
    }

    /// The `[packs]` keys rv reads.
    public static let keys = ["enabled", "disabled"]

    /// What the doors read: entries rv cannot read are skipped, so a typo
    /// never turns every pack off. `problems(in:known:)` names each one.
    public static func parse(_ text: String) -> PacksConfig {
        scan(text).config
    }

    /// Everything in `[packs]` that rv does not read as written, by line:
    /// an unknown key, a value that is not a list of quoted strings, an
    /// entry that is not quoted, and a selection that names no pack,
    /// category or preset in `known` (each with the nearest spelling).
    /// Empty when the section is exactly what rv enforces.
    public static func problems(in text: String, known: [String]) -> [PolicyDocumentProblem] {
        let scanned = scan(text)
        let knownSet = Set(known)
        let unknownSelections = scanned.entries
            .filter { knownSet.contains($0.value) == false }
            .map { entry -> PolicyDocumentProblem in
                let shown = DisplayedText.field(entry.value)
                let fix = nearestSelection(to: entry.value, in: known).map {
                    "did you mean \($0)? rv packs --all lists every pack"
                } ?? "use a pack id, category or preset from rv packs --all"
                return PolicyDocumentProblem(
                    line: entry.line, key: entry.key, problem: "no pack, category or preset is named \(shown)", fix: fix)
            }
        return (scanned.problems + unknownSelections).sorted { ($0.line ?? 0) < ($1.line ?? 0) }
    }

    private struct Entry {
        var line: Int
        var key: String
        var value: String
    }

    private struct Scan {
        var config = PacksConfig()
        var entries: [Entry] = []
        var problems: [PolicyDocumentProblem] = []
    }

    private static func scan(_ text: String) -> Scan {
        var result = Scan()
        var inPacks = false
        // The key of an array still open on an earlier line.
        var openKey: String?
        var lineNumber = 0
        // An unknown key's open array: its lines are skipped, not read.
        let unreadKey = "\u{0}"

        func record(_ key: String, _ value: String, line: Int) {
            if key == "enabled" { result.config.enabled.append(value) }
            if key == "disabled" { result.config.disabled.append(value) }
            result.entries.append(Entry(line: line, key: key, value: value))
        }

        /// Items between `[` and `]` (or one continuation line), quoted.
        func items(_ body: Substring, key: String, line: Int) {
            for raw in body.split(separator: ",") {
                let item = raw.trimmingCharacters(in: .whitespaces)
                if item.isEmpty { continue }
                if let value = parseQuoted(item) {
                    record(key, value, line: line)
                } else {
                    result.problems.append(PolicyDocumentProblem(
                        line: line, key: key, problem: "\(DisplayedText.field(item)) is not a quoted string",
                        fix: "quote it: \"\(DisplayedText.field(item.trimmingCharacters(in: CharacterSet(charactersIn: "'"))))\""))
                }
            }
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNumber += 1
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                if let key = openKey, key != unreadKey {
                    result.problems.append(PolicyDocumentProblem(
                        line: lineNumber - 1, key: key, problem: "\(key) has no closing ]", fix: "end the list with ]"))
                }
                openKey = nil
                inPacks = line == "[packs]"
                continue
            }
            guard inPacks else { continue }

            if let key = openKey {
                let close = line.firstIndex(of: "]")
                if key != unreadKey {
                    items(close.map { line[..<$0] } ?? Substring(line), key: key, line: lineNumber)
                }
                if close != nil { openKey = nil }
                continue
            }

            guard let eq = line.firstIndex(of: "=") else {
                result.problems.append(PolicyDocumentProblem(
                    line: lineNumber, key: nil, problem: "\(DisplayedText.field(line)) is not a key = value line",
                    fix: "write enabled = [\"PACK\"] or disabled = [\"PACK\"]"))
                continue
            }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            let known = keys.contains(key)
            if known == false {
                let fix = PolicyDocumentSpelling.suggestion(for: key, in: keys).map { "did you mean \($0)?" }
                    ?? "[packs] takes only enabled and disabled"
                result.problems.append(PolicyDocumentProblem(
                    line: lineNumber, key: key, problem: "unknown key \(DisplayedText.field(key)) in [packs]", fix: fix))
            }
            guard value.hasPrefix("[") else {
                if known {
                    result.problems.append(PolicyDocumentProblem(
                        line: lineNumber, key: key, problem: "\(key) is not a list",
                        fix: "write \(key) = [\"PACK\", ...]"))
                }
                continue
            }
            // A repeated key replaces the earlier list, as it always has.
            if key == "enabled" { result.config.enabled = [] }
            if key == "disabled" { result.config.disabled = [] }
            let body = value.dropFirst()
            // An unknown key's entries are not read: they are not checked
            // against the pack list either.
            let target = known ? key : ""
            if let close = body.lastIndex(of: "]") {
                if known { items(body[..<close], key: target, line: lineNumber) }
            } else {
                if known { items(body, key: target, line: lineNumber) }
                openKey = known ? key : unreadKey
            }
        }
        if let key = openKey, key != unreadKey {
            result.problems.append(PolicyDocumentProblem(
                line: lineNumber, key: key, problem: "\(key) has no closing ]", fix: "end the list with ]"))
        }
        return result
    }

    public static func render(_ config: PacksConfig) -> String {
        func array(_ values: [String]) -> String {
            if values.isEmpty { return "[]" }
            let body = values.map { "  \"\($0)\"," }.joined(separator: "\n")
            return "[\n\(body)\n]"
        }
        return """
        [packs]
        enabled = \(array(config.enabled))
        disabled = \(array(config.disabled))

        """
    }

    private static func stripComment(_ line: String) -> String {
        var inQuote = false
        var result = ""
        for ch in line {
            if ch == "\"" { inQuote.toggle() }
            if ch == "#" && !inQuote { break }
            result.append(ch)
        }
        return result
    }

    private static func parseQuoted(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ","))
        guard trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 else {
            return nil
        }
        return String(trimmed.dropFirst().dropLast())
    }
}
