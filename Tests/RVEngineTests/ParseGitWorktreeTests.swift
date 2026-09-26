import Testing
import RVDomain
@testable import RVEngine

@Suite("Parse git worktree")
struct ParseGitWorktreeTests {
    @Test func checkout_createForceOrphanAndAttachedBranch() {
        #expect(parseCheckout(["-b", "feature"]) == .createBranch(name: "feature", startPoint: nil, force: false))
        #expect(parseCheckout(["--branch", "topic", "main"]) == .createBranch(name: "topic", startPoint: "main", force: false))
        #expect(parseCheckout(["-B", "rewrite"]) == .createBranch(name: "rewrite", startPoint: nil, force: true))
        #expect(parseCheckout(["--orphan", "root"]) == .createBranch(name: "root", startPoint: nil, force: false))
        #expect(parseCheckout(["--branch=hotfix"]) == .createBranch(name: "hotfix", startPoint: nil, force: false))
        #expect(parseCheckout(["-qltm", "-b", "quiet"]) == .createBranch(name: "quiet", startPoint: nil, force: false))
        #expect(parseCheckout(["-qb", "from-cluster"]) == .createBranch(name: "from-cluster", startPoint: nil, force: false))
        #expect(parseCheckout(["-qB", "force-cluster"]) == .createBranch(name: "force-cluster", startPoint: nil, force: true))
    }

