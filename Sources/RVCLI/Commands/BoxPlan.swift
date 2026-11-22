import Foundation
import RVDomain
import RVIsolation

/// How strong a box's walls are. `rv box` takes the cage; `--linux` and
/// `--mac` take the VMs the workspace host already launches
/// (`rv workspace run --microvm` / `--macvm`). Every wall keeps the
/// project's writes on the workspace volume until it is closed.
enum BoxWall: String, Equatable, Sendable, CaseIterable {
    /// The Seatbelt cage on the workspace host. Starts at once.
    case cage
    /// A network-less Linux micro-VM booted from ``linuxImage``.
    case linux
    /// A network-less macOS VM cloned from the prepared ``macImage``.
    case mac

    /// The OCI image `--linux` boots; pulled and cached on first use.
    static let linuxImage = "alpine:3.20"
    /// The prepared image `--mac` clones (`rv-macvm prepare --image dev`).
    static let macImage = "dev"

    /// The VM this wall launches, or nil for the cage. Default sizes.
    var microVM: MicroVMLaunchOptions? {
        switch self {
        case .cage: nil
        case .linux: MicroVMLaunchOptions(image: Self.linuxImage)
        case .mac: MicroVMLaunchOptions(image: Self.macImage, guest: .macOS)
        }
    }

    /// The flag that picks this wall, or nil for the default cage.
    var flag: String? {
        switch self {
        case .cage: nil
        case .linux: "--linux"
        case .mac: "--mac"
        }
    }
}

/// What `rv box` was asked to put in the box.
enum BoxTarget: Equatable, Sendable {
    /// `rv box`: the workspace shell for the project.
    case shell
    /// `rv box claude [args...]`: an agent found by name.
    case agent(String, arguments: [String])
    /// `rv box -- npm test`: any command.
    case command(String, arguments: [String])
}

/// Why a box did not start, as one line and the one thing to do next.
struct BoxRefusal: Error, Equatable, Sendable {
    enum Mark: String, Sendable {
        /// It cannot start as asked.
        case stopped = "✕"
        /// It can start once a one-time step is done.
        case setup = "◐"
    }

    var mark: Mark = .stopped
    /// One sentence: what is wrong, in plain words.
    var why: String
    /// The next step; ends with the command to copy, when there is one.
    var fix: String?
    /// 64 when the command line itself was wrong, 1 otherwise.
    var exitCode: Int32 = 1

