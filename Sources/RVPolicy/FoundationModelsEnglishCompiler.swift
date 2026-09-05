import RVDomain

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple Foundation Models `EnglishCompiler`. Constructs on every host.
/// Tests inject `FakeEnglishCompiler` and set `usesSystemModel` false so
/// compile never requires a live on-device model.
///
/// Model output fills a closed `PolicyPredicate` form. English is not saved
/// as the matcher. Domain stays free of Foundation Models.
public struct FoundationModelsEnglishCompiler: EnglishCompiler {
    public static let defaultTimeout: Duration = .seconds(3)

    public var timeout: Duration
    /// Production is `true`. Tests set `false` so compile cannot invoke Apple.
    /// False still refuses empty English, then throws `.unavailable`.
    package let usesSystemModel: Bool
    private let injected: (any EnglishCompiler)?

    public init(timeout: Duration = Self.defaultTimeout) {
        self.timeout = timeout
        self.usesSystemModel = true
        self.injected = nil
    }

    package init(
        timeout: Duration = Self.defaultTimeout,
        usesSystemModel: Bool,
        compiler: (any EnglishCompiler)? = nil
    ) {
        self.timeout = timeout
        self.usesSystemModel = usesSystemModel
        self.injected = compiler
    }

    public func compile(_ english: String) async throws -> EnglishCompileResult {
        if english.isEmpty {
            return .refuse(.empty)
        }
        if let injected {
            return try await injected.compile(english)
        }
        #if canImport(FoundationModels)
        if usesSystemModel, #available(macOS 26, *) {
            do {
                return try await ReviewTimeout.run(timeout: timeout) {
                    try await FoundationModelsEnglishCompileClient.compile(english)
                }
            } catch let error as EnglishCompilerError {
                throw error
            } catch {
                throw EnglishCompilerError.unavailable
            }
        }
        #endif
        throw EnglishCompilerError.unavailable
    }
}

/// Closed-form preview used by the AFM client and by tests. Never stores English.
package enum FoundationModelsEnglishCompileMapping: Sendable {
    package static func preview(
        force: GitPushForce?,
        branch: String?,
        verdict: TypedRuleVerdict,
        sentence: String
    ) -> EnglishCompileResult {
        let text = sentence.isEmpty
            ? defaultSentence(force: force, branch: branch, verdict: verdict)
            : sentence
        return EnglishCompileResult.makePreview(
            sentence: text,
            draft: TypedRule(
                id: ruleID(force: force, branch: branch, verdict: verdict),
                predicate: .gitPush(force: force, branch: branch),
                verdict: verdict,
                origin: .machine
            ),
            allowedToSave: true
        )
    }

    private static func ruleID(
        force: GitPushForce?,
        branch: String?,
        verdict: TypedRuleVerdict
    ) -> RuleID {
        if force == .force, branch == "main", verdict == .deny {
            return RuleID(pack: .coreGit, pattern: "force-push-main")
        }
        var parts = ["git-push"]
        if let force {
            parts.append(force.rawValue)
        }
        if let branch {
            parts.append(branch)
        }
        parts.append(verdict.rawValue)
        return RuleID(pack: .coreGit, pattern: parts.joined(separator: "-"))
    }

    private static func defaultSentence(
        force: GitPushForce?,
        branch: String?,
        verdict: TypedRuleVerdict
    ) -> String {
        let branchText = branch ?? "any branch"
        switch (force, verdict) {
        case (.force, .deny):
            return "Always block force-push to \(branchText)."
        case (.force, .allow):
            return "Always allow force-push to \(branchText)."
        case (.force, .ask):
            return "Ask before force-push to \(branchText)."
        case (_, .deny):
            return "Always block git push to \(branchText)."
        case (_, .allow):
            return "Always allow git push to \(branchText)."
        case (_, .ask):
            return "Ask before git push to \(branchText)."
        }
    }
}

#if canImport(FoundationModels)
@available(macOS 26, *)
@Generable
enum FoundationModelsEnglishOutcome: Sendable {
    case preview
    case refuse
}

@available(macOS 26, *)
@Generable
enum FoundationModelsEnglishRefusal: Sendable {
    case empty
    case uncompilable
    case unsupported
}

@available(macOS 26, *)
@Generable
enum FoundationModelsEnglishVerdict: Sendable {
    case allow
    case ask
    case deny
}

@available(macOS 26, *)
@Generable
enum FoundationModelsEnglishForce: Sendable {
    case unspecified
    case none
    case forceWithLease
    case force
}

@available(macOS 26, *)
@Generable
struct FoundationModelsEnglishCompileOutput: Sendable {
    var outcome: FoundationModelsEnglishOutcome
    var refusal: FoundationModelsEnglishRefusal
    var force: FoundationModelsEnglishForce
    var branch: String
    var verdict: FoundationModelsEnglishVerdict
    var sentence: String
}

@available(macOS 26, *)
enum FoundationModelsEnglishCompileClient: Sendable {
    static func compile(_ english: String) async throws -> EnglishCompileResult {
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        default:
            throw EnglishCompilerError.unavailable
        }

        let session = LanguageModelSession()
        do {
            let response = try await session.respond(
                to: Prompt(prompt(for: english)),
                generating: FoundationModelsEnglishCompileOutput.self
            )
            return map(response.content)
        } catch is CancellationError {
            throw EnglishCompilerError.unavailable
        } catch let error as EnglishCompilerError {
            throw error
        } catch {
            throw EnglishCompilerError.unavailable
        }
    }

    private static func prompt(for english: String) -> String {
        """
        Fill a closed git-push rule form from the English, or refuse.
        Allowed predicate: gitPush only.
        Force: unspecified, none, forceWithLease, or force.
        Branch: a git branch name, or empty if unspecified.
        Verdict: allow, ask, or deny.
        Refuse empty, uncompilable (vague advice such as be careful in prod), \
        or unsupported (npm, mcp, git status, other tools).
        Do not invent other predicates. Do not copy the English into a matcher field.
        English:
        \(english)
        """
    }

    private static func map(_ output: FoundationModelsEnglishCompileOutput) -> EnglishCompileResult {
        switch output.outcome {
        case .refuse:
            return .refuse(refusal(output.refusal))
        case .preview:
            return FoundationModelsEnglishCompileMapping.preview(
                force: gitForce(output.force),
                branch: output.branch.isEmpty ? nil : output.branch,
                verdict: verdict(output.verdict),
                sentence: output.sentence
            )
        }
    }

    private static func refusal(_ value: FoundationModelsEnglishRefusal) -> EnglishCompileRefusal {
        switch value {
        case .empty:
            return .empty
        case .uncompilable:
            return .uncompilable
        case .unsupported:
            return .unsupported
        }
    }

    private static func gitForce(_ value: FoundationModelsEnglishForce) -> GitPushForce? {
        switch value {
        case .unspecified:
            return nil
        case .none:
            return GitPushForce.none
        case .forceWithLease:
            return .forceWithLease
        case .force:
            return .force
        }
    }

    private static func verdict(_ value: FoundationModelsEnglishVerdict) -> TypedRuleVerdict {
        switch value {
        case .allow:
            return .allow
        case .ask:
            return .ask
        case .deny:
            return .deny
        }
    }
}
#endif
