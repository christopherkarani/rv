import ArgumentParser
import Foundation
import RVDomain
import RVPolicy

struct HostCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "host",
        abstract: "Show or set how rv guards each agent host (block, observe, off).",
        subcommands: [HostListCommand.self, HostModeCommand.self]
    )
}

struct HostListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List every host with its mode and hook wiring."
    )

    @OptionGroup
    var format: FormatFlags

    func run() throws {
        guard let env = SetupEnvironment.live() else {
            try CommandContext.failHomeMissing(command: "host list")
        }
        try CeremonyCLI.emit(HostModeRun.list(env, json: format.json || format.robot))
    }
}

struct HostModeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mode",
        abstract: "Set one host to block, observe, or off. Loosening asks for device-owner authentication."
    )

    @Argument(help: "Host: grok, pi, opencode, claude, openclaw, hermes, codex, cursor, antigravity, or muse.")
    var host: String

    @Argument(help: "block, observe, or off.")
    var mode: String

    @OptionGroup
    var format: FormatFlags

    func validate() throws {
        guard HookHost(rawValue: host) != nil else {
            throw ValidationError("unknown host \(host)")
        }
        guard HostMode(rawValue: mode) != nil else {
            throw ValidationError("expected block, observe, or off")
        }
    }

    func run() async throws {
        guard let hookHost = HookHost(rawValue: host), let hostMode = HostMode(rawValue: mode) else {
            throw ValidationError("expected a host and block, observe, or off")
        }
        guard let env = SetupEnvironment.live() else {
            try CommandContext.failHomeMissing(command: "host mode")
        }
        // Loosening sheds oversight for that host: like `rv uninstall`, a
        // same-user agent must not do it unattended.
        let outcome = await HostModeRun.setMode(
            hostMode, for: hookHost, env: env, json: format.json || format.robot,
            authenticate: {
                // Only loosening calls this; with rvd down the human confirms
                // locally at a TTY (DaemonDownOwnerConfirmation).
                try await CLIOwnerAuth.requireAuthenticatedOrLocalWhenDaemonDown(
                    reason: "Authenticate to set rv to \(hostMode.rawValue) for \(hookHost.rawValue).",
                    action: .hostMode(hostMode, host: hookHost))
            }
        )
        try CeremonyCLI.emit(outcome)
    }
}
