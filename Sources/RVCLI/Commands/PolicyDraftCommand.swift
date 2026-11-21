import ArgumentParser
import Foundation
import RVDomain
import RVHistory
import RVPolicy
import RVPresentation

struct PolicyDraftCommand: AsyncParsableCommand, CommandUsage {
    static let configuration = CommandConfiguration(
        commandName: "draft",
        abstract: "Compile English into a typed rule preview."
    )

    static let usage = [
        HelpRow(name: "rv policy draft --english <text> [--repo] [--save [--wait [--wait-timeout <seconds>]]]"),
    ]

    @Option(name: .customLong("english"), help: "English to compile into a typed rule.")
    var english: String

    @Flag(name: .customLong("save"), help: "Write the compiled typed rule.")
    var save = false

    @Flag(name: .customLong("repo"), help: "Save to the repo policy file.")
    var repo = false

    @OptionGroup
    var format: FormatFlags

    @OptionGroup
    var waitFlags: PolicyWaitFlags

    func validate() throws {
        try waitFlags.check(save: save)
    }

    func run() async throws {
        let ctx = CommandContext.current(command: "policy draft", format: format)
        guard save == false || english.isEmpty == false else {
            try ctx.fail("rv policy draft: --save requires --english\n")
        }
        let home = try ctx.requireHome()
        let workspace = URL(
            fileURLWithPath: CLIProcess.workspacePath(),
            isDirectory: true
        )
        let compiler: any EnglishCompiler = CLIProcess.context?.englishCompiler ?? EnglishCompileChain()
        let result: PolicyDraftResult
        do {
            result = try await PolicyDraftRun.execute(
                english: english,
                save: save,
                repo: repo,
                robot: ctx.explicitRobot,
                home: home,
                workspace: workspace,
                compiler: compiler
            )
        } catch let error as PolicyCeilingError {
            try ctx.fail("rv policy draft: refused: \(error.refusal)\n")
        } catch {
            try ctx.fail("rv policy draft: failed\n")
        }
        ctx.writeStdout(result.text + "\n")
        switch result.outcome {
        case .preview(let saved):
            if save && saved == false {
                throw ExitCode(1)
            }
            if let savedHash = result.savedHash {
                try await PolicyLoadWait.confirm(
                    command: "policy draft", layer: repo ? .repo : .machine, hash: savedHash,
                    flags: waitFlags, robot: ctx.explicitRobot)
            }
        case .refuse:
            throw ExitCode(1)
        }
    }
}

struct PolicyDraftResult: Equatable, Sendable {
    var text: String
    var outcome: PolicyDraftOutcome
    /// `PolicyRevisionIdentity.hash` of the layer document the save wrote.
    var savedHash: String? = nil
}

enum PolicyDraftOutcome: Equatable, Sendable {
    case preview(saved: Bool)
    case refuse(EnglishCompileRefusal)
}

enum PolicyDraftRun {
    static func execute(
        english: String,
        save: Bool,
        repo: Bool = false,
        robot: Bool,
        home: HomeDirectory,
        workspace: URL,
        compiler: some EnglishCompiler
    ) async throws -> PolicyDraftResult {
        var authorization: String?
        if save { authorization = try await OwnerConfirmation.require("save a policy rule drafted from English") }
        let compiled = try await compiler.compile(english)
        switch compiled {
        case .refuse(let reason):
            return PolicyDraftResult(
                text: try render(compiled, robot: robot),
                outcome: .refuse(reason)
            )
        case .preview(let preview):
            var savedDocument: PolicyDocument?
            if save, preview.allowedToSave {
                savedDocument = try await ConfigChangeAudit.$authorization.withValue(authorization) {
                    try PolicyWorkspace(home: home, workspace: workspace).upsert(
                        preview.rule,
                        layer: repo ? .repo : .machine
                    )
                }
            }
            return PolicyDraftResult(
                text: try render(compiled, robot: robot),
                outcome: .preview(saved: savedDocument != nil),
                savedHash: savedDocument.map(PolicyRevisionIdentity.hash)
            )
        }
    }

    private static func render(_ result: EnglishCompileResult, robot: Bool) throws -> String {
        if robot {
            switch result {
            case .preview(let preview):
                return try RobotJSON.encode(preview)
            case .refuse(let reason):
                return try RobotJSON.encode(PolicyDraftRobotRefuse(refuse: reason))
            }
        }
        switch result {
        case .preview(let preview):
            return "\(preview.sentence)\n\(formatDocumentRule(preview.rule))"
        case .refuse(let reason):
            return "refused: \(reason.rawValue)"
        }
    }
}

struct PolicyDraftRobotRefuse: Equatable, Sendable, Codable {
    var refuse: EnglishCompileRefusal
}

func formatDocumentRule(_ rule: PolicyDocumentRule) -> String {
    "\(DisplayedText.field(rule.id.rawValue)) \(rule.verdict.rawValue) \(predicateText(rule.predicate))"
}

func predicateText(_ predicate: PolicyPredicate) -> String {
    switch predicate {
    case .gitPush(let force, let branch):
        let forceText: String
        switch force {
        case .any:
            forceText = "-"
        case .exactly(let value):
            forceText = value.rawValue
        }
        let branchText = branch.map { DisplayedText.field($0) } ?? "-"
        return "gitPush force=\(forceText) branch=\(branchText)"
    case .gitDiscardWorktree(let pathspec):
        return "gitDiscardWorktree pathspec=\(pathspec.map { DisplayedText.field($0) } ?? "-")"
    case .gitReset(let mode):
        return "gitReset mode=\(mode?.rawValue ?? "-")"
    case .gitClean(let force, let directories):
        return "gitClean force=\(force.map(String.init) ?? "-") directories=\(directories.map(String.init) ?? "-")"
    case .filesystemDelete(let recursive, let force):
        return "filesystemDelete recursive=\(recursive.map(String.init) ?? "-") force=\(force.map(String.init) ?? "-")"
    case .filesystemMove:
        return "filesystemMove"
    }
}
