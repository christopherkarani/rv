import ArgumentParser
import Foundation
import RVDomain
import RVIsolation
import RVMCP
import RVPolicy

/// Seams for `rv init`: where config lives and how the machine is inspected.
/// Tests inject a temp home and canned files; production probes the real one.
struct InitEnvironment: Sendable {
    var configDirectory: URL
    var home: URL
    var pathDirectories: [String]
    var fileExists: @Sendable (String) -> Bool
    var isExecutableFile: @Sendable (String) -> Bool

    static func live(home: HomeDirectory) -> InitEnvironment {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return InitEnvironment(
            configDirectory: RVPolicyPaths.configDirectory(home: home),
            home: URL(fileURLWithPath: home.rawValue, isDirectory: true),
            pathDirectories: path.split(separator: ":").map(String.init).filter { $0.hasPrefix("/") },
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            isExecutableFile: { FileManager.default.isExecutableFile(atPath: $0) }
        )
    }
}

enum InitRun {
    struct AgentCredential: Sendable {
        var agent: String
        /// Home-relative components; the staged destination joins them with "/".
        var relative: [String]
    }

    /// Credential files `rv init` stages when they exist. Sources are the
    /// installed locations from docs/security/runtime-resource-policy.md; the
    /// destination mirrors the home-relative path into the runtime-private
    /// home. Nothing is invented: a file that is absent is skipped.
    static let knownCredentials: [AgentCredential] = [
        AgentCredential(agent: "claude", relative: [".claude", ".credentials.json"]),
        AgentCredential(agent: "claude", relative: [".claude", "settings.json"]),
        AgentCredential(agent: "claude", relative: [".claude", "settings.local.json"]),
        AgentCredential(agent: "codex", relative: [".codex", "auth.json"]),
        AgentCredential(agent: "codex", relative: [".codex", "config.toml"]),
        AgentCredential(agent: "opencode", relative: [".local", "share", "opencode", "auth.json"]),
        AgentCredential(agent: "muse", relative: [".config", "muse", "auth.json"]),
    ]

    struct Plan: Sendable, Equatable {
        var profile: RuntimeResourceProfile
        var notes: [String]
    }

    /// Builds one profile for `project` without writing anything. `agents`
    /// narrows the profile to those tags; empty detects installed agents.
    /// `secretNames` are wired into the profile's `secrets` as-is: names that
    /// secrets.json does not define fail closed at launch, and the caller
    /// reports each name's defined-status separately.
    static func plan(
        profileID: String, project: String, agents: [String], secretNames: [String],
        environment: InitEnvironment
    ) -> Result<Plan, CommandFailure> {
        guard isProfileID(profileID) else {
            return .failure("profile id must be 1-64 of A-Z a-z 0-9 . _ -")
        }
        for agent in agents where AgentTagValidator.isValid(agent) == false {
            return .failure("agent tag \(DisplayedText.field(agent)) is invalid (1-32 of A-Z a-z 0-9 . _ -)")
        }
        if Set(agents).count != agents.count {
            return .failure("agent tags must be distinct")
        }
        if agents.count > 8 {
            return .failure("at most 8 agent tags")
        }
        let secrets = Array(Set(secretNames)).sorted()
        if secrets.count > 16 {
            return .failure("at most 16 secrets per profile")
        }
        for name in secrets where SecretsConfiguration.isVariableName(name) == false {
            return .failure("\(DisplayedText.field(name)) is not an environment variable name")
        }
        let wanted: [String] = agents.isEmpty ? RuntimeAgentEntries.known : agents
        var links: [RuntimeResourceProfile.ExecutableLink] = []
        var linkedAgents = Set<String>()
        for agent in wanted {
            if let target = executable(agent, environment: environment) {
                links.append(RuntimeResourceProfile.ExecutableLink(name: agent, target: target))
                linkedAgents.insert(agent)
            }
        }
        var credentials: [RuntimeResourceProfile.Credential] = []
        var credentialAgents = Set<String>()
        for known in knownCredentials where wanted.contains(known.agent) {
            let source = known.relative.reduce(environment.home) { $0.appendingPathComponent($1) }.path
            guard environment.fileExists(source) else { continue }
            credentials.append(RuntimeResourceProfile.Credential(
                source: source, destination: known.relative.joined(separator: "/")))
            credentialAgents.insert(known.agent)
        }
        let marks = agents.isEmpty ? linkedAgents.union(credentialAgents).sorted() : agents
        var notes: [String] = []
        if agents.isEmpty {
            if marks.isEmpty {
                notes.append("no agent binaries or credentials detected; the profile serves every launch")
            } else {
                notes.append("detected agents: \(marks.joined(separator: ", "))")
            }
        }
        if agents.isEmpty == false {
            for agent in wanted where linkedAgents.contains(agent) == false && credentialAgents.contains(agent) == false {
                notes.append("no binary or credential found for \(DisplayedText.field(agent)); launch rows may be missing")
            }
        }
        if links.isEmpty && credentials.isEmpty {
            notes.append("no executable links or credentials; add --agent or install the agent first")
        }
        let profile = RuntimeResourceProfile(
            id: profileID, projects: [project], agents: marks,
            executableLinks: links, credentials: credentials, secrets: secrets)
        return .success(Plan(profile: profile, notes: notes))
    }

