import Foundation
import Testing
import RVDomain
@testable import RVPacks

/// SwiftPM's generated `Bundle.module` traps when the resource bundle is
/// missing next to the binary, which crash-loops `rvd` under launchd.
/// The registry's lookup must fail as a thrown, recoverable error instead.
@Suite("Pack resource bundle lookup")
struct PackResourceBundleTests {
    @Test func missingBundleIsNilNotATrap() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-no-packs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(PackResourceBundle.locate(candidates: [empty, nil]) == nil)
    }

    @Test func missingBundleThrowsMissingResource() {
        #expect(throws: PackLoadError.missingResource(PackResourceBundle.bundleName)) {
            _ = try PackResourceBundle.require(nil)
        }
    }

    @Test func presentBundleIsFoundAtTheSameCandidatesSwiftPMUses() throws {
        let bundle = try #require(PackResourceBundle.located)
        #expect(bundle.bundleURL.lastPathComponent.hasPrefix(PackResourceBundle.bundleName))
        let index = try PackRegistry.loadIndex()
        #expect(index.packCount > 0)
        #expect(try PackRegistry.loadDayOne().isEmpty == false)
    }
}