    var text: String {
        var lines = ["\(mark.rawValue) \(why)"]
        if let fix { lines.append("  → \(fix)") }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// One contained launch, fully resolved: what `WorkspaceCommandRun`
/// hands the workspace host.
struct BoxLaunch: Equatable, Sendable {
    var wall: BoxWall
    /// Canonical project root the box is for.
    var project: String
    var executable: String
    var arguments: [String]
    var hook: HookHost?
    var profile: RuntimeResourceProfile?
}

/// What `rv box` resolved to.
enum BoxStart: Equatable, Sendable {
    case shell(project: String)
    case launch(BoxLaunch)
}

/// What the resolver reads from the machine. Production fills it from
/// the process and the file system; tests pass values.
struct BoxSurroundings {
    /// Canonical current directory.
    var workingDirectory: String
    /// Canonical home directory, when known.
    var home: String?
    /// Owner resource profiles (runtime-resources.json); `.empty` when none.
    var policy: RuntimeResourcePolicy
    /// Whether `<directory>/.git` exists (a directory, or a worktree's file).
    var hasGitEntry: (String) -> Bool
    /// An executable named `name` in the host PATH's absolute directories.
    var findOnPath: (String) -> String?
}

/// The functional core of `rv box`: argument resolution, the project root,
/// profile choice and the words rv prints. No I/O: `BoxCommand` reads the
/// machine into `BoxSurroundings` and performs the launch.
///
/// A front door only. Every launch it builds is one `rv workspace run`
/// could already make, and the workspace host re-validates the profile,
/// the executable and every wall as it would for that command.
enum BoxPlan {
    // MARK: Arguments

    /// The wall `--linux` / `--mac` ask for. `target` only shapes the fix.
    static func wall(linux: Bool, mac: Bool, target: BoxTarget) -> Result<BoxWall, BoxRefusal> {
        switch (linux, mac) {
        case (true, true):
            .failure(BoxRefusal(
                why: "Pick one wall: --linux or --mac.",
                fix: invocation(wall: .linux, target: target), exitCode: 64))
        case (true, false): .success(.linux)
        case (false, true): .success(.mac)
        case (false, false): .success(.cage)
        }
    }

    /// The captured words after `rv box`'s own flags.
    static func target(_ captured: [String]) -> Result<BoxTarget, BoxRefusal> {
        guard let first = captured.first else { return .success(.shell) }
        var rest = Array(captured.dropFirst())
        if first == "--" {
            guard let command = rest.first, command.isEmpty == false, command.contains("\0") == false else {
                return .failure(BoxRefusal(why: "Nothing to run after --.", fix: "rv box --help", exitCode: 64))
            }
            return .success(.command(command, arguments: Array(rest.dropFirst())))
        }
        if rest.first == "--" { rest.removeFirst() }
        if first.hasPrefix("-") {
            return .failure(BoxRefusal(
                why: "rv box has no \(DisplayedText.field(first)) option.", fix: "rv box --help", exitCode: 64))
        }
        if first.contains("/") {
            guard first.contains("\0") == false else {
                return .failure(BoxRefusal(why: "That path is unusable.", fix: "rv box --help", exitCode: 64))
            }
            return .success(.command(first, arguments: rest))
        }
        guard AgentTagValidator.isValid(first) else {
            return .failure(BoxRefusal(
                why: "\(DisplayedText.field(first)) isn't an agent name.",
                fix: "rv box -- " + InitRun.shellWord(first), exitCode: 64))
        }
        return .success(.agent(first, arguments: rest))
    }

    /// The `rv box …` line that asks for `target` behind `wall`, for fixes.
    static func invocation(wall: BoxWall, target: BoxTarget, profile: String? = nil) -> String {
        var words = ["rv", "box"]
        if let flag = wall.flag { words.append(flag) }
        if let profile { words += ["--profile", profile] }
        switch target {
        case .shell:
            break
        case .agent(let name, let arguments):
            words.append(name)
            if arguments.first?.hasPrefix("-") == true { words.append("--") }
            words += arguments.map(InitRun.shellWord)
        case .command(let command, let arguments):
            words += ["--", InitRun.shellWord(command)] + arguments.map(InitRun.shellWord)
        }
        return words.joined(separator: " ")
    }

    // MARK: Project

    /// The project a box is for: the nearest directory at or above
    /// `directory` that holds `.git`, else `directory` itself. The home
    /// folder is never a project, so the walk stops below it (a dotfiles
    /// repository in `~` does not swallow every folder under it).
    static func projectRoot(
        from directory: String, home: String?, hasGitEntry: (String) -> Bool
    ) -> Result<String, BoxRefusal> {
        let start = normalized(directory)
        let home = home.map(normalized)
        if start == "/" || start == home {
            return .failure(BoxRefusal(
                why: start == "/" ? "The root folder can't be a box." : "Your home folder can't be a box.",
                fix: "cd into a project folder, then run rv box again"))
        }
        var candidate = start
        while candidate != "/", candidate != home {
            if hasGitEntry(candidate) { return .success(candidate) }
            candidate = parent(of: candidate)
        }
        return .success(start)
    }

    // MARK: Profile

    /// The owner resource profile the box stages. `named` must serve this
    /// project. Otherwise an agent takes the one profile that serves it
    /// here (by its `agents` marks, or its link names when it has none,
    /// as the workspace shell's launcher decides); if none does, or for a
    /// shell or a plain command, the policy's `defaultProfile` when it
    /// serves this project. No profile means no credentials are staged.
    static func profile(
        for target: BoxTarget, named explicit: String?, wall: BoxWall,
        policy: RuntimeResourcePolicy, project: String, workingDirectory: String
    ) -> Result<RuntimeResourceProfile?, BoxRefusal> {
        let eligible = policy.profiles.filter { $0.projects.contains(project) }
        if let explicit {
            if let profile = eligible.first(where: { $0.id == explicit }) { return .success(profile) }
            return .failure(BoxRefusal(
                why: "No profile \(DisplayedText.field(explicit)) serves \(DisplayedText.field(displayPath(project))).",
                fix: initCommand(project: project, workingDirectory: workingDirectory, profileID: explicit)))
        }
        let fallback = policy.defaultProfile.flatMap { id in eligible.first { $0.id == id } }
        guard case .agent(let name, _) = target else { return .success(fallback) }
        let claiming = eligible.filter { claims($0, agent: name) }
        switch claiming.count {
        case 0:
            return .success(fallback)
        case 1:
            return .success(claiming[0])
        default:
            if let fallback, claiming.contains(fallback) { return .success(fallback) }
            let ids = claiming.map(\.id).sorted()
            return .failure(BoxRefusal(
                why: "\(claiming.count) profiles serve \(name) here: \(ids.map { DisplayedText.field($0) }.joined(separator: ", ")).",
                fix: invocation(wall: wall, target: target, profile: ids[0])))
        }
    }

    /// Whether `profile` serves agent `name`: its marks, or its link
    /// names when it has no marks (the launcher's legacy rule).
    static func claims(_ profile: RuntimeResourceProfile, agent name: String) -> Bool {
        profile.agents.isEmpty
            ? profile.executableLinks.contains { $0.name == name }
            : profile.agents.contains(name)
    }

    // MARK: Launch

    /// What to run in the box. In the cage an agent runs from its
    /// profile's link, else from the host PATH, and a bare command from the
    /// host PATH. A VM has its own file system, so a bare name is looked
    /// up on the guest's PATH by `/usr/bin/env`. A relative path is taken
    /// from the current directory, which the box shares.
    static func launch(
        _ target: BoxTarget, wall: BoxWall, project: String, profile: RuntimeResourceProfile?,
        workingDirectory: String, findOnPath: (String) -> String?
    ) -> Result<BoxStart, BoxRefusal> {
        let name: String
        let arguments: [String]
        let hook: HookHost?
        switch target {
        case .shell:
            return .success(.shell(project: project))
        case .agent(let agent, let rest):
            (name, arguments, hook) = (agent, rest, HookHost(rawValue: agent))
        case .command(let command, let rest):
            (name, arguments, hook) = (command, rest, nil)
        }
        guard arguments.contains(where: { $0.contains("\0") }) == false else {
            return .failure(BoxRefusal(why: "An argument holds a NUL byte.", fix: "rv box --help", exitCode: 64))
        }
        let executable: String
        var argv = arguments
        if name.contains("/") {
            executable = name.hasPrefix("/") ? normalized(name) : normalized(workingDirectory + "/" + name)
        } else if wall != .cage {
            executable = "/usr/bin/env"
            argv.insert(name, at: 0)
        } else if case .agent = target,
                  let link = profile?.executableLinks.first(where: { $0.name == name }) {
            executable = link.target
        } else if let found = findOnPath(name) {
            executable = found
        } else {
            return .failure(BoxRefusal(
                why: "No \(DisplayedText.field(name)) on your PATH.",
                fix: "rv box -- /full/path/to/\(name)"))
        }
        return .success(.launch(BoxLaunch(
            wall: wall, project: project, executable: executable, arguments: argv,
            hook: hook, profile: profile)))
    }

    /// The whole resolution, from parsed flags and captured words.
    static func start(
        linux: Bool, mac: Bool, profile explicit: String?, captured: [String],
        surroundings: BoxSurroundings
    ) -> Result<BoxStart, BoxRefusal> {
        let target: BoxTarget
        let wall: BoxWall
        let project: String
        let profile: RuntimeResourceProfile?
        switch Self.target(captured) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let value): target = value
        }
        switch Self.wall(linux: linux, mac: mac, target: target) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let value): wall = value
        }
        if target == .shell, wall != .cage {
            return .failure(BoxRefusal(
                why: "The box shell runs in the cage; --linux and --mac need something to run.",
                fix: invocation(wall: wall, target: .command("sh", arguments: [])), exitCode: 64))
        }
        switch projectRoot(
            from: surroundings.workingDirectory, home: surroundings.home, hasGitEntry: surroundings.hasGitEntry)
        {
        case .failure(let refusal): return .failure(refusal)
        case .success(let value): project = value
        }
        switch Self.profile(
            for: target, named: explicit, wall: wall, policy: surroundings.policy,
            project: project, workingDirectory: surroundings.workingDirectory)
        {
        case .failure(let refusal): return .failure(refusal)
        case .success(let value): profile = value
        }
        return launch(
            target, wall: wall, project: project, profile: profile,
            workingDirectory: surroundings.workingDirectory, findOnPath: surroundings.findOnPath)
    }

    // MARK: Refusals from the machine

    /// Contained launches are macOS-only; Linux refuses rather than run
    /// behind a weaker wall (`ContainedRuntimeRefusal`).
    static let linuxHostRefusal = BoxRefusal(
        why: "Boxes run on macOS only today; on Linux rv refuses rather than use a weaker wall.",
        fix: "guard agents here through their hooks instead: rv setup")

    /// `rv box` alone opens the workspace shell, which needs a terminal.
    static let shellNeedsTerminal = BoxRefusal(
        why: "rv box on its own opens the box shell, which needs a terminal.",
        fix: "rv box --help", exitCode: 64)

    /// A VM wall whose helper or image is not ready.
    static func refusal(_ unready: WorkspaceMicroVM.Unready) -> BoxRefusal {
        switch unready {
        case .helperMissing(.linux):
            BoxRefusal(
                why: "Linux boxes need rv-microvm next to rv.",
                fix: "reinstall rv, or build it: Scripts/build-microvm.sh")
        case .helperMissing(.macOS):
            BoxRefusal(
                why: "Mac boxes need rv-macvm, and this rv was built without it.",
                fix: "build it with the macOS 27 SDK: Scripts/build-microvm.sh")
        case .notPrepared(let options):
            BoxRefusal(
                mark: .setup,
                why: "Mac boxes need a one-time setup: about 26 GB to download.",
                fix: WorkspaceMicroVM.prepareInstruction(options))
        case .prepareFailed(let image, let status):
            BoxRefusal(
                why: "The Linux image \(DisplayedText.field(image)) could not be fetched (rv-microvm exit \(status)).",
                fix: "rv doctor")
        case .helperUnstartable(let path, let detail):
            BoxRefusal(
                why: "rv can't start \(DisplayedText.field(path)): \(DisplayedText.field(detail)).",
                fix: "rv doctor")
        }
    }

    // MARK: Words

    /// The lines before the agent takes the terminal.
    static func startLines(_ launch: BoxLaunch, home: String?, workingDirectory: String) -> String {
        let place = DisplayedText.field(displayPath(launch.project, home: home))
        let header: String
        let network: String
        switch launch.wall {
        case .cage:
            header = "◆ rv · box for \(place)"
            network = "public HTTPS through rv · LAN closed"
        case .linux:
            header = "◆ rv · linux box for \(place) · \(BoxWall.linuxImage.replacingOccurrences(of: ":", with: " "))"
            network = "public HTTPS through rv · no network card"
        case .mac:
            header = "◆ rv · mac box for \(place) · image \(BoxWall.macImage)"
            network = "public HTTPS through rv · no network card"
        }
        let keys: String
        if let profile = launch.profile {
            let id = DisplayedText.field(profile.id)
            keys = profile.secrets.isEmpty
                ? "  ✓ keys      from profile \(id)"
                : "  ✓ keys      \(profile.secrets.map { DisplayedText.field($0) }.joined(separator: ", ")) via rv · profile \(id)"
        } else {
            let command = initCommand(project: launch.project, workingDirectory: workingDirectory, profileID: nil)
            keys = "  ◐ keys      none staged · to stage them: \(command)"
        }
        return [
            header,
            "  ✓ sealed    writes stay in the box until you bring them home",
            keys,
            "  ✓ network   \(network)",
        ].joined(separator: "\n") + "\n"
    }

    /// Once the host has launched it.
    static func readyLine(seconds: Double) -> String {
        "  ready in \(String(format: "%.1f", max(0, seconds))) s\n"
    }

    /// After the runtime exits: its writes are still on the volume.
    static func exitLine(project: String, workingDirectory: String, home: String?) -> String {
        var command = "rv workspace close"
        if normalized(workingDirectory) != project {
            command += " --workspace " + shellPath(project, home: home)
        }
        return "  → bring the writes home: \(command)\n"
    }

    // MARK: Paths

    /// `~/code/app` for a path under `home`.
    static func displayPath(_ path: String, home: String? = nil) -> String {
        guard let home = home.map(normalized), home != "/" else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + String(path.dropFirst(home.count)) }
        return path
    }

    /// `displayPath` when a shell reads it back as the same path, else
    /// the path quoted.
    static func shellPath(_ path: String, home: String?) -> String {
        let shown = displayPath(path, home: home)
        if shown.hasPrefix("~/"), InitRun.shellWord(String(shown.dropFirst(2))) == String(shown.dropFirst(2)) {
            return shown
        }
        return InitRun.shellWord(path)
    }

    /// `rv init`, pointed at the project when the shell is elsewhere.
    static func initCommand(project: String, workingDirectory: String, profileID: String?) -> String {
        var command = "rv init"
        if normalized(workingDirectory) != project {
            command += " --project " + InitRun.shellWord(project)
        }
        if let profileID { command += " --profile-id " + InitRun.shellWord(profileID) }
        return command
    }

    /// `/a/./b/../c/` → `/a/c`. Lexical only; the shell canonicalizes first.
    static func normalized(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": _ = parts.popLast()
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    private static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
        return String(path[..<slash])
    }
}
