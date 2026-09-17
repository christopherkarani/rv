import Foundation
import Testing
@testable import RVCLI

struct SystemctlApplyingTests {
    @Test func silentSystemctl_swallowsBothActions() throws {
        let silent = SilentSystemctl()
        try silent.enableNow(unit: SystemdUserTemplate.unitName)
        try silent.disableNow(unit: SystemdUserTemplate.unitName)
    }

    @Test func defaultProcessToolsPointAtHostBinaries() {
        #expect(ProcessSystemctl().executableURL.path.contains("systemctl"))
        #expect(ProcessLaunchctl().executableURL.path.contains("launchctl"))
    }

    @Test func processSystemctl_enableSucceedsWhenToolExitsZero() throws {
        let tool = try fakeProcessTool(exit: 0)
        defer { try? FileManager.default.removeItem(at: tool) }
        try ProcessSystemctl(executableURL: tool).enableNow(unit: SystemdUserTemplate.unitName)
    }

    @Test func processSystemctl_enableMapsNonZeroToError() throws {
        let tool = try fakeProcessTool(exit: 1)
        defer { try? FileManager.default.removeItem(at: tool) }
        #expect(throws: SystemctlError.nonZeroExit(1)) {
            try ProcessSystemctl(executableURL: tool).enableNow(unit: "dev.rv.evaluate.service")
        }
    }

    @Test func processSystemctl_disableTreats1And5AsSuccess() throws {
        let one = try fakeProcessTool(exit: 1)
        defer { try? FileManager.default.removeItem(at: one) }
        try ProcessSystemctl(executableURL: one).disableNow(unit: "dev.rv.evaluate.service")

        let five = try fakeProcessTool(exit: 5)
        defer { try? FileManager.default.removeItem(at: five) }
        try ProcessSystemctl(executableURL: five).disableNow(unit: "dev.rv.evaluate.service")
    }

    @Test func processSystemctl_disableRejectsOtherStatuses() throws {
        let tool = try fakeProcessTool(exit: 2)
        defer { try? FileManager.default.removeItem(at: tool) }
        #expect(throws: SystemctlError.nonZeroExit(2)) {
            try ProcessSystemctl(executableURL: tool).disableNow(unit: "dev.rv.evaluate.service")
        }
    }

    @Test func processSystemctl_missingBinaryThrows() {
        let missing = URL(fileURLWithPath: "/tmp/rv-missing-systemctl-\(UUID().uuidString)")
        #expect(throws: (any Error).self) {
            try ProcessSystemctl(executableURL: missing).enableNow(unit: "x")
        }
    }

    @Test func processLaunchctl_bootstrapAndBootoutHonorStatuses() throws {
        let ok = try fakeProcessTool(exit: 0)
        defer { try? FileManager.default.removeItem(at: ok) }
        let plist = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-launchd-\(UUID().uuidString).plist")
        try "plist".write(to: plist, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: plist) }
        let launchctl = ProcessLaunchctl(executableURL: ok)
        try launchctl.bootstrap(domain: "gui/1", plist: plist)
        try launchctl.bootout(domain: "gui/1", label: "dev.rv.evaluate")
        #expect(launchctl.isLoaded(domain: "gui/1", label: "dev.rv.evaluate"))
    }

    @Test func processLaunchctl_isLoadedFalseWhenPrintFails() throws {
        let tool = try fakeProcessTool(exit: 1)
        defer { try? FileManager.default.removeItem(at: tool) }
        let launchctl = ProcessLaunchctl(executableURL: tool)
        #expect(launchctl.isLoaded(domain: "user/1", label: "dev.rv.evaluate") == false)
        #expect(throws: LaunchctlError.nonZeroExit(1)) {
            try launchctl.bootstrap(
                domain: "gui/1",
                plist: URL(fileURLWithPath: "/tmp/rv-missing.plist")
            )
        }
    }

    @Test func processLaunchctl_bootoutAcceptsAlreadyUnloadedStatuses() throws {
        var tools: [URL] = []
        defer {
            for tool in tools { try? FileManager.default.removeItem(at: tool) }
        }
        for status: Int32 in [3, 5, 113] {
            let tool = try fakeProcessTool(exit: status)
            tools.append(tool)
            try ProcessLaunchctl(executableURL: tool).bootout(
                domain: "user/1",
                label: "dev.rv.evaluate"
            )
        }
    }

    @Test func launchAgentProbe_missingLaunchctlIsNotLoaded() {
        #expect(LaunchAgentProbe.isLoaded(label: "dev.rv.evaluate") == false)
    }

    @Test func loginHome_pathIsReadableAndMatchIsLiteral() {
        let login = LoginHome.path()
        if let login {
            #expect(LoginHome.matchesProcessHome(login))
            #expect(LoginHome.matchesProcessHome("/tmp/rv-not-login-\(UUID().uuidString)") == false)
        } else {
            #expect(LoginHome.matchesProcessHome("/tmp") == false)
        }
    }

    @Test func launchdDomain_orders() {
        #expect(LaunchdDomain.gui(501) == "gui/501")
        #expect(LaunchdDomain.user(501) == "user/501")
        #expect(LaunchdDomain.bootoutOrder(uid: 501) == ["user/501", "gui/501"])
        #expect(LaunchdDomain.bootstrapOrder(uid: 501) == ["gui/501", "user/501"])
        #expect(LaunchdDomain.agentPrintTarget(uid: 501, label: "dev.rv.evaluate") == "gui/501/dev.rv.evaluate")
    }
}
