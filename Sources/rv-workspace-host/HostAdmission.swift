#if os(macOS)
import Foundation
import RVDomain
import RVEngine
import RVIsolation

/// The one production admission configuration for host-owned runtimes.
///
/// Every interactive runtime is launched by the workspace host, so this is
/// the only place that composes a live normalize/executor pair. Each
/// runtime still gets its own capability and channel binding; this value
/// only states how the host evaluates what a runtime asks for. Moved here
/// verbatim from the legacy in-process `rv opencode` door, which no longer
/// owns a workspace.
enum HostRuntimeAdmission {
    static func configuration() -> RuntimeAdmissionConfiguration {
        RuntimeAdmissionConfiguration(
            normalize: { subject, action in
                switch action {
                case .http(let method, let url):
                    return normalizeRuntimeHTTP(
                        subject: subject,
                        method: method,
                        url: url,
                        resolve: { name in
                            resolveAdmittedHTTPHost(
                                name,
                                budgetMilliseconds: HTTPEgressLimits.requestTimeoutMilliseconds,
                                lookup: resolveHTTPHost
                            )
                        }
                    )
                case .shell:
                    return normalizeRuntimeAdmission(subject: subject, action: action)
                }
            },
            executor: .containedCommand,
            http: .direct,
            approval: { _ in nil },
            policy: { _ in .empty },
            evidence: RuntimeAdmissionEvidence(appendingTo: RuntimeAdmissionEvidence.productionFile())
        )
    }
}
#endif
