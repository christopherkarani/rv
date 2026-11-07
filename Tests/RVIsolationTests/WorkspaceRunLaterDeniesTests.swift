import Foundation
import Testing
@testable import RVIsolation

/// Agent and editor config a host tool runs after publish must be as
/// protected as `.git/hooks`: otherwise a caged agent plants a hook in
/// `.claude/settings.json` that later runs unsandboxed on the host.
@Suite("Workspace run-later path denies")
struct WorkspaceRunLaterDeniesTests {
    private let workspace = "/Users/dev/project"

    @Test func everyRunLaterFileIsWriteDenied() {
        let profile = workspaceControlDenies(workspacePath: workspace)
        for file in WorkspaceRunLaterPaths.files {
            #expect(profile.contains("(literal \"\(workspace)/\(file)\")"), "missing deny for \(file)")
        }
        #expect(profile.contains("(literal \"\(workspace)/.claude/settings.json\")"))
        #expect(profile.contains("(literal \"\(workspace)/.mcp.json\")"))
        #expect(profile.contains("(literal \"\(workspace)/.envrc\")"))
    }

    @Test func runLaterFilesSitInAFullWriteDeny() {
        let denies = workspaceRunLaterDenies(workspacePath: workspace)
        let fileBlock = denies.components(separatedBy: "(deny file-write-unlink file-write-create")[0]
        #expect(fileBlock.hasPrefix("(deny file-write*"))
        for file in WorkspaceRunLaterPaths.files {
            #expect(fileBlock.contains("\(workspace)/\(file)"))
        }
    }

    @Test func parentDirectoriesCannotBeSwappedByRename() {
        let denies = workspaceRunLaterDenies(workspacePath: workspace)
        let parts = denies.components(separatedBy: "(deny file-write-unlink file-write-create")
        #expect(parts.count == 2)
        for directory in WorkspaceRunLaterPaths.pinnedDirectories {
            #expect(parts[1].contains("(literal \"\(workspace)/\(directory)\")"))
        }
        // Every listed file's top-level directory must be pinned, or the
        // rename bypass reopens for it.
        for file in WorkspaceRunLaterPaths.files where file.contains("/") {
            let top = String(file.split(separator: "/")[0])
            #expect(WorkspaceRunLaterPaths.pinnedDirectories.contains(top), "\(top) is not pinned")
        }
    }

    @Test func instructionFilesStayWritable() {
        // Agents edit these as ordinary work; they belong in publish review.
        let profile = workspaceControlDenies(workspacePath: workspace)
        #expect(profile.contains("\(workspace)/CLAUDE.md") == false)
        #expect(profile.contains("\(workspace)/AGENTS.md") == false)
        #expect(profile.contains("\(workspace)/.claude/skills") == false)
    }

    @Test func pathsAreEscaped() {
        let odd = "/Users/dev/we\"ird\\dir"
        let denies = workspaceRunLaterDenies(workspacePath: odd)
        #expect(denies.contains("/Users/dev/we\\\"ird\\\\dir/.mcp.json"))
        #expect(denies.contains("we\"ird") == false || denies.contains("we\\\"ird"))
    }

    @Test func macOSGuestProfileCarriesRunLaterDenies() {
        let profile = macOSGuestSandboxProfile(workspacePath: workspace)
        #expect(profile.contains("(literal \"\(workspace)/.claude/settings.json\")"))
        #expect(profile.contains("(literal \"\(workspace)/.vscode/tasks.json\")"))
    }
}
