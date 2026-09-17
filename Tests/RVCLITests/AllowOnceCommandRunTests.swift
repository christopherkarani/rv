import ArgumentParser
import Foundation
import Testing
import RVDomain
import RVPolicy
@testable import RVCLI

struct AllowOnceCommandRunTests {
    @Test func redeem_missingCodePrintsUsage() async throws {
        try await withCLIProcess(environment: [:]) {
            var command = try AllowOnceCommand.parse([])
            await #expect(throws: ExitCode(2)) {
                try await command.run()
            }
        }
    }

    @Test func redeem_missingHome() async throws {
        try await withCLIProcess(environment: [:], stdinIsTTY: true, stdoutIsTTY: true) {
            var command = try AllowOnceCommand.parse(["abcdef"])
            await #expect(throws: ExitCode(1)) {
                try await command.run()
            }
        }
    }

    @Test func redeem_requiresTTY() async throws {
        let home = try isolatedHome()
        try await withCLIProcess(home: home, stdinIsTTY: false, stdoutIsTTY: false) {
            var command = try AllowOnceCommand.parse(["abcdef"])
            await #expect(throws: ExitCode(2)) {
                try await command.run()
            }
        }
    }

    @Test func redeem_robotRefused() async throws {
        let home = try isolatedHome()
        try await withCLIProcess(home: home, stdinIsTTY: true, stdoutIsTTY: true) {
            var command = try AllowOnceCommand.parse(["--json", "abcdef"])
            await #expect(throws: ExitCode(2)) {
                try await command.run()
            }
            var robot = try AllowOnceCommand.parse(["--robot", "abcdef"])
            await #expect(throws: ExitCode(2)) {
                try await robot.run()
            }
        }
    }

    @Test func redeem_unknownCode() async throws {
        let home = try isolatedHome()
        try await withCLIProcess(home: home, stdinIsTTY: true, stdoutIsTTY: true) {
            var command = try AllowOnceCommand.parse(["ffffff"])
            await #expect(throws: ExitCode(2)) {
                try await command.run()
            }
        }
    }

    @Test func redeem_expiredCode() async throws {
        let home = try isolatedHome()
        let store = AllowOnceCLI.store(home: home)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        let code = try await store.mint(
            matchingView: "git reset --hard",
            cwd: wd("/tmp/a"),
            ruleID: nil,
            tty: tty,
            now: now
        )
        try await withCLIProcess(home: home, stdinIsTTY: true, stdoutIsTTY: true) {
            var command = try AllowOnceCommand.parse([code.rawValue])
            await #expect(throws: ExitCode(2)) {
                try await command.run()
            }
        }
    }

    @Test func redeem_happyPathThenAlreadySpent() async throws {
        let home = try isolatedHome()
        let store = AllowOnceCLI.store(home: home)
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        let code = try await store.mint(
            matchingView: "git reset --hard",
            cwd: wd("/tmp/a"),
            ruleID: nil,
            tty: tty,
            now: Date()
        )
        try await withCLIProcess(home: home, stdinIsTTY: true, stdoutIsTTY: true) {
            var first = try AllowOnceCommand.parse([code.rawValue])
            try await first.run()
            var spent = try AllowOnceCommand.parse([code.rawValue])
            await #expect(throws: ExitCode(2)) {
                try await spent.run()
            }
        }
    }

    @Test func redeem_whitespaceCodeIsNotRedeemable() async throws {
        let home = try isolatedHome()
        try await withCLIProcess(home: home, stdinIsTTY: true, stdoutIsTTY: true) {
            var command = try AllowOnceCommand.parse(["   "])
            await #expect(throws: ExitCode(2)) {
                try await command.run()
            }
        }
    }

    @Test func mintAndClear_missingHome() async throws {
        try await withCLIProcess(environment: [:], stdinIsTTY: true, stdoutIsTTY: true) {
            var mint = try AllowOnceMint.parse(["git", "status"])
            await #expect(throws: ExitCode(1)) {
                try await mint.run()
            }
            var clear = try AllowOnceClear.parse([])
            await #expect(throws: ExitCode(1)) {
                try await clear.run()
            }
        }
    }

    @Test func redeem_storeUnavailable() async throws {
        let home = try isolatedHome()
        let lock = allowOnceLockURL(home: home)
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
        try await withCLIProcess(home: home, stdinIsTTY: true, stdoutIsTTY: true) {
            var command = try AllowOnceCommand.parse(["abcdef"])
            await #expect(throws: ExitCode(2)) {
                try await command.run()
            }
        }
    }

    @Test func mint_missingCommand() async throws {
        let home = try isolatedHome()
        try await withCLIProcess(home: home, stdinIsTTY: true, stdoutIsTTY: true) {
            var command = try AllowOnceMint.parse([])
            await #expect(throws: ExitCode(2)) {
                try await command.run()
            }
        }
    }

    @Test func mint_requiresTTYAndRefusesRobot() async throws {
        let home = try isolatedHome()
        try await withCLIProcess(home: home, stdinIsTTY: false, stdoutIsTTY: false) {
            var tty = try AllowOnceMint.parse(["git", "status"])
            await #expect(throws: ExitCode(2)) {
                try await tty.run()
            }
        }
        try await withCLIProcess(home: home, stdinIsTTY: true, stdoutIsTTY: true) {
            var robot = try AllowOnceMint.parse(["--robot", "git", "status"])
            await #expect(throws: ExitCode(2)) {
                try await robot.run()
            }
        }
    }

    @Test func mint_succeedsOnTTY() async throws {
        let home = try isolatedHome()
        try await withCLIProcess(home: home, stdinIsTTY: true, stdoutIsTTY: true) {
            var command = try AllowOnceMint.parse(["git", "status"])
            try await command.run()
        }
    }

    @Test func mint_storeUnavailable() async throws {
        let home = try isolatedHome()
        let lock = allowOnceLockURL(home: home)
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
        try await withCLIProcess(home: home, stdinIsTTY: true, stdoutIsTTY: true) {
            var command = try AllowOnceMint.parse(["git", "status"])
            await #expect(throws: ExitCode(2)) {
                try await command.run()
            }
        }
    }

    @Test func list_emptyPrettyAndRobot() async throws {
        let home = try isolatedHome()
        try await withCLIProcess(home: home) {
            var pretty = try AllowOnceList.parse([])
            try await pretty.run()
            var robot = try AllowOnceList.parse(["--json"])
            try await robot.run()
        }
    }

    @Test func list_rowsPrettyAndRobot() async throws {
        let home = try isolatedHome()
        let store = AllowOnceCLI.store(home: home)
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        _ = try await store.mint(
            matchingView: "git reset --hard",
            cwd: wd("/tmp/a"),
            ruleID: nil,
            tty: tty,
            now: Date()
        )
        try await withCLIProcess(home: home) {
            var pretty = try AllowOnceList.parse([])
            try await pretty.run()
            var robot = try AllowOnceList.parse(["--robot"])
            try await robot.run()
        }
    }

    @Test func list_missingHome() async throws {
        try await withCLIProcess(environment: [:]) {
            var command = try AllowOnceList.parse([])
            await #expect(throws: ExitCode(1)) {
                try await command.run()
            }
        }
    }

    @Test func clear_requiresTTYThenSucceeds() async throws {
        let home = try isolatedHome()
        try await withCLIProcess(home: home, stdinIsTTY: false, stdoutIsTTY: false) {
            var tty = try AllowOnceClear.parse([])
            await #expect(throws: ExitCode(2)) {
                try await tty.run()
            }
        }
        try await withCLIProcess(home: home, stdinIsTTY: true, stdoutIsTTY: true) {
            var ok = try AllowOnceClear.parse([])
            try await ok.run()
        }
    }

    @Test func clear_storeUnavailable() async throws {
        let home = try isolatedHome()
        let lock = allowOnceLockURL(home: home)
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
        try await withCLIProcess(home: home, stdinIsTTY: true, stdoutIsTTY: true) {
            var command = try AllowOnceClear.parse([])
            await #expect(throws: ExitCode(2)) {
                try await command.run()
            }
        }
    }

    @Test func interactiveTTY_ciIsForbid() throws {
        let live = try withCLIProcess(environment: ["CI": "1"], stdinIsTTY: true, stdoutIsTTY: true) {
            AllowOnceCLI.interactiveTTY(json: false, robot: false, plain: false, noColor: false)
        }
        #expect(live.tty.ci)
        #expect(live.robot == false)
        let robot = try withCLIProcess(stdinIsTTY: true, stdoutIsTTY: true) {
            AllowOnceCLI.interactiveTTY(json: true, robot: false, plain: false, noColor: false)
        }
        #expect(robot.robot)
    }
}
