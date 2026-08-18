public struct RuleID: Hashable, Sendable, Equatable {
    public var pack: PackID
    public var pattern: String

    public init(pack: PackID, pattern: String) {
        self.pack = pack
        self.pattern = pattern
    }

    public var rawValue: String {
        "\(pack.rawValue):\(pattern)"
    }

    public init?(rawValue: String) {
        let parts = rawValue.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            return nil
        }
        pack = PackID(rawValue: String(parts[0]))
        pattern = String(parts[1])
    }
}
