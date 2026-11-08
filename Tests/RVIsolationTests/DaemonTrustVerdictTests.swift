#if os(macOS)
import Foundation
import Testing
@testable import RVIsolation

/// Static "would hooks trust this rvd?" verdicts, evaluated with the same
/// role rule the hook-consult client applies to the live daemon. Manifests
/// are parsed from bytes (the root-owned `load(from:)` checks cannot be met
/// by a test) and fixture binaries live in a temp dir; nothing here reads or
/// writes `/Library`.
@Suite struct DaemonTrustVerdictTests {
    private static let team = "5V273URY46"
    private static let identifier = "dev.rv.rvd"

    private static func productionManifest(role: String = "service") throws -> ProtectedPeerTrustConfiguration {
        let requirement = #"anchor apple generic and identifier \"\#(identifier)\" and certificate leaf[subject.OU] = \"\#(team)\""#
        let json = #"[{"role":"\#(role)","requirement":"\#(requirement)","requiredIdentifier":"\#(identifier)","requiredTeamIdentifier":"\#(team)"}]"#
        return try ProtectedPeerTrustConfiguration.parse(Data(json.utf8))
    }

    /// Copies `/usr/bin/true` into a temp dir and re-signs it.
    /// `signArguments` nil strips the signature instead.
    private static func fixture(_ signArguments: [String]?) throws -> (dir: URL, rvd: String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-trust-verdict-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rvd = dir.appendingPathComponent("rvd").path
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: rvd)
        let arguments = signArguments.map { ["-f", "-s", "-"] + $0 + [rvd] } ?? ["--remove-signature", rvd]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "codesign \(arguments) failed")
        return (dir, rvd)
    }

    @Test func manifestRejectsAdHocHardenedRvdWithActionableReason() throws {
        let (dir, rvd) = try Self.fixture(["-o", "runtime"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let verdict = ProtectedPeerTrustConfiguration.HookTrustSource
            .manifest(try Self.productionManifest())
            .evaluateDaemon(atPath: rvd)
        #expect(verdict.source == .manifest)
        #expect(verdict.satisfied == false)
        #expect(verdict.reason == "manifest requires Developer ID dev.rv.rvd (team 5V273URY46); installed rvd is ad-hoc signed")
    }

    @Test func manifestReasonNamesMissingHardenedRuntime() throws {
        let (dir, rvd) = try Self.fixture([])
        defer { try? FileManager.default.removeItem(at: dir) }
        let verdict = ProtectedPeerTrustConfiguration.HookTrustSource
            .manifest(try Self.productionManifest())
            .evaluateDaemon(atPath: rvd)
        #expect(verdict.satisfied == false)
        #expect(verdict.reason == "manifest requires Developer ID dev.rv.rvd (team 5V273URY46); installed rvd is ad-hoc signed, without hardened runtime")
    }

    @Test func manifestRejectsUnsignedRvd() throws {
        let (dir, rvd) = try Self.fixture(nil)
        defer { try? FileManager.default.removeItem(at: dir) }
        let verdict = ProtectedPeerTrustConfiguration.HookTrustSource
            .manifest(try Self.productionManifest())
            .evaluateDaemon(atPath: rvd)
        #expect(verdict.satisfied == false)
        #expect(verdict.reason == "manifest requires Developer ID dev.rv.rvd (team 5V273URY46); installed rvd has no valid code signature")
    }

    @Test func manifestWithoutServiceRoleRejectsEveryRvd() throws {
        let (dir, rvd) = try Self.fixture(["-o", "runtime"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let verdict = ProtectedPeerTrustConfiguration.HookTrustSource
            .manifest(try Self.productionManifest(role: "cli"))
            .evaluateDaemon(atPath: rvd)
        #expect(verdict.satisfied == false)
        #expect(verdict.reason == "manifest grants no service role, so hooks reject every rvd")
    }

    /// A development entry pins exact bytes at a root-owned path; a copy
    /// under a user-owned directory can never match it.
    @Test func manifestDevelopmentPinNamesBothHashesAndPaths() throws {
        let pinned = String(repeating: "ab", count: 20)
        let json = #"[{"role":"service","requirement":"cdhash H\"\#(pinned)\"","developmentCDHash":"\#(pinned)","developmentExecutablePath":"/usr/bin/true"}]"#
        let trust = try ProtectedPeerTrustConfiguration.parse(Data(json.utf8))
        let (dir, rvd) = try Self.fixture(["-o", "runtime"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let verdict = ProtectedPeerTrustConfiguration.HookTrustSource.manifest(trust).evaluateDaemon(atPath: rvd)
        #expect(verdict.satisfied == false)
        let reason = try #require(verdict.reason)
        #expect(reason.hasPrefix("manifest pins rvd cdhash \(pinned) at /usr/bin/true; installed rvd is cdhash "))
        let canonical = try #require(realpath(rvd, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        })
        #expect(reason.hasSuffix(" at \(canonical)"))
    }

    @Test func siblingPinTrustsAnyValidlySignedRvd() throws {
        let (dir, rvd) = try Self.fixture([])
        defer { try? FileManager.default.removeItem(at: dir) }
        let verdict = ProtectedPeerTrustConfiguration.HookTrustSource.siblingPin.evaluateDaemon(atPath: rvd)
        #expect(verdict == DaemonTrustVerdict(source: .siblingPin, satisfied: true, reason: nil))
    }

    @Test func siblingPinRejectsUnsignedRvd() throws {
        let (dir, rvd) = try Self.fixture(nil)
        defer { try? FileManager.default.removeItem(at: dir) }
        let verdict = ProtectedPeerTrustConfiguration.HookTrustSource.siblingPin.evaluateDaemon(atPath: rvd)
        #expect(verdict.source == .siblingPin)
        #expect(verdict.satisfied == false)
        #expect(verdict.reason == "installed rvd has no valid code signature, so hooks cannot pin it")
    }

    @Test func invalidManifestRejectsEveryRvd() throws {
        let (dir, rvd) = try Self.fixture(["-o", "runtime"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let verdict = ProtectedPeerTrustConfiguration.HookTrustSource.invalid.evaluateDaemon(atPath: rvd)
        #expect(verdict.source == .invalid)
        #expect(verdict.satisfied == false)
        #expect(verdict.reason == "trust manifest is present but rejected, so hooks reject every rvd")
    }

    @Test func injectedManifestPathSelectsTrustSource() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-trust-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appendingPathComponent("absent.json").path
        guard case .siblingPin = ProtectedPeerTrustConfiguration.hookTrustSource(manifestPath: missing) else {
            Issue.record("absent manifest must select the sibling pin")
            return
        }
        // User-owned bytes are never a valid manifest: tamper evidence.
        let userOwned = dir.appendingPathComponent("peer-trust.json")
        try Data("[]".utf8).write(to: userOwned)
        guard case .invalid = ProtectedPeerTrustConfiguration.hookTrustSource(manifestPath: userOwned.path) else {
            Issue.record("user-owned manifest must be invalid")
            return
        }
    }
}
#endif
