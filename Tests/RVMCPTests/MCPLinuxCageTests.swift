import Foundation
import Testing
@testable import RVMCP

/// The pure half of the Linux cage: what each Landlock ABI leaves open,
/// which hosts cage at all, which servers they admit, and the ruleset.
/// These run on every platform; `MCPLinuxSandboxTests` runs the result on
/// a real kernel.
@Suite("MCP Linux cage")
struct MCPLinuxCageTests {
    private func abi(_ value: Int) -> LandlockABI { LandlockABI(value)! }

    // MARK: ABI

    @Test func anABIStartsAtOne() {
        #expect(LandlockABI(0) == nil)
        #expect(LandlockABI(-1) == nil)
        #expect(LandlockABI(1)?.rawValue == 1)
        #expect(abi(4) == .tcp && abi(5) == .deviceIoctl && abi(6) == .scopes)
        #expect(abi(9) == .pathnameUnixSockets && abi(10) == .udp)
        #expect(abi(3) < .tcp && LandlockABI.tcp < .udp)
    }

    /// Every ABI the cage can run under, and exactly what it leaves open.
    @Test(arguments: [
        (4, [MCPLinuxCageGap.deviceIoctl, .abstractSocketsAndSignals, .pathnameUnixSockets, .udp, .otherSockets]),
        (5, [.abstractSocketsAndSignals, .pathnameUnixSockets, .udp, .otherSockets]),
        (6, [.pathnameUnixSockets, .udp, .otherSockets]),
        (7, [.pathnameUnixSockets, .udp, .otherSockets]),
        (8, [.pathnameUnixSockets, .udp, .otherSockets]),
        (9, [.udp, .otherSockets]),
        (10, [.otherSockets]),
        (11, [.otherSockets]),
        (12, [.otherSockets]),
        (99, [.otherSockets]),
    ])
    func eachABIClosesItsGapsAndNoneClosesTheLast(version: Int, open: [MCPLinuxCageGap]) {
        #expect(MCPLinuxCageGap.open(at: abi(version)) == open)
    }

    @Test func everyGapButOneHasTheABIThatClosesIt() {
        for gap in MCPLinuxCageGap.allCases {
            switch gap {
            case .deviceIoctl: #expect(gap.closedAt == .deviceIoctl)
            case .abstractSocketsAndSignals: #expect(gap.closedAt == .scopes)
            case .pathnameUnixSockets: #expect(gap.closedAt == .pathnameUnixSockets)
            case .udp: #expect(gap.closedAt == .udp)
            case .otherSockets: #expect(gap.closedAt == nil)
            }
            #expect(gap.summary.isEmpty == false)
        }
    }

    // MARK: Support and admission

