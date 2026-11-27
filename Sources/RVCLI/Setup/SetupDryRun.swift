import Foundation
import RVDomain

/// `rv setup --dry-run`: what setup would write, from the same read-only
/// inspection setup itself plans from. Writes nothing and starts nothing.
enum SetupDryRun {
    static func text(
        snapshot: HostAdapterInstallationSnapshot, paths: OwnedPaths, force: Bool, observe: Bool
    ) -> String {
        let home = paths.home.rawValue
        func shown(_ path: String) -> String {
            path.hasPrefix(home + "/") ? "~" + String(path.dropFirst(home.count)) : path
        }
        let width = HookHost.setupSlotOrder.map(\.rawValue.count).max() ?? 0
        var lines = ["rv setup --dry-run: nothing was written.", "", "Hosts"]
        for host in HookHost.setupSlotOrder {
            let installation = snapshot.installation(for: host)
            let destination = shown(paths.hostAdapter(for: host).destination)
            let action: String
            switch installation.setupPlan(force: force) {
            case .skipUndetected:
                action = "skip     not installed on this machine"
            case .skipOccupied:
                action = "skip     \(destination) holds another hook; --force backs it up to *.bak and replaces it"
            case .forceClearThenWrite:
                action = "replace  \(destination) (backed up to *.bak first)"
            case .write(let existing) where existing == nil:
                action = "write    \(destination)"
            case .write:
                action = installation.state == .wired
                    ? "refresh  \(destination) (already wired)"
                    : "repair   \(destination)"
            }
            lines.append("  " + host.rawValue.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + action)
        }
        lines += ["", "Service", "  write    \(shown(paths.evaluateServiceFile)) and start rvd"]
        if observe {
            lines += ["", "Mode", "  set      \(CommandVocabulary.PlannedWord.watching) (guard.mode observe)"]
        }
        lines += ["", "Run the same command without --dry-run to apply."]
        return lines.joined(separator: "\n") + "\n"
    }
}
