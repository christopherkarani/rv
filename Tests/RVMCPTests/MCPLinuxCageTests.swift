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
        #expect(abi(9) == .pathnameUnixSockets)
        #expect(abi(3) < .tcp && LandlockABI.tcp < .pathnameUnixSockets)
    }

    /// The socket filter closes the network on every kernel; what is left
    /// to the ABI is what only Landlock mediates.
    @Test(arguments: [
        (4, [MCPLinuxCageGap.deviceIoctl, .signals]), (5, [.signals]), (6, []), (9, []), (12, []), (99, []),
    ])
    func eachABIClosesItsGaps(version: Int, open: [MCPLinuxCageGap]) {
        #expect(MCPLinuxCageGap.open(at: abi(version)) == open)
    }

    @Test func everyGapSaysWhichABIClosesIt() {
        for gap in MCPLinuxCageGap.allCases {
            switch gap {
            case .deviceIoctl: #expect(gap.closedAt == .deviceIoctl)
            case .signals: #expect(gap.closedAt == .scopes)
            }
            #expect(gap.summary.isEmpty == false)
        }
    }

    // MARK: Support

    @Test func aHostCagesOnlyWithTheHelperTheTCPRulesAndTheSocketFilter() {
        #expect(MCPLinuxCageSupport.resolve(helperInstalled: false, report: "7") == .unavailable(.helperMissing))
        #expect(MCPLinuxCageSupport.resolve(helperInstalled: true, report: nil) == .unavailable(.probeFailed))
        #expect(MCPLinuxCageSupport.resolve(helperInstalled: true, report: "0") == .unavailable(.noLandlock))
        for version in 1...3 {
            #expect(MCPLinuxCageSupport.resolve(helperInstalled: true, report: String(version))
                == .unavailable(.tooOld(abi(version))))
        }
        for version in 4...12 {
            let support = MCPLinuxCageSupport.resolve(helperInstalled: true, report: String(version))
            #expect(support == .confines(abi(version)))
            #expect(support.abi == abi(version))
            // Landlock without seccomp filters is half a cage: none.
            #expect(MCPLinuxCageSupport.resolve(helperInstalled: true, report: "\(version) no-socket-filter")
                == .unavailable(.noSocketFilter))
        }
        // No Landlock is said before no socket filter: it is the first thing missing.
        #expect(MCPLinuxCageSupport.resolve(helperInstalled: true, report: "0 no-socket-filter") == .unavailable(.noLandlock))
        // Anything the helper does not print is a probe that failed, never an ABI.
        for report in ["", " ", "-3", "seven", "7 ", " 7", "7 x", "7 no-socket-filter x", "7\n8", "٧", "0x7", "+7"] {
            #expect(MCPLinuxCageSupport.resolve(helperInstalled: true, report: report) == .unavailable(.probeFailed), "\(report)")
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
        #expect(MCPLinuxCageSupport.Unavailable.noSocketFilter.reason.contains("seccomp"))
    }

    /// A host that can cage requires it of every local server. So does one
    /// that should be able to and cannot say so; one whose kernel has no
    /// cage runs servers bare, as before.
    @Test func aCageIsRequiredWhereThereIsOneOrShouldBe() {
        for version in 4...12 { #expect(MCPLinuxCage.isRequired(.confines(abi(version)))) }
        #expect(MCPLinuxCage.isRequired(.unavailable(.helperMissing)))
        #expect(MCPLinuxCage.isRequired(.unavailable(.probeFailed)))
        #expect(MCPLinuxCage.isRequired(.unavailable(.noLandlock)) == false)
        #expect(MCPLinuxCage.isRequired(.unavailable(.tooOld(abi(3)))) == false)
        #expect(MCPLinuxCage.isRequired(.unavailable(.noSocketFilter)) == false)
    }

    @Test func loaderVariablesAreTheOnesTheDynamicLoaderActsOn() {
        for name in ["LD_PRELOAD", "LD_LIBRARY_PATH", "LD_AUDIT", "LD_DEBUG", "GLIBC_TUNABLES"] {
            #expect(MCPLinuxCage.isLoaderVariable(name))
        }
        for name in ["PATH", "HOME", "LDFLAGS", "ld_preload", "NODE_OPTIONS", "GLIBC", ""] {
            #expect(MCPLinuxCage.isLoaderVariable(name) == false)
        }
        #expect(MCPLinuxCage.Refusal.loaderVariable("LD_PRELOAD").reason.contains("env LD_PRELOAD=... command"))
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

    /// A save writes `name.lock` or `.name.tmp` beside a file and renames
    /// it over: a grant follows the file, so a sibling that carries a
    /// protected name as a whole word is not granted.
    @Test func aSiblingNamedAfterAProtectedFileIsNotGranted() throws {
        let list = tree([
            "/": [("home", .directory)],
            "/home": [
                (".git-credentials", .file), (".git-credentials.lock", .file), (".git-credentials~", .file),
                ("#.git-credentials#", .file), (".netrc.tmp.123", .file), (".config", .directory), ("notes", .file),
                (".netrcAbCdEf", .file), ("my.netrc", .file), ("netrc", .file),
            ],
            "/home/.config": [("gh", .directory), ("gh.bak", .directory), ("ghostty", .directory), ("light", .directory)],
        ])
        let paths = try MCPLinuxCage.readable(
            protecting: ["/home/.git-credentials", "/home/.netrc", "/home/.config/gh"], list: list
        ).get()
        #expect(paths == ["/home/.config/ghostty", "/home/.config/light", "/home/netrc", "/home/notes"])
        #expect(MCPLinuxCage.names(".git-credentials.lock", ".git-credentials"))
        // A temporary name run together with the file's (`mkstemp`).
        #expect(MCPLinuxCage.names(".git-credentialsXXXXXX", ".git-credentials"))
        #expect(MCPLinuxCage.names("auth.json1234567", "auth.json") && MCPLinuxCage.names("credentials123", "credentials"))
        // A short plain name only as a whole word.
        #expect(MCPLinuxCage.names("ghostty", "gh") == false && MCPLinuxCage.names("gh", "gh") == false)
        #expect(MCPLinuxCage.names("x", "") == false && MCPLinuxCage.names("a.gh", "gh") && MCPLinuxCage.names("high", "gh") == false)
        #expect(MCPLinuxCage.names("gh-dash", "gh") && MCPLinuxCage.names("apple", "app") == false)
    }

    @Test func tooManyEntriesBesideAProtectedPathIsARefusal() {
        let many = (0...MCPLinuxCage.maximumReadablePaths).map { ("f\($0)", MCPLinuxCage.EntryKind.file) }
        let list = tree(["/": [("home", .directory)], "/home": many + [(".ssh", .directory)]])
        #expect(MCPLinuxCage.readable(protecting: ["/home/.ssh"], list: list) == .failure(.tooManyPaths))
    }

    @Test func moreBytesOfPathsThanARequestCarriesIsARefusal() {
        let long = String(repeating: "n", count: 200)
        let many = (0..<(MCPLinuxCage.maximumReadableBytes / 200)).map { ("\(long)\($0)", MCPLinuxCage.EntryKind.file) }
        #expect(many.count < MCPLinuxCage.maximumReadablePaths)
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
            readable: ["/usr", "/home/me/code"], writable: ["/home/me/.cache/rv-mcp/fs"], shared: ["/tmp", "/dev"],
            proxyPort: 40123)
        #expect(plan.arguments(executable: "/usr/bin/env", argv: ["/usr/bin/env", "npx", "--confine", "--"]) == [
            "--confine", "4", "--read", "/usr", "--read", "/home/me/code", "--write", "/home/me/.cache/rv-mcp/fs",
            "--temp", "/tmp", "--temp", "/dev", "--tcp", "40123", "--", "/usr/bin/env", "/usr/bin/env", "npx",
            "--confine", "--",
        ])
        let closed = MCPLinuxCage.Plan(readable: [], writable: [], shared: [], proxyPort: nil)
        #expect(closed.arguments(executable: "/bin/true", argv: ["true"]) == ["--confine", "4", "--", "/bin/true", "true"])
    }

    @Test func theNoticeNamesWhatAnOlderKernelLeavesOpen() throws {
        let old = try #require(MCPLinuxCage.notice(server: "fs", abi: .tcp))
        #expect(old.contains("fs") && old.contains("ABI 4") && old.contains("ioctl") && old.contains("signals"))
        let newer = try #require(MCPLinuxCage.notice(server: "fs", abi: abi(5)))
        #expect(newer.contains("signals") && newer.contains("ioctl") == false)
        // Nothing open, nothing to say.
        #expect(MCPLinuxCage.notice(server: "fs", abi: .scopes) == nil)
        #expect(MCPLinuxCage.notice(server: "fs", abi: abi(11)) == nil)
    }
}
