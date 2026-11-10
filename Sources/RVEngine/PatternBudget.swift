import Foundation

/// One evaluation request's pattern-matching allowance, shared by every
/// pass over it: segments, full view, alias expansions, and the semantic
/// door's own pack pass.
///
/// Measured in CPU time of the searching thread, so a loaded host (time
/// spent descheduled) never turns an ordinary command into indeterminate.
/// Each search also has its own cap, so one slow pattern cannot starve the
/// rules after it: a deny those rules find still wins. A wall-clock ceiling
/// stays as a backstop below the hook's 8 s timeout.
///
/// A value threaded `inout` through one evaluation: every pass charges the
/// same copy, so the request has one allowance.
public struct PatternBudget: Sendable {
    public static let defaultTotalCPU: Duration = .milliseconds(1500)
    public static let defaultPerSearchCPU: Duration = .milliseconds(150)
    public static let defaultWallCeiling: Duration = .seconds(6)

    private let totalCPU: Double
    private let perSearchCPU: Double
    private let wallDeadline: ContinuousClock.Instant
    private var spentCPU: Double = 0

    public init(
        totalCPU: Duration = PatternBudget.defaultTotalCPU,
        perSearchCPU: Duration = PatternBudget.defaultPerSearchCPU,
        wallCeiling: Duration = PatternBudget.defaultWallCeiling
    ) {
        self.totalCPU = totalCPU.seconds
        self.perSearchCPU = perSearchCPU.seconds
        self.wallDeadline = ContinuousClock.now + wallCeiling
    }

    /// True once no further search may start.
    public var isSpent: Bool {
        spentCPU >= totalCPU || ContinuousClock.now >= wallDeadline
    }

    /// Starts one search. Its `shouldStop` turns true past the per-search
    /// cap, the remaining total, or the wall ceiling; `finish` charges the
    /// CPU the search used.
    public func beginSearch() -> Search {
        Search(
            startCPU: threadCPUSeconds(),
            perSearchCPU: perSearchCPU,
            remainingCPU: totalCPU - spentCPU,
            wallDeadline: wallDeadline
        )
    }

    /// Charges the CPU `search` used since it began.
    public mutating func finish(_ search: Search) {
        spentCPU += max(0, threadCPUSeconds() - search.startCPU)
    }

    public struct Search: Sendable {
        fileprivate let startCPU: Double
        fileprivate let perSearchCPU: Double
        fileprivate let remainingCPU: Double
        fileprivate let wallDeadline: ContinuousClock.Instant

        public var shouldStop: Bool {
            let used = threadCPUSeconds() - startCPU
            return used >= perSearchCPU
                || used >= remainingCPU
                || ContinuousClock.now >= wallDeadline
        }
    }
}

private extension Duration {
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

/// CPU time consumed by the calling thread, in seconds.
func threadCPUSeconds() -> Double {
    var spec = timespec()
    guard clock_gettime(CLOCK_THREAD_CPUTIME_ID, &spec) == 0 else {
        // No thread clock: charge nothing and let the wall ceiling bound it.
        return 0
    }
    return Double(spec.tv_sec) + Double(spec.tv_nsec) / 1e9
}
