import ArgumentParser
import Foundation
import RVDomain
import RVIsolation
import RVTheme
import Testing
@testable import RVCLI

/// `rv box`'s functional core: argument resolution, project root, profile
/// choice, launch shape and the exact words, all without a workspace host.
@Suite("rv box resolves a launch")
struct BoxPlanTests {
    static let home = "/Users/chris"
    static let app = "/Users/chris/code/app"
    static let onPath = [
        "claude": BoxPathHit(path: "/opt/homebrew/bin/claude", resolved: "/opt/homebrew/Cellar/claude/1/bin/claude"),
        "npm": BoxPathHit(path: "/opt/homebrew/bin/npm", resolved: "/opt/homebrew/lib/node_modules/npm/bin/npm-cli.js"),
    ]

    static func surroundings(
        in directory: String = app,
        policy: RuntimeResourcePolicy = .empty,
        secrets: SecretsConfiguration = .empty,
        repos: Set<String> = [app],
        path: [String: BoxPathHit] = onPath
    ) -> BoxSurroundings {
        BoxSurroundings(
            workingDirectory: directory,
            home: home,
            policy: policy,
            secrets: secrets,
            hasGitEntry: { repos.contains($0) },
            findOnPath: { path[$0] }
        )
    }

    static func profile(
        _ id: String, project: String = app, agents: [String] = [],
        links: [String: String] = [:], credentials: Bool = false, secrets: [String] = []
    ) -> RuntimeResourceProfile {
        RuntimeResourceProfile(
            id: id, projects: [project], agents: agents,
            executableLinks: links.sorted { $0.key < $1.key }.map { .init(name: $0.key, target: $0.value) },
            credentials: credentials
                ? [.init(source: "/Users/chris/.claude/.credentials.json", destination: ".claude/.credentials.json")] : [],
            secrets: secrets)
    }

    static func start(
        linux: Bool = false, mac: Bool = false, profile: String? = nil, _ captured: [String],
        _ surroundings: BoxSurroundings = surroundings()
    ) -> Result<BoxStart, BoxRefusal> {
        BoxPlan.start(linux: linux, mac: mac, profile: profile, captured: captured, surroundings: surroundings)
    }

    static func launch(_ start: Result<BoxStart, BoxRefusal>) throws -> BoxLaunch {
        guard case .success(.launch(let launch)) = start else {
            Issue.record("expected a launch, got \(start)")
            throw CancellationError()
        }
        return launch
    }

    static func refusal(_ start: Result<BoxStart, BoxRefusal>) throws -> BoxRefusal {
        guard case .failure(let refusal) = start else {
            Issue.record("expected a refusal, got \(start)")
            throw CancellationError()
        }
        return refusal
    }

    // MARK: Arguments

    @Test("captured words become a shell, an agent, a command, list or setup")
    func targets() {
        #expect(BoxPlan.target([]) == .success(.shell))
        #expect(BoxPlan.target(["claude"]) == .success(.agent("claude", arguments: [])))
        #expect(BoxPlan.target(["claude", "--resume"]) == .success(.agent("claude", arguments: ["--resume"])))
        #expect(BoxPlan.target(["claude", "--", "--help"]) == .success(.agent("claude", arguments: ["--help"])))
        #expect(BoxPlan.target(["--", "npm", "test"]) == .success(.command("npm", arguments: ["test"])))
        #expect(BoxPlan.target(["--", "list"]) == .success(.command("list", arguments: [])))
        #expect(BoxPlan.target(["./migrate.sh", "up"]) == .success(.command("./migrate.sh", arguments: ["up"])))
        #expect(BoxPlan.target(["list", "--json"]) == .success(.list(["--json"])))
        #expect(BoxPlan.target(["setup", "mac"]) == .success(.setupMac))
    }

    @Test("a wrong command line is one line, one fix, exit 64")
    func usageRefusals() throws {
        guard case .failure(let dash) = BoxPlan.target(["--"]),
              case .failure(let flag) = BoxPlan.target(["--foo"]),
              case .failure(let name) = BoxPlan.target(["my agent"]),
              case .failure(let setup) = BoxPlan.target(["setup", "linux"]),
              case .failure(let walls) = BoxPlan.wall(linux: true, mac: true, target: .agent("claude", arguments: []))
        else {
            Issue.record("expected refusals")
            return
        }
        #expect(dash.text == "✕ Nothing to run after --.\n  → rv box --help\n")
        #expect(flag.text == "✕ rv box has no --foo option.\n  → rv box --help\n")
        #expect(name.text == "✕ my agent isn't an agent name.\n  → rv box -- 'my agent'\n")
        #expect(setup.text == "✕ Only Mac boxes need a setup.\n  → rv box setup mac\n")
        #expect(walls.text == "✕ Pick one wall: --linux or --mac.\n  → rv box --linux claude\n")
        #expect([dash, flag, name, setup, walls].allSatisfy { $0.exitCode == 64 })
    }