    @Test func checkout_discardForceSwitchAndSkipFlags() {
        #expect(
            parseCheckout(["HEAD", "--", "file.swift"])
                == .discardWorktree(pathspecs: ["file.swift"], source: "HEAD")
        )
        #expect(
            parseCheckout(["--ours", "--theirs", "--", "conflict.swift"])
                == .discardWorktree(pathspecs: ["conflict.swift"], source: nil)
        )
        #expect(
            parseCheckout(["--quiet", "--track", "--no-track", "-t", "-l", "--detach", "--", "x"])
                == .discardWorktree(pathspecs: ["x"], source: nil)
        )
        #expect(
            parseCheckout(["--conflict=merge", "--ignore-other-worktrees", "--", "y"])
                == .discardWorktree(pathspecs: ["y"], source: nil)
        )
        #expect(parseCheckout(["-f", "main"]) == .switchBranch(name: "main", force: true))
        #expect(parseCheckout(["--force", "topic"]) == .switchBranch(name: "topic", force: true))
        #expect(parseCheckout(["-qf", "only"]) == .switchBranch(name: "only", force: true))
    }

    @Test func checkout_rejectsUnknownPendingAndCreateWithPathspecs() {
        #expect(parseCheckout(["-p", "file"]) == nil)
        #expect(parseCheckout(["-z", "file"]) == nil)
        #expect(parseCheckout(["--unknown"]) == nil)
        #expect(parseCheckout(["-b"]) == nil)
        #expect(parseCheckout(["-b", "-f"]) == nil)
        #expect(parseCheckout(["-b", "a", "b", "c"]) == nil)
        #expect(parseCheckout(["-b", "feature", "--", "file"]) == nil)
        #expect(parseCheckout(["--branch="]) == nil)
        #expect(parseCheckout(["main"]) == nil)
        #expect(parseCheckout(["-f", "a", "b"]) == nil)
        #expect(parseCheckout([]) == nil)
    }

    @Test func switch_createForceAndSkip() {
        #expect(parseSwitch(["-c", "topic"]) == .createBranch(name: "topic", startPoint: nil, force: false))
        #expect(parseSwitch(["--create", "topic"]) == .createBranch(name: "topic", startPoint: nil, force: false))
        #expect(parseSwitch(["-C", "rewrite"]) == .createBranch(name: "rewrite", startPoint: nil, force: true))
        #expect(parseSwitch(["--force-create", "rewrite"]) == .createBranch(name: "rewrite", startPoint: nil, force: true))
        #expect(parseSwitch(["-f", "main"]) == .switchBranch(name: "main", force: true))
        #expect(parseSwitch(["--force", "main"]) == .switchBranch(name: "main", force: true))
        #expect(parseSwitch(["--discard-changes", "main"]) == .switchBranch(name: "main", force: true))
        #expect(parseSwitch(["-qdmt", "quiet"]) == .switchBranch(name: "quiet", force: false))
        #expect(parseSwitch(["-qf", "main"]) == .switchBranch(name: "main", force: true))
        #expect(parseSwitch(["-qc", "from-cluster"]) == .createBranch(name: "from-cluster", startPoint: nil, force: false))
        #expect(parseSwitch(["-qC", "force-cluster"]) == .createBranch(name: "force-cluster", startPoint: nil, force: true))
        #expect(parseSwitch(["--quiet", "--detach", "--guess", "--no-guess", "name"]) == .switchBranch(name: "name", force: false))
        #expect(parseSwitch(["name"]) == .switchBranch(name: "name", force: false))
    }

    @Test func switch_rejectsUnknownPendingAndSecondName() {
        #expect(parseSwitch(["-z", "name"]) == nil)
        #expect(parseSwitch(["--unknown", "name"]) == nil)
        #expect(parseSwitch(["-c"]) == nil)
        #expect(parseSwitch(["-c", "-f"]) == nil)
        #expect(parseSwitch(["name", "extra"]) == nil)
        #expect(parseSwitch([]) == nil)
    }

    @Test func restore_destinationsSourceAndSkip() {
        #expect(
            parseRestore(["file.swift"])
                == .restore(pathspecs: ["file.swift"], destination: .worktree, source: nil)
        )
        #expect(
            parseRestore(["--worktree", "-W", "a"])
                == .restore(pathspecs: ["a"], destination: .worktree, source: nil)
        )
        #expect(
            parseRestore(["--staged", "a"])
                == .restore(pathspecs: ["a"], destination: .index, source: nil)
        )
        #expect(
            parseRestore(["-S", "a"])
                == .restore(pathspecs: ["a"], destination: .index, source: nil)
        )
        #expect(
            parseRestore(["--staged", "--worktree", "a"])
                == .restore(pathspecs: ["a"], destination: .worktreeAndIndex, source: nil)
        )
        #expect(
            parseRestore(["-SWq", "a"])
                == .restore(pathspecs: ["a"], destination: .worktreeAndIndex, source: nil)
        )
        #expect(
            parseRestore(["--source", "HEAD", "a"])
                == .restore(pathspecs: ["a"], destination: .worktree, source: "HEAD")
        )
        #expect(
            parseRestore(["--source=HEAD~1", "--", "a", "b"])
                == .restore(pathspecs: ["a", "b"], destination: .worktree, source: "HEAD~1")
        )
        #expect(
            parseRestore(["--quiet", "--progress", "--no-progress", "--ours", "--theirs", "--merge", "a"])
                == .restore(pathspecs: ["a"], destination: .worktree, source: nil)
        )
        #expect(parseRestore(["-m", "a"]) == nil)
        #expect(
            parseRestore(["--ignore-unmerged", "--overlay", "--no-overlay", "a"])
                == .restore(pathspecs: ["a"], destination: .worktree, source: nil)
        )
        #expect(parseRestore([]) == .restore(pathspecs: [], destination: .worktree, source: nil))
    }

    @Test func restore_rejectsUnknownAndMissingSource() {
        #expect(parseRestore(["-z", "a"]) == nil)
        #expect(parseRestore(["--unknown", "a"]) == nil)
        #expect(parseRestore(["--source"]) == nil)
    }

    @Test func reset_modesPathspecsAndQuiet() {
        #expect(parseReset(["--hard"]) == .reset(mode: .hard, target: nil))
        #expect(parseReset(["--soft", "HEAD~1"]) == .reset(mode: .soft, target: "HEAD~1"))
        #expect(parseReset(["--mixed"]) == .reset(mode: .mixed, target: nil))
        #expect(parseReset(["--merge"]) == .reset(mode: .merge, target: nil))
        #expect(parseReset(["--keep"]) == .reset(mode: .keep, target: nil))
        #expect(parseReset(["-q", "--quiet", "-N", "--intent-to-add", "HEAD"]) == .reset(mode: .mixed, target: "HEAD"))
        #expect(
            parseReset(["--hard", "HEAD", "--", "file"])
                == .discardWorktree(pathspecs: ["file"], source: "HEAD")
        )
        #expect(parseReset(["--soft", "--", "file"]) == nil)
        #expect(parseReset(["--hard", "--soft"]) == nil)
        #expect(parseReset(["--soft", "--hard"]) == nil)
        #expect(parseReset(["--keep", "--mixed"]) == nil)
        #expect(parseReset(["--mixed", "--merge"]) == nil)
        #expect(parseReset(["--merge", "--keep"]) == nil)
        #expect(parseCheckout(["--branch", "a", "b", "c"]) == nil)
        #expect(parseCheckout(["--orphan", "a", "b", "c"]) == nil)
        #expect(parseReset(["--unknown"]) == nil)
        #expect(parseReset(["HEAD", "other"]) == nil)
        #expect(parseReset([]) == .reset(mode: .mixed, target: nil))
    }

    @Test func clean_forceDryRunDirectoriesAndExclude() {
        #expect(parseClean(["--force", "--dry-run", "-d"]) == .clean(force: true, dryRun: true, directories: true))
        #expect(parseClean(["-fd"]) == .clean(force: true, dryRun: false, directories: true))
        #expect(parseClean(["-n", "-q", "-x", "-X"]) == .clean(force: false, dryRun: true, directories: false))
        #expect(parseClean(["-e", "*.o", "--exclude", "build", "extra"]) == .clean(force: false, dryRun: false, directories: false))
        #expect(parseClean(["--quiet", "--", "path"]) == .clean(force: false, dryRun: false, directories: false))
        #expect(parseClean([]) == .clean(force: false, dryRun: false, directories: false))
    }

    @Test func argvDirect_matchesAdapter() {
        // T3b2: pin Argv-direct behavior so T4 adapter deletion cannot shift semantics.
        let checkoutArgs = ["-b", "feature"]
        #expect(parseCheckout(Argv(program: "git", args: checkoutArgs)) == parseCheckout(checkoutArgs))
        #expect(parseCheckout(Argv(program: "git", args: checkoutArgs)) == .createBranch(name: "feature", startPoint: nil, force: false))
        #expect(parseCheckout(Argv(program: "git", args: ["main"])) == nil)

        let switchArgs = ["-C", "rewrite"]
        #expect(parseSwitch(Argv(program: "git", args: switchArgs)) == parseSwitch(switchArgs))
        #expect(parseSwitch(Argv(program: "git", args: switchArgs)) == .createBranch(name: "rewrite", startPoint: nil, force: true))
        #expect(parseSwitch(Argv(program: "git", args: [])) == nil)

        let restoreArgs = ["--source", "HEAD", "a"]
        #expect(parseRestore(Argv(program: "git", args: restoreArgs)) == parseRestore(restoreArgs))
        #expect(parseRestore(Argv(program: "git", args: restoreArgs)) == .restore(pathspecs: ["a"], destination: .worktree, source: "HEAD"))
        #expect(parseRestore(Argv(program: "git", args: ["--source"])) == nil)

        let resetArgs = ["--hard", "HEAD", "--", "file"]
        #expect(parseReset(Argv(program: "git", args: resetArgs)) == parseReset(resetArgs))
        #expect(parseReset(Argv(program: "git", args: resetArgs)) == .discardWorktree(pathspecs: ["file"], source: "HEAD"))
        #expect(parseReset(Argv(program: "git", args: ["--hard", "--soft"])) == nil)

        let cleanArgs = ["-fd"]
        #expect(parseClean(Argv(program: "git", args: cleanArgs)) == parseClean(cleanArgs))
        #expect(parseClean(Argv(program: "git", args: cleanArgs)) == .clean(force: true, dryRun: false, directories: true))
        #expect(parseClean(Argv(program: "git", args: ["-e"])) == nil)
    }

    @Test func clean_rejectsInteractiveUnknownAndDanglingExclude() {
        #expect(parseClean(["-i"]) == nil)
        #expect(parseClean(["--interactive"]) == nil)
        #expect(parseClean(["-e"]) == nil)
        #expect(parseClean(["--exclude"]) == nil)
        #expect(parseClean(["-z"]) == nil)
        #expect(parseClean(["-qxX"]) == .clean(force: false, dryRun: false, directories: false))
        #expect(parseClean(["-fde"]) == nil)
        #expect(parseClean(["-fdie"]) == nil)
        #expect(parseClean(["--unknown"]) == nil)
        #expect(parseClean(["-e"]) == nil)
    }
}
