import Testing
@testable import RVDomain

@Suite("SemanticAnalysis wrappers")
struct SemanticAnalysisTests {
    @Test func wrapping_recordsLayersAndInnermost() {
        let inner = SemanticAnalysis.git(.reset(mode: .hard, target: nil))
        let analysis = inner.wrapping([.sudo, .env, .sh])
        #expect(analysis.wrappers == [.sudo, .env, .sh])
        #expect(analysis.innermost == inner)
        #expect(analysis.gitAction == .reset(mode: .hard, target: nil))
        #expect(analysis.filesystemAction == nil)
    }

    @Test func unwrapLimited_isDistinctFromUnknown() {
        #expect(SemanticAnalysis.unwrapLimited != .unknown)
        #expect(SemanticAnalysis.unwrapLimited.wrapping([.bash]).innermost == .unwrapLimited)
    }

    @Test func builtinUnwrapLimited_isStableRule() {
        #expect(ActionPolicyEngine.Builtin.unwrapLimited.ruleID.rawValue == "builtin.action:unwrap-limited")
    }

    @Test func wrapper_codableRoundTrip() throws {
        let analysis = SemanticAnalysis.filesystem(
            .delete(
                targets: [
                    FilesystemTarget(
                        apparent: "file",
                        canonical: "/tmp/file",
                        scope: .outsideRepository,
                        kind: .unknown
                    ),
                ],
                recursive: true,
                force: true
            )
        ).wrapping([.python])
        let data = try JSONEncoder().encode(analysis)
        #expect(try JSONDecoder().decode(SemanticAnalysis.self, from: data) == analysis)
    }
}
