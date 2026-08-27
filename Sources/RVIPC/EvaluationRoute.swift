public enum EvaluationRoute: Sendable {
    public enum Facts: Sendable, Equatable {
        /// Transport missing, send threw, or no evaluate reply was decoded.
        case transportAbsent
        /// Decoded evaluate / hookEvaluate reply. `via == .xpc` already enforced.
        case reply(clientSemver: String, advertisedServiceSemver: String?)
    }

    /// Returns the client evaluation path for these facts.
    /// Missing, empty, or unparseable advertised service semver cannot prove compatibility.
    public static func path(for facts: Facts) -> EvaluationPath {
        switch facts {
        case .transportAbsent:
            return .inProcess
        case let .reply(clientSemver, advertisedServiceSemver):
            guard let advertisedServiceSemver,
                  advertisedServiceSemver.isEmpty == false,
                  let clientMajor = ProtocolVersion.major(of: clientSemver),
                  let serviceMajor = ProtocolVersion.major(of: advertisedServiceSemver),
                  clientMajor == serviceMajor
            else {
                return .inProcess
            }
            return .xpc
        }
    }
}
