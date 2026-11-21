import RVIsolation
import Testing
@testable import RVJudgePool

@Suite("Judge pool peer trust")
struct JudgePoolTrustTests {
    @Test("manifest: only the exact role passes, both directions")
    func manifestRoles() {
        // Supervisor accepts rvd (service); rvd accepts the supervisor (judge).
        #expect(JudgePoolPeerDecision.allows(
            source: .manifest, peerRole: .service, requiredRole: .service, sameUser: false, matchesSibling: false))
        #expect(JudgePoolPeerDecision.allows(
            source: .manifest, peerRole: .judge, requiredRole: .judge, sameUser: false, matchesSibling: false))
        for role in TrustedRVComponentRole.allCases where role != .judge {
            #expect(!JudgePoolPeerDecision.allows(
                source: .manifest, peerRole: role, requiredRole: .judge, sameUser: true, matchesSibling: true))
        }
        for role in TrustedRVComponentRole.allCases where role != .service {
            #expect(!JudgePoolPeerDecision.allows(
                source: .manifest, peerRole: role, requiredRole: .service, sameUser: true, matchesSibling: true))
        }
    }

    @Test("a manifest without a judge entry verifies no supervisor, even the sibling bytes")
    func manifestWithoutJudgeRoleFailsClosed() {
        // The peer matches no manifest entry (nil role); a sibling match and
        // same uid must not stand in for the missing role.
        #expect(!JudgePoolPeerDecision.allows(
            source: .manifest, peerRole: nil, requiredRole: .judge, sameUser: true, matchesSibling: true))
    }

    @Test("sibling pin needs the same user AND the sibling's exact code")
    func siblingPin() {
        #expect(JudgePoolPeerDecision.allows(
            source: .siblingPin, peerRole: nil, requiredRole: .judge, sameUser: true, matchesSibling: true))
        #expect(!JudgePoolPeerDecision.allows(
            source: .siblingPin, peerRole: nil, requiredRole: .judge, sameUser: false, matchesSibling: true))
        #expect(!JudgePoolPeerDecision.allows(
            source: .siblingPin, peerRole: nil, requiredRole: .judge, sameUser: true, matchesSibling: false))
        // A role claim means nothing without a manifest.
        #expect(!JudgePoolPeerDecision.allows(
            source: .siblingPin, peerRole: .judge, requiredRole: .judge, sameUser: false, matchesSibling: false))
    }

    @Test("an invalid manifest rejects everything")
    func invalidManifest() {
        #expect(!JudgePoolPeerDecision.allows(
            source: .invalid, peerRole: .judge, requiredRole: .judge, sameUser: true, matchesSibling: true))
        #expect(!JudgePoolPeerDecision.allows(
            source: .invalid, peerRole: .service, requiredRole: .service, sameUser: true, matchesSibling: true))
    }
}
