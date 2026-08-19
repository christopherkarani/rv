import Foundation
@testable import RVCLI

final class RecordingLaunchctl: LaunchctlApplying {
    private(set) var bootstraps: [URL] = []
    private(set) var bootouts: [String] = []

    func bootstrap(domain _: String, plist: URL) throws {
        bootstraps.append(plist)
    }

    func bootout(domain _: String, label: String) throws {
        bootouts.append(label)
    }
}
