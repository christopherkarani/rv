import Foundation
import RVDomain
import RVIsolation

private typealias Glyph = CommandVocabulary.Glyph

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
    /// The prepared image `--mac` clones (`rv box setup mac` builds it).
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

/// What `rv box` was asked to do.
enum BoxTarget: Equatable, Sendable {
    /// `rv box`: the workspace shell for the project.
    case shell
    /// `rv box claude [args...]`: an agent found by name.
    case agent(String, arguments: [String])
    /// `rv box -- npm test`: any command.
    case command(String, arguments: [String])
    /// `rv box list [--json]`: the words after `list`.
    case list([String])
    /// `rv box setup mac`: build the Mac image now.
    case setupMac
    /// `rv box tidy [--yes]`: leftovers to the 7-day trash.
    case tidy(yes: Bool)
    /// `rv box done`: the review on the way home.
    case done
    /// `rv box default [on | off]`: boxed by default.
    case defaultSwitch(BoxDefaultRequest)
}

/// Why a box did not start, as one line and the one thing to do next.
struct BoxRefusal: Error, Equatable, Sendable {
    enum Mark: Sendable {
        /// It cannot start as asked.
        case stopped
        /// It can start once a one-time step is done.
        case setup

        var glyph: CommandVocabulary.Glyph { self == .stopped ? .stopped : .watched }
    }

    var mark: Mark = .stopped
    /// One sentence: what is wrong, in plain words.
    var why: String
    /// The next step; ends with the command to copy, when there is one.
    var fix: String?
    /// 64 when the command line itself was wrong, 1 otherwise.
    var exitCode: Int32 = 1

