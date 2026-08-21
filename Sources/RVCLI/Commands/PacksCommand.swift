import ArgumentParser
import Foundation
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

    @Flag(name: .customLong("enabled"), help: "Only effective-on packs.")
    var enabledOnly = false

    @OptionGroup
    var format: FormatFlags

    func run() async throws {
        guard let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty else {
            FileHandle.standardError.write(Data("rv packs: HOME is not set\n".utf8))
            throw ExitCode(1)
        }
        let snapshot = try PacksFacade.list(home: home, enabledOnly: enabledOnly)
        if format.json || format.robot {
            let payload = packsRobotPayload(
                rows: snapshot.packs.map(packsRobotRow),
                enabledCount: snapshot.enabledCount,
                totalCount: snapshot.totalCount
            )
            let text = try RobotJSON.encode(payload)
            FileHandle.standardOutput.write(Data((text + "\n").utf8))
            return
        }

        let catalog = snapshot.packs.map { ($0.id, $0.description) }
        let enabled = snapshot.packs.filter(\.enabled).map(\.id)
        let model = packsViewModel(enabled: enabled, catalog: catalog)
        let appearance = CLIAppearance.resolve(
            json: format.json,
            robot: format.robot,
            plain: format.plain,
            noColor: format.noColor
        )
        FileHandle.standardOutput.write(Data(PacksListFormat.pretty(model, appearance: appearance).utf8))
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
            guard let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty else {
                FileHandle.standardError.write(Data("rv packs: HOME is not set\n".utf8))
                throw ExitCode(1)
            }
            let row: PacksListRow
            do {
                row = try PacksFacade.info(home: home, id: id)
            } catch PacksCommandError.packNotFound {
                throw ExitCode(1)
            }
            if format.json || format.robot {
                let text = try RobotJSON.encode(packsRobotRow(row))
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
    guard let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty else {
        FileHandle.standardError.write(Data("rv packs: HOME is not set\n".utf8))
        throw ExitCode(1)
    }
    let result: PacksMutationResult
    do {
        result = enabling
            ? try PacksFacade.enable(home: home, ids: ids)
            : try PacksFacade.disable(home: home, ids: ids)
    } catch PacksCommandError.unknownID(let token) {
        FileHandle.standardError.write(Data("unknown pack id: \(token)\n".utf8))
        throw ExitCode(1)
    } catch PacksCommandError.criticalPatternUncompilable(let rule) {
        FileHandle.standardError.write(Data("critical pattern uncompilable: \(rule)\n".utf8))
        throw ExitCode(1)
    } catch {
        throw ExitCode(1)
    }
    let verb = enabling ? "enabled" : "disabled"
    let changed = result.changed.isEmpty ? "none" : result.changed.joined(separator: ", ")
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
