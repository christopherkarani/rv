import Foundation

/// Why `rv run` did not start the command. The child never ran.
package enum SecretRunRefusal: Error, Sendable, Equatable {
    case noSecretsSelected
    case nothingStageable(skipped: [SecretRunSkip])
    case unknownSecret(String)
    case realValueDelivery(String)
    case agentScoped(secret: String, agents: [String])
    case configuration(String)
    case peerBindingUnavailable
    case spawnUnavailable
    case homeUnavailable
    case lease(String)
    case emptyCommand
    case commandNotFound(String)
    case spawnFailed(String)
    case bindFailed(String)

    /// One line, without the `rv run:` prefix.
    package var message: String {
        switch self {
        case .noSecretsSelected:
            "no secrets selected; pass --secret NAME (repeatable) or --all"
        case .nothingStageable(let skipped):
            "no secret in secrets.json can be staged as a placeholder ("
                + skipped.map { "\($0.name): \($0.reason.text)" }.joined(separator: "; ") + ")"
        case .unknownSecret(let name): "secret \(name) is not defined in secrets.json"
        case .realValueDelivery(let name):
            "secret \(name) is delivered as an environment variable, so its real value would be in the "
                + "command's environment; rv run stages only gateway and awsSigV4 secrets"
        case .agentScoped(let name, let agents):
            "secret \(name) stages only for \(agents.joined(separator: ", ")); rv run carries no agent tag"
        case .configuration(let reason): reason
        case .peerBindingUnavailable:
            "the secrets gateway's peer check could not tell which process held a test connection here, "
                + "so placeholders cannot be bound to the command; refusing to launch"
        case .spawnUnavailable:
            "this platform cannot start the command suspended until its placeholders are bound; refusing to launch"
        case .homeUnavailable: "HOME is not an absolute path, so rv's configuration cannot be found"
        case .lease(let reason): reason
        case .emptyCommand: "no command given: rv run [--secret NAME]... [--all] -- COMMAND [ARGS...]"
        case .commandNotFound(let name): "command \(name) not found or not executable"
        case .spawnFailed(let reason): "could not start the command: \(reason)"
        case .bindFailed(let reason): "could not bind the placeholders to the command (\(reason)); it was stopped before it ran"
        }
    }

    /// `env(1)` and `timeout(1)` conventions: 127 command not found, 126
    /// found but not started, 125 the runner itself refused.
    package var exitCode: Int32 {
        switch self {
        case .commandNotFound: 127
        case .spawnFailed: 126
        default: 125
        }
    }
}

/// A secret `--all` passed over, and why.
package struct SecretRunSkip: Sendable, Equatable {
    package enum Reason: Sendable, Equatable {
        case realValueDelivery
        case agentScoped([String])

        package var text: String {
            switch self {
            case .realValueDelivery: "environment delivery would put the real value in the environment"
            case .agentScoped(let agents): "it stages only for \(agents.joined(separator: ", "))"
            }
        }
    }

    package var name: String
    package var reason: Reason
    /// What `rv run` keeps out of the command's environment for it.
    package var definition: SecretDefinition
}

/// Which secrets one `rv run` stages.
package struct SecretRunSelection: Sendable, Equatable {
    package var names: [String]
    package var skipped: [SecretRunSkip]

    /// Explicit names must each be stageable as a placeholder; `all` takes
    /// every one that is and reports the rest. Nothing selected is refused.
    package static func resolve(
        _ configuration: SecretsConfiguration, requested: [String], all: Bool
    ) -> Result<SecretRunSelection, SecretRunRefusal> {
        if all {
            var names: [String] = []
            var skipped: [SecretRunSkip] = []
            for definition in configuration.secrets {
                if let reason = skipReason(definition) {
                    skipped.append(SecretRunSkip(name: definition.name, reason: reason, definition: definition))
                } else {
                    names.append(definition.name)
                }
            }
            guard names.isEmpty == false else {
                return .failure(skipped.isEmpty ? .noSecretsSelected : .nothingStageable(skipped: skipped))
            }
            return .success(SecretRunSelection(names: names, skipped: skipped))
        }
        var names: [String] = []
        for name in requested where names.contains(name) == false {
            guard let definition = configuration.secret(named: name) else { return .failure(.unknownSecret(name)) }
            switch skipReason(definition) {
            case .realValueDelivery: return .failure(.realValueDelivery(name))
            case .agentScoped(let agents): return .failure(.agentScoped(secret: name, agents: agents))
            case nil: names.append(name)
            }
        }
        guard names.isEmpty == false else { return .failure(.noSecretsSelected) }
        return .success(SecretRunSelection(names: names, skipped: []))
    }

    private static func skipReason(_ definition: SecretDefinition) -> SecretRunSkip.Reason? {
        if definition.delivery == .environment { return .realValueDelivery }
        if definition.stages(forAgent: nil) == false { return .agentScoped(definition.agents ?? []) }
        return nil
    }
}

