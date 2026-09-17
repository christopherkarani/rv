import Foundation
import Testing
@testable import RVAnalytics

@Suite("PlatformSnapshot")
struct PlatformSnapshotTests {
    @Test func makeLiveUsesProcessInfoVersion() {
        let live = PlatformSnapshot.makeLive()
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #expect(
            live.osVersion
                == "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        )
        #expect(live.osBuild.isEmpty == false)
        #expect(live.osBuild.contains("/") == false)
        #expect(live.osBuild.contains(" ") == false)
    }

    @Test func explicitSnapshotRoundTrips() {
        let snapshot = PlatformSnapshot(osVersion: "1.2.3", osBuild: "build")
        #expect(snapshot.osVersion == "1.2.3")
        #expect(snapshot.osBuild == "build")
        #expect(snapshot == PlatformSnapshot(osVersion: "1.2.3", osBuild: "build"))
    }

#if !canImport(Darwin)
    @Test func osReleaseMissingFileIsNil() {
        #expect(
            PlatformSnapshot.osReleaseField("VERSION_ID", filePath: "/no/such/os-release") == nil
        )
    }

    @Test func osReleaseReadsHostFileWhenPresent() {
        let version = PlatformSnapshot.osReleaseField("VERSION_ID")
        if FileManager.default.fileExists(atPath: "/etc/os-release") {
            #expect(version == "24.04" || (version?.isEmpty == false))
        }
        #expect(PlatformSnapshot.osReleaseField("RV_NOT_A_FIELD") == nil)
    }

    @Test func osReleaseParsesQuotedAndBareValues() throws {
        let root = try temporaryConfigRoot()
        let file = root.appendingPathComponent("os-release", isDirectory: false)
        let text = """
        NAME="Ubuntu"
        VERSION_ID=24.04
        BUILD_ID="abc def"
        EMPTY=
        """
        try Data(text.utf8).write(to: file)
        #expect(
            PlatformSnapshot.osReleaseField("VERSION_ID", filePath: file.path) == "24.04"
        )
        #expect(
            PlatformSnapshot.osReleaseField("BUILD_ID", filePath: file.path) == "abc def"
        )
        #expect(PlatformSnapshot.osReleaseField("NAME", filePath: file.path) == "Ubuntu")
        #expect(PlatformSnapshot.osReleaseField("EMPTY", filePath: file.path) == "")
        #expect(PlatformSnapshot.osReleaseField("MISSING", filePath: file.path) == nil)
    }
#endif
}
