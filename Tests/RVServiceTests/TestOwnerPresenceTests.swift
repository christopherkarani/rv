import Foundation
import RVIPC
import Testing
@testable import RVService

/// docs/security/test-owner-presence.md. The first test runs in every build;
/// the rest only in a debug build made with RV_TEST_OWNER_PRESENCE=1.
struct TestOwnerPresenceTests {
    /// The variable alone changes nothing: a build without the feature
    /// checks the login password whatever rvd's environment says.
    @Test func theVariableAloneLeavesTheLoginPasswordCheckInANormalBuild() {
        let checker = OwnerPresence.liveChecker(environment: ["RV_TEST_OWNER_PASSWORD": "hunter2"])
        #if RV_TEST_OWNER_PRESENCE && !canImport(LocalAuthentication)
        #expect(checker is TestOwnerPasswordChecker)
        #else
        #expect(checker is UnixChkpwdChecker)
        #endif
    }

    @Test func noVariableOrAnEmptyOneIsTheLoginPasswordCheckInEveryBuild() {
        #expect(OwnerPresence.liveChecker(environment: [:]) is UnixChkpwdChecker)
        #expect(OwnerPresence.liveChecker(environment: ["RV_TEST_OWNER_PASSWORD": ""]) is UnixChkpwdChecker)
    }

    #if RV_TEST_OWNER_PRESENCE
    @Test func theTestCheckerAcceptsOnlyTheHarnessPassword() async {
        let checker = TestOwnerPasswordChecker(expected: "correct horse")
        #expect(await checker.check("correct horse") == true)
        #expect(await checker.check("correct hors") == false)
        #expect(await checker.check("correct horse ") == false)
        #expect(await checker.check("Correct horse") == false)
        #expect(await checker.check("") == false)
        #expect(await checker.check("correct\0horse") == false)
        #expect(await checker.check(String(repeating: "a", count: 512)) == false)
    }

    /// Only the leaf check changes: rvd's lockout and caller checks hold.
    @Test func ownerPresenceKeepsItsLockoutAndCallerChecksWithTheTestChecker() async {
        let presence = OwnerPresence(checker: TestOwnerPasswordChecker(expected: "pw"), authenticator: nil)
        let id = UUID()
        let peer = AuthenticatedRequestContext.captured(
            peer: .socketPeer(processID: 4242, effectiveUserID: 501, connectionID: id), connectionID: id)
        let anonymous = AuthenticatedRequestContext.unauthenticated
        #expect(await presence.confirm("x", proof: OwnerProof(password: "pw"), context: anonymous)
            == .denied(ConfirmOwnerActionReply(outcome: .proofRequired)))
        #expect(await presence.confirm("x", proof: nil, context: peer)
            == .denied(ConfirmOwnerActionReply(outcome: .proofRequired)))
        #expect(await presence.confirm("x", proof: OwnerProof(password: "pw"), context: peer) == .approved)
        for _ in 1..<OwnerPresence.maxFailures {
            #expect(await presence.confirm("x", proof: OwnerProof(password: "no"), context: peer)
                == .denied(ConfirmOwnerActionReply(outcome: .wrongPassword)))
        }
        guard case .denied(let reply) = await presence.confirm("x", proof: OwnerProof(password: "no"), context: peer)
        else { Issue.record("the fifth wrong password was approved"); return }
        #expect(reply.outcome == .lockedOut)
        guard case .denied(let locked) = await presence.confirm("x", proof: OwnerProof(password: "pw"), context: peer)
        else { Issue.record("the right password passed during a lockout"); return }
        #expect(locked.outcome == .lockedOut)
    }
    #endif
}
