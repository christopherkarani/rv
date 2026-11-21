#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVFileStore
import RVHistory
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
            // Accepting a new serial changes the gate: recorded write-ahead,
            // so a serial the audit log cannot hold is not accepted (the
            // bundle stays invalid, which enforces, and the next load retries).
            guard case .active(let bundle) = checked.state,
                let event = Self.acceptedEvent(bundle, prior: record.highest[bundle.directory])
            else { return unusable }
            do {
                try ConfigChangeAudit.commit(event, configDirectory: url.deletingLastPathComponent()) {
                    guard OwnerOnlyFile.write(raised.encoded(), to: url) else { throw ManagedSerialUnsaved() }
                }
            } catch is ManagedSerialUnsaved {
                return unusable
            } catch {
                return .invalid("the audit log could not record organization policy serial \(event.detail["serial"] ?? ""), so it was not accepted")
            }
            return checked.state
        }
    }

    /// `policy.managed` for a newly accepted serial: the bundle's serial,
    /// content hash and signer, never its body (an `audit_forward` header
    /// can hold a credential).
    static func acceptedEvent(_ bundle: ManagedPolicyBundle, prior: Int?) -> AuditEvent? {
        guard let serial = bundle.policy.serial else { return nil }
        let signer = bundle.signingKey.map { "organization signature (key \($0))" }
            ?? (bundle.isSigned ? "organization signature" : "unsigned bundle")
        var detail = [
            "change": "serial-accepted", "serial": String(serial), "sha256": bundle.sha256,
            "directory": bundle.directory, "signed": String(bundle.isSigned), "authorized_by": signer,
        ]
        if let prior { detail["prior_serial"] = String(prior) }
        return ConfigChangeAudit.event(
            .policyManaged, subject: bundle.policy.organization ?? bundle.directory, detail: detail)
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

private struct ManagedSerialUnsaved: Error {}
