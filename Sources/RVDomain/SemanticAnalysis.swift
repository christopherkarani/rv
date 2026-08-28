/// Closed analyzer family. Filesystem and wrapper cases stay off this slice.
public enum SemanticAnalysis: Sendable, Equatable, Codable {
    case git(GitAction)
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
