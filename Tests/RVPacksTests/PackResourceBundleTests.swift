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

    /// Swift Build emits `<name>.bundle` on Linux too; looking only for the
    /// legacy `.resources` name failed every pack load on Linux CI.
    @Test func dotBundleIsFoundOnEveryPlatform() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-packs-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = root.appendingPathComponent(PackResourceBundle.bundleName + ".bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let found = try #require(PackResourceBundle.locate(candidates: [nil, root]))
        #expect(found.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
            == bundleURL.standardizedFileURL.resolvingSymlinksInPath())
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