    @Test("flags that would be ignored are refused")
    func ignoredFlags() throws {
        let shellProfile = try Self.refusal(Self.start(profile: "main", []))
        #expect(shellProfile.text
            == "✕ The box shell picks its own profile; --profile needs something to run.\n  → rv box --profile main claude\n")
        let shellVM = try Self.refusal(Self.start(linux: true, []))
        #expect(shellVM.text
            == "✕ The box shell runs in the cage; --linux and --mac need something to run.\n  → rv box --linux -- sh\n")
        #expect(BoxPlan.checkFlags(linux: true, mac: false, profile: nil, target: .list([]))?.text
            == "✕ rv box list takes no --linux, --mac or --profile.\n  → rv box list\n")
        #expect(BoxPlan.checkFlags(linux: false, mac: false, profile: "x", target: .setupMac)?.exitCode == 64)
        #expect(BoxPlan.checkFlags(linux: false, mac: false, profile: nil, target: .list(["--json"])) == nil)
    }

    @Test("a wall or profile flag after list or setup mac gets the same refusal as before it")
    func flagsAfterListOrSetup() throws {
        let listText = "✕ rv box list takes no --linux, --mac or --profile.\n  → rv box list\n"
        for words in [["list", "--linux"], ["list", "--mac", "--json"], ["list", "--json", "--profile", "main"], ["list", "--profile=main"]] {
            let parsed = try #require(try RV.parseAsRoot(["box"] + words) as? BoxCommand)
            #expect(parsed.words == words)
            guard case .failure(let refusal) = BoxPlan.target(parsed.words) else {
                Issue.record("\(words) was not refused"); continue
            }
            #expect(refusal.text == listText)
            #expect(refusal.exitCode == 64)
        }
        guard case .failure(let setup) = BoxPlan.target(["setup", "mac", "--linux"]) else {
            Issue.record("setup mac --linux was not refused"); return
        }
        #expect(setup.text == "✕ rv box setup mac takes no --linux, --mac or --profile.\n  → rv box setup mac\n")
        guard case .failure(let stray) = BoxPlan.target(["list", "--frob"]),
              case .failure(let word) = BoxPlan.target(["list", "all"]) else {
            Issue.record("stray list words were not refused"); return
        }
        #expect(stray.text == "✕ rv box list has no --frob option.\n  → rv box list\n")
        #expect(word.text == "✕ rv box list takes no all.\n  → rv box list\n")
        #expect(BoxPlan.target(["list", "--json"]) == .success(.list(["--json"])))
        #expect(BoxPlan.target(["list", "--help"]) == .success(.list(["--help"])))
        // Every word the list check lets through, BoxListCommand parses.
        for word in BoxPlan.listWords where word != "--help" && word != "-h" {
            #expect(throws: Never.self) { _ = try BoxListCommand.parse([word]) }
        }
    }

    @Test("--linux and --mac pick the VMs; nothing picks the cage")
    func walls() {
        let target = BoxTarget.agent("claude", arguments: [])
        #expect(BoxPlan.wall(linux: false, mac: false, target: target) == .success(.cage))
        #expect(BoxPlan.wall(linux: true, mac: false, target: target) == .success(.linux))
        #expect(BoxPlan.wall(linux: false, mac: true, target: target) == .success(.mac))
        #expect(BoxWall.cage.microVM == nil)
        #expect(BoxWall.linux.microVM == MicroVMLaunchOptions(image: "alpine:3.20"))
        #expect(BoxWall.mac.microVM == MicroVMLaunchOptions(image: "dev", guest: .macOS))
    }

    // MARK: Project

    @Test("the project is the repo root above the current folder")
    func repoRoot() {
        let has: (String) -> Bool = { $0 == Self.app }
        #expect(BoxPlan.projectRoot(from: Self.app, home: Self.home, hasGitEntry: has) == .success(Self.app))
        #expect(BoxPlan.projectRoot(from: Self.app + "/src/auth", home: Self.home, hasGitEntry: has) == .success(Self.app))
        #expect(BoxPlan.projectRoot(from: Self.app + "/src/../src/", home: Self.home, hasGitEntry: has) == .success(Self.app))
    }

    @Test("outside a repo the current folder is the project, and ~ is never one")
    func noRepo() {
        let none: (String) -> Bool = { _ in false }
        #expect(BoxPlan.projectRoot(from: "/Users/chris/notes", home: Self.home, hasGitEntry: none) == .success("/Users/chris/notes"))
        // A dotfiles repository in ~ does not make ~ the project.
        let dotfiles: (String) -> Bool = { $0 == Self.home }
        #expect(BoxPlan.projectRoot(from: "/Users/chris/notes/a", home: Self.home, hasGitEntry: dotfiles) == .success("/Users/chris/notes/a"))
        #expect(BoxPlan.projectRoot(from: "/srv/site", home: Self.home, hasGitEntry: { $0 == "/srv" }) == .success("/srv"))
    }

    @Test("home, a folder above home, and / refuse with one line")
    func homeRefuses() throws {
        let expected = BoxRefusal(why: "Your home folder can't be a box.", fix: BoxPlan.elsewhere)
        #expect(BoxPlan.projectRoot(from: Self.home, home: Self.home, hasGitEntry: { _ in true }) == .failure(expected))
        #expect(BoxPlan.projectRoot(from: Self.home + "/", home: Self.home, hasGitEntry: { _ in true }) == .failure(expected))
        let above = try Self.refusal(Self.start(["claude"], Self.surroundings(in: "/Users", repos: [])))
        #expect(above.text == "✕ /Users holds your home folder, so it can't be a box.\n  → cd into a project folder, then run rv box again\n")
        // A repo at /Users would not help: the folder itself is refused first.
        #expect(BoxPlan.projectRoot(from: "/Users", home: Self.home, hasGitEntry: { _ in true }) == .failure(
            BoxRefusal(why: "/Users holds your home folder, so it can't be a box.", fix: BoxPlan.elsewhere)))
        guard case .failure(let root) = BoxPlan.projectRoot(from: "/", home: Self.home, hasGitEntry: { _ in false }) else {
            Issue.record("/ must refuse")
            return
        }
        #expect(root.text == "✕ The root folder can't be a box.\n  → cd into a project folder, then run rv box again\n")
        #expect(BoxPlan.missingFolder.text == "✕ This folder no longer exists.\n  → cd into a project folder, then run rv box again\n")
    }

    @Test("no passwd home, no box")
    func noHome() {
        #expect(BoxPlan.projectRoot(from: Self.app, home: nil, hasGitEntry: { _ in true }) == .failure(BoxPlan.noHome))
        #expect(BoxPlan.noHome.text == "✕ rv can't find your home folder, so it can't keep it out of a box.\n  → rv doctor\n")
    }

    /// macOS: `/Users` is a firmlink into the Data volume, so the same
    /// folders have a second spelling that `realpath` keeps.
    @Test("the Data volume's spelling of home, or of a folder above it, is refused")
    func dataVolumeAliases() {
        let data = "/System/Volumes/Data"
        let ids: [String: UInt64] = [
            "/": 1, "/System": 2, "/System/Volumes": 3, data: 4,
            "/Users": 5, data + "/Users": 5, Self.home: 6, data + Self.home: 6,
            data + Self.home + "/notes": 7, Self.app: 8, data + Self.app: 8,
        ]
        let identity: (String) -> FileIdentity? = { ids[$0].map { FileIdentity(device: 1, inode: $0) } }
        func root(_ start: String, git: @escaping (String) -> Bool = { _ in false }) -> Result<String, BoxRefusal> {
            BoxPlan.projectRoot(from: start, home: Self.home, homeAliases: [data + Self.home], hasGitEntry: git, identity: identity)
        }
        #expect(root(data + Self.home) == .failure(BoxRefusal(why: "Your home folder can't be a box.", fix: BoxPlan.elsewhere)))
        for above in [data, data + "/Users", "/System/Volumes", "/System"] {
            #expect(root(above) == .failure(BoxRefusal(
                why: "\(above) holds your home folder, so it can't be a box.", fix: BoxPlan.elsewhere)), "\(above)")
        }
        // The walk up stops at home under its other spelling too.
        #expect(root(data + Self.home + "/notes", git: { $0 == data + Self.home }) == .success(data + Self.home + "/notes"))
        #expect(root(data + Self.app, git: { $0 == data + Self.app }) == .success(data + Self.app))
        // Without aliases, the identity of home's tail below the start still finds it.
        #expect(BoxPlan.projectRoot(from: data, home: Self.home, hasGitEntry: { _ in false }, identity: identity)
            == .failure(BoxRefusal(why: "\(data) holds your home folder, so it can't be a box.", fix: BoxPlan.elsewhere)))
    }

    @Test("a symlink to home or to a folder above it is caught by inode, on this machine")
    func symlinkAliases() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("rv-box-alias-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: base) }
        let home = base + "/home/me"
        try FileManager.default.createDirectory(atPath: home + "/code", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: base + "/me-link", withDestinationPath: home)
        try FileManager.default.createSymbolicLink(atPath: base + "/home-link", withDestinationPath: base + "/home")
        func root(_ start: String) -> Result<String, BoxRefusal> {
            BoxPlan.projectRoot(from: start, home: home, hasGitEntry: { _ in false }, identity: BoxRun.identity)
        }
        #expect(root(base + "/me-link") == .failure(BoxRefusal(why: "Your home folder can't be a box.", fix: BoxPlan.elsewhere)))
        #expect(root(base + "/home-link/me") == .failure(BoxRefusal(why: "Your home folder can't be a box.", fix: BoxPlan.elsewhere)))
        #expect(root(base + "/home-link") == .failure(BoxRefusal(
            why: "\(base)/home-link holds your home folder, so it can't be a box.", fix: BoxPlan.elsewhere)))
        #expect(root(home + "/code") == .success(home + "/code"))
        #expect(root(base + "/me-link/code") == .success(base + "/me-link/code"))
    }

    // MARK: Profile

    static func chosen(
        _ target: BoxTarget, _ policy: RuntimeResourcePolicy, named: String? = nil, wall: BoxWall = .cage
    ) -> Result<RuntimeResourceProfile?, BoxRefusal> {
        BoxPlan.profile(
            for: target, named: named, wall: wall, policy: policy, project: app, workingDirectory: app)
    }

    static let claude = BoxTarget.agent("claude", arguments: [])

    @Test("an agent takes the one profile that serves it here")
    func profileClaimedByAgent() {
        let main = Self.profile("main", agents: ["claude", "codex"])
        let other = Self.profile("ops", agents: ["muse"])
        let elsewhere = Self.profile("site", project: "/Users/chris/code/site", agents: ["claude"])
        let policy = RuntimeResourcePolicy(profiles: [other, main, elsewhere])
        #expect(Self.chosen(Self.claude, policy) == .success(main))
        // Legacy profiles claim by link name.
        let legacy = Self.profile("old", links: ["claude": "/opt/claude-wrapper"])
        #expect(Self.chosen(Self.claude, RuntimeResourcePolicy(profiles: [legacy])) == .success(legacy))
    }

    @Test("with no claim, the operator default serves this project if its marks allow the agent")
    func profileDefault() {
        let shell = Self.profile("shell")
        let foreign = Self.profile("foreign", project: "/elsewhere")
        let policy = RuntimeResourcePolicy(profiles: [shell, foreign], defaultProfile: "shell")
        #expect(Self.chosen(Self.claude, policy) == .success(shell))
        #expect(Self.chosen(.shell, policy) == .success(shell))
        #expect(Self.chosen(.command("npm", arguments: []), policy) == .success(shell))
        #expect(Self.chosen(Self.claude, RuntimeResourcePolicy(profiles: [shell])) == .success(nil))
        #expect(Self.chosen(Self.claude, RuntimeResourcePolicy(profiles: [foreign], defaultProfile: "foreign")) == .success(nil))
        #expect(Self.chosen(Self.claude, .empty) == .success(nil))
        // A default marked for other agents does not serve claude.
        let museOnly = Self.profile("muse", agents: ["muse"])
        #expect(Self.chosen(Self.claude, RuntimeResourcePolicy(profiles: [museOnly], defaultProfile: "muse")) == .success(nil))
    }

    @Test("two claiming profiles: the default breaks the tie, else one line names --profile")
    func profileAmbiguous() {
        let a = Self.profile("a", agents: ["claude"])
        let b = Self.profile("b", agents: ["claude"])
        #expect(Self.chosen(Self.claude, RuntimeResourcePolicy(profiles: [a, b], defaultProfile: "b")) == .success(b))
        guard case .failure(let refusal) = Self.chosen(Self.claude, RuntimeResourcePolicy(profiles: [b, a])) else {
            Issue.record("ambiguous profiles must refuse")
            return
        }
        #expect(refusal.text == "✕ 2 profiles serve claude here: a, b.\n  → rv box --profile a claude\n")
    }

    @Test("--profile must serve this project; the rv init fix names a free id")
    func profileExplicit() {
        let main = Self.profile("main")
        let site = Self.profile("site", project: "/Users/chris/code/site")
        let policy = RuntimeResourcePolicy(profiles: [main, site])
        #expect(Self.chosen(Self.claude, policy, named: "main") == .success(main))
        guard case .failure(let taken) = Self.chosen(Self.claude, policy, named: "site"),
              case .failure(let fresh) = BoxPlan.profile(
                for: Self.claude, named: "x", wall: .cage, policy: policy, project: Self.app,
                workingDirectory: Self.app + "/src")
        else {
            Issue.record("a profile that does not serve this project must refuse")
            return
        }
        #expect(taken.text == "✕ No profile site serves /Users/chris/code/app.\n  → rv init --profile-id site-2\n")
        #expect(fresh.fix == "rv init --project /Users/chris/code/app --profile-id x")
        #expect(BoxPlan.freeProfileID("main", policy: .empty) == "main")
        #expect(BoxPlan.freeProfileID("main", policy: RuntimeResourcePolicy(profiles: [main, Self.profile("main-2")])) == "main-3")
    }

    @Test("a VM wall never picks a profile that shares host files")
    func vmSkipsHostPathProfiles() throws {
        let initStyle = Self.profile("main", agents: ["claude"], links: ["claude": "/opt/homebrew/bin/claude"], credentials: true)
        let secretsOnly = Self.profile("keys", agents: ["claude"], secrets: ["ANTHROPIC_API_KEY"])
        // Implicit: skipped, and the keys hint points at the cage, not rv init.
        let skipped = try Self.launch(Self.start(
            linux: true, ["claude"], Self.surroundings(policy: RuntimeResourcePolicy(profiles: [initStyle]))))
        #expect(skipped.profile == nil)
        #expect(skipped.keys == .none(next: "keys need the cage: rv box claude"))
        // A secrets-only profile still serves the VM.
        let kept = try Self.launch(Self.start(
            mac: true, ["claude"], Self.surroundings(policy: RuntimeResourcePolicy(profiles: [initStyle, secretsOnly]))))
        #expect(kept.profile == secretsOnly)
        // Explicit: refused up front, with the cage as the fix.
        let refused = try Self.refusal(Self.start(
            linux: true, profile: "main", ["claude"],
            Self.surroundings(policy: RuntimeResourcePolicy(profiles: [initStyle]))))
        #expect(refused.text == "✕ Profile main shares host files, which a VM box can't see.\n  → rv box --profile main claude\n")
    }

    // MARK: Launch

    @Test("rv box claude from a subfolder: repo root, PATH agent as PATH names it, hook, no flags")
    func cageAgent() throws {
        let launch = try Self.launch(Self.start(["claude", "--resume"], Self.surroundings(in: Self.app + "/src")))
        #expect(launch == BoxLaunch(
            wall: .cage, project: Self.app, executable: "/opt/homebrew/bin/claude",
            arguments: ["--resume"], hook: .claude, profile: nil,
            keys: .none(next: "rv init --project /Users/chris/code/app")))
    }

    @Test("a profile's link wins over PATH in the cage")
    func cageAgentFromLink() throws {
        let main = Self.profile("main", agents: ["claude"], links: ["claude": "/Users/chris/.local/bin/claude-wrapper"])
        let launch = try Self.launch(Self.start(["claude"], Self.surroundings(policy: RuntimeResourcePolicy(profiles: [main]))))
        #expect(launch.executable == "/Users/chris/.local/bin/claude-wrapper")
        #expect(launch.profile == main)
        #expect(launch.keys == .profile(id: "main", secrets: []))
    }

    @Test("with a profile staged, a PATH hit inside the project is refused")
    func plantedBinary() throws {
        let main = Self.profile("main", agents: ["claude"])
        let planted = ["claude": BoxPathHit(path: Self.app + "/.venv/bin/claude", resolved: Self.app + "/.venv/bin/claude")]
        let refusal = try Self.refusal(Self.start(
            ["claude"], Self.surroundings(policy: RuntimeResourcePolicy(profiles: [main]), path: planted)))
        #expect(refusal.text == """
            ✕ The claude on your PATH is inside this project, so it can't have profile main's keys.
              → link claude in profile main (executableLinks in ~/.config/rv/runtime-resources.json)

            """)
        // A symlink outside that resolves inside counts too.
        let linked = ["claude": BoxPathHit(path: "/Users/chris/bin/claude", resolved: Self.app + "/node_modules/.bin/claude")]
        #expect(throws: Never.self) {
            _ = try Self.refusal(Self.start(
                ["claude"], Self.surroundings(policy: RuntimeResourcePolicy(profiles: [main]), path: linked)))
        }
        // Without a profile there are no keys to take: it runs.
        let keyless = try Self.launch(Self.start(["claude"], Self.surroundings(path: planted)))
        #expect(keyless.executable == Self.app + "/.venv/bin/claude")
    }

    @Test("commands: bare names from PATH, relative paths from here, absolute as is")
    func cageCommands() throws {
        let here = Self.surroundings(in: Self.app + "/scripts")
        let npm = try Self.launch(Self.start(["--", "npm", "test"], here))
        #expect(npm.executable == "/opt/homebrew/bin/npm")
        #expect(npm.arguments == ["test"])
        #expect(npm.hook == nil)
        let relative = try Self.launch(Self.start(["--", "./migrate.sh"], here))
        #expect(relative.executable == Self.app + "/scripts/migrate.sh")
        let absolute = try Self.launch(Self.start(["--", "/bin/zsh", "-l"], here))
        #expect(absolute.executable == "/bin/zsh")
        #expect(absolute.arguments == ["-l"])
    }

    @Test("an agent rv knows no hook for runs untagged")
    func untaggedAgent() throws {
        let launch = try Self.launch(Self.start(
            ["aider"], Self.surroundings(path: ["aider": BoxPathHit(path: "/usr/local/bin/aider", resolved: "/usr/local/bin/aider")])))
        #expect(launch.hook == nil)
        #expect(launch.executable == "/usr/local/bin/aider")
    }

    @Test("a missing agent is one line and one fix")
    func agentMissing() throws {
        let refusal = try Self.refusal(Self.start(["codex"]))
        #expect(refusal.text == "✕ No codex on your PATH.\n  → rv box -- /full/path/to/codex\n")
        #expect(refusal.exitCode == 1)
    }

    @Test("VMs look names up on the guest's PATH")
    func vmLaunches() throws {
        let linux = try Self.launch(Self.start(linux: true, ["--", "npm", "test"]))
        #expect(linux.wall == .linux)
        #expect(linux.executable == "/usr/bin/env")
        #expect(linux.arguments == ["npm", "test"])
        let mac = try Self.launch(Self.start(mac: true, ["claude", "run the UI test"]))
        #expect(mac.wall == .mac)
        #expect(mac.executable == "/usr/bin/env")
        #expect(mac.arguments == ["claude", "run the UI test"])
        #expect(mac.hook == .claude)
        let script = try Self.launch(Self.start(linux: true, ["--", "./migrate.sh"]))
        #expect(script.executable == Self.app + "/migrate.sh")
        #expect(script.arguments.isEmpty)
    }

    @Test("rv box alone is the shell")
    func shell() {
        #expect(Self.start([], Self.surroundings(in: Self.app + "/src")) == .success(.shell(project: Self.app)))
    }

    // MARK: Words

    static func secret(_ name: String, gateway: Bool) -> SecretDefinition {
        SecretDefinition(
            name: name, source: .keychain(service: "rv", account: name),
            delivery: gateway
                ? .gateway(SecretGatewayBinding(upstream: URL(string: "https://api.anthropic.com")!, baseURLEnv: "ANTHROPIC_BASE_URL"))
                : .environment)
    }

    @Test("the keys line says the value never enters only for gateway placeholders")
    func keysWords() {
        let gateway = SecretsConfiguration(secrets: [Self.secret("ANTHROPIC_API_KEY", gateway: true), Self.secret("PLAIN", gateway: false)])
        func keys(_ profile: RuntimeResourceProfile?) -> BoxKeys {
            BoxPlan.keys(profile, secrets: gateway, wall: .cage, target: Self.claude, policy: .empty,
                         project: Self.app, workingDirectory: Self.app)
        }
        #expect(keys(Self.profile("main", secrets: ["ANTHROPIC_API_KEY"])) == .placeholders(["ANTHROPIC_API_KEY"]))
        #expect(keys(Self.profile("main", secrets: ["ANTHROPIC_API_KEY", "PLAIN"])) == .profile(id: "main", secrets: ["ANTHROPIC_API_KEY", "PLAIN"]))
        #expect(keys(Self.profile("main", credentials: true, secrets: ["ANTHROPIC_API_KEY"])) == .profile(id: "main", secrets: ["ANTHROPIC_API_KEY"]))
        #expect(keys(Self.profile("main", secrets: ["UNDEFINED"])) == .profile(id: "main", secrets: ["UNDEFINED"]))
        #expect(keys(nil) == .none(next: "rv init"))
        let mainTaken = RuntimeResourcePolicy(profiles: [Self.profile("main", project: "/elsewhere")])
        #expect(BoxPlan.keys(nil, secrets: .empty, wall: .cage, target: Self.claude, policy: mainTaken,
                             project: Self.app, workingDirectory: Self.app) == .none(next: "rv init --profile-id main-2"))
    }

    static func launchFor(_ wall: BoxWall, keys: BoxKeys, profile: RuntimeResourceProfile? = nil) -> BoxLaunch {
        BoxLaunch(wall: wall, project: app, executable: "/opt/homebrew/bin/claude", arguments: [],
                  hook: .claude, profile: profile, keys: keys)
    }

    @Test("the start lines match v4 Contained")
    func startLines() {
        let launch = Self.launchFor(.cage, keys: .placeholders(["ANTHROPIC_API_KEY"]))
        #expect(BoxPlan.headerLine(launch, home: Self.home) == "◆ rv · box for ~/code/app\n")
        #expect(BoxPlan.launchedLines(launch, seconds: 0.43, home: Self.home, workingDirectory: Self.app) == """
              ✓ sealed    writes stay in the box until you bring them home
              ✓ keys      ANTHROPIC_API_KEY via rv · the value never enters
              ✓ network   public HTTPS through rv · LAN closed
              ready in 0.4 s

            """)
        #expect(BoxPlan.exitLine(project: Self.app, workingDirectory: Self.app, home: Self.home)
            == "  → bring the writes home: rv workspace close\n")
        #expect(BoxPlan.exitLine(project: Self.app, workingDirectory: Self.app + "/src", home: Self.home)
            == "  → bring the writes home: rv workspace close --workspace ~/code/app\n")
    }

    @Test("no keys: the state, then the step last; a subfolder start names the root")
    func startLinesWithoutKeys() {
        let linux = Self.launchFor(.linux, keys: .none(next: "keys need the cage: rv box claude"))
        #expect(BoxPlan.headerLine(linux, home: Self.home) == "◆ rv · linux box for ~/code/app · alpine 3.20\n")
        #expect(BoxPlan.launchedLines(linux, seconds: 1.04, home: Self.home, workingDirectory: Self.app + "/src") == """
              ✓ sealed    writes stay in the box until you bring them home
              ◐ keys      none staged
              ✓ network   public HTTPS through rv · no network card
              ready in 1.0 s · starts in ~/code/app
              → keys need the cage: rv box claude

            """)
        let mac = Self.launchFor(.mac, keys: .profile(id: "main", secrets: ["A", "B"]))
        #expect(BoxPlan.headerLine(mac, home: Self.home) == "◆ rv · mac box for ~/code/app · image dev\n")
        #expect(BoxPlan.launchedLines(mac, seconds: 0, home: Self.home, workingDirectory: Self.app)
            .contains("  ✓ keys      A, B via rv · profile main\n"))
    }

    @Test("rv box setup mac leaves a ready image alone and builds a missing one")
    func setupMac() throws {
        let mac = try #require(BoxWall.mac.microVM)
        var calls: [[String]] = []
        var announced = 0
        func setup(status: Int32, prepare: Int32 = 0) throws(WorkspaceMicroVM.Unready) -> WorkspaceMicroVM.Prepared {
            calls = []
            return try WorkspaceMicroVM.prepare(mac, helper: "/opt/rv/rv-macvm", willBuild: { announced += 1 }) { _, arguments, _, _ in
                calls.append(arguments)
                return arguments.first == "status" ? status : prepare
            }
        }
        #expect(try setup(status: 0) == .alreadyReady)
        #expect(calls == [["status", "--image", "dev"]])
        #expect(announced == 0)
        #expect(BoxPlan.setupFinishedText(.alreadyReady) == "✓ Mac boxes are ready.\n")
        #expect(try setup(status: 1) == .built)
        #expect(calls == [["status", "--image", "dev"], ["prepare", "--image", "dev"]])
        #expect(announced == 1)
        #expect(BoxPlan.setupFinishedText(.built) == "  ✓ Mac boxes are ready.\n")
        #expect(throws: WorkspaceMicroVM.Unready.prepareFailed(mac, status: 2)) { try setup(status: 1, prepare: 2) }
        #expect(throws: WorkspaceMicroVM.Unready.helperMissing(.macOS)) {
            try WorkspaceMicroVM.prepare(mac, helper: nil, willBuild: {}) { _, _, _, _ in 0 }
        }
    }

    @Test("VM start failures are one line and one fix")
    func vmRefusals() {
        let mac = MicroVMLaunchOptions(image: "dev", guest: .macOS)!
        let linux = MicroVMLaunchOptions(image: "alpine:3.20")!
        #expect(BoxPlan.refusal(.notPrepared(mac)).text
            == "◐ Mac boxes need a one-time setup: about 26 GB to download.\n  → rv box setup mac\n")
        #expect(BoxPlan.refusal(.helperMissing(.linux)).text
            == "✕ Linux boxes need rv-microvm next to rv.\n  → reinstall rv, or build it: Scripts/build-microvm.sh\n")
        #expect(BoxPlan.refusal(.prepareFailed(linux, status: 3)).text
            == "✕ The Linux image alpine:3.20 could not be fetched (rv-microvm exit 3).\n  → rv doctor\n")
        #expect(BoxPlan.refusal(.prepareFailed(mac, status: 1)).text
            == "✕ The Mac image could not be set up (rv-macvm exit 1).\n  → rv doctor\n")
        // rv workspace run keeps its own words.
        #expect(WorkspaceMicroVM.Unready.notPrepared(mac).message
            == "macOS image dev is not prepared; build it once with: rv-macvm prepare --image dev")
        #expect(WorkspaceMicroVM.Unready.prepareFailed(linux, status: 3).message
            == "micro-VM image alpine:3.20 could not be prepared (rv-microvm exit 3)")
    }

    @Test("every host failure gets a → fix")
    func hostRefusals() {
        let trustText = "the workspace host was refused: pinned to another build; any host this start launched "
            + "was stopped; run 'rv doctor', and 'rv workspace leftovers' for anything it left"
        let startingText = "the workspace host this start launched is still mounting or recovering; it keeps running "
            + "in the background — run 'rv workspace status' to see when it is ready, then "
            + "'rv workspace start' again to attach"
        let timedOutText = "workspace host did not become ready in time; run 'rv workspace status' to check it, "
            + "or 'rv doctor' if it persists"
        #if os(macOS)
        // The host texts are macOS-only; pin the copies above to them.
        #expect(WorkspaceCommandRun.ensureFailureText(.control(.unauthorizedClient), hostTrustReason: "pinned to another build") == trustText)
        #expect(WorkspaceCommandRun.ensureFailureText(.stillStarting, hostTrustReason: nil) == startingText)
        #expect(WorkspaceCommandRun.ensureFailureText(.timedOut, hostTrustReason: nil) == timedOutText)
        #endif
        #expect(BoxPlan.hostRefusal(trustText).text
            == "✕ Boxes can't open on this Mac: the box helper's trust pin doesn't match this rv.\n  → see the fix (it needs an administrator): rv doctor\n")
        #expect(BoxPlan.hostRefusal(WorkspaceCommandRun.hostNotReachableText).text
            == "✕ Workspace host is not reachable.\n  → rv workspace status\n")
        #expect(BoxPlan.hostRefusal(timedOutText).text
            == "✕ Workspace host did not become ready in time.\n  → rv workspace status\n")
        #expect(BoxPlan.hostRefusal(startingText).text
            == "◐ The box is still starting in the background.\n  → run rv box again once it is ready: rv workspace status\n")
        #expect(BoxPlan.hostRefusal("runtime resource profile 'main' is unavailable for this project").text
            == "✕ Runtime resource profile 'main' is unavailable for this project.\n  → rv doctor\n")
    }

    @Test("paths show under ~ and copy back safely")
    func paths() {
        #expect(BoxPlan.displayPath("/Users/chris/code/app", home: Self.home) == "~/code/app")
        #expect(BoxPlan.displayPath("/Users/chrisx/app", home: Self.home) == "/Users/chrisx/app")
        #expect(BoxPlan.displayPath("/srv/app", home: nil) == "/srv/app")
        #expect(BoxPlan.shellPath("/Users/chris/my app", home: Self.home) == "'/Users/chris/my app'")
        #expect(BoxPlan.shellPath("/Users/chris/code/app", home: Self.home) == "~/code/app")
    }
}

@Suite("rv box list")
struct BoxListTests {
    static let utc = TimeZone(identifier: "UTC")!

    @Test("no boxes points at rv box")
    func empty() {
        #expect(BoxListRender.text([], home: "/Users/chris", timeZone: Self.utc) == "◆ rv · no boxes\n  → rv box claude\n")
        #expect(BoxListRender.text([], home: nil, platformNote: "boxes run on macOS only today", timeZone: Self.utc)
            == "◆ rv · no boxes · boxes run on macOS only today\n")
    }

    @Test("boxes newest first, one line each, the fix last")
    func rows() {
        let app = UUID(), site = UUID(), stuck = UUID()
        let boxes = [
            BoxListing(project: "/Users/chris/code/site", workspace: site, state: .unfinished,
                       lastActive: Date(timeIntervalSince1970: 1_763_510_400), walls: ["cage"]),
            BoxListing(project: "/Users/chris/code/app", workspace: app, state: .open,
                       lastActive: Date(timeIntervalSince1970: 1_763_769_600), walls: ["cage", "vm"]),
            BoxListing(project: "/tmp/try", workspace: stuck, state: .blocked,
                       lastActive: Date(timeIntervalSince1970: 1_763_337_600)),
        ]
        #expect(BoxListRender.text(boxes, home: "/Users/chris", timeZone: Self.utc) == """
            ◆ rv · 3 boxes
              ✓ ~/code/app    open · cage · vm · Nov 22
              ◐ ~/code/site   never finished · cage · Nov 19 · rv workspace start --workspace ~/code/site
              ✕ /tmp/try      blocked · Nov 17 · rv workspace status --workspace /tmp/try

            """)
    }

    @Test("walls come from the runtimes started in that workspace")
    func walls() {
        let mine = UUID(), other = UUID()
        let runtimes: [(workspace: UUID?, backend: String)] = [
            (mine, "microvm"), (mine, "seatbelt"), (other, "seatbelt"), (nil, "microvm"),
        ]
        #expect(BoxListRender.walls(for: mine, runtimes: runtimes) == ["cage", "vm"])
        #expect(BoxListRender.walls(for: other, runtimes: runtimes) == ["cage"])
        #expect(BoxListRender.walls(for: UUID(), runtimes: runtimes).isEmpty)
    }

    @Test("--json is rv.boxes.v1")
    func json() throws {
        let box = BoxListing(project: "/p", workspace: UUID(), state: .open,
                             lastActive: Date(timeIntervalSince1970: 0), walls: ["cage"])
        let text = try RobotJSON.encode(BoxListRender.document([box]), options: .compactISO8601)
        #expect(text == #"{"boxes":[{"last_active":"1970-01-01T00:00:00Z","project":"/p","state":"open","walls":["cage"]}],"schema":"rv.boxes.v1"}"#)
        #expect(try RobotJSON.encode(BoxListRender.document([]), options: .compactISO8601) == #"{"boxes":[],"schema":"rv.boxes.v1"}"#)
    }
}

@Suite("rv box parses and has its own help")
struct BoxCommandTests {
    @Test("the parser routes box words and list")
    func parses() throws {
        let agent = try #require(try RV.parseAsRoot(["box", "claude", "--resume"]) as? BoxCommand)
        #expect(agent.words == ["claude", "--resume"])
        #expect(agent.linux == false)
        let vm = try #require(try RV.parseAsRoot(["box", "--linux", "--", "npm", "test"]) as? BoxCommand)
        #expect(vm.linux)
        #expect(BoxPlan.target(vm.words) == .success(.command("npm", arguments: ["test"])))
        let mac = try #require(try RV.parseAsRoot(["box", "--mac", "--profile", "main", "claude"]) as? BoxCommand)
        #expect(mac.mac)
        #expect(mac.profile == "main")
        #expect(mac.words == ["claude"])
        // `list` is read from the captured words, not by the parser.
        let list = try #require(try RV.parseAsRoot(["box", "list", "--json"]) as? BoxCommand)
        #expect(list.words == ["list", "--json"])
        #expect(try BoxListCommand.parse(["--json"]).format.json)
        #expect(try RV.parseAsRoot(["box"]) is BoxCommand)
    }

    @Test("rv box --help is rv's box page; an agent's --help is the agent's")
    func help() {
        #expect(HelpDispatch.topic(arguments: ["box", "--help"]) == .box)
        #expect(HelpDispatch.topic(arguments: ["help", "box"]) == .box)
        #expect(HelpDispatch.topic(arguments: ["help", "box", "list"]) == .box)
        #expect(HelpDispatch.topic(arguments: ["help", "box", "setup", "mac"]) == .box)
        // Captured; `BoxCommand` answers it with this page itself.
        #expect(HelpDispatch.topic(arguments: ["box", "list", "--help"]) == nil)
        #expect(HelpDispatch.topic(arguments: ["box", "--linux", "--help"]) == .box)
        #expect(HelpDispatch.topic(arguments: ["box", "claude", "--help"]) == nil)
        let page = HelpDispatch.text(.box, palette: colorOffPalette)
        #expect(page.contains("rv box [--linux | --mac] [--profile <id>] [<agent> [args...]]"))
        #expect(page.contains("rv box list [--json]"))
        #expect(page.contains("rv box setup mac"))
        #expect(page.contains("rv-macvm") == false)
        let root = HelpCatalog.page(.root).sections.flatMap(\.rows).map(\.name)
        #expect(root.contains("box"))
    }
}

/// Only the glyphs take colour, and only on a terminal.
@Suite("rv box colours its glyphs")
struct BoxInkTests {
    static let color = Palette(for: ColorCapability(colorsEnabled: true))

    @Test("refusals: red ✕, blue →; the words stay plain")
    func refusal() {
        let refusal = BoxRefusal(why: "No codex on your PATH.", fix: "rv box -- /full/path/to/codex")
        #expect(BoxInk.paint(refusal.text, palette: Self.color)
            == "\u{1B}[1;31m✕\u{1B}[0m No codex on your PATH.\n  \u{1B}[1;34m→\u{1B}[0m rv box -- /full/path/to/codex\n")
        let setup = BoxRefusal(mark: .setup, why: "Mac boxes need a one-time setup.", fix: "rv box setup mac")
        #expect(BoxInk.paint(setup.text, palette: Self.color)
            == "\u{1B}[1;33m◐\u{1B}[0m Mac boxes need a one-time setup.\n  \u{1B}[1;34m→\u{1B}[0m rv box setup mac\n")
    }

    @Test("rv's ◆ and the ✓ lines")
    func headerAndList() {
        #expect(BoxInk.paint(BoxListRender.text([], home: nil), palette: Self.color)
            == "\u{1B}[1;36m◆\u{1B}[0m rv · no boxes\n  \u{1B}[1;34m→\u{1B}[0m rv box claude\n")
        #expect(BoxInk.paint("  ✓ sealed    writes stay in the box\n", palette: Self.color)
            == "  \u{1B}[1;32m✓\u{1B}[0m sealed    writes stay in the box\n")
        // A glyph that is not a line's lead, or not followed by a space, stays plain.
        #expect(BoxInk.paint("  ready in 0.4 s · → x\n→x\n", palette: Self.color) == "  ready in 0.4 s · → x\n→x\n")
    }

    @Test("plain when piped, with NO_COLOR, with TERM=dumb, or in CI")
    func plain() {
        let text = BoxRefusal(why: "Your home folder can't be a box.", fix: "rv box --help").text
        #expect(BoxInk.paint(text, palette: colorOffPalette) == text)
        #expect(BoxInk.palette(isTerminal: true, environment: ["TERM": "xterm-256color"]).colorsEnabled)
        #expect(BoxInk.palette(isTerminal: false, environment: ["TERM": "xterm-256color"]).colorsEnabled == false)
        #expect(BoxInk.palette(isTerminal: true, environment: ["TERM": "xterm-256color", "NO_COLOR": "1"]).colorsEnabled == false)
        #expect(BoxInk.palette(isTerminal: true, environment: ["TERM": "dumb"]).colorsEnabled == false)
        #expect(BoxInk.palette(isTerminal: true, environment: ["TERM": "xterm-256color", "CI": "1"]).colorsEnabled == false)
        let piped = BoxInk.palette(isTerminal: false, environment: [:])
        #expect(BoxInk.paint(text, palette: piped) == text)
    }
}
