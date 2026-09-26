public enum ProtocolVersion: Sendable {
    public static let name = "rv.ipc.v1"
    /// Handshake / doctor semver. Swift constant (not bundle or git describe).
    public static let serviceSemver = "1.0.0"

    public static func major(of semver: String) -> Int? {
        let head = semver.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first
        // Mirror rv_semver_major (Sources/rv-c/evaluation_route.h): the head
        // must be non-empty ASCII digits (Swift Int accepts "+1"/"-0"; C
        // rejects any non-digit head) and fit in INT_MAX. Heads longer than
        // 15 digits always exceed INT_MAX, so no separate length check.
        guard let head, head.isEmpty == false, head.allSatisfy({ $0 >= "0" && $0 <= "9" }) else {
            return nil
        }
        guard let value = Int(head), value <= Int(Int32.max) else { return nil }
        return value
    }

    public static func isMajorSkew(clientSemver: String, serviceSemver: String) -> Bool {
        guard let client = major(of: clientSemver), let service = major(of: serviceSemver) else {
            return false
        }
        return client != service
    }
}
