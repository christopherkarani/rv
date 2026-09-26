import Testing
import RVDomain
@testable import RVEngine

@Suite("Parse git refs")
struct ParseGitRefsTests {
    @Test func push_forceLeaseDeleteRepoAndSkip() {
        let topic = GitAnalysisContext(currentBranch: "topic")
        #expect(
            parsePush(["--force", "origin", "main"], context: .empty)
                == .push(remote: "origin", refspec: "main", force: .force)
        )
        #expect(
            parsePush(["--force-with-lease", "origin", "main"], context: .empty)
                == .push(remote: "origin", refspec: "main", force: .forceWithLease)
        )
        #expect(
            parsePush(["--force-with-lease=refs/heads/main", "--force-if-includes", "origin", "main"], context: .empty)
                == .push(remote: "origin", refspec: "main", force: .forceWithLease)
        )
        #expect(
            parsePush(["--force", "--force-with-lease", "origin", "main"], context: .empty)
                == .push(remote: "origin", refspec: "main", force: .force)
        )
        #expect(
            parsePush(["-fuqvn", "origin", "main"], context: .empty)
                == .push(remote: "origin", refspec: "main", force: .force)
        )
        #expect(
            parsePush(["-ud", "origin", "topic"], context: .empty)
                == .deleteRemoteRef(remote: "origin", refspec: "topic")
        )
        #expect(
            parsePush(["--delete", "origin", "topic"], context: .empty)
                == .deleteRemoteRef(remote: "origin", refspec: "topic")
        )
        #expect(
            parsePush(["-d", "origin", "topic"], context: .empty)
                == .deleteRemoteRef(remote: "origin", refspec: "topic")
        )
        #expect(
            parsePush(["origin", ":topic"], context: .empty)
                == .deleteRemoteRef(remote: "origin", refspec: "topic")
        )
        #expect(
            parsePush(["origin", ":"], context: .empty)
                == .deleteRemoteRef(remote: "origin", refspec: ":")
        )
        #expect(
            parsePush(["origin"], context: topic)
                == .push(remote: "origin", refspec: "topic", force: .none)
        )
        #expect(
            parsePush(["--repo", "origin", "--set-upstream", "--all", "--mirror", "--tags"], context: topic)
                == .push(remote: nil, refspec: "topic", force: .none)
        )
        #expect(
            parsePush(["--repo=origin", "--follow-tags", "--dry-run", "--prune", "--no-verify", "--verify"], context: .empty)
                == .push(remote: nil, refspec: nil, force: .none)
        )
        #expect(
            parsePush(["--atomic", "--no-atomic", "--progress", "--no-progress", "--ipv4", "--ipv6"], context: .empty)
                == .push(remote: nil, refspec: nil, force: .none)
        )
        #expect(parsePush(["-4", "origin"], context: .empty) == nil)
        #expect(parsePush(["-6", "origin"], context: .empty) == nil)
        #expect(parsePush([], context: .empty) == .push(remote: nil, refspec: nil, force: .none))
    }

    @Test func push_rejectsUnknownMissingRepoAndExtraPositionals() {
        #expect(parsePush(["-z", "origin"], context: .empty) == nil)
        #expect(parsePush(["--unknown"], context: .empty) == nil)
        #expect(parsePush(["--repo"], context: .empty) == nil)
        #expect(parsePush(["origin", "a", "b"], context: .empty) == nil)
    }

    @Test func branch_deleteForceAndSkip() {
        #expect(parseBranch(["--delete", "stale"]) == .deleteBranch(name: "stale", force: false))
        #expect(parseBranch(["-d", "stale"]) == .deleteBranch(name: "stale", force: false))
        #expect(parseBranch(["-D", "stale"]) == .deleteBranch(name: "stale", force: true))
        #expect(parseBranch(["--force", "-d", "stale"]) == .deleteBranch(name: "stale", force: true))
        #expect(parseBranch(["-f", "-d", "stale"]) == .deleteBranch(name: "stale", force: true))
        #expect(parseBranch(["-dqvat", "stale"]) == .deleteBranch(name: "stale", force: false))
        #expect(parseBranch(["-qfd", "stale"]) == .deleteBranch(name: "stale", force: true))
        #expect(parseBranch(["-qD", "force-cluster"]) == .deleteBranch(name: "force-cluster", force: true))
        #expect(parseBranch(["--quiet", "--verbose", "--all", "--remotes", "--list", "--track", "--no-track", "-d", "x"]) == .deleteBranch(name: "x", force: false))
        #expect(parseBranch(["-l", "-d", "x"]) == nil)
    }

    @Test func branch_rejectsCreateUnknownAndNameCount() {
        #expect(parseBranch(["name"]) == nil)
        #expect(parseBranch(["-d"]) == nil)
        #expect(parseBranch(["-d", "a", "b"]) == nil)
        #expect(parseBranch(["-z", "name"]) == nil)
        #expect(parseBranch(["--unknown", "-d", "name"]) == nil)
        #expect(parseBranch([]) == nil)
    }

    @Test func tag_deleteOnly() {
        #expect(parseTag(["--delete", "v1"]) == .deleteTag(name: "v1", remote: nil))
        #expect(parseTag(["-d", "v1"]) == .deleteTag(name: "v1", remote: nil))
        #expect(parseTag(["-dd", "v1"]) == .deleteTag(name: "v1", remote: nil))
        #expect(parseTag(["-dx", "v1"]) == nil)
        #expect(parseTag(["v1"]) == nil)
        #expect(parseTag(["-d"]) == nil)
        #expect(parseTag(["-d", "a", "b"]) == nil)
        #expect(parseTag(["-l", "v1"]) == nil)
        #expect(parseTag(["-n", "v1"]) == nil)
        #expect(parseTag(["-z", "v1"]) == nil)
        #expect(parseTag(["--unknown"]) == nil)
        #expect(parseTag([]) == nil)
    }

    @Test func stash_verbsFlagsAndMessage() {
        #expect(parseStash([]) == .stash(verb: .push))
        #expect(parseStash(["push"]) == .stash(verb: .push))
        #expect(parseStash(["pop"]) == .stash(verb: .pop))
        #expect(parseStash(["apply"]) == .stash(verb: .apply))
        #expect(parseStash(["drop", "stash@{0}"]) == .stash(verb: .drop))
        #expect(parseStash(["clear"]) == .stash(verb: .clear))
        #expect(parseStash(["list"]) == .stash(verb: .list))
        #expect(parseStash(["show"]) == .stash(verb: .show))
        #expect(parseStash(["-m", "wip", "push"]) == .stash(verb: .push))
        #expect(parseStash(["--message", "wip"]) == .stash(verb: .push))
        #expect(parseStash(["--message=wip", "-u", "--include-untracked", "-a", "--all"]) == .stash(verb: .push))
        #expect(parseStash(["-k", "--keep-index", "-q", "--quiet", "--index", "push"]) == .stash(verb: .push))
    }

    @Test func stash_rejectsUnknownFlagVerbAndDanglingMessage() {
        #expect(parseStash(["-m"]) == nil)
        #expect(parseStash(["--message"]) == nil)
        #expect(parseStash(["-z"]) == nil)
        #expect(parseStash(["bogus"]) == nil)
    }

    @Test func rebase_verbsOntoAndSkip() {
        #expect(parseRebase(["--abort"]) == .rebase(verb: .abort, onto: nil))
        #expect(parseRebase(["--continue"]) == .rebase(verb: .continueRebase, onto: nil))
        #expect(parseRebase(["--skip"]) == .rebase(verb: .skip, onto: nil))
        #expect(parseRebase(["--onto", "main"]) == .rebase(verb: .start, onto: "main"))
        #expect(parseRebase(["main"]) == .rebase(verb: .start, onto: "main"))
        #expect(parseRebase(["--onto", "main", "topic"]) == .rebase(verb: .start, onto: "main"))
        #expect(
            parseRebase(["-q", "--quiet", "--autostash", "--no-autostash", "--keep-empty", "main"])
                == .rebase(verb: .start, onto: "main")
        )
        #expect(
            parseRebase(["--rebase-merges", "--no-keep-empty", "--apply", "--merge", "main"])
                == .rebase(verb: .start, onto: "main")
        )
        #expect(parseRebase([]) == .rebase(verb: .start, onto: nil))
    }

    @Test func rebase_rejectsInteractiveUnknownAndDanglingOnto() {
        #expect(parseRebase(["-i"]) == nil)
        #expect(parseRebase(["--interactive"]) == nil)
        #expect(parseRebase(["--edit-todo"]) == nil)
        #expect(parseRebase(["--onto"]) == nil)
        #expect(parseRebase(["--unknown"]) == nil)
    }

    @Test func argvDirect_matchesAdapter() {
        // T3b2: pin Argv-direct behavior so T4 adapter deletion cannot shift semantics.
        let pushArgs = ["--force", "origin", "main"]
        #expect(parsePush(Argv(program: "git", args: pushArgs), context: .empty) == parsePush(pushArgs, context: .empty))
        #expect(parsePush(Argv(program: "git", args: pushArgs), context: .empty) == .push(remote: "origin", refspec: "main", force: .force))
        let pushBad = ["origin", "a", "b"]
        #expect(parsePush(Argv(program: "git", args: pushBad), context: .empty) == nil)
        #expect(parsePush(Argv(program: "git", args: pushBad), context: .empty) == parsePush(pushBad, context: .empty))

        let branchArgs = ["-D", "stale"]
        #expect(parseBranch(Argv(program: "git", args: branchArgs)) == parseBranch(branchArgs))
        #expect(parseBranch(Argv(program: "git", args: branchArgs)) == .deleteBranch(name: "stale", force: true))
        #expect(parseBranch(Argv(program: "git", args: ["name"])) == nil)

        let tagArgs = ["-d", "v1"]
        #expect(parseTag(Argv(program: "git", args: tagArgs)) == parseTag(tagArgs))
        #expect(parseTag(Argv(program: "git", args: tagArgs)) == .deleteTag(name: "v1", remote: nil))
        #expect(parseTag(Argv(program: "git", args: ["v1"])) == nil)

        let stashArgs = ["-m", "wip", "push"]
        #expect(parseStash(Argv(program: "git", args: stashArgs)) == parseStash(stashArgs))
        #expect(parseStash(Argv(program: "git", args: stashArgs)) == .stash(verb: .push))
        #expect(parseStash(Argv(program: "git", args: ["bogus"])) == nil)

        let rebaseArgs = ["--onto", "main"]
        #expect(parseRebase(Argv(program: "git", args: rebaseArgs)) == parseRebase(rebaseArgs))
        #expect(parseRebase(Argv(program: "git", args: rebaseArgs)) == .rebase(verb: .start, onto: "main"))
        #expect(parseRebase(Argv(program: "git", args: ["--onto"])) == nil)
    }

    @Test func flagTokens_clusteredShortsAndGitAttachedValue() {
        #expect(clusteredShorts("-abc") == ["a", "b", "c"])
        #expect(clusteredShorts("--abc") == nil)
        #expect(clusteredShorts("-") == nil)
        #expect(clusteredShorts("-a=b") == nil)
        #expect(clusteredShorts("abc") == nil)
        #expect(gitAttachedValue("--source=HEAD", long: "--source") == "HEAD")
        #expect(gitAttachedValue("--source=", long: "--source") == nil)
        #expect(gitAttachedValue("--source", long: "--source") == nil)
        #expect(gitAttachedValue("--other=x", long: "--source") == nil)
    }
}
