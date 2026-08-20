import RVIPC

/// Typed failure while talking to a reachable evaluation service.
enum ServiceDiagnosticFailure: Sendable, Equatable {
    case transport(ServiceTransportError)
    case invalidResponse
    case unexpectedResponse
    case service(IPCError)

    /// Operator-facing status string with no peer-supplied detail.
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

/// Why a successful hello still cannot use the peer.
enum ServiceSkewReason: Sendable, Equatable {
    case protocolMismatch
    case majorVersionMismatch
    case corePacksUnavailable
    case rejected

    /// Operator-facing status string with no peer-supplied detail.
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

/// Why diagnostics fell back to local readiness instead of an XPC snapshot.
enum ServiceFallbackCause: Sendable, Equatable {
    case down
    case skew(ServiceSkewReason)
    case requestFailed(ServiceDiagnosticFailure)
}

/// Local readiness facts when the XPC doctor snapshot is unavailable.
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

/// Result of one typed hello + doctorSnapshot diagnostic attempt.
enum ServiceDiagnosticResult: Sendable, Equatable {
    case xpc(snapshot: DoctorSnapshotReply, localCorePacksReady: Bool)
    case local(ServiceFallbackDiagnostic)
}
