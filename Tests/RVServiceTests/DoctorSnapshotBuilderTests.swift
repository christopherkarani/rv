import RVIPC
import RVPacks
import Testing
@testable import RVService

struct DoctorSnapshotBuilderTests {
    @Test func omittedKeepAliveStaysFalse() throws {
        let snapshot = DoctorSnapshotBuilder.make(
            catalog: PackCatalog(),
            corePacksReady: true,
            idleExitSeconds: 300
        )
        #expect(snapshot.keepAlive == false)
        #expect(snapshot.idleExitSeconds == 300)
        let packs = try #require(snapshot.checks.first { $0.id == .packs })
        #expect(packs.message == "core.filesystem, core.git, and system.disk loaded")
        let message = try launchdMessage(snapshot)
#if os(Linux)
        #expect(message == "template dev.rv.evaluate Restart=no idle-exit 300s")
        #expect(message.contains("KeepAlive") == false)
#else
        #expect(message == "template dev.rv.evaluate KeepAlive false idle-exit 300s")
#endif
    }

#if !os(Linux)
    @Test func darwinCompanionReportsKeepAliveTrue() throws {
        let snapshot = DoctorSnapshotBuilder.make(
            catalog: PackCatalog(),
            corePacksReady: true,
            idleExitSeconds: 300,
            keepAlive: true
        )
        #expect(snapshot.keepAlive == true)
        #expect(snapshot.idleExitSeconds == 300)
        #expect(try launchdMessage(snapshot) == "template dev.rv.evaluate KeepAlive true")
    }

    @Test func darwinWithoutCompanionReportsIdleExitSeconds() throws {
        let snapshot = DoctorSnapshotBuilder.make(
            catalog: PackCatalog(),
            corePacksReady: true,
            idleExitSeconds: 42,
            keepAlive: false
        )
        #expect(snapshot.keepAlive == false)
        #expect(snapshot.idleExitSeconds == 42)
        #expect(
            try launchdMessage(snapshot)
                == "template dev.rv.evaluate KeepAlive false idle-exit 42s"
        )
    }
#endif

#if os(Linux)
    @Test func linuxKeepAliveTrueStillReportsRestartNo() throws {
        let snapshot = DoctorSnapshotBuilder.make(
            catalog: PackCatalog(),
            corePacksReady: true,
            idleExitSeconds: 300,
            keepAlive: true
        )
        #expect(snapshot.keepAlive == false)
        let message = try launchdMessage(snapshot)
        #expect(message == "template dev.rv.evaluate Restart=no idle-exit 300s")
        #expect(message.contains("KeepAlive") == false)
    }

    @Test func linuxCopyReportsCallerIdleExitSeconds() throws {
        let snapshot = DoctorSnapshotBuilder.make(
            catalog: PackCatalog(),
            corePacksReady: true,
            idleExitSeconds: 42,
            keepAlive: true
        )
        #expect(snapshot.keepAlive == false)
        #expect(snapshot.idleExitSeconds == 42)
        #expect(
            try launchdMessage(snapshot)
                == "template dev.rv.evaluate Restart=no idle-exit 42s"
        )
    }
#endif
}

private func launchdMessage(_ snapshot: DoctorSnapshotReply) throws -> String {
    try #require(snapshot.checks.first { $0.id == .launchd }).message
}
