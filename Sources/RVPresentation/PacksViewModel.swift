import RVDomain

public struct PackRow: Equatable, Sendable {
    public var id: PackID
    public var enabled: Bool
    public var summary: String

    public init(id: PackID, enabled: Bool, summary: String) {
        self.id = id
        self.enabled = enabled
        self.summary = summary
    }
}

public struct PacksViewModel: Equatable, Sendable {
    public var rows: [PackRow]

    public init(rows: [PackRow]) {
        self.rows = rows
    }
}

public func packsViewModel(enabled: [PackID], catalog: [(PackID, String)]) -> PacksViewModel {
    let on = Set(enabled)
    let rows = catalog.map { item in
        PackRow(id: item.0, enabled: on.contains(item.0), summary: item.1)
    }
    return PacksViewModel(rows: rows)
}

// MARK: - Grouped pack presentation

/// A pack row used by the grouped catalog presentation.
public struct GroupedPackRow: Equatable, Sendable {
    /// The stable pack identifier.
    public var id: PackID
    /// The human-readable pack name.
    public var name: String
    /// The catalog category containing the pack.
    public var category: String
    /// The short description shown in verbose output.
    public var description: String
    /// Whether the pack is in the effective enabled set.
    public var enabled: Bool
    /// The number of safe patterns in the pack.
    public var safePatternCount: Int
    /// The number of destructive rules in the pack.
    public var destructivePatternCount: Int
    /// The safe patterns shown by verbose expansion.
    public var safePatterns: [NamedPattern]
    /// The destructive rules shown by verbose expansion.
    public var destructivePatterns: [DestructiveRule]

    /// Creates a grouped pack row.
    public init(
        id: PackID,
        name: String,
        category: String,
        description: String,
        enabled: Bool,
        safePatternCount: Int,
        destructivePatternCount: Int,
        safePatterns: [NamedPattern] = [],
        destructivePatterns: [DestructiveRule] = []
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.description = description
        self.enabled = enabled
        self.safePatternCount = safePatternCount
        self.destructivePatternCount = destructivePatternCount
        self.safePatterns = safePatterns
        self.destructivePatterns = destructivePatterns
    }
}

/// Packs grouped by their catalog category.
public struct PackCategoryGroup: Equatable, Sendable {
    /// The category identifier.
    public var category: String
    /// The packs in this category, sorted by stable identifier.
    public var packs: [GroupedPackRow]

    /// Creates a category group.
    public init(category: String, packs: [GroupedPackRow]) {
        self.category = category
        self.packs = packs
    }

    /// The number of enabled packs in the group.
    public var enabledCount: Int { packs.filter(\.enabled).count }
    /// The number of packs in the group.
    public var totalCount: Int { packs.count }
}

/// The complete grouped pack catalog used by the TUI renderer.
public struct PacksGroupedViewModel: Equatable, Sendable {
    /// The sorted category groups.
    public var groups: [PackCategoryGroup]
    /// The catalog-wide enabled count.
    public var enabledCount: Int
    /// The catalog-wide pack count.
    public var totalCount: Int

    /// Creates a grouped pack view model.
    public init(groups: [PackCategoryGroup], enabledCount: Int, totalCount: Int) {
        self.groups = groups
        self.enabledCount = enabledCount
        self.totalCount = totalCount
    }
}

/// Groups pack rows by category and sorts both categories and pack IDs.
///
/// - Parameters:
///   - rows: The rows to group.
///   - enabledCount: The catalog-wide enabled count.
///   - totalCount: The catalog-wide pack count.
/// - Returns: A deterministic grouped view model.
public func groupedPacksViewModel(
    rows: [GroupedPackRow],
    enabledCount: Int,
    totalCount: Int
) -> PacksGroupedViewModel {
    var byCategory: [String: [GroupedPackRow]] = [:]
    for row in rows {
        byCategory[row.category, default: []].append(row)
    }
    let groups = byCategory
        .map { (cat, packs) in
            PackCategoryGroup(category: cat, packs: packs.sorted { $0.id.rawValue < $1.id.rawValue })
        }
        .sorted { $0.category < $1.category }
    return PacksGroupedViewModel(groups: groups, enabledCount: enabledCount, totalCount: totalCount)
}
