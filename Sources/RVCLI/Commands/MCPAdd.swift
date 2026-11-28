#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import ArgumentParser
import Foundation
import RVDomain
import RVIsolation
import RVMCP
import RVPolicy

/// `rv mcp add [<host>]`: find the MCP servers every agent host already
/// has, show what rv would take and what it would leave (one line each),
/// show the exact host config rewrites, then with one owner confirmation
/// import them (local servers sealed, credentials into rv keys by name)
/// and point the hosts at rv's gateway. `rv mcp remove` puts the host
/// entries back. Discovery only reads files: no server is started.
enum MCPAdoptRun {
    struct Request: Sendable {
        /// nil: every host.
        var hosts: Set<MCPHost>?
        /// The host word the person typed, for the next command.
        var typed: String?
        var servers: [String] = []
        var project: URL?
        var preview = false
        /// The rv the hosts launch.
        var rvPath: String
        /// The rv that counts as already governing an entry.
        var rvExecutable: String
    }

    static func add(
        _ request: Request, environment: MCPEnvironment, hasTerminal: () -> Bool,
        show: @escaping @Sendable (String) -> Void
    ) async -> Result<String, CommandFailure> {
        let again = MCPAdoptText.command("add", typed: request.typed)
        // Owner-only: checked before anything is read, so an agent's shell
        // gets the refusal instead of a Touch ID prompt nobody asked for.
        if request.preview == false, hasTerminal() == false {
            return .failure(CommandFailure(MCPAdoptText.needsTerminal(again)))
        }
        let base: MCPRun.MCPStoredConfiguration
        switch MCPRun.readSnapshot(environment) {
        case .failure(let failure): return .failure(failure)
        case .success(let loaded): base = loaded
        }
        let secrets: SecretsConfiguration
        switch SecretsConfiguration.load(configDirectory: environment.configDirectory) {
        case .failure(let error): return .failure(CommandFailure(error.message))
        case .success(let loaded): secrets = loaded
        }
        let inventory = MCPInventory.discover(
            home: environment.home, project: request.project, environment: environment.processEnvironment)
        let wanted = request.servers.isEmpty ? nil : Set(request.servers)
        let survey = MCPAdoption.survey(
            entries: inventory.entries, configuration: base.configuration, secrets: secrets,
            rvExecutable: request.rvExecutable, hosts: request.hosts, servers: wanted)
        let missing = request.servers.filter { name in survey.rows.contains { $0.name == name } == false }
        guard missing.isEmpty else {
            let shown = missing.map(MCPDisplayedText.field).joined(separator: ", ")
            return .failure(CommandFailure("\(CommandVocabulary.Glyph.stopped.rawValue) no host has an MCP server named \(shown)"))
        }
        let files = MCPHostFile.all(home: environment.home, project: request.project, environment: environment.processEnvironment)
        let preview: MCPRoutePreview
        switch MCPAdoption.routePreview(survey, files: files, configuration: base.configuration, rvPath: request.rvPath) {
        case .failure(let error):
            return .failure(CommandFailure("\(CommandVocabulary.Glyph.stopped.rawValue) \(error.message); nothing changed"))
        case .success(let planned): preview = planned
        }
        let asked = request.hosts.map { hosts in MCPHost.allCases.filter(hosts.contains) } ?? []
        let problems = inventory.problems.filter { problem in
            request.hosts == nil || files.contains { $0.path.path == problem.path && request.hosts?.contains($0.host) == true }
        }
        let heading = MCPAdoptText.survey(survey, asked: asked, problems: problems, home: environment.home)
        guard survey.adopting > 0 else {
            return .success((heading + [MCPAdoptText.nothingToAdd(survey)]).joined(separator: "\n") + "\n")
        }
        let rewrites = MCPAdoptText.diff(preview.changes, relaid: preview.relaid, home: environment.home)
        let manual = MCPAdoptText.manualSteps(preview.manualSteps)
        if request.preview {
            let next = ["  nothing changed yet", "\(CommandVocabulary.Glyph.next.rawValue) \(again)"]
            let lines = heading + rewrites + manual + next
            return .success(lines.joined(separator: "\n") + "\n")
        }
        // The import's own review lists the rewrites it confirms, so they
        // are shown once, inside it, when there is anything to import.
        let shown = survey.imports.servers.isEmpty ? heading + rewrites + manual : heading + manual
        show(shown.joined(separator: "\n") + "\n")
        if case .failure(let failure) = await confirmAndImport(
            survey, base: base, secrets: secrets, rewrites: rewrites, environment: environment, show: show)
        {
            return .failure(failure)
        }
        return route(survey, files: files, request: request, environment: environment)
    }

