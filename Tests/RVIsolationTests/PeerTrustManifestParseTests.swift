#if os(macOS)
import Foundation
import Testing
@testable import RVIsolation

/// Manifest bytes → validated configuration, without the root-owned file
/// checks (`load(from:)` keeps those). Mirrors `Sources/rv-c/tests/daemon_trust_test.c`.
@Suite struct PeerTrustManifestParseTests {
    private static let team = "ABCDE12345"

    private static func entry(_ role: String, _ identifier: String) -> String {
        let requirement = #"anchor apple generic and identifier \"\#(identifier)\" and certificate leaf[subject.OU] = \"\#(team)\""#
        return #"{"role":"\#(role)","requirement":"\#(requirement)","requiredIdentifier":"\#(identifier)","requiredTeamIdentifier":"\#(team)"}"#
    }

    private static func parse(_ json: String) throws -> ProtectedPeerTrustConfiguration {
        try ProtectedPeerTrustConfiguration.parse(Data(json.utf8))
    }

    @Test func knownRolesParse() throws {
        let config = try Self.parse("[\(Self.entry("service", "dev.rv.rvd"))]")
        #expect(config.configuredRoles == [.service])
    }

    @Test func unknownRoleFromNewerBuildIsSkipped() throws {
        let config = try Self.parse(
            "[\(Self.entry("mcpCustodian", "dev.rv.mcp")),\(Self.entry("service", "dev.rv.rvd"))]"
        )
        #expect(config.configuredRoles == [.service])
    }

    @Test func unknownRoleIsNotValidatedLikeAKnownRole() throws {
        let config = try Self.parse(
            #"[\#(Self.entry("service", "dev.rv.rvd")),{"role":"mcpCustodian","requirement":"nonsense","socketPath":"/x"}]"#
        )
        #expect(config.configuredRoles == [.service])
    }

    @Test func duplicateUnknownRolesAreSkipped() throws {
        let config = try Self.parse(
            "[\(Self.entry("mcpCustodian", "a.b")),\(Self.entry("mcpCustodian", "c.d")),\(Self.entry("service", "dev.rv.rvd"))]"
        )
        #expect(config.configuredRoles == [.service])
    }

    @Test(arguments: [
        // Unknown-role entries must still be objects with a string role and string known fields.
        #"[{"role":"mcpCustodian","requirement":7}]"#,
        #"[{"role":7}]"#,
        #"[{"requirement":"x"}]"#,
        #"["mcpCustodian"]"#,
        // Known roles stay exactly as strict.
        #"[{"role":"service","requirement":"not a requirement (","requiredIdentifier":"dev.rv.rvd","requiredTeamIdentifier":"ABCDE12345"}]"#,
        #"[{"role":"service","requirement":"cdhash H\"0123456789abcdef0123456789abcdef01234567\"","developmentCDHash":"0123456789abcdef0123456789abcdef01234567","developmentExecutablePath":"/tmp/rvd"}]"#,
        #"[{"role":"service","requirement":"x","requiredIdentifier":"dev.rv.rvd"}]"#,
        "not json",
    ])
    func malformedManifestIsInvalid(_ json: String) {
        #expect(throws: PeerAuthenticationError.invalidTrustConfiguration) {
            try Self.parse(json)
        }
    }

    @Test func duplicateKnownRolesAreInvalid() {
        #expect(throws: PeerAuthenticationError.invalidTrustConfiguration) {
            try Self.parse("[\(Self.entry("service", "dev.rv.rvd")),\(Self.entry("service", "dev.rv.rvd"))]")
        }
    }
}
#endif
