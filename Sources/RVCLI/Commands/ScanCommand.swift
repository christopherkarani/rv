import ArgumentParser
import Foundation
import RVDomain
import RVPolicy
import RVPresentation
import RVScan
import RVTheme
import RVTUI

extension ScanHostID: ExpressibleByArgument {}

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
        scanAll ? .all : ScanTimeWindow(dayCount: days)
    }

    func resolvedPackIDs() throws -> [PackID] {
        guard packs.isEmpty == false else { return dayOnePackIDs }
        var ids: [PackID] = []
        ids.reserveCapacity(packs.count)
        for token in packs {
            guard let id = PackID(validating: token) else {
                throw ValidationError("unknown pack id: \(token)")
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
        if flags.includeGlobs.isEmpty == false, path == nil {
            throw ValidationError("--include-glob requires a path argument")
        }
    }

    func run() async throws {
        let homePath = ProcessInfo.processInfo.environment["HOME"] ?? ""
        guard let scanHome = ScanHome(validating: homePath) else {
            FileHandle.standardError.write(Data("rv scan: HOME is not set\n".utf8))
            throw ExitCode(1)
        }
        let packIDs = try flags.resolvedPackIDs()
        let probe = ThemeProbeFactory.live(
            jsonFlag: format.json,
            robotFlag: format.robot,
            plainFlag: format.plain,
            noColorFlag: format.noColor
        )
        let appearance = CLIAppearance.resolve(probe: probe, requested: OutputModeResolver.requested(
            json: format.json,
            robot: format.robot
        ))
        let result: ScanRunResult
        do {
            result = try ScanRun.execute(
                ScanRun.Request(
                    rootPath: path,
                    home: scanHome,
                    hostFilter: flags.host,
                    timeWindow: flags.timeWindow,
                    packIDs: packIDs,
                    allEvents: flags.allEvents,
                    includeGlobs: flags.includeGlobs,
                    bounds: .default,
                    now: Date(),
                    fileManager: .default
                )
            )
        } catch ScanRun.Error.pathNotFound(let missing) {
            FileHandle.standardError.write(Data("rv scan: path not found: \(missing)\n".utf8))
            throw ExitCode(1)
        } catch ScanRun.Error.packsUnavailable {
            FileHandle.standardError.write(Data("rv scan: packs unavailable\n".utf8))
            throw ExitCode(1)
        } catch {
            throw error
        }
        let pathEntries = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let setupNudge = scanSetupNudgeRecommended(
            hosts: result.eventHosts,
            home: scanHome,
            pathEntries: pathEntries,
            fileManager: .default
        )
        let outcome = ScanRun.render(
            report: result.report,
            showCommand: flags.showCommand,
            failOnFindings: flags.failOnFindings,
            setupNudgeRecommended: setupNudge,
            appearance: appearance,
            probe: probe
        )
        if outcome.stdout.isEmpty == false {
            FileHandle.standardOutput.write(Data(outcome.stdout.utf8))
        }
        throw ExitCode(outcome.exitCode)
    }
}

struct ScanOutcome: Equatable, Sendable {
    var stdout: String
    var exitCode: Int32
}

struct ScanRunResult: Equatable, Sendable {
    var report: ScanReport
    var eventHosts: Set<ScanHostID>
}

enum ScanRun {
    struct Request {
        var rootPath: String?
        var home: ScanHome
        var hostFilter: ScanHostID?
        var timeWindow: ScanTimeWindow
        var packIDs: [PackID]
        var allEvents: Bool
        var includeGlobs: [String]
        var bounds: ScanBounds
        var now: Date
        var fileManager: FileManager

        static func fixture(
            rootPath: String? = nil,
            home: ScanHome,
            hostFilter: ScanHostID? = nil,
            timeWindow: ScanTimeWindow = .all,
            packIDs: [PackID] = dayOnePackIDs,
            allEvents: Bool = false,
            includeGlobs: [String] = [],
            bounds: ScanBounds = .default,
            now: Date = Date(),
            fileManager: FileManager = .default
        ) -> Request {
            Request(
                rootPath: rootPath,
                home: home,
                hostFilter: hostFilter,
                timeWindow: timeWindow,
                packIDs: packIDs,
                allEvents: allEvents,
                includeGlobs: includeGlobs,
                bounds: bounds,
                now: now,
                fileManager: fileManager
            )
        }
    }

    enum Error: Swift.Error, Equatable {
        case pathNotFound(String)
        case packsUnavailable
        case includeGlobRequiresPath
        case missingRoot
        case listingFailed(String)
    }

    static func run(_ request: Request) throws -> ScanReport {
        try execute(request).report
    }

    static func execute(_ request: Request) throws -> ScanRunResult {
        do {
            let result = try SessionScan().run(
                SessionScanRequest(
                    home: request.home,
                    now: request.now,
                    rootPath: request.rootPath,
                    includeGlobs: request.includeGlobs,
                    hostFilter: request.hostFilter,
                    days: request.timeWindow.dayCount,
                    scanAll: request.timeWindow.isDisabled,
                    packIDs: request.packIDs,
                    allEvents: request.allEvents,
                    bounds: request.bounds
                ),
                fileManager: request.fileManager
            )
            return ScanRunResult(report: result.report, eventHosts: result.eventHosts)
        } catch let error as SessionScanError {
            throw mapped(error)
        }
    }

    private static func mapped(_ error: SessionScanError) -> Error {
        switch error {
        case .pathNotFound(let path): .pathNotFound(path)
        case .packsUnavailable: .packsUnavailable
        case .includeGlobRequiresPath: .includeGlobRequiresPath
        case .missingRoot: .missingRoot
        case .listingFailed(let path): .listingFailed(path)
        }
    }

    static func render(
        report: ScanReport,
        showCommand: Bool,
        failOnFindings: Bool = false,
        setupNudgeRecommended: Bool = false,
        appearance: CLIAppearance,
        probe: ThemeProbe
    ) -> ScanOutcome {
        let exitCode: Int32 = (failOnFindings && report.findings.isEmpty == false) ? 2 : 0
        switch appearance {
        case .robot:
            return ScanOutcome(
                stdout: renderScanSessionsRobot(
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
                lines = scanBrowseRender(scanBrowseState(model: model), palette: palette)
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
    let setupHosts = Set(hosts.map(\.hookHost))
    guard setupHosts.isEmpty == false else { return false }
    guard let homeDirectory = HomeDirectory(validating: home.path) else { return false }
    guard let snapshot = try? HostAdapterInstallation.inspect(
        paths: OwnedPaths(home: homeDirectory),
        pathEntries: pathEntries,
        fileManager: fileManager
    ) else {
        return false
    }
    return setupHosts.contains { snapshot.state(for: $0) != .wired }
}

private extension ScanHostID {
    var hookHost: HookHost {
        switch self {
        case .claude: .claude
        case .pi: .pi
        case .grok: .grok
        case .opencode: .opencode
        case .openclaw: .openclaw
        case .hermes: .hermes
        case .codex: .codex
        case .cursor: .cursor
        }
    }
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
        showCommand: showCommand
    )
}

private func scanFindingRow(from finding: ScanFinding, showCommand: Bool) -> ScanFindingRow {
    scanFindingRow(
        host: finding.host,
        sessionID: finding.sessionID,
        sourcePath: finding.sourcePath,
        occurredAt: finding.occurredAt,
        ruleID: finding.ruleID,
        packID: finding.packID,
        matchingView: finding.matchingView,
        count: finding.count,
        lastSeen: finding.lastSeen,
        showCommand: showCommand
    )
}
