import Foundation
import RVHooks
import RVPresentation

struct SetupOutcome: Equatable, Sendable {
    var stdout: String
    var stderr: String
    var exitCode: Int32

    init(stdout: String, stderr: String = "", exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }

    static let ok = SetupOutcome(stdout: "", exitCode: 0)
}

extension SetupHostKind {
    fileprivate static let rvPathMarker = "__RV_SETUP_BINARY_PATH__"

    var toolName: String {
        switch self {
        case .grok: "grok"
        case .pi: "pi"
        case .openCode: "opencode"
        }
    }

    var occupiedLine: String {
        switch self {
        case .grok: "Skipped occupied grok hook."
        case .pi: "Skipped occupied pi hook."
        case .openCode: "Skipped occupied opencode hook."
        }
    }

    func directory(in layout: HostLayout) -> String {
        switch self {
        case .grok: layout.grokDirectory
        case .pi: layout.piDirectory
        case .openCode: layout.openCodeDirectory
        }
    }

    func ownedPath(in layout: HostLayout) -> String {
        switch self {
        case .grok: layout.grokHook
        case .pi: layout.piExtension
        case .openCode: layout.openCodePlugin
        }
    }

    func adapterResource() throws -> HostAdapterResource {
        try HostAdapterResources.load(for: hookHost)
    }

    private var hookHost: HookHost {
        switch self {
        case .grok: .grok
        case .pi: .pi
        case .openCode: .opencode
        }
    }

    func isDetected(layout: HostLayout, env: SetupEnvironment, files: FileOps) -> Bool {
        files.isDirectory(directory(in: layout)) || env.pathEntries.contains { entry in
            env.fileManager.isExecutableFile(atPath: entry + "/" + toolName)
        }
    }
}

private func matchesCurrentTemplate(
    _ existing: String,
    marked: String,
    marker: String
) -> Bool {
    let parts = marked.components(separatedBy: marker)
    guard parts.count > 1 else { return existing == marked }
    let prefix = parts[0]
    guard existing.hasPrefix(prefix) else { return false }
    let afterPrefix = existing.dropFirst(prefix.count)
    let second = parts[1]
    let substitution: String
    if second.isEmpty {
        substitution = String(afterPrefix)
    } else {
        guard let range = afterPrefix.range(of: second) else { return false }
        substitution = String(afterPrefix[..<range.lowerBound])
    }
    return parts.joined(separator: substitution) == existing
}

struct SetupEnvironment {
    var home: String
    var pathEntries: [String]
    var rvPath: String
    var rvdPath: String
    var fileManager: FileManager
    var launchctl: any LaunchctlApplying
    var touchLaunchd: Bool

    static func live(environment: [String: String] = ProcessInfo.processInfo.environment) -> SetupEnvironment? {
        guard let home = environment["HOME"], home.isEmpty == false else { return nil }
        let pathEntries = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let executable = Bundle.main.executableURL
        return SetupEnvironment(
            home: home,
            pathEntries: pathEntries,
            rvPath: resolveRv(home: home),
            rvdPath: resolveRvd(nextTo: executable?.path, home: home)
                ?? (home + "/.local/bin/rvd"),
            fileManager: .default,
            launchctl: ProcessLaunchctl(),
            touchLaunchd: LoginHome.matchesProcessHome(home)
        )
    }

    /// Curl install bakes `$HOME/.local/bin/rv`. Do not walk PATH.
    static func resolveRv(home: String) -> String {
        home + "/.local/bin/rv"
    }

    /// Prefer `rvd` next to the running `rv`, then `$HOME/.local/bin/rvd`.
    static func resolveRvd(
        nextTo rvExecutable: String?,
        home: String,
        fileManager: FileManager = .default
    ) -> String? {
        if let rvExecutable {
            let sibling = (rvExecutable as NSString).deletingLastPathComponent + "/rvd"
            if fileManager.isExecutableFile(atPath: sibling) {
                return sibling
            }
        }
        let local = home + "/.local/bin/rvd"
        if fileManager.isExecutableFile(atPath: local) {
            return local
        }
        return nil
    }
}

enum SetupRun {
    static let hostlessLine = "Run rv setup after Pi, Grok, or OpenCode exists."
    static let robotCompleteLine = "Setup complete. Next  rv test 'git reset --hard'."
    static let launchAgentLabel = "dev.rv.evaluate"

    static func setup(
        _ env: SetupEnvironment,
        appearance: SetupAppearance = .robot
    ) -> SetupOutcome {
        do {
            let report = try perform(env)
            return SetupOutcome(
                stdout: SetupFormat.stdout(report: report, appearance: appearance),
                exitCode: 0
            )
        } catch {
            return SetupOutcome(stdout: "", stderr: "rv setup failed: \(error)\n", exitCode: 1)
        }
    }

