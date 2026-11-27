import Foundation
import RVDomain
import RVHistory
import RVIsolation
import RVPolicy
import RVPresentation
import RVTheme
import RVTUI

/// Bare `rv` on a terminal: who's covered, today, the last stop, secrets
/// and console (Q3). Pipes and scripts never get here; `rv/main.swift`
/// prints help for them. Every read is local and quick: one rvd snapshot
/// (no pack compile), the host files, the denial ledger, and secret names.
/// No secret value is ever read: only `secrets.json`'s names are counted.
public enum BareStatus {
    /// Prints the status to stdout. Exits 0 whatever it finds: it answers a
    /// question, it is not a check (`rv doctor` is the check).
    public static func run() async {
        let ctx = CommandContext.current(command: "rv", json: false, robot: false, plain: false, noColor: false)
        guard let home = ctx.home else {
            _ = HelpDispatch.tryEmit(arguments: [])
            return
        }
        let inputs = await StatusRun.gather(
            home: home,
            client: ServiceClient.probing(home: home),
            environment: CLIProcess.environment()
        )
        ctx.writeStdout(StatusRun.text(inputs, palette: ctx.appearance.palette))
    }
}

enum StatusRun {
    static func text(
        _ inputs: StatusInputs, now: Date = Date(), calendar: Calendar = .current,
        palette: Palette
    ) -> String {
        PrettyWriter.join(StatusRenderer().render(StatusViewModel(inputs, now: now, calendar: calendar), palette: palette))
    }

    /// Reads everything bare `rv` shows. rvd's snapshot runs while the
    /// files are read.
    static func gather(
        home: HomeDirectory,
        client: ServiceClient,
        environment: [String: String],
        fileManager: FileManager = .default,
        now: Date = Date()
    ) async -> StatusInputs {
        async let diagnostics = client.diagnostics(checkingLocalPacks: false)
        let paths = OwnedPaths(home: home)
        let configDirectory = RVPolicyPaths.configDirectory(home: home)
        let pathEntries = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let agents = wiredAgents(home: home, paths: paths, pathEntries: pathEntries, fileManager: fileManager)
        let recorded = DenialLedgerPreferences.isEnabled(inConfigDirectory: configDirectory)
        let events = recorded
            ? DenialLedger(configDirectory: configDirectory).records(asOf: now).map(event)
            : []
        let secrets = (try? SecretsConfiguration.load(configDirectory: configDirectory).get())?.secrets.count ?? 0
        let console = consoleConnected(home: home, configDirectory: configDirectory, fileManager: fileManager)
        let health = ServiceHealth.inspect(
            await diagnostics,
            launchAgentInstalled: fileManager.fileExists(atPath: paths.evaluateServiceFile),
            launchAgentLoaded: false
        )
        return StatusInputs(
            version: ProductVersion.semver,
            service: service(health),
            agents: agents,
            events: events,
            eventsRecorded: recorded,
            secrets: secrets,
            consoleConnected: console
        )
    }

    static func service(_ health: ServiceHealth) -> StatusService {
        switch health {
        case .reachable: .running
        case .notInstalled: .notInstalled
        case .down, .skew, .requestFailed: .down
        }
    }

    /// Wired agents and the mode rvd applies to each. The CLI's own
    /// environment is left out: `RV_GUARD_MODE` here says nothing about
    /// rvd's, and status must never claim guarding it cannot see.
    static func wiredAgents(
        home: HomeDirectory, paths: OwnedPaths, pathEntries: [String], fileManager: FileManager
    ) -> [HookHost: GuardMode] {
        guard let snapshot = try? HostAdapterInstallation.inspect(
            paths: paths, pathEntries: pathEntries, fileManager: fileManager
        ) else { return [:] }
        let config = GuardConfig.read(home: home)
        var agents: [HookHost: GuardMode] = [:]
        for host in HookHost.setupSlotOrder where snapshot.installation(for: host).state == .wired {
            agents[host] = GuardModeResolution.resolve(config, host: host, environment: [:])
        }
        return agents
    }

    /// A ledger row as status shows it: the rule, or the tool and its
    /// redacted path. The ledger holds no argv, so no command text (and no
    /// secret in one) can reach the screen from here.
    static func event(_ record: DenialLedgerRecord) -> StatusEvent {
        let what: String
        switch record.tool {
        case .bash:
            what = DisplayedText.field(record.ruleID.rawValue)
        case .file:
            what = record.tool.rawValue + " " + DisplayedText.field(record.path)
        }
        return StatusEvent(
            time: record.timestamp,
            agent: record.host.rawValue,
            stopped: record.observed == false,
            isJudgeNote: record.observed && record.category == .pack(.coreJudge),
            what: what
        )
    }

    /// The console counts as connected once audit forwarding is installed
    /// (the LaunchAgent) or has run (a cursor under `audit-forward/`).
    static func consoleConnected(home: HomeDirectory, configDirectory: URL, fileManager: FileManager) -> Bool {
        let agent = URL(fileURLWithPath: home.rawValue, isDirectory: true)
            .appendingPathComponent("Library/LaunchAgents/\(AuditForwardInstall.label).plist")
        if fileManager.fileExists(atPath: agent.path) { return true }
        let state = AuditForwardRun.stateDirectory(configDirectory)
        let files = (try? fileManager.contentsOfDirectory(atPath: state.path)) ?? []
        return files.contains { $0.hasSuffix(".json") }
    }
}
