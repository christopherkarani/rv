import ArgumentParser
import Foundation
import RVIPC

/// Operator launch plumbing (Step 4): propose an identity launch for review
/// and poll its status. Proposals are untrusted routing hints; nothing
/// launches until the workspace host prepares a description and the device
/// owner authorizes it in RVOperatorUI.
struct Operator: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "operator",
        abstract: "Propose and poll identity launches (review required).",
        subcommands: [OperatorPropose.self, OperatorProposalStatus.self]
    )

    init() {}
}

struct OperatorPropose: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "propose",
        abstract: "Propose one identity launch for operator review."
    )

    @Option(help: "Project path hint used to route to a registered host.")
    var workspace: String

    @Option(name: .customLong("hostID"), help: "Host routing hint (UUID).")
    var hostID: String?

    @Option(name: .customLong("sessionID"), help: "Workspace-session routing hint (UUID).")
    var sessionID: String?

    @Option(help: "Proposal kind: named or custom.")
    var kind: String = "named"

    @Option(help: "Agent definition ID (named only).")
    var definition: String?

    @Option(help: "Executable path (custom only).")
    var executable: String?

    @Option(help: "Expected content digest hex (custom only).")
    var digest: String?

    @Argument(help: "Arguments recorded for review (never trusted).")
    var arguments: [String] = []

    init() {}

    func run() async throws {
        let params = try buildParams()
        let client = ServiceClient()
        switch await client.proposeLaunch(params) {
        case .success(let reply):
            print("operation \(reply.operationID.uuidString) status \(reply.status)")
        case .failure(let error):
            FileHandle.standardError.write(
                Data("rv operator propose: \(describe(error))\n".utf8))
            throw ExitCode.failure
        }
    }

    func describe(_ error: ServiceClient.ServiceCommandError) -> String {
        switch error {
        case .noTransport:
            return "service unreachable"
        case .service(let reason):
            return reason
        case .transport(let reason):
            return reason
        }
    }

    func buildParams() throws -> ProposeLaunchParams {
        func uuid(_ text: String?, flag: String) throws -> UUID? {
            guard let text else { return nil }
            guard let id = UUID(uuidString: text) else {
                throw ValidationError("--\(flag) must be a UUID")
            }
            return id
        }
        guard kind == "named" || kind == "custom" else {
            throw ValidationError("--kind must be named or custom")
        }
        if kind == "named" {
            guard definition != nil else {
                throw ValidationError("--definition is required for named proposals")
            }
            guard executable == nil, digest == nil else {
                throw ValidationError("--executable/--digest are custom-only")
            }
        } else {
            guard executable != nil, digest != nil else {
                throw ValidationError("--executable and --digest are required for custom proposals")
            }
            guard definition == nil else {
                throw ValidationError("--definition is named-only")
            }
        }
        return ProposeLaunchParams(
            workspace: workspace,
            hostID: try uuid(hostID, flag: "hostID"),
            workspaceSessionID: try uuid(sessionID, flag: "sessionID"),
            kind: kind,
            definitionID: definition,
            executable: executable,
            expectedDigest: digest,
            arguments: arguments,
            io: .discard)
    }
}

struct OperatorProposalStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "proposal-status",
        abstract: "Poll one proposal's review status."
    )

    @Argument(help: "Operation ID from propose.")
    var operationID: String

    init() {}

    func run() async throws {
        guard let id = UUID(uuidString: operationID) else {
            throw ValidationError("operation ID must be a UUID")
        }
        let client = ServiceClient()
        switch await client.proposalStatus(operationID: id) {
        case .success(let reply):
            var line = "operation \(reply.operationID.uuidString) status \(reply.status)"
            if let launchResult = reply.launchResult {
                line += " launch \(launchResult)"
            }
            if let runtime = reply.runtimeSessionID {
                line += " runtime \(runtime.uuidString)"
            }
            if let instance = reply.agentInstanceID {
                line += " instance \(instance.uuidString)"
            }
            print(line)
        case .failure(let error):
            FileHandle.standardError.write(
                Data("rv operator proposal-status: \(describe(error))\n".utf8))
            throw ExitCode.failure
        }
    }

    func describe(_ error: ServiceClient.ServiceCommandError) -> String {
        switch error {
        case .noTransport:
            return "service unreachable"
        case .service(let reason):
            return reason
        case .transport(let reason):
            return reason
        }
    }
}
