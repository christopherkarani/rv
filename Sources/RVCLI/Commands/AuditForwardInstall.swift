import Foundation
import RVIsolation
import RVMCP

/// `rv audit forward --install`: a user LaunchAgent that runs one forward
/// pass every five minutes, plus a LaunchDaemon template for root to install.
enum AuditForwardInstall {
    static let label = "dev.rv.audit-forward"
    static let interval = 300

    struct Plan {
        var home: URL
        var rvExecutable: String
        var userID: uid_t
        var userName: String
        /// Everything after `rv audit forward`, without `--install`.
        var forwardArguments: [String]

        var programArguments: [String] { [rvExecutable, "audit", "forward"] + forwardArguments }
        var agentURL: URL { home.appendingPathComponent("Library/LaunchAgents/\(label).plist") }
        var daemonPath: String { "/Library/LaunchDaemons/\(label).\(userName).plist" }
        var logPath: String {
            AuditForwardRun.stateDirectory(home.appendingPathComponent(".config/rv", isDirectory: true))
                .appendingPathComponent("launchd.log").path
        }
    }

    /// Header values end up in the plist, so they must name secrets, not hold them.
    static func plaintextHeader(_ arguments: [String]) -> String? {
        zip(arguments, arguments.dropFirst()).first { flag, value in
            flag == "--header" && (MCPSecretReference.names(in: value) ?? []).isEmpty
        }.map { _, value in String(value.prefix { $0 != "=" }) }
    }

    static func agentPlist(_ plan: Plan) -> Data {
        serialize([
            "Label": label,
            "ProgramArguments": plan.programArguments,
            "StartInterval": interval,
            "RunAtLoad": true,
            "ProcessType": "Background",
            "StandardOutPath": plan.logPath,
            "StandardErrorPath": plan.logPath,
        ])
    }

    static func daemonPlist(_ plan: Plan) -> Data {
        serialize([
            "Label": "\(label).\(plan.userName)",
            "UserName": plan.userName,
            "ProgramArguments": plan.programArguments,
            "EnvironmentVariables": ["HOME": plan.home.path],
            "StartInterval": interval,
            "RunAtLoad": true,
            "ProcessType": "Background",
            "StandardOutPath": plan.logPath,
            "StandardErrorPath": plan.logPath,
        ])
    }

    static func install(_ plan: Plan) -> Result<String, CommandFailure> {
        if let header = plaintextHeader(plan.forwardArguments) {
            return .failure(CommandFailure(
                "--install writes the command into a plist, so header \(header) must use ${secret:NAME} instead of a literal value"))
        }
        guard OwnerOnlyFile.write(agentPlist(plan), to: plan.agentURL) else {
            return .failure(CommandFailure("could not write \(plan.agentURL.path)"))
        }
        let agent = plan.agentURL.path
        let daemon = String(decoding: daemonPlist(plan), as: UTF8.self)
        return .success("""
            wrote \(agent) (runs `rv audit forward` every \(interval / 60) minutes; log \(plan.logPath))
            load it now:
              launchctl bootout gui/\(plan.userID)/\(label) 2>/dev/null; launchctl bootstrap gui/\(plan.userID) \(agent)
            remove it:
              launchctl bootout gui/\(plan.userID)/\(label); rm \(agent)

            To forward even when \(plan.userName) is logged out, root can install this LaunchDaemon instead
            (save it as \(label).\(plan.userName).plist, then):
              sudo install -o root -g wheel -m 644 \(label).\(plan.userName).plist \(plan.daemonPath)
              sudo launchctl bootstrap system \(plan.daemonPath)

            \(daemon)
            """ + (daemon.hasSuffix("\n") ? "" : "\n"))
    }

    /// launchd is macOS only; elsewhere print the equivalent crontab line.
    static func cronHint(_ plan: Plan) -> String {
        let command = plan.programArguments.map { "'" + $0.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }
            .joined(separator: " ")
        return "launchd is macOS only; add this line with `crontab -e` instead:\n*/5 * * * * \(command)\n"
    }

    private static func serialize(_ object: [String: Any]) -> Data {
        (try? PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)) ?? Data()
    }
}