    private static func perform(_ env: SetupEnvironment) throws -> SetupReport {
        let files = FileOps(fileManager: env.fileManager)
        let layout = HostLayout(home: env.home)
        var kinds: [SetupHostKind: SetupSlotKind] = [
            .grok: .pending,
            .pi: .pending,
            .openCode: .pending,
        ]
        var wrote: Set<SetupHostKind> = []

        try files.createDirectory(atPath: layout.configDirectory)
        try writeLaunchAgent(env: env, layout: layout, files: files)

        for host in SetupHostKind.allCases {
            guard host.isDetected(layout: layout, env: env, files: files) else { continue }
            let adapter = try host.adapterResource()
            let marked = adapter.rendered(rvPath: SetupHostKind.rvPathMarker)
            switch try writeOwned(
                path: host.ownedPath(in: layout),
                contents: adapter.rendered(rvPath: env.rvPath),
                isCurrent: {
                    matchesCurrentTemplate(
                        $0,
                        marked: marked,
                        marker: SetupHostKind.rvPathMarker
                    )
                },
                files: files
            ) {
            case .wrote:
                wrote.insert(host)
                kinds[host] = .wired
            case .unchanged:
                kinds[host] = .wired
            case .occupied:
                kinds[host] = .occupied
            }
        }

        return SetupReport(
            grok: kinds[.grok] ?? .pending,
            pi: kinds[.pi] ?? .pending,
            openCode: kinds[.openCode] ?? .pending,
            wrote: wrote
        )
    }

    static func uninstall(_ env: SetupEnvironment) -> SetupOutcome {
        let files = FileOps(fileManager: env.fileManager)
        let layout = HostLayout(home: env.home)
        let owned = [
            layout.grokHook,
            layout.piExtension,
            layout.openCodePlugin,
            layout.launchAgent,
            layout.localRv,
            layout.localRvd,
        ]
        for path in owned {
            files.removeFile(atPath: path)
        }
        files.removeDirectoryIfExists(atPath: layout.configDirectory)
        if env.touchLaunchd {
            try? env.launchctl.bootout(domain: "gui/\(getuid())", label: launchAgentLabel)
        }
        if owned.contains(where: { files.fileExists($0) }) {
            return SetupOutcome(
                stdout: "",
                stderr: "rv uninstall failed: owned path still exists\n",
                exitCode: 1
            )
        }
        return .ok
    }

    private static func writeLaunchAgent(env: SetupEnvironment, layout: HostLayout, files: FileOps) throws {
        guard env.fileManager.isExecutableFile(atPath: env.rvdPath) else {
            return
        }
        let body = try LaunchAgentTemplate.rendered(rvdPath: env.rvdPath)
        try files.write(body, to: layout.launchAgent)
        if env.touchLaunchd {
            let url = URL(fileURLWithPath: layout.launchAgent)
            try? env.launchctl.bootout(domain: "gui/\(getuid())", label: launchAgentLabel)
            try env.launchctl.bootstrap(domain: "gui/\(getuid())", plist: url)
        }
    }

    private enum WriteKind {
        case wrote
        case unchanged
        case occupied
    }

    private static func writeOwned(
        path: String,
        contents: String,
        isCurrent: (String) -> Bool,
        files: FileOps
    ) throws -> WriteKind {
        guard files.fileExists(path) else {
            try files.write(contents, to: path)
            return .wrote
        }
        guard let existingData = files.readData(path) else {
            return .occupied
        }
        if existingData == Data(contents.utf8) {
            return .unchanged
        }
        if let existing = String(data: existingData, encoding: .utf8), isCurrent(existing) {
            try files.write(contents, to: path)
            return .wrote
        }
        return .occupied
    }
}

struct FileOps {
    var fileManager: FileManager

    func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    func fileExists(_ path: String) -> Bool {
        fileManager.fileExists(atPath: path)
    }

    func readData(_ path: String) -> Data? {
        fileManager.contents(atPath: path)
    }

    func write(_ contents: String, to path: String) throws {
        try createDirectory(atPath: (path as NSString).deletingLastPathComponent)
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func createDirectory(atPath path: String) throws {
        try fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    func removeFile(atPath path: String) {
        guard fileManager.fileExists(atPath: path) else { return }
        try? fileManager.removeItem(atPath: path)
    }

    func removeDirectoryIfExists(atPath path: String) {
        guard isDirectory(path) else { return }
        try? fileManager.removeItem(atPath: path)
    }
}
