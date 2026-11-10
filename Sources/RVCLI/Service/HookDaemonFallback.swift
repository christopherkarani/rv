#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import RVHooks
import RVPolicy
import RVService

/// `RV_HOOK_WHEN_DOWN`: how a hook renders when rvd is absent, slow or the
/// connection failed (`.unreachable` / `.timeout` / `.connection`). Exactly
/// `deny` is `.deny`; unset or any
/// other value is `.ask`. There is deliberately no allow/bypass value: the
/// variable can reach the hook from project-scoped host config an agent
/// can write. Identity and protocol failures always deny.
public enum HookWhenDown: String, Sendable, Equatable {
    case ask, deny

    public static let environmentKey = "RV_HOOK_WHEN_DOWN"

    public init(environmentValue: String?) {
        self = environmentValue.flatMap(Self.init(rawValue:)) ?? .ask
    }
}

/// Why the Swift hook path got no verdict from rvd. Mirrors the
/// daemon-unavailable classes of `Sources/rv-c/hook_fallback.h`.
///
/// `.unreachable` is the only class owner observe mode steps aside for, so
/// it means rvd was positively absent before any request byte was sent: a
/// Linux connect that failed with ENOENT/ECONNREFUSED on the uid-derived
/// socket, or a Darwin discovery connection launchd refused as invalid.
/// `.connection` is every other connection failure (dropped after send or
/// after the daemon was verified, an agent-chosen XDG_RUNTIME_DIR, an
/// unresolvable socket path, unrecognized errors): rvd drops in-flight
/// requests while draining, and an agent can trigger that.
enum HookDaemonFailure: Sendable, Equatable, CaseIterable {
    case unreachable, timeout, untrusted, `protocol`, connection
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
            "RV daemon identity check failed (stale or mismatched rvd after an upgrade?). Run `rv service restart`; if it persists, `rv setup`."
        case .protocol:
            "RV daemon sent an unexpected reply (version skew after an upgrade?). Run `rv service restart`; if it persists, `rv setup`."
        case .connection:
            "RV daemon connection failed or dropped before a verdict. Retry; if it persists run `rv doctor`."
        }
    }

    /// `ownerObserves`: the owner's config file puts `host` in observe mode
    /// (`HookObserveFallback`); an unreachable daemon then steps aside. A
    /// slow or dropped one does not: it may be live and would still have
    /// enforced rv's self-protection, and an agent can cause either.
    static func wire(
        host: HookHost,
        failure: HookDaemonFailure,
        mode: HookWhenDown,
        ownerObserves: Bool = false
    ) -> HookWire {
        let message = message(for: failure)
        // A daemon that fails identity verification may be an impostor, and a
        // malformed reply carries no trustworthy verdict: never soften those.
        guard failure == .unreachable || failure == .timeout || failure == .connection else {
            return deny(host: host, message: message)
        }
        if ownerObserves, failure == .unreachable {
            let allow = productionHostCodec(host).encodeAllow()
            return HookWire(
                stdout: allow.stdout, exitCode: allow.exitCode, stderr: HookObserveFallback.message + "\n")
        }
        switch mode {
        case .deny:
            return deny(host: host, message: message)
        case .ask:
            return ask(host: host, message: message) ?? deny(host: host, message: message)
        }
    }

    /// Classifies a transport-level error from the hook consult send. Same
    /// resolution as the C hook (`Sources/rv-c/rv.c`): only a typed
    /// positive-absence error is `.unreachable`.
    static func classify(_ error: any Error) -> HookDaemonFailure {
        if let error = error as? ServiceTransportError {
            switch error {
            case .timeout: return .timeout
            case .connectFailed: return .unreachable
            case .interrupted: return .connection
            case .decodeFailed, .unexpected: return .protocol
            }
        }
        if error is DecodingError {
            return .protocol
        }
#if canImport(XPC)
        if let error = error as? XPCEvaluateClientError {
            switch error {
            case .authenticationFailed: return .untrusted
            case .connectFailed: return .unreachable
            case .connectionLost, .cancelled: return .connection
            case .malformedReply: return .protocol
            }
        }
#endif
#if os(Linux)
        if let error = error as? UnixServiceConnection.TransportFailure {
            switch error {
            case .untrustedDaemon: return .untrusted
            case .frameTooLarge: return .protocol
            case .connect(let code):
                // A raw miss is not proof of absence: the transport maps a miss
                // on the uid-derived socket to `.connectFailed` itself.
                return [EAGAIN, EWOULDBLOCK, ETIMEDOUT, EINPROGRESS].contains(code) ? .timeout : .connection
            case .io(let code):
                return code == EAGAIN || code == EWOULDBLOCK ? .timeout : .connection
            case .noSocketPath: return .connection
            }
        }
#endif
        // Unrecognized failure: not proof rvd is absent, so never the observe
        // step-aside. Ask/deny per RV_HOOK_WHEN_DOWN.
        return .connection
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

/// Swift twin of `Sources/rv-c/observe_gate.c`: whether a hook that could
/// not reach rvd may step aside because the owner chose observe mode. Reads only `config.json` under the passwd home, never
/// `$HOME`, `RV_GUARD_MODE` or other environment. True only when no
/// organization policy directory exists, the config is a regular file (no
/// symlink) owned by this uid, not group- or world-writable, at most
/// `configMaxBytes`, and selects observe for `host`.
enum HookObserveFallback {
    static let configMaxBytes = 1024 * 1024

    /// Same sentence as the C constant (pinned by HookDaemonFallbackTests).
    static let message =
        "RV observe mode: daemon unavailable, so this call was allowed without being checked or logged. Run `rv doctor`."

    @Sendable static func live(host: HookHost) -> Bool {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else { return false }
        let home = String(cString: dir)
        guard home.hasPrefix("/") else { return false }
        return applies(
            configFile: home + "/.config/rv/config.json",
            managedDirectory: ManagedPolicyLocation.installedDirectory,
            host: host
        )
    }

    static func applies(configFile: String, managedDirectory: String, host: HookHost) -> Bool {
        var info = stat()
        guard lstat(managedDirectory, &info) != 0, errno == ENOENT else { return false }
        let fd = open(configFile, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return false }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard fstat(fd, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_uid == getuid(),
              (info.st_mode & mode_t(S_IWGRP | S_IWOTH)) == 0,
              info.st_size >= 0, info.st_size <= configMaxBytes,
              let data = try? handle.readToEnd(), data.count == Int(info.st_size),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return JudgeRuntime.configuredGuardMode(config: root, host: host) == .observe
    }
}
