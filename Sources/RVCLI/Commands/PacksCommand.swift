import ArgumentParser
import Foundation
import RVDomain
import RVPolicy
import RVPresentation
import RVService
import RVTheme
import RVTUI

struct Packs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "packs",
        abstract: "List and enable or disable packs.",
        subcommands: [Enable.self, Disable.self, Info.self],
        defaultSubcommand: nil
    )

    @Flag(name: .customLong("enabled"), help: "Only enabled packs.")
    var enabledOnly = false

    @Flag(name: .customLong("all"), help: "List all packs grouped by category. (Default: all)")
    var all = false

    @Flag(name: .customLong("verbose"), help: "Show descriptions and pattern counts.")
    var verbose = false

    @Flag(name: .customLong("expand"), help: "Show all patterns when --verbose. By default truncates to --max-patterns.")
    var expand = false

    @Option(name: .customLong("max-patterns"), help: "Maximum patterns per section when --verbose (default 10).")
    var maxPatterns: Int = 10

    @Option(name: .customLong("category"), help: "Filter to a single category.")
    var category: String?

    @Option(name: .customLong("search"), help: "Filter by id, name, or description.")
    var search: String?

    @OptionGroup
    var format: FormatFlags

    func run() async throws {
        let ctx = CommandContext.current(command: "packs", format: format)
        let home = try ctx.requireHome()
        // Always load the full snapshot; filtering is local so JSON and pretty share the same view.
        let full = try PacksFacade.list(home: home, enabledOnly: false)
        let filtered = PacksListFilter.apply(
            full,
            category: category,
            search: search,
            enabledOnly: enabledOnly && !all
        )
        let rows = filtered.packs

        if ctx.explicitRobot {
            let payload = packsRobotPayload(
                rows: rows.map(packsRobotRow),
                enabledCount: filtered.enabledCount,
                totalCount: filtered.totalCount
            )
            let text = try RobotDocument.packsList(payload).render()
            ctx.writeStdout(text + "\n")
            return
        }

        if rows.isEmpty {
            let hint: String
            if category != nil || search != nil {
                hint = "No packs match. Try `rv packs` or `rv packs --search <term>`.\n"
            } else if enabledOnly {
                hint = "No packs enabled. Try `rv packs` to see available packs.\n"
            } else {
                hint = "No packs found.\n"
            }
            ctx.writeStdout(hint)
            return
        }

        // `rv packs` defaults to the complete grouped catalog; filters narrow that view.
        // Collapsed quiet path removed; use --enabled/--category/--search to narrow.
        let verboseFlag = verbose
        let expandFlag = expand
        let maxPat = max(1, maxPatterns)

        let groupedRows = rows.map { row in
            GroupedPackRow(
                id: row.id,
                name: row.name,
                category: row.category,
                description: row.description,
                isEnabled: row.enabled,
                safePatternCount: row.safePatternCount,
                destructivePatternCount: row.destructivePatternCount,
                safePatterns: verboseFlag ? row.safePatterns : [],
                destructivePatterns: verboseFlag ? row.destructivePatterns : []
            )
        }
        let model = groupedPacksViewModel(
            rows: groupedRows,
            enabledCount: filtered.enabledCount,
            totalCount: filtered.totalCount
        )

        let text = PacksListFormat.prettyGrouped(model, appearance: ctx.appearance, verbose: verboseFlag, expand: expandFlag, maxPatterns: maxPat, collapsed: false)
        ctx.writeStdout(text)
    }

    struct Enable: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "enable",
            abstract: "Enable pack, category, or preset IDs."
        )

        @Argument(help: "Pack, category, or preset IDs.")
        var ids: [String]

        func run() async throws {
            try mutate(ids: ids, enabling: true)
        }
    }

    struct Disable: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "disable",
            abstract: "Disable pack, category, or preset IDs."
        )

        @Argument(help: "Pack, category, or preset IDs.")
        var ids: [String]

        func run() async throws {
            try mutate(ids: ids, enabling: false)
        }
    }

    struct Info: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "info",
            abstract: "Show one pack."
        )

        @OptionGroup
        var format: FormatFlags

        @Argument(help: "Pack ID.")
        var id: String

        func run() async throws {
            let ctx = CommandContext.current(command: "packs", format: format)
            let home = try ctx.requireHome()
            let row: PacksListRow
            do {
                guard let packID = PackID(validating: id) else {
                    try ctx.fail("unknown pack id: \(id)\n")
                }
                row = try PacksFacade.info(home: home, id: packID)
            } catch PacksCommandError.packNotFound {
                throw ExitCode(1)
            }
            if ctx.explicitRobot {
                let text = try RobotDocument.packsInfo(packsRobotRow(row)).render()
                ctx.writeStdout(text + "\n")
                return
            }
            let lines = [
                "id: \(row.id.rawValue)",
                "name: \(row.name)",
                "category: \(row.category)",
                "enabled: \(row.enabled)",
                "safe_patterns: \(row.safePatternCount)",
                "destructive_patterns: \(row.destructivePatternCount)",
            ]
            ctx.writeStdout(lines.joined(separator: "\n") + "\n")
        }
    }
}

