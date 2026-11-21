import Foundation
import RVDomain
import RVIPC
import RVLaya
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

@Suite("Doctor Core ML notes")
struct DoctorCoreMLNotesTests {
    @Test("a healthy guard adds no note")
    func healthy() {
        #expect(DoctorSnapshotBuilder.coreMLNotes(.init(units: .cpuAndGPU, cpuOnlyUntil: nil, diskLow: false)).isEmpty)
    }

    @Test("CPU-only fallback and a full disk are both named")
    func degraded() {
        let notes = DoctorSnapshotBuilder.coreMLNotes(
            .init(units: .cpuOnly, cpuOnlyUntil: Date(timeIntervalSince1970: 1_800_000_000), diskLow: true))
        #expect(notes.count == 2)
        #expect(notes[0].hasPrefix("CPU only until 2027-01-15"))
        #expect(notes[0].hasSuffix("after repeated Core ML crashes"))
        #expect(notes[1] == "disk nearly full; judge disabled until space is freed")
    }

    @Test("the last judge load refusal is shown")
    func lastRefusal() {
        let notes = DoctorSnapshotBuilder.coreMLNotes(
            .init(units: .cpuAndGPU, cpuOnlyUntil: nil, diskLow: false, lastRefusal: "Laya judge: nope"))
        #expect(notes == ["last judge load refused: Laya judge: nope"])
    }

    @Test("rvd running without its crash marker is named")
    func markerUnavailable() {
        let notes = DoctorSnapshotBuilder.coreMLNotes(
            .init(units: .cpuAndGPU, cpuOnlyUntil: nil, diskLow: false, crashMarkerUnavailable: true))
        #expect(notes == ["Core ML crash marker held by another process or unwritable; no CPU-only fallback after a crash"])
    }
}
