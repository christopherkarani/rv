import Foundation
import Testing
@testable import RVCLI

@Suite struct OwnerAccountPasswordTests {
    @Test(arguments: [
        // Debian/Ubuntu shadow `passwd -S` for one's own account.
        ("alice P 2026-11-11 0 99999 7 -1", OwnerAccountPassword.Status.usable),
        ("alice L 2026-10-24 0 99999 7 -1", .locked),
        ("alice NP 2026-10-24 0 99999 7 -1", .locked),
        // Fedora/RHEL (libuser) spellings, when run as root.
        ("alice PS 2024-01-01 0 99999 7 -1 (Password set, SHA512 crypt.)", .usable),
        ("alice LK 2024-01-01 0 99999 7 -1 (Password locked.)", .locked),
        // Anything else is unknown: the normal prompt runs.
        ("passwd: You may not view or modify password information for alice.", .unknown),
        ("Only root can do that.", .unknown),
        ("", .unknown),
        ("alice X 2026-10-24", .unknown),
    ])
    func parsesPasswdStatus(_ output: String, _ expected: OwnerAccountPassword.Status) {
        #expect(OwnerAccountPassword.status(passwdStatusOutput: output, user: "alice") == expected)
    }

    @Test func anotherUsersLineIsNotThisAccount() {
        #expect(OwnerAccountPassword.status(passwdStatusOutput: "root L 2026-10-24 0 99999 7 -1", user: "alice") == .unknown)
    }

    @Test func onlyADefiniteLockRefusesUpFront() {
        #expect(OwnerAccountPassword.refusalIfLocked(user: "alice", status: { _ in .usable }) == nil)
        #expect(OwnerAccountPassword.refusalIfLocked(user: "alice", status: { _ in .unknown }) == nil)
        #expect(OwnerAccountPassword.refusalIfLocked(user: nil, status: { _ in .locked }) == nil)
        let refusal = OwnerAccountPassword.refusalIfLocked(user: "alice", status: { _ in .locked })
        #expect(refusal?.contains("this account (alice) has no password") == true)
        #expect(refusal?.contains("`sudo passwd alice`") == true)
        let root = OwnerAccountPassword.lockedRefusal(user: "root")
        #expect(root.contains("set one with `passwd`"))
    }

    @Test func liveNeverGuessesForAnUnknownOrOptionLikeUser() {
        #expect(OwnerAccountPassword.live(user: "rv-no-such-user-\(UUID().uuidString.prefix(8).lowercased())") == .unknown)
        #expect(OwnerAccountPassword.live(user: "-a") == .unknown)
        #expect(OwnerAccountPassword.live(user: "") == .unknown)
        #expect(OwnerAccountPassword.live(user: nil) == .unknown)
    }
}
