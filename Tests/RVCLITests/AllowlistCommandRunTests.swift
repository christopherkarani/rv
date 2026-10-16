import ArgumentParser
import Foundation
import Testing
import RVDomain
import RVPolicy
@testable import RVCLI

struct AllowlistCommandRunTests {
    @Test(.disabled("TRANSITIONAL-BOUNDARY: LocalControlBoundary denies local mutations until service mutation routes land; re-enable then")) func add_missingHome() async throws {
        try await withCLIProcess(environment: [:]) {
            var command = try AllowlistAdd.parse(["core.git:reset-hard", "--reason", "reviewed"])
            await #expect(throws: ExitCode(1)) {
                try await command.run()
            }
        }
    }

    @Test(.disabled("TRANSITIONAL-BOUNDARY: LocalControlBoundary denies local mutations until service mutation routes land; re-enable then")) func add_emptyReason() async throws {
        let home = try isolatedHome()
        try await withCLIProcess(home: home, stdinIsTTY: true, stdoutIsTTY: true) {
            var command = try AllowlistAdd.parse(["core.git:reset-hard", "--reason", "   "])
            await #expect(throws: ExitCode(2)) {
                try await command.run()
            }
        }
    }

    @Test(.disabled("TRANSITIONAL-BOUNDARY: LocalControlBoundary denies local mutations until service mutation routes land; re-enable then")) func add_invalidRule() async throws {
        let home = try isolatedHome()
        try await withCLIProcess(home: home, stdinIsTTY: true, stdoutIsTTY: true) {
            var command = try AllowlistAdd.parse(["not-a-rule", "--reason", "reviewed"])
            await #expect(throws: ExitCode(2)) {
                try await command.run()
            }
        }
    }

    @Test func add_projectLayerRefused() async throws {
        let home = try isolatedHome()
        try await withCLIProcess(home: home, stdinIsTTY: true, stdoutIsTTY: true) {
            var command = try AllowlistAdd.parse([
                "core.git:reset-hard", "--reason", "reviewed", "--project",
            ])
            await #expect(throws: ExitCode(2)) {
                try await command.run()
            }
        }
    }

    @Test func add_systemLayerRefused() async throws {
        let home = try isolatedHome()
        try await withCLIProcess(home: home) {
            var command = try AllowlistAdd.parse([
                "core.git:reset-hard", "--reason", "reviewed", "--system",
            ])
            await #expect(throws: ExitCode(2)) {
                try await command.run()
            }
        }
    }

    @Test(.disabled("TRANSITIONAL-BOUNDARY: LocalControlBoundary denies local mutations until service mutation routes land; re-enable then")) func add_requiresTTY() async throws {
        let home = try isolatedHome()
        try await withCLIProcess(home: home, stdinIsTTY: false, stdoutIsTTY: false) {
            var command = try AllowlistAdd.parse(["core.git:reset-hard", "--reason", "reviewed"])
            await #expect(throws: ExitCode(2)) {
                try await command.run()
            }
        }
    }

    @Test(.disabled("TRANSITIONAL-BOUNDARY: LocalControlBoundary denies local mutations until service mutation routes land; re-enable then")) func add_slashRuleSucceedsOnTTY() async throws {
        let home = try isolatedHome()
        try await withCLIProcess(home: home, stdinIsTTY: true, stdoutIsTTY: true) {
            var command = try AllowlistAdd.parse(["core.git/reset-hard", "--reason", "reviewed"])
            try await command.run()
        }
        guard case .ok(let entries) = AllowlistCLI.store(home: home).loadForValidate(workspacePath: nil)
        else {
            Issue.record("expected allowlist row")
            return
        }
        #expect(entries.count == 1)
    }

    @Test(.disabled("TRANSITIONAL-BOUNDARY: LocalControlBoundary denies local mutations until service mutation routes land; re-enable then")) func add_lockFailed() async throws {
        let home = try isolatedHome()
        let lock = allowlistLockURL(home: home)
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
        try await withCLIProcess(home: home, stdinIsTTY: true, stdoutIsTTY: true) {
            var command = try AllowlistAdd.parse(["core.git:reset-hard", "--reason", "reviewed"])
            await #expect(throws: ExitCode(2)) {
                try await command.run()
            }
        }
    }

    @Test(.disabled("TRANSITIONAL-BOUNDARY: LocalControlBoundary denies local mutations until service mutation routes land; re-enable then")) func add_invalidExistingTOML() async throws {
        let home = try isolatedHome()
        let file = RVPolicyPaths.allowlistFile(inConfigDir: RVPolicyPaths.configDirectory(home: home))
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "not toml".write(to: file, atomically: true, encoding: .utf8)
        try await withCLIProcess(home: home, stdinIsTTY: true, stdoutIsTTY: true) {
            var command = try AllowlistAdd.parse(["core.git:reset-hard", "--reason", "reviewed"])
            await #expect(throws: ExitCode(2)) {
                try await command.run()
            }
        }
    }

    @Test(.disabled("TRANSITIONAL-BOUNDARY: LocalControlBoundary denies local mutations until service mutation routes land; re-enable then")) func addCommand_emptyReasonAndTTYAndSuccess() async throws {
        let home = try isolatedHome()
        try await withCLIProcess(home: home, stdinIsTTY: true, stdoutIsTTY: true) {
            var missing = try AllowlistAddCommand.parse(["echo hi", "--reason", ""])
            await #expect(throws: ExitCode(2)) {
                try await missing.run()
            }
            var ok = try AllowlistAddCommand.parse(["echo hi", "--reason", "safe"])
            try await ok.run()
        }
        try await withCLIProcess(home: home, stdinIsTTY: false, stdoutIsTTY: true) {
            var tty = try AllowlistAddCommand.parse(["echo hi", "--reason", "safe"])
            await #expect(throws: ExitCode(2)) {
                try await tty.run()
            }
        }
    }

    @Test(.disabled("TRANSITIONAL-BOUNDARY: LocalControlBoundary denies local mutations until service mutation routes land; re-enable then")) func addCommand_lockAndParseErrors() async throws {
        let home = try isolatedHome()
        let lock = allowlistLockURL(home: home)
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
        try await withCLIProcess(home: home, stdinIsTTY: true, stdoutIsTTY: true) {
            var command = try AllowlistAddCommand.parse(["echo hi", "--reason", "safe"])
            await #expect(throws: ExitCode(2)) {
                try await command.run()
            }
        }
        try FileManager.default.removeItem(at: lock)
        let file = RVPolicyPaths.allowlistFile(inConfigDir: RVPolicyPaths.configDirectory(home: home))
        try "broken".write(to: file, atomically: true, encoding: .utf8)
        try await withCLIProcess(home: home, stdinIsTTY: true, stdoutIsTTY: true) {
            var command = try AllowlistAddCommand.parse(["echo hi", "--reason", "safe"])
            await #expect(throws: ExitCode(2)) {
                try await command.run()
            }
        }
    }

    @Test func addCommand_projectRefused() async throws {
        let home = try isolatedHome()
        try await withCLIProcess(home: home) {
            var command = try AllowlistAddCommand.parse(["echo hi", "--reason", "safe", "--project"])
            await #expect(throws: ExitCode(2)) {
                try await command.run()
            }
        }
    }

    @Test(.disabled("TRANSITIONAL-BOUNDARY: LocalControlBoundary denies local mutations until service mutation routes land; re-enable then")) func remove_ttyLockParseAndSuccess() async throws {
        let home = try isolatedHome()
        try seedAllowlist(home: home)
        try await withCLIProcess(home: home, stdinIsTTY: false, stdoutIsTTY: false) {
            var tty = try AllowlistRemove.parse(["core.git:reset-hard"])
            await #expect(throws: ExitCode(2)) {
                try await tty.run()
            }
        }
        try await withCLIProcess(home: home, stdinIsTTY: true, stdoutIsTTY: true) {
            var ok = try AllowlistRemove.parse(["core.git:reset-hard"])
            try await ok.run()
        }
        #expect(AllowlistCLI.store(home: home).loadForValidate(workspacePath: nil) == .ok([]))
    }

    @Test(.disabled("TRANSITIONAL-BOUNDARY: LocalControlBoundary denies local mutations until service mutation routes land; re-enable then")) func remove_normalizedExactAlias() async throws {
        let home = try isolatedHome()
        let store = AllowlistCLI.store(home: home)
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        try store.add(
            AllowlistEntry(
                selector: .exactCommand(MatchingView("rm -rf ./build")),
                reason: "build",
                addedAt: Date()
            ),
            tty: tty
        )
        try await withCLIProcess(home: home, stdinIsTTY: true, stdoutIsTTY: true) {
            var command = try AllowlistRemove.parse(["sudo rm -rf ./build"])
            try await command.run()
        }
        #expect(store.loadForValidate(workspacePath: nil) == .ok([]))
    }

    @Test(.disabled("TRANSITIONAL-BOUNDARY: LocalControlBoundary denies local mutations until service mutation routes land; re-enable then")) func remove_lockAndParseErrors() async throws {
        let home = try isolatedHome()
        let lock = allowlistLockURL(home: home)
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
        try await withCLIProcess(home: home, stdinIsTTY: true, stdoutIsTTY: true) {
            var command = try AllowlistRemove.parse(["core.git:reset-hard"])
            await #expect(throws: ExitCode(2)) {
                try await command.run()
            }
        }
        try FileManager.default.removeItem(at: lock)
        let file = RVPolicyPaths.allowlistFile(inConfigDir: RVPolicyPaths.configDirectory(home: home))
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "broken".write(to: file, atomically: true, encoding: .utf8)
        try await withCLIProcess(home: home, stdinIsTTY: true, stdoutIsTTY: true) {
            var command = try AllowlistRemove.parse(["core.git:reset-hard"])
            await #expect(throws: ExitCode(2)) {
                try await command.run()
            }
        }
    }

    @Test func list_missingPrettyAndRobot() async throws {
        let home = try isolatedHome()
        try await withCLIProcess(home: home) {
            var pretty = try AllowlistList.parse([])
            try await pretty.run()
            var robot = try AllowlistList.parse(["--robot"])
            try await robot.run()
            var json = try AllowlistList.parse(["--json"])
            try await json.run()
        }
    }

    @Test func list_invalidFile() async throws {
        let home = try isolatedHome()
        let file = RVPolicyPaths.allowlistFile(inConfigDir: RVPolicyPaths.configDirectory(home: home))
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "nope".write(to: file, atomically: true, encoding: .utf8)
        try await withCLIProcess(home: home) {
            var command = try AllowlistList.parse([])
            await #expect(throws: ExitCode(2)) {
                try await command.run()
            }
        }
    }

    @Test func list_rowsPrettyRobotAndExpired() async throws {
        let home = try isolatedHome()
        let store = AllowlistCLI.store(home: home)
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        let now = Date()
        try store.add(
            AllowlistEntry(
                selector: .rule(try #require(RuleID(rawValue: "core.git:reset-hard"))),
                reason: "reviewed",
                addedAt: now
            ),
            tty: tty
        )
        try store.add(
            AllowlistEntry(
                selector: .exactCommand(MatchingView("echo hi")),
                reason: "safe",
                addedAt: now,
                expiresAt: now.addingTimeInterval(-1)
            ),
            tty: tty
        )
        try await withCLIProcess(home: home) {
            var pretty = try AllowlistList.parse([])
            try await pretty.run()
            var robot = try AllowlistList.parse(["--json"])
            try await robot.run()
        }
    }

    @Test func list_emptyOkFile() async throws {
        let home = try isolatedHome()
        let file = RVPolicyPaths.allowlistFile(inConfigDir: RVPolicyPaths.configDirectory(home: home))
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "".write(to: file, atomically: true, encoding: .utf8)
        try await withCLIProcess(home: home) {
            var command = try AllowlistList.parse([])
            try await command.run()
        }
    }

    @Test func validate_missingOkInvalidAndSymlink() async throws {
        let home = try isolatedHome()
        try await withCLIProcess(home: home) {
            var missing = try AllowlistValidate.parse([])
            try await missing.run()
        }
        try seedAllowlist(home: home)
        try await withCLIProcess(home: home) {
            var ok = try AllowlistValidate.parse([])
            try await ok.run()
        }
        let file = RVPolicyPaths.allowlistFile(inConfigDir: RVPolicyPaths.configDirectory(home: home))
        try "broken".write(to: file, atomically: true, encoding: .utf8)
        try await withCLIProcess(home: home) {
            var invalid = try AllowlistValidate.parse([])
            await #expect(throws: ExitCode(2)) {
                try await invalid.run()
            }
        }
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-allowlist-ws-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let target = workspace.appendingPathComponent("allowlist.toml")
        try "[[allow]]\n".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: target.path)
        try await withCLIProcess(home: home, workspacePath: workspace.path) {
            var linked = try AllowlistValidate.parse([])
            await #expect(throws: ExitCode(2)) {
                try await linked.run()
            }
            var listed = try AllowlistList.parse(["--robot"])
            try await listed.run()
        }
    }

    @Test func listEscapesReasonAndExactCommand() async throws {
        let sentence = "ok: every MCP server is governed by rv, allowed direct, or disabled"
        let raw = "x\u{1B}[2J\u{1B}[H" + sentence + "\u{2028}" + sentence + "\u{2029}" + sentence + "\u{202E}" + sentence
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let entries = [
            AllowlistEntry(
                selector: .exactCommand(MatchingView(raw)),
                reason: raw,
                addedAt: now
            ),
            AllowlistEntry(
                selector: .rule(RuleID(pack: .coreGit, pattern: "reset-hard")),
                reason: raw,
                addedAt: now
            ),
        ]
        let json = try RobotDocument.allowlistList(allowlistRobotRows(from: entries, now: now)).render()
        #expect(json.unicodeScalars.contains { $0.value == 0x2028 } == false)
        #expect(json.unicodeScalars.contains { $0.value == 0x2029 } == false)
        #expect(json.unicodeScalars.contains { $0.value == 0x202E } == false)
        #expect(json.contains("\\u2028"))
        #expect(json.contains("\\u2029"))
        #expect(json.contains("\\u202e"))
        let parsed = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        #expect(parsed.contains { $0["exact_command"] as? String == raw && $0["reason"] as? String == raw })
        #expect(parsed.contains { $0["reason"] as? String == raw && $0["rule"] as? String == "core.git:reset-hard" })

        let home = try isolatedHome()
        let file = RVPolicyPaths.allowlistFile(inConfigDir: RVPolicyPaths.configDirectory(home: home))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let toml = """
        [[allow]]
        exact_command = "\(raw)"
        reason = "\(raw)"
        added_at = "2026-01-01T00:00:00Z"

        """
        try toml.write(to: file, atomically: true, encoding: .utf8)
        let text = try await captureStdout {
            try await withCLIProcess(home: home) {
                var command = try AllowlistList.parse([])
                try await command.run()
            }
        }
        #expect(text.unicodeScalars.contains { $0.value == 0x1B } == false)
        #expect(text.unicodeScalars.contains { $0.value == 0x2028 } == false)
        #expect(text.unicodeScalars.contains { $0.value == 0x2029 } == false)
        #expect(text.unicodeScalars.contains { $0.value == 0x202E } == false)
        #expect(text.contains("exact "))
        #expect(text.contains("\\u001b[2J"))
        #expect(text.contains("\\u2028"))
        #expect(text.contains("\\u2029"))
        #expect(text.contains("\\u202e"))
        let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\u{2028}" || $0 == "\u{2029}" }).map(String.init)
        #expect(lines.contains(sentence) == false)
    }

    @Test func list_missingHome() async throws {
        try await withCLIProcess(environment: [:]) {
            var command = try AllowlistList.parse([])
            await #expect(throws: ExitCode(1)) {
                try await command.run()
            }
        }
    }

    @Test(.disabled("TRANSITIONAL-BOUNDARY: LocalControlBoundary denies local mutations until service mutation routes land; re-enable then")) func addCommand_andValidate_missingHome() async throws {
        try await withCLIProcess(environment: [:]) {
            var add = try AllowlistAddCommand.parse(["echo hi", "--reason", "safe"])
            await #expect(throws: ExitCode(1)) {
                try await add.run()
            }
            var validate = try AllowlistValidate.parse([])
            await #expect(throws: ExitCode(1)) {
                try await validate.run()
            }
            var remove = try AllowlistRemove.parse(["core.git:reset-hard"])
            await #expect(throws: ExitCode(1)) {
                try await remove.run()
            }
        }
    }

    @Test(.disabled("TRANSITIONAL-BOUNDARY: LocalControlBoundary denies local mutations until service mutation routes land; re-enable then")) func add_userFlagAndRemoveUnsupportedLayer() async throws {
        let home = try isolatedHome()
        try await withCLIProcess(home: home, stdinIsTTY: true, stdoutIsTTY: true) {
            var add = try AllowlistAdd.parse([
                "core.git:reset-hard", "--reason", "reviewed", "--user",
            ])
            try await add.run()
            var remove = try AllowlistRemove.parse(["core.git:reset-hard", "--project"])
            await #expect(throws: ExitCode(2)) {
                try await remove.run()
            }
            var system = try AllowlistAddCommand.parse([
                "echo hi", "--reason", "safe", "--system",
            ])
            await #expect(throws: ExitCode(2)) {
                try await system.run()
            }
        }
    }
}
