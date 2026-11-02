import Darwin
import Foundation

/// The VMs `rv-macvm` has running, one directory each under `runs/`. A run
/// holds an exclusive `flock` on its directory's `lock` file for as long as
/// its process lives, so a run is live exactly while that lock is held:
/// a SIGKILLed run releases it, and a reused pid cannot fake it. Counting
/// and creating happen under a lock on `runs/` itself, so two launches
/// cannot both take the last slot.
public enum MacVMRuns {
    public static let lockName = "lock"
    static let guardName = ".lock"

    public enum ClaimError: Error, Equatable, CustomStringConvertible {
        case limit(live: Int, allowed: Int)
        case io(String)

        public var description: String {
            switch self {
            case .limit(let live, let allowed): "Apple allows at most \(allowed) macOS VMs at a time and \(live) are running"
            case .io(let message): message
            }
        }
    }

    /// Sweeps dead runs, then creates and locks a new run directory unless
    /// `limit` runs are live.
    public static func claim(in runs: URL, limit: Int) -> Result<MacVMRunClaim, ClaimError> {
        withGuard(runs) {
            let live = sweepLocked(runs)
            guard live < limit else { return .failure(.limit(live: live, allowed: limit)) }
            let directory = runs.appendingPathComponent(MacVMRunDirectory.name(pid: getpid()), isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            } catch {
                return .failure(.io("cannot create \(directory.path): \(error.localizedDescription)"))
            }
            guard let descriptor = openLock(directory, create: true), flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                try? FileManager.default.removeItem(at: directory)
                return .failure(.io("cannot lock \(directory.path): \(String(cString: strerror(errno)))"))
            }
            return .success(MacVMRunClaim(directory: directory, descriptor: descriptor))
        }
    }

    /// Removes the directories of dead runs; returns how many.
    @discardableResult
    public static func sweep(in runs: URL) -> Int {
        let before = entries(runs).count
        let live = (try? withGuard(runs) { .success(sweepLocked(runs)) }.get()) ?? before
        return before - live
    }

    /// Under the guard: removes every run nobody holds; returns the live count.
    private static func sweepLocked(_ runs: URL) -> Int {
        var live = 0
        for name in entries(runs) {
            let directory = runs.appendingPathComponent(name, isDirectory: true)
            if let descriptor = openLock(directory, create: false) {
                defer { close(descriptor) }
                if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                    live += 1
                    continue
                }
            }
            // Unlocked, or no lock at all (an older layout): nobody owns it.
            try? FileManager.default.removeItem(at: directory)
        }
        return live
    }

    private static func entries(_ runs: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: runs.path)) ?? []).filter { !$0.hasPrefix(".") }
    }

    private static func openLock(_ directory: URL, create: Bool) -> Int32? {
        let path = directory.appendingPathComponent(lockName).path
        let descriptor = create ? open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600) : open(path, O_RDONLY | O_CLOEXEC)
        return descriptor >= 0 ? descriptor : nil
    }

    private static func withGuard<T>(
        _ runs: URL, _ body: () -> Result<T, ClaimError>
    ) -> Result<T, ClaimError> {
        do {
            try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)
        } catch {
            return .failure(.io("cannot create \(runs.path): \(error.localizedDescription)"))
        }
        let descriptor = open(runs.appendingPathComponent(guardName).path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return .failure(.io("cannot open the lock in \(runs.path)")) }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0, errno == EINTR {}
        return body()
    }
}

/// A live run: its directory, locked until `release` or process exit.
public final class MacVMRunClaim: @unchecked Sendable {
    public let directory: URL
    private let descriptor: Int32

    init(directory: URL, descriptor: Int32) {
        self.directory = directory
        self.descriptor = descriptor
    }

    /// Deletes the run's directory (its clones), then unlocks it.
    public func release() {
        try? FileManager.default.removeItem(at: directory)
        close(descriptor)
    }
}
