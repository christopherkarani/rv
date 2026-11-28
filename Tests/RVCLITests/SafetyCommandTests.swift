import ArgumentParser
import Foundation
import Testing
import RVDomain
import RVHistory
import RVPolicy
import RVTheme
@testable import RVCLI

struct SafetyCommandTests {
    @Test func registeredAndHelpOmitsPackIDs() {
        let names = RV.configuration.subcommands.map { $0.configuration.commandName }
        #expect(names.contains("safety"))
        let help = Safety.helpMessage()
        #expect(help.contains("normal"))
        #expect(help.contains("strict"))
        #expect(help.contains("core.git") == false)
        #expect(help.contains("core.filesystem") == false)
        #expect(HelpDispatch.text(.safety, palette: colorOffPalette).contains("core.") == false)
    }

    @Test func show_freshHome_isNormal() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        #expect(SafetyRun.show(home: home, workspace: nil) == "normal")
    }

    @Test func set_writesMachineConfig() async throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        try await withCLIProcess(home: home, stdinIsTTY: true, stdoutIsTTY: true, ownerAuthOutcome: .authenticated) {
            try await SafetyRun.set(.strict, home: home)
        }
        #expect(SafetyRun.show(home: home, workspace: nil) == "strict")
        try await withCLIProcess(home: home, stdinIsTTY: true, stdoutIsTTY: true, ownerAuthOutcome: .authenticated) {
            try await SafetyRun.set(.normal, home: home)
        }
        #expect(SafetyRun.show(home: home, workspace: nil) == "normal")
    }

    @Test func set_recordsTheOwnerCheckThatAuthorizedIt() async throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        try await withCLIProcess(home: home, stdinIsTTY: true, stdoutIsTTY: true, ownerAuthOutcome: .authenticated) {
            try await SafetyRun.set(.strict, home: home)
        }
        let events = AuditLedger(configDirectory: RVPolicyPaths.configDirectory(home: home))
            .events(AuditFilter(kinds: ["config.changed"]))
        #expect(events.map(\.subject) == ["safety.level"])
        #expect(events.first?.detail["authorized_by"] == OwnerConfirmation.testAuthorization)
    }

    /// Loosening safety while the audit log is unwritable is refused with
    /// the gate-change exit code, and the level stays strict.
    @Test func set_whenTheChangeCannotBeRecorded_exits74() async throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let config = RVPolicyPaths.configDirectory(home: home)
        let output = CLIOutputCapture()
        try await withCLIProcess(home: home, stdinIsTTY: true, stdoutIsTTY: true, ownerAuthOutcome: .authenticated, output: output) {
            try await SafetyRun.set(.strict, home: home)
            let log = AuditLog.fileURL(configDirectory: config)
            try FileManager.default.removeItem(at: log)
            try FileManager.default.createDirectory(at: log, withIntermediateDirectories: true)
            var command = try Safety.parse(["normal"])
            do {
                try await command.run()
                Issue.record("an unrecordable loosening was stored")
            } catch let exit as ExitCode {
                #expect(exit.rawValue == ConfigChangeRefusal.exitCode)
            }
        }
        #expect(output.stderr.hasPrefix("rv safety: the audit log could not record the safety.level change"))
        #expect(SafetyRun.show(home: home, workspace: nil) == "strict")
    }

    private func tempHome() throws -> HomeDirectory {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-safety-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try #require(HomeDirectory(validating: url.path))
    }
}
