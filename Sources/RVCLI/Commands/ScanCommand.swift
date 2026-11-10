import ArgumentParser
import Foundation
import RVDomain
import RVPolicy
import RVPresentation
import RVScan
import RVService
import RVTheme
import RVTUI

struct ScanSessionsFlags: ParsableArguments {
    @Option(name: .customLong("host"), help: "Restrict to one host session store.")
    var host: ScanHostID?

    @Option(name: .customLong("days"), help: "Include findings from the last N days (default 7).")
    var days: UInt = ScanTimeWindow.defaultDayCount

    @Flag(name: .customLong("all"), help: "Disable the time window filter.")
    var scanAll = false

    @Option(
        name: .customLong("packs"),
        parsing: .upToNextOption,
        help: "Pack IDs to evaluate (default: day-one packs)."
    )
    var packs: [String] = []

    @Flag(name: .customLong("show-command"), help: "Print full matching-view command text.")
    var showCommand = false

    @Flag(name: .customLong("all-events"), help: "Emit one row per deny event (skip dedupe).")
    var allEvents = false

    @Flag(name: .customLong("fail-on-findings"), help: "Exit 2 when deny findings exist.")
    var failOnFindings = false

    @Option(name: .customLong("include-glob"), help: "Extra glob patterns under an explicit path.")
    var includeGlobs: [String] = []

    var timeWindow: ScanTimeWindow {
        scanAll ? .all : .lastDays(days)
    }

    /// Packs to scan with. Without `--packs`, the owner's configured packs,
    /// so scan reports what the live gate would deny rather than only the
    /// three day-one packs. `--packs` IDs must name bundled packs: an
    /// unknown ID used to be accepted and silently match nothing.
    func resolvedPackIDs(home: HomeDirectory? = nil) throws -> [PackID] {
        guard packs.isEmpty == false else {
            guard let home else { return dayOnePackIDs }
            // Exactly what the evaluation doors walk: the owner's packs
            // plus the organization's required packs.
            return EvaluationWorld.walkedPackIDs(home: home).ids
        }
        let known: Set<PackID>? = home.flatMap { home in
            (try? PacksFacade.makeCatalog(home: home)).map { Set($0.records.map(\.id)) }
        }
        var ids: [PackID] = []
        ids.reserveCapacity(packs.count)
        for token in packs {
            guard let id = PackID(validating: token), known?.contains(id) ?? true else {
                throw ValidationError("unknown pack id: \(DisplayedText.field(token))")
            }
            ids.append(id)
        }
        return ids
    }
}

struct Scan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "Offline session forensics for deny-only findings.",
        subcommands: [ScanSessions.self],
        defaultSubcommand: ScanSessions.self
    )
}

struct ScanSessions: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sessions",
        abstract: "Scan agent session stores for deny-only findings."
    )

    @Argument(help: "Directory tree with known session layouts.")
    var path: String?

    @OptionGroup
    var flags: ScanSessionsFlags

    @OptionGroup
    var format: FormatFlags

    func validate() throws {
        // Hosts without a session reader (Antigravity, Muse) used to be
        // accepted and silently scan nothing.
        if let host = flags.host, SessionScanAdapters.adapters(for: host).isEmpty {
            let supported = SessionScanAdapters.all.map { $0.host.rawValue }.joined(separator: ", ")
            throw ValidationError("rv scan cannot read \(host.rawValue) sessions yet; supported hosts: \(supported)")
        }
        if flags.includeGlobs.isEmpty == false, path == nil {
            throw ValidationError("--include-glob requires a path argument")
        }
    }

    func run() async throws {
        let ctx = CommandContext.current(command: "scan", format: format)
        let scanHome = try ctx.requireHome()
        let packIDs = try flags.resolvedPackIDs(home: HomeDirectory(validating: scanHome.path))
        let result: SessionScanResult
        do {
            result = try SessionScan().run(
                SessionScanRequest(
                    home: scanHome,
                    now: Date(),
                    rootPath: path,
                    includeGlobs: flags.includeGlobs,
                    hostFilter: flags.host,
                    timeWindow: flags.timeWindow,
                    packIDs: packIDs,
                    reportsEveryEvent: flags.allEvents
                )
            )
        } catch SessionScanError.pathNotFound(let missing) {
            try ctx.fail("rv scan: path not found: \(DisplayedText.field(missing))\n")
        } catch SessionScanError.listingFailed(let path) {
            try ctx.fail("rv scan: listing failed: \(DisplayedText.field(path))\n")
        } catch SessionScanError.unreadableStore(let path) {
            try ctx.fail("rv scan: unreadable store: \(DisplayedText.field(path))\n")
        } catch SessionScanError.prepareFailed(let path) {
            try ctx.fail("rv scan: prepare failed: \(DisplayedText.field(path))\n")
        } catch SessionScanError.packsUnavailable {
            try ctx.fail("rv scan: packs unavailable\n")
        } catch {
            throw error
        }
        let pathEntries = (CLIProcess.environment()["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let setupNudge = scanSetupNudgeRecommended(
            hosts: result.eventHosts,
            home: scanHome,
            pathEntries: pathEntries,
            fileManager: .default
        )
        let outcome = try ScanRun.render(
            report: result.report,
            showCommand: flags.showCommand,
            failOnFindings: flags.failOnFindings,
            setupNudgeRecommended: setupNudge,
            appearance: ctx.appearance,
            probe: ctx.probe
        )
        try ctx.emit(stdout: outcome.stdout, exitCode: outcome.exitCode)
    }
}

