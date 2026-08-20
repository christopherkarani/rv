import Foundation

public struct PackIndex: Equatable, Sendable {
    public var pinVersion: String
    public var pinTag: String
    public var pinCommit: String
    public var packCount: Int
    public var defaultEnabled: [String]
    public var categories: [String: [String]]
    public var presets: [String: [String]]
    public var tiers: [String: Int]

    public var packIDs: [String] {
        categories.values.flatMap { $0 }.sorted()
    }
}

struct PackIndexFile: Decodable {
    var schemaVersion: Int
    var pinVersion: String
    var pinTag: String
    var pinCommit: String
    var packCount: Int
    var defaultEnabled: [String]
    var categories: [String: [String]]
    var presets: [String: [String]]
    var tiers: [String: Int]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case pinVersion = "pin_version"
        case pinTag = "pin_tag"
        case pinCommit = "pin_commit"
        case packCount = "pack_count"
        case defaultEnabled = "default_enabled"
        case categories
        case presets
        case tiers
    }
}

public enum PackIndexJSON {
    public static func decode(_ data: Data) throws -> PackIndex {
        let file = try JSONDecoder().decode(PackIndexFile.self, from: data)
        guard file.packCount == 99, file.categories.count == 27 else {
            throw PackLoadError.invalidIndex
        }
        return PackIndex(
            pinVersion: file.pinVersion,
            pinTag: file.pinTag,
            pinCommit: file.pinCommit,
            packCount: file.packCount,
            defaultEnabled: file.defaultEnabled,
            categories: file.categories,
            presets: file.presets,
            tiers: file.tiers
        )
    }
}
