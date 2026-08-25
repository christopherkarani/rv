import Foundation
import RVDomain
import RVPolicy
import RVPresentation
import Testing
@testable import RVCLI

private func withInstallationHome(
    _ body: (URL, OwnedPaths) throws -> Void
) throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-host-inspection-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    try body(home, OwnedPaths(home: try #require(HomeDirectory(validating: home.path))))
}

@Test(arguments: HookHost.setupSlotOrder)
func hostInstallation_missingIsReadOnly(_ host: HookHost) throws {
    try withInstallationHome { home, paths in
        let before = try FileManager.default.contentsOfDirectory(atPath: home.path)

        let snapshot = try HostAdapterInstallation.inspect(
            paths: paths,
            pathEntries: [],
            fileManager: .default
        )

        #expect(snapshot.state(for: host) == .missing)
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.path) == before)
    }
}

@Test(arguments: HookHost.setupSlotOrder)
func hostInstallation_detectedWithoutOwnedFileIsAbsentFile(_ host: HookHost) throws {
    try withInstallationHome { _, paths in
        let owned = paths.hostAdapter(for: host)
        try FileManager.default.createDirectory(
            atPath: owned.detectionDirectory,
            withIntermediateDirectories: true
        )

        let snapshot = try HostAdapterInstallation.inspect(
            paths: paths,
            pathEntries: [],
            fileManager: .default
        )

        #expect(snapshot.state(for: host) == .absentFile)
        #expect(FileManager.default.fileExists(atPath: owned.destination) == false)
    }
}

@Test(arguments: HookHost.setupSlotOrder)
func hostInstallation_foreignOwnedBytesAreOccupiedAndUnchanged(_ host: HookHost) throws {
    try withInstallationHome { _, paths in
        let owned = paths.hostAdapter(for: host)
        let foreign = Data([0xFF, 0x00, 0x41])
        try FileManager.default.createDirectory(
            atPath: (owned.destination as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try foreign.write(to: URL(fileURLWithPath: owned.destination))

        let snapshot = try HostAdapterInstallation.inspect(
            paths: paths,
            pathEntries: [],
            fileManager: .default
        )

        #expect(snapshot.state(for: host) == .occupied)
        #expect(try Data(contentsOf: URL(fileURLWithPath: owned.destination)) == foreign)
    }
}

@Test(arguments: HookHost.setupSlotOrder)
func hostInstallation_symlinkAtOwnedNameIsOccupiedWithoutFollowing(_ host: HookHost) throws {
    try withInstallationHome { home, paths in
        let owned = paths.hostAdapter(for: host)
        let target = home.appendingPathComponent("foreign-adapter")
        try "foreign".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            atPath: (owned.destination as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: owned.destination,
            withDestinationPath: target.path
        )

        let snapshot = try HostAdapterInstallation.inspect(
            paths: paths,
            pathEntries: [],
            fileManager: .default
        )

        #expect(snapshot.state(for: host) == .occupied)
        #expect(try String(contentsOf: target, encoding: .utf8) == "foreign")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: owned.destination) == target.path)
    }
}

@Test(arguments: HookHost.setupSlotOrder)
func hostInstallation_danglingSymlinkAtOwnedNameIsOccupied(_ host: HookHost) throws {
    try withInstallationHome { _, paths in
        let owned = paths.hostAdapter(for: host)
        try FileManager.default.createDirectory(
            atPath: (owned.destination as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: owned.destination,
            withDestinationPath: "/nonexistent/foreign-adapter"
        )

        let snapshot = try HostAdapterInstallation.inspect(
            paths: paths,
            pathEntries: [],
            fileManager: .default
        )

        #expect(snapshot.state(for: host) == .occupied)
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: owned.destination)
                == "/nonexistent/foreign-adapter"
        )
    }
}

@Test(arguments: HookHost.setupSlotOrder)
func hostInstallation_currentResourceWithMissingExecutableIsBroken(_ host: HookHost) throws {
    try withInstallationHome { _, paths in
        let owned = paths.hostAdapter(for: host)
        let body = try host.adapterResource().rendered(rvPath: "/nonexistent/rv")
        try FileManager.default.createDirectory(
            atPath: (owned.destination as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try body.write(toFile: owned.destination, atomically: true, encoding: .utf8)

        let snapshot = try HostAdapterInstallation.inspect(
            paths: paths,
            pathEntries: [],
            fileManager: .default
        )

        #expect(snapshot.state(for: host) == .broken)
        #expect(snapshot.state(for: host) != .wired)
    }
}

@Test(arguments: HookHost.setupSlotOrder)
func hostInstallation_currentResourceWithExecutableIsWired(_ host: HookHost) throws {
    try withInstallationHome { home, paths in
        let owned = paths.hostAdapter(for: host)
        let executable = home.appendingPathComponent("bin/rv")
        try makeExecutable(executable)
        let body = try host.adapterResource().rendered(rvPath: executable.path)
        try FileManager.default.createDirectory(
            atPath: (owned.destination as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try body.write(toFile: owned.destination, atomically: true, encoding: .utf8)

        let snapshot = try HostAdapterInstallation.inspect(
            paths: paths,
            pathEntries: [],
            fileManager: .default
        )

        #expect(snapshot.state(for: host) == .wired)
    }
}
