#if os(macOS)
import Foundation
import RVDomain
import Testing
@testable import RVIsolation

/// T11: R3 tmp posture — re-accepted as explicit risk (2026-10-10).
///
/// Under the T10 per-MIB posture (dedicated cage uid DEFERRED), the
/// confstr-tmp grant stays read-write over the whole confstr dir:
/// write-only breaks the test-bundle plist read-back, a subdir grant
/// breaks SwiftBuild's own temp names, and Seatbelt subpaths are
/// prefix-only so the grant cannot be scoped to cage-created files.
/// These tests lock the accepted shape at profile-text level. The live
/// pins (`containedChildReadsPlantedPerUserTmpFile`,
/// `siblingTmpOutsideWorkspaceStaysContentDenied`) and the neighboring
/// profile-text pins
/// (`productiveProfileGrantsSystemTemporaryDirectoryReadWrite`,
/// `productiveProfileOmitsSystemTemporaryDirectoryWhenUnresolved`)
/// live in their owning suites and stay green as-is. If a future ticket
/// narrows this grant (upstream temp-var propagation, dedicated uid),
/// it must flip these tests deliberately and update the operator
/// guidance at the grant site in `SeatbeltProfile`.
@Suite("SeatbeltR3TmpPosture")
struct SeatbeltR3TmpPostureTests {
    /// The accepted shape is read-write over the resolved dir, exactly
    /// once — co-pinned here from T11's side so a future narrowing
    /// breaks loudly against the recorded decision, not silently.
    /// No narrowed fallback shape (write-only, metadata-only) is
    /// present for the resolved dir.
    @Test func acceptedGrantIsReadWriteOverResolvedDir() {
        var resolution = ProductiveWorkspaceResolution()
        resolution.systemTemporaryDirectory = "/private/var/folders/x/T"
        let base = SeatbeltProfile(source: "(version 1)\n(deny default)\n", workspacePath: "/tmp/ws")
        let profile = base.allowingProductiveWorkspace(resolution)
        #expect(profile.source.contains("(allow file-read* file-write*\n    (subpath \"/private/var/folders/x/T\"))"))
        #expect(profile.source.components(separatedBy: "/private/var/folders/x/T").count == 2)
        #expect(profile.source.contains("(allow file-write*\n    (subpath \"/private/var/folders/x/T\"))") == false)
        #expect(profile.source.contains("(allow file-read-metadata\n    (subpath \"/private/var/folders/x/T\"))") == false)
    }

    /// Scope: the fallback grant adds no coverage for the shared `/tmp`
    /// root, its canonical spelling, or the confstr parent dir — the
    /// grant is the resolved dir only. Profile-text complement of the
    /// `siblingTmpOutsideWorkspaceStaysContentDenied` live control.
    @Test func fallbackGrantAddsNoSiblingOrRootCoverage() {
        var resolution = ProductiveWorkspaceResolution()
        resolution.systemTemporaryDirectory = "/private/var/folders/x/T"
        let base = SeatbeltProfile(source: "(version 1)\n(deny default)\n", workspacePath: "/tmp/ws")
        let profile = base.allowingProductiveWorkspace(resolution)
        #expect(profile.source.contains("/tmp") == false)
        #expect(profile.source.contains("/private/tmp") == false)
        #expect(profile.source.contains("/private/var/folders/x\"") == false)
    }

    /// Injection safety: a hostile tmp string cannot break out of the
    /// quoted subpath — quotes and backslashes are escaped, so no
    /// smuggled rule survives in the compiled text. The resolver never
    /// produces such strings (canonical real paths only); the builder
    /// takes the struct field verbatim, so the escape is the boundary.
    @Test func fallbackGrantEscapesHostilePathCharacters() {
        var resolution = ProductiveWorkspaceResolution()
        resolution.systemTemporaryDirectory = "/private/var/folders/x/T\")) (allow file-read* (subpath \"/"
        let base = SeatbeltProfile(source: "(version 1)\n(deny default)\n", workspacePath: "/tmp/ws")
        let profile = base.allowingProductiveWorkspace(resolution)
        #expect(profile.source.contains("T\")) (allow file-read*") == false)
        #expect(profile.source.contains("T\\\")) (allow file-read*") == true)
    }

    /// The resolver stays confstr-authoritative: none of the host temp
    /// vars redirect the grant. Extends the TMPDIR pin in
    /// `productiveResolutionCarriesSystemTemporaryDirectory` to the full
    /// SwiftBuild-dropped set (TMPDIR/TEMP/TMP).
    @Test func resolverIgnoresAllHostTempVars() throws {
        let resolution = resolveProductiveWorkspace(
            workspacePath: "/tmp/ws",
            hostEnvironment: [
                "HOME": "/Users/test",
                "PATH": "/usr/bin:/bin",
                "TMPDIR": "/elsewhere-tmpdir",
                "TEMP": "/elsewhere-temp",
                "TMP": "/elsewhere-tmp",
            ]
        )
        let systemTmp = try #require(resolution.systemTemporaryDirectory)
        #expect(systemTmp.contains("/elsewhere-tmpdir") == false)
        #expect(systemTmp.contains("/elsewhere-temp") == false)
        #expect(systemTmp.contains("/elsewhere-tmp") == false)
        #expect(posixRealpath(systemTmp) == systemTmp)
    }
}
#endif