    /// The one owner confirmation. With servers to import, it is the import's
    /// own review and confirmation, which also covers `rewrites`; with only
    /// host entries to point at servers mcp.json already has, it confirms
    /// those rewrites on their own, after the same integrity check.
    static func confirmAndImport(
        _ survey: MCPAdoptionSurvey, base: MCPRun.MCPStoredConfiguration, secrets: SecretsConfiguration,
        rewrites: [String], environment: MCPEnvironment, show: @escaping @Sendable (String) -> Void
    ) async -> Result<Void, CommandFailure> {
        guard survey.imports.servers.isEmpty else {
            return await MCPRun.commitImport(
                survey.imports, base: base, secrets: secrets, environment: environment,
                toolModeForFreshConfig: .search, routes: rewrites, show: show
            ).mapError { CommandFailure("\(CommandVocabulary.Glyph.stopped.rawValue) \($0.message)") }
        }
        let integrity = MCPIntegrity.status(
            of: base.bytes, configDirectory: environment.configDirectory, signing: environment.approvalSigning)
        if let problem = integrity.problem {
            return .failure(CommandFailure(
                "\(CommandVocabulary.Glyph.stopped.rawValue) \(problem); nothing changed\n"
                    + "\(CommandVocabulary.Glyph.next.rawValue) \(CommandVocabulary.Command.mcp.invocation) trust"))
        }
        return await confirm("route", rewrites, environment: environment)
    }

    /// Asks the device owner to confirm `lines`; the reason carries their digest.
    static func confirm(_ action: String, _ lines: [String], environment: MCPEnvironment) async -> Result<Void, CommandFailure> {
        let body = lines.joined(separator: "\n")
        let reason = "rv: \(action) sha256 \(RVDigest.sha256Hex(Array(body.utf8)))\n\(body)"
        switch await environment.presence.confirm(reason, .deviceOwner) {
        case .confirmed: return .success(())
        case .refused(let why):
            return .failure(CommandFailure("\(CommandVocabulary.Glyph.stopped.rawValue) not confirmed: \(why); nothing changed"))
        }
    }

    /// Points each host at rv's gateway through `MCPHostSetup` (a backup of
    /// every file first, and the manifest `rv mcp remove` undoes from).
    static func route(
        _ survey: MCPAdoptionSurvey, files: [MCPHostFile], request: Request, environment: MCPEnvironment
    ) -> Result<String, CommandFailure> {
        let undo = MCPAdoptText.command("remove", typed: request.typed)
        let configuration: MCPConfiguration
        switch MCPRun.configuration(environment) {
        case .failure(let failure): return .failure(failure)
        case .success(let loaded): configuration = loaded
        }
        var applied = Applied()
        for host in MCPHost.allCases {
            guard let names = survey.routes[host], names.isEmpty == false else { continue }
            let outcome = MCPHostSetup.setup(
                files: files.filter { $0.host == host }, configuration: configuration, servers: names,
                rvPath: request.rvPath, configDirectory: environment.configDirectory)
            switch outcome {
            case .success(let result):
                applied.changed += result.changed
                applied.backups += result.backups
                applied.manualSteps += result.manualSteps
            case .failure(let error):
                if case .partial(let landed, _) = error {
                    applied.changed += landed.changed
                    applied.backups += landed.backups
                }
                return .failure(CommandFailure(stopped(error, applied: applied, undo: undo)))
            }
        }
        let taken = survey.rows.filter { if case .adopt = $0.verdict { true } else { false } }.count
        var lines = MCPAdoptText.done(survey, taken: taken, undo: undo)
        lines += MCPAdoptText.manualSteps(applied.manualSteps)
        if let backup = applied.backups.first {
            let count = applied.backups.count == 1 ? "1 file" : "\(applied.backups.count) files"
            let folder = MCPRun.abbreviate((backup as NSString).deletingLastPathComponent, home: environment.home)
            lines.append("  \(count) backed up first, in " + MCPDisplayedText.field(folder))
        }
        return .success(lines.joined(separator: "\n") + "\n")
    }

