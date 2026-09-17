import Testing
import RVDomain
@testable import RVPresentation

@Test func packsViewModel_helperMarksEnabledFromCatalog() {
    let vm = packsViewModel(
        enabled: [.coreGit],
        catalog: [
            (.coreFilesystem, "filesystem"),
            (.coreGit, "git"),
            (.systemDisk, "disk"),
        ]
    )
    #expect(vm.rows.map(\.id) == [.coreFilesystem, .coreGit, .systemDisk])
    #expect(vm.rows.map(\.isEnabled) == [false, true, false])
    #expect(vm.rows.map(\.summary) == ["filesystem", "git", "disk"])
}

@Test func packsViewModel_emptyCatalogIsEmpty() {
    let vm = PacksViewModel.make(enabled: dayOnePackIDs, catalog: [])
    #expect(vm.rows.isEmpty)
}

@Test func groupedPacksViewModel_sortsCategoriesAndPackIDs() {
    let later = GroupedPackRow(
        id: PackID(rawValue: "core.network"),
        name: "Network",
        category: "core",
        description: "network",
        isEnabled: false,
        safePatternCount: 0,
        destructivePatternCount: 1,
        safePatterns: [NamedPattern(name: "curl", pattern: "curl ")],
        destructivePatterns: [
            DestructiveRule(name: "dd", pattern: "dd ", severity: .high, reason: "wipe")
        ]
    )
    let git = GroupedPackRow(
        id: .coreGit,
        name: "Git",
        category: "core",
        description: "git",
        isEnabled: true,
        safePatternCount: 2,
        destructivePatternCount: 3
    )
    let sqlite = GroupedPackRow(
        id: PackID(rawValue: "database.sqlite"),
        name: "SQLite",
        category: "database",
        description: "sqlite",
        isEnabled: false,
        safePatternCount: 1,
        destructivePatternCount: 0
    )
    let model = groupedPacksViewModel(
        rows: [later, sqlite, git],
        enabledCount: 1,
        totalCount: 95
    )
    #expect(model.groups.map(\.category) == ["core", "database"])
    #expect(model.groups[0].packs.map(\.id.rawValue) == ["core.git", "core.network"])
    #expect(model.groups[0].enabledCount == 1)
    #expect(model.groups[0].totalCount == 2)
    #expect(model.groups[1].enabledCount == 0)
    #expect(model.groups[1].totalCount == 1)
    #expect(model.enabledCount == 1)
    #expect(model.totalCount == 95)
}

@Test func groupedPacksViewModel_emptyRowsHasZeroGroups() {
    let model = groupedPacksViewModel(rows: [], enabledCount: 0, totalCount: 0)
    #expect(model.groups.isEmpty)
    #expect(model.enabledCount == 0)
    #expect(model.totalCount == 0)
}
