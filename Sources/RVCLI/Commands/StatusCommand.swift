import ArgumentParser
import Foundation
import RVDomain
import RVHistory
import RVPolicy

/// `rv status`: one screen that says whether rv is protecting this
/// machine (rvd, each host's mode, the latest denial) and where to look
/// next. Read-only; it composes `rv service status`, `rv host list` and
/// `rv blocks` rather than probing anything of its own.
enum StatusRun {
    struct HomeMissing: Error, CustomStringConvertible {
        var description: String { "home directory not found" }
    }

    struct Host: Encodable, Equatable {
        let host: String
        let mode: String
        let wiring: String
    }

    struct LastBlock: Encodable, Equatable {
        let timestamp: Date
        let host: String
        let rule: String
        let observed: Bool
    }

    struct Document: Encodable, Equatable {
        let schema = "rv.status.v1"
        let version: String
        let service: String
        let serviceError: String?
        let guardMode: String?
        let hosts: [Host]
        let hostsError: String?
        let lastBlock: LastBlock?

        enum CodingKeys: String, CodingKey {
            case schema, version, service, hosts
            case serviceError = "service_error"
            case guardMode = "guard"
            case hostsError = "hosts_error"
            case lastBlock = "last_block"
        }

        /// Everything rv needs is up: rvd answers and no host's hook is broken.
        var healthy: Bool {
            service == "running" && hostsError == nil && hosts.contains { $0.wiring == "broken" } == false
        }
    }

    static func document(
        version: String = ProductVersion.semver,
        service: ServiceStatusReport,
        hosts: Result<HostModeRun.ListDocument, any Error>,
        lastBlock: DenialLedgerRecord?
    ) -> Document {
        let listed: HostModeRun.ListDocument?
        let hostsError: String?
        switch hosts {
        case .success(let document):
            listed = document
            hostsError = nil
        case .failure(let error):
            listed = nil
            hostsError = "\(error)"
        }
        return Document(
            version: version,
            service: service.state,
            serviceError: service.lastError,
            guardMode: listed?.guardMode,
            // Hosts that are not installed on this machine are noise here;
            // `rv host list` still shows every one.
            hosts: (listed?.hosts ?? [])
                .filter { $0.wiring != DoctorHostState.missing.rawValue }
                .map { Host(host: $0.host, mode: $0.mode, wiring: $0.wiring) },
            hostsError: hostsError,
            lastBlock: lastBlock.map {
                LastBlock(
                    timestamp: $0.timestamp, host: $0.host.rawValue,
                    rule: $0.ruleID.rawValue, observed: $0.observed)
            }
        )
    }

    static func text(_ document: Document, now: Date = Date()) -> String {
        var lines = ["rv \(document.version)"]
        var service = "service   \(document.service == "running" ? "running" : document.service)"
        if let error = document.serviceError, document.service != "running" {
            service += " (\(DisplayedText.field(error)))"
        }
        lines.append(service)
        if let guardMode = document.guardMode {
            lines.append("guard     \(guardMode)")
        }
        if let error = document.hostsError {
            lines.append("hosts     unknown (\(DisplayedText.field(error)))")
        } else if document.hosts.isEmpty {
            lines.append("hosts     none detected; run rv setup after installing an agent")
        } else {
            let width = document.hosts.map(\.host.count).max() ?? 0
            for (index, host) in document.hosts.enumerated() {
                let label = index == 0 ? "hosts     " : "          "
                let name = host.host.padding(toLength: width, withPad: " ", startingAt: 0)
                let wiring = host.wiring == "wired" ? "" : "  (hook \(host.wiring))"
                lines.append(label + name + "  " + host.mode + wiring)
            }
        }
        if let last = document.lastBlock {
            let verb = last.observed ? "would have blocked" : "blocked"
            lines.append(
                "last      \(verb) \(DisplayedText.field(last.rule)) on \(last.host), \(ago(last.timestamp, now: now))")
        } else {
            lines.append("last      no denials recorded")
        }
        lines.append("")
        if document.service != "running" {
            lines.append("Next: rv doctor (rvd is not answering, so agent commands are refused)")
        } else if document.hosts.contains(where: { $0.wiring == "broken" }) {
            lines.append("Next: rv setup (a host hook is broken)")
        } else {
            lines.append("More: rv doctor for a full check, rv blocks for recent denials")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(seconds / 60)m ago"
        case ..<86_400: return "\(seconds / 3600)h ago"
        default: return "\(seconds / 86_400)d ago"
        }
    }
}

struct Overview: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show whether rv is protecting this machine: rvd, each host's mode, the latest denial."
    )

    @OptionGroup
    var format: FormatFlags

    func run() async throws {
        let ctx = CommandContext.current(command: "status", format: format)
        let home = try ctx.requireHome()
        let service = await ServiceClient.probing(home: home).status()
        let hosts: Result<HostModeRun.ListDocument, any Error>
        if let env = SetupEnvironment.live() {
            hosts = Result { try HostModeRun.listDocument(env) }
        } else {
            hosts = .failure(StatusRun.HomeMissing())
        }
        let lastBlock = DenialLedger(
            configDirectory: RVPolicyPaths.configDirectory(home: home)
        ).records(asOf: Date()).first
        let document = StatusRun.document(service: service, hosts: hosts, lastBlock: lastBlock)
        if ctx.explicitRobot {
            ctx.writeStdout(try RobotJSON.encode(document, options: .compactISO8601) + "\n")
        } else {
            ctx.writeStdout(StatusRun.text(document))
        }
        if document.healthy == false {
            throw ExitCode(1)
        }
    }
}

struct VersionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "Print rv's version (same as rv --version)."
    )

    func run() throws {
        CommandContext.writeStdout(ProductVersion.semver + "\n")
    }
}
