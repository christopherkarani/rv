import Foundation
import RVDomain
import RVPolicy
import Synchronization

/// Proves rvd answers after setup starts the service: a real health
/// round-trip over the same hook-consult door hooks use (XPC on macOS, the
/// Unix socket on Linux), polled until a bounded deadline.
enum ServiceReadiness {
    /// How long setup waits for a freshly started rvd to answer.
    static let deadline: TimeInterval = 10
    static let pollInterval: TimeInterval = 0.5
    /// Ceiling for one probe, so a wedged transport cannot outlive the deadline.
    static let probeTimeout: TimeInterval = 3

    /// Polls `probe` until it answers true or `deadline` elapses. The probe
    /// always runs at least once.
    static func wait(
        deadline: TimeInterval = deadline,
        pollInterval: TimeInterval = pollInterval,
        now: () -> Date = Date.init,
        sleep: (TimeInterval) -> Void,
        probe: () -> Bool
    ) -> Bool {
        let end = now().addingTimeInterval(deadline)
        while true {
            if probe() { return true }
            guard now() < end else { return false }
            sleep(pollInterval)
        }
    }

    /// Live readiness for `SetupEnvironment.serviceAnswers`. Blocks the
    /// calling thread, so callers run setup off the cooperative pool
    /// (`Setup.setupOutcome`); the probe itself runs on the pool.
    static func live(home: HomeDirectory) -> () -> Bool {
        {
            let client = ServiceClient.probing(home: home)
            return wait(sleep: { Thread.sleep(forTimeInterval: $0) }) {
                blockingProbe(client)
            }
        }
    }

    private static func blockingProbe(_ client: ServiceClient) -> Bool {
        let answer = Mutex(false)
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let answered = await client.verifyHookService(attempts: 1, retryDelayNanoseconds: 0)
            answer.withLock { $0 = answered }
            done.signal()
        }
        guard done.wait(timeout: .now() + probeTimeout) == .success else { return false }
        return answer.withLock { $0 }
    }
}
