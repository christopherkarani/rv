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
        foreign: Set<String> = [], libraries: [String] = [], untrusted: [String] = []
    ) -> MCPCustodianSetup.Host {
        MCPCustodianSetup.Host(
            isRoot: isRoot, hasSystemd: hasSystemd, source: source, libraries: libraries, untrusted: untrusted, pam: pam,
            accountExists: accountExists,
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
        #expect(shipped.prefix(2) == [
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
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/debug/rv-mcp-custodian").path
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
        let libraries = try #require(MCPCustodianSetup.loadedLibraries(of: builtCustodian))
        let names = Set(libraries.map { ($0 as NSString).lastPathComponent })
        // Asked for by the binary, and by a library it asks for.
        #expect(names.contains("libswiftCore.so") && names.contains("libFoundation.so"))
        #expect(names.contains("lib_FoundationICU.so"))
        // The system's own are left to the system.
        #expect(names.contains("libc.so.6") == false && names.contains("libm.so.6") == false)
        #expect(libraries.allSatisfy { $0.hasPrefix("/") })
        #expect(MCPCustodianSetup.loadedLibraries(of: "/etc/hostname") == nil)
    }

    @Test func aFileOthersCanChangeIsNamedWithTheDirectoryThatLetsThem() throws {
        // The system's own: nothing above it is anyone else's.
        #expect(MCPCustodianSetup.changeableByOthers("/usr/bin/env").isEmpty)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rv-setup-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("rv-mcp-custodian").path
        try Data("x".utf8).write(to: URL(fileURLWithPath: file))
        #expect(chmod(directory.path, 0o777) == 0)
        // A world-writable directory: its entries can be replaced.
        #expect(MCPCustodianSetup.changeableByOthers(file).contains(directory.path))
        #expect(MCPCustodianSetup.changeableByOthers(directory.path + "/missing").contains(directory.path + "/missing"))
        if getuid() != 0 {
            // Not root's file at all.
            #expect(MCPCustodianSetup.changeableByOthers(file).contains(file))
        }
    }
    #endif

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