struct ScanOutcome: Equatable, Sendable {
    var stdout: String
    var exitCode: Int32
}

/// Rendering plus the fail-on-findings exit code; scanning itself is
/// the RVScan seam (`SessionScan`).
enum ScanRun {
    static func render(
        report: ScanReport,
        showCommand: Bool,
        failOnFindings: Bool = false,
        setupNudgeRecommended: Bool = false,
        appearance: CLIAppearance,
        probe: ThemeProbe
    ) throws -> ScanOutcome {
        let exitCode: Int32 = (failOnFindings && report.findings.isEmpty == false) ? 2 : 0
        switch appearance {
        case .robot:
            return ScanOutcome(
                stdout: try renderScanSessionsRobot(
                    from: report,
                    showCommand: showCommand,
                    setupNudge: setupNudgeRecommended
                ) + "\n",
                exitCode: exitCode
            )
        case .pretty(let palette):
            let model = scanCommandViewModel(
                from: report,
                showCommand: showCommand,
                setupNudgeRecommended: setupNudgeRecommended
            )
            let lines: [String]
            if probe.isBrowseEligible {
                lines = ScanBrowseRenderer().render(ScanBrowseState(model: model), palette: palette)
            } else {
                lines = ScanPrettyRenderer().render(model, palette: palette)
            }
            return ScanOutcome(stdout: PrettyWriter.join(lines), exitCode: exitCode)
        }
    }
}

func scanSetupNudgeRecommended(
    hosts: Set<ScanHostID>,
    home: ScanHome,
    pathEntries: [String],
    fileManager: FileManager
) -> Bool {
    guard hosts.isEmpty == false else { return false }
    guard let homeDirectory = HomeDirectory(validating: home.path) else { return false }
    guard let snapshot = try? HostAdapterInstallation.inspect(
        paths: OwnedPaths(home: homeDirectory),
        pathEntries: pathEntries,
        fileManager: fileManager
    ) else {
        return false
    }
    return hosts.contains { snapshot.state(for: $0) != .wired }
}

private func scanCommandViewModel(
    from report: ScanReport,
    showCommand: Bool,
    setupNudgeRecommended: Bool
) -> ScanViewModel {
    ScanViewModel(
        rows: report.findings.map { scanFindingRow(from: $0, showCommand: showCommand) },
        warnings: report.warnings.map { ScanWarningRow(code: $0.code, message: $0.message) },
        filesScanned: report.filesScanned,
        eventsExtracted: report.eventsExtracted,
        setupNudgeRecommended: setupNudgeRecommended,
        showsCommand: showCommand
    )
}

private func scanFindingRow(from finding: ScanFinding, showCommand: Bool) -> ScanFindingRow {
    scanFindingRow(
        host: finding.host,
        sessionID: finding.sessionID?.rawValue,
        sourcePath: finding.sourcePath,
        occurredAt: finding.occurredAt,
        ruleID: finding.ruleID,
        matchingView: finding.matchingView,
        count: finding.count,
        lastSeen: finding.lastSeen,
        showsCommand: showCommand
    )
}
