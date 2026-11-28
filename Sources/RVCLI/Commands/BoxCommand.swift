import ArgumentParser
import Foundation
import RVDomain
import RVIsolation
import RVPolicy
import RVPresentation
import RVTheme
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// `rv box <agent>`: one front door over `rv workspace run`. It finds the
/// project, the agent and the resource profile, then launches exactly as
/// `rv workspace run` would; the workspace host enforces every wall.
///
/// `list` and `setup mac` are read from the captured words: a passthrough
/// capture takes every word after the flags, a subcommand name included.
struct BoxCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "box",
        abstract: "Run an agent in a box for this project."
    )

    static let usage = [
        HelpRow(
            name: "rv box [--linux | --mac] [--profile <id>] [<agent> [args...]]",
            description: "Run an agent in a box for this repo, found on your PATH; with no agent, open the box shell"),
        HelpRow(
            name: "rv box [--linux | --mac] [--profile <id>] -- <command> [args...]",
            description: "Run any command in the box"),
        HelpRow(name: "rv box list [--json]", description: "Every box, any strength, newest first; --json writes schema rv.boxes.v1"),
        HelpRow(name: "rv box setup mac", description: "Build the Mac box image now, in the foreground (about 26 GB)"),
        HelpRow(name: "rv box tidy [--yes]", description: "Move old box images to a 7-day trash; boxes with unsaved work are never touched"),
    ]

    static let flags = [
        HelpRow(name: "--linux", description: "A network-less Linux micro-VM booted from \(BoxWall.linuxImage), fetched once (macOS 26+, Apple silicon); a bare name runs from the VM's PATH"),
        HelpRow(name: "--mac", description: "A network-less macOS VM cloned from the Mac box image (macOS 27); build it once with rv box setup mac"),
        HelpRow(name: "--verbose", description: "When a box can't start, also print the workspace host's own words"),
        HelpRow(name: "--profile", description: "Resource profile to stage. Default: the one profile that serves this agent here, else the defaultProfile in runtime-resources.json, else none. A VM box never stages a profile that shares host files"),
    ]

    /// Words offered after `rv box`: the known agents, `list` and `setup`.
    static let completions = RuntimeAgentEntries.known + ["list", "setup", "tidy"]

    @Flag(name: .long, help: "Run in a network-less Linux micro-VM.")
    var linux = false

    @Flag(name: .long, help: "Run in a network-less macOS VM.")
    var mac = false

    @Option(name: .long, help: "Owner resource profile ID to stage. Default: the profile that serves this agent here.")
    var profile: String?

    @Flag(name: .long, help: "When a box can't start, also print the workspace host's own words.")
    var verbose = false

    @Argument(
        parsing: .captureForPassthrough,
        help: "An agent name and its arguments, -- and a command, list, tidy, or setup mac.",
        completion: .list(BoxCommand.completions))
    var words: [String] = []

    func run() async throws {
        let target: BoxTarget
        switch BoxPlan.target(words) {
        case .failure(let refusal): try BoxRun.refuse(refusal)
        case .success(let value): target = value
        }
        if let refusal = BoxPlan.checkFlags(linux: linux, mac: mac, profile: profile, target: target) {
            try BoxRun.refuse(refusal)
        }
        switch target {
        case .list(let rest):
            if rest.contains(where: { $0 == "--help" || $0 == "-h" }) {
                _ = HelpDispatch.tryEmit(arguments: ["box", "--help"])
                return
            }
            let list = try BoxListCommand.parse(rest)
            try list.run()
        case .setupMac:
            try BoxRun.setupMac()
        case .tidy(let yes):
            if words.contains(where: { $0 == "--help" || $0 == "-h" }) {
                _ = HelpDispatch.tryEmit(arguments: ["box", "--help"])
                return
            }
            try BoxTidyRun.run(yes: yes)
        case .shell, .agent, .command:
            try await BoxRun.run(linux: linux, mac: mac, profile: profile, captured: words, verbose: verbose)
        }
    }
}

/// `rv box list`. Not a registered subcommand: `BoxCommand` hands it the
/// words after `list`.
struct BoxListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List boxes, newest first."
    )

    @OptionGroup
    var format: FormatFlags

    func run() throws {
        let ctx = CommandContext.current(command: "box list", format: format)
        #if os(macOS)
        let home = try ctx.requireHome()
        let boxes = BoxRun.listings(home: home)
        let shownHome = BoxRun.canonical(home.rawValue)
        let platformNote: String? = nil
        #else
        let boxes: [BoxListing] = []
        let shownHome: String? = nil
        let platformNote: String? = "boxes run on macOS only today"
        #endif
        if ctx.explicitRobot {
            ctx.writeStdout(try RobotJSON.encode(BoxListRender.document(boxes), options: .compactISO8601) + "\n")
        } else {
            ctx.writeStdout(BoxInk.paint(
                BoxListRender.text(boxes, home: shownHome, platformNote: platformNote), palette: ctx.appearance.palette))
        }
    }
}

