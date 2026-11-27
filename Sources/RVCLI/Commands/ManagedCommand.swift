import ArgumentParser
import Foundation
import RVDomain
import RVIsolation
import RVMCP
import RVPolicy
import RVService

/// `rv managed`: inspect, prepare, and sign the organization policy bundle.
enum ManagedRun {
    /// The managed policy as `rv managed` and `rv report` present it. Closed, so
    /// every consumer must handle each state; the robot JSON stays the flat shape
    /// fleet tooling already parses.
    enum Status: Encodable, Equatable {
        case none(directory: String)
        case invalid(directory: String, reason: String)
        case active(Active)

        struct Active: Equatable {
            var directory: String
            var organization: String?
            var serial: Int?
            var sha256: String
            var signed: Bool
            var signingKey: Int?
            var highestSerial: Int?
            var restrictions: [String]
        }

        private enum CodingKeys: String, CodingKey {
            case state, directory, reason, organization, serial, sha256, signed, signingKey, highestSerial, restrictions
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .none(let directory):
                try container.encode("none", forKey: .state)
                try container.encode(directory, forKey: .directory)
            case .invalid(let directory, let reason):
                try container.encode("invalid", forKey: .state)
                try container.encode(directory, forKey: .directory)
                try container.encode(reason, forKey: .reason)
            case .active(let active):
                try container.encode("active", forKey: .state)
                try container.encode(active.directory, forKey: .directory)
                try container.encodeIfPresent(active.organization, forKey: .organization)
                try container.encodeIfPresent(active.serial, forKey: .serial)
                try container.encode(active.sha256, forKey: .sha256)
                try container.encode(active.signed, forKey: .signed)
                try container.encodeIfPresent(active.signingKey, forKey: .signingKey)
                try container.encodeIfPresent(active.highestSerial, forKey: .highestSerial)
                try container.encode(active.restrictions, forKey: .restrictions)
            }
        }

