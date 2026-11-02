#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

enum LaunchAgentProbe {
    static func isLoaded(label: String, userID: uid_t = getuid()) -> Bool {
        let launchctl = ProcessLaunchctl()
        return LaunchdDomain.bootstrapOrder(uid: userID).contains { domain in
            launchctl.isLoaded(domain: domain, label: label)
        }
    }

    /// Which domains hold the job, and whether an Aqua `gui/` domain exists.
    static func observe(
        label: String,
        userID: uid_t,
        launchctl: any LaunchctlApplying
    ) -> LaunchdObservation {
        LaunchdObservation(
            guiDomainExists: launchctl.domainExists(LaunchdDomain.gui(userID)),
            loadedInGui: launchctl.isLoaded(domain: LaunchdDomain.gui(userID), label: label),
            loadedInUser: launchctl.isLoaded(domain: LaunchdDomain.user(userID), label: label)
        )
    }
}