package enum SecretRunEnvironment {
    /// Real AWS credentials a parent shell may export beside the key pair
    /// rv replaces; a session token would pair with nothing rv staged.
    static let awsCredentialVariables = ["AWS_SESSION_TOKEN", "AWS_SECURITY_TOKEN"]

    /// The parent's environment without any variable a selected or
    /// `skipped` secret stages (its real value may be exported there) or is
    /// read from (a `hostEnvironment` source's variable holds the real
    /// value), without the login of the store a selected secret comes from,
    /// and without any variable holding one of `realValues`, then the
    /// lease's placeholders and base URLs on top.
    static func build(
        parent: [String: String], selected: [SecretDefinition], skipped: [SecretDefinition],
        lease: [(name: String, value: String)], realValues: [SecretValue]
    ) -> [String: String] {
        var environment = parent
        for definition in selected + skipped {
            for variable in definition.stagedVariables { environment[variable] = nil }
            if case .hostEnvironment(let variable) = definition.source { environment[variable] = nil }
        }
        for definition in selected {
            for variable in storeLoginVariables(definition.source) { environment[variable] = nil }
            if case .awsSigV4 = definition.delivery {
                for variable in awsCredentialVariables { environment[variable] = nil }
            }
        }
        for name in copies(parent: parent, realValues: realValues) { environment[name] = nil }
        for entry in lease { environment[entry.name] = entry.value }
        return environment
    }

    /// The variables rv's own provider for `source` authenticates to its
    /// store with (`SecretResolver.live`): a command holding one could fetch
    /// the real value itself. Only names rv reads are listed; a provider CLI
    /// reads its own login from the environment rv passes it, and those
    /// names are not rv's to know.
    static func storeLoginVariables(_ source: SecretSource) -> [String] {
        switch source {
        case .vault: ["VAULT_TOKEN"]
        case .keychain, .hostEnvironment, .onePassword, .awsSecretsManager, .infisical, .bitwarden, .gcp, .azure,
            .awsProfile, .oauth:
            []
        }
    }

    /// A real value this long also gives away a variable it appears inside
    /// (`Bearer <token>`); a shorter one only an exact copy, so a short PIN
    /// or id does not take unrelated variables with it.
    static let containedValueLength = 12

    /// The parent's variables, by name, whose value is one of `realValues`
    /// (as is or trimmed of whitespace) or contains one at least
    /// `containedValueLength` bytes long. Compared in memory as bytes; the
    /// values are never printed.
    static func copies(parent: [String: String], realValues: [SecretValue]) -> [String] {
        let real = Set(realValues.map { $0.revealed() })
        guard real.isEmpty == false else { return [] }
        let contained = real.filter { $0.count >= containedValueLength }
        return parent.compactMap { name, value in
            let padded = Array(value.utf8)
            let trimmed = Array(value.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
            if real.contains(padded) || real.contains(trimmed) { return name }
            let inside = contained.contains { SecretLeakScanner.occurrences(of: $0, in: padded).isEmpty == false }
            return inside ? name : nil
        }.sorted()
    }

    /// `NAME=value` entries in a stable order, for `posix_spawn`.
    static func entries(_ environment: [String: String]) -> [String] {
        environment.keys.sorted().map { "\($0)=\(environment[$0] ?? "")" }
    }
}

package enum SecretRunExit {
    /// A `waitpid` status as a shell reports it: the exit code, or 128 plus
    /// the signal that ended the process.
    static func code(waitStatus status: Int32) -> Int32 {
        let signal = status & 0x7f
        if signal == 0 { return (status >> 8) & 0xff }
        return 128 + signal
    }
}

package enum SecretRunCommand {
    /// A name with a slash is a path (relative to `directory`); a bare name
    /// is searched in `PATH`'s absolute entries. Relative `PATH` entries are
    /// skipped: they would resolve against whatever directory rv runs in.
    static func resolve(
        _ name: String, path: String?, directory: String, isExecutable: (String) -> Bool
    ) -> String? {
        guard name.isEmpty == false, name.contains("\0") == false else { return nil }
        if name.contains("/") {
            let candidate = name.hasPrefix("/")
                ? name : URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(name).path
            let standardized = URL(fileURLWithPath: candidate).standardizedFileURL.path
            return isExecutable(standardized) ? standardized : nil
        }
        for entry in (path ?? "/usr/bin:/bin").split(separator: ":", omittingEmptySubsequences: true)
        where entry.hasPrefix("/") {
            let candidate = URL(fileURLWithPath: String(entry), isDirectory: true).appendingPathComponent(name).path
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    /// A regular file this process may execute.
    static func isExecutableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue == false && FileManager.default.isExecutableFile(atPath: path)
    }
}
