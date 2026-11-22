import Foundation
import RVDomain
import RVIPC
import RVJudgePool
import RVPolicy

/// The `rv-hook-local` process contract with the C hook (`local_eval.h`):
/// argv is exactly `--host <host> --request-id <uuid>`, stdin is the host
/// payload, and stdout is one answer:
///
/// - `rv-hook-local/1 final\n` and the IPC reply rvd would send for this
///   request id, or
/// - `rv-hook-local/1 escalate <reason>\n`, after which the hook asks rvd.
///
/// Anything this process cannot do cleanly is an escalation or a nonzero
/// exit, and the hook treats both the same: it asks rvd.
package enum LocalHookCommand {
    package static let finalTag = "rv-hook-local/1 final\n"
    package static let escalateTag = "rv-hook-local/1 escalate "
    /// The C hook's own stdin cap (`RV_STDIN_XPC_MAX`).
    package static let inputLimit = 1024 * 1024

    package struct Arguments: Equatable, Sendable {
        package let host: HookHost
        package let requestID: UUID
    }

    /// The only accepted argv (after the program name).
    package static func parse(_ arguments: [String]) -> Arguments? {
        guard arguments.count == 4, arguments[0] == "--host", arguments[2] == "--request-id",
            let host = HookHost(rawValue: arguments[1]),
            let id = UUID(uuidString: arguments[3])
        else { return nil }
        return Arguments(host: host, requestID: id)
    }

    /// The framed answer for one call. `home` is the passwd home; nil
    /// escalates, as does input past the hook's cap or not UTF-8.
    /// `started` is when the process began (the decider's write deadline
    /// counts from it). `judge` is the pool client judged calls ask.
    package static func respond(
        to arguments: Arguments,
        input: Data,
        home: HomeDirectory?,
        started: ContinuousClock.Instant = .now,
        judge: (any JudgeClient)? = nil
    ) async -> Data {
        guard let home else { return escalation(.unexpected) }
        guard input.count <= inputLimit, let stdin = String(data: input, encoding: .utf8) else {
            return escalation(.malformed)
        }
        let outcome = await LocalHookDecider(home: home, judge: judge)
            .decide(host: arguments.host, stdin: stdin, started: started)
        switch outcome {
        case .escalate(let reason):
            return escalation(reason)
        case .final(let reply):
            let response = IPCResponse(id: arguments.requestID, result: .hookEvaluate(reply))
            guard let body = try? IPCJSON.encode(response) else { return escalation(.unexpected) }
            return Data(finalTag.utf8) + body
        }
    }

    /// The evaluator's pool client: `dev.rv.judge`, the supervisor
    /// verified by the peer-trust manifest or as `rv-judge` beside this
    /// executable, exactly as rvd verifies it. It never warms (the pool
    /// serves warm and status to rvd only). Nil off macOS, where rvd runs
    /// no pool either.
    package static func liveJudge() -> (any JudgeClient)? {
        #if canImport(XPC)
        return XPCJudgeClient(warms: false)
        #else
        return nil
        #endif
    }

    package static func escalation(_ reason: LocalHookEscalation) -> Data {
        Data((escalateTag + reason.rawValue + "\n").utf8)
    }

    /// The passwd entry's home for this uid. Never `$HOME`.
    package static func passwdHome() -> HomeDirectory? {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else { return nil }
        let path = String(cString: dir)
        guard path.hasPrefix("/") else { return nil }
        return HomeDirectory(validating: path)
    }
}
