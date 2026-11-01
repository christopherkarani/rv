import Foundation
import RVDomain
import RVHooks
import RVService

/// `RV_HOOK_WHEN_DOWN`: how a hook renders when rvd gives no verdict.
/// Unset or any other value is `.ask`. `.allow` prints nothing and exits 0,
/// deferring to the host's own permission system — never an RV allow.
public enum HookWhenDown: String, Sendable, Equatable {
    case ask, deny, allow

    public static let environmentKey = "RV_HOOK_WHEN_DOWN"

    public init(environmentValue: String?) {
        self = environmentValue.flatMap(Self.init(rawValue:)) ?? .ask
    }
}

/// Why the Swift hook path got no verdict from rvd. Mirrors the
/// daemon-unavailable classes of `Sources/rv-c/hook_fallback.h`.
enum HookDaemonFailure: Sendable, Equatable, CaseIterable {
    case unreachable, timeout, untrusted, `protocol`
}

/// Swift twin of `Sources/rv-c/hook_fallback.c` for daemon-unavailable
/// hooks. Deny reuses each host codec's deny wire; only Claude and Cursor
/// have a native ask, every other host falls back to its deny.
enum HookDaemonFallback {
    /// Same sentences as the C constants (pinned by HookDaemonFallbackTests).
    static func message(for failure: HookDaemonFailure) -> String {
        switch failure {
        case .unreachable:
            "RV daemon is not reachable (dev.rv.evaluate). Run `rv doctor`; `rv setup` repairs the service."
        case .timeout:
            "RV daemon did not answer in time. Retry; if it persists run `rv doctor`."
        case .untrusted:
            "RV daemon identity check failed (stale or mismatched rvd after an upgrade?). Run `rv setup`, then `rv doctor`."
        case .protocol:
            "RV daemon sent an unexpected reply (version skew after an upgrade?). Run `rv setup`, then `rv doctor`."
        }
    }

    static func wire(host: HookHost, failure: HookDaemonFailure, mode: HookWhenDown) -> HookWire {
        let message = message(for: failure)
        switch mode {
        case .allow:
            return HookWire(stdout: "", exitCode: 0)
        case .deny:
            return deny(host: host, message: message)
        case .ask:
            return ask(host: host, message: message) ?? deny(host: host, message: message)
        }
    }

    /// Classifies a transport-level error from the hook consult send.
    static func classify(_ error: any Error) -> HookDaemonFailure {
        if let error = error as? ServiceTransportError {
            switch error {
            case .timeout: return .timeout
            case .connectFailed, .interrupted: return .unreachable
            case .decodeFailed, .unexpected: return .protocol
            }
        }
#if canImport(XPC)
        if let error = error as? XPCEvaluateClientError {
            switch error {
            case .authenticationFailed: return .untrusted
            case .connectFailed, .cancelled: return .unreachable
            }
        }
#endif
        return .protocol
    }

    private static func deny(host: HookHost, message: String) -> HookWire {
        productionHostCodec(host).encodeDeny(reason: message, rule: nil, next: .none)
    }

    private static func ask(host: HookHost, message: String) -> HookWire? {
        let text = jsonString(message)
        switch host {
        case .claude:
            return HookWire(
                stdout: "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"ask\",\"permissionDecisionReason\":\(text)},\"systemMessage\":\(text)}\n",
                exitCode: 0
            )
        case .cursor:
            return HookWire(
                stdout: "{\"permission\":\"ask\",\"user_message\":\(text),\"agent_message\":\(text)}\n",
                exitCode: 0
            )
        case .grok, .pi, .opencode, .openclaw, .hermes, .codex, .antigravity, .muse:
            return nil
        }
    }

    private static func jsonString(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
            return "\"RV daemon unavailable.\""
        }
        return text
    }
}
