import Foundation
import RVDomain

/// Live gitdir / HEAD facts for the git analyzer. Classification stays pure.
struct GitLiveFacts: Sendable, Equatable {
    var analysis: GitAnalysisContext
    var rebaseInProgress: Bool
}

/// Read-only gitdir + HEAD probe. Engine stays pure.
enum GitLiveProbe {
    static func facts(
        cwd: WorkingDirectory?,
        homeDirectory _: String? = nil
    ) -> GitLiveFacts {
        let unknown = GitLiveFacts(
            analysis: GitAnalysisContext(workingDirectory: cwd),
            rebaseInProgress: false
        )
        guard let cwd else { return unknown }
        guard let root = FilesystemLiveProbe.discoverRepositoryRoot(from: cwd.rawValue) else {
            return unknown
        }
        guard let gitdir = resolvedGitDir(repoRoot: root.rawValue) else {
            return unknown
        }
        let branch = namedBranch(fromHEADAt: gitdir + "/HEAD")
        return GitLiveFacts(
            analysis: GitAnalysisContext(
                workingDirectory: cwd,
                currentBranch: branch,
                isSharedBranch: branch == "main" || branch == "master"
            ),
            rebaseInProgress: isRebaseDirectory(gitdir + "/rebase-merge")
                || isRebaseDirectory(gitdir + "/rebase-apply")
        )
    }

    private static func resolvedGitDir(repoRoot: String) -> String? {
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

    private static func parseGitDirFile(at path: String, repoRoot: String) -> String? {
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

    private static func namedBranch(fromHEADAt path: String) -> String? {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        guard
            let first = contents.split(
                omittingEmptySubsequences: false,
                whereSeparator: \.isNewline
            ).first
        else {
            return nil
        }
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        let prefix = "ref: refs/heads/"
        guard trimmed.hasPrefix(prefix) else { return nil }
        let name = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    private static func isRebaseDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
    }
}