    /// What already landed when a run stopped part way.
    struct Applied: Sendable {
        var changed: [String] = []
        var skipped: [String] = []
        var backups: [String] = []
        var manualSteps: [String] = []
    }

    static func stopped(_ error: MCPSetupError, applied: Applied, undo: String) -> String {
        var lines = ["\(CommandVocabulary.Glyph.stopped.rawValue) \(error.message)"]
        if applied.changed.isEmpty == false {
            lines.append("  \(applied.changed.count == 1 ? "1 entry" : "\(applied.changed.count) entries") already point at rv")
            lines.append("\(CommandVocabulary.Glyph.next.rawValue) \(undo)")
        }
        return lines.joined(separator: "\n")
    }

    /// `rv mcp remove [<host>]`: put back every host entry rv pointed at its
    /// gateway that is still as rv wrote it. Owner-only, like add.
    static func remove(
        hosts: Set<MCPHost>?, typed: String?, preview: Bool, environment: MCPEnvironment, hasTerminal: () -> Bool,
        show: @escaping @Sendable (String) -> Void
    ) async -> Result<String, CommandFailure> {
        let again = MCPAdoptText.command("remove", typed: typed)
        if preview == false, hasTerminal() == false {
            return .failure(CommandFailure(MCPAdoptText.needsTerminal(again)))
        }
        let records = MCPAdoption.setupRecords(configDirectory: environment.configDirectory)
        let selected = hosts.map { set in MCPHost.allCases.filter(set.contains) }
        let scopes: [MCPHost?] = selected.map { $0.map(Optional.some) } ?? [nil]
        let changes = scopes.flatMap { MCPAdoption.undoPreview(records: records, host: $0) }
        var lines = MCPAdoptText.removal(changes, hosts: selected ?? [], home: environment.home)
        guard changes.isEmpty == false else { return .success(lines.joined(separator: "\n") + "\n") }
        if preview {
            lines += ["  nothing changed yet", "\(CommandVocabulary.Glyph.next.rawValue) \(again)"]
            return .success(lines.joined(separator: "\n") + "\n")
        }
        show(lines.joined(separator: "\n") + "\n")
        if case .failure(let failure) = await confirm("remove", Array(lines.dropFirst()), environment: environment) {
            return .failure(failure)
        }
        var result = Applied()
        for host in scopes {
            switch MCPHostSetup.undo(host: host, servers: nil, configDirectory: environment.configDirectory) {
            case .success(let undone):
                result.changed += undone.changed
                result.skipped += undone.skipped
            case .failure(let error):
                return .failure(CommandFailure(stopped(error, applied: result, undo: again)))
            }
        }
        let changed = MCPHost.allCases.filter { host in changes.contains { $0.host == host } }
        return .success(MCPAdoptText.removed(changed: result.changed, skipped: result.skipped, hosts: changed)
            .joined(separator: "\n") + "\n")
    }

    /// After `rv setup`: one heading and the next command when any agent
    /// host has MCP servers that do not run through rv, else nil. Reads
    /// host configs only; nothing is started or written.
    static func setupHint(environment: MCPEnvironment, project: URL?, rvExecutable: String) -> String? {
        guard case .success(let base) = MCPRun.readSnapshot(environment),
            case .success(let secrets) = SecretsConfiguration.load(configDirectory: environment.configDirectory)
        else { return nil }
        let inventory = MCPInventory.discover(home: environment.home, project: project, environment: environment.processEnvironment)
        let survey = MCPAdoption.survey(
            entries: inventory.entries, configuration: base.configuration, secrets: secrets, rvExecutable: rvExecutable)
        guard survey.notGoverned > 0 else { return nil }
        return "\(CommandVocabulary.Glyph.rv.rawValue) rv found \(MCPAdoptText.servers(survey.found)) in "
            + "\(MCPAdoptText.hostList(survey.hosts)), \(survey.notGoverned) not governed\n"
            + "\(CommandVocabulary.Glyph.next.rawValue) \(MCPAdoptText.command("add", typed: nil))"
    }

