import Foundation
import RVDomain
import RVEngine
import RVPacks
import Testing

/// Comments on inert commands and the `/dev/null` discard sink, on both the
/// pack pin and the semantic door. Each relaxation keeps its near misses.
struct CommentAndDiscardSinkCorpusTests {
    @Test(arguments: [
        "ls # rm -rf /",
        "true # git reset --hard",
        "echo done # git push --force origin main",
        "ls -la # never rm -rf /",
        "pwd # git clean -fdx",
    ])
    func inertCommentIsNotEvaluated(command: String) throws {
        let harness = try StressHarness.dayOne()
        #expect(harness.pin(command).decision == .allow, "pin \(describeDecision(harness.pin(command)))")
        #expect(harness.door(command).decision == .allow, "door \(describeDecision(harness.door(command)))")
    }

    /// Each still denies: the comment ends at the newline, the comment is on
    /// a command a literal `#` would hand the words to, the comment carries
    /// shell syntax, or the text uses a construct the scan does not model.
    @Test(arguments: [
        "ls # x\nrm -rf /",
        "ls # x\ngit reset --hard",
        "rm -rf # /",
        "rm -rf / # ls",
        "git reset # --hard",
        "git push # --force",
        "find / # -delete",
        "sudo ls # rm -rf /",
        "ls # ; rm -rf /",
        "ls # x; rm -rf /",
        "ls # it's\nrm -rf /",
        "ls # $(rm -rf /)",
        "echo $(ls # x\n) ; rm -rf /",
        "# git reset --hard",
        "ls\n# git reset --hard",
        "ls \\\n# x\nrm -rf /",
        "echo hi # <<EOF\nrm -rf ~\nEOF",
        "ls a#b ; rm -rf /",
        "ls \\#x ; rm -rf /",
    ])
    func commentNearMissesStillDeny(command: String) throws {
        // The product door; the pack-only pin never read `git reset # --hard`
        // as a reset, comment or not.
        let harness = try StressHarness.dayOne()
        #expect(harness.door(command).decision != .allow, "door \(command)")
    }
}