/// The imperative shell of `rv box`: reads the machine, then hands the
/// launch `BoxPlan` resolved to `WorkspaceCommandRun`.
enum BoxRun {
    static func run(linux: Bool, mac: Bool, profile: String?, captured: [String], verbose: Bool = false) async throws {
        #if !os(macOS)
        try refuse(BoxPlan.linuxHostRefusal)
        #else
        let clock = ContinuousClock()
        let started = clock.now
        guard let surroundings = live() else { try refuse(BoxPlan.missingFolder) }
        let start: BoxStart
        switch BoxPlan.start(
            linux: linux, mac: mac, profile: profile, captured: captured, surroundings: surroundings)
        {
        case .failure(let refusal): try refuse(refusal)
        case .success(let value): start = value
        }
        switch start {
        case .shell(let project):
            guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
                try refuse(BoxPlan.shellNeedsTerminal)
            }
            try await WorkspaceTUICommand.run(project)
        case .launch(let launch):
            try runLaunch(launch, surroundings: surroundings, verbose: verbose) {
                let elapsed = started.duration(to: clock.now).components
                return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            }
        }
        #endif
    }

    /// `rv box setup mac`: the Mac image's one-time build, in the foreground.
    static func setupMac() throws {
        #if !os(macOS)
        try refuse(BoxPlan.linuxHostRefusal)
        #else
        guard let options = BoxWall.mac.microVM else { return }
        let directory = canonical(FileManager.default.currentDirectoryPath) ?? "/"
        let prepared: WorkspaceMicroVM.Prepared
        do throws(WorkspaceMicroVM.Unready) {
            prepared = try WorkspaceMicroVM.prepare(
                options, project: directory, willBuild: { writeStderr(BoxPlan.setupStartLine) })
        } catch {
            try refuse(BoxPlan.refusal(error))
        }
        writeStderr(BoxPlan.setupFinishedText(prepared))
        #endif
    }

    #if os(macOS)
    private static func runLaunch(
        _ launch: BoxLaunch, surroundings: BoxSurroundings, verbose: Bool, elapsed: () -> Double
    ) throws {
        if let microVM = launch.wall.microVM {
            do throws(WorkspaceMicroVM.Unready) {
                try WorkspaceMicroVM.ensureReady(microVM, project: launch.project)
            } catch {
                try refuse(BoxPlan.refusal(error))
            }
        }
        let home = surroundings.home
        let workingDirectory = surroundings.workingDirectory
        writeStderr(BoxPlan.headerLine(launch, home: home))
        let exitLine = BoxPlan.exitLine(project: launch.project, workingDirectory: workingDirectory, home: home)
        do {
            // The ✓ lines wait for the host's launch, so a refused launch
            // never shows them above its ✕.
            try WorkspaceCommandRun.runInteractive(
                project: launch.project,
                executable: launch.executable,
                arguments: launch.arguments,
                hook: launch.hook,
                rows: nil,
                columns: nil,
                resourceProfileID: launch.profile?.id,
                microVM: launch.wall.microVM,
                onLaunched: {
                    writeStderr(BoxPlan.launchedLines(
                        launch, seconds: elapsed(), home: home, workingDirectory: workingDirectory))
                }
            )
        } catch let exit as ExitCode {
            // The runtime ran and exited; its writes are still in the box.
            writeStderr(exitLine)
            throw exit
        } catch let error as ValidationError {
            // A refused trust pin can look like an unreachable host: ask
            // the installed helper's peer-trust check only then.
            let trust = BoxStartFailure.mayBeTrust(error.message) ? WorkspaceCommandRun.currentHostTrustReason() : nil
            try refuse(BoxStartFailure.refusal(error.message, hostTrustReason: trust),
                       detail: verbose ? BoxStartFailure.detail(error.message) : nil)
        } catch {
            // Anything else the start throws is still one line and one fix.
            try refuse(BoxStartFailure.fallback,
                       detail: verbose ? BoxStartFailure.detail(String(describing: error)) : nil)
        }
        writeStderr(exitLine)
    }

    /// The machine, as `BoxPlan` reads it; nil when the current folder
    /// can no longer be resolved.
    static func live() -> BoxSurroundings? {
        guard let workingDirectory = canonical(FileManager.default.currentDirectoryPath) else { return nil }
        let environment = CLIProcess.environment()
        let pathDirectories = (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":")
            .map(String.init).filter { $0.hasPrefix("/") && $0.contains("\0") == false }
        // The passwd home, as the workspace host reads it: `$HOME` can be
        // unset or point anywhere, and the home checks must not be skipped.
        let home = passwdHome()
        let canonicalHome = home.flatMap { canonical($0.rawValue) }
        let secrets = home.flatMap { home in
            try? SecretsConfiguration.load(configDirectory: RVPolicyPaths.configDirectory(home: home)).get()
        } ?? .empty
        return BoxSurroundings(
            workingDirectory: workingDirectory,
            home: canonicalHome,
            homeAliases: canonicalHome.map(homeAliases) ?? [],
            identity: identity,
            policy: WorkspaceTUICommand.loadResourceProfiles(home: home),
            secrets: secrets,
            hasGitEntry: { FileManager.default.fileExists(atPath: $0 + "/.git") },
            findOnPath: { name in
                for directory in pathDirectories {
                    let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                        .appendingPathComponent(name).path
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory),
                        isDirectory.boolValue == false,
                        FileManager.default.isExecutableFile(atPath: candidate)
                    else { continue }
                    // argv[0] stays as PATH names it: version-manager shims
                    // (mise, volta, rustup) dispatch on it.
                    return BoxPathHit(path: candidate, resolved: canonical(candidate) ?? candidate)
                }
                return nil
            }
        )
    }

    /// Open workspaces and leftovers, with the walls their runtimes used.
    static func listings(home: HomeDirectory) -> [BoxListing] {
        let runtimeLog = RVPolicyPaths.configDirectory(home: home)
            .appendingPathComponent("runtime-sessions.jsonl", isDirectory: false)
        let runtimes = RuntimeSessionLog.records(at: runtimeLog).map { (workspace: $0.workspaceSession, backend: $0.backend) }
        return WorkspaceHosts.unclosedWorkspaces().compactMap { found -> BoxListing? in
            var workspace = found.workspace
            let state: BoxListing.State
            switch found.attachment {
            case .live(let endpoint):
                state = .open
                workspace = endpoint.workspace
            case .starting: state = .starting
            case .orphaned, .staleEndpoint: state = .unfinished
            case .recovering: state = .recovering
            case .blocked: state = .blocked
            case .absent, .unsupported: return nil
            }
            return BoxListing(
                project: found.project, workspace: workspace, state: state, lastActive: found.recordedAt,
                walls: BoxListRender.walls(for: workspace, runtimes: runtimes))
        }
    }
    #endif

    /// The home directory in the passwd entry, never `$HOME`.
    static func passwdHome() -> HomeDirectory? {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else { return nil }
        let home = String(cString: directory)
        guard home.hasPrefix("/") else { return nil }
        return HomeDirectory(validating: home)
    }

    /// Home's other spellings: on macOS, `/Users` is a firmlink into the
    /// Data volume, and `realpath` keeps whichever spelling it was given.
    static func homeAliases(_ home: String) -> [String] {
        let data = "/System/Volumes/Data" + home
        guard let homeID = identity(home), identity(data) == homeID else { return [] }
        return [data]
    }

    /// `stat(2)`'s device and inode: the same folder under any spelling.
    static func identity(_ path: String) -> FileIdentity? {
        guard path.contains("\0") == false else { return nil }
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileIdentity(device: UInt64(truncatingIfNeeded: info.st_dev), inode: UInt64(truncatingIfNeeded: info.st_ino))
    }

    /// `realpath(3)`: the path the workspace host and profiles use.
    static func canonical(_ path: String) -> String? {
        guard path.hasPrefix("/"), path.contains("\0") == false, let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func refuse(_ refusal: BoxRefusal, detail: String? = nil) throws -> Never {
        writeStderr(refusal.text)
        if let detail { writeStderr(detail) }
        throw ExitCode(refusal.exitCode)
    }

    /// Glyphs are coloured only when stderr is a terminal (`BoxInk`).
    private static let stderrPalette = BoxInk.palette(
        isTerminal: isatty(STDERR_FILENO) == 1, environment: CLIProcess.environment())

    private static func writeStderr(_ text: String) {
        FileHandle.standardError.write(Data(BoxInk.paint(text, palette: stderrPalette).utf8))
    }
}

