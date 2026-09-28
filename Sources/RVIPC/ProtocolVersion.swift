public enum ProtocolVersion: Sendable {
    public static let name = "rv.ipc.v1"
    /// Handshake / doctor semver. Swift constant (not bundle or git describe).
    public static let serviceSemver = "1.0.0"

    /// Major version of a `"<head>.<rest>"` semver, or nil on miss.
    ///
    /// Grammar (mirrors `rv_semver_major` in `Sources/rv-c/evaluation_route.h`):
    /// the head before the first `.` must be 1-15 ASCII digits and fit INT_MAX.
    /// Misses (empty head, non-digit bytes like `+1`/`-0`, 16+ chars, overflow)
    /// return nil; callers that must fail closed treat nil as incompatible.
    public static func major(of semver: String) -> Int? {
        let head = semver.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first
        guard let head, head.isEmpty == false, head.count < 16,
              head.allSatisfy({ $0 >= "0" && $0 <= "9" })
        else {
            return nil
        }
        guard let value = Int(head), value <= Int(Int32.max) else { return nil }
        return value
    }

    /// True only when both semvers parse and their majors differ.
    /// Unparseable input is not skew (returns false); callers that must fail
    /// closed on garbage check `major(of:)` for nil separately — see
    /// `EvaluationRoute.path`, which routes any miss to `.inProcess`.
    public static func isMajorSkew(clientSemver: String, serviceSemver: String) -> Bool {
        guard let client = major(of: clientSemver), let service = major(of: serviceSemver) else {
            return false
        }
        return client != service
    }
}
