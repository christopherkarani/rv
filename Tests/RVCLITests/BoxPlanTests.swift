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

    static func surroundings(
        in directory: String = app,
        policy: RuntimeResourcePolicy = .empty,
        repos: Set<String> = [app],
        path: [String: String] = ["claude": "/opt/homebrew/bin/claude", "npm": "/opt/homebrew/bin/npm"]
    ) -> BoxSurroundings {
        BoxSurroundings(
            workingDirectory: directory,
            home: home,
            policy: policy,
            hasGitEntry: { repos.contains($0) },
            findOnPath: { path[$0] }
        )
    }

    static func profile(
        _ id: String, project: String = app, agents: [String] = [],
        links: [String: String] = [:], secrets: [String] = []
    ) -> RuntimeResourceProfile {
        RuntimeResourceProfile(
            id: id, projects: [project], agents: agents,
            executableLinks: links.sorted { $0.key < $1.key }.map { .init(name: $0.key, target: $0.value) },
            secrets: secrets)
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

    @Test("captured words become a shell, an agent or a command")
    func targets() {
        #expect(BoxPlan.target([]) == .success(.shell))
        #expect(BoxPlan.target(["claude"]) == .success(.agent("claude", arguments: [])))
        #expect(BoxPlan.target(["claude", "--resume"]) == .success(.agent("claude", arguments: ["--resume"])))
        #expect(BoxPlan.target(["claude", "--", "--help"]) == .success(.agent("claude", arguments: ["--help"])))
        #expect(BoxPlan.target(["--", "npm", "test"]) == .success(.command("npm", arguments: ["test"])))
        #expect(BoxPlan.target(["--", "./migrate.sh"]) == .success(.command("./migrate.sh", arguments: [])))
        #expect(BoxPlan.target(["./migrate.sh", "up"]) == .success(.command("./migrate.sh", arguments: ["up"])))
    }

    @Test("a wrong command line is one line, one fix, exit 64")
    func usageRefusals() throws {
        guard case .failure(let dash) = BoxPlan.target(["--"]),
              case .failure(let flag) = BoxPlan.target(["--foo"]),
              case .failure(let name) = BoxPlan.target(["my agent"]),
              case .failure(let walls) = BoxPlan.wall(linux: true, mac: true, target: .agent("claude", arguments: []))
        else {
            Issue.record("expected refusals")
            return
        }
        #expect(dash.text == "✕ Nothing to run after --.\n  → rv box --help\n")
        #expect(flag.text == "✕ rv box has no --foo option.\n  → rv box --help\n")
        #expect(name.text == "✕ my agent isn't an agent name.\n  → rv box -- 'my agent'\n")
        #expect(walls.text == "✕ Pick one wall: --linux or --mac.\n  → rv box --linux claude\n")
        #expect([dash, flag, name, walls].allSatisfy { $0.exitCode == 64 })
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

    @Test("home and / refuse with one line")
    func homeRefuses() {
        let expected = BoxRefusal(
            why: "Your home folder can't be a box.", fix: "cd into a project folder, then run rv box again")
        #expect(BoxPlan.projectRoot(from: Self.home, home: Self.home, hasGitEntry: { _ in true }) == .failure(expected))
        #expect(BoxPlan.projectRoot(from: Self.home + "/", home: Self.home, hasGitEntry: { _ in true }) == .failure(expected))
        guard case .failure(let root) = BoxPlan.projectRoot(from: "/", home: Self.home, hasGitEntry: { _ in false }) else {
            Issue.record("/ must refuse")
            return
        }
        #expect(root.text == "✕ The root folder can't be a box.\n  → cd into a project folder, then run rv box again\n")
    }

    // MARK: Profile

    static func chosen(
        _ target: BoxTarget, _ policy: RuntimeResourcePolicy, named: String? = nil
    ) -> Result<RuntimeResourceProfile?, BoxRefusal> {
        BoxPlan.profile(
            for: target, named: named, wall: .cage, policy: policy, project: app, workingDirectory: app)
    }

    @Test("an agent takes the one profile that serves it here")
    func profileClaimedByAgent() {
        let claude = Self.profile("main", agents: ["claude", "codex"])
        let other = Self.profile("ops", agents: ["muse"])
        let elsewhere = Self.profile("site", project: "/Users/chris/code/site", agents: ["claude"])
        let policy = RuntimeResourcePolicy(profiles: [other, claude, elsewhere])
        #expect(Self.chosen(.agent("claude", arguments: []), policy) == .success(claude))
        // Legacy profiles claim by link name.
        let legacy = Self.profile("old", links: ["claude": "/opt/claude-wrapper"])
        #expect(Self.chosen(.agent("claude", arguments: []), RuntimeResourcePolicy(profiles: [legacy])) == .success(legacy))
    }

    @Test("with no claim, the operator default serves this project or nothing does")
    func profileDefault() {
        let shell = Self.profile("shell")
        let foreign = Self.profile("foreign", project: "/elsewhere")
        let policy = RuntimeResourcePolicy(profiles: [shell, foreign], defaultProfile: "shell")
        #expect(Self.chosen(.agent("claude", arguments: []), policy) == .success(shell))
        #expect(Self.chosen(.shell, policy) == .success(shell))
        #expect(Self.chosen(.command("npm", arguments: []), policy) == .success(shell))
        let noDefault = RuntimeResourcePolicy(profiles: [shell])
        #expect(Self.chosen(.agent("claude", arguments: []), noDefault) == .success(nil))
        let foreignDefault = RuntimeResourcePolicy(profiles: [foreign], defaultProfile: "foreign")
        #expect(Self.chosen(.agent("claude", arguments: []), foreignDefault) == .success(nil))
        #expect(Self.chosen(.agent("claude", arguments: []), .empty) == .success(nil))
    }

    @Test("two claiming profiles: the default breaks the tie, else one line names --profile")
    func profileAmbiguous() {
        let a = Self.profile("a", agents: ["claude"])
        let b = Self.profile("b", agents: ["claude"])
        #expect(Self.chosen(.agent("claude", arguments: []), RuntimeResourcePolicy(profiles: [a, b], defaultProfile: "b")) == .success(b))
        guard case .failure(let refusal) = Self.chosen(.agent("claude", arguments: []), RuntimeResourcePolicy(profiles: [b, a])) else {
            Issue.record("ambiguous profiles must refuse")
            return
        }
        #expect(refusal.text == "✕ 2 profiles serve claude here: a, b.\n  → rv box --profile a claude\n")
    }

    @Test("--profile must serve this project")
    func profileExplicit() {
        let main = Self.profile("main")
        let site = Self.profile("site", project: "/Users/chris/code/site")
        let policy = RuntimeResourcePolicy(profiles: [main, site])
        #expect(Self.chosen(.agent("claude", arguments: []), policy, named: "main") == .success(main))
        guard case .failure(let refusal) = Self.chosen(.agent("claude", arguments: []), policy, named: "site") else {
            Issue.record("a profile for another project must refuse")
            return
        }
        #expect(refusal.text == "✕ No profile site serves /Users/chris/code/app.\n  → rv init --profile-id site\n")
        let fromSubfolder = BoxPlan.profile(
            for: .shell, named: "x", wall: .cage, policy: policy, project: Self.app,
            workingDirectory: Self.app + "/src")
        #expect((try? fromSubfolder.get()) == nil)
        if case .failure(let sub) = fromSubfolder {
            #expect(sub.fix == "rv init --project /Users/chris/code/app --profile-id x")
        }
    }

    // MARK: Launch

    @Test("rv box claude from a subfolder: repo root, PATH agent, hook, no flags")
    func cageAgent() throws {
        let start = BoxPlan.start(
            linux: false, mac: false, profile: nil, captured: ["claude", "--resume"],
            surroundings: Self.surroundings(in: Self.app + "/src"))
        let launch = try Self.launch(start)
        #expect(launch == BoxLaunch(
            wall: .cage, project: Self.app, executable: "/opt/homebrew/bin/claude",
            arguments: ["--resume"], hook: .claude, profile: nil))
    }

    @Test("a profile's link wins over PATH in the cage")
    func cageAgentFromLink() throws {
        let main = Self.profile("main", agents: ["claude"], links: ["claude": "/Users/chris/.local/bin/claude-wrapper"])
        let launch = try Self.launch(BoxPlan.start(
            linux: false, mac: false, profile: nil, captured: ["claude"],
            surroundings: Self.surroundings(policy: RuntimeResourcePolicy(profiles: [main]))))
        #expect(launch.executable == "/Users/chris/.local/bin/claude-wrapper")
        #expect(launch.profile == main)
    }

    @Test("commands: bare names from PATH, relative paths from here, absolute as is")
    func cageCommands() throws {
        let here = Self.surroundings(in: Self.app + "/scripts")
        let npm = try Self.launch(BoxPlan.start(linux: false, mac: false, profile: nil, captured: ["--", "npm", "test"], surroundings: here))
        #expect(npm.executable == "/opt/homebrew/bin/npm")
        #expect(npm.arguments == ["test"])
        #expect(npm.hook == nil)
        let relative = try Self.launch(BoxPlan.start(linux: false, mac: false, profile: nil, captured: ["--", "./migrate.sh"], surroundings: here))
        #expect(relative.executable == Self.app + "/scripts/migrate.sh")
        let absolute = try Self.launch(BoxPlan.start(linux: false, mac: false, profile: nil, captured: ["--", "/bin/zsh", "-l"], surroundings: here))
        #expect(absolute.executable == "/bin/zsh")
        #expect(absolute.arguments == ["-l"])
    }

    @Test("an agent rv knows no hook for runs untagged")
    func untaggedAgent() throws {
        let launch = try Self.launch(BoxPlan.start(
            linux: false, mac: false, profile: nil, captured: ["aider"],
            surroundings: Self.surroundings(path: ["aider": "/usr/local/bin/aider"])))
        #expect(launch.hook == nil)
        #expect(launch.executable == "/usr/local/bin/aider")
    }

    @Test("a missing agent is one line and one fix")
    func agentMissing() throws {
        let refusal = try Self.refusal(BoxPlan.start(
            linux: false, mac: false, profile: nil, captured: ["codex"], surroundings: Self.surroundings()))
        #expect(refusal.text == "✕ No codex on your PATH.\n  → rv box -- /full/path/to/codex\n")
        #expect(refusal.exitCode == 1)
    }

    @Test("VMs look names up on the guest's PATH")
    func vmLaunches() throws {
        let linux = try Self.launch(BoxPlan.start(
            linux: true, mac: false, profile: nil, captured: ["--", "npm", "test"], surroundings: Self.surroundings()))
        #expect(linux.wall == .linux)
        #expect(linux.executable == "/usr/bin/env")
        #expect(linux.arguments == ["npm", "test"])
        let mac = try Self.launch(BoxPlan.start(
            linux: false, mac: true, profile: nil, captured: ["claude", "run the UI test"], surroundings: Self.surroundings()))
        #expect(mac.wall == .mac)
        #expect(mac.executable == "/usr/bin/env")
        #expect(mac.arguments == ["claude", "run the UI test"])
        #expect(mac.hook == .claude)
        let script = try Self.launch(BoxPlan.start(
            linux: true, mac: false, profile: nil, captured: ["--", "./migrate.sh"], surroundings: Self.surroundings()))
        #expect(script.executable == Self.app + "/migrate.sh")
        #expect(script.arguments.isEmpty)
    }

    @Test("rv box alone is the shell, in the cage only")
    func shell() throws {
        #expect(BoxPlan.start(linux: false, mac: false, profile: nil, captured: [], surroundings: Self.surroundings(in: Self.app + "/src"))
            == .success(.shell(project: Self.app)))
        let refusal = try Self.refusal(BoxPlan.start(
            linux: true, mac: false, profile: nil, captured: [], surroundings: Self.surroundings()))
        #expect(refusal.text == "✕ The box shell runs in the cage; --linux and --mac need something to run.\n  → rv box --linux -- sh\n")
    }

    // MARK: Words

    @Test("the start lines match v4 Contained")
    func startLines() {
        let main = Self.profile("main", agents: ["claude"], secrets: ["ANTHROPIC_API_KEY"])
        let launch = BoxLaunch(
            wall: .cage, project: Self.app, executable: "/opt/homebrew/bin/claude", arguments: [],
            hook: .claude, profile: main)
        #expect(BoxPlan.startLines(launch, home: Self.home, workingDirectory: Self.app) == """
            ◆ rv · box for ~/code/app
              ✓ sealed    writes stay in the box until you bring them home
              ✓ keys      ANTHROPIC_API_KEY via rv · profile main
              ✓ network   public HTTPS through rv · LAN closed

            """)
        #expect(BoxPlan.readyLine(seconds: 0.43) == "  ready in 0.4 s\n")
        #expect(BoxPlan.exitLine(project: Self.app, workingDirectory: Self.app, home: Self.home)
            == "  → bring the writes home: rv workspace close\n")
        #expect(BoxPlan.exitLine(project: Self.app, workingDirectory: Self.app + "/src", home: Self.home)
            == "  → bring the writes home: rv workspace close --workspace ~/code/app\n")
    }

    @Test("no profile says so, with rv init last")
    func startLinesWithoutKeys() {
        var launch = BoxLaunch(
            wall: .linux, project: Self.app, executable: "/usr/bin/env", arguments: ["npm", "test"],
            hook: nil, profile: nil)
        #expect(BoxPlan.startLines(launch, home: Self.home, workingDirectory: Self.app + "/src") == """
            ◆ rv · linux box for ~/code/app · alpine 3.20
              ✓ sealed    writes stay in the box until you bring them home
              ◐ keys      none staged · to stage them: rv init --project /Users/chris/code/app
              ✓ network   public HTTPS through rv · no network card

            """)
        launch.wall = .mac
        launch.profile = Self.profile("main")
        #expect(BoxPlan.startLines(launch, home: Self.home, workingDirectory: Self.app) == """
            ◆ rv · mac box for ~/code/app · image dev
              ✓ sealed    writes stay in the box until you bring them home
              ✓ keys      from profile main
              ✓ network   public HTTPS through rv · no network card

            """)
    }

    @Test("VM start failures are one line and one fix")
    func vmRefusals() {
        let mac = MicroVMLaunchOptions(image: "dev", guest: .macOS)!
        #expect(BoxPlan.refusal(.notPrepared(mac)).text
            == "◐ Mac boxes need a one-time setup: about 26 GB to download.\n  → rv-macvm prepare --image dev\n")
        #expect(BoxPlan.refusal(.helperMissing(.linux)).text
            == "✕ Linux boxes need rv-microvm next to rv.\n  → reinstall rv, or build it: Scripts/build-microvm.sh\n")
        #expect(BoxPlan.refusal(.prepareFailed(image: "alpine:3.20", status: 3)).text
            == "✕ The Linux image alpine:3.20 could not be fetched (rv-microvm exit 3).\n  → rv doctor\n")
        // rv workspace run keeps its own words.
        #expect(WorkspaceMicroVM.Unready.notPrepared(mac).message
            == "macOS image dev is not prepared; build it once with: rv-macvm prepare --image dev")
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
        #expect(text.contains(#""schema":"rv.boxes.v1""#))
        #expect(text.contains(#""state":"open""#))
        #expect(text.contains(#""last_active":"1970-01-01T00:00:00Z""#))
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
        // Captured; `BoxCommand` answers it with this page itself.
        #expect(HelpDispatch.topic(arguments: ["box", "list", "--help"]) == nil)
        #expect(HelpDispatch.topic(arguments: ["box", "--linux", "--help"]) == .box)
        #expect(HelpDispatch.topic(arguments: ["box", "claude", "--help"]) == nil)
        let page = HelpDispatch.text(.box, palette: colorOffPalette)
        #expect(page.contains("rv box [--linux | --mac] [--profile <id>] [<agent> [args...]]"))
        #expect(page.contains("rv box list [--json]"))
        let root = HelpCatalog.page(.root).sections.flatMap(\.rows).map(\.name)
        #expect(root.contains("box"))
    }
}
