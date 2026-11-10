import Foundation
import RVPolicy
import Testing
@testable import RVCLI

/// Byte-for-byte pins of the `rv managed` robot JSON and text so the status
/// model can change shape without changing what operators and fleet tooling see.
@Suite("rv managed status golden output")
struct ManagedStatusGoldenTests {
    #if os(macOS)
    private static let sandboxLine = "mcp: every local server must be sandboxed (remote servers are exempt)"
    #else
    private static let sandboxLine =
        "mcp: sandboxes need macOS; sandboxed servers are refused here (remote servers are exempt)"
    #endif

    private func bundle(signed: Bool, key: Int?, highest: Int?) throws -> ManagedPolicyState {
        let policy = try ManagedPolicy.decode(Data(#"{"version": 1, "organization": "Acme", "serial": 8}"#.utf8)).get()
        return .active(ManagedPolicyBundle(
            policy: policy, sha256: "abc", isSigned: signed, directory: "/managed", signingKey: key, highestSerial: highest))
    }

    @Test func noneGolden() throws {
        let status = ManagedRun.status(.none, directory: "/managed")
        #expect(try RobotJSON.encode(status, options: .pretty) == """
            {
              "directory" : "/managed",
              "state" : "none"
            }

            """)
        #expect(ManagedRun.statusText(status) == "no organization policy installed (/managed)\n")
    }

    @Test func invalidGolden() throws {
        let status = ManagedRun.status(.invalid("bad signature"), directory: "/managed")
        #expect(try RobotJSON.encode(status, options: .pretty) == """
            {
              "directory" : "/managed",
              "reason" : "bad signature",
              "state" : "invalid"
            }

            """)
        #expect(ManagedRun.statusText(status)
            == "organization policy INVALID: bad signature\n"
            + "MCP and secret staging are disabled and safety is forced to strict until it is fixed (/managed)\n")
    }

    @Test func activeSignedGolden() throws {
        let status = ManagedRun.status(try bundle(signed: true, key: 2, highest: 8), directory: "/managed")
        #expect(try RobotJSON.encode(status, options: .pretty) == """
            {
              "directory" : "/managed",
              "highestSerial" : 8,
              "organization" : "Acme",
              "restrictions" : [
                "\(Self.sandboxLine)"
              ],
              "serial" : 8,
              "sha256" : "abc",
              "signed" : true,
              "signingKey" : 2,
              "state" : "active"
            }

            """)
        #expect(ManagedRun.statusText(status) == """
            organization policy active: Acme serial 8
              signed by key 2 in org-key.pub sha256 abc
              anti-rollback: highest serial accepted here is 8
              \(Self.sandboxLine)

            """)
    }

    @Test func activeSignedWithoutKeyGolden() throws {
        let status = ManagedRun.status(try bundle(signed: true, key: nil, highest: nil), directory: "/managed")
        #expect(try RobotJSON.encode(status, options: .pretty) == """
            {
              "directory" : "/managed",
              "organization" : "Acme",
              "restrictions" : [
                "\(Self.sandboxLine)"
              ],
              "serial" : 8,
              "sha256" : "abc",
              "signed" : true,
              "state" : "active"
            }

            """)
        #expect(ManagedRun.statusText(status) == """
            organization policy active: Acme serial 8
              signed (org-key.pub pinned) sha256 abc
              \(Self.sandboxLine)

            """)
    }

    @Test func activeUnsignedGolden() throws {
        let status = ManagedRun.status(try bundle(signed: false, key: nil, highest: nil), directory: "/managed")
        #expect(try RobotJSON.encode(status, options: .pretty) == """
            {
              "directory" : "/managed",
              "organization" : "Acme",
              "restrictions" : [
                "\(Self.sandboxLine)"
              ],
              "serial" : 8,
              "sha256" : "abc",
              "signed" : false,
              "state" : "active"
            }

            """)
        #expect(ManagedRun.statusText(status) == """
            organization policy active: Acme serial 8
              unsigned sha256 abc
              \(Self.sandboxLine)

            """)
    }

    @Test func activeWithoutOrganizationOrSerialOmitsKeys() throws {
        let policy = try ManagedPolicy.decode(Data(#"{"version": 1}"#.utf8)).get()
        let status = ManagedRun.status(
            .active(ManagedPolicyBundle(policy: policy, sha256: "abc", isSigned: false, directory: "/managed")),
            directory: "/ignored")
        #expect(try RobotJSON.encode(status, options: .pretty) == """
            {
              "directory" : "/managed",
              "restrictions" : [
                "\(Self.sandboxLine)"
              ],
              "sha256" : "abc",
              "signed" : false,
              "state" : "active"
            }

            """)
        #expect(ManagedRun.statusText(status) == """
            organization policy active: unnamed
              unsigned sha256 abc
              \(Self.sandboxLine)

            """)
    }

    @Test func reportEmbedsTheSameFlatManagedObject() throws {
        let report = ReportRun.Report(
            schema: ReportRun.schema,
            generatedAt: "2026-01-01T00:00:00Z",
            rv: .init(version: "0.0.0", platform: "linux"),
            host: .init(name: "build", user: "me", uid: 1),
            managed: ManagedRun.status(.invalid("bad owner"), directory: "/managed"),
            config: [],
            mcp: .init(ok: true, error: nil, servers: 0, counts: [:], failing: [], plaintextCredentials: 0),
            secrets: .init(error: nil, items: []),
            audit: .init(since: "2026-01-01T00:00:00Z", total: 0, byKind: [:], lastEventAt: nil),
            sandbox: .init(platform: "linux", mcpSandbox: false, peerTrustInstalled: false))
        #expect(try RobotJSON.encode(report, options: .pretty).contains("""
              "managed" : {
                "directory" : "/managed",
                "reason" : "bad owner",
                "state" : "invalid"
              },
            """))
        #expect(report.compliant == false)
    }

    @Test func invalidPolicyIsNeverCompliant() throws {
        #expect(ManagedRun.status(.invalid("x"), directory: "/m").isInvalid)
        #expect(ManagedRun.status(.none, directory: "/m").isInvalid == false)
        #expect(ManagedRun.status(try bundle(signed: true, key: nil, highest: nil), directory: "/m").isInvalid == false)
    }
}