    /// Appends `profile` to runtime-resources.json. Refuses when the id is
    /// taken; every other profile is left byte-identical. The write
    /// round-trips through the store's own decoder, so only documents the
    /// host would accept are persisted.
    static func writeProfile(
        _ profile: RuntimeResourceProfile, configDirectory: URL
    ) -> Result<Void, CommandFailure> {
        let policy: RuntimeResourcePolicy
        switch RuntimeResourcePolicyStore.load(from: configDirectory) {
        case .failure(let error):
            return .failure(CommandFailure(RuntimeResourcePolicyFile.message(error)))
        case .success(let loaded):
            policy = loaded
        }
        if policy.profiles.contains(where: { $0.id == profile.id }) {
            return .failure(
                "profile \(DisplayedText.field(profile.id)) already exists; pass --profile-id or edit runtime-resources.json")
        }
        var updated = policy
        updated.profiles.append(profile)
        switch RuntimeResourcePolicyFile.write(updated, configDirectory: configDirectory) {
        case .failure(let error):
            return .failure(CommandFailure(RuntimeResourcePolicyFile.message(error)))
        case .success:
            return .success(())
        }
    }

    /// Appends `secret` to profile `profileID`'s staged secrets. Used by
    /// `rv secrets set --profile` after the value is stored.
    static func attachSecret(
        _ secret: String, profileID: String, configDirectory: URL
    ) -> Result<Bool, CommandFailure> {
        let policy: RuntimeResourcePolicy
        switch RuntimeResourcePolicyStore.load(from: configDirectory) {
        case .failure(let error):
            return .failure(CommandFailure(RuntimeResourcePolicyFile.message(error)))
        case .success(let loaded):
            policy = loaded
        }
        guard let index = policy.profiles.firstIndex(where: { $0.id == profileID }) else {
            return .failure(
                "profile \(DisplayedText.field(profileID)) does not exist; run `rv init` to create it")
        }
        if policy.profiles[index].secrets.contains(secret) {
            return .success(false)
        }
        var updated = policy
        updated.profiles[index].secrets.append(secret)
        switch RuntimeResourcePolicyFile.write(updated, configDirectory: configDirectory) {
        case .failure(let error):
            return .failure(CommandFailure(RuntimeResourcePolicyFile.message(error)))
        case .success:
            return .success(true)
        }
    }

    static func executable(_ name: String, environment: InitEnvironment) -> String? {
        for directory in environment.pathDirectories {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if environment.isExecutableFile(candidate) {
                return candidate
            }
        }
        return nil
    }

