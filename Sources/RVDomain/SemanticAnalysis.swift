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

/// Caller-supplied repository facts. Analyzers do not read disk.
public struct GitAnalysisContext: Sendable, Equatable {
    public var workingDirectory: WorkingDirectory?
    public var currentBranch: String?
    public var isSharedBranch: Bool

    public init(
        workingDirectory: WorkingDirectory? = nil,
        currentBranch: String? = nil,
        isSharedBranch: Bool = false
    ) {
        self.workingDirectory = workingDirectory
        self.currentBranch = currentBranch
        self.isSharedBranch = isSharedBranch
    }

    public static let empty = GitAnalysisContext()

    public var reviewContext: ReviewContext {
        ReviewContext(
            repository: RepositoryReviewContext(
                currentBranch: currentBranch,
                isSharedBranch: isSharedBranch
            )
        )
    }
}

/// Caller-supplied path facts. Live canonicalize stays at the evaluate door.
public struct FilesystemAnalysisContext: Sendable, Equatable {
    public var workingDirectory: WorkingDirectory?
    public var repositoryRoot: RepositoryRoot?
    public var homeDirectory: String?
    public var catalog: SecretPathCatalog
    public var facts: [FilesystemPathFact]

    public init(
        workingDirectory: WorkingDirectory? = nil,
        repositoryRoot: RepositoryRoot? = nil,
        homeDirectory: String? = nil,
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
}
