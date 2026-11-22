import ArgumentParser
import Foundation
import RVDomain
import RVHistory
import RVPolicy
import RVPresentation
import RVService

struct PolicyDraftCommand: AsyncParsableCommand, CommandUsage {
    static let configuration = CommandConfiguration(
        commandName: "draft",
        abstract: "Turn a plain sentence into a typed rule preview."
    )

    static let usage = [
        HelpRow(name: "rv policy draft \"<sentence>\" [--repo] [--save [--wait [--wait-timeout <seconds>]]]"),
        HelpRow(name: "rv policy draft --english <sentence> ..."),
    ]

    @Argument(help: "The rule, in plain words: \"never force-push to main\".")
    var sentence: String?

    @Option(name: .customLong("english"), help: "The same sentence, as an option.")
    var englishOption: String?

    var english: String { englishOption ?? sentence ?? "" }

    @Flag(name: .customLong("save"), help: "Write the compiled typed rule.")
    var save = false

    @Flag(name: .customLong("repo"), help: "Save to the repo policy file.")
    var repo = false

    @OptionGroup
    var format: FormatFlags

    @OptionGroup
    var waitFlags: PolicyWaitFlags

    func validate() throws {
        if sentence != nil, englishOption != nil {
            throw ValidationError("give the sentence once: either \"<sentence>\" or --english")
        }
        try waitFlags.check(save: save)
    }

    func run() async throws {
        let ctx = CommandContext.current(command: "policy draft", format: format)
        guard save == false || english.isEmpty == false else {
            try ctx.fail("rv policy draft: --save needs a sentence: rv policy draft \"never force-push to main\" --save\n")
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
        case .refuse(.alreadyBuiltIn) where result.alreadyOn:
            return
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
    /// A built-in rule already stops what the sentence asked for, here.
    var alreadyOn = false
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
        // Compile first: the owner approves the rule they can see, and a
        // sentence with nothing to save never asks.
        let compiled = try await compiler.compile(english)
        switch compiled {
        case .refuse(let reason):
            let alreadyOn = reason == .alreadyBuiltIn && coreFilesystemOn(home: home)
            return PolicyDraftResult(
                text: try render(compiled, english: english, alreadyOn: alreadyOn, robot: robot),
                outcome: .refuse(reason),
                alreadyOn: alreadyOn
            )
        case .preview(let preview):
            var savedDocument: PolicyDocument?
            if save, preview.allowedToSave {
                // The typed rule, never the model's words, goes in the prompt.
                let authorization = try await OwnerConfirmation.require(
                    "save the policy rule \(formatDocumentRule(preview.rule))")
                savedDocument = try await ConfigChangeAudit.$authorization.withValue(authorization) {
                    try PolicyWorkspace(home: home, workspace: workspace).upsert(
                        preview.rule,
                        layer: repo ? .repo : .machine
                    )
                }
            }
            return PolicyDraftResult(
                text: try render(compiled, english: english, alreadyOn: false, robot: robot),
                outcome: .preview(saved: savedDocument != nil),
                savedHash: savedDocument.map(PolicyRevisionIdentity.hash)
            )
        }
    }

    /// The out-of-repo stop belongs to `core.filesystem`; off, nothing stops it.
    private static func coreFilesystemOn(home: HomeDirectory) -> Bool {
        (try? PacksFacade.effectiveIDs(home: home))?.contains(.coreFilesystem) ?? false
    }

    private static func render(
        _ result: EnglishCompileResult, english: String, alreadyOn: Bool, robot: Bool
    ) throws -> String {
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
            var lines = ["\(DisplayedText.field(preview.sentence))", formatDocumentRule(preview.rule)]
            if preview.rule.verdict == .allow {
                lines.append(restrictOnlyNote)
            }
            return lines.joined(separator: "\n")
        case .refuse(.alreadyBuiltIn):
            if alreadyOn {
                return "✓ Already on: rv stops deletes and moves outside this repo "
                    + "(\(BuiltinRule.outOfRepoWrite.ruleID.rawValue)). Nothing to save."
            }
            return "refused (alreadyBuiltIn): only the core.filesystem pack stops changes outside this repo, "
                + "and it is off here; a rule can't name a path yet\n→ rv packs enable core.filesystem"
        case .refuse(let reason):
            return "refused (\(reason.rawValue)): \(refusalReason(reason, english: english))"
        }
    }

    /// Typed rules only add stops; an allow cannot loosen rv or a pack.
    static let restrictOnlyNote =
        "note: allow is restrict-only: it never lets through what rv or a pack stops, so this rule changes nothing on its own"

    /// One line: the grammar's own reason when it has one, else the kind's.
    static func refusalReason(_ reason: EnglishCompileRefusal, english: String) -> String {
        if case .refused(_, let why) = PlainEnglishRuleCompiler().draft(english) {
            return why
        }
        switch reason {
        case .empty:
            return "nothing to draft; say a rule, like \"never force-push to main\""
        case .uncompilable:
            return "can't tell which command this is about; name one: git push, git reset, git clean, git restore, rm or mv"
        case .unsupported, .unsupportedPredicate:
            return "drafts cover git push, reset, clean and restore, and deleting or moving files"
        case .hardStop:
            return "rv always stops this; a rule cannot change it"
        case .alreadyBuiltIn:
            return "rv already stops this with a built-in rule"
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
