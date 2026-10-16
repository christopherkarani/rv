#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
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

    /// Values of `flag` in both `--flag value` and `--flag=value` spellings.
    static func values(forFlag flag: String, in arguments: [String]) -> [String] {
        var values: [String] = []
        for (index, argument) in arguments.enumerated() {
            if argument == flag, index + 1 < arguments.count {
                values.append(arguments[index + 1])
            } else if argument.hasPrefix(flag + "=") {
                values.append(String(argument.dropFirst(flag.count + 1)))
            }
        }
        return values
    }

    /// `--to` is copied into the plist. Refuse it here too, so a direct install
    /// cannot write a destination `AuditForwardRun.destination` would reject.
    static func refusedDestination(_ arguments: [String]) -> CommandFailure? {
        for value in values(forFlag: "--to", in: arguments) {
            if case .failure(let failure) = AuditForwardRun.destination(value) { return failure }
        }
        return nil
    }

    /// Header values end up in the plist, so they must name secrets, not hold them.
    /// A literal beside `${secret:NAME}` is still a secret.
    static func plaintextHeader(_ arguments: [String]) -> String? {
        values(forFlag: "--header", in: arguments).first { headerCarriesLiteral($0) }
            .map { value in String(value.prefix { $0 != "=" }) }
    }

    /// True unless every credential in the header is a `${secret:NAME}` reference.
    /// `Bearer` / `Basic` / `Token` may sit in front of one reference; any other leftover is literal.
    static func headerCarriesLiteral(_ header: String) -> Bool {
        guard let names = MCPSecretReference.names(in: header), names.isEmpty == false else { return true }
        var rest = header
        for name in names {
            rest = rest.replacingOccurrences(of: "${secret:\(name)}", with: "")
        }
        let payload = rest.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).dropFirst()
            .joined(separator: "=")
        let words = payload.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.isEmpty { return false }
        if words.count == 1, ["bearer", "basic", "token"].contains(words[0].lowercased()) { return false }
        return true
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
        if let failure = refusedDestination(plan.forwardArguments) { return .failure(failure) }
        if let header = plaintextHeader(plan.forwardArguments) {
            return .failure(CommandFailure(
                "--install writes the command into a plist, so header \(header) must use ${secret:NAME} instead of a literal value"))
        }
        guard OwnerOnlyFile.write(agentPlist(plan), to: plan.agentURL) else {
            return .failure(CommandFailure("could not write \(plan.agentURL.path)"))
        }
        let agent = shellQuote(plan.agentURL.path)
        let source = shellQuote("\(label).\(plan.userName).plist")
        let daemonPath = shellQuote(plan.daemonPath)
        let daemon = String(decoding: daemonPlist(plan), as: UTF8.self)
        return .success("""
            wrote \(plan.agentURL.path) (runs `rv audit forward` every \(interval / 60) minutes; log \(plan.logPath))
            load it now:
              launchctl bootout gui/\(plan.userID)/\(label) 2>/dev/null; launchctl bootstrap gui/\(plan.userID) \(agent)
            remove it:
              launchctl bootout gui/\(plan.userID)/\(label); rm \(agent)

            To forward even when \(plan.userName) is logged out, root can install this LaunchDaemon instead
            (save it as \(source), then):
              sudo install -o root -g wheel -m 644 \(source) \(daemonPath)
              sudo launchctl bootstrap system \(daemonPath)

            \(daemon)
            """ + (daemon.hasSuffix("\n") ? "" : "\n"))
    }

    /// The login name from the passwd entry. `USER` is caller-controlled.
    static func accountName() -> String? {
        guard let entry = getpwuid(getuid()), let pointer = entry.pointee.pw_name else { return nil }
        let name = String(cString: pointer)
        guard name.isEmpty == false else { return nil }
        return name
    }

    /// Single quotes, with an embedded `'` written as `'\''`.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// launchd is macOS only; elsewhere print the equivalent crontab line.
    static func cronHint(_ plan: Plan) -> String {
        // crontab rewrites an unescaped % to a newline, so quote and escape.
        let command = plan.programArguments
            .map { "'" + $0.replacingOccurrences(of: "'", with: #"'\''"#).replacingOccurrences(of: "%", with: "\\%") + "'" }
            .joined(separator: " ")
        return "launchd is macOS only; add this line with `crontab -e` instead:\n*/5 * * * * \(command)\n"
    }

    private static func serialize(_ object: [String: Any]) -> Data {
        (try? PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)) ?? Data()
    }
}
