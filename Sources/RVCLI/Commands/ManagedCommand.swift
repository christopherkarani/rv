import ArgumentParser
import Foundation
import RVDomain
import RVIsolation
import RVPolicy

/// `rv managed`: inspect, prepare, and sign the organization policy bundle.
enum ManagedRun {
    struct Status: Encodable, Equatable {
        var state: String
        var directory: String
        var reason: String?
        var organization: String?
        var serial: Int?
        var sha256: String?
        var signed: Bool?
        var signingKey: Int?
        var highestSerial: Int?
        var restrictions: [String]?
        /// Effective dotenv posture, present whenever a dotenv binding exists.
        var dotenv: String?
    }

    /// The installed policy after the anti-rollback check against the user's serial record.
    static func installed(home: HomeDirectory) -> ManagedPolicyState {
        ManagedPolicyLocation.installed.load(serialsIn: RVPolicyPaths.configDirectory(home: home))
    }

    static func status(_ state: ManagedPolicyState, directory: String, dotenvBoundCount: Int = 0) -> Status {
        switch state {
        case .none:
            return Status(state: "none", directory: directory, dotenv: dotenvLine(state: state, boundCount: dotenvBoundCount))
        case .invalid(let reason):
            return Status(state: "invalid", directory: directory, reason: reason)
        case .active(let bundle):
            return Status(
                state: "active", directory: bundle.directory, organization: bundle.policy.organization,
                serial: bundle.policy.serial, sha256: bundle.sha256, signed: bundle.isSigned,
                signingKey: bundle.signingKey, highestSerial: bundle.highestSerial,
                restrictions: restrictions(bundle.policy),
                dotenv: dotenvLine(state: state, boundCount: dotenvBoundCount))
        }
    }

    /// Names dotenv's effective status whenever a binding exists, including
    /// the default-allow case a fleet would otherwise gain silently.
    static func dotenvLine(state: ManagedPolicyState, boundCount: Int) -> String? {
        guard boundCount > 0 else { return nil }
        let noun = "\(boundCount) dotenv-bound secret\(boundCount == 1 ? "" : "s")"
        guard let policy = state.policy else {
            return "dotenv: allowed (no organization policy); \(noun)"
        }
        if policy.allowsSecretSource("dotenv") == false {
            return "dotenv: forbidden; \(noun) will fail closed"
        }
        if policy.secrets.allowedSources == nil {
            return "dotenv: allowed by default (policy does not enumerate allowedSources); \(noun)"
        }
        return "dotenv: allowed; \(noun)"
    }

    static func statusText(_ status: Status) -> String {
        switch status.state {
        case "none":
            var text = "no organization policy installed (\(status.directory))\n"
            if let dotenv = status.dotenv { text += "  \(dotenv)\n" }
            return text
        case "invalid":
            return "organization policy INVALID: \(status.reason ?? "unknown")\n"
                + "MCP and secret staging are disabled until it is fixed (\(status.directory))\n"
        default:
            let signature = switch (status.signed, status.signingKey) {
            case (true, let key?): "signed by key \(key) in \(ManagedPolicyLocation.publicKeyFile)"
            case (true, nil): "signed (\(ManagedPolicyLocation.publicKeyFile) pinned)"
            default: "unsigned"
            }
            var lines = [
                "organization policy active: \(DisplayedText.field(status.organization ?? "unnamed"))"
                    + (status.serial.map { " serial \($0)" } ?? ""),
                "  \(signature) sha256 \(status.sha256 ?? "")",
            ]
            if let highest = status.highestSerial { lines.append("  anti-rollback: highest serial accepted here is \(highest)") }
            let rules = status.restrictions ?? []
            lines += rules.isEmpty ? ["  no restrictions"] : rules.map { "  " + DisplayedText.field($0) }
            if let dotenv = status.dotenv { lines.append("  " + dotenv) }
            return lines.joined(separator: "\n") + "\n"
        }
    }

