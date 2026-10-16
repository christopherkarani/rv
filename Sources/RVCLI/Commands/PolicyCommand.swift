import ArgumentParser
import Foundation
import RVDomain
import RVPolicy

struct Policy: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "policy",
        abstract: "Show, list, draft, or share compiled typed rules.",
        subcommands: [Show.self, List.self, PolicyDraftCommand.self, Validate.self, Export.self, Apply.self],
        defaultSubcommand: Show.self
    )

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "List built-in, machine, and repo typed rules."
        )

        @OptionGroup
        var format: FormatFlags

        @Flag(name: .customLong("base"), help: "Show per-layer base rules.")
        var base = false

        @Flag(name: .customLong("effective"), help: "Show merged effective rules.")
        var effective = false

        func run() async throws {
            let ctx = CommandContext.current(command: "policy show", format: format)
            let home = try ctx.requireHome()
            let workspace = URL(
                fileURLWithPath: CLIProcess.workspacePath(),
                isDirectory: true
            )
            let showBase = base || effective == false
            let snapshot: PolicyShowSnapshot?
            do {
                snapshot = showBase
                    ? try PolicyShowRun.load(home: home, workspace: workspace)
                    : nil
            } catch {
                try ctx.fail("rv policy show: invalid policy file\n")
            }
            let effectiveRules: [TypedRule]?
            do {
                effectiveRules = effective
                    ? try PolicyShowRun.loadEffective(home: home, workspace: workspace)
                    : nil
            } catch {
                try ctx.fail("rv policy show: invalid policy file\n")
            }
            let exemptions = PolicyShowRun.loadExemptions(home: home, workspace: workspace)
            let text: String
            if ctx.explicitRobot {
                do {
                    switch (snapshot, effectiveRules) {
                    case (let baseSnapshot?, let rules?):
                        text = try PolicyShowRun.robotCombined(
                            baseSnapshot, effective: rules, exemptions: exemptions)
                    case (nil, let rules?):
                        text = try PolicyShowRun.robotEffective(rules)
                    case (let baseSnapshot?, nil):
                        text = try PolicyShowRun.robot(baseSnapshot, exemptions: exemptions)
                    case (nil, nil):
                        // Unreachable (`showBase` covers `!effective`): a
                        // logic error must fail loudly, never emit a
                        // fake-empty success document.
                        try ctx.fail("rv policy show: encode failed\n")
                    }
                } catch {
                    try ctx.fail("rv policy show: encode failed\n")
                }
            } else {
                var sections: [String] = []
                if let snapshot {
                    sections.append(PolicyShowRun.pretty(snapshot, exemptions: exemptions))
                }
                if let effectiveRules {
                    sections.append(PolicyShowRun.prettyEffective(effectiveRules))
                }
                text = sections.joined(separator: "\n\n")
            }
            ctx.writeStdout(text + "\n")
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List policy revisions for one layer, oldest first."
        )

        @Flag(name: .customLong("repo"), help: "List the repo layer.")
        var repo = false

        @OptionGroup
        var format: FormatFlags

        func run() async throws {
            let ctx = CommandContext.current(command: "policy list", format: format)
            let home = try ctx.requireHome()
            let workspace = URL(
                fileURLWithPath: CLIProcess.workspacePath(),
                isDirectory: true
            )
            let revisions: [PolicyRevision]
            do {
                revisions = try PolicyListRun.load(home: home, workspace: workspace, repo: repo)
            } catch {
                try ctx.fail("rv policy list: invalid policy file\n")
            }
            let text: String
            if ctx.explicitRobot {
                do {
                    text = try PolicyListRun.robot(revisions)
                } catch {
                    try ctx.fail("rv policy list: encode failed\n")
                }
            } else {
                text = PolicyListRun.pretty(revisions)
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
            let home = try CommandContext.requireHome(command: "policy validate")
            let target: PolicyValidateRun.Target
            if let path {
                target = .file(URL(fileURLWithPath: path), home)
            } else {
                target = .machine(home)
            }
            let report: PolicyDiffRiskReport
            do {
                report = try PolicyValidateRun.riskReport(target)
            } catch {
                try CommandContext.fail("rv policy validate: invalid policy file\n", exitCode: 2)
            }
            let validateWorkspace = URL(
                fileURLWithPath: CLIProcess.workspacePath(),
                isDirectory: true
            )
            for note in PolicyValidateRun.exemptionNotes(target, workspace: validateWorkspace) {
                CommandContext.writeStderr(note + "\n")
            }
            for line in report.findingLines {
                CommandContext.writeStdout(line + "\n")
            }
            if report.hasBlockingFindings {
                try CommandContext.fail(
                    "rv policy validate: blocked by policy risk findings\n",
                    exitCode: 2
                )
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
            let existing: PolicyDocument
            do {
                existing = repo
                    ? try session.loadRepoDocument()
                    : try session.loadMachineDocument()
            } catch {
                try CommandContext.fail("rv policy apply: invalid policy file\n")
            }
            let merged: PolicyDocument
            do {
                merged = try session.mergeIncoming(incoming, layer: layer, save: false)
            } catch {
                try CommandContext.fail("rv policy apply: invalid policy file\n")
            }
            // Share-ask risk, not post-merge outcome: the merge is tighten-only,
            // so diffing the merged result could never flag a relaxation. A
            // share that asks to weaken an existing rule refuses `--save`.
            let risk = PolicyDiffRisk.evaluateShare(existing: existing, incoming: incoming)
            let preview = merged.rules.map { "  \(formatDocumentRule($0))" }.joined(separator: "\n")
            let body = preview.isEmpty ? "  (none)" : preview
            let riskText = risk.previewLines.map { "\($0)\n" }.joined()
            CommandContext.writeStdout("apply\n\(body)\n\(riskText)")
            if save {
                if risk.hasBlockingFindings {
                    try CommandContext.fail("rv policy apply: blocked by policy risk findings\n")
                }
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

/// Blessed-union exemption view for `policy show` (T7).
///
/// The enforced set plus the repo-layer literals that requested exemption but
/// were dropped for lack of machine blessing. Base and effective policy are
/// inspected as separate views, borrowed from OpenShell:
/// https://docs.nvidia.com/openshell/latest/how-it-works/policies/manage-policies
struct SecretExemptionsView: Equatable, Sendable, Codable {
    var effective: [String]
    var droppedRepoLiterals: [String]
    var blessPaths: [String]
    var documentLoadFailed: Bool = false

    static let empty = SecretExemptionsView(effective: [], droppedRepoLiterals: [], blessPaths: [])
}

/// Robot document for `policy show`: the three rule origins plus the
/// exemption view. The `secretAllowPaths` key is purely additive; payloads
/// written before it existed still decode (missing key reads as empty).
struct PolicyShowRobotDocument: Equatable, Sendable, Codable {
    var builtin: [TypedRule]
    var machine: [TypedRule]
    var repo: [TypedRule]
    var secretAllowPaths: SecretExemptionsView

    init(
        builtin: [TypedRule],
        machine: [TypedRule],
        repo: [TypedRule],
        secretAllowPaths: SecretExemptionsView
    ) {
        self.builtin = builtin
        self.machine = machine
        self.repo = repo
        self.secretAllowPaths = secretAllowPaths
    }

    private enum CodingKeys: String, CodingKey {
        case builtin
        case machine
        case repo
        case secretAllowPaths
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.builtin = try container.decode([TypedRule].self, forKey: .builtin)
        self.machine = try container.decode([TypedRule].self, forKey: .machine)
        self.repo = try container.decode([TypedRule].self, forKey: .repo)
        self.secretAllowPaths =
            try container.decodeIfPresent(SecretExemptionsView.self, forKey: .secretAllowPaths)
            ?? .empty
    }
}

enum PolicyShowRun {
    static func load(
        home: HomeDirectory,
        workspace: URL,
        builtin: [TypedRule] = []
    ) throws -> PolicyShowSnapshot {
        try PolicyWorkspace(home: home, workspace: workspace).loadLayers(builtin: builtin)
    }

    static func loadEffective(
        home: HomeDirectory,
        workspace: URL,
        builtin: [TypedRule] = []
    ) throws -> [TypedRule] {
        try PolicyWorkspace(home: home, workspace: workspace).loadEffectiveRules(builtin: builtin)
    }

    /// Read-only exemption view. Missing files are empty; nothing is minted.
    static func loadExemptions(home: HomeDirectory, workspace: URL) -> SecretExemptionsView {
        let detailed = SecretAllowPaths.loadEffectiveDetailed(home: home, workspace: workspace)
        let configFile = RVPolicyPaths.configDirectory(home: home)
            .appendingPathComponent("config.json", isDirectory: false)
        return SecretExemptionsView(
            effective: detailed.effective.literals,
            droppedRepoLiterals: detailed.droppedRepoLiterals,
            blessPaths: SecretAllowPaths.loadBlessPaths(from: configFile),
            documentLoadFailed: detailed.documentLoadFailed
        )
    }

    static func pretty(_ snapshot: PolicyShowSnapshot) -> String {
        pretty(snapshot, exemptions: .empty)
    }

    static func pretty(_ snapshot: PolicyShowSnapshot, exemptions: SecretExemptionsView) -> String {
        [
            prettyExemptions(exemptions),
            prettyOrigin(.builtin, snapshot.builtin),
            prettyOrigin(.machine, snapshot.machine),
            prettyOrigin(.repo, snapshot.repo),
        ].joined(separator: "\n\n")
    }

    static func prettyExemptions(_ view: SecretExemptionsView) -> String {
        func row(_ values: [String]) -> String {
            values.isEmpty ? "(none)" : values.joined(separator: ", ")
        }
        var lines = [
            "secret.allow_paths",
            "  effective: \(row(view.effective))",
            "  dropped: \(row(view.droppedRepoLiterals))",
            "  bless_paths: \(row(view.blessPaths))",
        ]
        if view.documentLoadFailed {
            lines.append("  load: failed (a policy file could not be parsed; its exemptions were not evaluated)")
        }
        return lines.joined(separator: "\n")
    }

    static func prettyEffective(_ rules: [TypedRule]) -> String {
        let body: String
        if rules.isEmpty {
            body = "  (none)"
        } else {
            body = rules.map { "  \(formatRule($0))" }.joined(separator: "\n")
        }
        return "effective\n\(body)"
    }

    static func robot(_ snapshot: PolicyShowSnapshot) throws -> String {
        try robot(snapshot, exemptions: .empty)
    }

    static func robot(
        _ snapshot: PolicyShowSnapshot,
        exemptions: SecretExemptionsView
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let document = PolicyShowRobotDocument(
            builtin: snapshot.builtin,
            machine: snapshot.machine,
            repo: snapshot.repo,
            secretAllowPaths: exemptions
        )
        let data = try encoder.encode(document)
        return DisplayedText.escapeJSONScalars(String(decoding: data, as: UTF8.self))
    }

    static func robotEffective(_ rules: [TypedRule]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(PolicyShowEffectiveSnapshot(effective: rules))
        return DisplayedText.escapeJSONScalars(String(decoding: data, as: UTF8.self))
    }

    static func robotCombined(
        _ snapshot: PolicyShowSnapshot,
        effective: [TypedRule],
        exemptions: SecretExemptionsView
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(
            PolicyShowCombinedSnapshot(
                builtin: snapshot.builtin,
                machine: snapshot.machine,
                repo: snapshot.repo,
                effective: effective,
                secretAllowPaths: exemptions
            )
        )
        return DisplayedText.escapeJSONScalars(String(decoding: data, as: UTF8.self))
    }
}

struct PolicyShowEffectiveSnapshot: Sendable, Equatable, Codable {
    var effective: [TypedRule]
}

struct PolicyShowCombinedSnapshot: Sendable, Equatable, Codable {
    var builtin: [TypedRule]
    var machine: [TypedRule]
    var repo: [TypedRule]
    var effective: [TypedRule]
    var secretAllowPaths: SecretExemptionsView
}

enum PolicyListRun {
    static func load(
        home: HomeDirectory,
        workspace: URL,
        repo: Bool
    ) throws -> [PolicyRevision] {
        try PolicyWorkspace(home: home, workspace: workspace)
            .listRevisions(layer: repo ? .repo : .machine)
    }

    static func pretty(_ revisions: [PolicyRevision]) -> String {
        if revisions.isEmpty {
            return "(none)"
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return revisions.map { entry in
            "r\(entry.revision) \(entry.hash.prefix(12)) rules=\(entry.ruleCount) \(formatter.string(from: entry.recordedAt))"
        }.joined(separator: "\n")
    }

    static func robot(_ revisions: [PolicyRevision]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(revisions)
        return DisplayedText.escapeJSONScalars(String(decoding: data, as: UTF8.self))
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
        case file(URL, HomeDirectory)
    }

    /// Default (no path) uses the same machine load as `policy show` / evaluate:
    /// `policy.toml` if present, else legacy `typed-rules.json`. An explicit path
    /// is a share file: missing is valid; present must parse as TOML.
    static func validate(_ target: Target) throws {
        let report = try riskReport(target)
        if report.hasBlockingFindings {
            throw PolicyDiffRiskError.blockedByFindings(report)
        }
    }

    /// Parse validation plus the Phase 2 diff-risk report. The machine file is
    /// checked standalone against an empty baseline. An explicit share file is
    /// checked as an adoption candidate against the machine layer (the default
    /// `policy apply` target) with overlay semantics, so a share that asks to
    /// relax a machine rule exits 2; a share bound for the repo layer is still
    /// checked against machine, which is stricter than the effective merge.
    /// Parse failures keep their original errors; risk never masks an
    /// invalid file.
    static func riskReport(_ target: Target) throws -> PolicyDiffRiskReport {
        switch target {
        case .machine(let home):
            let document = try PolicyWorkspace(home: home).loadMachineDocument()
            return PolicyDiffRisk.evaluate(
                oldDocument: PolicyDocument(),
                newDocument: document
            )
        case .file(let url, let home):
            guard FileManager.default.fileExists(atPath: url.path) else {
                return .clean
            }
            let document = try PolicyDocumentRun.load(url)
            let baseline = try PolicyWorkspace(home: home).loadMachineDocument()
            return PolicyDiffRisk.evaluateShare(existing: baseline, incoming: document)
        }
    }

    /// Dropped-literal visible signal for `policy validate` (T7). Read-only;
    /// notes never change the exit code. The candidate-vs-boundary check is
    /// borrowed from OpenShell:
    /// https://docs.nvidia.com/openshell/latest/how-it-works/policies/prover
    static func exemptionNotes(_ target: Target, workspace: URL?) -> [String] {
        switch target {
        case .machine(let home):
            let detailed = SecretAllowPaths.loadEffectiveDetailed(
                home: home, workspace: workspace)
            var notes = detailed.droppedRepoLiterals.map {
                "rv policy validate: dropped unblessed repo literal '\($0)'"
                    + " (add to secret.bless_paths to allow)"
            }
            if detailed.documentLoadFailed {
                notes.insert(
                    "rv policy validate: a policy file could not be parsed; "
                        + "its secret.allow_paths were not evaluated",
                    at: 0
                )
            }
            return notes
        case .file(let url, _):
            guard FileManager.default.fileExists(atPath: url.path) else {
                return []
            }
            guard let document = try? PolicyDocumentRun.load(url) else {
                return []
            }
            guard document.allowPaths.isEmpty == false else {
                return []
            }
            return [
                "rv policy validate: \(document.allowPaths.count) secret.allow_paths"
                    + " literal(s) take effect at the repo layer only when named"
                    + " in secret.bless_paths",
            ]
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
    "\(DisplayedText.field(rule.id.rawValue)) \(rule.verdict.rawValue) \(predicateText(rule.predicate))"
}