    /// True when this process has a controlling terminal: `/dev/tty` opens
    /// and is a tty. An agent's shell usually has none.
    static func controllingTerminalExists() -> Bool {
        let fd = open("/dev/tty", O_RDWR | O_NOCTTY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return isatty(fd) == 1
    }

    /// `claude`, `cursor`, … as `MCPHost`, or a usage error naming the hosts.
    static func host(_ word: String?) throws -> Set<MCPHost>? {
        guard let word else { return nil }
        guard let host = MCPHost(word: word) else {
            let known = ["claude"] + MCPHost.allCases.map(\.rawValue)
            throw ValidationError("no host named \(MCPDisplayedText.field(word)); hosts: \(known.joined(separator: ", "))")
        }
        return [host]
    }

    /// Glyphs coloured only when `fd` is a terminal, never under NO_COLOR or TERM=dumb.
    static func paint(_ text: String, fd: Int32 = STDOUT_FILENO) -> String {
        BoxInk.paint(text, palette: BoxInk.palette(
            isTerminal: isatty(fd) == 1, environment: ProcessInfo.processInfo.environment))
    }
}

struct MCPAdd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Bring the MCP servers your agents already have under rv: sealed, keys moved, hosts pointed at rv.")

    @Argument(help: "Only this host: claude, cursor, codex, and the rest rv knows. Default: every host.") var host: String?
    @Option(name: .customLong("server"), help: "Only this server (repeatable).") var servers: [String] = []
    @Option(help: "Project directory for project-scoped configs. Default: current directory.") var project: String?
    @Option(help: "rv path the hosts should launch. Default: this rv.") var rvPath: String?
    @Flag(help: "Show what would change; change nothing.") var preview = false

    func validate() throws { _ = try MCPAdoptRun.host(host) }

    func run() async throws {
        let ctx = CommandContext.current(command: "mcp add", json: false, robot: false, plain: true, noColor: true)
        let environment = MCPEnvironment.live(home: try ctx.requireHome())
        let request = MCPAdoptRun.Request(
            hosts: try MCPAdoptRun.host(host), typed: host, servers: servers, project: MCPRun.projectURL(project),
            preview: preview, rvPath: rvPath ?? MCPRun.rvExecutablePath(environment: environment.processEnvironment),
            rvExecutable: MCPExecutable.currentPath())
        switch await MCPAdoptRun.add(
            request, environment: environment, hasTerminal: MCPAdoptRun.controllingTerminalExists,
            show: { ctx.writeStdout(MCPAdoptRun.paint($0)) })
        {
        case .failure(let failure): try ctx.fail(MCPAdoptRun.paint(failure.message + "\n", fd: STDERR_FILENO), exitCode: failure.exitCode)
        case .success(let text): ctx.writeStdout(MCPAdoptRun.paint(text))
        }
    }
}

struct MCPRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Put back the host entries `rv mcp add` pointed at rv, when they are unchanged.")

    @Argument(help: "Only this host. Default: every host.") var host: String?
    @Flag(help: "Show what would change; change nothing.") var preview = false

    func validate() throws { _ = try MCPAdoptRun.host(host) }

    func run() async throws {
        let ctx = CommandContext.current(command: "mcp remove", json: false, robot: false, plain: true, noColor: true)
        let environment = MCPEnvironment.live(home: try ctx.requireHome())
        switch await MCPAdoptRun.remove(
            hosts: try MCPAdoptRun.host(host), typed: host, preview: preview, environment: environment,
            hasTerminal: MCPAdoptRun.controllingTerminalExists, show: { ctx.writeStdout(MCPAdoptRun.paint($0)) })
        {
        case .failure(let failure): try ctx.fail(MCPAdoptRun.paint(failure.message + "\n", fd: STDERR_FILENO), exitCode: failure.exitCode)
        case .success(let text): ctx.writeStdout(MCPAdoptRun.paint(text))
        }
    }
}
