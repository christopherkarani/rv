import Testing
import RVDomain
import RVPolicy
@testable import RVCLI

struct HomeSeamTests {
    @Test func evaluateCommand_flowsInjectedHomeIntoPackSelection() async throws {
        let home = try isolatedHome()
        try PacksConfigStore.save(PacksConfig(disabled: ["core.git"]), home: home)
        let result = try await CommandRun.evaluateCommand(
            "git reset --hard",
            cwd: "/tmp/ws",
            allowOnceDirectory: try isolatedAllowOnceDirectory(),
            home: home
        )
        #expect(result.decision == .allow)
    }

    @Test func serviceClient_flowsInjectedHomeIntoPackSelection() async throws {
        let home = try isolatedHome()
        try PacksConfigStore.save(PacksConfig(disabled: ["core.git"]), home: home)
        let client = ServiceClient(
            transport: nil,
            allowOnceDirectory: try isolatedAllowOnceDirectory(),
            home: home
        )
        let reply = await client.evaluate(command: ShellCommand(rawValue: "git reset --hard"))
        #expect(reply.result.decision == .allow)
    }
}
