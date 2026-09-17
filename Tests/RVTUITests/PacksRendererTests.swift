import Testing
import RVDomain
import RVPresentation
import RVTheme
@testable import RVTUI

private func safe(_ name: String, _ pattern: String) -> NamedPattern {
    NamedPattern(name: name, pattern: pattern)
}

private func destructive(
    _ name: String,
    _ pattern: String,
    severity: Severity = .high
) -> DestructiveRule {
    DestructiveRule(name: name, pattern: pattern, severity: severity, reason: "reason")
}

private func row(
    id: PackID,
    name: String = "Pack",
    category: String,
    description: String = "Protects commands",
    enabled: Bool,
    safePatterns: [NamedPattern] = [],
    destructivePatterns: [DestructiveRule] = []
) -> GroupedPackRow {
    GroupedPackRow(
        id: id,
        name: name,
        category: category,
        description: description,
        isEnabled: enabled,
        safePatternCount: safePatterns.count,
        destructivePatternCount: destructivePatterns.count,
        safePatterns: safePatterns,
        destructivePatterns: destructivePatterns
    )
}

private func grouped(_ rows: [GroupedPackRow]) -> PacksGroupedViewModel {
    groupedPacksViewModel(
        rows: rows,
        enabledCount: rows.filter(\.isEnabled).count,
        totalCount: rows.count
    )
}

private func manySafe(_ count: Int) -> [NamedPattern] {
    (1...count).map { safe("s\($0)", "SAFE\($0)") }
}

private func manyDestructive(_ count: Int) -> [DestructiveRule] {
    (1...count).map { destructive("d\($0)", "DEST\($0)") }
}

private func renderGrouped(
    _ model: PacksGroupedViewModel,
    verbose: Bool = false,
    expand: Bool = false,
    maxPatterns: Int = 10,
    collapsed: Bool = false,
    palette: Palette = colorOffPalette
) -> [String] {
    PacksRenderer().render(
        PacksGroupedFrame(
            model: model,
            verbose: verbose,
            expand: expand,
            maxPatterns: maxPatterns,
            collapsed: collapsed
        ),
        palette: palette
    )
}

@Test func packsRenderer_emptyGroups_saysNoMatch() {
    let lines = renderGrouped(grouped([]))
    #expect(lines == ["No packs match."])
}

@Test func packsRenderer_tree_marksEnabledAndDisabled() {
    let model = grouped([
        row(id: .coreGit, category: "core", enabled: true),
        row(id: .coreFilesystem, category: "core", enabled: false),
    ])
    let lines = renderGrouped(model)
    let text = lines.joined(separator: "\n")
    #expect(lines.first == "Available Packs")
    #expect(text.contains("● core.git"))
    #expect(text.contains("○ core.filesystem"))
    #expect(text.contains("Legend: ● = enabled, ○ = disabled"))
    #expect(text.contains("Enable packs in ~/.config/rv/config.toml"))
}

@Test func packsRenderer_treeVerbose_countsWithoutPatternsStayLeaves() {
    let model = grouped([
        row(
            id: .coreGit,
            category: "core",
            description: "Protects git\\ commands",
            enabled: true
        ),
    ])
    let text = renderGrouped(model, verbose: true).joined(separator: "\n")
    #expect(text.contains("● core.git - Protects git commands (0 safe, 0 destructive)"))
    #expect(text.contains("Safe patterns") == false)
}

@Test func packsRenderer_treeVerbose_expandsSafeAndDestructive() {
    let model = grouped([
        row(
            id: .coreGit,
            category: "core",
            enabled: true,
            safePatterns: [safe("status", "git status")],
            destructivePatterns: [destructive("reset", "git reset --hard", severity: .critical)]
        ),
    ])
    let lines = renderGrouped(model, verbose: true, expand: true)
    let text = lines.joined(separator: "\n")
    #expect(text.contains("Safe patterns"))
    #expect(text.contains("status: git status"))
    #expect(text.contains("Destructive patterns"))
    #expect(text.contains("reset [critical]: git reset --hard"))
    #expect(text.contains("more patterns") == false)
}

@Test func packsRenderer_treeVerbose_truncatesWhenOverMax() {
    let model = grouped([
        row(
            id: .coreFilesystem,
            category: "core",
            enabled: true,
            safePatterns: manySafe(5),
            destructivePatterns: manyDestructive(5)
        ),
    ])
    let text = renderGrouped(model, verbose: true, expand: false, maxPatterns: 2)
        .joined(separator: "\n")
    #expect(text.contains("Safe patterns (5 total)"))
    #expect(text.contains("Destructive patterns (5 total)"))
    #expect(text.contains("... 3 more patterns (--expand to show all)"))
    #expect(text.contains("s1: SAFE1"))
    #expect(text.contains("s5: SAFE5"))
    #expect(text.contains("s3: SAFE3") == false)
}

