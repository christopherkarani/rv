import RVIPC

enum ServiceDiagnosticFailure: Sendable, Equatable {
    case transport(ServiceTransportError)
    case invalidResponse
    case unexpectedResponse
    case service(IPCError)

    var statusMessage: String {
        switch self {
        case .transport:
            "request failed"
        case .invalidResponse:
            "invalid response"
        case .unexpectedResponse:
            "unexpected response"
        case .service:
            "service error"
        }
    }
}

enum ServiceSkewReason: Sendable, Equatable {
    case protocolMismatch
    case majorVersionMismatch
    case corePacksUnavailable
    case rejected

    var statusMessage: String {
        switch self {
        case .protocolMismatch:
            "protocol mismatch"
        case .majorVersionMismatch:
            "major version mismatch"
        case .corePacksUnavailable:
            "core packs unavailable"
        case .rejected:
            "handshake rejected"
        }
    }
}

enum ServiceFallbackCause: Sendable, Equatable {
    case down
    case skew(ServiceSkewReason)
    case requestFailed(ServiceDiagnosticFailure)
}

struct ServiceFallbackDiagnostic: Sendable, Equatable {
    var cause: ServiceFallbackCause
    var corePacksReady: Bool
    var serviceSemver: String?

    init(
        cause: ServiceFallbackCause,
        corePacksReady: Bool,
        serviceSemver: String? = nil
    ) {
        self.cause = cause
        self.corePacksReady = corePacksReady
        self.serviceSemver = serviceSemver
    }
}

enum ServiceDiagnosticResult: Sendable, Equatable {
    case xpc(snapshot: DoctorSnapshotReply, localCorePacksReady: Bool)
    case local(ServiceFallbackDiagnostic)
}

extension ServiceDiagnosticResult {
    var statusReport: ServiceStatusReport {
        switch self {
        case .xpc(let snapshot, _):
            ServiceStatusReport(
                state: "running",
                protocolName: snapshot.protocolName,
                label: snapshot.label,
                fallback: "inactive",
                keepAlive: snapshot.keepAlive,
                lastError: snapshot.lastError
            )
        case .local(let diagnostic):
            switch diagnostic.cause {
            case .down:
                ServiceStatusReport(state: "down", fallback: "down")
            case .skew(let reason):
                ServiceStatusReport(
                    state: "skew",
                    fallback: "skew",
                    lastError: reason.statusMessage
                )
            case .requestFailed(let failure):
                ServiceStatusReport(
                    state: "down",
                    fallback: "down",
                    lastError: failure.statusMessage
                )
            }
        }
    }
}
