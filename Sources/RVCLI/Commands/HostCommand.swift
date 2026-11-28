import ArgumentParser
import Foundation
import RVDomain
import RVPolicy

struct HostCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "host",
        abstract: "Show or set how rv guards each agent host (block, observe, off).",
        subcommands: [HostListCommand.self, HostModeCommand.self],
        // `rv host` alone answers "what mode is each host in?".
        defaultSubcommand: HostListCommand.self
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
        abstract: "Set one host to block, observe, or off. Loosening asks for device-owner authentication; an agent's block ends on its own after an hour."
    )

    @Argument(help: "Host: grok, pi, opencode, claude, openclaw, hermes, codex, cursor, antigravity, or muse.")
    var host: String?

    @Argument(help: "block, observe, or off.")
    var mode: String?

    @OptionGroup
    var format: FormatFlags

    func validate() throws {
        if let host, HookHost(rawValue: host) == nil {
            let known = HookHost.allCases.map(\.rawValue).sorted().joined(separator: ", ")
            throw ValidationError("unknown host \(host); expected one of \(known)")
        }
        if let mode, HostMode(rawValue: mode) == nil {
            throw ValidationError("expected block, observe, or off")
        }
    }

    func run() async throws {
        guard let env = SetupEnvironment.live() else {
            try CommandContext.failHomeMissing(command: "host mode")
        }
        // Without a mode this is a question, not a change: show the
        // current modes (every host, or the one named) like rv host list.
        guard let mode, let hostMode = HostMode(rawValue: mode),
              let host, let hookHost = HookHost(rawValue: host)
        else {
            try CeremonyCLI.emit(HostModeRun.list(env, json: format.json || format.robot, only: host.flatMap(HookHost.init(rawValue:))))
        }
        // Loosening sheds oversight for that host: like `rv uninstall`, a
        // same-user agent must not do it unattended. A block that would stop
        // agents is permanent only with the owner's check at a terminal;
        // otherwise it ends on its own or waits for the owner (Q4).
        let outcome = await HostModeRun.setMode(
            hostMode, for: hookHost, env: env, json: format.json || format.robot,
            requester: .live(),
            authenticate: {
                // Loosening, or a permanent block at a terminal; with rvd
                // down the human confirms locally at a TTY
                // (DaemonDownOwnerConfirmation).
                try await CLIOwnerAuth.requireAuthenticatedOrLocalWhenDaemonDown(
                    reason: "Authenticate to set rv to \(hostMode.rawValue) for \(hookHost.rawValue).",
                    action: .hostMode(hostMode, host: hookHost))
            }
        )
        try CeremonyCLI.emit(outcome)
    }
}