extension HelpCatalog {
    static let box = HelpViewModel(
        title: "",
        blurb: "",
        sections: [
            HelpSection(heading: "Usage", rows: BoxCommand.usage),
            HelpSection(heading: "Flags", rows: BoxCommand.flags),
            HelpSection(heading: "Walls", rows: [
                HelpRow(name: "cage", description: "Default. Seatbelt on the workspace host: starts at once, public HTTPS through rv, LAN closed"),
                HelpRow(name: "linux", description: "--linux: its own Linux kernel and no network card; public HTTPS through rv"),
                HelpRow(name: "mac", description: "--mac: a whole macOS VM with no network card, cloned fresh for each run"),
            ]),
            HelpSection(heading: "Notes", rows: [
                HelpRow(name: "project", description: "The nearest folder at or above this one that holds .git, else this folder; never your home folder or one that holds it"),
                HelpRow(name: "start", description: "The box starts in the project root; a relative path you name is taken from this folder"),
                HelpRow(name: "writes", description: "Stay in the box until rv workspace close brings them home"),
                HelpRow(name: "keys", description: "Only what the resource profile stages; rv init writes one for this project. With a profile staged, an agent found on PATH inside the project is refused"),
                HelpRow(name: "platform", description: "macOS only; on Linux rv box refuses rather than use a weaker wall"),
            ]),
        ],
        examples: ["rv box claude", "rv box --linux -- npm test", "rv box list", "rv box tidy"]
    )
}
