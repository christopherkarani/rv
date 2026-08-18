public actor IdleWatchdog {
    public static let defaultSeconds = 300

    public private(set) var fired = false
    private var generation = 0
    private let seconds: Double
    private let onFire: @Sendable () async -> Void

    public init(seconds: Int = IdleWatchdog.defaultSeconds, onFire: @escaping @Sendable () async -> Void = {}) {
        self.seconds = Double(seconds)
        self.onFire = onFire
    }

    public func ping() {
        generation += 1
        fired = false
        let gen = generation
        let delay = seconds
        Task {
            let ns = UInt64(delay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ns)
            guard gen == self.generation else { return }
            self.fired = true
            await self.onFire()
        }
    }
}
