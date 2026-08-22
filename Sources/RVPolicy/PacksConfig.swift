import Foundation
import RVDomain

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
    case unwritable
}

public enum PacksConfigStore {
    public static func configURL(home: HomeDirectory) -> URL {
        URL(fileURLWithPath: home.rawValue, isDirectory: true)
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("rv", isDirectory: true)
            .appendingPathComponent("config.toml", isDirectory: false)
    }

    public static func load(home: HomeDirectory, fileManager: FileManager = .default) throws -> PacksConfig {
        let url = configURL(home: home)
        guard fileManager.fileExists(atPath: url.path) else {
            return .empty
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw PacksConfigError.unreadable
        }
        return parse(text)
    }

    public static func save(
        _ config: PacksConfig,
        home: HomeDirectory,
        fileManager: FileManager = .default
    ) throws {
        let url = configURL(home: home)
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let body = mergePacksSection(existing: existing, config: config)
        guard let data = body.data(using: .utf8) else {
            throw PacksConfigError.unwritable
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw PacksConfigError.unwritable
        }
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
