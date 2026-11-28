import ArgumentParser
import Foundation
import Testing
import RVDomain
import RVPacks
import RVPolicy
import RVService
@testable import RVCLI

/// G6: `rv protect <tool>` adds protection with no owner check and offers
/// the undo; `rv protect <tool> off` always needs the owner.
@Suite("rv protect")
struct ProtectCommandTests {
    @Test func protect_addsWithoutTheOwner_andOffersUndo() async throws {
        let home = try isolatedHome()
        let capture = CLIOutputCapture()
        try await withCLIProcess(home: home, output: capture) {
            try await Protect.parse(["redis"]).run()
        }
        #expect(capture.stdout == "  ✓ Redis is protected. 13 rules check its commands.\n  → Undo: rv protect redis off\n")
        #expect(capture.stderr.isEmpty)
        #expect(try PacksFacade.effectiveIDs(home: home).contains(PackID(rawValue: "database.redis")))
    }

    @Test func protect_again_saysAlreadyProtected() async throws {
        let home = try isolatedHome()
        try await withCLIProcess(home: home) { try await Protect.parse(["terraform"]).run() }
        let capture = CLIOutputCapture()
        try await withCLIProcess(home: home, output: capture) { try await Protect.parse(["Terraform"]).run() }
        #expect(capture.stdout == "  ✓ Terraform is already protected.\n")
    }

    @Test func protect_off_needsTheOwner_andChangesNothingWithout() async throws {
        let home = try isolatedHome()
        try await withCLIProcess(home: home) { try await Protect.parse(["redis"]).run() }
        let before = try Data(contentsOf: PacksConfigStore.configURL(home: home))
        let capture = CLIOutputCapture()
        try await withCLIProcess(home: home, output: capture) {
            let off = try Protect.parse(["redis", "off"])
            await #expect(throws: ExitCode(EX_NOPERM)) { try await off.run() }
        }
        #expect(capture.stderr.contains("needs owner authentication"))
        #expect(try Data(contentsOf: PacksConfigStore.configURL(home: home)) == before)
        #expect(try PacksFacade.effectiveIDs(home: home).contains(PackID(rawValue: "database.redis")))
    }

    @Test func protect_off_withTheOwner_turnsItOff() async throws {
        let home = try isolatedHome()
        try await withCLIProcess(home: home) { try await Protect.parse(["redis"]).run() }
        let capture = CLIOutputCapture()
        try await withCLIProcess(home: home, ownerAuthOutcome: .authenticated, output: capture) {
            try await Protect.parse(["redis", "off"]).run()
        }
        #expect(capture.stdout == "  ✓ Redis is no longer protected.\n  → Turn it back on: rv protect redis\n")
        #expect(try PacksFacade.effectiveIDs(home: home).contains(PackID(rawValue: "database.redis")) == false)
    }

    @Test func protect_off_whenOff_asksNobody() async throws {
        let home = try isolatedHome()
        let capture = CLIOutputCapture()
        try await withCLIProcess(home: home, output: capture) {
            try await Protect.parse(["redis", "off"]).run()
        }
        #expect(capture.stdout == "  Redis is not protected.\n")
    }

    @Test func typo_scriptGetsTheNearestName_andNothingChanges() async throws {
        let home = try isolatedHome()
        let capture = CLIOutputCapture()
        try await withCLIProcess(home: home, output: capture) {
            let command = try Protect.parse(["reddis"])
            await #expect(throws: ExitCode(1)) { try await command.run() }
        }
        #expect(capture.stderr == "rv: no tool is named reddis. Did you mean Redis?\n→ rv protect redis\n")
        #expect(PacksConfigStore.isAbsent(home: home))
    }

    @Test func typo_atATerminal_enterAccepts() async throws {
        let home = try isolatedHome()
        let capture = CLIOutputCapture()
        try await withCLIProcess(home: home, stdinIsTTY: true, stdoutIsTTY: true, stdinText: "\n", output: capture) {
            try await Protect.parse(["reddis"]).run()
        }
        #expect(capture.stdout == "  Redis? ⏎   ✓ Redis is protected. 13 rules check its commands.\n  → Undo: rv protect redis off\n")
    }

    @Test func typo_atATerminal_noDeclines() async throws {
        let home = try isolatedHome()
        try await withCLIProcess(home: home, stdinIsTTY: true, stdoutIsTTY: true, stdinText: "n\n") {
            let command = try Protect.parse(["reddis"])
            await #expect(throws: ExitCode(1)) { try await command.run() }
        }
        #expect(PacksConfigStore.isAbsent(home: home))
    }

