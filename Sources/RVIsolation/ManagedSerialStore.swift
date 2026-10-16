#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVPolicy
import Synchronization

/// The user's `managed-state.json`: applies the anti-rollback check to a
/// loaded organization policy and remembers a raised serial.
public struct ManagedSerialStore: Sendable {
    public var url: URL

    public init(configDirectory: URL) {
        url = configDirectory.appendingPathComponent(ManagedSerialRecord.fileName)
    }

    public func check(_ state: ManagedPolicyState) -> ManagedPolicyState {
        guard case .active = state else { return state }
        let unusable = ManagedPolicyState.invalid(
            "\(url.path) is unreadable or unsafe, so the policy serial cannot be checked for rollback")
        return CheckLock.withLock {
            guard let lock = Self.acquire(url) else { return unusable }
            defer {
                _ = flock(lock, LOCK_UN)
                close(lock)
            }
            var record = ManagedSerialRecord()
            switch OwnerOnlyFile.read(url, maximumBytes: ManagedSerialRecord.maximumBytes) {
            case .failure:
                return unusable
            case .success(nil):
                break
            case .success(let data?):
                guard case .success(let decoded) = ManagedSerialRecord.decode(data) else { return unusable }
                record = decoded
            }
            let checked = state.checkedForRollback(against: record)
            guard let raised = checked.raised else { return checked.state }
            for (directory, serial) in raised.highest {
                if let stored = record.highest[directory], serial < stored { return unusable }
            }
            guard OwnerOnlyFile.write(raised.encoded(), to: url) else { return unusable }
            return checked.state
        }
    }

    /// Exclusive lock on a sibling of the state file. `OwnerOnlyFile.write`
    /// renames a new inode into place, so the lock has to be a file that
    /// stays put. An in-process mutex is held as well: macOS `flock` does
    /// not exclude another thread in this process.
    private static func acquire(_ state: URL) -> Int32? {
        let directory = state.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            return nil
        }
        let lockURL = directory.appendingPathComponent(".\(state.lastPathComponent).lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return nil }
        // Bounded: a stopped process holding the lock must fail the check
        // closed, not hang every later startup behind a blocking flock.
        for attempt in 0..<50 {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return fd }
            if errno != EWOULDBLOCK && errno != EINTR {
                close(fd)
                return nil
            }
            if attempt < 49 { usleep(20_000) }
        }
        close(fd)
        return nil
    }

    private enum CheckLock {
        private static let mutex = Mutex<Void>(())

        static func withLock<T: Sendable>(_ body: () -> T) -> T {
            mutex.withLock { _ in body() }
        }
    }
}

extension ManagedPolicyLocation {
    /// `load()` followed by the anti-rollback check against the user's serial record.
    public func load(serialsIn configDirectory: URL) -> ManagedPolicyState {
        ManagedSerialStore(configDirectory: configDirectory).check(load())
    }
}
