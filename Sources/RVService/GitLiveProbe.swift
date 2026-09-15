import Foundation
import RVDomain

/// Read-only gitdir + HEAD facts for the git analyzer. Classification stays pure.
enum GitLiveProbe {
    static func context(cwd: WorkingDirectory?) -> GitAnalysisContext {
        GitAnalysisContext(
            workingDirectory: cwd,
            currentBranch: namedBranch(cwd: cwd)
        )
    }

    private static func namedBranch(cwd: WorkingDirectory?) -> String? {
        guard let cwd else { return nil }
        guard let root = FilesystemLiveProbe.discoverRepositoryRoot(from: cwd.rawValue) else {
            return nil
        }
        guard let gitdir = GitRebaseProbe.resolvedGitDir(repoRoot: root.rawValue) else {
            return nil
        }
        return namedBranch(fromHEADAt: gitdir + "/HEAD")
    }

    private static func namedBranch(fromHEADAt path: String) -> String? {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        let prefix = "ref: refs/heads/"
        for line in contents.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.isEmpty == false else { continue }
            guard trimmed.hasPrefix(prefix) else { return nil }
            let name = String(trimmed.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
        return nil
    }
}
