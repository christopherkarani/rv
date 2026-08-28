import ArgumentParser
import Foundation
import RVDomain
import RVPolicy
import RVService

enum AllowlistCLI {
    static func interactiveTTY(
        json: Bool,
        robot: Bool,
        plain: Bool,
        noColor: Bool
    ) -> TTYCapability {
        let probe = ThemeProbeFactory.live(
            jsonFlag: json,
            robotFlag: robot,
            plainFlag: plain,
            noColorFlag: noColor
        )
        return TTYCapability(
            stdinIsTTY: probe.terminal.stdinIsTTY,
            stdoutIsTTY: probe.terminal.stdoutIsTTY,
            ci: probe.forbid.ci
        )
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
            FileHandle.standardError.write(Data("rv allowlist: HOME is not set\n".utf8))
            throw ExitCode(1)
        }
        return home
    }

    static func store(home: HomeDirectory) -> AllowlistStore {
        AllowlistStore(baseDirectory: RVPolicyPaths.configDirectory(home: home))
    }
}

struct AllowlistCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "allowlist",
        abstract: "Manage permanent user-layer allowlist exceptions.",
        subcommands: [
            AllowlistAdd.self,
            AllowlistAddCommand.self,
            AllowlistRemove.self,
            AllowlistList.self,
            AllowlistValidate.self,
        ]
    )
}

struct AllowlistLayerFlags: ParsableArguments {
    @Flag(name: .customLong("user"), help: "User layer (default; only writable layer).")
    var user = false

    @Flag(name: .customLong("project"), help: "Project layer (not in v1).")
    var project = false

    @Flag(name: .customLong("system"), help: "System layer (not in v1).")
    var system = false

    func refuseUnsupported() throws {
        if project || system {
            FileHandle.standardError.write(
                Data("rv allowlist: --project/--system not in v1\n".utf8)
            )
            throw ExitCode(2)
        }
    }
}

struct AllowlistAdd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add a rule-id exception."
    )

    @Argument(help: "Rule id (colon or slash form).")
    var rule: String

    @Option(name: [.customShort("r"), .customLong("reason")], help: "Required reason.")
    var reason: String

    @OptionGroup
    var layer: AllowlistLayerFlags

    @OptionGroup
    var format: FormatFlags

    func run() async throws {
        try layer.refuseUnsupported()
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            FileHandle.standardError.write(Data("rv allowlist add: reason required\n".utf8))
            throw ExitCode(2)
        }
        guard let ruleID = parseAllowlistRuleID(rule) else {
            FileHandle.standardError.write(Data("rv allowlist add: invalid rule id\n".utf8))
            throw ExitCode(2)
        }
        let tty = AllowlistCLI.interactiveTTY(
            json: format.json,
            robot: format.robot,
            plain: format.plain,
            noColor: format.noColor
        )
        let entry = AllowlistEntry(
            selector: .rule(ruleID),
            reason: trimmed,
            addedAt: Date()
        )
        do {
            try AllowlistCLI.store(home: try AllowlistCLI.requireHome()).add(entry, tty: tty)
            FileHandle.standardOutput.write(
                Data("added \(ruleID.rawValue)\n".utf8)
            )
        } catch AllowOnceError.ttyRequired {
            FileHandle.standardError.write(
                Data("rv allowlist add: requires an interactive TTY\n".utf8)
            )
            throw ExitCode(2)
        } catch AllowlistStoreError.lockFailed {
            FileHandle.standardError.write(Data("rv allowlist add: store unavailable\n".utf8))
            throw ExitCode(2)
        } catch is AllowlistParseError {
            FileHandle.standardError.write(Data("rv allowlist add: invalid allowlist.toml\n".utf8))
            throw ExitCode(2)
        }
    }
}

struct AllowlistAddCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add-command",
        abstract: "Add an exact-command exception."
    )

    @Argument(help: "Exact command text.")
    var command: String

    @Option(name: [.customShort("r"), .customLong("reason")], help: "Required reason.")
    var reason: String

    @OptionGroup
    var layer: AllowlistLayerFlags

    @OptionGroup
    var format: FormatFlags

    func run() async throws {
        try layer.refuseUnsupported()
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            FileHandle.standardError.write(Data("rv allowlist add-command: reason required\n".utf8))
            throw ExitCode(2)
        }
        let tty = AllowlistCLI.interactiveTTY(
            json: format.json,
            robot: format.robot,
            plain: format.plain,
            noColor: format.noColor
        )
        let matchingView = EvaluationWorld.matchingView(of: ShellCommand(rawValue: command))
        let entry = AllowlistEntry(
            selector: .exactCommand(matchingView),
            reason: trimmed,
            addedAt: Date()
        )
        do {
            try AllowlistCLI.store(home: try AllowlistCLI.requireHome()).add(entry, tty: tty)
            FileHandle.standardOutput.write(
                Data("added exact command\n".utf8)
            )
        } catch AllowOnceError.ttyRequired {
            FileHandle.standardError.write(
                Data("rv allowlist add-command: requires an interactive TTY\n".utf8)
            )
            throw ExitCode(2)
        } catch AllowlistStoreError.lockFailed {
            FileHandle.standardError.write(
                Data("rv allowlist add-command: store unavailable\n".utf8)
            )
            throw ExitCode(2)
        } catch is AllowlistParseError {
            FileHandle.standardError.write(
                Data("rv allowlist add-command: invalid allowlist.toml\n".utf8)
            )
            throw ExitCode(2)
        }
    }
}

