import Foundation
import RVDomain

struct PackFile: Decodable {
    var schemaVersion: Int
    var id: String
    var name: String
    var version: String
    var description: String
    var enabledByDefault: Bool
    var keywords: [String]
    var safePatterns: [SafeFile]
    var destructivePatterns: [DestructiveFile]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case id
        case name
        case version
        case description
        case enabledByDefault = "enabled_by_default"
        case keywords
        case safePatterns = "safe_patterns"
        case destructivePatterns = "destructive_patterns"
    }
}

struct SafeFile: Decodable {
    var name: String
    var pattern: String
    var description: String?
}

struct DestructiveFile: Decodable {
    var name: String
    var pattern: String
    var severity: String
    var description: String
    var explanation: String?
}

public enum PackJSON {
    public static func decode(_ data: Data) throws -> PackSnapshot {
        let file = try JSONDecoder().decode(PackFile.self, from: data)
        guard let packID = PackID(validating: file.id) else {
            throw PackLoadError.invalidPackID(file.id)
        }
        let safe = file.safePatterns.map { NamedPattern(name: $0.name, pattern: $0.pattern) }
        let destructive = try file.destructivePatterns.map { row -> DestructiveRule in
            guard let severity = Severity(rawValue: row.severity) else {
                throw PackLoadError.invalidSeverity(row.severity)
            }
            return DestructiveRule(
                name: row.name,
                pattern: row.pattern,
                severity: severity,
                reason: row.description,
                explanation: row.explanation
            )
        }
        return PackSnapshot(
            id: packID,
            name: file.name,
            description: file.description,
            keywords: file.keywords,
            safe: safe,
            destructive: destructive
        )
    }
}

public enum PackLoadError: Error, Equatable {
    case missingResource(String)
    case invalidPackID(String)
    case invalidSeverity(String)
    case emptyCorePack(String)
}
