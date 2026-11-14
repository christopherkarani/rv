import ArgumentParser
import Foundation
import RVDomain
import RVPolicy

/// `rv policy check --ceiling`: read-only containment of the policy layers
/// (or one shared file) in the owner's ceiling, with a concrete witness for
/// each layer that exceeds it.
struct PolicyCheck: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Check policy layers against the policy ceiling (read-only)."
    )

    @Flag(name: .customLong("ceiling"), help: "Check containment in ceiling.toml.")
    var ceiling = false

    @Argument(help: "A policy.toml to check instead of the machine and repo layers.")
    var path: String?

    @OptionGroup
    var format: FormatFlags

    func run() async throws {
        let ctx = CommandContext.current(command: "policy check", format: format)
        guard ceiling else {
            try ctx.fail("rv policy check: pass --ceiling\n", exitCode: 2)
        }
        let home = try ctx.requireHome()
        let workspace = URL(fileURLWithPath: CLIProcess.workspacePath(), isDirectory: true)
        let report: PolicyCeilingReport
        do {
            report = try PolicyCeilingRun.check(
                home: home, workspace: workspace, file: path.map { URL(fileURLWithPath: $0) })
        } catch PolicyCeilingError.invalidFile {
            try ctx.fail("rv policy check: the policy ceiling (ceiling.toml) is invalid\n", exitCode: 2)
        } catch {
            try ctx.fail("rv policy check: invalid policy file\n", exitCode: 2)
        }
        if ctx.explicitRobot {
            do {
                ctx.writeStdout(try RobotJSON.encode(report) + "\n")
            } catch {
                try ctx.fail("rv policy check: encode failed\n")
            }
        } else {
            ctx.writeStdout(report.pretty + "\n")
        }
        if report.withinCeiling == false {
            throw ExitCode(2)
        }
    }
}

/// `rv policy ceiling`: show or replace the owner's never-exceed bound.
struct PolicyCeilingCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ceiling",
        abstract: "Show or set the policy ceiling.",
        subcommands: [Show.self, SetCeiling.self],
        defaultSubcommand: Show.self
    )

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Print ceiling.toml."
        )

        func run() async throws {
            let home = try CommandContext.requireHome(command: "policy ceiling show")
            do {
                let ceiling = try PolicyWorkspace(home: home).loadCeiling()
                CommandContext.writeStdout(ceiling.map(PolicyCeilingTOML.render) ?? "(none)\n")
            } catch {
                try CommandContext.fail("rv policy ceiling show: the policy ceiling (ceiling.toml) is invalid\n", exitCode: 2)
            }
        }
    }

    struct SetCeiling: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "Replace ceiling.toml (asks for owner authentication)."
        )

        @Argument(help: "Path to a ceiling.toml file.")
        var path: String

        func run() async throws {
            let home = try CommandContext.requireHome(command: "policy ceiling set")
            let workspace = URL(fileURLWithPath: CLIProcess.workspacePath(), isDirectory: true)
            let outcome = try await PolicyCeilingRun.set(
                home: home, workspace: workspace, file: URL(fileURLWithPath: path))
            for line in outcome.lines { CommandContext.writeStdout(line + "\n") }
            if outcome.saved == false {
                throw ExitCode(2)
            }
        }
    }
}

/// One checked layer in `rv policy check --ceiling`.
struct PolicyCeilingLayerResult: Equatable, Sendable, Codable {
    struct Witness: Equatable, Sendable, Codable {
        var command: String
        var candidateRule: String
        var candidateVerdict: String
        var ceilingRule: String
        var ceilingVerdict: String
    }

    /// `machine`, `repo`, or the checked file's path.
    var layer: String
    /// `within`, `exceeds`, or `indeterminate`.
    var status: String
    var witness: Witness?
    var reason: String?

    init(layer: String, result: PolicyContainmentResult) {
        self.layer = layer
        switch result {
        case .contained:
            status = "within"
        case .exceeds(let found):
            status = "exceeds"
            witness = Witness(
                command: found.command,
                candidateRule: DisplayedText.field(found.candidateRule.rawValue),
                candidateVerdict: found.candidateVerdict.rawValue,
                ceilingRule: DisplayedText.field(found.ceilingRule.rawValue),
                ceilingVerdict: found.ceilingVerdict.rawValue
            )
        case .indeterminate(let text):
            status = "indeterminate"
            reason = DisplayedText.field(text)
        }
    }

