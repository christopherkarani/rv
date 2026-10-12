import ArgumentParser
import Foundation
import RVDomain
import RVMCP
import RVPolicy

/// Seams for `rv mcp`: where rv and the hosts keep configuration.
struct MCPEnvironment: Sendable {
    var configDirectory: URL
    var home: URL
    var processEnvironment: [String: String]

    static func live(home: HomeDirectory) -> MCPEnvironment {
        MCPEnvironment(
            configDirectory: RVPolicyPaths.configDirectory(home: home),
            home: URL(fileURLWithPath: home.rawValue, isDirectory: true),
            processEnvironment: ProcessInfo.processInfo.environment
        )
    }
}

enum MCPRun {
    struct Row: Encodable, Equatable {
        var host: String
        var scope: String
        var configPath: String
        var name: String
        var status: String
        var command: String
        var environmentNames: [String]
        var headerNames: [String]
        var plaintextCredentials: [String]
        var governedServer: String?
    }

    struct Problem: Encodable, Equatable {
        var path: String
        var message: String
    }

    struct Report: Encodable, Equatable {
        var servers: Int
        var direct: Int
        var blocked: Int
        var rows: [Row]
        var problems: [Problem]

        var failing: [Row] {
            rows.filter { MCPEntryStatus(rawValue: $0.status)?.isAcceptable == false }
        }

        var passes: Bool { failing.isEmpty && problems.isEmpty }
    }

    static func configuration(_ environment: MCPEnvironment) -> Result<MCPConfiguration, CommandFailure> {
        MCPConfiguration.load(configDirectory: environment.configDirectory).mapError { CommandFailure($0.message) }
    }

    static func report(_ environment: MCPEnvironment, project: URL?, configuration: MCPConfiguration) -> Report {
        let inventory = MCPInventory.discover(
            home: environment.home, project: project, environment: environment.processEnvironment)
        let rows = MCPInventoryRow.rows(inventory, configuration: configuration).map { row in
            Row(
                host: row.entry.host.rawValue,
                scope: row.entry.scope.label,
                configPath: row.entry.configPath,
                name: row.entry.name,
                status: row.status.rawValue,
                command: row.display,
                environmentNames: row.environmentNames,
                headerNames: row.headerNames,
                plaintextCredentials: row.plaintextCredentials,
                governedServer: row.entry.governedServer)
        }
        return Report(
            servers: configuration.servers.count,
            direct: configuration.direct.count,
            blocked: configuration.blocked.count,
            rows: rows,
            problems: inventory.problems.map { Problem(path: $0.path, message: $0.message) })
    }

    static func listText(_ report: Report, home: URL) -> String {
        var lines = [
            "rv mcp.json: \(report.servers) gateway servers, \(report.direct) direct, \(report.blocked) blocked"
        ]
        if report.rows.isEmpty { lines.append("no MCP servers found in any host configuration") }
        var currentFile: String?
        let width = min(28, report.rows.map(\.name.count).max() ?? 0)
        for row in report.rows {
            let file = "\(row.host) (\(row.scope == "user" ? "user" : "project"), \(abbreviate(row.configPath, home: home)))"
            if file != currentFile {
                lines.append("")
                lines.append(file)
                currentFile = file
            }
            let name = row.name.padding(toLength: max(width, row.name.count), withPad: " ", startingAt: 0)
            let status = row.status.padding(toLength: 10, withPad: " ", startingAt: 0)
            lines.append("  \(name)  \(status)  \(row.command)")
            var details: [String] = []
            if row.environmentNames.isEmpty == false { details.append("env " + capped(row.environmentNames)) }
            if row.headerNames.isEmpty == false { details.append("headers " + row.headerNames.joined(separator: ", ")) }
            if row.plaintextCredentials.isEmpty == false {
                details.append("plaintext credential: " + row.plaintextCredentials.joined(separator: ", "))
            }
            if details.isEmpty == false {
                lines.append("  " + String(repeating: " ", count: max(width, row.name.count)) + "  " + details.joined(separator: " · "))
            }
        }
        lines.append("")
        lines.append(summary(report))
        lines += problemLines(report, home: home)
        return lines.joined(separator: "\n") + "\n"
    }

