import RVDomain
import RVIPC
import RVPresentation
import RVService
import Testing
@testable import RVCLI

struct ServiceStatusTests {
    @Test func robotAndPlainFieldsForDown() async throws {
        let client = try isolatedClient(transport: nil)
        let health = ServiceHealth.inspect(await client.diagnostics())
        #expect(
            health == .down(
                .local(.init(corePacksReady: true, serviceSemver: nil, launchAgent: .missing))
            )
        )

        let report = await client.status()
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
        let snapshot = DoctorSnapshotReply(
            state: .running,
            idleExitSeconds: 300,
            packsEnabled: [.coreGit, .coreFilesystem],
            checks: []
        )
        let transport = ScriptedTransport(
            ack: HelloAckView(protocolName: "rv.ipc.v1", serviceSemver: "1.0.0", ok: true),
            responseResult: .doctorSnapshot(snapshot)
        )
        let client = try isolatedClient(transport: transport)
        let health = ServiceHealth.inspect(await client.diagnostics())
        #expect(
            health == .reachable(
                .init(snapshot: snapshot, localCorePacksReady: true, launchAgent: .missing)
            )
        )

        let report = await client.status()
        #expect(report.state == "running")
        #expect(report.fallback == "inactive")
        #expect(report.keepAlive == false)
#if canImport(XPC)
        #expect(XPCServiceTransport.serviceName == "dev.rv.evaluate")
#else
        #expect(RVService.machServiceName == "dev.rv.evaluate")
#endif
    }

    @Test func requestFailureIsDownNotFalseRunning() async throws {
        let transport = ScriptedTransport(
            ack: HelloAckView(protocolName: "rv.ipc.v1", serviceSemver: "1.0.0", ok: true),
            sendError: .interrupted
        )

        let client = try isolatedClient(transport: transport)
        let health = ServiceHealth.inspect(await client.diagnostics())
        #expect(
            health == .requestFailed(
                failure: .transport(.interrupted),
                local: .init(
                    corePacksReady: true,
                    serviceSemver: "1.0.0",
                    launchAgent: .missing
                )
            )
        )

        let report = await client.status()
        #expect(report.state == "down")
        #expect(report.fallback == "down")
        #expect(report.lastError == "request failed")
    }

    @Test func xpcDownSnapshotReportsDownNotRunning() async throws {
        let snapshot = DoctorSnapshotReply(
            state: .down,
            idleExitSeconds: 300,
            packsEnabled: [.coreGit, .coreFilesystem],
            checks: []
        )
        let transport = ScriptedTransport(
            ack: HelloAckView(protocolName: "rv.ipc.v1", serviceSemver: "1.0.0", ok: true),
            responseResult: .doctorSnapshot(snapshot)
        )
        let client = try isolatedClient(transport: transport)
        let health = ServiceHealth.inspect(await client.diagnostics())
        #expect(
            health == .down(
                .xpc(
                    .init(
                        snapshot: snapshot,
                        localCorePacksReady: true,
                        launchAgent: .missing
                    )
                )
            )
        )

        let report = await client.status()
        #expect(report.state == "down")
        #expect(report.fallback == "down")
        #expect(report.lastError == nil)
        let robot = ServiceStatusCommand.robotText(report)
        #expect(robot.contains("state=down"))
        #expect(robot.contains("launch") == false)
        #expect(robot.contains("pack") == false)
    }

    @Test func robotOutputKeepsExactPreMigrationBytes() {
        let running = ServiceStatusReport(
            state: "running",
            fallback: "inactive",
            keepAlive: true,
            lastError: "peer supplied detail"
        )
        let runningGolden = """
            state=running
            protocol=rv.ipc.v1
            label=dev.rv.evaluate
            fallback=inactive
            keepAlive=true
            lastError=peer supplied detail
            """
        #expect(ServiceStatusCommand.robotText(running) == runningGolden)
        #expect(RobotDocument.serviceStatus(running).render() == runningGolden)

        let down = ServiceStatusReport(state: "down", fallback: "down")
        let downGolden = """
            state=down
            protocol=rv.ipc.v1
            label=dev.rv.evaluate
            fallback=down
            keepAlive=false
            """
        #expect(ServiceStatusCommand.robotText(down) == downGolden)
        #expect(RobotDocument.serviceStatus(down).render() == downGolden)
    }

    @Test func xpcSkewSnapshotReportsSkewNotRunning() async throws {
        let snapshot = DoctorSnapshotReply(
            state: .skew,
            idleExitSeconds: 300,
            packsEnabled: [.coreGit, .coreFilesystem],
            lastError: "peer supplied detail",
            checks: []
        )
        let transport = ScriptedTransport(
            ack: HelloAckView(protocolName: "rv.ipc.v1", serviceSemver: "1.0.0", ok: true),
            responseResult: .doctorSnapshot(snapshot)
        )
        let client = try isolatedClient(transport: transport)
        let health = ServiceHealth.inspect(await client.diagnostics())
        #expect(
            health == .skew(
                reason: nil,
                source: .xpc(
                    .init(
                        snapshot: snapshot,
                        localCorePacksReady: true,
                        launchAgent: .missing
                    )
                )
            )
        )

        let report = await client.status()
        #expect(report.state == "skew")
        #expect(report.fallback == "skew")
        #expect(report.lastError == nil)
        let robot = ServiceStatusCommand.robotText(report)
        #expect(robot.contains("state=skew"))
        #expect(robot.contains("peer supplied detail") == false)
        #expect(robot.contains("launch") == false)
        #expect(robot.contains("pack") == false)
    }
}
