import ArgumentParser
import Foundation
import RVDomain
import RVPolicy

struct Policy: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "policy",
        abstract: "Show, draft, or share compiled typed rules.",
        subcommands: [Show.self, PolicyDraftCommand.self, Validate.self, Export.self, Apply.self],
        defaultSubcommand: Show.self
    )

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "List built-in, machine, and repo typed rules."
        )

        @OptionGroup
        var format: FormatFlags

        func run() async throws {
            let ctx = CommandContext.current(command: "policy show", format: format)
            let home = try ctx.requireHome()
            let workspace = URL(
                fileURLWithPath: CLIProcess.workspacePath(),
                isDirectory: true
            )
            let snapshot: PolicyShowSnapshot
            do {
                snapshot = try PolicyShowRun.load(home: home, workspace: workspace)
            } catch {
                try ctx.fail("rv policy show: invalid policy file\n")
            }
            let text: String
            if ctx.explicitRobot {
                do {
                    text = try PolicyShowRun.robot(snapshot)
                } catch {
                    try ctx.fail("rv policy show: encode failed\n")
                }
            } else {
                text = PolicyShowRun.pretty(snapshot)
            }
            ctx.writeStdout(text + "\n")
        }
    }

    struct Validate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "validate",
            abstract: "Validate a policy document."
        )

        @Argument(help: "Path to policy.toml. Defaults to the machine file.")
        var path: String?

        func run() throws {
            let target: PolicyValidateRun.Target
            if let path {
                target = .file(URL(fileURLWithPath: path))
            } else {
                target = .machine(try CommandContext.requireHome(command: "policy validate"))
            }
            do {
                try PolicyValidateRun.validate(target)
            } catch {
                try CommandContext.fail("rv policy validate: invalid policy file\n", exitCode: 2)
            }
        }
    }

    struct Export: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "export",
            abstract: "Write one origin as policy.toml."
        )

        @Flag(name: .customLong("repo"), help: "Export the repo layer.")
        var repo = false

        @Option(name: .customLong("output"), help: "Write to this path instead of stdout.")
        var output: String?

        func run() throws {
            let home = try CommandContext.requireHome(command: "policy export")
            let workspace = URL(
                fileURLWithPath: CLIProcess.workspacePath(),
                isDirectory: true
            )
            let session = PolicyWorkspace(home: home, workspace: workspace)
            let document: PolicyDocument
            do {
                document = repo
                    ? try session.loadRepoDocument()
                    : try session.loadMachineDocument()
            } catch {
                try CommandContext.fail("rv policy export: invalid policy file\n")
            }
            let text = PolicyDocumentTOML.render(document)
            if let output {
                try LocalControlBoundary.requireOwnerAuthorization()
                let url = URL(fileURLWithPath: output)
                do {
                    try text.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    try CommandContext.fail("rv policy export: write failed\n")
                }
            } else {
                CommandContext.writeStdout(text)
            }
        }
    }

    struct Apply: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "apply",
            abstract: "Preview or merge a shared policy document."
        )

        @Argument(help: "Path to a policy.toml file.")
        var path: String

        @Flag(name: .customLong("save"), help: "Write the merged layer.")
        var save = false

        @Flag(name: .customLong("repo"), help: "Write the repo layer.")
        var repo = false

        func run() throws {
            let home = try CommandContext.requireHome(command: "policy apply")
            let workspace = URL(
                fileURLWithPath: CLIProcess.workspacePath(),
                isDirectory: true
            )
            let incoming: PolicyDocument
            do {
                incoming = try PolicyDocumentRun.load(URL(fileURLWithPath: path))
            } catch {
                try CommandContext.fail("rv policy apply: invalid policy file\n")
            }
            let session = PolicyWorkspace(home: home, workspace: workspace)
            let layer: PolicyDocumentLayer = repo ? .repo : .machine
            let merged: PolicyDocument
            do {
                merged = try session.mergeIncoming(incoming, layer: layer, save: false)
            } catch {
                try CommandContext.fail("rv policy apply: invalid policy file\n")
            }
            let preview = merged.rules.map { "  \(formatDocumentRule($0))" }.joined(separator: "\n")
            let body = preview.isEmpty ? "  (none)" : preview
            CommandContext.writeStdout("apply\n\(body)\n")
            if save {
                try LocalControlBoundary.requireOwnerAuthorization()
                do {
                    _ = try session.mergeIncoming(incoming, layer: layer, save: true)
                } catch {
                    try CommandContext.fail("rv policy apply: write failed\n")
                }
            }
        }
    }
}

typealias PolicyShowSnapshot = PolicyWorkspace.ShowSnapshot

enum PolicyShowRun {
    static func load(
        home: HomeDirectory,
        workspace: URL,
        builtin: [TypedRule] = []
    ) throws -> PolicyShowSnapshot {
        try PolicyWorkspace(home: home, workspace: workspace).loadLayers(builtin: builtin)
    }

    static func pretty(_ snapshot: PolicyShowSnapshot) -> String {
        [
            prettyOrigin(.builtin, snapshot.builtin),
            prettyOrigin(.machine, snapshot.machine),
            prettyOrigin(.repo, snapshot.repo),
        ].joined(separator: "\n\n")
    }

    static func robot(_ snapshot: PolicyShowSnapshot) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(snapshot)
        return String(decoding: data, as: UTF8.self)
    }
}

enum PolicyDocumentRun {
    static func load(_ url: URL) throws -> PolicyDocument {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw PolicyDocumentError.invalidFile
        }
        return try PolicyDocumentTOML.parse(text)
    }
}

enum PolicyValidateRun {
    enum Target: Equatable, Sendable {
        case machine(HomeDirectory)
        case file(URL)
    }

    /// Default (no path) uses the same machine load as `policy show` / evaluate:
    /// `policy.toml` if present, else legacy `typed-rules.json`. An explicit path
    /// is a share file: missing is valid; present must parse as TOML.
    static func validate(_ target: Target) throws {
        switch target {
        case .machine(let home):
            _ = try PolicyWorkspace(home: home).loadMachineDocument()
        case .file(let url):
            guard FileManager.default.fileExists(atPath: url.path) else {
                return
            }
            _ = try PolicyDocumentRun.load(url)
        }
    }
}

private func prettyOrigin(_ origin: TypedRuleOrigin, _ rules: [TypedRule]) -> String {
    let body: String
    if rules.isEmpty {
        body = "  (none)"
    } else {
        body = rules.map { "  \(formatRule($0))" }.joined(separator: "\n")
    }
    return "\(origin.rawValue)\n\(body)"
}

private func formatRule(_ rule: TypedRule) -> String {
    "\(rule.id.rawValue) \(rule.verdict.rawValue) \(predicateText(rule.predicate))"
}
