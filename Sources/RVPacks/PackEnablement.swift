import Foundation
import RVDomain

public enum PackSetError: Error, Equatable, Sendable {
    case unknownID(SelectionToken)
}

/// Defaults ∪ expand(enabled) − expand(disabled), with pin tier ordering.
public enum PackSet {
    public static let defaultIDs: [PackID] = [.coreFilesystem, .coreGit]

    public static func expand(
        _ tokens: [SelectionToken],
        index: PackIndex,
        rejectUnknown: Bool = false
    ) throws -> Set<PackID> {
        var expanded = Set<PackID>()
        for token in tokens {
            switch token {
            case .id(let id):
                guard index.packIDs.contains(id.rawValue) else {
                    if rejectUnknown {
                        throw PackSetError.unknownID(token)
                    }
                    continue
                }
                expanded.insert(id)
            case .category(let name):
                guard let members = index.categories[name] else {
                    if rejectUnknown {
                        throw PackSetError.unknownID(token)
                    }
                    continue
                }
                expanded.formUnion(members.compactMap(PackID.init(validating:)))
            case .preset(let name):
                guard let members = index.presets[name] else {
                    if rejectUnknown {
                        throw PackSetError.unknownID(token)
                    }
                    continue
                }
                expanded.formUnion(members.compactMap(PackID.init(validating:)))
            }
        }
        return expanded
    }

    public static func effectiveOrdered(
        enabled: [SelectionToken],
        disabled: [SelectionToken],
        index: PackIndex,
        rejectUnknown: Bool = false
    ) throws -> [PackID] {
        let defaults = Set(defaultIDs)
        let on = try expand(enabled, index: index, rejectUnknown: rejectUnknown)
        let off = try expand(disabled, index: index, rejectUnknown: rejectUnknown)
        return order(defaults.union(on).subtracting(off), index: index)
    }

    public static func order(_ ids: Set<PackID>, index: PackIndex) -> [PackID] {
        let known = Set(index.packIDs)
        return ids
            .filter { known.contains($0.rawValue) }
            .sorted { lhs, rhs in
                let tierL = tier(for: lhs, index: index)
                let tierR = tier(for: rhs, index: index)
                if tierL != tierR { return tierL < tierR }
                return lhs.rawValue < rhs.rawValue
            }
    }

    public static func tier(for packID: PackID, index: PackIndex) -> Int {
        index.tiers[categoryOf(packID.rawValue)] ?? 13
    }
}
