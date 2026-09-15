import Foundation
import RVDomain

/// Read-only probe for Git rebase-merge / rebase-apply directories.
enum GitRebaseProbe {
    static func rebaseInProgress(cwd: WorkingDirectory?) -> Bool {
        guard let cwd else { return false }
        guard let root = FilesystemLiveProbe.discoverRepositoryRoot(from: cwd.rawValue) else {
            return false
        }
        guard let gitdir = GitLiveProbe.resolvedGitDir(repoRoot: root.rawValue) else {
            return false
        }
        return isRebaseDirectory(gitdir + "/rebase-merge")
            || isRebaseDirectory(gitdir + "/rebase-apply")
    }

    private static func isRebaseDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
    }
}
