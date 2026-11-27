#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import ArgumentParser
import Foundation
import RVIsolation
import RVMCP

/// How `rv mcp serve` refuses, and how `rv mcp list` knows it would.
extension MCPServe {
    /// Serve could not start: the owner's line on stderr, then the reason
    /// and its fix as the error to every request the client sends, so the
    /// host shows the agent why instead of an empty pipe. Runs after
    /// `serve` returned: its signal handlers, proxies and placeholder
    /// broker are gone, and nothing was started.
    static func refuse(_ refusal: MCPServeRefusal, ctx: CommandContext) throws -> Never {
        // Through the gateway's stderr writer, so a closed stderr cannot end
        // serve by SIGPIPE before it says why it stops; a test's captured
        // output still gets the line.
        let line = "rv mcp serve: \(refusal.log)\n"
        guard CLIProcess.context?.output == nil else { try ctx.emit(stdout: "", stderr: line, exitCode: 1) }
        MCPGatewayRuntime.writeStderrLine(line)
        // A person who ran serve at a terminal has read the line above; only
        // a host's pipe gets the protocol answer.
        if isatty(STDIN_FILENO) == 0 {
            signal(SIGPIPE, SIG_IGN)
            MCPRefusalResponder.serve(refusal)
        }
        throw ExitCode(1)
    }

    /// The refusal when no planned server would start (each was refused on
    /// its own); nil when any would. Serve then answers in the protocol
    /// instead of serving an empty tool list with the reasons on stderr only.
    static func nothingStarts(
        _ planned: [MCPUpstreamConnection], configuration: MCPConfiguration, servers: [String]
    ) -> MCPServeRefusal? {
        guard let cause = MCPServeRefusal.cause(ofPlanned: planned, configuration: configuration) else { return nil }
        let reasons = planned.compactMap { connection -> String? in
            guard case .refused(let server, let refusal) = connection else { return nil }
            return "not starting MCP server \(MCPDisplayedText.field(server)): \(refusal.message)"
        }
        return MCPServeRefusal(servers: servers, cause: cause, log: reasons.joined(separator: "; "))
    }
}

extension MCPRun {
    /// Why serve would refuse the server a governed host entry launches;
    /// nil when it would start it. `secrets` nil: secrets.json is unreadable.
    static func offRefusal(
        _ entry: MCPHostEntry, configuration: MCPConfiguration, integrity: MCPIntegrityStatus,
        secrets: SecretsConfiguration?
    ) -> MCPServeRefusal? {
        guard let server = entry.governedServer else { return nil }
        return MCPServeRefusal.cause(
            serving: server, configuration: configuration, integrity: integrity, secrets: secrets
        ).map { MCPServeRefusal(servers: [server], cause: $0, log: "") }
    }
}