enum PacksListFilter {
    static func apply(
        _ snapshot: PacksListSnapshot,
        category: String?,
        search: String?,
        enabledOnly: Bool
    ) -> PacksListSnapshot {
        var rows = snapshot.packs

        if let category = category?.trimmingCharacters(in: .whitespacesAndNewlines), !category.isEmpty {
            rows = rows.filter { $0.category == category }
        }
        if let search = search?.trimmingCharacters(in: .whitespacesAndNewlines), !search.isEmpty {
            let needle = search.lowercased()
            rows = rows.filter {
                $0.id.rawValue.lowercased().contains(needle)
                    || $0.name.lowercased().contains(needle)
                    || $0.category.lowercased().contains(needle)
                    || $0.description.lowercased().contains(needle)
            }
        }
        if enabledOnly {
            rows = rows.filter(\.enabled)
        }

        return PacksListSnapshot(
            packs: rows,
            enabledCount: snapshot.enabledCount,
            totalCount: snapshot.totalCount
        )
    }
}

private func mutate(ids: [String], enabling: Bool) throws {
    try LocalControlBoundary.requireOwnerAuthorization()
    try applyPackMutation(ids: ids, enabling: enabling)
}

/// Pack enable/disable behind the owner gate. The gate throws until
/// authenticated service mutation routes exist; without this body an
/// implemented gate would report success while changing nothing.
func applyPackMutation(ids: [String], enabling: Bool) throws {
    guard !ids.isEmpty else {
        throw ValidationError("missing pack id")
    }
    let home = try CommandContext.requireHome(command: "packs")
    let result: PacksMutationResult
    do {
        result = enabling
            ? try PacksFacade.enable(home: home, ids: ids)
            : try PacksFacade.disable(home: home, ids: ids)
    } catch PacksCommandError.unknownID(let token) {
        try CommandContext.fail("unknown pack id: \(token.rawValue)\n")
    } catch PacksCommandError.criticalPatternUncompilable(let rule) {
        try CommandContext.fail("critical pattern uncompilable: \(rule.rawValue)\n")
    } catch {
        throw ExitCode(1)
    }
    let verb = enabling ? "enabled" : "disabled"
    let changed = result.changed.isEmpty ? "none" : result.changed.map(\.rawValue).joined(separator: ", ")
    let line =
        "\(verb): \(changed) (\(result.enabledCount)/\(result.totalCount) enabled)\n"
    CommandContext.writeStdout(line)
}

enum PacksListFormat {
    static func pretty(_ model: PacksViewModel, appearance: CLIAppearance) -> String {
        let palette: Palette
        switch appearance {
        case .robot:
            palette = colorOffPalette
        case .pretty(let value):
            palette = value
        }
        return PrettyWriter.join(PacksRenderer().render(model, palette: palette))
    }

    static func prettyGrouped(
        _ model: PacksGroupedViewModel,
        appearance: CLIAppearance,
        verbose: Bool,
        expand: Bool = false,
        maxPatterns: Int = 10,
        collapsed: Bool = false
    ) -> String {
        let palette: Palette
        switch appearance {
        case .robot:
            palette = colorOffPalette
        case .pretty(let value):
            palette = value
        }
        return PrettyWriter.join(
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
        )
    }
}

private func packsRobotRow(_ row: PacksListRow) -> PacksRobotRow {
    PacksRobotRow(
        id: row.id,
        name: row.name,
        category: row.category,
        description: row.description,
        isEnabled: row.enabled,
        safePatternCount: row.safePatternCount,
        destructivePatternCount: row.destructivePatternCount
    )
}
