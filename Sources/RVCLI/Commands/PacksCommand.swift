import ArgumentParser
import Foundation
import RVDomain
import RVPacks
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
        guard let home = HomeDirectory.process() else {
            FileHandle.standardError.write(Data("rv packs: HOME is not set\n".utf8))
            throw ExitCode(1)
        }
        // Always load full snapshot; filtering is local so --json and pretty share the same view.
        let full = try PacksFacade.list(home: home, enabledOnly: false)
        var rows = full.packs

        if let cat = category?.trimmingCharacters(in: .whitespacesAndNewlines), !cat.isEmpty {
            rows = rows.filter { $0.category == cat }
        }
        if let q = search?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty {
            let needle = q.lowercased()
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

        if format.json || format.robot {
            // JSON respects same filters; counts reflect filtered view's enabled vs filtered total for discoverability,
            // but keep original total for legend parity when no filter.
            let enabledInView = rows.filter(\.enabled).count
            let payload = packsRobotPayload(
                rows: rows.map(packsRobotRow),
                enabledCount: enabledInView,
                totalCount: rows.count
            )
            let text = RobotDocument.packsList(payload).render()
            FileHandle.standardOutput.write(Data((text + "\n").utf8))
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
            FileHandle.standardOutput.write(Data(hint.utf8))
            return
        }

        // Replica: `rv packs` default is upstream grouped `Available packs:` (like --all).
        // Collapsed quiet path removed; use --enabled/--category/--search to narrow.
        let verboseFlag = verbose
        let expandFlag = expand
        let maxPat = max(1, maxPatterns)

        // Load pattern details only when verbose (matches upstream --verbose + --expand).
        let groupedRows: [(id: PackID, name: String, category: String, description: String, enabled: Bool, safe: Int, destructive: Int, safePatterns: [NamedPattern], destructivePatterns: [DestructiveRule])]
        if verboseFlag {
            groupedRows = rows.map { r in
                let doc = try? PackRegistry.loadDocument(id: r.id.rawValue)
                return (
                    id: r.id,
                    name: r.name,
                    category: r.category,
                    description: r.description,
                    enabled: r.enabled,
                    safe: r.safePatternCount,
                    destructive: r.destructivePatternCount,
                    safePatterns: doc?.safe ?? [],
                    destructivePatterns: doc?.destructive ?? []
                )
            }
        } else {
            groupedRows = rows.map {
                (id: $0.id, name: $0.name, category: $0.category, description: $0.description, enabled: $0.enabled, safe: $0.safePatternCount, destructive: $0.destructivePatternCount, safePatterns: [], destructivePatterns: [])
            }
        }
        let enabledInView = rows.filter(\.enabled).count
        let model = groupedPacksViewModel(rows: groupedRows, enabledCount: enabledInView, totalCount: rows.count)

        let appearance = CLIAppearance.resolve(
            json: format.json,
            robot: format.robot,
            plain: format.plain,
            noColor: format.noColor
        )
        let text = PacksListFormat.prettyGrouped(model, appearance: appearance, verbose: verboseFlag, expand: expandFlag, maxPatterns: maxPat, collapsed: false)
        FileHandle.standardOutput.write(Data(text.utf8))
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
            guard let home = HomeDirectory.process() else {
                FileHandle.standardError.write(Data("rv packs: HOME is not set\n".utf8))
                throw ExitCode(1)
            }
            let row: PacksListRow
            do {
                guard let packID = PackID(validating: id) else {
                    FileHandle.standardError.write(Data("unknown pack id: \(id)\n".utf8))
                    throw ExitCode(1)
                }
                row = try PacksFacade.info(home: home, id: packID)
            } catch PacksCommandError.packNotFound {
                throw ExitCode(1)
            }
            if format.json || format.robot {
                let text = RobotDocument.packsInfo(packsRobotRow(row)).render()
                FileHandle.standardOutput.write(Data((text + "\n").utf8))
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
            FileHandle.standardOutput.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        }
    }
}

private func mutate(ids: [String], enabling: Bool) throws {
    guard !ids.isEmpty else {
        throw ValidationError("missing pack id")
    }
    guard let home = HomeDirectory.process() else {
        FileHandle.standardError.write(Data("rv packs: HOME is not set\n".utf8))
        throw ExitCode(1)
    }
    let result: PacksMutationResult
    do {
        result = enabling
            ? try PacksFacade.enable(home: home, ids: ids)
            : try PacksFacade.disable(home: home, ids: ids)
    } catch PacksCommandError.unknownID(let token) {
        FileHandle.standardError.write(Data("unknown pack id: \(token.rawValue)\n".utf8))
        throw ExitCode(1)
    } catch PacksCommandError.criticalPatternUncompilable(let rule) {
        FileHandle.standardError.write(Data("critical pattern uncompilable: \(rule.rawValue)\n".utf8))
        throw ExitCode(1)
    } catch {
        throw ExitCode(1)
    }
    let verb = enabling ? "enabled" : "disabled"
    let changed = result.changed.isEmpty ? "none" : result.changed.map(\.rawValue).joined(separator: ", ")
    let line =
        "\(verb): \(changed) (\(result.enabledCount)/\(result.totalCount) enabled)\n"
    FileHandle.standardOutput.write(Data(line.utf8))
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
        return PrettyWriter.join(PacksRenderer().renderGrouped(model, palette: palette, verbose: verbose, expand: expand, maxPatterns: maxPatterns, collapsed: collapsed))
    }
}

private func packsRobotRow(_ row: PacksListRow) -> PacksRobotRow {
    PacksRobotRow(
        id: row.id,
        name: row.name,
        category: row.category,
        description: row.description,
        enabled: row.enabled,
        safePatternCount: row.safePatternCount,
        destructivePatternCount: row.destructivePatternCount
    )
}
