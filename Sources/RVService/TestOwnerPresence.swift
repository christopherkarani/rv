#if RV_TEST_OWNER_PRESENCE
import Foundation

// Everything in this file exists only in a debug build made with
// RV_TEST_OWNER_PRESENCE=1 in the build's environment (Package.swift). A
// release build never contains it, and Scripts/check-no-test-owner-presence.sh
// fails a release whose binaries carry `marker` or `environmentKey`.
// docs/security/test-owner-presence.md has the design and its limits.

/// Owner presence for automated tests on Linux: the "login password" is
/// one the test harness chose and put in rvd's environment, so owner
/// actions, allow-once redeem and mint run end to end with nobody present.
/// Only the leaf check changes. rvd still decides, with the same one-at-a-
/// time slot, lockout, audit and caller checks as with `unix_chkpwd`.
package enum TestOwnerPresence {
    /// Printed by rvd and in its version line, and searched for in release
    /// binaries. Keep it unique.
    package static let marker = "rv-test-owner-presence"
    /// rvd: the password the owner check accepts. The CLI: the password it
    /// sends as if typed. Unset or empty: the build behaves as production.
    package static let environmentKey = "RV_TEST_OWNER_PASSWORD"

    /// The password from `environment`, or nil when unset or empty.
    package static func password(in environment: [String: String]) -> String? {
        guard let value = environment[environmentKey], value.isEmpty == false else { return nil }
        return value
    }

    /// What rvd prints when it uses the test check.
    static let notice =
        "rvd: TEST BUILD (\(marker)): the owner check accepts the password in \(environmentKey), "
        + "not your login password; never install this build\n"
}

/// Accepts exactly the password the harness chose. Same answers as
/// `UnixChkpwdChecker`: true on a match, false otherwise (a strike toward
/// the lockout), never nil, since this check is always available.
package struct TestOwnerPasswordChecker: OwnerPasswordChecking {
    private let expected: [UInt8]

    package init(expected: String) {
        self.expected = Array(expected.utf8)
    }

    package func check(_ password: String) async -> Bool? {
        let given = Array(password.utf8)
        // Same refusals as the real helper: empty, too long, a NUL.
        guard given.isEmpty == false, given.count <= UnixChkpwdChecker.maxPasswordBytes,
              given.contains(0) == false
        else { return false }
        // Compare every byte, whatever the first difference.
        var difference = UInt8(given.count == expected.count ? 0 : 1)
        for index in 0..<max(given.count, expected.count) {
            let left = index < given.count ? given[index] : 0
            let right = index < expected.count ? expected[index] : 0
            difference |= left ^ right
        }
        return difference == 0
    }
}
#endif
