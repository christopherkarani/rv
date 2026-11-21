#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
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
        if isAbsent(home: home) {
            return .empty
        }
        guard let text = try? String(contentsOf: configURL(home: home), encoding: .utf8) else {
            throw PacksConfigError.unreadable
        }
        return parse(text)
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

    public static func parse(_ text: String) -> PacksConfig {
        var inPacks = false
        var enabled: [String] = []
        var disabled: [String] = []
        var currentKey: String?

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                inPacks = line == "[packs]"
                currentKey = nil
                continue
            }
            guard inPacks else { continue }

            if let eq = line.firstIndex(of: "=") {
                let key = line[..<eq].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                currentKey = key
                if let parsed = parseStringArray(value) {
                    if key == "enabled" { enabled = parsed }
                    if key == "disabled" { disabled = parsed }
                    currentKey = nil
                }
                continue
            }

            if let key = currentKey, let item = parseQuoted(line.trimmingCharacters(in: CharacterSet(charactersIn: ","))) {
                if key == "enabled" { enabled.append(item) }
                if key == "disabled" { disabled.append(item) }
            }
            if line.contains("]") {
                currentKey = nil
            }
        }

        return PacksConfig(enabled: enabled, disabled: disabled)
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

    private static func parseStringArray(_ value: String) -> [String]? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return nil }
        let inner = trimmed.dropFirst().dropLast()
        if inner.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
        return inner.split(separator: ",").compactMap { parseQuoted(String($0)) }
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
