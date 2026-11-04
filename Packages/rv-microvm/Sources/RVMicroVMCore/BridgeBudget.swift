import Synchronization

/// Caps concurrent host relay bridges. Every guest connection to a relayed
/// port costs two threads and two descriptors in the entitled helper, so a
/// guest looping `connect` must hit a ceiling rather than exhaust the host.
public final class BridgeBudget: Sendable {
    /// Shared by every relayed port of one VM.
    public static let relayLimit = 128

    private let limit: Int
    private let active = Atomic<Int>(0)

    public init(limit: Int = BridgeBudget.relayLimit) {
        self.limit = limit
    }

    public func tryAcquire() -> Bool {
        while true {
            let current = active.load(ordering: .relaxed)
            guard current < limit else { return false }
            if active.compareExchange(
                expected: current, desired: current + 1, ordering: .acquiringAndReleasing
            ).exchanged {
                return true
            }
        }
    }

    public func release() {
        active.subtract(1, ordering: .acquiringAndReleasing)
    }
}
