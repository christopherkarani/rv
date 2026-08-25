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

private func workPlanLayout() throws -> OwnedPaths {
    OwnedPaths(home: try #require(HomeDirectory(validating: "/rv-plan-home")))
}

@Test func workPlan_occupiedGrokDetectedPi_skipsOccupiedAndWritesPi() throws {
    let layout = try workPlanLayout()
    let homePath = layout.home.rawValue
    #expect(FileManager.default.fileExists(atPath: homePath) == false)

    let plan = SetupWorkPlanBuilder.make(
        installations: HostAdapterInstallationSnapshot(
            grok: .occupied(layout.hostAdapter(for: .grok)),
            pi: .absentFile(layout.hostAdapter(for: .pi)),
            openCode: .missing(layout.hostAdapter(for: .openCode))
        ),
        layout: layout,
        force: false,
        rvdIsExecutable: true
    )

    #expect(plan.steps == [
        .createConfigDirectory,
        .writeLaunchAgent,
        .skipOccupied(.grok),
        .write(.pi, existingData: nil),
        .skipUndetected(.openCode),
    ])
    #expect(plan.predictedKind(for: .grok) == .occupied)
    #expect(plan.predictedKind(for: .pi) == .wired)
    #expect(plan.predictedKind(for: .openCode) == .pending)
    #expect(FileManager.default.fileExists(atPath: homePath) == false)
}

@Test func workPlan_rvdNotExecutable_skipsLaunchAgent() throws {
    let layout = try workPlanLayout()
    let plan = SetupWorkPlanBuilder.make(
        installations: HostAdapterInstallationSnapshot(
            grok: .missing(layout.hostAdapter(for: .grok)),
            pi: .missing(layout.hostAdapter(for: .pi)),
            openCode: .missing(layout.hostAdapter(for: .openCode))
        ),
        layout: layout,
        force: false,
        rvdIsExecutable: false
    )

    #expect(plan.steps == [
        .createConfigDirectory,
        .skipLaunchAgent,
        .skipUndetected(.grok),
        .skipUndetected(.pi),
        .skipUndetected(.openCode),
    ])
}

@Test func workPlan_occupiedWithForce_forceClearThenWrite() throws {
    let layout = try workPlanLayout()
    let plan = SetupWorkPlanBuilder.make(
        installations: HostAdapterInstallationSnapshot(
            grok: .occupied(layout.hostAdapter(for: .grok)),
            pi: .absentFile(layout.hostAdapter(for: .pi)),
            openCode: .missing(layout.hostAdapter(for: .openCode))
        ),
        layout: layout,
        force: true,
        rvdIsExecutable: true
    )

    #expect(plan.steps == [
        .createConfigDirectory,
        .writeLaunchAgent,
        .forceClearThenWrite(.grok),
        .write(.pi, existingData: nil),
        .skipUndetected(.openCode),
    ])
}

@Test func workPlan_wiredHost_carriesExistingBytesOnWrite() throws {
    let layout = try workPlanLayout()
    let payload = Data("wired".utf8)
    let plan = SetupWorkPlanBuilder.make(
        installations: HostAdapterInstallationSnapshot(
            grok: .wired(path: layout.hostAdapter(for: .grok), existingData: payload),
            pi: .missing(layout.hostAdapter(for: .pi)),
            openCode: .missing(layout.hostAdapter(for: .openCode))
        ),
        layout: layout,
        force: false,
        rvdIsExecutable: true
    )
    #expect(plan.steps.contains(.write(.grok, existingData: payload)))
}
