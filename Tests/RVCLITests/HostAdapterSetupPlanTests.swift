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
