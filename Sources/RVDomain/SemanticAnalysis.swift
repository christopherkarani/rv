/// Closed wrapper family peeled before Git / filesystem analysis.
public enum WrapperKind: String, Sendable, Equatable, Codable {
    case bash
    case sh
    case zsh
    case sudo
    case env
    case command
    case python
    case node
    case ruby
    case timeout
    case nice
    case mise
    case ssh
}

/// Closed analyzer family. Wrapper layers wrap an inner Git / filesystem hit,
/// `.unknown`, or a fail-closed `.unwrapLimited`.
public enum SemanticAnalysis: Sendable, Equatable, Codable {
    case git(GitAction)
    case filesystem(FilesystemAction)
    indirect case wrapper(WrapperKind, inner: SemanticAnalysis)
    case unwrapLimited
    case unknown

    /// Walks wrapper layers to the leaf analysis.
    public var innermost: SemanticAnalysis {
        switch self {
        case .wrapper(_, let inner):
            return inner.innermost
        case .git, .filesystem, .unwrapLimited, .unknown:
            return self
        }
    }

    public var wrappers: [WrapperKind] {
        switch self {
        case .wrapper(let kind, let inner):
            return [kind] + inner.wrappers
        case .git, .filesystem, .unwrapLimited, .unknown:
            return []
        }
    }

    public var gitAction: GitAction? {
        if case .git(let action) = innermost {
            return action
        }
        return nil
    }

    public var filesystemAction: FilesystemAction? {
        if case .filesystem(let action) = innermost {
            return action
        }
        return nil
    }

    /// Wraps this analysis in `layers` from outermost to innermost.
    public func wrapping(_ layers: [WrapperKind]) -> SemanticAnalysis {
        layers.reversed().reduce(self) { current, kind in
            .wrapper(kind, inner: current)
        }
    }
}

extension SemanticAction {
    public var effects: ActionEffects {
        switch self {
        case .git(let action):
            return action.effects
        case .filesystem(let action):
            return action.effects
        }
    }

    public var resources: ActionResources {
        switch self {
        case .git(let action):
            return action.resources
        case .filesystem(let action):
            return action.resources
        }
    }
}

/// Shared-by-name set used by `GitAnalysisContext.isSharedBranch` and
/// `ActionPolicyEngine`.
enum GitSharedBranch {
    static let names: Set<String> = ["main", "master"]

    static func contains(_ name: String?) -> Bool {
        guard let name else { return false }
        return names.contains(name)
    }
}

/// Caller-supplied repository facts. Analyzers do not read disk.
///
/// `empty` is the empty probed payload. No world injected is
/// `GitAnalysisWorld.unprobed`, not `.probed(.empty)`.
public struct GitAnalysisContext: Sendable, Equatable {
    public var workingDirectory: WorkingDirectory?
    public var currentBranch: String?

    /// True iff `currentBranch` is `main` or `master`.
    public var isSharedBranch: Bool {
        GitSharedBranch.contains(currentBranch)
    }

    public init(
        workingDirectory: WorkingDirectory? = nil,
        currentBranch: String? = nil
    ) {
        self.workingDirectory = workingDirectory
        self.currentBranch = currentBranch
    }

    public static let empty = GitAnalysisContext()

    public var reviewContext: ReviewContext {
        ReviewContext(
            repository: RepositoryReviewContext(
                currentBranch: currentBranch
            )
        )
    }
}

/// Whether git repository facts were injected for analysis.
///
/// Unprobed: pack deny is the floor; implicit refspec is nil; `isSharedBranch`
/// is not consulted. Probed: HEAD / shared-by-name facts may fill
/// `GitAnalysisContext`.
public enum GitAnalysisWorld: Sendable, Equatable {
    case unprobed
    case probed(GitAnalysisContext)
}

/// Whether a filesystem I/O world was injected for analysis.
///
/// Unprobed: pack deny is the floor; unresolved-path does not tighten an allow.
/// Probed: missing cwd or repo root stays fail-closed unknown.
public enum FilesystemAnalysisWorld: Sendable, Equatable {
    case unprobed
    case probed(FilesystemAnalysisContext)
}

/// Caller-supplied path facts. Live canonicalize stays at the evaluate door.
///
/// `empty` is the empty probed payload (no cwd, no facts), used only inside
/// `.probed` when a live probe ran with missing cwd. No world injected is
/// `FilesystemAnalysisWorld.unprobed`, not `.probed(.empty)`.
public struct FilesystemAnalysisContext: Sendable, Equatable, Codable {
    public var workingDirectory: WorkingDirectory?
    public var repositoryRoot: RepositoryRoot?
    public var homeDirectory: HomePath?
    public var catalog: SecretPathCatalog
    public var facts: [FilesystemPathFact]

    public init(
        workingDirectory: WorkingDirectory? = nil,
        repositoryRoot: RepositoryRoot? = nil,
        homeDirectory: HomePath? = nil,
        catalog: SecretPathCatalog = .dayOne,
        facts: [FilesystemPathFact] = []
    ) {
        self.workingDirectory = workingDirectory
        self.repositoryRoot = repositoryRoot
        self.homeDirectory = homeDirectory
        self.catalog = catalog
        self.facts = facts
    }

    public static let empty = FilesystemAnalysisContext()

    public func fact(for apparent: String) -> FilesystemPathFact? {
        facts.first { $0.apparent == apparent }
    }

    private enum CodingKeys: String, CodingKey {
        case workingDirectory
        case repositoryRoot
        case homeDirectory
        case facts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workingDirectory = try container.decodeIfPresent(
            WorkingDirectory.self,
            forKey: .workingDirectory
        )
        repositoryRoot = try container.decodeIfPresent(
            RepositoryRoot.self,
            forKey: .repositoryRoot
        )
        homeDirectory = try container.decodeIfPresent(HomePath.self, forKey: .homeDirectory)
        catalog = .dayOne
        facts = try container.decodeIfPresent([FilesystemPathFact].self, forKey: .facts) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(workingDirectory, forKey: .workingDirectory)
        try container.encodeIfPresent(repositoryRoot, forKey: .repositoryRoot)
        try container.encodeIfPresent(homeDirectory, forKey: .homeDirectory)
        try container.encode(facts, forKey: .facts)
    }
}
