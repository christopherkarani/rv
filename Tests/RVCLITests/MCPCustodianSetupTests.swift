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
        foreign: Set<String> = [], libraries: [String] = []
    ) -> MCPCustodianSetup.Host {
        MCPCustodianSetup.Host(
            isRoot: isRoot, hasSystemd: hasSystemd, source: source, libraries: libraries, pam: pam,
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
            "ProtectHome=read-only", "RestrictSUIDSGID=yes", "CapabilityBoundingSet=CAP_DAC_READ_SEARCH",
        ] {
            #expect(presence.contains(line), "\(line)")
        }
        #expect(presence.contains("User=") == false)
        #expect(presence.contains("CAP_SYS_ADMIN") == false && presence.contains("CAP_SYS_PTRACE") == false)
        for text in [key, presence, MCPCustodianSetup.pamText(include: ("system-auth", "system-auth"))] {
            #expect(text.hasPrefix(MCPCustodianSetup.marker))
        }
    }

    @Test func thePAMServiceIncludesTheDistributionsOwnStacks() {
        #expect(MCPCustodianSetup.pamInclude { $0.hasSuffix("common-auth") || $0.hasSuffix("common-account") }?.auth == "common-auth")
        #expect(MCPCustodianSetup.pamInclude { $0.hasSuffix("system-auth") }?.account == "system-auth")
        #expect(MCPCustodianSetup.pamInclude { $0.hasSuffix("common-auth") } == nil)
        #expect(MCPCustodianSetup.pamInclude { _ in false } == nil)
        let text = MCPCustodianSetup.pamText(include: ("common-auth", "common-account"))
        #expect(text.contains("auth     include  common-auth\n") && text.contains("account  include  common-account\n"))
    }
}