struct AllowlistRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove a user-layer exception."
    )

    @Argument(help: "Rule id or exact command.")
    var target: String

    @OptionGroup
    var layer: AllowlistLayerFlags

    @OptionGroup
    var format: FormatFlags

    func run() async throws {
        try layer.refuseUnsupported()
        let tty = AllowlistCLI.interactiveTTY(
            json: format.json,
            robot: format.robot,
            plain: format.plain,
            noColor: format.noColor
        )
        do {
            let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = EvaluationWorld.matchingView(of: ShellCommand(rawValue: trimmed)).rawValue
            let removed = try AllowlistCLI.store(home: try AllowlistCLI.requireHome()).remove(
                matching: trimmed,
                tty: tty,
                exactCommandAliases: normalized == trimmed ? [] : [normalized]
            )
            FileHandle.standardOutput.write(Data("removed \(removed)\n".utf8))
        } catch AllowOnceError.ttyRequired {
            FileHandle.standardError.write(
                Data("rv allowlist remove: requires an interactive TTY\n".utf8)
            )
            throw ExitCode(2)
        } catch AllowlistStoreError.lockFailed {
            FileHandle.standardError.write(Data("rv allowlist remove: store unavailable\n".utf8))
            throw ExitCode(2)
        } catch is AllowlistParseError {
            FileHandle.standardError.write(
                Data("rv allowlist remove: invalid allowlist.toml\n".utf8)
            )
            throw ExitCode(2)
        }
    }
}

struct AllowlistList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List user-layer allowlist rows."
    )

    @OptionGroup
    var format: FormatFlags

    func run() async throws {
        let now = Date()
        switch AllowlistCLI.store(home: try AllowlistCLI.requireHome()).loadForValidate(workspacePath: nil) {
        case .missing, .symlinkIntoWorkspace:
            if format.json || format.robot {
                let document = RobotDocument.allowlistList([])
                FileHandle.standardOutput.write(Data((document.render() + "\n").utf8))
            } else {
                FileHandle.standardOutput.write(Data("no allowlist rows\n".utf8))
            }
        case .invalid:
            FileHandle.standardError.write(Data("rv allowlist list: invalid allowlist.toml\n".utf8))
            throw ExitCode(2)
        case .ok(let entries):
            if format.json || format.robot {
                let document = RobotDocument.allowlistList(allowlistRobotRows(from: entries, now: now))
                FileHandle.standardOutput.write(Data((document.render() + "\n").utf8))
            } else {
                if entries.isEmpty {
                    FileHandle.standardOutput.write(Data("no allowlist rows\n".utf8))
                    return
                }
                for entry in entries {
                    let mark = entry.isActive(at: now) ? "" : " (expired)"
                    switch entry.selector {
                    case .rule(let ruleID):
                        FileHandle.standardOutput.write(
                            Data("rule \(ruleID.rawValue) — \(entry.reason)\(mark)\n".utf8)
                        )
                    case .exactCommand(let command):
                        FileHandle.standardOutput.write(
                            Data("exact \(command.rawValue) — \(entry.reason)\(mark)\n".utf8)
                        )
                    }
                }
            }
        }
    }
}

struct AllowlistValidate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Validate user allowlist.toml."
    )

    func run() async throws {
        switch AllowlistCLI.store(home: try AllowlistCLI.requireHome()).loadForValidate(workspacePath: nil) {
        case .missing:
            FileHandle.standardOutput.write(Data("allowlist: missing (ok)\n".utf8))
        case .symlinkIntoWorkspace:
            FileHandle.standardError.write(
                Data("rv allowlist validate: allowlist.toml resolves into workspace\n".utf8)
            )
            throw ExitCode(2)
        case .invalid(let error):
            FileHandle.standardError.write(
                Data("rv allowlist validate: \(String(describing: error))\n".utf8)
            )
            throw ExitCode(2)
        case .ok:
            FileHandle.standardOutput.write(Data("allowlist: ok\n".utf8))
        }
    }
}
