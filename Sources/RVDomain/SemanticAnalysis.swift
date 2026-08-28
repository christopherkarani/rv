/// Closed analyzer family. Wrapper recursion stays off this slice.
public enum SemanticAnalysis: Sendable, Equatable, Codable {
    case git(GitAction)
    case filesystem(FilesystemAction)
    case unknown
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
