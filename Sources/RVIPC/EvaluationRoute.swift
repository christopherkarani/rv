public enum EvaluationRoute: Sendable {
    public enum Facts: Sendable, Equatable {
        case transportAbsent
        case reply(clientSemver: String, advertisedServiceSemver: String?)
    }

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
