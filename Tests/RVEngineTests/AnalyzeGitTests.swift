import Testing
import RVDomain
@testable import RVEngine

@Suite("AnalyzeGit")
struct AnalyzeGitTests {
    @Test func checkoutDashB_isBranchCreation() {
        let analysis = analyzeGit(ShellCommand(rawValue: "git checkout -b feature"))
        guard case .git(let action) = analysis else {
            Issue.record("expected git analysis")
            return
        }
        #expect(action == .createBranch(name: "feature", startPoint: nil, force: false))
        #expect(action.explainAction == "branch creation")
        #expect(action.effects.kinds == [.localBranchCreate])
        #expect(action.effectScope == .localRef)
        #expect(action.resources.branchName == "feature")
    }

    @Test func checkoutOursTheirsDoubleDash_isWorkingTreeDiscard() {
        for command in ["git checkout --ours -- file.swift", "git checkout --theirs -- file.swift"] {
            let analysis = analyzeGit(ShellCommand(rawValue: command))
            guard case .git(.discardWorktree(let pathspecs, let source)) = analysis else {
                Issue.record("expected discard for \(command), got \(analysis)")
                return
            }
            #expect(pathspecs == ["file.swift"], Comment(rawValue: command))
            #expect(source == nil, Comment(rawValue: command))
        }
    }

    @Test func checkoutDoubleDash_isWorkingTreeDiscard() {
        let analysis = analyzeGit(ShellCommand(rawValue: "git checkout -- file.swift"))
        guard case .git(.discardWorktree(let pathspecs, let source)) = analysis else {
            Issue.record("expected discard, got \(analysis)")
            return
        }
        #expect(pathspecs == ["file.swift"])
        #expect(source == nil)
        guard case .git(let action) = analysis else { return }
        #expect(action.explainAction == "working-tree overwrite/discard")
        #expect(action.effects.kinds == [.workingTreeDiscard])
        #expect(action.effectScope == .localWorkingTree)
    }

    @Test func pushNormal_differsFromForcePush() {
        let normal = analyzeGit(ShellCommand(rawValue: "git push origin feature"))
        let forced = analyzeGit(ShellCommand(rawValue: "git push --force origin main"))
        #expect(normal != forced)
        guard case .git(let normalAction) = normal else {
            Issue.record("expected git analysis for normal push")
            return
        }
        guard case .git(let forcedAction) = forced else {
            Issue.record("expected git analysis for force push")
            return
        }
        #expect(
            normalAction == .push(
                remote: "origin",
                refspec: "feature",
                force: .none,
                delete: false
            )
        )
        #expect(
            forcedAction == .push(
                remote: "origin",
                refspec: "main",
                force: .force,
                delete: false
            )
        )
        #expect(normalAction.effects.kinds.isEmpty)
        #expect(forcedAction.effects.kinds == [.remoteSharedBranchMutation])
        #expect(normalAction.explainAction == "push")
        #expect(forcedAction.explainAction == "force-push")
        #expect(forcedAction.effectScope == .remote)
        #expect(normalAction.effectScope == .remote)
    }

    @Test func unknownSyntax_isUnknown() {
        #expect(analyzeGit(ShellCommand(rawValue: "echo hello")) == .unknown)
        #expect(analyzeGit(ShellCommand(rawValue: "git --weird-flag checkout -b feature")) == .unknown)
        #expect(analyzeGit(ShellCommand(rawValue: "git checkout feature")) == .unknown)
        #expect(analyzeGit(ShellCommand(rawValue: "git checkout -b $FEATURE")) == .unknown)
        #expect(analyzeGit(ShellCommand(rawValue: "git status")) == .unknown)
    }

    @Test func globalsAndSwitchCreate_stillParse() {
        let analysis = analyzeGit(
            ShellCommand(rawValue: "git --no-pager -c advice.detachedHead=false checkout -b feature")
        )
        #expect(analysis == .git(.createBranch(name: "feature", startPoint: nil, force: false)))
        #expect(
            analyzeGit(ShellCommand(rawValue: "git switch -c topic"))
                == .git(.createBranch(name: "topic", startPoint: nil, force: false))
        )
    }

    @Test func highValueOperations_parse() {
        #expect(
            analyzeGit(ShellCommand(rawValue: "git reset --hard"))
                == .git(.reset(mode: .hard, target: nil))
        )
        #expect(
            analyzeGit(ShellCommand(rawValue: "git restore file.swift"))
                == .git(
                    .restore(
                        pathspecs: ["file.swift"],
                        staged: false,
                        worktree: true,
                        source: nil
                    )
                )
        )
        #expect(
            analyzeGit(ShellCommand(rawValue: "git clean -fd"))
                == .git(.clean(force: true, dryRun: false, directories: true))
        )
        #expect(
            analyzeGit(ShellCommand(rawValue: "git branch -D stale"))
                == .git(.deleteBranch(name: "stale", force: true, remote: false))
        )
        #expect(
            analyzeGit(ShellCommand(rawValue: "git tag -d v1"))
                == .git(.deleteTag(name: "v1", remote: nil))
        )
        #expect(
            analyzeGit(ShellCommand(rawValue: "git stash drop"))
                == .git(.stash(verb: .drop))
        )
        #expect(
            analyzeGit(ShellCommand(rawValue: "git rebase --abort"))
                == .git(.rebase(verb: .abort, onto: nil))
        )
        #expect(
            analyzeGit(ShellCommand(rawValue: "git push --force-with-lease origin main"))
                == .git(
                    .push(
                        remote: "origin",
                        refspec: "main",
                        force: .forceWithLease,
                        delete: false
                    )
                )
        )
        #expect(
            analyzeGit(ShellCommand(rawValue: "git push -f origin main"))
                == .git(
                    .push(remote: "origin", refspec: "main", force: .force, delete: false)
                )
        )
    }

    @Test func pushWithoutRefspec_usesCurrentBranch() {
        let context = GitAnalysisContext(currentBranch: "topic")
        let analysis = analyzeGit(ShellCommand(rawValue: "git push origin"), context: context)
        #expect(
            analysis
                == .git(
                    .push(remote: "origin", refspec: "topic", force: .none, delete: false)
                )
        )
    }

    @Test func multiSegmentAndWrappers_areUnknown() {
        #expect(
            analyzeGit(ShellCommand(rawValue: "git checkout -b feature && rm -rf /")) == .unknown
        )
        #expect(
            analyzeGit(ShellCommand(rawValue: "bash -c 'git reset --hard'")) == .unknown
        )
    }
}
