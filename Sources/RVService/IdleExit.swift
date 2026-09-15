public actor IdleWatchdog {
    public static let defaultSeconds = 300

    /// Whether the idle timer has elapsed without a ping.
    public private(set) var hasFired = false
    private(set) var pingCount = 0
    private var generation = 0
    private let seconds: Double
    private let onFire: @Sendable () async -> Void

    public init(seconds: Int = IdleWatchdog.defaultSeconds, onFire: @escaping @Sendable () async -> Void = {}) {
        self.seconds = Double(seconds)
        self.onFire = onFire
    }

    public func ping() {
        pingCount += 1
        generation += 1
        hasFired = false
        let gen = generation
        let delay = seconds
        Task {
            let ns = UInt64(delay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ns)
            guard gen == self.generation else { return }
            self.hasFired = true
            await self.onFire()
        }
    }
}
