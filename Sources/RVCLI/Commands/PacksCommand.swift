import ArgumentParser
import Foundation
import RVDomain
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
            let payload = RobotPacksList(
                schema: "rv.packs.v1",
                packs: snapshot.packs.map(RobotPackRow.init),
                enabledCount: snapshot.enabledCount,
                totalCount: snapshot.totalCount
            )
            FileHandle.standardOutput.write(Data((try RobotJSON.encode(payload) + "\n").utf8))
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
                guard let packID = PackID(validating: id) else {
                    FileHandle.standardError.write(Data("unknown pack id: \(id)\n".utf8))
                    throw ExitCode(1)
                }
                row = try PacksFacade.info(home: home, id: packID)
            } catch PacksCommandError.packNotFound {
                throw ExitCode(1)
            }
            if format.json || format.robot {
                FileHandle.standardOutput.write(Data((try RobotJSON.encode(RobotPackRow(row)) + "\n").utf8))
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
}

private struct RobotPacksList: Encodable {
    var schema: String
    var packs: [RobotPackRow]
    var enabledCount: Int
    var totalCount: Int

    enum CodingKeys: String, CodingKey {
        case schema
        case packs
        case enabledCount = "enabled_count"
        case totalCount = "total_count"
    }
}

private struct RobotPackRow: Encodable {
    var id: String
    var name: String
    var category: String
    var description: String
    var enabled: Bool
    var safePatternCount: Int
    var destructivePatternCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case category
        case description
        case enabled
        case safePatternCount = "safe_pattern_count"
        case destructivePatternCount = "destructive_pattern_count"
    }

    init(_ row: PacksListRow) {
        id = row.id.rawValue
        name = row.name
        category = row.category
        description = row.description
        enabled = row.enabled
        safePatternCount = row.safePatternCount
        destructivePatternCount = row.destructivePatternCount
    }
}

