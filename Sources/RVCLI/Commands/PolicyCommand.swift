import ArgumentParser
import Foundation
import RVDomain
import RVPolicy

struct Policy: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "policy",
        abstract: "Show compiled typed rules by origin.",
        subcommands: [Show.self],
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
                    Data("rv policy show: invalid typed-rules file\n".utf8)
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

private func predicateText(_ predicate: PolicyPredicate) -> String {
    switch predicate {
    case .gitPush(let force, let branch):
        let forceText = force?.rawValue ?? "-"
        let branchText = branch ?? "-"
        return "gitPush force=\(forceText) branch=\(branchText)"
    }
}