    @Test func aHostCagesOnlyWithTheHelperAndTCPRules() {
        #expect(MCPLinuxCageSupport.resolve(helperInstalled: false, reportedABI: 7) == .unavailable(.helperMissing))
        #expect(MCPLinuxCageSupport.resolve(helperInstalled: true, reportedABI: nil) == .unavailable(.probeFailed))
        #expect(MCPLinuxCageSupport.resolve(helperInstalled: true, reportedABI: 0) == .unavailable(.noLandlock))
        #expect(MCPLinuxCageSupport.resolve(helperInstalled: true, reportedABI: -3) == .unavailable(.noLandlock))
        for version in 1...3 {
            #expect(MCPLinuxCageSupport.resolve(helperInstalled: true, reportedABI: version)
                == .unavailable(.tooOld(abi(version))))
        }
        for version in 4...12 {
            let support = MCPLinuxCageSupport.resolve(helperInstalled: true, reportedABI: version)
            #expect(support == .confines(abi(version)))
            #expect(support.abi == abi(version))
        }
        #expect(MCPLinuxCageSupport.unavailable(.noLandlock).abi == nil)
    }

    @Test func everyUnavailableHostSaysWhatIsMissingAndHowToFixIt() {
        #expect(MCPLinuxCageSupport.Unavailable.helperMissing.reason.contains("reinstall rv"))
        #expect(MCPLinuxCageSupport.Unavailable.probeFailed.reason.contains("reinstall rv"))
        #expect(MCPLinuxCageSupport.Unavailable.noLandlock.reason.contains("Linux 6.7"))
        #expect(MCPLinuxCageSupport.Unavailable.noLandlock.reason.contains("lsm=landlock"))
        let old = MCPLinuxCageSupport.Unavailable.tooOld(abi(3)).reason
        #expect(old.contains("ABI 3") && old.contains("ABI 4") && old.contains("Linux 6.7"))
    }

    /// A server is admitted from the floor up and refused below it; a floor
    /// under the TCP rules is the TCP rules.
    @Test func admissionIsTheHostsABIAgainstTheNetworkFloor() {
        for version in 4...12 {
            let support = MCPLinuxCageSupport.confines(abi(version))
            #expect(MCPLinuxCage.admit(support, networkFloor: .tcp) == .success(abi(version)))
            #expect(MCPLinuxCage.admit(support, networkFloor: abi(1)) == .success(abi(version)))
            let strict = MCPLinuxCage.admit(support, networkFloor: .udp)
            if version >= 10 {
                #expect(strict == .success(abi(version)))
            } else {
                #expect(strict == .failure(.networkNotConfined(abi: abi(version), floor: .udp)))
            }
        }
        for unavailable in [
            MCPLinuxCageSupport.Unavailable.helperMissing, .probeFailed, .noLandlock, .tooOld(abi(3)),
        ] {
            #expect(MCPLinuxCage.admit(.unavailable(unavailable), networkFloor: .tcp) == .failure(.unavailable(unavailable)))
        }
        #expect(MCPLinuxCage.networkFloor == .tcp)
        let reason = MCPLinuxCage.Refusal.networkNotConfined(abi: abi(7), floor: .udp).reason
        #expect(reason.contains("ABI 7") && reason.contains("UDP") && reason.contains("ABI 10"))
    }

    // MARK: Readable paths

    /// A file system as a dictionary: directory to entries.
    private func tree(_ directories: [String: [(String, MCPLinuxCage.EntryKind)]]) -> (String) -> [MCPLinuxCage.Entry]? {
        { directory in directories[directory]?.map { MCPLinuxCage.Entry(name: $0.0, kind: $0.1) } }
    }

    @Test func everythingBesideTheProtectedPathsIsReadableAndNothingAboveOrInThem() throws {
        let list = tree([
            "/": [("usr", .directory), ("home", .directory), ("etc", .directory), ("vmlinuz", .symlink), ("swap", .file)],
            "/home": [("me", .directory), ("other", .directory)],
            "/home/me": [
                (".ssh", .directory), (".aws", .directory), (".config", .directory), ("code", .directory),
                (".netrc", .file), ("notes.txt", .file), ("link", .symlink), ("bus", .other),
            ],
            "/home/me/.config": [("rv", .directory), ("gh", .directory), ("nvim", .directory), ("mimeapps.list", .file)],
        ])
        let protected: Set<String> = [
            "/home/me/.ssh", "/home/me/.aws", "/home/me/.netrc", "/home/me/.config/rv", "/home/me/.config/gh",
            "/home/me/.gnupg",
        ]
        let paths = try MCPLinuxCage.readable(protecting: protected, list: list).get()
        #expect(paths == [
            "/etc", "/home/me/.config/mimeapps.list", "/home/me/.config/nvim", "/home/me/code", "/home/me/notes.txt",
            "/home/other", "/swap", "/usr",
        ])
    }

    @Test func aDirectoryHoldingAProtectedPathMustBeListable() {
        let list = tree(["/": [("home", .directory)], "/home": [("me", .directory)]])
        #expect(MCPLinuxCage.readable(protecting: ["/home/me/.ssh"], list: list) == .failure(.unlistable("/home/me")))
        #expect(MCPLinuxCage.readable(protecting: ["/"], list: list) == .failure(.unlistable("/")))
        #expect(MCPLinuxCage.readable(protecting: ["/x"], list: { _ in nil }) == .failure(.unlistable("/")))
    }

    @Test func aProtectedPathReachedOnlyThroughALinkIsNotWalked() throws {
        // /home/me is a link: nothing under it is granted from here; its
        // target is protected under its own, resolved, path.
        let list = tree(["/": [("home", .directory), ("data", .directory)], "/home": [("me", .symlink)],
            "/data": [("me", .directory)], "/data/me": [(".ssh", .directory), ("code", .directory)]])
        let paths = try MCPLinuxCage.readable(protecting: ["/home/me/.ssh", "/data/me/.ssh"], list: list).get()
        #expect(paths == ["/data/me/code"])
    }

    @Test func tooManyEntriesBesideAProtectedPathIsARefusal() {
        let many = (0...MCPLinuxCage.maximumReadablePaths).map { ("f\($0)", MCPLinuxCage.EntryKind.file) }
        let list = tree(["/": [("home", .directory)], "/home": many + [(".ssh", .directory)]])
        #expect(MCPLinuxCage.readable(protecting: ["/home/.ssh"], list: list) == .failure(.tooManyPaths))
    }

    /// Random trees: no granted path is a protected one, holds one, or is
    /// inside one, and every unprotected regular entry is reachable.
    @Test func noGrantEverCoversAProtectedPath() throws {
        var random = FuzzRandom(seed: 0x1A7D_10C4)
        for _ in 0..<300 {
            var directories: [String: [(String, MCPLinuxCage.EntryKind)]] = [:]
            var all: [(path: String, kind: MCPLinuxCage.EntryKind)] = []
            func grow(_ directory: String, depth: Int) {
                var entries: [(String, MCPLinuxCage.EntryKind)] = []
                for index in 0..<Int.random(in: 0...4, using: &random) {
                    let kind: MCPLinuxCage.EntryKind = [.directory, .directory, .file, .symlink, .other]
                        .randomElement(using: &random)!
                    let name = "n\(index)"
                    let path = directory == "/" ? "/" + name : directory + "/" + name
                    entries.append((name, kind))
                    all.append((path, kind))
                    if kind == .directory, depth < 4 { grow(path, depth: depth + 1) }
                }
                directories[directory] = entries
            }
            grow("/", depth: 0)
            let protected = Set(all.filter { _ in Int.random(in: 0..<5, using: &random) == 0 }.map(\.path))
            let paths = try MCPLinuxCage.readable(protecting: protected, list: tree(directories)).get()
            for path in paths {
                for guarded in protected {
                    #expect(path != guarded && guarded.hasPrefix(path + "/") == false && path.hasPrefix(guarded + "/") == false)
                }
            }
            for entry in all where entry.kind == .file || entry.kind == .directory {
                let guarded = protected.contains { entry.path == $0 || entry.path.hasPrefix($0 + "/") }
                let holds = protected.contains { $0.hasPrefix(entry.path + "/") }
                let viaLink = all.contains { $0.kind != .directory && entry.path.hasPrefix($0.path + "/") }
                let covered = paths.contains { entry.path == $0 || entry.path.hasPrefix($0 + "/") }
                if guarded || holds { #expect(paths.contains(entry.path) == false) }
                if guarded == false, holds == false, viaLink == false { #expect(covered, "\(entry.path) is not readable") }
            }
        }
    }

    // MARK: Writable paths

    @Test func aWritablePathMayNotUndoAProtectedOne() {
        let protected: Set<String> = ["/home/me/.ssh", "/home/me/.config/rv"]
        func conflict(_ path: String) -> MCPLinuxCage.Refusal? { MCPLinuxCage.writableConflict([path], protected: protected) }
        #expect(conflict("/") == .writableConflict(writable: "/", protected: "/"))
        #expect(conflict("/home/me") == .writableConflict(writable: "/home/me", protected: "/home/me/.config/rv"))
        #expect(conflict("/home/me/.config") == .writableConflict(writable: "/home/me/.config", protected: "/home/me/.config/rv"))
        #expect(conflict("/home/me/.ssh") == .writableConflict(writable: "/home/me/.ssh", protected: "/home/me/.ssh"))
        #expect(conflict("/home/me/.ssh/keys") == .writableConflict(writable: "/home/me/.ssh/keys", protected: "/home/me/.ssh"))
        #expect(conflict("/home/me/.sshx") == nil)
        #expect(conflict("/home/me/.cache") == nil)
        #expect(conflict("/tmp") == nil)
        #expect(MCPLinuxCage.writableConflict([], protected: protected) == nil)
        #expect(MCPLinuxCage.Refusal.writableConflict(writable: "/home/me", protected: "/home/me/.ssh").reason
            .contains("/home/me/.ssh"))
    }

    // MARK: The request

    @Test func thePlanIsTheHelpersArguments() {
        let plan = MCPLinuxCage.Plan(
            floor: .tcp, readable: ["/usr", "/home/me/code"], writable: ["/tmp", "/home/me/.cache/rv-mcp/fs"],
            tcpPorts: [40123])
        #expect(plan.arguments(executable: "/usr/bin/env", argv: ["/usr/bin/env", "npx", "--confine", "--"]) == [
            "--confine", "4", "--read", "/usr", "--read", "/home/me/code", "--write", "/tmp", "--write",
            "/home/me/.cache/rv-mcp/fs", "--tcp", "40123", "--", "/usr/bin/env", "/usr/bin/env", "npx", "--confine", "--",
        ])
        let closed = MCPLinuxCage.Plan(floor: .udp, readable: [], writable: [], tcpPorts: [])
        #expect(closed.arguments(executable: "/bin/true", argv: ["true"]) == ["--confine", "10", "--", "/bin/true", "true"])
    }

    @Test func theNoticeNamesWhatTheKernelLeavesOpen() throws {
        let old = try #require(MCPLinuxCage.notice(server: "fs", abi: .tcp))
        #expect(old.contains("fs") && old.contains("ABI 4") && old.contains("UDP") && old.contains("Unix sockets"))
        let new = try #require(MCPLinuxCage.notice(server: "fs", abi: abi(10)))
        #expect(new.hasSuffix("this kernel does not block " + MCPLinuxCageGap.otherSockets.summary))
    }
}
