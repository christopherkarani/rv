public enum ProtocolVersion: Sendable {
    public static let name = "rv.ipc.v1"
    /// Handshake / doctor semver. Swift constant (not bundle or git describe).
    public static let serviceSemver = "1.0.0"

    public static func major(of semver: String) -> Int? {
        let head = semver.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first
        guard let head, let value = Int(head), value >= 0 else { return nil }
        return value
    }

    public static func isMajorSkew(clientSemver: String, serviceSemver: String) -> Bool {
        guard let client = major(of: clientSemver), let service = major(of: serviceSemver) else {
            return false
        }
        return client != service
    }
}