    static func isProfileID(_ value: String) -> Bool {
        value.isEmpty == false && value.utf8.count <= 64 && value.utf8.allSatisfy {
            ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122)
                || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    /// Fresh names a varlock import would add: sensitive items with provider
    /// references that secrets.json does not already define. Mirrors the
    /// write path's filter so the profile wires exactly what lands.
    static func varlockFreshNames(text: String, current: SecretsConfiguration) -> [String] {
        guard case .success(let plan) = VarlockSchema.plan(text) else { return [] }
        return plan.secrets.map(\.name).filter { current.secret(named: $0) == nil }
    }

    /// Dry-run review for `--dotenv`: every bindable name, annotated. The
    /// secret-name heuristic only annotates; it never skips a name.
    static func dotenvReviewLines(_ candidates: SecretsRun.DotenvCandidates) -> [String] {
        var lines = [
            "dotenv \(DisplayedText.field(candidates.storedPath)): would bind \(candidates.fresh.count) name\(candidates.fresh.count == 1 ? "" : "s") (values stay in .env)"
        ]
        for secret in candidates.fresh {
            var line = "  bind \(secret.name) (dotenv \(secret.name); delivery environment"
            if MCPRedaction.isSecretName(secret.name) == false { line += "; not secret-looking" }
            lines.append(line + ")")
        }
        for name in candidates.alreadyDefinedHere {
            lines.append("  wire \(name) (already bound to this file)")
        }
        lines += candidates.lines.filter { $0.hasPrefix("skip ") || $0.hasPrefix("note ") }
        return lines
    }

    /// Names a dotenv ingestion wires into the profile: fresh binds plus
    /// names already bound to this exact file. Identical for dry-run and
    /// write, so the reviewed plan is what lands. A name bound anywhere
    /// else is never wired: another project's value must not stage here.
    static func dotenvWiredNames(_ candidates: SecretsRun.DotenvCandidates) -> [String] {
        candidates.fresh.map(\.name) + candidates.alreadyDefinedHere
    }



    static func planText(
        _ plan: Plan, project: String, secretDefined: [String: Bool], varlockLines: [String],
        dryRun: Bool, wrote: Bool, dotenvLines: [String] = [], dotenvBound: Bool = false
    ) -> String {
        var lines = ["profile \(DisplayedText.field(plan.profile.id)) for \(DisplayedText.field(project))"]
        for link in plan.profile.executableLinks {
            lines.append("  link \(DisplayedText.field(link.name)) -> \(DisplayedText.field(link.target))")
        }
        for credential in plan.profile.credentials {
            lines.append(
                "  credential \(DisplayedText.field(credential.source)) -> \(DisplayedText.field(credential.destination))")
        }
        for name in plan.profile.secrets {
            if secretDefined[name] == true {
                lines.append("  secret \(DisplayedText.field(name)) (defined; staged at launch)")
            } else {
                lines.append(
                    "  secret \(DisplayedText.field(name)) (not defined; run `rv secrets set \(name)`)")
            }
        }
        lines += plan.notes.map { "note: \($0)" }
        lines += varlockLines
        lines += dotenvLines
        if dryRun {
            lines.append("dry run: nothing written")
        } else if wrote {
            lines.append("wrote runtime-resources.json")
        }
        if dotenvBound {
            lines.append(
                "next: rv run --workspace \(shellWord(project)) --resource-profile \(plan.profile.id) -- python main.py")
        } else {
            lines.append(
                "next: rv opencode --workspace \(shellWord(project)) --resource-profile \(plan.profile.id) -- run '...'")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Quotes a word for the suggested next command when pasting it raw
    /// would split or expand. Displayed paths elsewhere stay unquoted.
    /// Single quotes are the only quoting in which `$`, backticks, and
    /// `;` stay inert; an embedded `'` is written as `'\''`.
    static func shellWord(_ path: String) -> String {
        let safe = path.isEmpty == false && path.allSatisfy { character in
            character.isLetter || character.isNumber
                || "/._-:=%@+,".contains(character)
        }
        if safe { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Fails with the duplicate-id message when `profileID` is already
    /// taken, so callers can refuse before producing any side effect.
    static func ensureProfileCanBeAdded(
        _ profileID: String, configDirectory: URL
    ) -> Result<Void, CommandFailure> {
        switch RuntimeResourcePolicyStore.load(from: configDirectory) {
        case .failure(let error):
            return .failure(CommandFailure(RuntimeResourcePolicyFile.message(error)))
        case .success(let policy):
            if policy.profiles.contains(where: { $0.id == profileID }) {
                return .failure(
                    "profile \(DisplayedText.field(profileID)) already exists; pass --profile-id or edit runtime-resources.json")
            }
            return .success(())
        }
    }
}

struct Init: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Generate a runtime resource profile for this project.",
        discussion: """
            Inspects installed agent binaries and credential files, imports
            .env.schema when present, and appends one profile to
            runtime-resources.json. Launches still name the profile explicitly.
            With --dotenv, also binds <project>/.env by reference (values stay
            in .env). Without the flag, an existing .env is only noted: the
            flag is the attestation, because .env carries values and
            .env.schema does not. v1 binds exactly one file: <project>/.env.
            """
    )

    @Option(help: "Project directory. Default: current directory.") var project: String?
    @Option(name: .customLong("profile-id"), help: "Profile id to create. Default: main.") var profileID = "main"
    @Option(name: .customLong("agent"), help: "Serve this agent tag (repeatable). Default: detect installed agents.")
    var agents: [String] = []
    @Option(name: .customLong("secret"), help: "Wire this secret name into the profile (repeatable).")
    var secrets: [String] = []
    @Option(name: .customLong("varlock"), help: "Varlock .env.schema to import. Default: <project>/.env.schema when present.")
    var varlock: String?
    @Flag(name: .customLong("dotenv"), help: "Bind <project>/.env by reference; values stay in .env.")
    var dotenv = false
    @Flag(name: .customLong("dry-run"), help: "Show the plan; write nothing.") var dryRun = false

    func run() throws {
        let ctx = CommandContext.current(command: "init", json: false, robot: false, plain: true, noColor: true)
        let home = try ctx.requireHome()
        let environment = InitEnvironment.live(home: home)
        let root = URL(fileURLWithPath: project ?? FileManager.default.currentDirectoryPath, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            try ctx.fail("rv init: \(DisplayedText.field(root.path)) is not a directory\n")
        }
        let schemaURL: URL?
        if let varlock {
            schemaURL = URL(fileURLWithPath: varlock).standardizedFileURL
            guard FileManager.default.fileExists(atPath: schemaURL?.path ?? "") else {
                try ctx.fail("rv init: \(DisplayedText.field(varlock)) does not exist\n")
            }
        } else {
            let candidate = root.appendingPathComponent(".env.schema", isDirectory: false)
            schemaURL = FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
        }
        let secretsEnvironment = SecretsEnvironment.live(home: home)
        var varlockLines: [String] = []
        var importedNames: [String] = []
        // Read and plan the schema before any write, so invalid input,
        // a bad plan, or a duplicate profile id fails with nothing
        // imported and nothing written.
        var schemaText: String?
        if let schemaURL {
            guard let data = try? Data(contentsOf: schemaURL),
                data.count <= VarlockSchema.maximumBytes,
                let text = String(data: data, encoding: .utf8)
            else {
                try ctx.fail("rv init: could not read \(schemaURL.path)\n")
            }
            schemaText = text
            let current: SecretsConfiguration
            switch SecretsRun.configuration(secretsEnvironment) {
            case .failure(let failure): try ctx.fail("rv init: \(failure.message)\n")
            case .success(let loaded): current = loaded
            }
            if case .success(let schemaPlan) = VarlockSchema.plan(text) {
                // Every schema name is defined once the import below has
                // run: fresh names land, existing names already are.
                importedNames = schemaPlan.secrets.map(\.name)
            }
            if dryRun {
                let fresh = InitRun.varlockFreshNames(text: text, current: current)
                varlockLines.append(
                    "varlock \(schemaURL.path): would import \(fresh.count) secret\(fresh.count == 1 ? "" : "s")")
            }
        }
        var dotenvLines: [String] = []
        var dotenvBound = false
        var dotenvWritePending = false
        let dotenvURL = root.appendingPathComponent(".env", isDirectory: false)
        if dotenv {
            guard FileManager.default.fileExists(atPath: dotenvURL.path) else {
                try ctx.fail("rv init: --dotenv given but \(DisplayedText.field(dotenvURL.path)) does not exist\n")
            }
            let current: SecretsConfiguration
            switch SecretsRun.configuration(secretsEnvironment) {
            case .failure(let failure): try ctx.fail("rv init: \(failure.message)\n")
            case .success(let loaded): current = loaded
            }
            let candidates: SecretsRun.DotenvCandidates
            switch SecretsRun.dotenvCandidates(
                path: dotenvURL, current: current, hostEnvironment: ProcessInfo.processInfo.environment)
            {
            case .failure(let failure): try ctx.fail("rv init: \(failure.message)\n")
            case .success(let built): candidates = built
            }
            // Same policy gate as the write path, applied before anything
            // is written: a denying policy reports the denial, not a plan.
            // The real import runs only after the profile plan validates,
            // so a failed init never leaves new bindings behind.
            switch SecretsRun.importDotenv(path: dotenvURL, dryRun: true, environment: secretsEnvironment) {
            case .failure(let failure): try ctx.fail("rv init: \(failure.message)\n")
            case .success: break
            }
            if dryRun {
                dotenvLines = InitRun.dotenvReviewLines(candidates)
            } else {
                dotenvWritePending = true
            }
            importedNames += InitRun.dotenvWiredNames(candidates)
            dotenvBound = InitRun.dotenvWiredNames(candidates).isEmpty == false
        } else if FileManager.default.fileExists(atPath: dotenvURL.path) {
            var countClause = ""
            if case .success(let snapshot) = DotenvLiveReader.read(path: dotenvURL.path),
                case .success(let parsed) = DotenvFile.parse(snapshot.data)
            {
                countClause = " with \(parsed.entries.count) entries"
            }
            dotenvLines.append(
                "note: \(DisplayedText.field(dotenvURL.path)) exists\(countClause); pass --dotenv to bind them (values stay in .env)")
        }
        let plan: InitRun.Plan
        switch InitRun.plan(
            profileID: profileID, project: root.path, agents: agents,
            secretNames: secrets + importedNames, environment: environment)
        {
        case .failure(let failure): try ctx.fail("rv init: \(failure.message)\n")
        case .success(let built): plan = built
        }
        if dryRun == false {
            switch InitRun.ensureProfileCanBeAdded(profileID, configDirectory: environment.configDirectory) {
            case .failure(let failure): try ctx.fail("rv init: \(failure.message)\n")
            case .success: break
            }
            if let schemaURL, schemaText != nil {
                switch SecretsRun.importVarlock(path: schemaURL, dryRun: false, environment: secretsEnvironment) {
                case .failure(let failure): try ctx.fail("rv init: \(failure.message)\n")
                case .success(let text):
                    varlockLines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
                }
            }
            if dotenvWritePending {
                switch SecretsRun.importDotenv(path: dotenvURL, dryRun: false, environment: secretsEnvironment) {
                case .failure(let failure): try ctx.fail("rv init: \(failure.message)\n")
                case .success(let text):
                    dotenvLines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
                        .filter { $0.hasPrefix("storing absolute path:") == false }
                }
            }
            switch InitRun.writeProfile(plan.profile, configDirectory: environment.configDirectory) {
            case .failure(let failure): try ctx.fail("rv init: \(failure.message)\n")
            case .success: break
            }
        }
        let defined: [String: Bool]
        switch SecretsRun.configuration(secretsEnvironment) {
        case .failure:
            defined = Dictionary(uniqueKeysWithValues: plan.profile.secrets.map { ($0, false) })
        case .success(let configuration):
            defined = Dictionary(
                uniqueKeysWithValues: plan.profile.secrets.map { ($0, configuration.secret(named: $0) != nil) })
        }
        ctx.writeStdout(InitRun.planText(
            plan, project: root.path, secretDefined: defined, varlockLines: varlockLines,
            dryRun: dryRun, wrote: dryRun == false, dotenvLines: dotenvLines, dotenvBound: dotenvBound))
    }
}