    var pretty: [String] {
        let name = DisplayedText.field(layer)
        switch (status, witness) {
        case ("within", _):
            return ["\(name): within the ceiling"]
        case ("exceeds", let witness?):
            return [
                "\(name): exceeds the ceiling",
                "  witness: \(witness.command)",
                "  rule \(witness.candidateRule) says \(witness.candidateVerdict);"
                    + " ceiling rule \(witness.ceilingRule) says \(witness.ceilingVerdict)",
            ]
        default:
            return ["\(name): indeterminate (\(reason ?? "unknown")); treated as exceeding"]
        }
    }
}

struct PolicyCeilingReport: Equatable, Sendable, Codable {
    /// False when no ceiling.toml is set: nothing is bounded.
    var ceilingSet: Bool
    var layers: [PolicyCeilingLayerResult]

    var withinCeiling: Bool {
        layers.allSatisfy { $0.status == "within" }
    }

    var pretty: String {
        guard ceilingSet else { return "ceiling: none (no ceiling.toml)" }
        return layers.flatMap(\.pretty).joined(separator: "\n")
    }
}

enum PolicyCeilingRun {
    /// Machine and repo layers, or one shared file. Throws
    /// `PolicyCeilingError.invalidFile` for an unreadable ceiling and the
    /// layer's own error for an unreadable policy file.
    static func check(home: HomeDirectory, workspace: URL, file: URL?) throws -> PolicyCeilingReport {
        let session = PolicyWorkspace(home: home, workspace: workspace)
        guard let ceiling = try session.loadCeiling() else {
            return PolicyCeilingReport(ceilingSet: false, layers: [])
        }
        if let file {
            let document = try PolicyDocumentRun.load(file)
            return PolicyCeilingReport(
                ceilingSet: true,
                layers: [PolicyCeilingLayerResult(layer: file.path, result: ceiling.check(document))]
            )
        }
        return PolicyCeilingReport(
            ceilingSet: true,
            layers: [
                PolicyCeilingLayerResult(layer: "machine", result: ceiling.check(try session.loadMachineDocument())),
                PolicyCeilingLayerResult(layer: "repo", result: ceiling.check(try session.loadRepoDocument())),
            ]
        )
    }

    struct SetOutcome: Equatable, Sendable {
        var lines: [String]
        var saved: Bool
    }

    /// Parse, refuse a ceiling the machine layer already exceeds (every
    /// evaluation would fail closed), confirm the owner, then replace.
    /// The current repo layer is reported, not refused: other repos are not
    /// visible here, and a repo above the ceiling fails closed on its own.
    static func set(home: HomeDirectory, workspace: URL, file: URL) async throws -> SetOutcome {
        let ceiling: PolicyCeiling
        do {
            ceiling = try PolicyCeilingTOML.parse(String(contentsOf: file, encoding: .utf8))
        } catch {
            return SetOutcome(lines: ["rv policy ceiling set: invalid ceiling file"], saved: false)
        }
        let session = PolicyWorkspace(home: home, workspace: workspace)
        let machine: PolicyDocument
        let repo: PolicyDocument
        do {
            machine = try session.loadMachineDocument()
            repo = try session.loadRepoDocument()
        } catch {
            return SetOutcome(lines: ["rv policy ceiling set: invalid policy file"], saved: false)
        }
        let machineResult = PolicyCeilingLayerResult(layer: "machine", result: ceiling.check(machine))
        let repoResult = PolicyCeilingLayerResult(layer: "repo", result: ceiling.check(repo))
        let lines = machineResult.pretty + repoResult.pretty
        guard machineResult.status == "within" else {
            return SetOutcome(
                lines: lines + ["rv policy ceiling set: refused: the machine layer exceeds this ceiling"],
                saved: false
            )
        }
        try await OwnerConfirmation.require("replace the policy ceiling from \(file.path)")
        do {
            try PolicyCeilingStore(configDirectory: RVPolicyPaths.configDirectory(home: home)).save(ceiling)
        } catch {
            return SetOutcome(lines: lines + ["rv policy ceiling set: write failed"], saved: false)
        }
        return SetOutcome(lines: lines + ["saved ceiling.toml"], saved: true)
    }
}
