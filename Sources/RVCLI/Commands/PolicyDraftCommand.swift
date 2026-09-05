import ArgumentParser
import Foundation
import RVDomain
import RVPolicy

struct PolicyDraftCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "draft",
        abstract: "Compile English into a typed rule preview."
    )

    @Option(name: .customLong("english"), help: "English to compile into a typed rule.")
    var english: String

    @Flag(name: .customLong("save"), help: "Write the compiled typed rule to machine policy.")
    var save = false

    @OptionGroup
    var format: FormatFlags

    func run() async throws {
        guard let home = HomeDirectory.process() else {
            FileHandle.standardError.write(Data("rv policy draft: HOME is not set\n".utf8))
            throw ExitCode(1)
        }
        let workspace = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        let result: PolicyDraftResult
        do {
            result = try await PolicyDraftRun.execute(
                english: english,
                save: save,
                robot: format.json || format.robot,
                home: home,
                workspace: workspace,
                compiler: FakeEnglishCompiler()
            )
        } catch {
            FileHandle.standardError.write(Data("rv policy draft: failed\n".utf8))
            throw ExitCode(1)
        }
        FileHandle.standardOutput.write(Data((result.text + "\n").utf8))
        switch result.outcome {
        case .preview(let saved):
            if save && saved == false {
                throw ExitCode(1)
            }
        case .refuse:
            throw ExitCode(1)
        }
    }
}

struct PolicyDraftResult: Equatable, Sendable {
    var text: String
    var outcome: PolicyDraftOutcome
}

enum PolicyDraftOutcome: Equatable, Sendable {
    case preview(saved: Bool)
    case refuse(EnglishCompileRefusal)
}

enum PolicyDraftRun {
    static func execute(
        english: String,
        save: Bool,
        robot: Bool,
        home: HomeDirectory,
        workspace _: URL,
        compiler: some EnglishCompiler
    ) async throws -> PolicyDraftResult {
        let compiled = try await compiler.compile(english)
        switch compiled {
        case .refuse(let reason):
            return PolicyDraftResult(
                text: try render(compiled, robot: robot),
                outcome: .refuse(reason)
            )
        case .preview(let preview):
            var saved = false
            if save, preview.allowedToSave {
                let store = TypedRuleStore(
                    baseDirectory: RVPolicyPaths.configDirectory(home: home)
                )
                try upsert(preview.draft, into: store)
                saved = true
            }
            return PolicyDraftResult(
                text: try render(compiled, robot: robot),
                outcome: .preview(saved: saved)
            )
        }
    }

    private static func upsert(_ rule: TypedRule, into store: TypedRuleStore) throws {
        let stamped = TypedRule(
            id: rule.id,
            predicate: rule.predicate,
            verdict: rule.verdict,
            origin: .machine
        )
        var machine = try store.loadMachine()
        if let index = machine.firstIndex(where: { $0.predicate == stamped.predicate }) {
            machine[index] = stamped
        } else {
            machine.append(stamped)
        }
        try store.saveMachine(machine)
    }

    private static func render(_ result: EnglishCompileResult, robot: Bool) throws -> String {
        if robot {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data: Data
            switch result {
            case .preview(let preview):
                data = try encoder.encode(preview)
            case .refuse(let reason):
                data = try encoder.encode(PolicyDraftRobotRefuse(refuse: reason))
            }
            return String(decoding: data, as: UTF8.self)
        }
        switch result {
        case .preview(let preview):
            return "\(preview.sentence)\n\(formatRule(preview.draft))"
        case .refuse(let reason):
            return "refused: \(reason.rawValue)"
        }
    }
}

struct PolicyDraftRobotRefuse: Equatable, Sendable, Codable {
    var refuse: EnglishCompileRefusal
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
