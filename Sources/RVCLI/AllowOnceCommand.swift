import ArgumentParser
import Foundation
import RVDomain
import RVPolicy
import RVService

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

    static func home(
        from environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> HomeDirectory? {
        HomeDirectory(validating: environment["HOME"] ?? "")
    }

    static func requireHome(
        from environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> HomeDirectory {
        guard let home = home(from: environment) else {
            FileHandle.standardError.write(Data("rv allow-once: HOME is not set\n".utf8))
            throw ExitCode(1)
        }
        return home
    }

    static func store(home: HomeDirectory) -> AllowOnceStore {
        AllowOnceStore.live(home: home)
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
        command: ShellCommand,
        cwd: WorkingDirectory,
        tty: TTYCapability,
        robot: Bool,
        store: AllowOnceStore,
        now: Date
    ) async throws -> String {
        let matchingView = EvaluationWorld.matchingView(of: command)
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
        abstract: "Redeem the six-character code from a hook deny.",
        discussion: """
            Redeem the six-character code printed on a hook deny. mint is optional pre-arm.
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
                store: AllowOnceCLI.store(home: try AllowOnceCLI.requireHome()),
                now: Date()
            )
            FileHandle.standardOutput.write(
                Data("granted \(row.commandRedacted) (cwd \(row.cwd.rawValue))\n".utf8)
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
        } catch AllowOnceError.lockFailed, AllowOnceError.encodeFailed {
            FileHandle.standardError.write(Data("rv allow-once: store unavailable\n".utf8))
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
            guard let cwd = WorkingDirectory(validating: FileManager.default.currentDirectoryPath) else {
                FileHandle.standardError.write(Data("rv allow-once mint: missing working directory\n".utf8))
                throw ExitCode(2)
            }
            let code = try await AllowOnceCLI.mint(
                command: ShellCommand(rawValue: raw),
                cwd: cwd,
                tty: live.tty,
                robot: live.robot,
                store: AllowOnceCLI.store(home: try AllowOnceCLI.requireHome()),
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
        } catch AllowOnceError.emptyCommand {
            FileHandle.standardError.write(Data("rv allow-once mint: missing command\n".utf8))
            throw ExitCode(2)
        } catch AllowOnceError.lockFailed, AllowOnceError.encodeFailed, AllowOnceError.collision {
            FileHandle.standardError.write(Data("rv allow-once mint: store unavailable\n".utf8))
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
        let rows = await AllowOnceCLI.store(home: try AllowOnceCLI.requireHome()).list(now: Date())
        if format.json || format.robot {
            let document = RobotDocument.allowOnceList(allowOnceRobotRows(from: rows))
            FileHandle.standardOutput.write(Data((document.render() + "\n").utf8))
            return
        }
        if rows.isEmpty {
            FileHandle.standardOutput.write(Data("no allow-once rows\n".utf8))
            return
        }
        for row in rows {
            FileHandle.standardOutput.write(
                Data("\(row.kind.rawValue) \(row.commandRedacted) cwd=\(row.cwd.rawValue)\n".utf8)
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
            try await AllowOnceCLI.store(home: try AllowOnceCLI.requireHome()).clear(tty: live.tty, now: Date())
            FileHandle.standardOutput.write(Data("cleared allow-once rows\n".utf8))
        } catch AllowOnceError.ttyRequired {
            FileHandle.standardError.write(
                Data("rv allow-once clear: requires an interactive TTY\n".utf8)
            )
            throw ExitCode(2)
        } catch AllowOnceError.lockFailed, AllowOnceError.encodeFailed {
            FileHandle.standardError.write(Data("rv allow-once clear: store unavailable\n".utf8))
            throw ExitCode(2)
        }
    }
}
