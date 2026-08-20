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
    var occupiedLine: String {
        switch self {
        case .grok: "Skipped occupied grok hook."
        case .pi: "Skipped occupied pi hook."
        case .openCode: "Skipped occupied opencode hook."
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
        appearance: CLIAppearance = .robot
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
        let layout = OwnedPaths(home: env.home)
        let installations = try HostAdapterInstallation.inspect(
            paths: layout,
            pathEntries: env.pathEntries,
            fileManager: env.fileManager
        )
        var kinds: [SetupHostKind: SetupSlotKind] = [
            .grok: .pending,
            .pi: .pending,
            .openCode: .pending,
        ]
        var wrote: Set<SetupHostKind> = []

        try files.createDirectory(atPath: layout.configDirectory)
        try writeLaunchAgent(env: env, layout: layout, files: files)

        for owned in layout.hostAdapters {
            let host = owned.host
            let installation = installations.installation(for: host)
            let existingData: Data?
            switch installation {
            case .missing:
                continue
            case .occupied:
                kinds[host] = .occupied
                continue
            case .absentFile:
                existingData = nil
            case .broken(_, let data), .wired(_, let data):
                existingData = data
            }
            let adapter = try HostAdapterResources.load(for: owned.hookHost)
            if try writeOwned(
                path: owned.destination,
                contents: adapter.rendered(rvPath: env.rvPath),
                existingData: existingData,
                files: files
            ) {
                wrote.insert(host)
            }
            kinds[host] = .wired
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
        let layout = OwnedPaths(home: env.home)
        let installations: HostAdapterInstallationSnapshot
        do {
            installations = try HostAdapterInstallation.inspect(
                paths: layout,
                pathEntries: env.pathEntries,
                fileManager: env.fileManager
            )
        } catch {
            return SetupOutcome(
                stdout: "",
                stderr: "rv uninstall failed: unable to inspect Host adapters\n",
                exitCode: 1
            )
        }
        var removedPaths = [layout.launchAgent, layout.localRv, layout.localRvd]
        for owned in layout.hostAdapters {
            switch installations.installation(for: owned.host) {
            case .broken, .wired:
                removedPaths.append(owned.destination)
            case .missing, .absentFile, .occupied:
                break
            }
        }
        for path in removedPaths {
            files.removeFile(atPath: path)
        }
        files.removeDirectoryIfEmpty(atPath: layout.configDirectory)
        if env.touchLaunchd {
            try? env.launchctl.bootout(domain: "gui/\(getuid())", label: launchAgentLabel)
        }
        if removedPaths.contains(where: { files.fileExists($0) }) {
            return SetupOutcome(
                stdout: "",
                stderr: "rv uninstall failed: owned path still exists\n",
                exitCode: 1
            )
        }
        return .ok
    }

    private static func writeLaunchAgent(env: SetupEnvironment, layout: OwnedPaths, files: FileOps) throws {
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

    /// Writes `contents` when missing or different. Returns whether a write occurred.
    private static func writeOwned(
        path: String,
        contents: String,
        existingData: Data?,
        files: FileOps
    ) throws -> Bool {
        let payload = Data(contents.utf8)
        if existingData == payload {
            return false
        }
        try files.write(contents, to: path)
        return true
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

    func removeDirectoryIfEmpty(atPath path: String) {
        guard isDirectory(path) else { return }
        guard let contents = try? fileManager.contentsOfDirectory(atPath: path), contents.isEmpty else {
            return
        }
        try? fileManager.removeItem(atPath: path)
    }
}
