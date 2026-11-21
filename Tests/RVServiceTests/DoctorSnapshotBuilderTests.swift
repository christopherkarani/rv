import RVDomain
import RVIPC
import RVPacks
import Testing
@testable import RVService

struct DoctorSnapshotBuilderTests {
    @Test func reportsTheTemplateSupervisorAndIdleExit() throws {
        let snapshot = DoctorSnapshotBuilder.make(
            catalog: PackCatalog(),
            corePacksReady: true,
            idleExitSeconds: 300
        )
        #expect(snapshot.idleExitSeconds == 300)
        let packs = try #require(snapshot.checks.first { $0.id == .packs })
        #expect(packs.message == "core.filesystem, core.git, and system.disk loaded")
        let message = try launchdMessage(snapshot)
#if os(Linux)
        #expect(snapshot.keepAlive == false)
        #expect(message == "template dev.rv.evaluate Restart=always idle-exit 300s")
        #expect(message.contains("KeepAlive") == false)
#else
        #expect(snapshot.keepAlive == true)
        #expect(message == "template dev.rv.evaluate KeepAlive true idle-exit 300s")
#endif
    }

    /// The default: the supervisor keeps rvd resident, no idle exit.
    @Test func idleExitOffIsReportedAsOff() throws {
        let snapshot = DoctorSnapshotBuilder.make(
            catalog: PackCatalog(),
            corePacksReady: true,
            idleExitSeconds: 0
        )
        #expect(snapshot.idleExitSeconds == 0)
#if os(Linux)
        #expect(try launchdMessage(snapshot) == "template dev.rv.evaluate Restart=always idle-exit off")
#else
        #expect(snapshot.keepAlive == true)
        #expect(try launchdMessage(snapshot) == "template dev.rv.evaluate KeepAlive true idle-exit off")
#endif
    }
}

private func launchdMessage(_ snapshot: DoctorSnapshotReply) throws -> String {
    try #require(snapshot.checks.first { $0.id == .launchd }).message
}
