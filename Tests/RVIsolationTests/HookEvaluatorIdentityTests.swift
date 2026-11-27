#if os(macOS)
import Foundation
import Security
import Synchronization
import Testing
@testable import RVIsolation

/// The hook-local evaluator's identity under a peer-trust manifest, derived
/// exactly as the C hook derives it (`has_evaluator_identity`,
/// daemon_trust.c): the release-signed `dev.rv.rv-hook-local` from the team
/// the manifest pins rvd to. A development manifest has no team and gets
/// no evaluator.
@Suite struct HookEvaluatorIdentityTests {
    private static let team = "ABCDE12345"

    private static func production() throws -> ProtectedPeerTrustConfiguration {
        let requirement = #"anchor apple generic and identifier \"dev.rv.rvd\" and certificate leaf[subject.OU] = \"\#(team)\""#
        return try ProtectedPeerTrustConfiguration.parse(Data(
            #"[{"role":"service","requirement":"\#(requirement)","requiredIdentifier":"dev.rv.rvd","requiredTeamIdentifier":"\#(team)"}]"#.utf8))
    }

    private static func evaluator(
        identifier: String = ProtectedPeerTrustConfiguration.hookEvaluatorIdentifier,
        team: String? = team, adHoc: Bool = false, hardened: Bool = true, injections: Set<String> = []
    ) -> PeerCodeIdentity {
        PeerCodeIdentity(
            identifier: identifier, teamIdentifier: team, cdHash: Data(repeating: 0xAB, count: 20),
            executablePath: "/opt/rv/bin/rv-hook-local", isAdHoc: adHoc, hardenedRuntime: hardened,
            injectionExceptions: injections)
    }

    private static func text(_ requirement: SecRequirement) -> String? {
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess else { return nil }
        return text as String?
    }

    @Test func releaseSignedEvaluatorFromTheServiceTeamIsAccepted() throws {
        let checked = Mutex<[String]>([])
        let accepted = try Self.production().isHookEvaluator(identity: Self.evaluator()) { requirement in
            checked.withLock { $0.append(Self.text(requirement) ?? "?") }
            return true
        }
        #expect(accepted)
        let expressions = checked.withLock { $0 }
        #expect(expressions.count == 1)
        #expect(expressions.first?.contains(#"identifier "dev.rv.rv-hook-local""#) == true)
        #expect(expressions.first?.contains("anchor apple generic") == true)
        #expect(expressions.first?.contains(Self.team) == true)
    }

    @Test(arguments: [
        HookEvaluatorIdentityTests.evaluator(identifier: "dev.rv.rvd"),
        HookEvaluatorIdentityTests.evaluator(identifier: "dev.rv.rv-hook-local.evil"),
        HookEvaluatorIdentityTests.evaluator(team: "ZZZZZ99999"),
        HookEvaluatorIdentityTests.evaluator(team: nil),
        HookEvaluatorIdentityTests.evaluator(adHoc: true),
        HookEvaluatorIdentityTests.evaluator(hardened: false),
        HookEvaluatorIdentityTests.evaluator(injections: ["com.apple.security.cs.allow-dyld-environment-variables"]),
    ])
    func anyOtherIdentityIsRejected(_ identity: PeerCodeIdentity) throws {
        #expect(!(try Self.production().isHookEvaluator(identity: identity) { _ in true }))
    }

    @Test func codeThatFailsTheSignatureRequirementIsRejected() throws {
        #expect(!(try Self.production().isHookEvaluator(identity: Self.evaluator()) { _ in false }))
    }

    @Test func noServiceEntryMeansNoEvaluator() throws {
        let requirement = #"anchor apple generic and identifier \"dev.rv.rv-judge\" and certificate leaf[subject.OU] = \"\#(Self.team)\""#
        let judgeOnly = try ProtectedPeerTrustConfiguration.parse(Data(
            #"[{"role":"judge","requirement":"\#(requirement)","requiredIdentifier":"dev.rv.rv-judge","requiredTeamIdentifier":"\#(Self.team)"}]"#.utf8))
        #expect(!judgeOnly.isHookEvaluator(identity: Self.evaluator()) { _ in true })
        #expect(!ProtectedPeerTrustConfiguration.denyAll.isHookEvaluator(identity: Self.evaluator()) { _ in true })
    }

    @Test func developmentServiceEntryMeansNoEvaluator() {
        let development = ProtectedPeerTrustConfiguration(entries: [
            .init(role: .service, requirement: "cdhash H\"\(String(repeating: "ab", count: 20))\"",
                  requiredIdentifier: nil, requiredTeamIdentifier: Self.team,
                  developmentCDHash: String(repeating: "ab", count: 20),
                  developmentExecutablePath: "/opt/rv/bin/rvd"),
        ])
        #expect(!development.isHookEvaluator(identity: Self.evaluator()) { _ in true })
    }
}
#endif
