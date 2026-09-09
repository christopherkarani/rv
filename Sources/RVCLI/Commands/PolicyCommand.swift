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
            guard let home = HomeDirectory.process() else {
                FileHandle.standardError.write(Data("rv policy show: HOME is not set\n".utf8))
                throw ExitCode(1)
            }
            let workspace = URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath,
                isDirectory: true
            )
            let snapshot: PolicyShowSnapshot
            do {
                snapshot = try PolicyShowRun.load(home: home, workspace: workspace)
            } catch {
                FileHandle.standardError.write(
                    Data("rv policy show: invalid policy file\n".utf8)
                )
                throw ExitCode(1)
            }
            let text: String
            if format.json || format.robot {
                do {
                    text = try PolicyShowRun.robot(snapshot)
                } catch {
                    FileHandle.standardError.write(
                        Data("rv policy show: encode failed\n".utf8)
                    )
                    throw ExitCode(1)
                }
            } else {
                text = PolicyShowRun.pretty(snapshot)
            }
            FileHandle.standardOutput.write(Data((text + "\n").utf8))
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
                guard let home = HomeDirectory.process() else {
                    FileHandle.standardError.write(Data("rv policy validate: HOME is not set\n".utf8))
                    throw ExitCode(1)
                }
                target = .machine(home)
            }
            do {
                try PolicyValidateRun.validate(target)
            } catch {
                FileHandle.standardError.write(Data("rv policy validate: invalid policy file\n".utf8))
                throw ExitCode(2)
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
            guard let home = HomeDirectory.process() else {
                FileHandle.standardError.write(Data("rv policy export: HOME is not set\n".utf8))
                throw ExitCode(1)
            }
            let workspace = URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath,
                isDirectory: true
            )
            let store = TypedRuleStore(
                baseDirectory: RVPolicyPaths.configDirectory(home: home)
            )
            let document: PolicyDocument
            do {
                document = repo
                    ? try store.loadRepoDocument(workspace: workspace)
                    : try store.loadMachineDocument()
            } catch {
                FileHandle.standardError.write(Data("rv policy export: invalid policy file\n".utf8))
                throw ExitCode(1)
            }
            let text = PolicyDocumentTOML.render(document)
            if let output {
                let url = URL(fileURLWithPath: output)
                do {
                    try text.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    FileHandle.standardError.write(Data("rv policy export: write failed\n".utf8))
                    throw ExitCode(1)
                }
            } else {
                FileHandle.standardOutput.write(Data(text.utf8))
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
            guard let home = HomeDirectory.process() else {
                FileHandle.standardError.write(Data("rv policy apply: HOME is not set\n".utf8))
                throw ExitCode(1)
            }
            let workspace = URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath,
                isDirectory: true
            )
            let incoming: PolicyDocument
            do {
                incoming = try PolicyDocumentRun.load(URL(fileURLWithPath: path))
            } catch {
                FileHandle.standardError.write(Data("rv policy apply: invalid policy file\n".utf8))
                throw ExitCode(1)
            }
            let store = TypedRuleStore(
                baseDirectory: RVPolicyPaths.configDirectory(home: home)
            )
            let existing: PolicyDocument
            do {
                existing = repo
                    ? try store.loadRepoDocument(workspace: workspace)
                    : try store.loadMachineDocument()
            } catch {
                FileHandle.standardError.write(Data("rv policy apply: invalid policy file\n".utf8))
                throw ExitCode(1)
            }
            let merged = PolicyDocument(
                rules: PolicyDocumentTOML.mergeLayer(existing: existing.rules, incoming: incoming.rules)
            )
            let preview = merged.rules.map { "  \(formatDocumentRule($0))" }.joined(separator: "\n")
            let body = preview.isEmpty ? "  (none)" : preview
            FileHandle.standardOutput.write(Data(("apply\n\(body)\n").utf8))
            if save {
                do {
                    if repo {
                        try store.saveRepo(merged, workspace: workspace)
                    } else {
                        try store.saveMachine(merged)
                    }
                } catch {
                    FileHandle.standardError.write(Data("rv policy apply: write failed\n".utf8))
                    throw ExitCode(1)
                }
            }
        }
    }
}

struct PolicyShowSnapshot: Equatable, Sendable, Codable {
    var builtin: [TypedRule]
    var machine: [TypedRule]
    var repo: [TypedRule]
}

enum PolicyShowRun {
    static func load(
        home: HomeDirectory,
        workspace: URL,
        builtin: [TypedRule] = []
    ) throws -> PolicyShowSnapshot {
        let store = TypedRuleStore(
            baseDirectory: RVPolicyPaths.configDirectory(home: home)
        )
        return PolicyShowSnapshot(
            builtin: builtin,
            machine: try store.loadMachine(),
            repo: try store.loadRepo(workspace: workspace)
        )
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
            let store = TypedRuleStore(
                baseDirectory: RVPolicyPaths.configDirectory(home: home)
            )
            _ = try store.loadMachineDocument()
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
