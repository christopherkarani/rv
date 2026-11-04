import Testing
import RVDomain
@testable import RVEngine

/// `git checkout <tree-ish> <paths>` and `git checkout .` overwrite working
/// tree files exactly like the `--` forms, so they parse as a discard.
@Suite("git checkout path forms")
struct ParseGitCheckoutPathsTests {
    @Test func treeIshWithPathsWithoutDashDiscards() {
        #expect(parseCheckout(["HEAD~3", "src/x"]) == .discardWorktree(pathspecs: ["src/x"], source: "HEAD~3"))
        #expect(parseCheckout(["main", "a", "b"]) == .discardWorktree(pathspecs: ["a", "b"], source: "main"))
        #expect(parseCheckout(["-q", "HEAD", "f"]) == .discardWorktree(pathspecs: ["f"], source: "HEAD"))
    }

    @Test func dotPathspecDiscards() {
        #expect(parseCheckout(["."]) == .discardWorktree(pathspecs: ["."], source: nil))
        #expect(parseCheckout(["./src"]) == .discardWorktree(pathspecs: ["./src"], source: nil))
        #expect(parseCheckout(["../x"]) == .discardWorktree(pathspecs: ["../x"], source: nil))
    }

    @Test func branchSwitchAndCreateAreUnchanged() {
        #expect(parseCheckout(["main"]) == nil)
        #expect(parseCheckout(["feature/x"]) == nil)
        #expect(parseCheckout(["-t", "origin/main"]) == nil)
        #expect(parseCheckout(["-b", "feature"]) == .createBranch(name: "feature", startPoint: nil, force: false))
        #expect(parseCheckout(["-b", "feature", "main"]) == .createBranch(name: "feature", startPoint: "main", force: false))
        #expect(parseCheckout(["-f", "main"]) == .switchBranch(name: "main", force: true))
    }
}
