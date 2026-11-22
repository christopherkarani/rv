#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Foundation
import RVPolicy
import Testing
@testable import RVIsolation
@testable import RVMCP

@Suite("rv mcp serve refuses inside the MCP protocol")
struct MCPServeRefusalTests {
    private let untrusted = MCPServeRefusal(
        servers: ["wax"], cause: .untrusted,
        log: "mcp.json was edited outside rv (no rv signature); review it, then run `rv mcp trust`; not launching MCP servers")

    @Test func agentHearsWhatIsOffThatNothingRanAndTheFix() {
        #expect(untrusted.agentMessage == "✕ wax is off · mcp.json is untrusted · nothing ran\n→ ask your user: rv mcp trust")
        let gateway = MCPServeRefusal(servers: [], cause: .configurationUnusable, log: "x")
        #expect(gateway.agentMessage == "✕ rv's MCP gateway is off · rv can't use its MCP setup · nothing ran\n→ ask your user: rv mcp check")
        let many = MCPServeRefusal(servers: ["a", "b", "c", "d", "e"], cause: .trustUnavailable, log: "x")
        #expect(many.agentMessage.hasPrefix("✕ a, b, c +2 more are off · "))
        #expect(many.next == "sudo rv mcp custodian install")
    }

    @Test func initializeGetsTheRefusalAsAJSONRPCError() throws {
        let line = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#.utf8)
        let answer = try #require(untrusted.answer(line))
        #expect(answer["id"] == .int(1))
        #expect(answer["result"] == nil)
        #expect(answer["error"]?["code"] == .int(MCPServeRefusal.errorCode))
        #expect(answer["error"]?["message"]?.stringValue == untrusted.agentMessage)
        #expect(answer["error"]?["data"]?["rv"]?["state"]?.stringValue == "off")
        #expect(answer["error"]?["data"]?["rv"]?["next"]?.stringValue == "rv mcp trust")
        // Every later request too, whatever its id type.
        let list = try #require(untrusted.answer(Data(#"{"jsonrpc":"2.0","id":"x","method":"tools/list"}"#.utf8)))
        #expect(list["id"] == .string("x"))
    }

    @Test func notificationsAndResponsesGetNoAnswerAndGarbageGetsAParseError() throws {
        #expect(untrusted.answer(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)) == nil)
        #expect(untrusted.answer(Data(#"{"jsonrpc":"2.0","id":3,"result":{}}"#.utf8)) == nil)
        #expect(untrusted.answer(Data(#"[1,2]"#.utf8)) == nil)
        let garbage = try #require(untrusted.answer(Data("not json".utf8)))
        #expect(garbage["error"]?["code"] == .int(-32700))
        #expect(garbage["id"] == .null)
    }

    /// The agent's channel is the model's context: resolver and sandbox
    /// detail stays in the owner's log.
    @Test func theAgentNeverSeesTheOwnersDetail() {
        let cause = MCPServeRefusal.cause(
            of: .secretUnavailable(server: "wax", secret: "WAX_TOKEN", reason: "provider printed sk-live-123"))
        let refusal = MCPServeRefusal(servers: ["wax"], cause: cause, log: "wax could not read secret WAX_TOKEN: sk-live-123")
        #expect(refusal.agentMessage.contains("WAX_TOKEN"))
        #expect(refusal.agentMessage.contains("sk-live") == false)
        #expect(refusal.errorResponse(id: .int(1)).compactText.contains("sk-live") == false)
        let sandbox = MCPServeRefusal(
            servers: ["wax"], cause: MCPServeRefusal.cause(of: .sandbox("/Users/me/secret-dir cannot be read")), log: "x")
        #expect(sandbox.agentMessage.contains("secret-dir") == false)
        #expect(sandbox.next == "rv doctor")
    }

    @Test func namesAreEscapedBeforeTheAgentSeesThem() {
        let hostile = MCPServeRefusal(servers: ["wax\u{1B}[2J\u{202E}"], cause: .unknownServer("wax\u{1B}[2J"), log: "x")
        let text = hostile.errorResponse(id: .int(1)).compactText
        #expect(text.contains("\u{1B}") == false)
        #expect(text.contains("\u{202E}") == false)
        #expect(hostile.agentMessage.unicodeScalars.contains { $0 == "\u{1B}" } == false)
    }

