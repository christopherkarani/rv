/// Operator posture. Missing config is `normal`. Repo may raise, never lower.
public enum SafetyLevel: String, Sendable, Equatable, Codable, CaseIterable {
    case normal
    case strict
}
