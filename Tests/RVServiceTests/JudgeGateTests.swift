import Foundation
import Testing
@testable import RVService
import RVDomain

@Suite("Judge gate")
struct JudgeGateTests {
    @Test("threshold profiles match laya-guard source profiles")
    func thresholds() {
        #expect(JudgeRuntime.thresholds(provenance: .unknown) == (0.8, 0.45))
        #expect(JudgeRuntime.thresholds(provenance: .userTyped) == (0.8, 0.45))
        #expect(JudgeRuntime.thresholds(provenance: .toolOutput) == (0.6, 0.30))
        #expect(JudgeRuntime.thresholds(provenance: .web) == (0.6, 0.30))
        #expect(JudgeRuntime.thresholds(provenance: .email) == (0.6, 0.30))
    }

    @Test("runner script names parsed from plain commands only")
    func scriptNames() {
        #expect(PackageScriptGate.scriptNames(in: "npm test") == ["test"])
        #expect(PackageScriptGate.scriptNames(in: "pnpm run build") == ["build"])
        #expect(PackageScriptGate.scriptNames(in: "bun lint") == ["lint"])
        #expect(PackageScriptGate.scriptNames(in: "npm install left-pad") == nil)
        #expect(PackageScriptGate.scriptNames(in: "ls -la") == nil)
    }

    @Test("poisoned package.json script is denied through the packs")
    func poisonedScript() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-judge-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"{"scripts":{"test":"rm -rf ~/Documents"}}"#
            .write(to: dir.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        let session = EvaluateSession()
        let hit = PackageScriptGate.check(
            command: ShellCommand(rawValue: "npm test"),
            cwd: WorkingDirectory(rawValue: dir.path),
            session: session,
            enabledPacks: dayOnePackIDs
        )
        #expect(hit != nil)
        if let hit {
            #expect(hit.decision != .allow)
        }
    }

    @Test("clean package.json script passes")
    func cleanScript() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-judge-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"{"scripts":{"test":"node --test"}}"#
            .write(to: dir.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        let session = EvaluateSession()
        let hit = PackageScriptGate.check(
            command: ShellCommand(rawValue: "npm test"),
            cwd: WorkingDirectory(rawValue: dir.path),
            session: session,
            enabledPacks: dayOnePackIDs
        )
        #expect(hit == nil)
    }
}
