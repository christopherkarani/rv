import Foundation
import RVDomain

public enum PackSetError: Error, Equatable, Sendable {
    case unknownID(String)
}

/// Defaults ∪ expand(enabled) − expand(disabled), with pin tier ordering.
public enum PackSet {
    public static let defaultIDs: [PackID] = [.coreFilesystem, .coreGit]

    public static func expand(
        _ tokens: [String],
        index: PackIndex,
        rejectUnknown: Bool
    ) throws -> Set<String> {
        var expanded = Set<String>()
        let knownPacks = Set(index.packIDs)
        let knownCategories = Set(index.categories.keys)
        let knownPresets = Set(index.presets.keys)

        for token in tokens {
            let isPack = knownPacks.contains(token)
            let isCategory = knownCategories.contains(token)
            let isPreset = knownPresets.contains(token)
            if !isPack && !isCategory && !isPreset {
                if rejectUnknown {
                    throw PackSetError.unknownID(token)
                }
                continue
            }
            if isCategory, let members = index.categories[token] {
                expanded.formUnion(members)
            }
            if isPreset, let members = index.presets[token] {
                expanded.formUnion(members)
            }
            if isPack {
                expanded.insert(token)
            }
        }
        return expanded
    }

    public static func effectiveOrdered(
        enabled: [String],
        disabled: [String],
        index: PackIndex,
        rejectUnknown: Bool = false
    ) throws -> [PackID] {
        let defaults = Set(defaultIDs.map(\.rawValue))
        let on = try expand(enabled, index: index, rejectUnknown: rejectUnknown)
        let off = try expand(disabled, index: index, rejectUnknown: rejectUnknown)
        let effective = defaults.union(on).subtracting(off)
        return order(effective, index: index)
    }

    public static func order(_ ids: Set<String>, index: PackIndex) -> [PackID] {
        let known = Set(index.packIDs)
        return ids
            .filter { known.contains($0) }
            .sorted { lhs, rhs in
                let tierL = tier(for: lhs, index: index)
                let tierR = tier(for: rhs, index: index)
                if tierL != tierR { return tierL < tierR }
                return lhs < rhs
            }
            .map { PackID(rawValue: $0) }
    }

    public static func tier(for packID: String, index: PackIndex) -> Int {
        let category = categoryOf(packID)
        return index.tiers[category] ?? 13
    }
}
