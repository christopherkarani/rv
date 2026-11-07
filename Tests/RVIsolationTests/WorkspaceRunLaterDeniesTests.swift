import Foundation
import Testing
@testable import RVIsolation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Agent and editor config a host tool runs after publish must be as
/// protected as `.git/hooks`: otherwise a caged agent plants a hook in
/// `.claude/settings.json` that later runs unsandboxed on the host.
@Suite("Workspace run-later path denies")
struct WorkspaceRunLaterDeniesTests {
    private let workspace = "/Users/dev/project"

    /// POSIX extended-regex match, the dialect Seatbelt `regex` filters use.
    private func matches(_ pattern: String, _ path: String) -> Bool {
        var compiled = regex_t()
        guard regcomp(&compiled, pattern, REG_EXTENDED | REG_NOSUB) == 0 else {
            Issue.record("pattern does not compile: \(pattern)")
            return false
        }
        defer { regfree(&compiled) }
        return regexec(&compiled, path, 0, nil, 0) == 0
    }

    private func pattern(_ relative: String, tree: Bool = false) -> String {
        caseInsensitiveWorkspaceRegex(workspacePath: workspace, relative: relative, tree: tree)
    }

    @Test func everyProtectedPathAppearsAsARegexDeny() {
        let profile = workspaceControlDenies(workspacePath: workspace)
        for file in WorkspaceRunLaterPaths.files {
            let expected = "(regex \"\(escapeSeatbeltSubpath(pattern(file)))\")"
            #expect(profile.contains(expected), "missing deny for \(file)")
        }
        for tree in WorkspaceRunLaterPaths.trees {
            #expect(profile.contains(escapeSeatbeltSubpath(pattern(tree, tree: true))))
        }
    }

    @Test func caseVariantsAreMatched() {
        // APFS is usually case-insensitive: `.MCP.json` is the same file.
        #expect(matches(pattern(".mcp.json"), "\(workspace)/.mcp.json"))
        #expect(matches(pattern(".mcp.json"), "\(workspace)/.MCP.JSON"))
        #expect(matches(pattern(".claude/settings.json"), "\(workspace)/.Claude/Settings.json"))
        #expect(matches(pattern(".envrc"), "\(workspace)/.EnvRC"))
    }

    @Test func dotsAreLiteralAndMatchesAreAnchored() {
        #expect(matches(pattern(".mcp.json"), "\(workspace)/xmcpxjson") == false)
        #expect(matches(pattern(".mcp.json"), "\(workspace)/.mcp.json.bak") == false)
        #expect(matches(pattern(".mcp.json"), "\(workspace)/sub/.mcp.json") == false)
        #expect(matches(pattern(".mcp.json"), "/other\(workspace)/.mcp.json") == false)
    }

    @Test func treesCoverTheirContentsOnly() {
        let hooks = pattern(".claude/hooks", tree: true)
        #expect(matches(hooks, "\(workspace)/.claude/hooks"))
        #expect(matches(hooks, "\(workspace)/.claude/hooks/pre.sh"))
        #expect(matches(hooks, "\(workspace)/.CLAUDE/HOOKS/deep/x.sh"))
        #expect(matches(hooks, "\(workspace)/.claude/hooksy") == false)
        #expect(matches(hooks, "\(workspace)/.claude/agents/a.md") == false)
    }

    @Test func workspacePrefixIsEscaped() {
        let odd = "/Users/dev/a.b+c(d)"
        let regex = caseInsensitiveWorkspaceRegex(workspacePath: odd, relative: ".envrc")
        #expect(matches(regex, "/Users/dev/a.b+c(d)/.envrc"))
        #expect(matches(regex, "/Users/dev/aXbbc(d)/.envrc") == false)
    }

    @Test func quotesAndBackslashesAreEscapedForSBPL() {
        let odd = "/Users/dev/we\"ird\\dir"
        let denies = workspaceRunLaterDenies(workspacePath: odd)
        // The regex escapes the backslash (\\), then the SBPL string escapes
        // both backslashes and the quote: we\"ird\\\\dir in the profile text.
        #expect(denies.contains("we\\\"ird\\\\\\\\dir"))
        #expect(denies.contains("we\"ird") == false)
    }

    @Test func parentDirectoriesCannotBeSwappedByRename() {
        let denies = workspaceRunLaterDenies(workspacePath: workspace)
        let parts = denies.components(separatedBy: "(deny file-write-unlink file-write-create")
        #expect(parts.count == 2)
        #expect(parts[0].hasPrefix("(deny file-write*"))
        for directory in WorkspaceRunLaterPaths.pinnedDirectories {
            #expect(parts[1].contains(escapeSeatbeltSubpath(pattern(directory))))
        }
        // Every protected path's top-level directory must be pinned, or the
        // rename bypass reopens for it.
        for path in WorkspaceRunLaterPaths.files + WorkspaceRunLaterPaths.trees where path.contains("/") {
            let top = String(path.split(separator: "/")[0])
            #expect(WorkspaceRunLaterPaths.pinnedDirectories.contains(top), "\(top) is not pinned")
        }
    }

    @Test func instructionFilesStayWritable() {
        // Agents edit these as ordinary work; they belong in publish review.
        for path in ["CLAUDE.md", "AGENTS.md", ".claude/skills/x/SKILL.md", ".claude/agents/a.md"] {
            for file in WorkspaceRunLaterPaths.files {
                #expect(matches(pattern(file), "\(workspace)/\(path)") == false)
            }
            for tree in WorkspaceRunLaterPaths.trees {
                #expect(matches(pattern(tree, tree: true), "\(workspace)/\(path)") == false)
            }
        }
    }

    @Test func legacyControlPathsAlsoMatchCaseVariants() {
        let denies = workspaceControlCaseVariantDenies(workspacePath: workspace)
        #expect(workspaceControlDenies(workspacePath: workspace).contains(denies))
        let rv = pattern(".rv", tree: true)
        #expect(denies.contains(escapeSeatbeltSubpath(rv)))
        #expect(matches(rv, "\(workspace)/.RV/policy.toml"))
        #expect(matches(rv, "\(workspace)/.rv"))
        #expect(matches(rv, "\(workspace)/.rvx") == false)
        let hooks = pattern(".git/hooks", tree: true)
        #expect(matches(hooks, "\(workspace)/.GIT/Hooks/pre-commit"))
        #expect(matches(pattern(".git/config"), "\(workspace)/.Git/CONFIG"))
        #expect(matches(pattern(".git/config"), "\(workspace)/.git/config.lock") == false)
        // `.git` itself is entry-pinned (data, unlink, create), not a tree:
        // objects and refs inside must stay writable.
        #expect(matches(pattern(".git"), "\(workspace)/.git/objects/ab") == false)
    }

    @Test func macOSGuestProfileDeniesLinksAndCarriesRunLaterDenies() {
        let profile = macOSGuestSandboxProfile(workspacePath: workspace)
        #expect(profile.contains("(deny file-link)"))
        #expect(profile.contains("(deny file-clone)"))
        #expect(profile.hasSuffix(workspaceControlDenies(workspacePath: workspace)))
        #expect(profile.contains(escapeSeatbeltSubpath(pattern(".claude/settings.json"))))
    }
}
