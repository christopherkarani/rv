import ArgumentParser
import Foundation
import RVDomain
import RVEngine
import RVPolicy
import RVService

enum AllowlistCLI {
    static func interactiveTTY(
        json: Bool,
        robot: Bool,
        plain: Bool,
        noColor: Bool
    ) -> TTYCapability {
        CommandContext.current(
            command: "allowlist",
            json: json,
            robot: robot,
            plain: plain,
            noColor: noColor
        ).tty
    }

    static func home(
        from environment: [String: String] = CLIProcess.environment()
    ) -> HomeDirectory? {
        HomeDirectory(validating: environment["HOME"] ?? "")
    }

    static func requireHome(
        from environment: [String: String] = CLIProcess.environment()
    ) throws -> HomeDirectory {
        guard let home = home(from: environment) else {
            try CommandContext.failHomeMissing(command: "allowlist")
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
            try CommandContext.fail("rv allowlist: --project/--system not in v1\n", exitCode: 2)
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
        try LocalControlBoundary.requireOwnerAuthorization()
        let ctx = CommandContext.current(command: "allowlist", format: format)
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            try ctx.fail("rv allowlist add: reason required\n", exitCode: 2)
        }
        guard let ruleID = parseAllowlistRuleID(rule) else {
            try ctx.fail("rv allowlist add: invalid rule id\n", exitCode: 2)
        }
        let entry = AllowlistEntry(
            selector: .rule(ruleID),
            reason: trimmed,
            addedAt: Date()
        )
        do {
            try AllowlistCLI.store(home: try ctx.requireHome()).add(entry, tty: ctx.tty)
            ctx.writeStdout("added \(ruleID.rawValue)\n")
        } catch AllowOnceError.ttyRequired {
            try ctx.fail("rv allowlist add: requires an interactive TTY\n", exitCode: 2)
        } catch AllowlistStoreError.lockFailed {
            try ctx.fail("rv allowlist add: store unavailable\n", exitCode: 2)
        } catch is AllowlistParseError {
            try ctx.fail("rv allowlist add: invalid allowlist.toml\n", exitCode: 2)
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
        try LocalControlBoundary.requireOwnerAuthorization()
        let ctx = CommandContext.current(command: "allowlist", format: format)
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            try ctx.fail("rv allowlist add-command: reason required\n", exitCode: 2)
        }
        let shell = ShellCommand(rawValue: command)
        let matchingView = EvaluationWorld.matchingView(of: shell)
        let entry = AllowlistEntry(
            selector: .exactCommand(matchingView),
            reason: trimmed,
            addedAt: Date(),
            maskedPayloadDigest: maskedPayloadContentDigest(Normalize.maskedSegments(of: shell)),
            invocationDigest: maskedPayloadContentDigest(Normalize.invocationPrefix(of: shell))
        )
        do {
            try AllowlistCLI.store(home: try ctx.requireHome()).add(entry, tty: ctx.tty)
            ctx.writeStdout("added exact command\n")
        } catch AllowOnceError.ttyRequired {
            try ctx.fail("rv allowlist add-command: requires an interactive TTY\n", exitCode: 2)
        } catch AllowlistStoreError.lockFailed {
            try ctx.fail("rv allowlist add-command: store unavailable\n", exitCode: 2)
        } catch is AllowlistParseError {
            try ctx.fail("rv allowlist add-command: invalid allowlist.toml\n", exitCode: 2)
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
        try LocalControlBoundary.requireOwnerAuthorization()
        let ctx = CommandContext.current(command: "allowlist", format: format)
        do {
            let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = EvaluationWorld.matchingView(of: ShellCommand(rawValue: trimmed)).rawValue
            let removed = try AllowlistCLI.store(home: try ctx.requireHome()).remove(
                matching: trimmed,
                tty: ctx.tty,
                exactCommandAliases: normalized == trimmed ? [] : [normalized]
            )
            ctx.writeStdout("removed \(removed)\n")
        } catch AllowOnceError.ttyRequired {
            try ctx.fail("rv allowlist remove: requires an interactive TTY\n", exitCode: 2)
        } catch AllowlistStoreError.lockFailed {
            try ctx.fail("rv allowlist remove: store unavailable\n", exitCode: 2)
        } catch is AllowlistParseError {
            try ctx.fail("rv allowlist remove: invalid allowlist.toml\n", exitCode: 2)
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
        let ctx = CommandContext.current(command: "allowlist", format: format)
        let now = Date()
        switch AllowlistCLI.store(home: try ctx.requireHome()).loadForValidate(
            workspacePath: CLIProcess.workspacePath()
        ) {
        case .missing, .symlinkIntoWorkspace:
            if ctx.explicitRobot {
                let document = RobotDocument.allowlistList([])
                ctx.writeStdout(try document.render() + "\n")
            } else {
                ctx.writeStdout("no allowlist rows\n")
            }
        case .invalid:
            try ctx.fail("rv allowlist list: invalid allowlist.toml\n", exitCode: 2)
        case .ok(let entries):
            if ctx.explicitRobot {
                let document = RobotDocument.allowlistList(allowlistRobotRows(from: entries, now: now))
                ctx.writeStdout(try document.render() + "\n")
            } else {
                if entries.isEmpty {
                    ctx.writeStdout("no allowlist rows\n")
                    return
                }
                for entry in entries {
                    let mark = entry.isActive(at: now) ? "" : " (expired)"
                    switch entry.selector {
                    case .rule(let ruleID):
                        ctx.writeStdout("rule \(ruleID.rawValue) — \(entry.reason)\(mark)\n")
                    case .exactCommand(let command):
                        ctx.writeStdout("exact \(command.rawValue) — \(entry.reason)\(mark)\n")
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
        switch AllowlistCLI.store(home: try CommandContext.requireHome(command: "allowlist")).loadForValidate(
            workspacePath: CLIProcess.workspacePath()
        ) {
        case .missing:
            CommandContext.writeStdout("allowlist: missing (ok)\n")
        case .symlinkIntoWorkspace:
            try CommandContext.fail(
                "rv allowlist validate: allowlist.toml resolves into workspace\n",
                exitCode: 2
            )
        case .invalid(let error):
            try CommandContext.fail(
                "rv allowlist validate: \(String(describing: error))\n",
                exitCode: 2
            )
        case .ok:
            CommandContext.writeStdout("allowlist: ok\n")
        }
    }
}
