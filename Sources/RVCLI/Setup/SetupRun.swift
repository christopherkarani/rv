import Foundation

struct SetupOutcome: Equatable, Sendable {
    var stdout: String
    var exitCode: Int32

    static let ok = SetupOutcome(stdout: "", exitCode: 0)
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
        return SetupEnvironment(
            home: home,
            pathEntries: pathEntries,
            rvPath: resolveBinary(named: "rv", home: home, pathEntries: pathEntries),
            rvdPath: resolveBinary(named: "rvd", home: home, pathEntries: pathEntries),
            fileManager: .default,
            launchctl: ProcessLaunchctl(),
            touchLaunchd: LoginHome.matchesProcessHome(home)
        )
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
        var wiredNewHost = false

        do {
            try files.createDirectory(atPath: layout.configDirectory)
            try writeLaunchAgent(env: env, layout: layout, files: files)

            let grok = detected(directory: layout.grokDirectory, tool: "grok", env: env, files: files)
            let pi = detected(directory: layout.piDirectory, tool: "pi", env: env, files: files)
            let openCode = detected(directory: layout.openCodeDirectory, tool: "opencode", env: env, files: files)

            if grok {
                switch try writeOwned(
                    path: layout.grokHook,
                    contents: try HostTemplates.grokHook(rvPath: env.rvPath),
                    isCurrent: HostTemplates.isCurrentGrokHook,
                    files: files
                ) {
                case .wrote:
                    wiredNewHost = true
                case .unchanged:
                    break
                case .occupied:
                    lines.append("Skipped occupied grok hook.")
                }
            }

            if pi {
                switch try writeOwned(
                    path: layout.piExtension,
                    contents: try HostTemplates.piExtension(rvPath: env.rvPath),
                    isCurrent: HostTemplates.isCurrentPiExtension,
                    files: files
                ) {
                case .wrote:
                    wiredNewHost = true
                case .unchanged:
                    break
                case .occupied:
                    lines.append("Skipped occupied pi hook.")
                }
            }

            if openCode {
                switch try writeOwned(
                    path: layout.openCodePlugin,
                    contents: try HostTemplates.openCodePlugin(rvPath: env.rvPath),
                    isCurrent: HostTemplates.isCurrentOpenCodePlugin,
                    files: files
                ) {
                case .wrote:
                    wiredNewHost = true
                case .unchanged:
                    break
                case .occupied:
                    lines.append("Skipped occupied opencode hook.")
                }
            }

            if grok == false && pi == false && openCode == false {
                lines.append(hostlessLine)
            } else if wiredNewHost && grok {
                lines.append(grokRestartLine)
            }

            return SetupOutcome(stdout: join(lines), exitCode: 0)
        } catch {
            return SetupOutcome(stdout: "rv setup failed\n", exitCode: 1)
        }
    }

    static func uninstall(_ env: SetupEnvironment) -> SetupOutcome {
        let files = FileOps(fileManager: env.fileManager)
        let layout = HostLayout(home: env.home)
        files.removeFile(atPath: layout.grokHook)
        files.removeFile(atPath: layout.piExtension)
        files.removeFile(atPath: layout.openCodePlugin)
        files.removeFile(atPath: layout.launchAgent)
        files.removeFile(atPath: layout.localRv)
        files.removeFile(atPath: layout.localRvd)
        files.removeDirectoryIfExists(atPath: layout.configDirectory)
        if env.touchLaunchd {
            try? env.launchctl.bootout(domain: "gui/\(getuid())", label: launchAgentLabel)
        }
        return .ok
    }

    private static func writeLaunchAgent(env: SetupEnvironment, layout: HostLayout, files: FileOps) throws {
        let body = try HostTemplates.launchAgentPlist(rvdPath: env.rvdPath)
        try files.write(body, to: layout.launchAgent)
        if env.touchLaunchd {
            let url = URL(fileURLWithPath: layout.launchAgent)
            try? env.launchctl.bootout(domain: "gui/\(getuid())", label: launchAgentLabel)
            try env.launchctl.bootstrap(domain: "gui/\(getuid())", plist: url)
        }
    }

    private static func detected(directory: String, tool: String, env: SetupEnvironment, files: FileOps) -> Bool {
        files.isDirectory(directory) || env.pathEntries.contains { entry in
            env.fileManager.isExecutableFile(atPath: entry + "/" + tool)
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
        if let existing = files.read(path) {
            if existing == contents {
                return .unchanged
            }
            if isCurrent(existing) {
                try files.write(contents, to: path)
                return .wrote
            }
            return .occupied
        }
        try files.write(contents, to: path)
        return .wrote
    }

    private static func join(_ lines: [String]) -> String {
        if lines.isEmpty { return "" }
        return lines.joined(separator: "\n") + "\n"
    }
}

private func resolveBinary(named name: String, home: String, pathEntries: [String]) -> String {
    if let exe = Bundle.main.executableURL, exe.lastPathComponent == name {
        return exe.path
    }
    let local = home + "/.local/bin/" + name
    if FileManager.default.isExecutableFile(atPath: local) {
        return local
    }
    for entry in pathEntries {
        let candidate = entry + "/" + name
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }
    return local
}

struct FileOps {
    var fileManager: FileManager

    func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    func read(_ path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
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
