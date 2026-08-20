import ArgumentParser
import Foundation
import RVDomain
import RVEngine
import RVPolicy

enum AllowOnceCLI {
    static func interactiveTTY(
        json: Bool,
        robot: Bool,
        plain: Bool,
        noColor: Bool
    ) -> (tty: TTYCapability, robot: Bool) {
        let probe = ThemeProbeFactory.live(
            jsonFlag: json,
            robotFlag: robot,
            plainFlag: plain,
            noColorFlag: noColor
        )
        let tty = TTYCapability(
            stdinIsTTY: probe.terminal.stdinIsTTY,
            stdoutIsTTY: probe.terminal.stdoutIsTTY,
            ci: probe.forbid.ci
        )
        return (tty, json || robot)
    }

    static func store() -> AllowOnceStore {
        AllowOnceStore.live()
    }

    static func redeem(
        code: String,
        tty: TTYCapability,
        robot: Bool,
        store: AllowOnceStore,
        now: Date
    ) async throws -> AllowOnceListRow {
        try await store.redeem(code: code, tty: tty, now: now, robot: robot)
    }

    static func mint(
        command: String,
        cwd: String,
        tty: TTYCapability,
        robot: Bool,
        store: AllowOnceStore,
        now: Date
    ) async throws -> String {
        let matchingView = Normalize.matchingView(of: command)
        return try await store.mint(
            matchingView: matchingView,
            cwd: cwd,
            ruleID: nil,
            tty: tty,
            now: now,
            robot: robot
        )
    }
}

struct AllowOnceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "allow-once",
        abstract: "Mint and redeem single-use unlock codes.",
        discussion: """
            Unlock a deny by running the command in Terminal, or redeem a code on a TTY.
            """,
        subcommands: [AllowOnceMint.self, AllowOnceList.self, AllowOnceClear.self]
    )

    @Argument(help: "Six-character allow-once code.")
    var code: String?

    @OptionGroup
    var format: FormatFlags

    func run() async throws {
        guard let code, code.isEmpty == false else {
            FileHandle.standardError.write(
                Data(
                    """
                    usage: rv allow-once mint -- <command>
                           rv allow-once <code>
                           rv allow-once list
                           rv allow-once clear

                    """.utf8
                )
            )
            throw ExitCode(2)
        }
        let live = AllowOnceCLI.interactiveTTY(
            json: format.json,
            robot: format.robot,
            plain: format.plain,
            noColor: format.noColor
        )
        do {
            let row = try await AllowOnceCLI.redeem(
                code: code,
                tty: live.tty,
                robot: live.robot,
                store: AllowOnceCLI.store(),
                now: Date()
            )
            FileHandle.standardOutput.write(
                Data("granted \(row.commandRedacted) (cwd \(row.cwd))\n".utf8)
            )
        } catch AllowOnceError.ttyRequired {
            FileHandle.standardError.write(
                Data("rv allow-once: requires an interactive TTY (stdin and stdout)\n".utf8)
            )
            throw ExitCode(2)
        } catch AllowOnceError.robotRefused {
            FileHandle.standardError.write(
                Data("rv allow-once: --json/--robot refused for redeem\n".utf8)
            )
            throw ExitCode(2)
        } catch AllowOnceError.unknownCode, AllowOnceError.expired, AllowOnceError.alreadySpent {
            FileHandle.standardError.write(Data("rv allow-once: code not redeemable\n".utf8))
            throw ExitCode(2)
        }
    }
}

struct AllowOnceMint: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mint",
        abstract: "Mint a single-use allow-once code for a command."
    )

    @OptionGroup
    var format: FormatFlags

    @Argument(parsing: .captureForPassthrough, help: "Command to unlock once.")
    var commandParts: [String] = []

    func run() async throws {
        let raw = commandParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.isEmpty == false else {
            FileHandle.standardError.write(Data("rv allow-once mint: missing command\n".utf8))
            throw ExitCode(2)
        }
        let live = AllowOnceCLI.interactiveTTY(
            json: format.json,
            robot: format.robot,
            plain: format.plain,
            noColor: format.noColor
        )
        do {
            let code = try await AllowOnceCLI.mint(
                command: raw,
                cwd: FileManager.default.currentDirectoryPath,
                tty: live.tty,
                robot: live.robot,
                store: AllowOnceCLI.store(),
                now: Date()
            )
            FileHandle.standardOutput.write(
                Data("allow-once code: \(code)\nrv allow-once \(code)\n".utf8)
            )
        } catch AllowOnceError.ttyRequired {
            FileHandle.standardError.write(
                Data("rv allow-once: requires an interactive TTY (stdin and stdout)\n".utf8)
            )
            throw ExitCode(2)
        } catch AllowOnceError.robotRefused {
            FileHandle.standardError.write(
                Data("rv allow-once mint: --json/--robot refused\n".utf8)
            )
            throw ExitCode(2)
        }
    }
}

struct AllowOnceList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List redacted allow-once rows."
    )

    @OptionGroup
    var format: FormatFlags

    func run() async throws {
        let rows = await AllowOnceCLI.store().list(now: Date())
        if format.json || format.robot {
            let payload: [[String: String]] = rows.map { row in
                [
                    "kind": row.kind.rawValue,
                    "code_hash": row.codeHash,
                    "command_redacted": row.commandRedacted,
                    "cwd": row.cwd,
                ]
            }
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            return
        }
        if rows.isEmpty {
            FileHandle.standardOutput.write(Data("no allow-once rows\n".utf8))
            return
        }
        for row in rows {
            FileHandle.standardOutput.write(
                Data("\(row.kind.rawValue) \(row.commandRedacted) cwd=\(row.cwd)\n".utf8)
            )
        }
    }
}

struct AllowOnceClear: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear",
        abstract: "Clear pending and granted allow-once rows."
    )

    @OptionGroup
    var format: FormatFlags

    func run() async throws {
        let live = AllowOnceCLI.interactiveTTY(
            json: format.json,
            robot: format.robot,
            plain: format.plain,
            noColor: format.noColor
        )
        do {
            try await AllowOnceCLI.store().clear(tty: live.tty, now: Date())
            FileHandle.standardOutput.write(Data("cleared allow-once rows\n".utf8))
        } catch AllowOnceError.ttyRequired {
            FileHandle.standardError.write(
                Data("rv allow-once clear: requires an interactive TTY\n".utf8)
            )
            throw ExitCode(2)
        }
    }
}
