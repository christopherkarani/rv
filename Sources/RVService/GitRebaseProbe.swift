import RVDomain

/// Rebase-in-progress is a `GitLiveProbe` fact. This name stays as a wrapper.
enum GitRebaseProbe {
    static func rebaseInProgress(cwd: WorkingDirectory?) -> Bool {
        GitLiveProbe.facts(cwd: cwd).rebaseInProgress
    }
}
