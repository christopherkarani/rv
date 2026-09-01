import Foundation
import RVDomain

public struct PackIndex: Equatable, Sendable {
    public var pinVersion: String
    public var pinTag: String
    public var pinCommit: String
    public var packCount: Int
    public var defaultEnabled: [PackID]
    public var categories: [String: [PackID]]
    public var presets: [String: [PackID]]
    public var tiers: [String: Int]

    public var packIDs: [PackID] {
        categories.values.flatMap { $0 }.sorted { $0.rawValue < $1.rawValue }
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
        guard file.packCount == 95, file.categories.count == 26 else {
            throw PackLoadError.invalidIndex
        }
        try validatePackReferences(file)
        return PackIndex(
            pinVersion: file.pinVersion,
            pinTag: file.pinTag,
            pinCommit: file.pinCommit,
            packCount: file.packCount,
            defaultEnabled: try packIDs(file.defaultEnabled),
            categories: try packMap(file.categories),
            presets: try packMap(file.presets),
            tiers: file.tiers
        )
    }

    private static func packIDs(_ raw: [String]) throws -> [PackID] {
        try raw.map { token in
            guard let id = PackID(validating: token) else {
                throw PackLoadError.invalidPackID(token)
            }
            return id
        }
    }

    private static func packMap(_ raw: [String: [String]]) throws -> [String: [PackID]] {
        var mapped: [String: [PackID]] = [:]
        mapped.reserveCapacity(raw.count)
        for (key, values) in raw {
            mapped[key] = try packIDs(values)
        }
        return mapped
    }

    private static func validatePackReferences(_ file: PackIndexFile) throws {
        var declared = Set(file.defaultEnabled)
        declared.formUnion(file.categories.values.flatMap { $0 })
        declared.formUnion(file.presets.values.flatMap { $0 })
        for raw in declared.sorted() where !PackID.isValid(raw) {
            throw PackLoadError.invalidPackID(raw)
        }
    }
}
