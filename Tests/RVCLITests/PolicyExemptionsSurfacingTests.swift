import Foundation
import Testing
import RVDomain
import RVPolicy
@testable import RVCLI

@Suite("PolicyExemptionsSurfacing")
struct PolicyExemptionsSurfacingTests {
    @Test func showPretty_surfacesEffectiveAndDropped() throws {
        try withTempExemptionsContext { home, workspace in
            try writeMachineExemptions(
                home: home,
                allowPaths: ["/tmp/machine.env"],
                blessPaths: [".env"],
                machineDocPaths: ["/tmp/machine-doc.env"]
            )
            try writeRepoPolicy(workspace: workspace, allowPaths: [".env", "dropped.env"])

            let snapshot = try PolicyShowRun.load(home: home, workspace: workspace)
            let exemptions = PolicyShowRun.loadExemptions(home: home, workspace: workspace)
            #expect(exemptions.effective == ["/tmp/machine.env", "/tmp/machine-doc.env", ".env"])
            #expect(exemptions.droppedRepoLiterals == ["dropped.env"])
            #expect(exemptions.blessPaths == [".env"])

            let text = PolicyShowRun.pretty(snapshot, exemptions: exemptions)
            let lines = text.split(separator: "\n").map(String.init)
            #expect(lines.contains("secret.allow_paths"))
            #expect(
                lines.contains("  effective: /tmp/machine.env, /tmp/machine-doc.env, .env")
            )
            #expect(lines.contains("  dropped: dropped.env"))
            #expect(lines.contains("  bless_paths: .env"))
        }
    }

    @Test func showPretty_emptyShowsNone() throws {
        try withTempExemptionsContext { home, workspace in
            let snapshot = try PolicyShowRun.load(home: home, workspace: workspace)
            let exemptions = PolicyShowRun.loadExemptions(home: home, workspace: workspace)
            #expect(exemptions.effective == [])
            #expect(exemptions.droppedRepoLiterals == [])
            #expect(exemptions.blessPaths == [])

            let text = PolicyShowRun.pretty(snapshot, exemptions: exemptions)
            let lines = text.split(separator: "\n").map(String.init)
            #expect(lines.contains("secret.allow_paths"))
            #expect(lines.contains("  effective: (none)"))
            #expect(lines.contains("  dropped: (none)"))
            #expect(lines.contains("  bless_paths: (none)"))
        }
    }

    @Test func showRobot_includesSecretAllowPaths() throws {
        try withTempExemptionsContext { home, workspace in
            try writeMachineExemptions(
                home: home,
                allowPaths: [],
                blessPaths: [".env"],
                machineDocPaths: []
            )
            try writeRepoPolicy(workspace: workspace, allowPaths: [".env", "dropped.env"])

            let json = try PolicyShowRun.robot(
                try PolicyShowRun.load(home: home, workspace: workspace),
                exemptions: PolicyShowRun.loadExemptions(home: home, workspace: workspace)
            )
            let decoded = try JSONDecoder().decode(
                PolicyShowRobotDocument.self,
                from: Data(json.utf8)
            )
            #expect(decoded.secretAllowPaths.effective == [".env"])
            #expect(decoded.secretAllowPaths.droppedRepoLiterals == ["dropped.env"])
            #expect(decoded.secretAllowPaths.blessPaths == [".env"])

            // Legacy shape still decodes: the new key is purely additive.
            let legacy = try JSONDecoder().decode(
                PolicyShowSnapshot.self,
                from: Data(json.utf8)
            )
            #expect(legacy.builtin == [])
            #expect(legacy.machine == [])
            #expect(legacy.repo == [])
        }
    }

    @Test func showRobot_legacyOverloadGainsEmptyView() throws {
        try withTempExemptionsContext { home, workspace in
            let json = try PolicyShowRun.robot(
                try PolicyShowRun.load(home: home, workspace: workspace)
            )
            let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
            let dictionary = try #require(object as? [String: Any])
            let view = try #require(dictionary["secretAllowPaths"] as? [String: Any])
            #expect(view["effective"] as? [Any] != nil)
            #expect((view["effective"] as? [Any])?.isEmpty == true)
            #expect((view["droppedRepoLiterals"] as? [Any])?.isEmpty == true)
            #expect((view["blessPaths"] as? [Any])?.isEmpty == true)
        }
    }

    @Test func validateMachine_notesDroppedLiterals() throws {
        try withTempExemptionsContext { home, workspace in
            try writeRepoPolicy(workspace: workspace, allowPaths: [".env"])
            let notes = PolicyValidateRun.exemptionNotes(.machine(home), workspace: workspace)
            #expect(notes.count == 1)
            #expect(notes[0].contains(".env"))
            #expect(notes[0].contains("secret.bless_paths"))
        }
    }

    @Test func validateMachine_silentWhenNothingDropped() throws {
        try withTempExemptionsContext { home, workspace in
            try writeMachineExemptions(
                home: home,
                allowPaths: [],
                blessPaths: [".env"],
                machineDocPaths: []
            )
            try writeRepoPolicy(workspace: workspace, allowPaths: [".env"])
            #expect(
                PolicyValidateRun.exemptionNotes(.machine(home), workspace: workspace) == []
            )
        }
    }

    @Test func validateFile_notesBlessGateWhenLiteralsPresent() throws {
        try withTempExemptionsContext { home, workspace in
            let file = workspace.appendingPathComponent("share.toml")
            try Data(
                "schema_version = 1\nsecret.allow_paths = [\".env\"]\n".utf8
            ).write(to: file)
            try PolicyValidateRun.validate(.file(file, home))
            let notes = PolicyValidateRun.exemptionNotes(.file(file, home), workspace: workspace)
            #expect(notes.count == 1)
            #expect(notes[0].contains("secret.bless_paths"))
        }
    }

    @Test func validateFile_silentWithoutLiterals() throws {
        try withTempExemptionsContext { home, workspace in
            let file = workspace.appendingPathComponent("share.toml")
            try Data("schema_version = 1\n".utf8).write(to: file)
            try PolicyValidateRun.validate(.file(file, home))
            #expect(PolicyValidateRun.exemptionNotes(.file(file, home), workspace: workspace) == [])

            let missing = workspace.appendingPathComponent("missing.toml")
            try PolicyValidateRun.validate(.file(missing, home))
            #expect(PolicyValidateRun.exemptionNotes(.file(missing, home), workspace: workspace) == [])
        }
    }
}

