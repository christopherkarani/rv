import ArgumentParser
import Foundation
import RVDomain
import RVHistory
import RVPolicy
import RVPresentation
import RVService
import RVTheme
import RVTUI

struct Packs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "packs",
        abstract: "List and enable or disable packs.",
        subcommands: [List.self, Enable.self, Disable.self, Info.self, TestPack.self],
        defaultSubcommand: List.self
    )

    /// `rv packs` and `rv packs list`: the grouped catalog.
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List packs (the default)."
        )

        @Flag(name: .customLong("enabled"), help: "Only enabled packs.")
        var enabledOnly = false

        @Flag(name: .customLong("all"), help: "List every pack grouped by category, with descriptions.")
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
            if (try? PacksConfigStore.load(home: home)) == nil {
                ctx.writeStderr(
                    "warning: \(PacksConfigStore.configURL(home: home).path) cannot be read; every bundled pack is enforced until you fix or remove it\n")
            }
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

            // Bare `rv packs` shows what is on (each category's enabled packs,
            // then a count of the rest), not the ~250-line catalog. --all,
            // --verbose, --category and --search show the full tree.
            let collapsedView = !all && !verbose && category == nil && search == nil
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

            let text = PacksListFormat.prettyGrouped(model, appearance: ctx.appearance, verbose: verboseFlag, expand: expandFlag, maxPatterns: maxPat, collapsed: collapsedView)
            ctx.writeStdout(text)
            if collapsedView {
                ctx.writeStdout(
                    "\n\(filtered.enabledCount) of \(filtered.totalCount) packs on. "
                        + "See every pack: rv packs --all\n")
            }
        }
    }

    struct Enable: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "enable",
            abstract: "Enable pack, category, or preset IDs."
        )

        @Argument(help: "Pack, category, or preset IDs.")
        var ids: [String]

        func run() async throws {
            try await mutate(ids: ids, enabling: true)
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
            try await mutate(ids: ids, enabling: false)
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
                    try ctx.fail("unknown pack id: \(DisplayedText.field(id))\n")
                }
                row = try PacksFacade.info(home: home, id: packID)
            } catch PacksCommandError.packNotFound(let packID) {
                try ctx.fail("unknown pack id: \(DisplayedText.field(packID.rawValue)) (rv packs lists every pack)\n")
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
                "enabled: \(row.enabled)\(row.requiredByOrganization ? " (required by organization policy)" : "")",
                "safe_patterns: \(row.safePatternCount)",
                "destructive_patterns: \(row.destructivePatternCount)",
            ]
            ctx.writeStdout(lines.joined(separator: "\n") + "\n")
        }
    }
}

extension Packs {
    /// `rv packs test <pack>`: runs every example of the pack's rules and
    /// shows which pass. Reads the bundle only; changes nothing.
    struct TestPack: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "test",
            abstract: "Run a pack's examples and show which rules pass."
        )

        @OptionGroup
        var format: FormatFlags

        @Argument(help: "Pack ID.")
        var id: String

        func run() async throws {
            let ctx = CommandContext.current(command: "packs", format: format)
            let probe: PackProbe
            do {
                probe = try PackProbe.bundled()
            } catch {
                try ctx.fail("rv: the bundled packs cannot be read. Run rv doctor.\n")
            }
            guard let packID = PackID(validating: id), let runs = probe.runExamples(of: packID) else {
                let ids = probe.packIDs.map(\.rawValue)
                var text = "rv: no pack is named \(DisplayedText.field(id))."
                if let near = PacksConfigStore.nearestSelection(to: id, in: ids) { text += " Did you mean \(near)?" }
                try ctx.fail(text + " rv packs --all lists every pack.\n")
            }
            let enabled = ctx.home.map { EvaluationWorld.walkedPackIDs(home: $0).ids } ?? dayOnePackIDs
            let model = PackTestReport.model(packID: packID, runs: runs, enabled: enabled.contains(packID))
            let exitCode: Int32 = model.passed ? 0 : 1
            if ctx.explicitRobot {
                try ctx.emit(stdout: PackTestReport.json(packID: packID, runs: runs) + "\n", exitCode: exitCode)
                return
            }
            let palette: Palette
            switch ctx.appearance {
            case .robot: palette = colorOffPalette
            case .pretty(let value): palette = value
            }
            try ctx.emit(stdout: PrettyWriter.join(PackTestRenderer().render(model, palette: palette)), exitCode: exitCode)
        }
    }
}

/// `rv packs test` results to the view model and `--json`.
enum PackTestReport {
    static func model(packID: PackID, runs: [RuleExampleRun], enabled: Bool) -> PackTestViewModel {
        PackTestViewModel(
            packID: packID,
            rules: runs.map { run in
                PackTestViewModel.Rule(
                    name: run.ruleID.pattern,
                    stops: run.stops,
                    allows: run.allows,
                    failures: run.failures.map { "\($0.label.rawValue): \(DisplayedText.field($0.command)) \($0.got)" }
                )
            },
            turnOn: enabled ? nil : "\(CommandVocabulary.Command.packs.invocation) enable \(packID.rawValue)"
        )
    }

    /// `{"schema":"rv.packs.test.v1","pack_id":…,"passed":…,"rules":[…]}`
    static func json(packID: PackID, runs: [RuleExampleRun]) throws -> String {
        let rules: [[String: Any]] = runs.map { run in
            [
                "rule_id": run.ruleID.rawValue,
                "stops": run.stops,
                "allows": run.allows,
                "passed": run.passed,
                "failures": run.failures.map { ["label": $0.label.rawValue, "command": $0.command, "got": $0.got] },
            ]
        }
        let object: [String: Any] = [
            "schema": "rv.packs.test.v1",
            "pack_id": packID.rawValue,
            "passed": runs.allSatisfy(\.passed),
            "rules": rules,
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
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

private func mutate(ids: [String], enabling: Bool) async throws {
    let authorization = try await OwnerConfirmation.require(
        "\(enabling ? "enable" : "disable") packs \(ids.joined(separator: ", "))")
    try await ConfigChangeAudit.$authorization.withValue(authorization) {
        try applyPackMutation(ids: ids, enabling: enabling)
    }
}

/// Pack enable/disable, run after the owner gate approved it.
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
    } catch PacksCommandError.configUnreadable {
        try CommandContext.fail(
            "\(PacksConfigStore.configURL(home: home).path) cannot be read; every bundled pack is enforced until you fix or remove it\n")
    } catch let unrecorded as ConfigChangeUnrecorded {
        try ConfigChangeRefusal.fail(command: "packs", unrecorded)
    } catch {
        throw ExitCode(1)
    }
    let verb = enabling ? "enabled" : "disabled"
    let changed = result.changed.isEmpty ? "none" : result.changed.map(\.rawValue).joined(separator: ", ")
    let line =
        "\(verb): \(changed) (\(result.enabledCount)/\(result.totalCount) enabled)\n"
    CommandContext.writeStdout(line)
    if enabling == false {
        let required = Set(ManagedGate.requiredPacks(home: home).map(\.rawValue))
        let stillOn = ids.filter { required.contains($0) }
        if stillOn.isEmpty == false {
            CommandContext.writeStdout(
                "note: \(stillOn.joined(separator: ", ")) stays enforced: required by organization policy\n")
        }
    }
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
