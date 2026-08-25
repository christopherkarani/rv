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

// MARK: - Grouped (quiet default)

public struct GroupedPackRow: Equatable, Sendable {
    public var id: PackID
    public var name: String
    public var category: String
    public var description: String
    public var enabled: Bool
    public var safePatternCount: Int
    public var destructivePatternCount: Int
    public var safePatterns: [NamedPattern]
    public var destructivePatterns: [DestructiveRule]

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

public struct PackCategoryGroup: Equatable, Sendable {
    public var category: String
    public var packs: [GroupedPackRow]

    public init(category: String, packs: [GroupedPackRow]) {
        self.category = category
        self.packs = packs
    }

    public var enabledCount: Int { packs.filter(\.enabled).count }
    public var totalCount: Int { packs.count }
}

public struct PacksGroupedViewModel: Equatable, Sendable {
    public var groups: [PackCategoryGroup]
    public var enabledCount: Int
    public var totalCount: Int

    public init(groups: [PackCategoryGroup], enabledCount: Int, totalCount: Int) {
        self.groups = groups
        self.enabledCount = enabledCount
        self.totalCount = totalCount
    }
}

public func groupedPacksViewModel(
    rows: [(id: PackID, name: String, category: String, description: String, enabled: Bool, safe: Int, destructive: Int, safePatterns: [NamedPattern], destructivePatterns: [DestructiveRule])],
    enabledCount: Int,
    totalCount: Int
) -> PacksGroupedViewModel {
    var byCategory: [String: [GroupedPackRow]] = [:]
    for r in rows {
        let row = GroupedPackRow(
            id: r.id,
            name: r.name,
            category: r.category,
            description: r.description,
            enabled: r.enabled,
            safePatternCount: r.safe,
            destructivePatternCount: r.destructive,
            safePatterns: r.safePatterns,
            destructivePatterns: r.destructivePatterns
        )
        byCategory[r.category, default: []].append(row)
    }
    let groups = byCategory
        .map { (cat, packs) in
            PackCategoryGroup(category: cat, packs: packs.sorted { $0.id.rawValue < $1.id.rawValue })
        }
        .sorted { $0.category < $1.category }
    return PacksGroupedViewModel(groups: groups, enabledCount: enabledCount, totalCount: totalCount)
}

public func groupedPacksViewModel(
    rows: [(id: PackID, name: String, category: String, description: String, enabled: Bool, safe: Int, destructive: Int)],
    enabledCount: Int,
    totalCount: Int
) -> PacksGroupedViewModel {
    groupedPacksViewModel(
        rows: rows.map { (id: $0.id, name: $0.name, category: $0.category, description: $0.description, enabled: $0.enabled, safe: $0.safe, destructive: $0.destructive, safePatterns: [], destructivePatterns: []) },
        enabledCount: enabledCount,
        totalCount: totalCount
    )
}