private func withTempExemptionsContext(
    _ body: (HomeDirectory, URL) throws -> Void
) throws {
    let home = try isolatedHome()
    let homeURL = URL(fileURLWithPath: home.rawValue, isDirectory: true)
    let workspace = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-exempt-ws-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: homeURL)
        try? FileManager.default.removeItem(at: workspace)
    }
    try body(home, workspace)
}

private func writeMachineExemptions(
    home: HomeDirectory,
    allowPaths: [String],
    blessPaths: [String],
    machineDocPaths: [String]
) throws {
    let configDir = RVPolicyPaths.configDirectory(home: home)
    try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    let configFile = configDir.appendingPathComponent("config.json")
    if allowPaths.isEmpty == false {
        try SecretAllowPaths.saveMachineConfig(allowPaths, to: configFile)
    }
    if blessPaths.isEmpty == false {
        try SecretAllowPaths.saveBlessPaths(blessPaths, to: configFile)
    }
    if machineDocPaths.isEmpty == false {
        try TypedRuleStore(baseDirectory: configDir).saveMachine(
            PolicyDocument(allowPaths: machineDocPaths)
        )
    }
}

private func writeRepoPolicy(workspace: URL, allowPaths: [String]) throws {
    try FileManager.default.createDirectory(
        at: workspace.appendingPathComponent(".rv", isDirectory: true),
        withIntermediateDirectories: true
    )
    let toml = "schema_version = 1\nsecret.allow_paths = ["
        + allowPaths.map { "\"\($0)\"" }.joined(separator: ", ")
        + "]\n"
    try Data(toml.utf8).write(to: workspace.appendingPathComponent(".rv/policy.toml"))
}
