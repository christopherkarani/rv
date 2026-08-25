import ArgumentParser
import Darwin
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
        let report: ScanReport
        do {
            report = try ScanRun.run(
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
                    fileManager: .default,
                    pathEntries: (ProcessInfo.processInfo.environment["PATH"] ?? "")
                        .split(separator: ":")
                        .map(String.init)
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
        let outcome = ScanRun.render(
            report: report,
            showCommand: flags.showCommand,
            failOnFindings: flags.failOnFindings,
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
        var pathEntries: [String] = []
    }

    enum Error: Swift.Error, Equatable {
        case pathNotFound(String)
        case packsUnavailable
    }

    private static let adapters: [any SessionStoreAdapter] = [
        ClaudeSessionStoreAdapter(),
        PiStoreAdapter(),
        GrokStoreAdapter(),
        OpenCodeStoreAdapter(),
    ]

    static func run(_ request: Request) throws -> ScanReport {
        let selected = selectedAdapters(hostFilter: request.hostFilter)
        let walker = DirectoryWalker(bounds: request.bounds)
        var warnings: [ScanWarning] = []
        var candidates: [(url: URL, adapter: any SessionStoreAdapter)] = []
        var filesScanned = 0

        if let rootPath = request.rootPath {
            let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard request.fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                throw Error.pathNotFound(rootPath)
            }
            let walk = walker.walk(root: root, fileManager: request.fileManager)
            warnings.append(contentsOf: walk.warnings)
            filesScanned = walk.filesVisited
            for fileURL in walk.fileURLs {
                let recognized = selected.filter { $0.recognizes(fileURL: fileURL) }
                if recognized.isEmpty {
                    if matchesIncludeGlob(
                        fileURL: fileURL,
                        scanRoot: root,
                        patterns: request.includeGlobs
                    ) {
                        for adapter in selected {
                            candidates.append((fileURL, adapter))
                        }
                    }
                    continue
                }
                for adapter in recognized {
                    candidates.append((fileURL, adapter))
                }
            }
        } else {
            for adapter in selected {
                for root in adapter.roots(home: request.home) {
                    var isDirectory: ObjCBool = false
                    guard request.fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
                          isDirectory.boolValue
                    else {
                        continue
                    }
                    let walk = walker.walk(root: root, fileManager: request.fileManager)
                    warnings.append(contentsOf: walk.warnings)
                    filesScanned += walk.filesVisited
                    for fileURL in walk.fileURLs {
                        guard adapter.recognizes(fileURL: fileURL) else { continue }
                        candidates.append((fileURL, adapter))
                    }
                }
            }
        }

        var events: [ExtractedEvent] = []
        events.reserveCapacity(candidates.count)
        for candidate in candidates {
            let data = (try? Data(contentsOf: candidate.url)) ?? Data()
            events.append(
                contentsOf: try candidate.adapter.extract(fileURL: candidate.url, data: data)
            )
        }

        let classify: ScanClassify
        do {
            classify = try ScanClassify(enabledPacks: request.packIDs)
        } catch ScanClassifyError.packsUnavailable {
            throw Error.packsUnavailable
        }
        let resolver = fileInstantResolver(fileManager: request.fileManager)
        let rawFindings = classify.classify(events)
        let inWindow = request.timeWindow.filter(rawFindings, now: request.now, resolver: resolver)
        let findings = ScanDedupe.apply(inWindow, allEvents: request.allEvents, resolver: resolver)

        return ScanReport(
            findings: findings,
            warnings: warnings,
            filesScanned: filesScanned,
            eventsExtracted: events.count,
            setupNudgeRecommended: setupNudgeRecommended(
                events: events,
                home: request.home,
                pathEntries: request.pathEntries,
                fileManager: request.fileManager
            )
        )
    }

    static func render(
        report: ScanReport,
        showCommand: Bool,
        failOnFindings: Bool = false,
        appearance: CLIAppearance,
        probe: ThemeProbe
    ) -> ScanOutcome {
        let exitCode: Int32 = (failOnFindings && report.findings.isEmpty == false) ? 2 : 0
        switch appearance {
        case .robot:
            return ScanOutcome(
                stdout: renderScanSessionsRobot(from: report, showCommand: showCommand) + "\n",
                exitCode: exitCode
            )
        case .pretty(let palette):
            let model = scanViewModel(from: report, showCommand: showCommand)
            let lines: [String]
            if probe.isBrowseEligible {
                lines = scanBrowseRender(scanBrowseState(model: model), palette: palette)
            } else {
                lines = ScanPrettyRenderer().render(model, palette: palette)
            }
            return ScanOutcome(stdout: PrettyWriter.join(lines), exitCode: exitCode)
        }
    }

    private static func setupNudgeRecommended(
        events: [ExtractedEvent],
        home: ScanHome,
        pathEntries: [String],
        fileManager: FileManager
    ) -> Bool {
        let setupHosts = Set(events.compactMap(\.host.setupHostKind))
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

    private static func selectedAdapters(hostFilter: ScanHostID?) -> [any SessionStoreAdapter] {
        guard let hostFilter else { return adapters }
        return adapters.filter { $0.host == hostFilter }
    }

    private static func fileInstantResolver(fileManager: FileManager) -> ScanFindingInstantResolver {
        ScanFindingInstantResolver { path in
            let url = URL(fileURLWithPath: path)
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            return values?.contentModificationDate
        }
    }
}

private extension ScanHostID {
    /// v1 setup/doctor Hosts only. Claude has session forensics without a Host adapter install path.
    var setupHostKind: SetupHostKind? {
        switch self {
        case .claude:
            nil
        case .pi:
            .pi
        case .grok:
            .grok
        case .opencode:
            .openCode
        }
    }
}

private func matchesIncludeGlob(fileURL: URL, scanRoot: URL, patterns: [String]) -> Bool {
    guard patterns.isEmpty == false else { return false }
    let relative = relativePath(fileURL: fileURL, to: scanRoot)
    let name = fileURL.lastPathComponent
    for pattern in patterns {
        if fnmatch(pattern, relative, FNM_PATHNAME) == 0 { return true }
        if fnmatch(pattern, name, 0) == 0 { return true }
    }
    return false
}

private func relativePath(fileURL: URL, to root: URL) -> String {
    let rootPath = root.standardizedFileURL.path
    let filePath = fileURL.standardizedFileURL.path
    guard filePath.hasPrefix(rootPath) else { return fileURL.lastPathComponent }
    var suffix = String(filePath.dropFirst(rootPath.count))
    if suffix.hasPrefix("/") {
        suffix.removeFirst()
    }
    return suffix.isEmpty ? fileURL.lastPathComponent : suffix
}