    /// A typo on the way off is never auto-corrected, even at a terminal.
    @Test func typo_off_isNeverGuessed() async throws {
        let home = try isolatedHome()
        let capture = CLIOutputCapture()
        try await withCLIProcess(home: home, stdinIsTTY: true, stdoutIsTTY: true, stdinText: "\n", output: capture) {
            let command = try Protect.parse(["reddis", "off"])
            await #expect(throws: ExitCode(1)) { try await command.run() }
        }
        #expect(capture.stderr == "rv: no tool is named reddis. Did you mean Redis?\n→ rv protect redis off\n")
    }

    @Test func unknownAndMissingNames() async throws {
        let home = try isolatedHome()
        let capture = CLIOutputCapture()
        try await withCLIProcess(home: home, output: capture) {
            let unknown = try Protect.parse(["zzzzzzzz"])
            await #expect(throws: ExitCode(1)) { try await unknown.run() }
            let none = try Protect.parse([])
            await #expect(throws: ExitCode(1)) { try await none.run() }
            let two = try Protect.parse(["redis", "docker"])
            await #expect(throws: ExitCode(1)) { try await two.run() }
        }
        #expect(capture.stderr == """
        rv: no tool is named zzzzzzzz.
        → rv packs --all
        rv: name a tool to protect, such as redis or terraform.
        → rv protect TOOL
        rv: name one tool at a time.
        → rv protect redis

        """)
    }

    @Test func toolNames_mapToPacks() throws {
        let tools = try ProtectTools.bundled()
        let expected: [String: String] = [
            "redis": "database.redis", "terraform": "infrastructure.terraform", "docker": "containers.docker",
            "kubernetes": "kubernetes.kubectl", "kubectl": "kubernetes.kubectl", "aws": "cloud.aws",
            "postgres": "database.postgresql", "helm": "kubernetes.helm", "database.redis": "database.redis",
            "git": "core.git", "vault": "secrets.vault",
        ]
        for (word, id) in expected {
            guard case .found(let target) = tools.resolve(word) else {
                Issue.record("\(word) did not resolve")
                continue
            }
            #expect(target.packID.rawValue == id, "\(word)")
        }
        guard case .nearest(let near) = tools.resolve("terrafrom") else {
            Issue.record("terrafrom got no suggestion")
            return
        }
        #expect(near.packID.rawValue == "infrastructure.terraform")
        // Every alias names a real pack.
        let ids = Set(try PackRegistry.loadIndex().packIDs.map(\.rawValue))
        for (name, id) in PackToolNames.aliases {
            #expect(ids.contains(id), "\(name) → \(id)")
        }
    }

    /// `rv packs enable/on` share the gate: no owner check to add.
    @Test func packsEnableAndOn_needNoOwner_disableAndOffDo() async throws {
        let home = try isolatedHome()
        try await withCLIProcess(home: home) {
            try await Packs.Enable.parse(["database.redis"]).run()
            var on = try #require(try Packs.parseAsRoot(["on", "containers.docker"]) as? AsyncParsableCommand)
            try await on.run()
        }
        let on = Set(try PacksFacade.effectiveIDs(home: home).map(\.rawValue))
        #expect(on.isSuperset(of: ["database.redis", "containers.docker"]))
        try await withCLIProcess(home: home) {
            let disable = try Packs.Disable.parse(["database.redis"])
            await #expect(throws: ExitCode(EX_NOPERM)) { try await disable.run() }
            let off = try #require(try Packs.parseAsRoot(["off", "containers.docker"]) as? AsyncParsableCommand)
            await #expect(throws: ExitCode(EX_NOPERM)) {
                var command = off
                try await command.run()
            }
        }
        let still = Set(try PacksFacade.effectiveIDs(home: home).map(\.rawValue))
        #expect(still.isSuperset(of: ["database.redis", "containers.docker"]))
    }

    /// The no-owner enable path never turns a pack off.
    @Test func enableTightening_refusesAnythingThatWouldLoosen() throws {
        let home = try isolatedHome()
        let result = try PacksFacade.enableTightening(home: home, ids: ["database"])
        #expect(result.changed.isEmpty == false)
        let before = Set(try PacksFacade.effectiveIDs(home: home))
        _ = try PacksFacade.enableTightening(home: home, ids: ["database.redis"])
        #expect(Set(try PacksFacade.effectiveIDs(home: home)).isSuperset(of: before))
    }
}
