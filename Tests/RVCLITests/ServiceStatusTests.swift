import Testing
@testable import RVCLI

struct ServiceStatusTests {
    @Test func robotAndPlainFieldsForDown() async throws {
        let report = try await isolatedClient(transport: nil).status()
        #expect(report.state == "down")
        #expect(report.fallback == "down")
        #expect(report.protocolName == "rv.ipc.v1")
        #expect(report.label == "dev.rv.evaluate")
        #expect(report.keepAlive == false)
        let robot = ServiceStatusCommand.robotText(report)
        #expect(robot.contains("state=down"))
        #expect(robot.contains("protocol=rv.ipc.v1"))
        #expect(robot.contains("label=dev.rv.evaluate"))
        #expect(robot.contains("fallback=down"))
        #expect(robot.contains("keepAlive=false"))
        #expect(robot.contains("\u{001B}") == false)
        let plain = ServiceStatusCommand.plainText(report)
        #expect(plain.contains("state down"))
        #expect(plain.contains("\u{001B}") == false)
    }

    @Test func runningReportsInactiveFallback() async throws {
        let transport = ScriptedTransport(
            ack: HelloAckView(protocolName: "rv.ipc.v1", serviceSemver: "1.0.0", ok: true)
        )
        let report = try await isolatedClient(transport: transport).status()
        #expect(report.state == "running")
        #expect(report.fallback == "inactive")
        #expect(report.keepAlive == false)
        #expect(XPCServiceTransport.serviceName == "dev.rv.evaluate")
    }
}