@Test func packsRenderer_treeVerbose_maxPatternsBelowOneUsesOne() {
    let model = grouped([
        row(
            id: .coreGit,
            category: "core",
            enabled: false,
            safePatterns: manySafe(4)
        ),
    ])
    let text = renderGrouped(model, verbose: true, maxPatterns: 0).joined(separator: "\n")
    #expect(text.contains("Safe patterns (4 total)"))
    #expect(text.contains("s1: SAFE1"))
    #expect(text.contains("... 3 more patterns (--expand to show all)"))
    #expect(text.contains("s2: SAFE2") == false)
}

@Test func packsRenderer_collapsed_allOffIsMutedCount() {
    let model = grouped([
        row(id: .coreGit, category: "core", enabled: false),
        row(id: .coreFilesystem, category: "core", enabled: false),
    ])
    let lines = renderGrouped(model, collapsed: true)
    #expect(lines == ["core: 2 off"])
}

@Test func packsRenderer_collapsed_listsEnabledAndOffRemainder() {
    let model = grouped([
        row(id: .coreGit, name: "Core Git", category: "core", enabled: true),
        row(id: .coreFilesystem, category: "core", enabled: false),
        row(id: PackID(rawValue: "database.sqlite"), category: "database", enabled: false),
    ])
    let lines = renderGrouped(model, collapsed: true)
    #expect(lines.contains("  core:"))
    #expect(lines.contains { $0.contains("✓") && $0.contains("core.git") && $0.contains("Core Git") })
    #expect(lines.contains("    ○ 1 off"))
    #expect(lines.contains("database: 1 off"))
}

@Test func packsRenderer_collapsedVerbose_unwrapsAndTruncatesPatterns() {
    let model = grouped([
        row(
            id: .coreGit,
            category: "core",
            description: "Protects git\\  history",
            enabled: true,
            safePatterns: manySafe(6),
            destructivePatterns: manyDestructive(3)
        ),
    ])
    let text = renderGrouped(model, verbose: true, expand: false, maxPatterns: 3, collapsed: true)
        .joined(separator: "\n")
    #expect(text.contains("✓ core.git - Protects git history (6 safe, 3 destructive)"))
    #expect(text.contains("      Safe patterns:"))
    #expect(text.contains("        - s1: SAFE1"))
    #expect(text.contains("        - ... 3 more patterns (--expand to show all)"))
    #expect(text.contains("        - s6: SAFE6"))
    #expect(text.contains("      Destructive patterns:"))
    #expect(text.contains("        - d1 [high]: DEST1"))
}

@Test func packsRenderer_collapsedVerbose_expandShowsEveryPattern() {
    let model = grouped([
        row(
            id: .coreGit,
            category: "core",
            enabled: true,
            safePatterns: manySafe(4),
            destructivePatterns: []
        ),
    ])
    let text = renderGrouped(model, verbose: true, expand: true, maxPatterns: 1, collapsed: true)
        .joined(separator: "\n")
    #expect(text.contains("        - s2: SAFE2"))
    #expect(text.contains("        - s4: SAFE4"))
    #expect(text.contains("more patterns") == false)
}

@Test func packsRenderer_legacyFlat_padsIdsAndPaintsFlags() {
    let vm = PacksViewModel.make(
        enabled: [.coreGit],
        catalog: [
            (id: .coreFilesystem, summary: "filesystem"),
            (id: .coreGit, summary: "git"),
        ]
    )
    let off = PacksRenderer().render(vm, palette: colorOffPalette)
    #expect(off == [
        "core.filesystem  off",
        "core.git         on",
    ])

    let on = Palette(for: ColorCapability(colorsEnabled: true))
    let painted = PacksRenderer().render(vm, palette: on)
    #expect(painted[0].contains(on.muted))
    #expect(painted[1].contains(on.allow))
}

@Test func packsRenderer_groupedFrame_defaultsToTree() {
    let frame = PacksGroupedFrame(
        model: grouped([row(id: .coreGit, category: "core", enabled: true)])
    )
    #expect(frame.verbose == false)
    #expect(frame.expand == false)
    #expect(frame.maxPatterns == 10)
    #expect(frame.collapsed == false)
    let lines = PacksRenderer().render(frame, palette: colorOffPalette)
    #expect(lines.first == "Available Packs")
}

@Test func packsRenderer_colorOn_paintsTreeLegend() {
    let model = grouped([
        row(id: .coreGit, category: "core", enabled: true),
        row(id: .coreFilesystem, category: "core", enabled: false),
    ])
    let palette = Palette(for: ColorCapability(colorsEnabled: true))
    let lines = renderGrouped(model, palette: palette)
    #expect(lines.contains { $0.contains(palette.allow) && $0.contains("●") })
    #expect(lines.contains { $0.contains(palette.muted) && $0.contains("○") })
    #expect(lines.contains { $0.contains(palette.muted) && $0.contains("Legend") })
}
