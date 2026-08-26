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
}
