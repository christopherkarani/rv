import Foundation
import RVHistory
import Synchronization

/// rvd's side of the first save (C5): when a decision row is the first
/// real stop, claim `first-save.json` and say so once. Runs on the
/// recorder's detached task, never on the hook reply's path.
package enum FirstSaveNotice {
    /// Claims the first save for `record` when it qualifies and none exists
    /// yet; posts the one notification when this call made the claim.
    @discardableResult
    package static func consider(
        _ record: DecisionRecord, configDirectory: URL,
        post: (String) -> Void = FirstSaveNotice.postSystemNotification
    ) -> Bool {
        guard let save = FirstSaveRecord(record) else { return false }
        let store = FirstSaveStore(configDirectory: configDirectory)
        // Cheap check first: after the first save every stop ends here.
        guard FileManager.default.fileExists(atPath: store.fileURL.path) == false else { return false }
        guard store.claim(save) else { return false }
        post(save.notificationText)
        return true
    }

    /// macOS: a Notification Center banner through `osascript`, the text
    /// passed as an argument (never spliced into the script). Elsewhere a
    /// no-op: `rv log`'s ★ row is the record on every platform. The code
    /// compiles everywhere; only macOS runs it.
    package static func postSystemNotification(_ text: String) {
        guard postsSystemNotifications else { return }
        run(notification(text))
    }

    /// The `osascript` run for `text`.
    package static func notification(_ text: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e", "on run argv",
            "-e", "display notification (item 1 of argv) with title \"rv\"",
            "-e", "end run",
            text,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    /// Starts `process` without waiting, holding it until it exits so
    /// nothing is torn down while it runs.
    package static func run(_ process: Process) {
        let held = Held(process)
        let key = ObjectIdentifier(process)
        running.withLock { $0[key] = held }
        process.terminationHandler = { finished in
            _ = running.withLock { $0.removeValue(forKey: ObjectIdentifier(finished)) }
        }
        do {
            try process.run()
        } catch {
            _ = running.withLock { $0.removeValue(forKey: key) }
        }
    }

    /// How many notification runs are still held.
    package static var runningCount: Int { running.withLock { $0.count } }

    #if os(macOS)
    static let postsSystemNotifications = true
    #else
    static let postsSystemNotifications = false
    #endif

    /// A started process, held from its start to its exit.
    private final class Held: @unchecked Sendable {
        let process: Process
        init(_ process: Process) { self.process = process }
    }

    private static let running = Mutex<[ObjectIdentifier: Held]>([:])
}