    @Test func everyRefusedPlanIsOffAndAnyStartableServerIsNot() {
        let configuration = MCPConfiguration(servers: [
            MCPServerDefinition(name: "wax", command: "w"),
            MCPServerDefinition(name: "open", command: "o", sandbox: MCPSandboxPolicy(network: true)),
        ])
        let launch = MCPUpstreamLaunch(server: "ok", executable: "/usr/bin/env", arguments: ["true"], environment: [:])
        func cause(_ planned: [MCPUpstreamConnection]) -> MCPServeRefusal.Cause? {
            MCPServeRefusal.cause(ofPlanned: planned, configuration: configuration)
        }
        #expect(cause([.refused(server: "wax", .sandbox("needs a sandbox"))]) == .noSandbox("wax"))
        #expect(cause([.refused(server: "open", .sandbox("stays off the network"))]) == .openNetwork("open"))
        #expect(cause([.refused(server: "p", .placeholder(.unsupportedPlatform)), .refused(server: "wax", .sandbox("x"))])
            == .placeholders(server: "p", .unsupportedPlatform))
        #expect(cause([.refused(server: "p", .placeholder(.unknownSecret("K")))]) == .secretUndefined(server: "p", secret: "K"))
        #expect(cause([.refused(server: "wax", .sandbox("x")), .process(launch)]) == nil)
        #expect(cause([]) == nil)
    }

    /// Every off state names its own fix; none sends the person to a
    /// command that only repeats the problem.
    @Test func eachCauseHasARealFix() {
        func next(_ cause: MCPServeRefusal.Cause) -> String { MCPServeRefusal(servers: ["wax"], cause: cause, log: "").next }
        #expect(next(.noSandbox("wax")) == #"add "sandbox": {"network": false} to wax in mcp.json, then rv mcp trust"#)
        #expect(next(.openNetwork("wax")) == "list the hosts wax needs in sandbox.hosts in mcp.json, then rv mcp trust")
        #expect(next(.secretUndefined(server: "wax", secret: "WAX_TOKEN")) == "rv secrets set WAX_TOKEN")
        #expect(next(.placeholders(server: "wax", .unsupportedPlatform)) == "fix wax's placeholders in mcp.json, then rv mcp trust")
        #expect(next(.cageUnavailable) == "rv doctor")
        // Lease detail is the gateway's, not mcp.json's: it stays out of the agent's text.
        let lease = MCPServeRefusal(servers: ["wax"], cause: .placeholders(server: "wax", .leaseFailed("socket /tmp/x: EACCES")), log: "")
        #expect(lease.agentMessage.contains("/tmp/x") == false)
    }

    private static let secretsJSON = """
        {"version":1,"secrets":[
          {"name":"WAX_TOKEN","source":{"keychain":{"service":"rv.secrets","account":"WAX_TOKEN"}},"delivery":{"environment":{}}},
          {"name":"API_KEY","source":{"keychain":{"service":"rv.secrets","account":"API_KEY"}},
           "delivery":{"gateway":{"upstream":"https://api.example.com/v1","baseURLEnv":"API_BASE_URL"}}}
        ]}
        """

    private static func secrets() throws -> SecretsConfiguration {
        try SecretsConfiguration.decode(Data(secretsJSON.utf8)).get()
    }

    private static func configuration() throws -> MCPConfiguration {
        let sealed = MCPSandboxPolicy(network: false)
        return MCPConfiguration(servers: [
            MCPServerDefinition(name: "bare", command: "b"),
            MCPServerDefinition(name: "open", command: "o", sandbox: MCPSandboxPolicy(network: true)),
            MCPServerDefinition(name: "sealed", command: "c", sandbox: sealed),
            MCPServerDefinition(name: "keyed", command: "k", secrets: ["WAX_TOKEN": "WAX_TOKEN"], sandbox: sealed),
            MCPServerDefinition(name: "missing", command: "m", secrets: ["TOKEN": "NOPE"], sandbox: sealed),
            MCPServerDefinition(name: "argmissing", command: "m", args: ["--key=${secret:GONE}"], sandbox: sealed),
            MCPServerDefinition(name: "held", command: "h", sandbox: sealed, placeholders: ["API_KEY"]),
            MCPServerDefinition(name: "unknownheld", command: "h", sandbox: sealed, placeholders: ["NOPE"]),
            MCPServerDefinition(name: "envheld", command: "h", sandbox: sealed, placeholders: ["WAX_TOKEN"]),
            MCPServerDefinition(name: "bareheld", command: "h", placeholders: ["API_KEY"]),
            MCPServerDefinition(name: "web", remote: MCPRemoteServer(url: try #require(URL(string: "https://mcp.example/mcp")))),
            MCPServerDefinition(name: "webmissing", remote: MCPRemoteServer(
                url: try #require(URL(string: "https://mcp.example/mcp")), headers: ["Authorization": "Bearer ${secret:NOPE}"])),
        ])
    }

    @Test func listJudgesAServerOffExactlyWhenServeWouldRefuseIt() throws {
        let configuration = try Self.configuration()
        let secrets = try Self.secrets()
        func cause(
            _ name: String, _ integrity: MCPIntegrityStatus = .trusted, cage: Bool, placeholders: Bool = true,
            secrets known: SecretsConfiguration?? = .none
        ) -> MCPServeRefusal.Cause? {
            MCPServeRefusal.cause(
                serving: name, configuration: configuration, integrity: integrity,
                secrets: known ?? secrets, requireSandbox: cage, placeholdersSupported: placeholders)
        }
        for name in ["bare", "sealed", "web"] {
            #expect(cause(name, .untrusted("no rv signature"), cage: true) == .untrusted)
            #expect(cause(name, .unsupportedPlatform, cage: false) == .trustUnavailable)
            #expect(cause(name, cage: true, secrets: .some(nil)) == .secretsUnusable)
        }
        #expect(cause("bare", cage: true) == .noSandbox("bare"))
        #expect(cause("open", cage: true) == .openNetwork("open"))
        #expect(cause("sealed", cage: true) == nil)
        #expect(cause("keyed", cage: true) == nil)
        #expect(cause("web", cage: true) == nil)
        // A secret secrets.json does not define, by `secrets`, in args, or in a remote header.
        #expect(cause("missing", cage: true) == .secretUndefined(server: "missing", secret: "NOPE"))
        #expect(cause("argmissing", cage: true) == .secretUndefined(server: "argmissing", secret: "GONE"))
        #expect(cause("webmissing", cage: true) == .secretUndefined(server: "webmissing", secret: "NOPE"))
        // Placeholders: the planner's own checks.
        #expect(cause("held", cage: true) == nil)
        #expect(cause("held", cage: true, placeholders: false) == .placeholders(server: "held", .unsupportedPlatform))
        #expect(cause("held", cage: false) == .cageUnavailable)
        #expect(cause("unknownheld", cage: true) == .secretUndefined(server: "unknownheld", secret: "NOPE"))
        #expect(cause("envheld", cage: true) == .placeholders(server: "envheld", .environmentDelivery("WAX_TOKEN")))
        #expect(cause("bareheld", cage: true) == .noSandbox("bareheld"))
        // No cage on this host: a bare server runs uncaged; one that asks
        // for a sandbox is refused.
        #expect(cause("bare", cage: false) == nil)
        #expect(cause("sealed", cage: false) == .cageUnavailable)
        #expect(cause("web", .noConfiguration, cage: false) == nil)

        var managed = configuration
        managed.managed = try ManagedPolicy.decode(Data(#"{"version":1,"mcp":{"requireSandbox":true}}"#.utf8)).get()
        #expect(MCPServeRefusal.cause(
            serving: "bare", configuration: managed, integrity: .trusted, secrets: secrets, requireSandbox: false)
            == .cageUnavailable)
        #expect(MCPEntryStatus.off.isAcceptable == false)
    }

    /// The list's answer and the planner's agree, server by server: what
    /// list calls off, serve refuses; what it would start, serve plans.
    @Test func listAndThePlannerAgree() throws {
        let configuration = try Self.configuration()
        let secrets = try Self.secrets()
        let resolver = SecretResolver { _ in .success(SecretValue("value-0123456789")!) }
        for cage in [true, false] {
            let hook: (MCPServerDefinition, MCPUpstreamLaunch, MCPCageReach) -> Result<MCPUpstreamLaunch, MCPLaunchError> = {
                definition, launch, _ in
                MCPSandbox.refusesUncaged(definition, enforced: cage) ? .failure(.sandbox("uncaged")) : .success(launch)
            }
            for server in configuration.servers where server.placeholders.isEmpty {
                let listed = MCPServeRefusal.cause(
                    serving: server.name, configuration: configuration, integrity: .trusted, secrets: secrets,
                    requireSandbox: cage)
                let planned = MCPLaunchPlanner.plan(
                    servers: [server.name], configuration: configuration, secrets: secrets, resolver: resolver,
                    baseEnvironment: [:], requireSandbox: cage, sandbox: hook)
                let serveRefuses: Bool = switch planned {
                case .failure: true
                case .success(let launches): MCPServeRefusal.cause(ofPlanned: launches.map(\.1), configuration: configuration) != nil
                }
                #expect((listed != nil) == serveRefuses, "\(server.name) cage=\(cage): list \(String(describing: listed))")
            }
            for server in configuration.servers where server.placeholders.isEmpty == false {
                let listed = MCPServeRefusal.cause(
                    serving: server.name, configuration: configuration, integrity: .trusted, secrets: secrets,
                    requireSandbox: cage, placeholdersSupported: true)
                guard listed != nil else { continue }
                let planned = MCPLaunchPlanner.plan(
                    servers: [server.name], configuration: configuration, secrets: secrets, resolver: resolver,
                    baseEnvironment: [:], requireSandbox: cage, sandbox: hook,
                    placeholders: MCPPlaceholderLeasing(
                        platformSupported: true, capability: { nil }, lease: { _, _ in .failure(.gatewayUnavailable) }))
                let serveRefuses: Bool = switch planned {
                case .failure: true
                case .success(let launches): MCPServeRefusal.cause(ofPlanned: launches.map(\.1), configuration: configuration) != nil
                }
                #expect(serveRefuses, "\(server.name) cage=\(cage): list says off, serve would plan it")
            }
        }
    }

    @Test func overlongAndNonScalarIDsAreAnsweredWithNull() throws {
        let long = String(repeating: "x", count: MCPServeRefusal.maximumIDBytes + 1)
        let answer = try #require(untrusted.answer(Data(#"{"jsonrpc":"2.0","id":"\#(long)","method":"initialize"}"#.utf8)))
        #expect(answer["id"] == .null)
        let object = try #require(untrusted.answer(Data(#"{"jsonrpc":"2.0","id":{"a":1},"method":"initialize"}"#.utf8)))
        #expect(object["id"] == .null)
        let fine = try #require(untrusted.answer(Data(#"{"jsonrpc":"2.0","id":"abc","method":"initialize"}"#.utf8)))
        #expect(fine["id"] == .string("abc"))
    }

    // MARK: - The stdio responder

    private func pipePair() throws -> (read: Int32, write: Int32) {
        var fds: [Int32] = [0, 0]
        try #require(pipe(&fds) == 0)
        return (fds[0], fds[1])
    }

    private static func send(_ fd: Int32, _ text: String) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    private func readAll(_ fd: Int32) -> [JSONValue] {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { break }
            data.append(contentsOf: buffer[0..<n])
        }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { try? JSONValue.parse(String($0)) }
    }

    @Test func responderAnswersEachRequestUntilTheClientCloses() throws {
        let input = try pipePair()
        let output = try pipePair()
        Self.send(input.write, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"# + "\r\n")
        Self.send(input.write, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"# + "\n\n")
        Self.send(input.write, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        close(input.write)
        let answered = MCPRefusalResponder.serve(untrusted, input: input.read, output: output.write, idleSeconds: 5)
        close(input.read)
        close(output.write)
        let lines = readAll(output.read)
        close(output.read)
        #expect(answered == 2)
        #expect(lines.map { $0["id"] } == [.int(1), .int(2)])
        #expect(lines.allSatisfy { $0["error"]?["message"]?.stringValue == untrusted.agentMessage })
    }

    @Test func responderStopsAfterItsAnswerBudget() throws {
        let input = try pipePair()
        let output = try pipePair()
        let request = #"{"jsonrpc":"2.0","id":7,"method":"ping"}"# + "\n"
        Self.send(input.write, String(repeating: request, count: MCPRefusalResponder.maximumLines + 5))
        let answered = MCPRefusalResponder.serve(untrusted, input: input.read, output: output.write, idleSeconds: 5)
        close(input.write)
        close(input.read)
        close(output.write)
        #expect(answered == MCPRefusalResponder.maximumLines)
        #expect(readAll(output.read).count == MCPRefusalResponder.maximumLines)
        close(output.read)
    }

    /// Empty lines and notifications count too, so trickling them keeps
    /// nothing alive past the budget.
    @Test func everyLineCountsTowardTheBudget() throws {
        let input = try pipePair()
        let output = try pipePair()
        let note = #"{"jsonrpc":"2.0","method":"notifications/x"}"# + "\n"
        Self.send(input.write, String(repeating: "\n", count: 20) + String(repeating: note, count: 20)
            + #"{"jsonrpc":"2.0","id":1,"method":"ping"}"# + "\n")
        let answered = MCPRefusalResponder.serve(untrusted, input: input.read, output: output.write, idleSeconds: 5)
        #expect(answered == 0)
        for fd in [input.read, input.write, output.read, output.write] { close(fd) }
    }

    /// A client that trickles bytes without a newline is cut off at the
    /// overall deadline, not kept alive by each byte.
    @Test func aTricklingClientIsCutOffAtTheDeadline() throws {
        let input = try pipePair()
        let output = try pipePair()
        let writer = Thread {
            for _ in 0..<40 {
                Self.send(input.write, " ")
                usleep(100_000)
            }
        }
        writer.start()
        let started = Date()
        let answered = MCPRefusalResponder.serve(
            untrusted, input: input.read, output: output.write, idleSeconds: 5, totalSeconds: 1)
        #expect(answered == 0)
        #expect(Date().timeIntervalSince(started) < 3)
        while writer.isFinished == false { usleep(50_000) }
        for fd in [input.read, input.write, output.read, output.write] { close(fd) }
    }

    /// A reader that never reads stalls a blocking stdout; the write gives
    /// up at its deadline instead of hanging serve.
    @Test func aStalledReaderEndsTheWrite() throws {
        let output = try pipePair()
        // Fill the pipe so the next write would block.
        let flags = fcntl(output.write, F_GETFL)
        _ = fcntl(output.write, F_SETFL, flags | O_NONBLOCK)
        var chunk = [UInt8](repeating: 0x61, count: 4096)
        while chunk.withUnsafeMutableBytes({ write(output.write, $0.baseAddress, $0.count) }) > 0 {}
        _ = fcntl(output.write, F_SETFL, flags)
        let started = Date()
        #expect(MCPRefusalResponder.writeLine(output.write, "{}", seconds: 1) == false)
        #expect(Date().timeIntervalSince(started) < 3)
        close(output.read)
        close(output.write)
    }

    @Test func responderGivesUpOnAnIdleClient() throws {
        let input = try pipePair()
        let output = try pipePair()
        let started = Date()
        let answered = MCPRefusalResponder.serve(untrusted, input: input.read, output: output.write, idleSeconds: 1)
        #expect(answered == 0)
        #expect(Date().timeIntervalSince(started) < 10)
        for fd in [input.read, input.write, output.read, output.write] { close(fd) }
    }

    @Test func responderDropsAnOversizedLineWhole() throws {
        let input = try pipePair()
        let output = try pipePair()
        let writer = Thread {
            let huge = #"{"jsonrpc":"2.0","id":9,"method":"x","params":""#
                + String(repeating: "a", count: MCPRefusalResponder.maximumLineBytes + 10) + "\"}\n"
            Self.send(input.write, huge)
            Self.send(input.write, #"{"jsonrpc":"2.0","id":10,"method":"tools/list"}"# + "\n")
            close(input.write)
        }
        writer.start()
        let answered = MCPRefusalResponder.serve(untrusted, input: input.read, output: output.write, idleSeconds: 5)
        close(input.read)
        close(output.write)
        let lines = readAll(output.read)
        close(output.read)
        #expect(answered == 1)
        #expect(lines.map { $0["id"] } == [.int(10)])
    }

    @Test func responderStopsWhenTheClientIsGone() throws {
        let input = try pipePair()
        let output = try pipePair()
        close(output.read)
        // As serve does before it answers; left ignored, as the gateway leaves it.
        signal(SIGPIPE, SIG_IGN)
        Self.send(input.write, #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"# + "\n"
            + #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"# + "\n")
        close(input.write)
        let answered = MCPRefusalResponder.serve(untrusted, input: input.read, output: output.write, idleSeconds: 5)
        close(input.read)
        close(output.write)
        #expect(answered == 0)
    }
}
