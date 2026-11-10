import Foundation
import Testing
import RVDomain
import RVPolicy
@testable import RVService

/// The signed organization policy's `gate` section reaches every door: its
/// packs join the walk set every door evaluates under, and it can only raise
/// safety to strict.
@Suite("Managed gate")
struct ManagedGateTests {
    private func active(_ gate: ManagedPolicy.Gate) -> ManagedPolicyState {
        var policy = ManagedPolicy()
        policy.gate = gate
        return .active(ManagedPolicyBundle(policy: policy, sha256: "test", isSigned: true, directory: "/etc/rv/managed"))
    }

    @Test func requiredPacksJoinTheWalkSet() throws {
        let homeURL = try isolatedHomeDirectory()
        defer { try? FileManager.default.removeItem(at: homeURL) }
        let home = try #require(HomeDirectory(validating: homeURL.path))
        var gate = ManagedPolicy.Gate()
        gate.requirePacks = [PackID(rawValue: "database.sqlite")]
        let walked = ManagedGate.$override.withValue(active(gate)) {
            EvaluationWorld.walkedPackIDs(home: home)
        }
        #expect(walked.ids.contains(PackID(rawValue: "database.sqlite")))
        for id in dayOnePackIDs { #expect(walked.ids.contains(id)) }
        let noHome = ManagedGate.$override.withValue(active(gate)) {
            EvaluationWorld.walkedPackIDs(home: nil)
        }
        #expect(noHome.ids.contains(PackID(rawValue: "database.sqlite")))
    }

    @Test func userConfigCannotDropARequiredPack() throws {
        let homeURL = try isolatedHomeDirectory()
        defer { try? FileManager.default.removeItem(at: homeURL) }
        let home = try #require(HomeDirectory(validating: homeURL.path))
        _ = try PacksFacade.disable(home: home, ids: ["core.git"])
        var gate = ManagedPolicy.Gate()
        gate.requirePacks = [.coreGit]
        let walked = ManagedGate.$override.withValue(active(gate)) {
            EvaluationWorld.walkedPackIDs(home: home)
        }
        #expect(walked.ids.contains(.coreGit))
    }

    @Test func requiredPackOutsideDayOneIsCompiledAndEnforced() async throws {
        // The pack is required by the org but not enabled in user config:
        // the daemon must still compile and walk it.
        let homeURL = try isolatedHomeDirectory()
        defer { try? FileManager.default.removeItem(at: homeURL) }
        let home = try #require(HomeDirectory(validating: homeURL.path))
        var gate = ManagedPolicy.Gate()
        gate.requirePacks = [PackID(rawValue: "database.sqlite")]
        let decision = await ManagedGate.$override.withValue(active(gate)) {
            let runtime = ServiceRuntime(home: home, allowOnceDirectory: try! isolatedAllowOnceDirectory())
            return await runtime.evaluate(
                .makeDayOne(command: ShellCommand(rawValue: "DROP TABLE users"))
            ).result.decision
        }
        guard case .deny(let deny) = decision else {
            Issue.record("an org-required pack must be enforced by rvd, got \(decision)")
            return
        }
        #expect(deny.ruleID.rawValue == "database.sqlite:drop-table")
    }

    @Test func safetyOnlyRises() {
        var strict = ManagedPolicy.Gate()
        strict.requireStrictSafety = true
        ManagedGate.$override.withValue(active(strict)) {
            #expect(ManagedGate.safety(.normal, home: nil) == .strict)
            #expect(ManagedGate.safety(.strict, home: nil) == .strict)
        }
        ManagedGate.$override.withValue(active(ManagedPolicy.Gate())) {
            #expect(ManagedGate.safety(.normal, home: nil) == .normal)
        }
        ManagedGate.$override.withValue(ManagedPolicyState.none) {
            #expect(ManagedGate.safety(.normal, home: nil) == .normal)
        }
        // A present but untrusted bundle fails closed to strict.
        ManagedGate.$override.withValue(.invalid("bad signature")) {
            #expect(ManagedGate.safety(.normal, home: nil) == .strict)
            #expect(ManagedGate.requiredPacks(home: nil).isEmpty)
        }
    }

    @Test func gateRequirementsPinEnforceMode() {
        var packs = ManagedPolicy.Gate()
        packs.requirePacks = [PackID(rawValue: "database.sqlite")]
        var strict = ManagedPolicy.Gate()
        strict.requireStrictSafety = true
        for gate in [packs, strict] {
            ManagedGate.$override.withValue(active(gate)) {
                #expect(ManagedGate.guardMode(.observe, home: nil) == .enforce)
            }
        }
        ManagedGate.$override.withValue(.invalid("bad signature")) {
            #expect(ManagedGate.guardMode(.observe, home: nil) == .enforce)
        }
        // No gate requirement: the owner's choice stands.
        ManagedGate.$override.withValue(active(ManagedPolicy.Gate())) {
            #expect(ManagedGate.guardMode(.observe, home: nil) == .observe)
        }
        ManagedGate.$override.withValue(ManagedPolicyState.none) {
            #expect(ManagedGate.guardMode(.observe, home: nil) == .observe)
        }
    }
}
