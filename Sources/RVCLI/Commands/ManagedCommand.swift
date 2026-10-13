import ArgumentParser
import Foundation
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
        var restrictions: [String]?
    }

    static func status(_ state: ManagedPolicyState, directory: String) -> Status {
        switch state {
        case .none:
            return Status(state: "none", directory: directory)
        case .invalid(let reason):
            return Status(state: "invalid", directory: directory, reason: reason)
        case .active(let bundle):
            return Status(
                state: "active", directory: bundle.directory, organization: bundle.policy.organization,
                serial: bundle.policy.serial, sha256: bundle.sha256, signed: bundle.isSigned,
                restrictions: restrictions(bundle.policy))
        }
    }

    static func statusText(_ status: Status) -> String {
        switch status.state {
        case "none":
            return "no organization policy installed (\(status.directory))\n"
        case "invalid":
            return "organization policy INVALID: \(status.reason ?? "unknown")\n"
                + "MCP and secret staging are disabled until it is fixed (\(status.directory))\n"
        default:
            var lines = [
                "organization policy active: \(status.organization ?? "unnamed")"
                    + (status.serial.map { " serial \($0)" } ?? ""),
                "  \(status.signed == true ? "signed (org-key.pub pinned)" : "unsigned") sha256 \(status.sha256 ?? "")",
            ]
            let rules = status.restrictions ?? []
            lines += rules.isEmpty ? ["  no restrictions"] : rules.map { "  " + $0 }
            return lines.joined(separator: "\n") + "\n"
        }
    }

    static func restrictions(_ policy: ManagedPolicy) -> [String] {
        var lines: [String] = []
        let mcp = policy.mcp
        if mcp.blocked.isEmpty == false { lines.append("mcp blocked servers: " + mcp.blocked.joined(separator: ", ")) }
        if mcp.allowDirect == false { lines.append("mcp: servers may not run outside rv (direct ignored)") }
        if mcp.requireSandbox { lines.append("mcp: every served server must be sandboxed") }
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
            return .failure(CommandFailure("\(directory.path) has no \(ManagedPolicyLocation.policyFile)"))
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
            return .failure(CommandFailure("\(url.path) already exists; refusing to overwrite a key"))
        }
        let pair = ManagedPolicyVerifier.generateKeyPair()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard FileManager.default.createFile(
                atPath: privateURL.path, contents: Data((pair.privateKey + "\n").utf8),
                attributes: [.posixPermissions: 0o600])
            else { return .failure(CommandFailure("could not write \(privateURL.path)")) }
            try Data((pair.publicKey + "\n").utf8).write(to: publicURL)
        } catch {
            return .failure(CommandFailure("could not write keys to \(directory.path)"))
        }
        return .success("""
            wrote \(publicURL.path) (install it in the managed directory)
            wrote \(privateURL.path) (keep it off managed machines)

            """)
    }

    static func sign(policy policyURL: URL, key keyURL: URL, output: URL?) -> Result<String, CommandFailure> {
        guard let policy = try? Data(contentsOf: policyURL) else {
            return .failure(CommandFailure("cannot read \(policyURL.path)"))
        }
        if case .failure(let error) = ManagedPolicy.decode(policy) {
            return .failure(CommandFailure("\(policyURL.lastPathComponent): \(error.message); not signed"))
        }
        guard let key = try? Data(contentsOf: keyURL), let signature = ManagedPolicyVerifier.sign(policy, privateKey: key) else {
            return .failure(CommandFailure("\(keyURL.path) is not a base64 Ed25519 private key"))
        }
        let destination = output ?? policyURL.deletingLastPathComponent().appendingPathComponent(ManagedPolicyLocation.signatureFile)
        do {
            try Data((signature + "\n").utf8).write(to: destination)
        } catch {
            return .failure(CommandFailure("could not write \(destination.path)"))
        }
        return .success("wrote \(destination.path)\n")
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
        let status = ManagedRun.status(
            ManagedPolicyLocation.installed.load(), directory: ManagedPolicyLocation.installedDirectory)
        if ctx.explicitRobot {
            ctx.writeStdout(jsonText(status))
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
        case .success(let status): ctx.writeStdout(ctx.explicitRobot ? jsonText(status) : ManagedRun.statusText(status))
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

private func jsonText<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else { return "{}\n" }
    return text + "\n"
}
