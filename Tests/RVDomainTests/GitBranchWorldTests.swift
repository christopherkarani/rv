import Foundation
import Testing
import RVDomain

@Suite("GitBranchWorld")
struct GitBranchWorldTests {
    @Test func workingDirectoryOnly_isUnprobedNotSharednessFalse() {
        let cwd = WorkingDirectory(validating: "/tmp/rv")
        let context = GitAnalysisContext(workingDirectory: cwd)
        #expect(context.branchWorld == .unprobed)
        #expect(context.currentBranch == nil)
        #expect(context.reviewContext.repository.sharedness == .unknown)
        #expect(context.reviewContext.repository.currentBranch == nil)
    }

    @Test func empty_isUnprobedUnknownSharedness() {
        #expect(GitAnalysisContext.empty.workingDirectory == nil)
        #expect(GitAnalysisContext.empty.branchWorld == .unprobed)
        #expect(GitAnalysisContext.empty.reviewContext.repository.sharedness == .unknown)
    }

    @Test func probedShared_mapsToSharedReviewContext() {
        let context = GitAnalysisContext(
            branchWorld: .probed(currentBranch: "main", isShared: true)
        )
        #expect(context.currentBranch == "main")
        #expect(context.reviewContext.repository.sharedness == .shared)
        #expect(context.reviewContext.repository.currentBranch == "main")
    }

    @Test func probedNotShared_mapsToNotSharedReviewContext() {
        let context = GitAnalysisContext(
            branchWorld: .probed(currentBranch: "topic", isShared: false)
        )
        #expect(context.currentBranch == "topic")
        #expect(context.reviewContext.repository.sharedness == .notShared)
    }

    @Test func missingSharednessKey_decodesUnknownNeverNotShared() throws {
        let data = Data(#"{"name":"rv","currentBranch":"main"}"#.utf8)
        let decoded = try JSONDecoder().decode(RepositoryReviewContext.self, from: data)
        #expect(decoded.sharedness == .unknown)
        #expect(decoded.name == "rv")
        #expect(decoded.currentBranch == "main")
    }

    @Test func sharednessRoundTrip_preservesCases() throws {
        for sharedness: GitSharedness in [.unknown, .notShared, .shared] {
            let original = RepositoryReviewContext(
                name: "rv",
                currentBranch: "topic",
                sharedness: sharedness
            )
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(RepositoryReviewContext.self, from: data)
            #expect(decoded == original)
        }
    }
}
