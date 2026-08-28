import Foundation
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

    @Test func builtinRepositoryBoundary_isStableRule() {
        #expect(
            ActionPolicyEngine.Builtin.inRepository.rawValue == "builtin.action:in-repo-write"
        )
        #expect(
            ActionPolicyEngine.Builtin.outsideRepository.ruleID.rawValue
                == "builtin.action:out-of-repo-write"
        )
        #expect(
            ActionPolicyEngine.Builtin.unresolvedFilesystem.ruleID.rawValue
                == "builtin.action:unresolved-path"
        )
        #expect(
            ActionPolicyEngine.Builtin.outsideRepositoryRead.rawValue
                == "builtin.action:out-of-repo-read"
        )
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
