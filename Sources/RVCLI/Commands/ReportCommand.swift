import ArgumentParser
import Foundation
import RVDomain
import RVHistory
import RVIsolation
import RVMCP
import RVPolicy

/// `rv report`: one machine's governance posture for MDM / fleet collection.
/// Never resolves secret values, so it never prompts or touches the network.
enum ReportRun {
    static let schema = "rv.report.v1"

    struct Inputs: Sendable {
        var configDirectory: URL
        var home: URL
        var processEnvironment: [String: String]
        var managed: ManagedPolicyState
        var managedDirectory: String
        var now: Date
        var hostName: String
        var userName: String
        var userID: UInt32
        var fileExists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
        var approvalKeys: MCPApprovalKeyStore = .unavailable
    }

    struct Report: Encodable, Equatable {
        struct Product: Encodable, Equatable {
            var version: String
            var platform: String
        }

        struct Host: Encodable, Equatable {
            var name: String
            var user: String
            var uid: UInt32
        }

        struct ConfigFile: Encodable, Equatable {
            var file: String
            var present: Bool
            var sha256: String?
        }

        struct MCPSummary: Encodable, Equatable {
            var ok: Bool
            var error: String?
            var servers: Int
            var counts: [String: Int]
            var failing: [Failing]
            var plaintextCredentials: Int

            struct Failing: Encodable, Equatable {
                var host: String
                var name: String
                var status: String
                var config: String
            }
        }

        struct SecretSummary: Encodable, Equatable {
            var error: String?
            var items: [Item]

            struct Item: Encodable, Equatable {
                var name: String
                var source: String
                var delivery: String
                var policyViolation: String?
            }
        }

        struct AuditSummary: Encodable, Equatable {
            var since: String
            var total: Int
            var byKind: [String: [String: Int]]
            var lastEventAt: String?
            /// Hash-chain state of audit.jsonl; nil when it cannot be read.
            var chainIntact: Bool?
            var chainHead: String?
        }

        struct Sandbox: Encodable, Equatable {
            var platform: String
            var mcpSandbox: Bool
            var peerTrustInstalled: Bool
        }

        var schema: String
        var generatedAt: String
        var rv: Product
        var host: Host
        var managed: ManagedRun.Status
        var config: [ConfigFile]
        var mcp: MCPSummary
        var secrets: SecretSummary
        var audit: AuditSummary
        var sandbox: Sandbox

        /// Healthy enough for a fleet dashboard to show green.
        var compliant: Bool {
            managed.state != "invalid" && mcp.ok && secrets.error == nil
                && secrets.items.allSatisfy { $0.policyViolation == nil }
                && audit.chainIntact != false
        }
    }

    static func build(_ inputs: Inputs) -> Report {
        let directory = inputs.configDirectory
        let files: [URL] = [
            MCPConfiguration.fileURL(configDirectory: directory),
            directory.appendingPathComponent(SecretsConfiguration.fileName),
            RVPolicyPaths.policyFile(inConfigDir: directory),
            RVPolicyPaths.allowlistFile(inConfigDir: directory),
            RVPolicyPaths.denylistFile(inConfigDir: directory),
            RVPolicyPaths.typedRulesFile(inConfigDir: directory),
            RVPolicyPaths.agentDefinitionsFile(inConfigDir: directory),
            RVPolicyPaths.runtimeResourcesFile(inConfigDir: directory),
        ]
        let config = files.map { url in
            let hash = RVFileDigest.sha256HexOfFile(atPath: url.path, maxBytes: 16 * 1024 * 1024)
            return Report.ConfigFile(file: url.lastPathComponent, present: hash != nil, sha256: hash)
        }
        return Report(
            schema: schema,
            generatedAt: iso8601(inputs.now),
            rv: Report.Product(version: ProductVersion.semver, platform: platform),
            host: Report.Host(name: inputs.hostName, user: inputs.userName, uid: inputs.userID),
            managed: ManagedRun.status(inputs.managed, directory: inputs.managedDirectory),
            config: config,
            mcp: mcpSummary(inputs),
            secrets: secretSummary(inputs),
            audit: auditSummary(inputs),
            sandbox: Report.Sandbox(
                platform: platform,
                mcpSandbox: inputs.fileExists(MCPSandbox.sandboxExec),
                peerTrustInstalled: inputs.fileExists("/Library/Application Support/RV/peer-trust.json")))
    }

    static func mcpSummary(_ inputs: Inputs) -> Report.MCPSummary {
        let environment = MCPEnvironment(
            configDirectory: inputs.configDirectory, home: inputs.home, processEnvironment: inputs.processEnvironment,
            keychain: SecretKeychainWriter(store: { _, _, _ in false }, delete: { _, _ in false }),
            managed: inputs.managed,
            approvalKeys: inputs.approvalKeys)
        switch MCPRun.configuration(environment) {
        case .failure(let failure):
            return Report.MCPSummary(ok: false, error: failure.message, servers: 0, counts: [:], failing: [], plaintextCredentials: 0)
        case .success(let configuration):
            let report = MCPRun.report(
                environment, project: nil, configuration: configuration, rvExecutable: MCPExecutable.currentPath())
            var counts: [String: Int] = [:]
            for row in report.rows { counts[row.status, default: 0] += 1 }
            return Report.MCPSummary(
                ok: report.passes,
                error: mcpError(report),
                servers: report.servers,
                counts: counts,
                failing: report.failing.map {
                    .init(host: $0.host, name: $0.name, status: $0.status, config: $0.configPath)
                },
                plaintextCredentials: report.rows.reduce(0) { $0 + $1.plaintextCredentials.count })
        }
    }

