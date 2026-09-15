import Foundation
import RVDomain
import RVEngine

/// Read-only HEAD probe after unwrap. Always `.probed`; missing gitdir is
/// unknown, not unprobed, and not an unresolved-path deny.
enum GitLiveProbe {
    static func world(
        unwrapped: UnwrapOutcome,
        fallbackCwd: WorkingDirectory?
    ) -> GitAnalysisWorld {
        let cwd: WorkingDirectory?
        switch unwrapped {
        case .complete(let extracted):
            cwd = extracted.workingDirectory ?? fallbackCwd
        case .limited:
            cwd = fallbackCwd
        }
        return .probed(context(cwd: cwd))
    }

    /// Resolves `.git` directory or `gitdir:` file. Shared with `GitRebaseProbe`.
    static func resolvedGitDir(repoRoot: String) -> String? {
        let git = repoRoot == "/" ? "/.git" : repoRoot + "/.git"
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: git, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue {
            return git
        }
        return parseGitDirFile(at: git, repoRoot: repoRoot)
    }
}

private func context(cwd: WorkingDirectory?) -> GitAnalysisContext {
    guard let cwd else {
        return GitAnalysisContext()
    }
    guard let root = FilesystemLiveProbe.discoverRepositoryRoot(from: cwd.rawValue),
        let gitdir = GitLiveProbe.resolvedGitDir(repoRoot: root.rawValue),
        let branch = attachedBranch(at: gitdir)
    else {
        return GitAnalysisContext(workingDirectory: cwd)
    }
    return GitAnalysisContext(
        workingDirectory: cwd,
        currentBranch: branch
    )
}

private func attachedBranch(at gitdir: String) -> String? {
    guard let contents = try? String(contentsOfFile: gitdir + "/HEAD", encoding: .utf8) else {
        return nil
    }
    guard let rawLine = contents.split(whereSeparator: \.isNewline).first else {
        return nil
    }
    let line = rawLine.trimmingCharacters(in: .whitespaces)
    guard line.hasPrefix("ref:") else { return nil }
    let ref = line.dropFirst("ref:".count).trimmingCharacters(in: .whitespaces)
    let heads = "refs/heads/"
    guard ref.hasPrefix(heads) else { return nil }
    let name = String(ref.dropFirst(heads.count))
    guard name.isEmpty == false else { return nil }
    return name
}

private func parseGitDirFile(at path: String, repoRoot: String) -> String? {
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
        return nil
    }
    for line in contents.split(whereSeparator: \.isNewline) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("gitdir:") else { continue }
        let rest = trimmed.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard rest.isEmpty == false else { return nil }
        if rest.hasPrefix("/") {
            return rest
        }
        return repoRoot + "/" + rest
    }
    return nil
}