    var text: String {
        var lines = ["\(mark.glyph.rawValue) \(why)"]
        if let fix { lines.append("  \(Glyph.next.rawValue) \(fix)") }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// One contained launch, fully resolved: what `WorkspaceCommandRun`
/// hands the workspace host, and the keys line rv prints for it.
struct BoxLaunch: Equatable, Sendable {
    var wall: BoxWall
    /// Canonical project root the box is for. The runtime starts here.
    var project: String
    var executable: String
    var arguments: [String]
    var hook: HookHost?
    var profile: RuntimeResourceProfile?
    /// The keys line, and the step that stages keys when there are none.
    var keys: BoxKeys
}

/// What the keys line says.
enum BoxKeys: Equatable, Sendable {
    /// Every staged secret is a placeholder the gateway swaps; nothing
    /// else from the host is copied in.
    case placeholders([String])
    /// Secrets, files or keychain values from this profile.
    case profile(id: String, secrets: [String])
    /// Nothing staged; `next` is the command that would stage keys.
    case none(next: String)
}

/// What `rv box` resolved to.
enum BoxStart: Equatable, Sendable {
    case shell(project: String)
    case launch(BoxLaunch)
}

/// An executable found on the host PATH: the path as PATH names it (kept as
/// argv[0], so version-manager shims keep working) and where it resolves.
struct BoxPathHit: Equatable, Sendable {
    var path: String
    var resolved: String
}

/// What the resolver reads from the machine. Production fills it from
/// the process and the file system; tests pass values.
/// A folder's `(st_dev, st_ino)`: the same folder under any spelling (a
/// symlink, a bind mount, the macOS Data volume's firmlinks).
struct FileIdentity: Hashable, Sendable {
    var device: UInt64
    var inode: UInt64
}

struct BoxSurroundings {
    /// Canonical current directory.
    var workingDirectory: String
    /// Canonical home directory from the passwd entry, never `$HOME`; nil
    /// when it cannot be found, and then no box starts.
    var home: String?
    /// Other spellings of home, such as `/System/Volumes/Data/Users/<me>`.
    var homeAliases: [String] = []
    /// The identity of a folder, or nil when it can't be read.
    var identity: (String) -> FileIdentity? = { _ in nil }
    /// Owner resource profiles (runtime-resources.json); `.empty` when none.
    var policy: RuntimeResourcePolicy
    /// secrets.json, to tell placeholders from copied values.
    var secrets: SecretsConfiguration = .empty
    /// Whether `<directory>/.git` exists (a directory, or a worktree's file).
    var hasGitEntry: (String) -> Bool
    /// An executable named `name` in the host PATH's absolute directories.
    var findOnPath: (String) -> BoxPathHit?
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
        if first == "list" {
            if let refusal = listRefusal(rest) { return .failure(refusal) }
            return .success(.list(rest))
        }
        if first == "tidy" {
            if rest.contains(where: isWallOrProfileFlag) { return .failure(wallFlagsRefusal("rv box tidy")) }
            if let stray = rest.first(where: { BoxTidyRun.words.contains($0) == false }) {
                let why = stray.hasPrefix("-")
                    ? "rv box tidy has no \(DisplayedText.field(stray)) option."
                    : "rv box tidy takes no \(DisplayedText.field(stray))."
                return .failure(BoxRefusal(why: why, fix: "rv box tidy", exitCode: 64))
            }
            return .success(.tidy(yes: rest.contains("--yes") || rest.contains("-y")))
        }
        if first == "done" || first == "default" {
            return homeTarget(first, rest)
        }
        if first == "setup" {
            if rest.first == "mac", rest.dropFirst().contains(where: isWallOrProfileFlag) {
                return .failure(wallFlagsRefusal("rv box setup mac"))
            }
            guard rest == ["mac"] else {
                return .failure(BoxRefusal(why: "Only Mac boxes need a setup.", fix: "rv box setup mac", exitCode: 64))
            }
            return .success(.setupMac)
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

    /// Flags that would be silently ignored are refused instead.
    /// The words `rv box list` takes after `list`: its format flags and
    /// `--help`. A wall or profile flag in either place gets the same refusal.
    static let listWords: Set = ["--json", "--robot", "--plain", "--no-color", "--help", "-h"]

    static func listRefusal(_ rest: [String]) -> BoxRefusal? {
        if rest.contains(where: isWallOrProfileFlag) { return wallFlagsRefusal("rv box list") }
        guard let stray = rest.first(where: { listWords.contains($0) == false }) else { return nil }
        let why = stray.hasPrefix("-")
            ? "rv box list has no \(DisplayedText.field(stray)) option."
            : "rv box list takes no \(DisplayedText.field(stray))."
        return BoxRefusal(why: why, fix: "rv box list", exitCode: 64)
    }

    private static func isWallOrProfileFlag(_ word: String) -> Bool {
        word == "--linux" || word == "--mac" || word == "--profile" || word.hasPrefix("--profile=")
    }

    private static func wallFlagsRefusal(_ command: String) -> BoxRefusal {
        BoxRefusal(why: "\(command) takes no --linux, --mac or --profile.", fix: command, exitCode: 64)
    }

    /// `done` and `default`: neither takes anything but `--help`, and
    /// `default` takes on or off.
    private static func homeTarget(_ first: String, _ rest: [String]) -> Result<BoxTarget, BoxRefusal> {
        let command = "rv box " + first
        if rest.contains(where: isWallOrProfileFlag) { return .failure(wallFlagsRefusal(command)) }
        let words = rest.filter { BoxDoneRun.words.contains($0) == false }
        if first == "done" {
            guard let stray = words.first else { return .success(.done) }
            let why = stray.hasPrefix("-") ? "\(command) has no \(DisplayedText.field(stray)) option." : "\(command) takes no \(DisplayedText.field(stray))."
            return .failure(BoxRefusal(why: why, fix: command, exitCode: 64))
        }
        return BoxDefaultRequest.parse(words).map(BoxTarget.defaultSwitch)
    }

    static func checkFlags(
        linux: Bool, mac: Bool, profile: String?, target: BoxTarget
    ) -> BoxRefusal? {
        switch target {
        case .done, .defaultSwitch:
            guard linux || mac || profile != nil else { return nil }
            return wallFlagsRefusal(target == .done ? "rv box done" : "rv box default")
        case .list, .setupMac, .tidy:
            guard linux || mac || profile != nil else { return nil }
            switch target {
            case .setupMac: return wallFlagsRefusal("rv box setup mac")
            case .tidy: return wallFlagsRefusal("rv box tidy")
            default: return wallFlagsRefusal("rv box list")
            }
        case .shell:
            if linux || mac {
                let wall: BoxWall = linux ? .linux : .mac
                return BoxRefusal(
                    why: "The box shell runs in the cage; --linux and --mac need something to run.",
                    fix: invocation(wall: wall, target: .command("sh", arguments: [])), exitCode: 64)
            }
            if let profile {
                return BoxRefusal(
                    why: "The box shell picks its own profile; --profile needs something to run.",
                    fix: invocation(wall: .cage, target: .agent("claude", arguments: []), profile: profile),
                    exitCode: 64)
            }
            return nil
        case .agent, .command:
            return nil
        }
    }

    /// The `rv box …` line that asks for `target` behind `wall`, for fixes.
    static func invocation(wall: BoxWall, target: BoxTarget, profile: String? = nil) -> String {
        var words = ["rv", "box"]
        if let flag = wall.flag { words.append(flag) }
        if let profile { words += ["--profile", InitRun.shellWord(profile)] }
        switch target {
        case .shell:
            break
        case .agent(let name, let arguments):
            words.append(name)
            if arguments.first?.hasPrefix("-") == true { words.append("--") }
            words += arguments.map(InitRun.shellWord)
        case .command(let command, let arguments):
            words += ["--", InitRun.shellWord(command)] + arguments.map(InitRun.shellWord)
        case .list(let rest):
            words += ["list"] + rest.map(InitRun.shellWord)
        case .setupMac:
            words += ["setup", "mac"]
        case .tidy(let yes):
            words += yes ? ["tidy", "--yes"] : ["tidy"]
        case .done:
            words.append("done")
        case .defaultSwitch(let request):
            words.append("default")
            if case .turn(let on) = request { words.append(on ? "on" : "off") }
        }
        return words.joined(separator: " ")
    }

    // MARK: Project

    static let elsewhere = "cd into a project folder, then run rv box again"

    /// The current folder could not be read (it was deleted or moved).
    static let missingFolder = BoxRefusal(why: "This folder no longer exists.", fix: elsewhere)

    /// No passwd home, so rv can't tell what a box would expose.
    static let noHome = BoxRefusal(
        why: "rv can't find your home folder, so it can't keep it out of a box.", fix: "rv doctor")

    /// The project a box is for: the nearest directory at or above
    /// `directory` that holds `.git`, else `directory` itself. The home
    /// folder is never a project, so the walk stops below it (a dotfiles
    /// repository in `~` does not swallow every folder under it), and
    /// neither is any folder that holds home: the box could read it all.
    /// Folders are compared by `identity` as well as by path, so another
    /// spelling of home or of a folder above it (a symlink, a bind mount,
    /// `/System/Volumes/Data`) is refused too.
    static func projectRoot(
        from directory: String, home: String?, homeAliases: [String] = [],
        hasGitEntry: (String) -> Bool, identity: (String) -> FileIdentity? = { _ in nil }
    ) -> Result<String, BoxRefusal> {
        let start = normalized(directory)
        guard let home = home.map(normalized) else { return .failure(noHome) }
        if start == "/" {
            return .failure(BoxRefusal(why: "The root folder can't be a box.", fix: elsewhere))
        }
        let homeID = identity(home)
        func isHome(_ path: String) -> Bool {
            path == home || (homeID != nil && identity(path) == homeID)
        }
        if isHome(start) {
            return .failure(BoxRefusal(why: "Your home folder can't be a box.", fix: elsewhere))
        }
        let spellings = [home] + homeAliases.map(normalized)
        if holdsHome(start, spellings: spellings, homeID: homeID, identity: identity) {
            return .failure(BoxRefusal(
                why: "\(DisplayedText.field(start)) holds your home folder, so it can't be a box.", fix: elsewhere))
        }
        var candidate = start
        while candidate != "/", isHome(candidate) == false {
            if hasGitEntry(candidate) { return .success(candidate) }
            candidate = parent(of: candidate)
        }
        return .success(start)
    }

    /// Whether `start` is a folder above home: by path, as an alias of one
    /// of home's parents, or because home's own tail lies below it.
    private static func holdsHome(
        _ start: String, spellings: [String], homeID: FileIdentity?, identity: (String) -> FileIdentity?
    ) -> Bool {
        if spellings.contains(where: { $0.hasPrefix(start + "/") }) { return true }
        guard let homeID, let startID = identity(start) else { return false }
        for spelling in spellings {
            var above = spelling
            repeat {
                above = parent(of: above)
                if identity(above) == startID { return true }
            } while above != "/"
        }
        let parts = spellings[0].split(separator: "/").map(String.init)
        return (1...max(parts.count, 1)).contains { count in
            identity(start + "/" + parts.suffix(count).joined(separator: "/")) == homeID
        }
    }

    // MARK: Profile

    /// The owner resource profile the box stages. `named` must serve this
    /// project. Otherwise an agent takes the one profile that serves it
    /// here (by its `agents` marks, or its link names when it has none,
    /// as the workspace shell's launcher decides); if none does, the
    /// policy's `defaultProfile` when it serves this project and its marks
    /// allow the agent. A plain command takes the `defaultProfile` too.
    /// A VM sees only the workspace, so VM walls never pick a profile that
    /// grants host paths (the host would refuse the launch). No profile
    /// means no credentials are staged.
    static func profile(
        for target: BoxTarget, named explicit: String?, wall: BoxWall,
        policy: RuntimeResourcePolicy, project: String, workingDirectory: String
    ) -> Result<RuntimeResourceProfile?, BoxRefusal> {
        let serving = policy.profiles.filter { $0.projects.contains(project) }
        let usable = wall == .cage ? serving : serving.filter { $0.grantsHostPaths == false }
        if let explicit {
            if let profile = usable.first(where: { $0.id == explicit }) { return .success(profile) }
            if serving.contains(where: { $0.id == explicit }) {
                return .failure(BoxRefusal(
                    why: "Profile \(DisplayedText.field(explicit)) shares host files, which a VM box can't see.",
                    fix: invocation(wall: .cage, target: target, profile: explicit)))
            }
            return .failure(BoxRefusal(
                why: "No profile \(DisplayedText.field(explicit)) serves \(DisplayedText.field(displayPath(project))).",
                fix: initCommand(
                    project: project, workingDirectory: workingDirectory,
                    profileID: freeProfileID(explicit, policy: policy))))
        }
        let fallback = policy.defaultProfile.flatMap { id in usable.first { $0.id == id } }
        guard case .agent(let name, _) = target else { return .success(fallback) }
        let claiming = usable.filter { claims($0, agent: name) }
        switch claiming.count {
        case 0:
            guard let fallback, fallback.agents.isEmpty || fallback.agents.contains(name) else { return .success(nil) }
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

    /// `base`, or `base-2`, `base-3`… when the policy already has it.
    static func freeProfileID(_ base: String, policy: RuntimeResourcePolicy) -> String {
        let taken = Set(policy.profiles.map(\.id))
        guard taken.contains(base) else { return base }
        var number = 2
        while taken.contains("\(base)-\(number)") { number += 1 }
        return "\(base)-\(number)"
    }

    /// What the keys line says for `profile`.
    static func keys(
        _ profile: RuntimeResourceProfile?, secrets: SecretsConfiguration, wall: BoxWall, target: BoxTarget,
        policy: RuntimeResourcePolicy, project: String, workingDirectory: String
    ) -> BoxKeys {
        guard let profile else {
            // `rv init` writes links and credential files, which a VM
            // refuses; keys for a VM need a profile written by hand.
            let next = wall == .cage
                ? initCommand(
                    project: project, workingDirectory: workingDirectory,
                    profileID: freeProfileID("main", policy: policy))
                : "keys need the cage: " + invocation(wall: .cage, target: target)
            return .none(next: next)
        }
        let placeholders = profile.secrets.isEmpty == false
            && profile.credentials.isEmpty && profile.keychain.isEmpty
            && profile.environment.allSatisfy { $0.hostVariable == nil }
            && profile.secrets.allSatisfy { name in
                switch secrets.secret(named: name)?.delivery {
                case .gateway, .awsSigV4: true
                case .environment, nil: false
                }
            }
        return placeholders ? .placeholders(profile.secrets) : .profile(id: profile.id, secrets: profile.secrets)
    }

    // MARK: Launch

    /// What to run in the box. In the cage an agent runs from its
    /// profile's link, else from the host PATH as PATH names it, and a
    /// bare command from the host PATH. A VM has its own file system, so a
    /// bare name is looked up on the guest's PATH by `/usr/bin/env`. A
    /// relative path is made absolute from the current folder (the box
    /// shares the project at the same path); the runtime itself starts in
    /// the project root, which the ready line names.
    ///
    /// With a profile staged, a PATH hit inside the project is refused: a
    /// repo can put its own `claude` first on PATH (direnv, `.venv/bin`),
    /// and it would run with the profile's keys.
    static func launch(
        _ target: BoxTarget, wall: BoxWall, project: String, profile: RuntimeResourceProfile?,
        keys: BoxKeys, workingDirectory: String, findOnPath: (String) -> BoxPathHit?
    ) -> Result<BoxStart, BoxRefusal> {
        let name: String
        let arguments: [String]
        let hook: HookHost?
        switch target {
        case .shell:
            return .success(.shell(project: project))
        case .list, .setupMac, .tidy, .done, .defaultSwitch:
            return .failure(BoxRefusal(why: "Nothing to launch.", fix: "rv box --help", exitCode: 64))
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
        } else if let hit = findOnPath(name) {
            if let profile, isInside(hit.path, project) || isInside(hit.resolved, project) {
                return .failure(BoxRefusal(
                    why: "The \(DisplayedText.field(name)) on your PATH is inside this project, so it can't have profile \(DisplayedText.field(profile.id))'s keys.",
                    fix: "link \(DisplayedText.field(name)) in profile \(DisplayedText.field(profile.id)) (executableLinks in ~/.config/rv/runtime-resources.json)"))
            }
            executable = hit.path
        } else {
            return .failure(BoxRefusal(
                why: "No \(DisplayedText.field(name)) on your PATH.",
                fix: "rv box -- /full/path/to/\(name)"))
        }
        return .success(.launch(BoxLaunch(
            wall: wall, project: project, executable: executable, arguments: argv,
            hook: hook, profile: profile, keys: keys)))
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
        if let refusal = checkFlags(linux: linux, mac: mac, profile: explicit, target: target) {
            return .failure(refusal)
        }
        switch Self.wall(linux: linux, mac: mac, target: target) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let value): wall = value
        }
        switch projectRoot(
            from: surroundings.workingDirectory, home: surroundings.home, homeAliases: surroundings.homeAliases,
            hasGitEntry: surroundings.hasGitEntry, identity: surroundings.identity)
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
        let keys = Self.keys(
            profile, secrets: surroundings.secrets, wall: wall, target: target, policy: surroundings.policy,
            project: project, workingDirectory: surroundings.workingDirectory)
        return launch(
            target, wall: wall, project: project, profile: profile, keys: keys,
            workingDirectory: surroundings.workingDirectory, findOnPath: surroundings.findOnPath)
    }

    // MARK: Refusals from the machine

    /// Contained launches are macOS-only; Linux refuses rather than run
    /// behind a weaker wall (`ContainedRuntimeRefusal`).
    static let linuxHostRefusal = BoxRefusal(
        why: "Boxes run on macOS only today, so rv refuses here rather than use a weaker wall.",
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
        case .notPrepared:
            BoxRefusal(
                mark: .setup,
                why: "Mac boxes need a one-time setup: about 26 GB to download.",
                fix: "rv box setup mac")
        case .prepareFailed(let options, let status) where options.guest == .macOS:
            BoxRefusal(
                why: "The Mac image could not be set up (rv-macvm exit \(status)).",
                fix: "rv doctor")
        case .prepareFailed(let options, let status):
            BoxRefusal(
                why: "The Linux image \(DisplayedText.field(options.image)) could not be fetched (rv-microvm exit \(status)).",
                fix: "rv doctor")
        case .helperUnstartable(let path, let detail):
            BoxRefusal(
                why: "rv can't start \(DisplayedText.field(path)): \(DisplayedText.field(detail)).",
                fix: "rv doctor")
        }
    }

    /// A refusal from the workspace host (`rv workspace run`'s words),
    /// as one line and one fix (`BoxStartFailure`).
    static func hostRefusal(_ message: String) -> BoxRefusal {
        BoxStartFailure.refusal(message)
    }

    // MARK: Words

    /// The line before the host launches anything.
    static func headerLine(_ launch: BoxLaunch, home: String?) -> String {
        let place = DisplayedText.field(displayPath(launch.project, home: home))
        switch launch.wall {
        case .cage:
            return "\(Glyph.rv.rawValue) rv · box for \(place)\n"
        case .linux:
            return "\(Glyph.rv.rawValue) rv · linux box for \(place) · \(BoxWall.linuxImage.replacingOccurrences(of: ":", with: " "))\n"
        case .mac:
            return "\(Glyph.rv.rawValue) rv · mac box for \(place) · image \(BoxWall.macImage)\n"
        }
    }

    /// The lines once the host has launched it: the walls, the time, and
    /// the step that stages keys when none are, last.
    static func launchedLines(
        _ launch: BoxLaunch, seconds: Double, home: String?, workingDirectory: String
    ) -> String {
        let network = launch.wall == .cage
            ? "public HTTPS through rv · LAN closed"
            : "public HTTPS through rv · no network card"
        var lines = ["  \(Glyph.done.rawValue) sealed    writes stay in the box until you bring them home"]
        var next: String?
        switch launch.keys {
        case .placeholders(let names):
            let shown = names.map { DisplayedText.field($0) }.joined(separator: ", ")
            lines.append("  \(Glyph.done.rawValue) keys      \(shown) via rv · \(names.count == 1 ? "the value never enters" : "the values never enter")")
        case .profile(let id, let secrets):
            lines.append(secrets.isEmpty
                ? "  \(Glyph.done.rawValue) keys      from profile \(DisplayedText.field(id))"
                : "  \(Glyph.done.rawValue) keys      \(secrets.map { DisplayedText.field($0) }.joined(separator: ", ")) via rv · profile \(DisplayedText.field(id))")
        case .none(let command):
            lines.append("  \(Glyph.watched.rawValue) keys      none staged")
            next = command
        }
        lines.append("  \(Glyph.done.rawValue) network   \(network)")
        var ready = "  ready in \(String(format: "%.1f", max(0, seconds))) s"
        if normalized(workingDirectory) != launch.project {
            ready += " · starts in \(DisplayedText.field(displayPath(launch.project, home: home)))"
        }
        lines.append(ready)
        if let next { lines.append("  \(Glyph.next.rawValue) \(next)") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// After the runtime exits: its writes are still on the volume, and
    /// `rv box done` reviews them on the way home. It finds the box from
    /// anywhere in the project, as `rv box` did.
    static func exitLine(project: String, workingDirectory: String, home: String?) -> String {
        let inside = normalized(workingDirectory) == project || isInside(workingDirectory, project)
        let command = inside ? "rv box done" : "cd \(shellPath(project, home: home)) && rv box done"
        return "  \(Glyph.next.rawValue) bring it home: \(command)\n"
    }

    /// `rv box setup mac`, before and after the helper's own progress.
    static let setupStartLine = "\(Glyph.rv.rawValue) rv · setting up Mac boxes · about 26 GB to download, in the foreground\n"
    /// The last line of `rv box setup mac`: under the setup header after a
    /// build, on its own when the image was already there.
    static func setupFinishedText(_ prepared: WorkspaceMicroVM.Prepared) -> String {
        switch prepared {
        case .built: setupDoneLine
        case .alreadyReady: setupReadyLine
        }
    }

    static let setupReadyLine = "\(Glyph.done.rawValue) Mac boxes are ready.\n"
    static let setupDoneLine = "  \(Glyph.done.rawValue) Mac boxes are ready.\n"

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

    /// `rv init`, pointed at the project when the shell is elsewhere, with
    /// `--profile-id` when the id is not init's default.
    static func initCommand(project: String, workingDirectory: String, profileID: String) -> String {
        var command = "rv init"
        if normalized(workingDirectory) != project {
            command += " --project " + InitRun.shellWord(project)
        }
        if profileID != "main" { command += " --profile-id " + InitRun.shellWord(profileID) }
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

    private static func isInside(_ path: String, _ directory: String) -> Bool {
        normalized(path).hasPrefix(directory + "/")
    }

    private static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
        return String(path[..<slash])
    }
}