    static func restrictions(_ policy: ManagedPolicy) -> [String] {
        var lines: [String] = []
        let mcp = policy.mcp
        if mcp.blocked.isEmpty == false { lines.append("mcp blocked servers: " + mcp.blocked.joined(separator: ", ")) }
        if mcp.allowDirect == false { lines.append("mcp: servers may not run outside rv (direct ignored)") }
        if mcp.requireSandbox {
            lines.append("mcp: every local server must be sandboxed (remote servers are exempt)")
        }
        if mcp.deny.isEmpty == false { lines.append("mcp deny: " + mcp.deny.joined(separator: ", ")) }
        if mcp.ask.isEmpty == false { lines.append("mcp ask: " + mcp.ask.joined(separator: ", ")) }
        if mcp.allow.isEmpty == false { lines.append("mcp allow: " + mcp.allow.joined(separator: ", ")) }
        for ruled in mcp.rules { lines.append("mcp \(ruled.decision.rawValue): \(ruled.rule.summary)") }
        if mcp.defaultDecision != .allow { lines.append("mcp default for other tools: \(mcp.defaultDecision.rawValue)") }
        if let sources = policy.secrets.allowedSources {
            lines.append("secret sources allowed: " + (sources.isEmpty ? "none" : sources.joined(separator: ", ")))
        }
        if policy.secrets.allowEnvironmentDelivery == false { lines.append("secrets: gateway delivery only") }
        if let forward = policy.auditForward { lines.append("audit forwarded to \(forward.url)") }
        return lines
    }

    /// Pre-deploy check of a candidate bundle directory. No ownership check:
    /// the files are not installed yet.
    static func verify(directory: URL) -> Result<Status, CommandFailure> {
        func read(_ name: String) -> Data? {
            try? Data(contentsOf: directory.appendingPathComponent(name))
        }
        guard let policy = read(ManagedPolicyLocation.policyFile) else {
            return .failure(CommandFailure("\(DisplayedText.field(directory.path)) has no \(ManagedPolicyLocation.policyFile)"))
        }
        let state = ManagedPolicyVerifier.verify(
            policy: policy, signature: read(ManagedPolicyLocation.signatureFile),
            publicKey: read(ManagedPolicyLocation.publicKeyFile), directory: directory.path)
        if let reason = state.invalidReason { return .failure(CommandFailure(reason)) }
        return .success(status(state, directory: directory.path))
    }

    static func keygen(directory: URL) -> Result<String, CommandFailure> {
        let publicURL = directory.appendingPathComponent(ManagedPolicyLocation.publicKeyFile)
        let privateURL = directory.appendingPathComponent("org-key.private")
        for url in [publicURL, privateURL] where FileManager.default.fileExists(atPath: url.path) {
            return .failure(CommandFailure("\(DisplayedText.field(url.path)) already exists; refusing to overwrite a key"))
        }
        let pair = ManagedPolicyVerifier.generateKeyPair()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard FileManager.default.createFile(
                atPath: privateURL.path, contents: Data((pair.privateKey + "\n").utf8),
                attributes: [.posixPermissions: 0o600])
            else { return .failure(CommandFailure("could not write \(DisplayedText.field(privateURL.path))")) }
            try Data((pair.publicKey + "\n").utf8).write(to: publicURL)
        } catch {
            return .failure(CommandFailure("could not write keys to \(DisplayedText.field(directory.path))"))
        }
        return .success("""
            wrote \(DisplayedText.field(publicURL.path)) (install it in the managed directory)
            wrote \(DisplayedText.field(privateURL.path)) (keep it off managed machines)

            """)
    }

    static func sign(policy policyURL: URL, key keyURL: URL, output: URL?) -> Result<String, CommandFailure> {
        guard let policy = try? Data(contentsOf: policyURL) else {
            return .failure(CommandFailure("cannot read \(DisplayedText.field(policyURL.path))"))
        }
        if case .failure(let error) = ManagedPolicy.decode(policy) {
            return .failure(CommandFailure("\(DisplayedText.field(policyURL.lastPathComponent)): \(error.message); not signed"))
        }
        guard let key = try? Data(contentsOf: keyURL), let signature = ManagedPolicyVerifier.sign(policy, privateKey: key) else {
            return .failure(CommandFailure("\(DisplayedText.field(keyURL.path)) is not a base64 Ed25519 private key"))
        }
        let destination = output ?? policyURL.deletingLastPathComponent().appendingPathComponent(ManagedPolicyLocation.signatureFile)
        do {
            try Data((signature + "\n").utf8).write(to: destination)
        } catch {
            return .failure(CommandFailure("could not write \(DisplayedText.field(destination.path))"))
        }
        return .success("wrote \(DisplayedText.field(destination.path))\n")
    }

    /// Robot JSON for `rv managed`. `JSONEncoder` already writes ESC as
    /// `\u001b`. U+2028, U+2029, and U+202E stay raw unless they are replaced
    /// after encoding. The result is still valid JSON. Policy strings are not
    /// fielded first: that would turn ESC into the literal spelling `\\u001b`.
    static func robotJSON<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), var text = String(data: data, encoding: .utf8) else { return "{}\n" }
        text += "\n"
        let scalars: [(Character, String)] = [
            ("\u{2028}", "\\u2028"),
            ("\u{2029}", "\\u2029"),
            ("\u{202E}", "\\u202e"),
        ]
        for (scalar, escaped) in scalars {
            text = text.replacingOccurrences(of: String(scalar), with: escaped)
        }
        return text
    }
}

