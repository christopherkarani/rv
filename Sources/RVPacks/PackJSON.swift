import Foundation
import RVDomain

/// Codable document for one bundled pack JSON file.
public struct PackDocument: Equatable, Sendable {
    public var id: PackID
    public var name: String
    public var description: String
    public var category: String
    public var keywords: [String]
    public var safe: [NamedPattern]
    public var destructive: [DestructiveRule]
    public var enabledByDefault: Bool
    /// One entry per destructive rule, in file order. Not part of
    /// `snapshot`: the engine never sees it.
    public var guidance: [RuleGuidance]

    public init(
        id: PackID,
        name: String,
        description: String,
        category: String,
        keywords: [String],
        safe: [NamedPattern],
        destructive: [DestructiveRule],
        enabledByDefault: Bool,
        guidance: [RuleGuidance] = []
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.category = category
        self.keywords = keywords
        self.safe = safe
        self.destructive = destructive
        self.enabledByDefault = enabledByDefault
        self.guidance = guidance
    }

    /// Guidance for one of this pack's rules, by pattern name.
    public func guidance(forRule name: String) -> RuleGuidance? {
        guidance.first { $0.ruleID.pattern == name }
    }

    public var snapshot: PackSnapshot {
        PackSnapshot(
            id: id,
            name: name,
            description: description,
            keywords: keywords,
            safe: safe,
            destructive: destructive
        )
    }
}

struct PackFile: Decodable {
    var schemaVersion: Int
    var id: String
    var name: String
    var version: String?
    var description: String
    var category: String?
    var enabledByDefault: Bool?
    var keywords: [String]
    var safePatterns: [SafeFile]
    var destructivePatterns: [DestructiveFile]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case id
        case name
        case version
        case description
        case category
        case enabledByDefault = "enabled_by_default"
        case keywords
        case safePatterns = "safe_patterns"
        case destructivePatterns = "destructive_patterns"
        case reason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        if let description = try container.decodeIfPresent(String.self, forKey: .description) {
            self.description = description
        } else if let reason = try container.decodeIfPresent(String.self, forKey: .reason) {
            self.description = reason
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.description,
                .init(codingPath: container.codingPath, debugDescription: "missing description")
            )
        }
        category = try container.decodeIfPresent(String.self, forKey: .category)
        enabledByDefault = try container.decodeIfPresent(Bool.self, forKey: .enabledByDefault)
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords) ?? []
        safePatterns = try container.decodeIfPresent([SafeFile].self, forKey: .safePatterns) ?? []
        destructivePatterns =
            try container.decodeIfPresent([DestructiveFile].self, forKey: .destructivePatterns) ?? []
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
    var reason: String?
    var saferCommand: String?
    var whoActs: String?
    var examples: ExamplesFile?

    enum CodingKeys: String, CodingKey {
        case name
        case pattern
        case severity
        case description
        case explanation
        case reason
        case saferCommand = "safer_command"
        case whoActs = "who_acts"
        case examples
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        pattern = try container.decode(String.self, forKey: .pattern)
        severity = try container.decodeIfPresent(String.self, forKey: .severity) ?? "high"
        if let description = try container.decodeIfPresent(String.self, forKey: .description) {
            self.description = description
        } else if let reason = try container.decodeIfPresent(String.self, forKey: .reason) {
            self.description = reason
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.description,
                .init(codingPath: container.codingPath, debugDescription: "missing description")
            )
        }
        explanation = try container.decodeIfPresent(String.self, forKey: .explanation)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        // An empty value says nothing; it must not render as advice.
        saferCommand = try container.decodeIfPresent(String.self, forKey: .saferCommand).flatMap(nonBlank)
        whoActs = try container.decodeIfPresent(String.self, forKey: .whoActs).flatMap(nonBlank)
        examples = try container.decodeIfPresent(ExamplesFile.self, forKey: .examples)
    }
}

private func nonBlank(_ text: String) -> String? {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
}

/// `examples` holds `stop` and `allow` only. Any other key (`allowed`,
/// `deny`) is a typo that would silently drop examples, so it fails the load.
struct ExamplesFile: Decodable {
    var stop: [String]?
    var allow: [String]?

    enum CodingKeys: String, CodingKey {
        case stop
        case allow
    }

    init(from decoder: Decoder) throws {
        let any = try decoder.container(keyedBy: AnyKey.self)
        if let unknown = any.allKeys.first(where: { CodingKeys(stringValue: $0.stringValue) == nil }) {
            throw DecodingError.dataCorruptedError(
                forKey: unknown, in: any,
                debugDescription: "unknown examples key \(unknown.stringValue); expected stop or allow"
            )
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stop = try container.decodeIfPresent([String].self, forKey: .stop)
        allow = try container.decodeIfPresent([String].self, forKey: .allow)
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

public enum PackJSON {
    public static func decode(_ data: Data) throws -> PackSnapshot {
        try decodeDocument(data).snapshot
    }

    public static func decodeDocument(_ data: Data) throws -> PackDocument {
        let file = try JSONDecoder().decode(PackFile.self, from: data)
        guard let packID = PackID(validating: file.id) else {
            throw PackLoadError.invalidPackID(file.id)
        }
        let category = file.category ?? categoryOf(file.id)
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
        let guidance = file.destructivePatterns.map { row in
            RuleGuidance(
                ruleID: RuleID(pack: packID, pattern: row.name),
                saferCommand: row.saferCommand,
                whoActs: row.whoActs,
                examples: RuleExamples(
                    stop: row.examples?.stop ?? [],
                    allow: row.examples?.allow ?? []
                )
            )
        }
        let enabledByDefault =
            file.enabledByDefault
            ?? dayOnePackIDs.contains(packID)
        return PackDocument(
            id: packID,
            name: file.name,
            description: file.description,
            category: category,
            keywords: file.keywords,
            safe: safe,
            destructive: destructive,
            enabledByDefault: enabledByDefault,
            guidance: guidance
        )
    }
}

func categoryOf(_ packID: String) -> String {
    if let dot = packID.firstIndex(of: ".") {
        return String(packID[..<dot])
    }
    return packID
}

public enum PackLoadError: Error, Equatable {
    case missingResource(String)
    case invalidPackID(String)
    case invalidSeverity(String)
    case emptyCorePack(String)
    case invalidIndex
}
