import Foundation

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

enum SetupHost: CaseIterable, Hashable, Sendable {
    case grok
    case pi
    case openCode

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

    func template(rvPath: String) throws -> String {
        switch self {
        case .grok: try HostTemplates.grokHook(rvPath: rvPath)
        case .pi: try HostTemplates.piExtension(rvPath: rvPath)
        case .openCode: try HostTemplates.openCodePlugin(rvPath: rvPath)
        }
    }

    func rawTemplate() throws -> String {
        switch self {
        case .grok: try HostTemplates.rawGrok()
        case .pi: try HostTemplates.rawPi()
        case .openCode: try HostTemplates.rawOpenCode()
        }
    }

    func isCurrent(_ existing: String, raw: String) -> Bool {
        HostTemplates.matchesCurrentTemplate(existing, raw: raw)
    }

    func isDetected(layout: HostLayout, env: SetupEnvironment, files: FileOps) -> Bool {
        files.isDirectory(directory(in: layout)) || env.pathEntries.contains { entry in
            env.fileManager.isExecutableFile(atPath: entry + "/" + toolName)
        }
    }
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
            rvPath: resolveRv(executable: executable, home: home, pathEntries: pathEntries),
            rvdPath: resolveRvd(nextTo: executable?.path, home: home, pathEntries: pathEntries)
                ?? (home + "/.local/bin/rvd"),
            fileManager: .default,
            launchctl: ProcessLaunchctl(),
            touchLaunchd: LoginHome.matchesProcessHome(home)
        )
    }

    static func resolveRv(
        executable: URL?,
        home: String,
        pathEntries: [String],
        fileManager: FileManager = .default
    ) -> String {
        if let executable, executable.lastPathComponent == "rv" {
            return executable.path
        }
        let local = home + "/.local/bin/rv"
        if fileManager.isExecutableFile(atPath: local) {
            return local
        }
        for entry in pathEntries {
            let candidate = entry + "/rv"
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return local
    }

    /// Prefer `rvd` next to the running `rv`, then `$HOME/.local/bin/rvd`, then PATH.
    static func resolveRvd(
        nextTo rvExecutable: String?,
        home: String,
        pathEntries: [String],
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
        for entry in pathEntries {
            let candidate = entry + "/rvd"
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}

enum SetupRun {
    static let hostlessLine = "Run rv setup after Pi, Grok, or OpenCode exists."
    static let grokRestartLine = "Reload /hooks or restart Grok."
    static let launchAgentLabel = "dev.rv.evaluate"

    static func setup(_ env: SetupEnvironment) -> SetupOutcome {
        let files = FileOps(fileManager: env.fileManager)
        let layout = HostLayout(home: env.home)
        var lines: [String] = []
        var wrote: Set<SetupHost> = []
        var detected: Set<SetupHost> = []

        do {
            try files.createDirectory(atPath: layout.configDirectory)
            try writeLaunchAgent(env: env, layout: layout, files: files)

            for host in SetupHost.allCases {
                guard host.isDetected(layout: layout, env: env, files: files) else { continue }
                detected.insert(host)
                let raw = try host.rawTemplate()
                switch try writeOwned(
                    path: host.ownedPath(in: layout),
                    contents: try host.template(rvPath: env.rvPath),
                    isCurrent: { host.isCurrent($0, raw: raw) },
                    files: files
                ) {
                case .wrote:
                    wrote.insert(host)
                case .unchanged:
                    break
                case .occupied:
                    lines.append(host.occupiedLine)
                }
            }

            if detected.isEmpty {
                lines.append(hostlessLine)
            } else if wrote.contains(.grok) {
                lines.append(grokRestartLine)
            }

            return SetupOutcome(stdout: join(lines), exitCode: 0)
        } catch {
            return SetupOutcome(stdout: "", stderr: "rv setup failed: \(error)\n", exitCode: 1)
        }
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
        let body = try HostTemplates.launchAgentPlist(rvdPath: env.rvdPath)
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

    private static func join(_ lines: [String]) -> String {
        if lines.isEmpty { return "" }
        return lines.joined(separator: "\n") + "\n"
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
