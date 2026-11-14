import ArgumentParser
import Foundation
import RVDomain
import RVPolicy

/// `rv policy check --ceiling`: read-only containment of the policy layers
/// (or one shared file) in the owner's ceiling, with a concrete witness for
/// each layer that exceeds it. Exit 0 within, 1 exceeds or indeterminate,
/// 2 for usage or an invalid ceiling or policy file.
struct PolicyCheck: AsyncParsableCommand {
    static let exceedsExitCode: Int32 = 1
    static let invalidExitCode: Int32 = 2

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
            try ctx.fail("rv policy check: the policy ceiling (ceiling.toml) is invalid\n", exitCode: Self.invalidExitCode)
        } catch {
            try ctx.fail("rv policy check: invalid policy file\n", exitCode: Self.invalidExitCode)
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
            throw ExitCode(Self.exceedsExitCode)
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
        /// The action, display-escaped. Something to check, not to run.
        var command: String
        /// The read-only `rv explain` of `command`.
        var check: String
        var candidateRule: String
        var candidateVerdict: String
        var ceilingRule: String
        var ceilingVerdict: String

        init(_ found: PolicyContainmentWitness) {
            command = found.command
            check = found.checkCommand
            candidateRule = DisplayedText.field(found.candidateRule.rawValue)
            candidateVerdict = found.candidateVerdict.rawValue
            ceilingRule = DisplayedText.field(found.ceilingRule.rawValue)
            ceilingVerdict = found.ceilingVerdict.rawValue
        }
    }

    /// `machine`, `repo`, or the checked file's path.
    var layer: String
    /// `within`, `exceeds`, `indeterminate`, or `unchecked`.
    var status: String
    var witness: Witness?
    var reason: String?
    /// A layer `allow` the ceiling overrides. Evaluation ignores typed
    /// allows, so this never makes the layer exceed.
    var advisory: Witness?

    init(layer: String, result: PolicyContainmentResult, advisory: PolicyContainmentResult = .contained) {
        self.layer = layer
        switch result {
        case .contained:
            status = "within"
        case .exceeds(let found):
            status = "exceeds"
            witness = Witness(found)
        case .indeterminate(let text):
            status = "indeterminate"
            reason = DisplayedText.field(text)
        }
        if case .exceeds(let found) = advisory {
            self.advisory = Witness(found)
        }
    }

    init(layer: String, ceiling: PolicyCeiling, document: PolicyDocument) {
        self.init(layer: layer, result: ceiling.check(document), advisory: ceiling.advisory(document))
    }

    /// A layer whose policy file could not be read; nothing was checked.
    static func unchecked(layer: String) -> PolicyCeilingLayerResult {
        var result = PolicyCeilingLayerResult(layer: layer, result: .contained)
        result.status = "unchecked"
        result.reason = "invalid policy file"
        return result
    }

    var pretty: [String] {
        let name = DisplayedText.field(layer)
        var lines: [String]
        switch (status, witness) {
        case ("within", _):
            lines = ["\(name): within the ceiling"]
        case ("exceeds", let witness?):
            lines = [
                "\(name): exceeds the ceiling",
                "  witness: \(witness.check)",
                "  rule \(witness.candidateRule) says \(witness.candidateVerdict);"
                    + " ceiling rule \(witness.ceilingRule) says \(witness.ceilingVerdict)",
            ]
        case ("unchecked", _):
            lines = ["\(name): invalid policy file (not checked)"]
        default:
            lines = ["\(name): indeterminate (\(reason ?? "unknown")); treated as exceeding"]
        }
        if let advisory {
            lines.append(
                "  note: rule \(advisory.candidateRule) says allow on \(advisory.check);"
                    + " it has no effect, ceiling rule \(advisory.ceilingRule) says \(advisory.ceilingVerdict)"
            )
        }
        return lines
    }
}

struct PolicyCeilingReport: Equatable, Sendable, Codable {
    /// False when no ceiling.toml is set: nothing is bounded.
    var ceilingSet: Bool
    var layers: [PolicyCeilingLayerResult]

    /// Advisory notes and unchecked layers do not fail the check; an
    /// unreadable layer fails `check` itself with the invalid exit code.
    var withinCeiling: Bool {
        layers.allSatisfy { $0.status == "within" || $0.status == "unchecked" }
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
                layers: [PolicyCeilingLayerResult(layer: file.path, ceiling: ceiling, document: document)]
            )
        }
        return PolicyCeilingReport(
            ceilingSet: true,
            layers: [
                PolicyCeilingLayerResult(layer: "machine", ceiling: ceiling, document: try session.loadMachineDocument()),
                PolicyCeilingLayerResult(layer: "repo", ceiling: ceiling, document: try session.loadRepoDocument()),
            ]
        )
    }

    struct SetOutcome: Equatable, Sendable {
        var lines: [String]
        var saved: Bool
    }

    /// Parse, refuse a ceiling the machine layer already exceeds, confirm
    /// the owner, then `replaceCeiling`, which re-checks the machine layer
    /// under the machine policy locks before it writes. The current repo
    /// layer is reported, never refused: an invalid repo file does not
    /// block the owner, and evaluation overlays the ceiling on every repo.
    static func set(home: HomeDirectory, workspace: URL, file: URL) async throws -> SetOutcome {
        let ceiling: PolicyCeiling
        do {
            ceiling = try PolicyCeilingTOML.parse(String(contentsOf: file, encoding: .utf8))
        } catch {
            return SetOutcome(lines: ["rv policy ceiling set: invalid ceiling file"], saved: false)
        }
        let session = PolicyWorkspace(home: home, workspace: workspace)
        let machine: PolicyDocument
        do {
            machine = try session.loadMachineDocument()
        } catch {
            return SetOutcome(lines: ["rv policy ceiling set: invalid machine policy file"], saved: false)
        }
        let machineResult = PolicyCeilingLayerResult(layer: "machine", ceiling: ceiling, document: machine)
        let repoResult: PolicyCeilingLayerResult
        if let repo = try? session.loadRepoDocument() {
            repoResult = PolicyCeilingLayerResult(layer: "repo", ceiling: ceiling, document: repo)
        } else {
            repoResult = .unchecked(layer: "repo")
        }
        let lines = machineResult.pretty + repoResult.pretty
        let refused = "rv policy ceiling set: refused: the machine layer exceeds this ceiling"
        guard machineResult.status == "within" else {
            return SetOutcome(lines: lines + [refused], saved: false)
        }
        try await OwnerConfirmation.require("replace the policy ceiling from \(file.path)")
        do {
            try session.replaceCeiling(ceiling)
        } catch let error as PolicyCeilingError {
            // The machine layer changed between the check and the lock.
            return SetOutcome(lines: lines + [refused, "  \(error.refusal)"], saved: false)
        } catch {
            return SetOutcome(lines: lines + ["rv policy ceiling set: write failed"], saved: false)
        }
        return SetOutcome(lines: lines + ["saved ceiling.toml"], saved: true)
    }
}
