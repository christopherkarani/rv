#if os(macOS)
import Foundation
import RVDomain
import RVEngine
import RVIsolation
import RVService
import Synchronization

/// The one production admission configuration for host-owned runtimes.
///
/// Every interactive runtime is launched by the workspace host, so this is
/// the only place that composes a live normalize/executor pair. Each
/// runtime still gets its own capability and channel binding; this value
/// only states how the host evaluates what a runtime asks for. Moved here
/// verbatim from the legacy in-process `rv opencode` door, which no longer
/// owns a workspace.
enum HostRuntimeAdmission {
    static func configuration(bridge: WorkspaceHostBridgeClient) -> RuntimeAdmissionConfiguration {
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
                case .shell(let command):
                    if subject.agent != nil && !serviceAllows(bridge: bridge, subject: subject, command: command) {
                        return .failure(.failed)
                    }
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
    /// The admission API is synchronous; the XPC callback runs independently.
    /// A bounded wait fails closed and cancels the exchange. No local fallback
    /// is allowed for an instance-bound shell request when the bridge fails.
    private static func serviceAllows(
        bridge: WorkspaceHostBridgeClient, subject: RuntimeAdmissionSubject, command: ShellCommand
    ) -> Bool {
        let allowed = Mutex(false)
        let finished = DispatchSemaphore(value: 0)
        let task = Task {
            defer { finished.signal() }
            if let reply = try? await bridge.evaluate(subject: subject, command: command),
               reply.result.decision == .allow {
                allowed.withLock { $0 = true }
            }
        }
        guard finished.wait(timeout: .now() + 11) == .success else {
            task.cancel()
            return false
        }
        return allowed.withLock { $0 }
    }
}
#endif
