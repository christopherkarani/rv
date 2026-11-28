import RVDomain

/// `rv packs test <pack>`: each rule's examples, run.
public struct PackTestViewModel: Equatable, Sendable {
    public struct Rule: Equatable, Sendable {
        /// The rule's name inside its pack (`flushall`).
        public var name: String
        public var stops: Int
        public var allows: Int
        /// One line per example that did not do what its label says:
        /// `stop: redis-cli FLUSHALL ran`.
        public var failures: [String]

        public init(name: String, stops: Int, allows: Int, failures: [String]) {
            self.name = name
            self.stops = stops
            self.allows = allows
            self.failures = failures
        }

        public var hasExamples: Bool { stops + allows > 0 }
    }

    public var packID: PackID
    public var rules: [Rule]
    /// The command that turns the pack on when it is off; nil when on.
    public var turnOn: String?

    public init(packID: PackID, rules: [Rule], turnOn: String?) {
        self.packID = packID
        self.rules = rules
        self.turnOn = turnOn
    }

    public var failedCount: Int { rules.filter { $0.failures.isEmpty == false }.count }
    public var passed: Bool { failedCount == 0 }
}