    static func checkText(_ report: Report, home: URL) -> String {
        var lines: [String] = []
        if report.passes {
            lines.append("ok: every MCP server is governed by rv, allowed direct, or disabled (\(report.rows.count) checked)")
        } else {
            for row in report.failing {
                let status = MCPEntryStatus(rawValue: row.status)
                lines.append("\(row.status)  \(row.name)  \(row.host) \(abbreviate(row.configPath, home: home))")
                if let status { lines.append("  \(status.explanation)") }
            }
            lines += problemLines(report, home: home)
            lines.append(summary(report))
        }
        let leaks = report.rows.filter { $0.plaintextCredentials.isEmpty == false }
        if leaks.isEmpty == false {
            lines.append(
                "warning: \(leaks.count) host entr\(leaks.count == 1 ? "y holds" : "ies hold") plaintext credentials ("
                    + leaks.map(\.name).joined(separator: ", ") + "); `rv mcp import` moves them into rv secrets")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func capped(_ names: [String], limit: Int = 4) -> String {
        names.count <= limit
            ? names.joined(separator: ", ")
            : names.prefix(limit).joined(separator: ", ") + " +\(names.count - limit) more"
    }

    static func summary(_ report: Report) -> String {
        let order: [MCPEntryStatus] = [.governed, .direct, .bypass, .unreviewed, .blocked, .dangling, .disabled]
        let counts = order.compactMap { status -> String? in
            let count = report.rows.filter { $0.status == status.rawValue }.count
            return count == 0 ? nil : "\(count) \(status.rawValue)"
        }
        let files = Set(report.rows.map(\.configPath)).count
        return "\(report.rows.count) host entries in \(files) files" + (counts.isEmpty ? "" : ": " + counts.joined(separator: ", "))
    }

    static func problemLines(_ report: Report, home: URL) -> [String] {
        report.problems.map { "unreadable: \(abbreviate($0.path, home: home)): \($0.message)" }
    }

    static func abbreviate(_ path: String, home: URL) -> String {
        let prefix = home.standardizedFileURL.path
        guard path.hasPrefix(prefix + "/") else { return path }
        return "~" + path.dropFirst(prefix.count)
    }

    static func projectURL(_ raw: String?) -> URL {
        URL(fileURLWithPath: raw ?? FileManager.default.currentDirectoryPath, isDirectory: true).standardizedFileURL
    }
}

struct MCP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Find, review, and govern the MCP servers your agents use.",
        subcommands: [MCPList.self, MCPCheck.self],
        defaultSubcommand: MCPList.self
    )
}

struct MCPList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list", abstract: "List MCP servers from every host config, with rv's review status.")

    @Option(help: "Project directory for project-scoped configs. Default: current directory.") var project: String?
    @OptionGroup var format: FormatFlags

    func run() throws {
        let ctx = CommandContext.current(command: "mcp list", format: format)
        let environment = MCPEnvironment.live(home: try ctx.requireHome())
        switch MCPRun.configuration(environment) {
        case .failure(let failure):
            try ctx.fail("rv mcp list: \(failure.message)\n")
        case .success(let configuration):
            let report = MCPRun.report(environment, project: MCPRun.projectURL(project), configuration: configuration)
            ctx.writeStdout(ctx.explicitRobot ? SecretsRun.json(report) : MCPRun.listText(report, home: environment.home))
        }
    }
}

struct MCPCheck: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Exit 1 when any MCP server bypasses rv, is unreviewed, or is blocked.")

    @Option(help: "Project directory for project-scoped configs. Default: current directory.") var project: String?
    @OptionGroup var format: FormatFlags

    func run() throws {
        let ctx = CommandContext.current(command: "mcp check", format: format)
        let environment = MCPEnvironment.live(home: try ctx.requireHome())
        switch MCPRun.configuration(environment) {
        case .failure(let failure):
            try ctx.fail("rv mcp check: \(failure.message)\n")
        case .success(let configuration):
            let report = MCPRun.report(environment, project: MCPRun.projectURL(project), configuration: configuration)
            let text = ctx.explicitRobot ? SecretsRun.json(report) : MCPRun.checkText(report, home: environment.home)
            if report.passes {
                ctx.writeStdout(text)
            } else {
                try ctx.emit(stdout: text, exitCode: 1)
            }
        }
    }
}