        /// A present-but-untrustworthy policy: not compliant, `rv managed status` exits 1.
        var isInvalid: Bool {
            switch self {
            case .invalid: true
            case .none, .active: false
            }
        }
    }

    /// The installed policy after the anti-rollback check against the user's serial record.
    static func installed(home: HomeDirectory) -> ManagedPolicyState {
        ManagedPolicyLocation.installed.load(serialsIn: RVPolicyPaths.configDirectory(home: home))
    }

    static func status(_ state: ManagedPolicyState, directory: String) -> Status {
        switch state {
        case .none:
            return .none(directory: directory)
        case .invalid(let reason):
            return .invalid(directory: directory, reason: reason)
        case .active(let bundle):
            return .active(Status.Active(
                directory: bundle.directory, organization: bundle.policy.organization,
                serial: bundle.policy.serial, sha256: bundle.sha256, signed: bundle.isSigned,
                signingKey: bundle.signingKey, highestSerial: bundle.highestSerial,
                restrictions: restrictions(bundle.policy)))
        }
    }

    static func statusText(_ status: Status) -> String {
        switch status {
        case .none(let directory):
            return "no organization policy installed (\(directory))\n"
        case .invalid(let directory, let reason):
            return "organization policy INVALID: \(reason)\n"
                + "MCP and secret staging are disabled and safety is forced to strict until it is fixed (\(directory))\n"
        case .active(let active):
            let signature = switch (active.signed, active.signingKey) {
            case (true, let key?): "signed by key \(key) in \(ManagedPolicyLocation.publicKeyFile)"
            case (true, nil): "signed (\(ManagedPolicyLocation.publicKeyFile) pinned)"
            case (false, _): "unsigned"
            }
            var lines = [
                "organization policy active: \(DisplayedText.field(active.organization ?? "unnamed"))"
                    + (active.serial.map { " serial \($0)" } ?? ""),
                "  \(signature) sha256 \(active.sha256)",
            ]
            if let highest = active.highestSerial { lines.append("  anti-rollback: highest serial accepted here is \(highest)") }
            lines += active.restrictions.isEmpty
                ? ["  no restrictions"] : active.restrictions.map { "  " + DisplayedText.field($0) }
            return lines.joined(separator: "\n") + "\n"
        }
    }

    static func restrictions(_ policy: ManagedPolicy, sandboxEnforced: Bool = MCPSandbox.enforced) -> [String] {
        var lines: [String] = []
        let mcp = policy.mcp
        if mcp.blocked.isEmpty == false { lines.append("mcp blocked servers: " + mcp.blocked.joined(separator: ", ")) }
        if mcp.allowDirect == false { lines.append("mcp: servers may not run outside rv (direct ignored)") }
        // The hard flip requires sandboxes where the cage runs, so there
        // `requireSandbox` changes nothing. Without a cage it refuses every
        // local server.
        if sandboxEnforced {
            lines.append("mcp: every local server must be sandboxed (remote servers are exempt)")
        } else if mcp.requireSandbox {
            lines.append("mcp: no MCP server sandbox on this host, so every local server is refused here (remote servers are exempt)")
        } else {
            lines.append("mcp: no MCP server sandbox on this host; sandboxed servers are refused here (remote servers are exempt)")
        }
        if mcp.deny.isEmpty == false { lines.append("mcp deny: " + mcp.deny.joined(separator: ", ")) }
        if mcp.ask.isEmpty == false { lines.append("mcp ask: " + mcp.ask.joined(separator: ", ")) }
        if mcp.allow.isEmpty == false { lines.append("mcp allow: " + mcp.allow.joined(separator: ", ")) }
        for ruled in mcp.rules { lines.append("mcp \(ruled.decision.rawValue): \(ruled.rule.summary)") }
        if mcp.defaultDecision != .allow { lines.append("mcp default for other tools: \(mcp.defaultDecision.rawValue)") }
        if let sources = policy.secrets.allowedSources {
            lines.append("secret sources allowed: " + (sources.isEmpty ? "none" : sources.map(\.rawValue).joined(separator: ", ")))
        }
        if policy.secrets.allowEnvironmentDelivery == false { lines.append("secrets: gateway delivery only") }
        if let forward = policy.auditForward { lines.append("audit forwarded to \(forward.url)") }
        if policy.gate.requirePacks.isEmpty == false {
            lines.append("gate: packs required: \(policy.gate.requirePacks.map(\.rawValue).joined(separator: ", "))")
            let unknown = ManagedGate.unknownRequiredPacks(policy.gate.requirePacks)
            if unknown.isEmpty == false {
                lines.append(
                    "gate: warning: not bundled packs, so not enforced: \(unknown.map(\.rawValue).joined(separator: ", "))")
            }
        }
        if policy.gate.requireStrictSafety { lines.append("gate: strict safety required") }
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

    /// What `rv managed verify` checked on a candidate bundle, and what it
    /// cannot check from here. Every line it prints is one of these.
    struct VerifyReport: Encodable, Equatable {
        var directory: String
        var organization: String?
        var serial: Int?
        var sha256: String
        /// 1-based key in the bundle's own `org-key.pub` that verified the
        /// signature, or nil when no key was there to check against.
        var signingKey: Int?
        /// A `policy.json.sig` sits in the bundle with no `org-key.pub`, so
        /// nothing checked it.
        var signatureUnchecked: Bool
        var restrictions: [String]
        var checked: [String]
        var notChecked: [String]

        private enum CodingKeys: String, CodingKey {
            case state, directory, organization, serial, sha256, signed, signingKey, signatureUnchecked
            case restrictions, checked, notChecked
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("verified", forKey: .state)
            try container.encode(directory, forKey: .directory)
            try container.encodeIfPresent(organization, forKey: .organization)
            try container.encodeIfPresent(serial, forKey: .serial)
            try container.encode(sha256, forKey: .sha256)
            try container.encode(signingKey != nil, forKey: .signed)
            try container.encodeIfPresent(signingKey, forKey: .signingKey)
            try container.encode(signatureUnchecked, forKey: .signatureUnchecked)
            try container.encode(restrictions, forKey: .restrictions)
            try container.encode(checked, forKey: .checked)
            try container.encode(notChecked, forKey: .notChecked)
        }
    }

    /// `verify`, with each claim tied to the check that backs it.
    static func verifyReport(directory: URL) -> Result<VerifyReport, CommandFailure> {
        func read(_ name: String) -> Data? {
            try? Data(contentsOf: directory.appendingPathComponent(name))
        }
        guard let policyData = read(ManagedPolicyLocation.policyFile) else {
            return .failure(CommandFailure("\(DisplayedText.field(directory.path)) has no \(ManagedPolicyLocation.policyFile)"))
        }
        let signature = read(ManagedPolicyLocation.signatureFile)
        let state = ManagedPolicyVerifier.verify(
            policy: policyData, signature: signature,
            publicKey: read(ManagedPolicyLocation.publicKeyFile), directory: directory.path)
        guard case .active(let bundle) = state else {
            return .failure(CommandFailure(state.invalidReason ?? "\(ManagedPolicyLocation.policyFile) is not valid"))
        }
        let pub = ManagedPolicyLocation.publicKeyFile
        let sig = ManagedPolicyLocation.signatureFile
        var checked = [
            "\(ManagedPolicyLocation.policyFile) parses as an organization policy this rv reads",
        ]
        var notChecked: [String] = []
        if let key = bundle.signingKey {
            checked.append("\(sig) verifies against key \(key) in this bundle's \(pub)")
            notChecked.append(
                "that this \(pub) is your organization's key (compare it with "
                    + "\(ManagedPolicyLocation.installedDirectory)/\(pub) on a managed machine)")
        } else if signature != nil {
            notChecked.append("\(sig): this bundle has no \(pub) to check it against, so it installs unsigned")
        } else {
            notChecked.append("a signature: this bundle has no \(sig), so it installs unsigned")
        }
        notChecked += [
            "anti-rollback: each machine refuses a serial lower than one it already accepted",
            "owner and permissions once installed (root-owned, not writable by others)",
        ]
        return .success(VerifyReport(
            directory: bundle.directory, organization: bundle.policy.organization, serial: bundle.policy.serial,
            sha256: bundle.sha256, signingKey: bundle.signingKey,
            signatureUnchecked: bundle.signingKey == nil && signature != nil,
            restrictions: policyRestrictions(bundle.policy), checked: checked, notChecked: notChecked))
    }

    /// The bundle's restrictions as the policy states them. Unlike
    /// `restrictions`, nothing here depends on the host running the check.
    static func policyRestrictions(_ policy: ManagedPolicy) -> [String] {
        restrictions(policy, sandboxEnforced: false).map { line in
            line.hasPrefix("mcp: no MCP server sandbox on this host")
                ? (policy.mcp.requireSandbox ? "mcp: every local server must be sandboxed (remote servers are exempt)" : "")
                : line.replacingOccurrences(of: "not bundled packs, so not enforced", with: "packs this rv does not bundle")
        }.filter { $0.isEmpty == false }
    }

    static func verifyText(_ report: VerifyReport) -> String {
        var lines = [
            "policy bundle \(DisplayedText.field(report.directory)): "
                + DisplayedText.field(report.organization ?? "unnamed")
                + (report.serial.map { " serial \($0)" } ?? "") + " sha256 \(report.sha256)",
        ]
        lines += report.checked.map { "  ✓ \($0)" }
        lines += report.restrictions.map { "    " + DisplayedText.field($0) }
        lines += report.notChecked.map { "  ◐ not checked: \($0)" }
        lines.append("  → " + verifyNext(report))
        return lines.joined(separator: "\n") + "\n"
    }

    /// The one next step after a verify: sign it, add the key that checks
    /// the signature, or deploy it and read it back on a managed machine.
    static func verifyNext(_ report: VerifyReport) -> String {
        let policy = URL(fileURLWithPath: report.directory, isDirectory: true)
            .appendingPathComponent(ManagedPolicyLocation.policyFile).path
        if report.signatureUnchecked {
            return "add \(ManagedPolicyLocation.publicKeyFile) to the bundle, then: rv managed verify "
                + DisplayedText.field(report.directory)
        }
        if report.signingKey == nil {
            return "rv managed sign \(DisplayedText.field(policy)) --key org-key.private"
        }
        return "after deploying to \(ManagedPolicyLocation.installedDirectory), on that Mac: rv managed status"
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
        let status = ManagedRun.status(
            ManagedRun.installed(home: home), directory: ManagedPolicyLocation.installedDirectory)
        if ctx.explicitRobot {
            ctx.writeStdout(try RobotJSON.encode(status, options: .pretty))
        } else {
            ctx.writeStdout(ManagedRun.statusText(status))
        }
        switch status {
        case .invalid: throw ExitCode(1)
        case .none, .active: break
        }
    }
}

struct ManagedVerify: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify", abstract: "Check a policy bundle directory before deploying it.")

    @Argument(help: "Directory with policy.json and optionally policy.json.sig and org-key.pub.") var directory: String
    @OptionGroup var format: FormatFlags

    func run() throws {
        let ctx = CommandContext.current(command: "managed verify", format: format)
        switch ManagedRun.verifyReport(directory: URL(fileURLWithPath: directory, isDirectory: true)) {
        case .failure(let failure): try ctx.fail("rv managed verify: \(failure.message)\n")
        case .success(let report):
            ctx.writeStdout(
                ctx.explicitRobot
                    ? try RobotJSON.encode(report, options: .pretty)
                    : ManagedRun.verifyText(report))
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