    static func mcpError(_ report: MCPRun.Report) -> String? {
        let messages = report.problems.map { "\($0.path): \($0.message)" } + [report.integrityProblem].compactMap { $0 }
        return messages.isEmpty ? nil : messages.joined(separator: "; ")
    }

    static func secretSummary(_ inputs: Inputs) -> Report.SecretSummary {
        switch SecretsConfiguration.load(configDirectory: inputs.configDirectory) {
        case .failure(let error):
            return Report.SecretSummary(error: error.message, items: [])
        case .success(let configuration):
            return Report.SecretSummary(error: nil, items: configuration.secrets.map { secret in
                Report.SecretSummary.Item(
                    name: secret.name, source: secret.source.kind, delivery: secret.delivery.kind,
                    policyViolation: inputs.managed.invalidReason
                        ?? SecretOrganizationRules.violation(secret, policy: inputs.managed.policy))
            })
        }
    }

    static func auditSummary(_ inputs: Inputs) -> Report.AuditSummary {
        let since = inputs.now.addingTimeInterval(-86_400)
        let events = AuditLedger(configDirectory: inputs.configDirectory).events(AuditFilter(since: since))
        var byKind: [String: [String: Int]] = [:]
        for event in events { byKind[event.kind.rawValue, default: [:]][event.decision.rawValue, default: 0] += 1 }
        let chain = AuditChain.verify(fileURL: AuditLog.fileURL(configDirectory: inputs.configDirectory))
        return Report.AuditSummary(
            since: iso8601(since), total: events.count, byKind: byKind, lastEventAt: events.last.map { iso8601($0.time) },
            chainIntact: (try? chain.get())?.isIntact, chainHead: (try? chain.get())?.head)
    }

    static func text(_ report: Report) -> String {
        var lines = [
            "rv \(report.rv.version) on \(report.host.name) (\(report.host.user)): "
                + (report.compliant ? "compliant" : "NOT compliant"),
            "",
            ManagedRun.statusText(report.managed).trimmingCharacters(in: .newlines),
        ]
        if let error = report.mcp.error, report.mcp.ok == false, report.mcp.counts.isEmpty {
            lines.append("mcp: \(error)")
        } else {
            let counts = report.mcp.counts.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }
            lines.append("mcp: \(report.mcp.ok ? "ok" : "FAIL"), \(report.mcp.servers) gateway servers; "
                + (counts.isEmpty ? "no host entries" : counts.joined(separator: ", ")))
            lines += report.mcp.failing.map { "  \($0.status)  \($0.name)  \($0.host)" }
            if let error = report.mcp.error { lines.append("  " + error) }
            if report.mcp.plaintextCredentials > 0 {
                lines.append("  \(report.mcp.plaintextCredentials) plaintext credential(s) in host configs")
            }
        }
        if let error = report.secrets.error {
            lines.append("secrets: \(error)")
        } else {
            lines.append("secrets: \(report.secrets.items.count) defined")
            lines += report.secrets.items.compactMap { item in item.policyViolation.map { "  \(item.name): \($0)" } }
        }
        lines.append("audit (24h): \(report.audit.total) events" + (report.audit.lastEventAt.map { ", last \($0)" } ?? ""))
        let present = report.config.filter(\.present).map(\.file)
        lines.append("config: " + (present.isEmpty ? "none" : present.joined(separator: ", ")))
        return lines.joined(separator: "\n") + "\n"
    }

    static func json(_ report: Report) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(report), let text = String(data: data, encoding: .utf8) else { return "{}\n" }
        return text + "\n"
    }

    static var platform: String {
        #if os(macOS)
        "macos"
        #elseif os(Linux)
        "linux"
        #else
        "other"
        #endif
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

struct ReportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "report",
        abstract: "Summarize this machine's governance posture (for MDM collection).")

    @OptionGroup var format: FormatFlags

    @Flag(help: "Exit 1 when the machine is not compliant.") var strict = false

    func run() throws {
        let ctx = CommandContext.current(command: "report", format: format)
        let home = try ctx.requireHome()
        let configDirectory = RVPolicyPaths.configDirectory(home: home)
        let report = ReportRun.build(ReportRun.Inputs(
            configDirectory: configDirectory,
            home: URL(fileURLWithPath: home.rawValue, isDirectory: true),
            processEnvironment: ProcessInfo.processInfo.environment,
            managed: ManagedRun.installed(home: home),
            managedDirectory: ManagedPolicyLocation.installedDirectory,
            now: Date(),
            hostName: ProcessInfo.processInfo.hostName,
            userName: ProcessInfo.processInfo.environment["USER"] ?? NSUserName(),
            userID: getuid(),
            approvalKeys: .live(configDirectory: configDirectory, home: home.rawValue)))
        ctx.writeStdout(ctx.explicitRobot ? ReportRun.json(report) : ReportRun.text(report))
        if strict, report.compliant == false { throw ExitCode(1) }
    }
}
