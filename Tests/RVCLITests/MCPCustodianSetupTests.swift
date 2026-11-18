import Foundation
import Testing

@testable import RVCLI

/// What `rv mcp custodian install` and `uninstall` would do to a host,
/// as plans: no host is touched here. The real thing is run by
/// Scripts/linux-custodian-e2e.sh.
@Suite("MCP custodian setup")
struct MCPCustodianSetupTests {
    private func host(
        isRoot: Bool = true, hasSystemd: Bool = true, source: String? = "/opt/rv/rv-mcp-custodian",
        pam: (auth: String, account: String)? = ("common-auth", "common-account"), accountExists: Bool = false,
        foreign: Set<String> = [], libraries: [String] = [], untrusted: [String] = [], unreadable: String? = nil
    ) -> MCPCustodianSetup.Host {
        MCPCustodianSetup.Host(
            isRoot: isRoot, hasSystemd: hasSystemd, source: source, libraries: libraries, untrusted: untrusted,
            unreadable: unreadable, pam: pam, accountExists: accountExists,
            nologin: "/usr/sbin/nologin", isForeign: { foreign.contains($0) })
    }

    @Test func installMakesTheAccountThenTheFilesThenStartsTheUnits() throws {
        let steps = try MCPCustodianSetup.installPlan(host()).get()
        #expect(steps.first == .run([
            "useradd", "--system", "--user-group", "--no-create-home", "--home-dir", "/nonexistent", "--shell",
            "/usr/sbin/nologin", "rv-mcp-custodian",
        ]))
        #expect(steps.contains(.installFile(from: "/opt/rv/rv-mcp-custodian", to: "/usr/local/libexec/rv/rv-mcp-custodian", mode: 0o755)))
        #expect(steps.suffix(3) == [
            .run(["systemctl", "daemon-reload"]),
            .run(["systemctl", "enable", "rv-mcp-custodian.service", "rv-mcp-presence.service"]),
            .run(["systemctl", "restart", "rv-mcp-custodian.service", "rv-mcp-presence.service"]),
        ])
        // A second install: the account is there, the rest is written again.
        let again = try MCPCustodianSetup.installPlan(host(accountExists: true)).get()
        #expect(again == Array(steps.dropFirst()))
        // A release ships the Swift runtime beside its binaries; the
        // custodian's copy loads it from its own directory.
        let shipped = try MCPCustodianSetup.installPlan(
            host(accountExists: true, libraries: ["/opt/rv/libswiftCore.so", "/opt/rv/libFoundation.so"])
        ).get()
        // The keys' directory is made before any unit starts, so that the
        // presence helper's unit can be kept out of it from its first start.
        let directory = MCPCustodianSetup.Step.run([
            "install", "-d", "-o", "rv-mcp-custodian", "-g", "rv-mcp-custodian", "-m", "0700", "/var/lib/rv-mcp-custodian",
        ])
        #expect(steps.dropFirst().first == directory && shipped.first == directory)
        #expect(shipped.dropFirst().prefix(2) == [
            .installFile(from: "/opt/rv/libFoundation.so", to: "/usr/local/libexec/rv/libFoundation.so", mode: 0o755),
            .installFile(from: "/opt/rv/libswiftCore.so", to: "/usr/local/libexec/rv/libswiftCore.so", mode: 0o755),
        ])
    }

    @Test func installRefusesAHostItCannotInstallOnAndChangesNothing() {
        let cases: [(MCPCustodianSetup.Host, String)] = [
            (host(isRoot: false), "run it as root"), (host(hasSystemd: false), "does not run systemd"),
            (host(source: nil), "reinstall rv"), (host(pam: nil), "no PAM stack"),
            // What root would install can be changed by the owner's account.
            (host(untrusted: ["/home/me/.local/bin", "/home/me/.local/bin/rv-mcp-custodian"]),
                "/home/me/.local/bin can be changed by an account other than root"),
            // rv itself, run as root, would load a library from there.
            (host(untrusted: ["/home/me/swift/usr/lib/swift/linux"]), "rv run as root"),
            (host(unreadable: "/opt/rv/rv"), "/opt/rv/rv is not a program rv can make safe for root to run"),
            (host(foreign: [MCPCustodianSetup.pamFile]), "was not written by rv"),
            (host(foreign: [MCPCustodianSetup.keyUnit]), "was not written by rv"),
        ]
        for (host, text) in cases {
            guard case .failure(let refusal) = MCPCustodianSetup.installPlan(host) else {
                Issue.record("\(text): a plan was made")
                continue
            }
            #expect(refusal.message.contains(text), "\(refusal.message)")
        }
    }

    @Test func uninstallRemovesWhatInstallMadeAndKeepsTheKeysUnlessPurged() throws {
        let steps = try MCPCustodianSetup.uninstallPlan(host(accountExists: true), purge: false).get()
        #expect(steps == [
            .attempt(["systemctl", "disable", "--now", "rv-mcp-custodian.service", "rv-mcp-presence.service"]),
            .removeFile(MCPCustodianSetup.keyUnit), .removeFile(MCPCustodianSetup.presenceUnit),
            .run(["systemctl", "daemon-reload"]),
            .removeFile(MCPCustodianSetup.pamFile), .removeTree("/usr/local/libexec/rv"),
        ])
        let purged = try MCPCustodianSetup.uninstallPlan(host(accountExists: true), purge: true).get()
        #expect(purged == steps + [.removeTree("/var/lib/rv-mcp-custodian"), .run(["userdel", "rv-mcp-custodian"])])
        // Everything install writes, uninstall removes.
        let installed = try MCPCustodianSetup.installPlan(host()).get()
        for case .writeFile(let path, _, _) in installed { #expect(steps.contains(.removeFile(path))) }
        for case .installFile(_, let path, _) in installed { #expect(path.hasPrefix("/usr/local/libexec/rv/")) }
        guard case .failure(let refusal) = MCPCustodianSetup.uninstallPlan(host(isRoot: false), purge: true) else {
            Issue.record("uninstall planned without root")
            return
        }
        #expect(refusal.message.contains("run it as root"))
        guard case .failure = MCPCustodianSetup.uninstallPlan(host(foreign: [MCPCustodianSetup.presenceUnit]), purge: false)
        else {
            Issue.record("uninstall would remove a file rv did not write")
            return
        }
    }

    /// The units' confinement, as written: the key daemon is not root, has
    /// no capability and no network; neither can gain privileges.
    @Test func theUnitsConfineTheDaemons() {
        let key = MCPCustodianSetup.keyUnitText
        for line in [
            "User=rv-mcp-custodian", "ExecStart=/usr/local/libexec/rv/rv-mcp-custodian serve", "NoNewPrivileges=yes",
            "CapabilityBoundingSet=\n", "PrivateNetwork=yes", "ProtectSystem=strict", "ProtectHome=yes",
            "StateDirectoryMode=0700", "RestrictAddressFamilies=AF_UNIX\n", "MemoryDenyWriteExecute=yes",
            "SystemCallFilter=@system-service",
        ] {
            #expect(key.contains(line), "\(line)")
        }
        let presence = MCPCustodianSetup.presenceUnitText
        for line in [
            "ExecStart=/usr/local/libexec/rv/rv-mcp-custodian presence", "NoNewPrivileges=yes", "ProtectSystem=full",
            "ProtectHome=yes", "InaccessiblePaths=-/var/lib/rv-mcp-custodian", "RestrictSUIDSGID=yes",
            "CapabilityBoundingSet=CAP_DAC_READ_SEARCH", "SystemCallFilter=@system-service @setuid",
        ] {
            #expect(presence.contains(line), "\(line)")
        }
        #expect(presence.contains("User=") == false)
        #expect(presence.contains("CAP_SYS_ADMIN") == false && presence.contains("CAP_SYS_PTRACE") == false)
        for text in [key, presence, MCPCustodianSetup.pamText(include: ("system-auth", "system-auth"))] {
            #expect(text.hasPrefix(MCPCustodianSetup.marker))
        }
    }

    // MARK: - What root runs

    #if os(Linux)
    /// The custodian this build made, beside the other products.
    private var builtCustodian: String {
        URL(fileURLWithPath: "/proc/self/exe").resolvingSymlinksInPath().deletingLastPathComponent()
            .appendingPathComponent("rv-mcp-custodian").path
    }

    /// A build's binary searches its toolchain's directory first, which
    /// may be under someone's home; root's copy searches only its own.
    @Test func rootsCopySearchesOnlyItsOwnDirectoryForLibraries() throws {
        let data = try #require(FileManager.default.contents(atPath: builtCustodian), "build the products first")
        let built = try #require(ELFDynamic(data))
        #expect(built.needed.contains("libswiftCore.so") && built.needed.contains("libc.so.6"))
        #expect(built.searchPath.contains("$ORIGIN") && built.searchPath.count > 1)
        let confined = try #require(ELFDynamic.confined(data))
        #expect(confined.count == data.count)
        let installed = try #require(ELFDynamic(confined))
        #expect(installed.searchPath == ["$ORIGIN"])
        #expect(installed.needed == built.needed)
        // Confining again changes nothing.
        #expect(ELFDynamic.confined(confined) == confined)
    }

    @Test func theLibrariesItLoadsFromItsSearchPathAreFoundWithTheirOwn() throws {
        let files = FileManager.default
        func isFile(_ path: String) -> Bool {
            var isDirectory: ObjCBool = false
            return files.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue == false
        }
        let loaded = try #require(
            LoadedCode(program: builtCustodian, read: { files.contents(atPath: $0) }, isFile: isFile))
        let names = Set(loaded.libraries.map { ($0 as NSString).lastPathComponent })
        // Asked for by the binary, and by a library it asks for.
        #expect(names.contains("libswiftCore.so") && names.contains("libFoundation.so"))
        #expect(names.contains("lib_FoundationICU.so"))
        // The system's own are left to the system.
        #expect(names.contains("libc.so.6") == false && names.contains("libm.so.6") == false)
        #expect(loaded.libraries.allSatisfy { $0.hasPrefix("/") })
        // Where its loader looks: the build's own directory among them.
        #expect(loaded.searched.contains((builtCustodian as NSString).deletingLastPathComponent)
            || loaded.searched.contains(URL(fileURLWithPath: builtCustodian).resolvingSymlinksInPath()
                .deletingLastPathComponent().path))
        #expect(LoadedCode(program: "/etc/hostname", read: { files.contents(atPath: $0) }, isFile: isFile) == nil)
        // The real binary names the system's loader.
        let built = try #require(files.contents(atPath: builtCustodian).flatMap(ELFDynamic.init))
        #expect(built.interpreter?.hasPrefix("/lib") == true && loaded.interpreter == built.interpreter)
        // The live reader agrees with the system about the system's own,
        // where the system looks the usual way (in some build sandboxes
        // `/` is nobody's and `/tmp` is private).
        var slash = stat()
        var temporary = stat()
        if stat("/", &slash) == 0, slash.st_uid == 0, stat("/tmp", &temporary) == 0, temporary.st_mode & 0o1002 == 0o1002 {
            #expect(RootTrust.changeable("/usr/bin/env", as: .file, inspect: RootTrust.live).isEmpty)
            #expect(RootTrust.changeable("/usr/lib", as: .searched, inspect: RootTrust.live).isEmpty)
            #expect(RootTrust.changeable("/tmp", as: .searched, inspect: RootTrust.live) == ["/tmp"])
        }
        #expect(RootTrust.live("/no/such/path") == nil)
    }
    #endif

    // MARK: - Who can change what root would use

    private static let root = RootTrust.Entry(owner: 0, mode: 0o040755)
    private static let program = RootTrust.Entry(owner: 0, mode: 0o100755)

    /// A file system as a table: what is not in it is not there.
    private func changeable(
        _ path: String, as kind: RootTrust.Kind = .file, in entries: [String: RootTrust.Entry]
    ) -> [String] {
        RootTrust.changeable(path, as: kind) { entries[$0] }
    }

    @Test func aPathOnlyRootCanChangeIsTrusted() {
        let entries: [String: RootTrust.Entry] = [
            "/": Self.root, "/opt": Self.root, "/opt/rv": Self.root, "/opt/rv/rv": Self.program,
            "/tmp": .init(owner: 0, mode: 0o041777), "/tmp/staged": Self.root, "/tmp/staged/rv": Self.program,
        ]
        #expect(changeable("/opt/rv/rv", in: entries) == [])
        #expect(changeable("/opt/rv", as: .searched, in: entries) == [])
        // Root's own directory under a sticky one: nobody else can replace it.
        #expect(changeable("/tmp/staged/rv", in: entries) == [])
        #expect(changeable("/tmp/staged", as: .searched, in: entries) == [])
        // A directory that is not there, where only root could make it.
        #expect(changeable("/opt/rv/missing/lib", as: .searched, in: entries) == [])
        #expect(changeable("/home/runner/.local/share/swift", as: .searched, in: entries.merging(["/home": Self.root]) { $1 }) == [])
    }

    @Test func whatAnotherAccountCanChangeIsNamed() {
        let home = RootTrust.Entry(owner: 1000, mode: 0o040750)
        let entries: [String: RootTrust.Entry] = [
            "/": Self.root, "/home": Self.root, "/home/me": home, "/home/me/bin": home,
            "/home/me/bin/rv": .init(owner: 1000, mode: 0o100755),
            "/srv": Self.root, "/srv/shared": .init(owner: 0, mode: 0o040775), "/srv/shared/rv": Self.program,
            "/srv/rv": .init(owner: 0, mode: 0o100775),
            "/tmp": .init(owner: 0, mode: 0o041777), "/tmp/rv": Self.program,
        ]
        #expect(changeable("/home/me/bin/rv", in: entries) == ["/home/me", "/home/me/bin", "/home/me/bin/rv"])
        #expect(changeable("/srv/shared/rv", in: entries) == ["/srv/shared"])
        #expect(changeable("/srv/rv", in: entries) == ["/srv/rv"])
        #expect(changeable("/srv/missing", in: entries) == ["/srv/missing"])
        // Sticky lets nobody replace root's file, and anybody add one beside
        // it: no place for a program, a searched directory, or a missing one.
        #expect(changeable("/tmp/rv", in: entries) == ["/tmp"])
        #expect(changeable("/tmp", as: .searched, in: entries) == ["/tmp"])
        #expect(changeable("/tmp/later/lib", as: .searched, in: entries) == ["/tmp"])
        #expect(changeable("/home/me/swift/lib", as: .searched, in: entries) == ["/home/me"])
        // A file where a directory should be, and a path from nowhere.
        #expect(changeable("/srv/rv", as: .searched, in: entries) == ["/srv/rv"])
        #expect(changeable("/srv/rv/lib", as: .searched, in: entries) == ["/srv/rv"])
        #expect(changeable("lib", as: .searched, in: entries) == ["lib"])
    }

    @Test func aLinkIsFollowedAndTrustedOnlyWhereItAndItsTargetAre() {
        func link(_ target: String, owner: UInt32 = 0) -> RootTrust.Entry {
            .init(owner: owner, mode: 0o120777, link: target)
        }
        let home = RootTrust.Entry(owner: 1000, mode: 0o040755)
        let entries: [String: RootTrust.Entry] = [
            "/": Self.root, "/usr": Self.root, "/usr/lib": Self.root, "/usr/lib/libz.so.1.3": Self.program,
            // A merged /usr and a versioned name: both links are root's.
            "/lib": link("usr/lib"), "/usr/lib/libz.so.1": link("libz.so.1.3"),
            "/opt": Self.root, "/opt/up": link("../usr/lib"), "/opt/away": link("/home/me/lib"),
            "/opt/mine": link("/usr/lib", owner: 1000), "/opt/loop": link("/opt/loop"),
            "/home": Self.root, "/home/me": home, "/home/me/lib": home, "/home/me/link": link("/usr/lib"),
        ]
        #expect(changeable("/lib/libz.so.1", in: entries) == [])
        #expect(changeable("/lib", as: .searched, in: entries) == [])
        #expect(changeable("/opt/up/libz.so.1.3", in: entries) == [])
        // Where it leads is someone else's.
        #expect(changeable("/opt/away", as: .searched, in: entries) == ["/home/me", "/home/me/lib"])
        // The link is someone else's, or sits where someone else can replace it.
        #expect(changeable("/opt/mine", as: .searched, in: entries) == ["/opt/mine"])
        #expect(changeable("/home/me/link/libz.so.1.3", in: entries) == ["/home/me"])
        #expect(changeable("/opt/loop/x", in: entries) == ["/opt/loop"])
    }

    // MARK: - What a program has its loader bring in

    /// A minimal 64-bit ELF file: one loaded segment holding a dynamic
    /// section with these entries, then the strings they name.
    private func elf(
        needed: [String] = [], runpath: String? = nil, soname: String? = nil, other: [(tag: UInt64, name: String)] = [],
        mergedTail: Bool = false, interpreter: String? = nil
    ) -> Data {
        var strings: [UInt8] = [0]
        var entries: [(UInt64, UInt64)] = []
        func add(_ tag: UInt64, _ text: String) {
            entries.append((tag, UInt64(strings.count)))
            strings += Array(text.utf8) + [0]
        }
        if let runpath { add(29, runpath) }
        if mergedTail, let runpath, let last = needed.last, runpath.hasSuffix(last) {
            // As a linker that stores one string as the tail of another would.
            for name in needed.dropLast() { add(1, name) }
            entries.append((1, UInt64(1 + runpath.utf8.count - last.utf8.count)))
        } else {
            for name in needed { add(1, name) }
        }
        if let soname { add(14, soname) }
        for (tag, name) in other { add(tag, name) }
        let dynamicOffset = 64 + 3 * 56
        let stringsOffset = dynamicOffset + (entries.count + 2) * 16
        entries.append((5, UInt64(stringsOffset)))
        entries.append((0, 0))
        var bytes = [UInt8](repeating: 0, count: stringsOffset) + strings
        let interpreterOffset = bytes.count
        if let interpreter { bytes += Array(interpreter.utf8) + [0] }
        func put<T: FixedWidthInteger>(_ value: T, at offset: Int) {
            for index in 0..<MemoryLayout<T>.size { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
        }
        bytes.replaceSubrange(0..<6, with: [0x7F, 0x45, 0x4C, 0x46, 2, 1])
        put(UInt64(64), at: 0x20)
        put(UInt16(56), at: 0x36)
        put(UInt16(interpreter == nil ? 2 : 3), at: 0x38)
        if let interpreter {
            // PT_INTERP.
            put(UInt32(3), at: 176)
            put(UInt64(interpreterOffset), at: 176 + 8)
            put(UInt64(interpreter.utf8.count + 1), at: 176 + 32)
        }
        // PT_LOAD: the whole file at address 0.
        put(UInt32(1), at: 64)
        put(UInt64(bytes.count), at: 64 + 32)
        // PT_DYNAMIC.
        put(UInt32(2), at: 120)
        put(UInt64(dynamicOffset), at: 120 + 8)
        put(UInt64((entries.count) * 16), at: 120 + 32)
        for (index, entry) in entries.enumerated() {
            put(entry.0, at: dynamicOffset + index * 16)
            put(entry.1, at: dynamicOffset + index * 16 + 8)
        }
        return Data(bytes)
    }

    @Test func aSearchPathIsReadWholeAndConfinedToTheFilesOwnDirectory() throws {
        let file = elf(needed: ["libswiftCore.so", "libc.so.6"], runpath: "/home/dev/swift/lib:$ORIGIN", soname: "libx.so")
        let read = try #require(ELFDynamic(file))
        #expect(read.needed == ["libswiftCore.so", "libc.so.6"])
        #expect(read.searchPath == ["/home/dev/swift/lib", "$ORIGIN"])
        let confined = try #require(ELFDynamic.confined(file).flatMap(ELFDynamic.init))
        #expect(confined.searchPath == ["$ORIGIN"] && confined.needed == read.needed)
        // An empty entry is the current directory to a loader: kept, so that it is refused.
        #expect(ELFDynamic(elf(runpath: "/opt/lib::/usr/lib"))?.searchPath == ["/opt/lib", "", "/usr/lib"])
        #expect(ELFDynamic(elf(runpath: ""))?.searchPath == [])
    }

    @Test func aFileThatBringsInCodeAnotherWayIsNotRead() {
        // DT_AUDIT, DT_DEPAUDIT, DT_FILTER, DT_AUXILIARY.
        for tag: UInt64 in [0x6FFF_FEFC, 0x6FFF_FEFB, 0x7FFF_FFFF, 0x7FFF_FFFD] {
            #expect(ELFDynamic(elf(needed: ["libc.so.6"], other: [(tag, "/home/dev/audit.so")])) == nil)
        }
        // A library name stored as the tail of the search path: rewriting
        // the path would rename the library.
        let merged = elf(needed: ["libc.so.6", "libfoo.so"], runpath: "/opt/libfoo.so", mergedTail: true)
        #expect(ELFDynamic(merged)?.needed == ["libc.so.6", "libfoo.so"])
        #expect(ELFDynamic.confined(merged) == nil)
    }

    @Test func aHeaderThatPointsPastTheEndOfEverythingIsRefusedNotACrash() {
        func corrupted(_ value: UInt64, at offset: Int) -> Data {
            var bytes = [UInt8](elf(needed: ["libc.so.6"], runpath: "$ORIGIN"))
            for index in 0..<8 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
            return Data(bytes)
        }
        // The program header table, a segment's file offset, the dynamic
        // section, each at the far end of what an offset can say.
        for value: UInt64 in [UInt64(Int.max) - 3, UInt64(Int.max), .max, .max - 7] {
            for offset in [0x20, 64 + 8, 64 + 16, 120 + 8, 120 + 32] {
                let data = corrupted(value, at: offset)
                #expect(ELFDynamic(data) == nil)
                #expect(ELFDynamic.confined(data) == nil)
            }
        }
    }

    @Test func whatAProgramLoadsIsFoundInItsLoadersOrder() throws {
        let files: [String: Data] = [
            "/opt/rv/rv": elf(needed: ["libA.so", "libc.so.6"], runpath: "/home/dev/swift/lib:${ORIGIN}"),
            // In both places: the loader takes the first on the path.
            "/home/dev/swift/lib/libA.so": elf(needed: ["libB.so"], runpath: "$ORIGIN/deps"),
            "/opt/rv/libA.so": elf(),
            "/home/dev/swift/lib/deps/libB.so": elf(),
        ]
        let loaded = try #require(LoadedCode(program: "/opt/rv/rv", read: { files[$0] }, isFile: { files[$0] != nil }))
        #expect(loaded.libraries == ["/home/dev/swift/lib/libA.so", "/home/dev/swift/lib/deps/libB.so"])
        #expect(loaded.searched == ["/home/dev/swift/lib", "/opt/rv", "/home/dev/swift/lib/deps"])
        // What a loader would do with these cannot be told from the file.
        for path in ["lib", "$LIB/rv", "/opt/$PLATFORM", "/opt/lib::/usr/lib", "$ORIGINX", "${ORIGIN}lib", "/opt/$ORIGIN"] {
            let odd = ["/opt/rv/rv": elf(needed: ["libc.so.6"], runpath: path)]
            #expect(LoadedCode(program: "/opt/rv/rv", read: { odd[$0] }, isFile: { odd[$0] != nil }) == nil, "\(path)")
        }
        let byPath = ["/opt/rv/rv": elf(needed: ["/home/dev/libA.so"])]
        #expect(LoadedCode(program: "/opt/rv/rv", read: { byPath[$0] }, isFile: { byPath[$0] != nil }) == nil)
        let damaged = ["/opt/rv/rv": elf(needed: ["libA.so"], runpath: "$ORIGIN"), "/opt/rv/libA.so": Data("no".utf8)]
        #expect(LoadedCode(program: "/opt/rv/rv", read: { damaged[$0] }, isFile: { damaged[$0] != nil }) == nil)
    }

    /// The finding this closes: a copy of rv that only root can write still
    /// searched its toolchain's directory first, and the check passed it.
    @Test func rvRunAsRootIsCheckedForWhereItLoadsFrom() {
        let home = RootTrust.Entry(owner: 1000, mode: 0o040755)
        let files: [String: Data] = [
            "/opt/rv/rv": elf(needed: ["libswiftCore.so"], runpath: "/home/dev/swift/lib:$ORIGIN"),
            "/opt/rv/rv-mcp-custodian": elf(needed: ["libswiftCore.so"], runpath: "$ORIGIN"),
            "/opt/rv/libswiftCore.so": elf(),
        ]
        var entries: [String: RootTrust.Entry] = [
            "/": Self.root, "/opt": Self.root, "/opt/rv": Self.root, "/home": Self.root, "/home/dev": home,
            "/opt/rv/rv": Self.program, "/opt/rv/rv-mcp-custodian": Self.program, "/opt/rv/libswiftCore.so": Self.program,
        ]
        func trust(_ programs: [String]) -> (libraries: [String], untrusted: [String], unreadable: String?) {
            MCPCustodianSetup.sourceTrust(
                programs: programs, copied: "/opt/rv/rv-mcp-custodian", read: { files[$0] }, isFile: { files[$0] != nil },
                inspect: { entries[$0] })
        }
        // The custodian alone is clean, and its library is the one to copy.
        let custodian = trust(["/opt/rv/rv-mcp-custodian"])
        #expect(custodian.untrusted == [] && custodian.libraries == ["/opt/rv/libswiftCore.so"])
        // rv is not: its loader looks under the developer's home first.
        #expect(trust(["/opt/rv/rv", "/opt/rv/rv-mcp-custodian"]).untrusted == ["/home/dev"])
        // A release's leftover build path, which only root could create, is fine.
        entries["/home/dev"] = nil
        #expect(trust(["/opt/rv/rv", "/opt/rv/rv-mcp-custodian"]).untrusted == [])
        #expect(trust(["/opt/rv/missing"]).unreadable == "/opt/rv/missing")
    }

    /// The loader a program names for itself runs before any library.
    @Test func aProgramsOwnLoaderIsCheckedToo() throws {
        let files: [String: Data] = [
            "/opt/rv/rv": elf(needed: ["libc.so.6"], runpath: "$ORIGIN", interpreter: "/home/dev/nix/ld.so"),
            "/opt/rv/rv-cli": elf(needed: ["libc.so.6"], runpath: "$ORIGIN", interpreter: "/lib64/ld-linux-x86-64.so.2"),
        ]
        #expect(ELFDynamic(try #require(files["/opt/rv/rv"]))?.interpreter == "/home/dev/nix/ld.so")
        let entries: [String: RootTrust.Entry] = [
            "/": Self.root, "/opt": Self.root, "/opt/rv": Self.root, "/opt/rv/rv": Self.program,
            "/opt/rv/rv-cli": Self.program, "/lib64": Self.root, "/lib64/ld-linux-x86-64.so.2": Self.program,
            "/home": Self.root, "/home/dev": .init(owner: 1000, mode: 0o040755),
        ]
        func untrusted(_ program: String) -> [String] {
            MCPCustodianSetup.sourceTrust(
                programs: [program], copied: nil, read: { files[$0] }, isFile: { files[$0] != nil },
                inspect: { entries[$0] }
            ).untrusted
        }
        #expect(untrusted("/opt/rv/rv-cli") == [])
        // The directory that is someone else's, and the loader missing from it.
        #expect(untrusted("/opt/rv/rv").sorted() == ["/home/dev", "/home/dev/nix"])
    }

    /// What cannot be looked at (a mount root may not enter) is not
    /// "missing": only root could make a missing directory, anyone may be
    /// behind one that cannot be seen.
    @Test func aPathThatCannotBeLookedAtIsNotTrusted() {
        let unseen = RootTrust.Entry(owner: .max, mode: 0)
        let entries: [String: RootTrust.Entry] = ["/": Self.root, "/home": Self.root, "/home/dev": unseen]
        #expect(changeable("/home/dev", as: .searched, in: entries) == ["/home/dev"])
        #expect(changeable("/home/dev/lib", as: .searched, in: entries) == ["/home/dev"])
        #expect(changeable("/home/other/lib", as: .searched, in: entries) == [])
    }

    @Test func anELFFileThatIsNotOneIsNotRead() {
        #expect(ELFDynamic(Data()) == nil)
        #expect(ELFDynamic(Data("#!/bin/sh\n".utf8)) == nil)
        #expect(ELFDynamic.confined(Data(repeating: 0, count: 4096)) == nil)
        // A 32-bit or big-endian header.
        var header = [UInt8](repeating: 0, count: 64)
        header.replaceSubrange(0..<6, with: [0x7F, 0x45, 0x4C, 0x46, 1, 1])
        #expect(ELFDynamic(Data(header)) == nil)
        header[4] = 2
        header[5] = 2
        #expect(ELFDynamic(Data(header)) == nil)
        // 64-bit little-endian with no program headers: nothing asked for.
        header[5] = 1
        let empty = ELFDynamic(Data(header))
        #expect(empty?.needed == [] && empty?.searchPath == [])
    }

    #if os(Linux)
    /// Any damage to a real file is read as something or refused, never a crash.
    @Test func aDamagedELFFileNeverCrashesTheReader() throws {
        let data = try #require(FileManager.default.contents(atPath: builtCustodian))
        let head = [UInt8](data.prefix(8192))
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<400 {
            var bytes = head
            for _ in 0..<Int.random(in: 1...8, using: &generator) {
                bytes[Int.random(in: 0..<bytes.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
            }
            let cut = Int.random(in: 0...bytes.count, using: &generator)
            _ = ELFDynamic(Data(bytes.prefix(cut)))
            _ = ELFDynamic.confined(Data(bytes))
        }
    }
    #endif

    @Test func thePAMServiceIncludesTheDistributionsOwnStacks() {
        #expect(MCPCustodianSetup.pamInclude { $0.hasSuffix("common-auth") || $0.hasSuffix("common-account") }?.auth == "common-auth")
        #expect(MCPCustodianSetup.pamInclude { $0.hasSuffix("system-auth") }?.account == "system-auth")
        #expect(MCPCustodianSetup.pamInclude { $0.hasSuffix("common-auth") } == nil)
        #expect(MCPCustodianSetup.pamInclude { _ in false } == nil)
        let text = MCPCustodianSetup.pamText(include: ("common-auth", "common-account"))
        #expect(text.contains("auth     include  common-auth\n") && text.contains("account  include  common-account\n"))
    }
}
