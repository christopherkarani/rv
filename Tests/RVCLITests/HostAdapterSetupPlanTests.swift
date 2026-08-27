import Foundation
import RVPolicy
import RVPresentation
import Testing
@testable import RVCLI

@Test func setupPlan_missingAndOccupiedAndWrite() throws {
    let path = OwnedPaths(home: try #require(HomeDirectory(validating: "/tmp"))).hostAdapter(for: .grok)
    let payload = Data("wired".utf8)
    #expect(HostAdapterInstallation.missing(path).setupPlan(force: false) == .skipUndetected)
    #expect(HostAdapterInstallation.missing(path).setupPlan(force: true) == .skipUndetected)
    #expect(HostAdapterInstallation.occupied(path).setupPlan(force: false) == .skipOccupied)
    #expect(HostAdapterInstallation.occupied(path).setupPlan(force: true) == .forceClearThenWrite)
    #expect(HostAdapterInstallation.absentFile(path).setupPlan(force: false) == .write(existingData: nil))
    #expect(
        HostAdapterInstallation.broken(path: path, existingData: payload).setupPlan(force: false)
            == .write(existingData: payload)
    )
    #expect(
        HostAdapterInstallation.wired(path: path, existingData: payload).setupPlan(force: false)
            == .write(existingData: payload)
    )
}

@Test func uninstallPlan_removeOccupiedSkip() throws {
    let path = OwnedPaths(home: try #require(HomeDirectory(validating: "/tmp"))).hostAdapter(for: .pi)
    let payload = Data("x".utf8)
    #expect(HostAdapterInstallation.broken(path: path, existingData: payload).uninstallPlan == .remove)
    #expect(HostAdapterInstallation.wired(path: path, existingData: payload).uninstallPlan == .remove)
    #expect(HostAdapterInstallation.occupied(path).uninstallPlan == .leaveOccupied)
    #expect(HostAdapterInstallation.missing(path).uninstallPlan == .skip)
    #expect(HostAdapterInstallation.absentFile(path).uninstallPlan == .skip)
}

@Test func workPlan_occupiedGrokAndAbsentPi_skipsGrokWritesPiWithoutFilesystem() throws {
    let homePath = "/tmp/rv-workplan-absent-\(UUID().uuidString)"
    let layout = OwnedPaths(home: try #require(HomeDirectory(validating: homePath)))
    let installations = HostAdapterInstallationSnapshot(
        grok: .occupied(layout.hostAdapter(for: .grok)),
        pi: .absentFile(layout.hostAdapter(for: .pi)),
        openCode: .missing(layout.hostAdapter(for: .opencode)),
        claude: .missing(layout.hostAdapter(for: .claude)),
        openClaw: .missing(layout.hostAdapter(for: .openclaw)),
        hermes: .missing(layout.hostAdapter(for: .hermes)),
        codex: .missing(layout.hostAdapter(for: .codex)),
        cursor: .missing(layout.hostAdapter(for: .cursor))
    )

    let plan = SetupWorkPlanBuilder.make(
        installations: installations,
        layout: layout,
        force: false,
        rvdIsExecutable: true
    )

    #expect(plan.steps == [
        .createConfigDirectory,
        .skipOccupied(.grok),
        .write(.pi, existingData: nil),
        .skipUndetected(.opencode),
        .skipUndetected(.claude),
        .skipUndetected(.openclaw),
        .skipUndetected(.hermes),
        .skipUndetected(.codex),
        .skipUndetected(.cursor),
        .writeLaunchAgent,
    ])
    #expect(
        FileManager.default.fileExists(atPath: homePath) == false,
        "plan builder must not create HOME"
    )
}

@Test func workPlan_rvdNotExecutable_skipsLaunchAgent() throws {
    let homePath = "/tmp/rv-workplan-no-rvd-\(UUID().uuidString)"
    let layout = OwnedPaths(home: try #require(HomeDirectory(validating: homePath)))
    let installations = HostAdapterInstallationSnapshot(
        grok: .missing(layout.hostAdapter(for: .grok)),
        pi: .missing(layout.hostAdapter(for: .pi)),
        openCode: .missing(layout.hostAdapter(for: .opencode)),
        claude: .missing(layout.hostAdapter(for: .claude)),
        openClaw: .missing(layout.hostAdapter(for: .openclaw)),
        hermes: .missing(layout.hostAdapter(for: .hermes)),
        codex: .missing(layout.hostAdapter(for: .codex)),
        cursor: .missing(layout.hostAdapter(for: .cursor))
    )

    let plan = SetupWorkPlanBuilder.make(
        installations: installations,
        layout: layout,
        force: false,
        rvdIsExecutable: false
    )

    #expect(plan.steps.contains(.skipLaunchAgent))
    #expect(plan.steps.contains(.writeLaunchAgent) == false)
    #expect(plan.steps == [
        .createConfigDirectory,
        .skipUndetected(.grok),
        .skipUndetected(.pi),
        .skipUndetected(.opencode),
        .skipUndetected(.claude),
        .skipUndetected(.openclaw),
        .skipUndetected(.hermes),
        .skipUndetected(.codex),
        .skipUndetected(.cursor),
        .skipLaunchAgent,
    ])
    #expect(
        FileManager.default.fileExists(atPath: homePath) == false,
        "plan builder must not create HOME"
    )
}

@Test func workPlan_forceOccupied_isForceClearThenWrite() throws {
    let layout = OwnedPaths(home: try #require(HomeDirectory(validating: "/tmp")))
    let installations = HostAdapterInstallationSnapshot(
        grok: .occupied(layout.hostAdapter(for: .grok)),
        pi: .missing(layout.hostAdapter(for: .pi)),
        openCode: .missing(layout.hostAdapter(for: .opencode)),
        claude: .missing(layout.hostAdapter(for: .claude)),
        openClaw: .missing(layout.hostAdapter(for: .openclaw)),
        hermes: .missing(layout.hostAdapter(for: .hermes)),
        codex: .missing(layout.hostAdapter(for: .codex)),
        cursor: .missing(layout.hostAdapter(for: .cursor))
    )

    let plan = SetupWorkPlanBuilder.make(
        installations: installations,
        layout: layout,
        force: true,
        rvdIsExecutable: true
    )

    #expect(plan.steps.contains(.forceClearThenWrite(.grok)))
    #expect(plan.steps.contains(.skipOccupied(.grok)) == false)
    #expect(plan.steps == [
        .createConfigDirectory,
        .forceClearThenWrite(.grok),
        .skipUndetected(.pi),
        .skipUndetected(.opencode),
        .skipUndetected(.claude),
        .skipUndetected(.openclaw),
        .skipUndetected(.hermes),
        .skipUndetected(.codex),
        .skipUndetected(.cursor),
        .writeLaunchAgent,
    ])
}