struct Managed: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "managed",
        abstract: "Inspect, check, and sign the organization policy.",
        subcommands: [ManagedStatus.self, ManagedVerify.self, ManagedKeygen.self, ManagedSign.self],
        defaultSubcommand: ManagedStatus.self
    )
}

struct ManagedStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show the installed organization policy.")

    @OptionGroup var format: FormatFlags

    func run() throws {
        let ctx = CommandContext.current(command: "managed status", format: format)
        let home = try ctx.requireHome()
        var dotenvBound = 0
        if case .success(let configuration) = SecretsConfiguration.load(
            configDirectory: RVPolicyPaths.configDirectory(home: home))
        {
            dotenvBound = configuration.secrets.count { $0.source.kind == "dotenv" }
        }
        let status = ManagedRun.status(
            ManagedRun.installed(home: home), directory: ManagedPolicyLocation.installedDirectory,
            dotenvBoundCount: dotenvBound)
        if ctx.explicitRobot {
            ctx.writeStdout(ManagedRun.robotJSON(status))
        } else {
            ctx.writeStdout(ManagedRun.statusText(status))
        }
        if status.state == "invalid" { throw ExitCode(1) }
    }
}

struct ManagedVerify: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify", abstract: "Check a policy bundle directory before deploying it.")

    @Argument(help: "Directory with policy.json and optionally policy.json.sig and org-key.pub.") var directory: String
    @OptionGroup var format: FormatFlags

    func run() throws {
        let ctx = CommandContext.current(command: "managed verify", format: format)
        switch ManagedRun.verify(directory: URL(fileURLWithPath: directory, isDirectory: true)) {
        case .failure(let failure): try ctx.fail("rv managed verify: \(failure.message)\n")
        case .success(let status): ctx.writeStdout(ctx.explicitRobot ? ManagedRun.robotJSON(status) : ManagedRun.statusText(status))
        }
    }
}

struct ManagedKeygen: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keygen", abstract: "Create an Ed25519 key pair for signing the policy.")

    @Option(help: "Directory for org-key.pub and org-key.private.") var out: String

    func run() throws {
        let ctx = CommandContext.current(command: "managed keygen", json: false, robot: false, plain: true, noColor: true)
        switch ManagedRun.keygen(directory: URL(fileURLWithPath: out, isDirectory: true)) {
        case .failure(let failure): try ctx.fail("rv managed keygen: \(failure.message)\n")
        case .success(let text): ctx.writeStdout(text)
        }
    }
}

struct ManagedSign: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sign", abstract: "Write policy.json.sig for a policy file.")

    @Argument(help: "policy.json to sign.") var policy: String
    @Option(help: "Private key from `rv managed keygen`.") var key: String
    @Option(help: "Signature path. Default: policy.json.sig next to the policy.") var out: String?

    func run() throws {
        let ctx = CommandContext.current(command: "managed sign", json: false, robot: false, plain: true, noColor: true)
        switch ManagedRun.sign(
            policy: URL(fileURLWithPath: policy), key: URL(fileURLWithPath: key), output: out.map { URL(fileURLWithPath: $0) })
        {
        case .failure(let failure): try ctx.fail("rv managed sign: \(failure.message)\n")
        case .success(let text): ctx.writeStdout(text)
        }
    }
}

