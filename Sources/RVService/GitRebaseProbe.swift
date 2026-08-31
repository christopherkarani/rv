import Foundation
import RVDomain

/// Read-only probe for Git rebase-merge / rebase-apply directories.
enum GitRebaseProbe {
    static func rebaseInProgress(cwd: WorkingDirectory?) -> Bool {
        guard let cwd else { return false }
        guard let root = FilesystemLiveProbe.discoverRepositoryRoot(from: cwd.rawValue) else {
            return false
        }
        guard let gitdir = resolvedGitDir(repoRoot: root.rawValue) else {
            return false
        }
        return isRebaseDirectory(gitdir + "/rebase-merge")
            || isRebaseDirectory(gitdir + "/rebase-apply")
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

    private static func isRebaseDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
    }
}
