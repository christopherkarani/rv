#if os(macOS)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RVDomain
import RVFileStore
import RVPolicy
import Synchronization
import Testing
@testable import RVIsolation

// MARK: - E2E rehearsal (E1-F manual gate, committed as regression)

// What this proves that unit suites cannot: real operator files on disk
// (agent-definitions.json + runtime-resources.json + secrets-providers.json
// + secrets-file.json, all owner-only) load through the real stores; the
// real factory builds the real provider set; a real contained launch injects
// one broker secret into the child environment (observed child-side via a
// file the child writes); an oversized sibling entry drops with a denied
// ledger row; one MCP tool dispatch crosses a real loopback HTTP socket to a
// stub server, with connection credentials resolved through the real broker;
// and the canary values appear NOWHERE in any ledger, audit, log, or stub
// artifact.
//
// "v2" = a definition document carrying the provider-selection field
// (`secretsProvider`). v1 documents without it take the migration path
// (covered by store unit tests); the rehearsal pins the v2 shape.

private enum RehearsalError: Error {
    case stubNotReady
    case waitTimedOut
    case announceFailed
    case activateFailed
    case bindFailed
}

// Fixed greppable canaries (fake secrets). The leak assertions below — and
// the post-run shell grep over the repo — prove these byte strings never
// land in any committed file except this one, nor in any ledger, audit,
// log, or stub artifact the run produces. `seen.txt` (child-observed env)
// holds the canary BY DESIGN and is the only allowed carrier.
private let rehearsalCanary = "E2E-CANARY-9f2b7d1a4c5e"
private let rehearsalConnectionSecret = "E2E-CONN-3c8d2f6a1b9e"
private let rehearsalToolResult = "e2e-tool-result-ok"

/// Minimal MCP loopback stub: validates the envelope shape and the auth
/// headers, logs labels only (address + idempotency key — never header
/// values), and answers one fixed tool result. Binds an ephemeral port and
/// prints it for the parent to consume; no port-picking race.
private let rehearsalStubScript = #"""
import http.server, json, sys
LOG_PATH = sys.argv[1]
RESULT = sys.argv[2]
class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != '/mcp/invoke':
            self.send_response(404)
            self.end_headers()
            return
        length = int(self.headers.get('Content-Length', 0))
        raw = self.rfile.read(length)
        try:
            envelope = json.loads(raw)
            assert {'resource', 'address', 'arguments', 'idempotencyKey'} <= set(envelope)
        except Exception:
            self.send_response(400)
            self.end_headers()
            return
        auth = self.headers.get('Authorization', '')
        conn = self.headers.get('X-RV-Connection-Auth', '')
        if not auth.startswith('Bearer ') or not conn:
            self.send_response(401)
            self.end_headers()
            return
        with open(LOG_PATH, 'a') as handle:
            handle.write('served address=%s key=%s\n' % (envelope['address'], envelope['idempotencyKey']))
        body = RESULT.encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass
server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
print('RV_E2E_PORT=%d' % server.server_port, flush=True)
server.serve_forever()
"""#

private func rehearsalWriteFile(at directory: URL, name: String, text: String, mode: Int = 0o600) throws {
    let url = directory.appendingPathComponent(name)
    try text.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
}

private func rehearsalWaitFor(_ url: URL, timeoutSeconds: TimeInterval = 20) async -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: url.path) {
            return true
        }
        try? await Task.sleep(for: .milliseconds(100))
    }
    return false
}

/// Runs one `accept` on a dedicated thread while the test suspends,
/// mirroring production (the off-pool supervise pump). `accept` blocks in
/// the MCP bridge while the invoke task needs pool threads; awaiting it
/// here keeps the pool free. Local copy of the E1-E helper (that file's
/// helpers are private to it).
private func rehearsalAcceptOffPool(
    session: RuntimeAdmissionSession, bytes: Data
) async -> [RuntimeAdmissionDecision] {
    await withCheckedContinuation { continuation in
        Thread {
            continuation.resume(returning: session.accept(bytes))
        }.start()
    }
}

/// Production-shaped loopback send over live URLSession. No test double:
/// bytes cross a real socket to the stub server above.
private func rehearsalLiveSend(_ http: MCPHTTPRequest) async throws -> MCPHTTPResponse {
    guard let url = URL(string: http.url) else {
        throw MCPTransportError.nonLoopbackTarget
    }
    var request = URLRequest(url: url)
    request.httpMethod = http.method.rawValue
    for (name, value) in http.headers {
        request.setValue(value, forHTTPHeaderField: name)
    }
    request.httpBody = http.body
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
        throw MCPTransportError.remoteFailed(status: 0)
    }
    var headers: [String: String] = [:]
    for (key, value) in httpResponse.allHeaderFields {
        headers["\(key)"] = "\(value)"
    }
    return MCPHTTPResponse(status: httpResponse.statusCode, headers: headers, body: data)
}

// MARK: - Rehearsal world

/// Real files, real stores, real factory, real supervisor, real stub
/// server. Every path below is production code; the only test doubles are
/// the stub MCP server (a real process over a real socket) and the wall
/// clock.
// Not Sendable by design: it owns a live `Process` handle and a
// containment tree, both used linearly by one serialized test.
private struct RehearsalWorld {
    let root: URL
    let configDir: URL
    let mcpAuditDir: URL
    let brokerAuditDir: URL
    let tree: ContainmentTree
    let definition: AgentDefinition
    let providers: [any SecretsProvider]
    let supervisor: WorkspaceSessionSupervisor
    let runtimeLog: URL
    let stub: Process
    let stubLog: URL
    let stubPort: Int

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        configDir = root.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: configDir.path)
        mcpAuditDir = root.appendingPathComponent("mcp-audit", isDirectory: true)
        brokerAuditDir = root.appendingPathComponent("broker-audit", isDirectory: true)
        tree = try ContainmentTree()
        let workspacePath = tree.workspaceURL.path

        // Operator files. The definition is v2: it carries `secretsProvider`
        // explicitly instead of relying on the v1 migration default.
        let huge = String(repeating: "X", count: 9_000)
        try rehearsalWriteFile(
            at: configDir, name: "runtime-resources.json",
            text: """
            {"version":1,"profiles":[\
            {"id":"e2e","projects":["\(workspacePath)"],\
            "executableLinks":[],"readFiles":[],"readTrees":[],"writeTrees":[],\
            "credentials":[],"environment":[],"keychain":[],\
            "secrets":[\
            {"provider":"file","item":"e2e/api-token","env":"E2E_BROKER_VALUE"},\
            {"provider":"file","item":"e2e/huge","env":"E2E_BROKER_DROPPED"}\
            ]}]}
            """
        )
        try rehearsalWriteFile(
            at: configDir, name: "agent-definitions.json",
            text: """
            {"version":1,"definitions":[\
            {"id":"e2e-agent","displayName":"E2E rehearsal","blurb":"",\
            "executable":{"allowsUnsigned":true},"hookHost":"opencode",\
            "agentTag":"e2e-agent","resourceProfile":"e2e",\
            "credentialBindings":[],"secretsProvider":"file",\
            "requiredAssurance":"launchObserved","authorityCeiling":["shell"]}\
            ]}
            """
        )
        try rehearsalWriteFile(
            at: configDir, name: "secrets-providers.json",
            text: """
            {"version":1,"bindings":[\
            {"name":"e2e","provider":"file","item":"e2e/api-token"}\
            ]}
            """
        )
        try rehearsalWriteFile(
            at: configDir, name: "secrets-file.json",
            text: """
            {"version":1,"items":{\
            "e2e/api-token":{"text":"\(rehearsalCanary)"},\
            "e2e/huge":{"text":"\(huge)"},\
            "e2e/connection":{"text":"\(rehearsalConnectionSecret)"}\
            }}
            """
        )

        // Real stores, real factory.
        let policy = try RuntimeResourcePolicyStore.load(from: configDir).get()
        let set = try AgentDefinitionStore.load(from: configDir, resourcePolicy: policy).get()
        let definitionID = try #require(AgentDefinitionID(validating: "e2e-agent"))
        definition = try #require(set.definition(id: definitionID))
        providers = try SecretsProviderFactory.makeProviders(configDirectory: configDir)

        // Real supervisor over the containment tree.
        let lifeLog = root.appendingPathComponent("workspace.jsonl")
        let journal = root.appendingPathComponent("instances.jsonl")
        runtimeLog = root.appendingPathComponent("runtime.jsonl")
        let directory = try #require(WorkingDirectory(validating: tree.workspaceURL.path))
        supervisor = try WorkspaceSessionSupervisor.open(
            directory,
            lifecycleLog: .file(lifeLog),
            instanceJournal: .file(journal)
        ).get()

        // Real stub MCP server over a real loopback socket.
        stubLog = root.appendingPathComponent("stub.log")
        let scriptURL = root.appendingPathComponent("stub-mcp-server.py")
        try rehearsalStubScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        let stub = Process()
        stub.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        stub.arguments = [scriptURL.path, stubLog.path, rehearsalToolResult]
        let stubPipe = Pipe()
        stub.standardOutput = stubPipe
        stub.standardError = FileHandle.nullDevice
        try stub.run()
        self.stub = stub
        stubPort = try RehearsalWorld.readStubPort(stubPipe)
    }

    /// Reads the `RV_E2E_PORT=` marker the stub prints after binding.
    /// Bounded: the stub must report within 15 seconds or setup fails.
    static func readStubPort(_ pipe: Pipe) throws -> Int {
        let handle = pipe.fileHandleForReading
        var pending = Data()
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let chunk = handle.availableData
            if chunk.isEmpty == false {
                pending += chunk
            }
            if let line = String(data: pending, encoding: .utf8),
                let range = line.range(of: "RV_E2E_PORT=")
            {
                let rest = line[range.upperBound...]
                let digits = rest.prefix(while: { $0.isNumber })
                if let port = Int(digits) {
                    return port
                }
            }
            if chunk.isEmpty {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        throw RehearsalError.stubNotReady
    }

    func cleanup() {
        stub.terminate()
        _ = supervisor.close()
        tree.tearDown()
        try? FileManager.default.removeItem(at: root)
    }
}

// MARK: - Launch half

/// Announces the loaded definition on the supervisor's registry.
private func rehearsalAnnounce(
    _ world: RehearsalWorld
) throws -> AgentInstance {
    let granted = world.definition.authorityCeiling
    let instance = AgentInstance(
        id: AgentInstanceID(),
        owner: OwnerPrincipal(uid: 501),
        definitionID: world.definition.id,
        definitionRevision: AgentDefinitionRevision.resolve(world.definition),
        workspaceSessionID: world.supervisor.id,
        runtimeSessionID: RuntimeSessionID(),
        executableEvidence: .none,
        assurance: .launchObserved,
        groupLeader: RuntimeChildIdentity(pid: 100),
        workloadProcess: nil,
        parent: nil,
        effectiveAuthority: granted,
        delegableAuthority: granted,
        mintedAt: Date()
    )
    guard world.supervisor.agentInstances.announce(instance) else {
        throw RehearsalError.announceFailed
    }
    return instance
}

private func rehearsalActivate(
    _ world: RehearsalWorld, instance: AgentInstance
) throws {
    let directory = try #require(
        WorkingDirectory(validating: FileManager.default.temporaryDirectory.path)
    )
    let session = RuntimeSession(
        id: instance.runtimeSessionID,
        workspaceSessionID: world.supervisor.id,
        host: .opencode,
        workspace: directory,
        backend: .seatbelt,
        startedAt: Date(),
        child: nil
    )
    let established = try #require(
        EstablishedRuntimeSession(session: session, instance: instance, establishedAt: Date())
    )
    guard world.supervisor.agentInstances.activate(established) != nil else {
        throw RehearsalError.activateFailed
    }
}

/// Fresh usable caller context, resolved from the registry after
/// activation — never a cached snapshot.
private func rehearsalActiveContext(
    _ world: RehearsalWorld
) throws -> AuthenticatedAgentContext {
    let instance = try rehearsalAnnounce(world)
    try rehearsalActivate(world, instance: instance)
    let context = try #require(world.supervisor.agentInstances.context(for: instance.id))
    try #require(context.isUsable)
    return context
}

private func rehearsalSeen(_ world: RehearsalWorld) async throws -> String {
    let url = world.tree.workspaceURL.appendingPathComponent("seen.txt")
    guard await rehearsalWaitFor(url) else {
        throw RehearsalError.waitTimedOut
    }
    return try String(contentsOf: url, encoding: .utf8)
}

// MARK: - Dispatch half

/// Admission session wired to the REAL loopback transport, the REAL
/// broker (factory providers over the rehearsal files) for connection
/// credentials, and REAL ledger-backed audit sinks. Policy stays in code:
/// no MCP policy file loader exists yet, so there is no policy file to
/// load — the rehearsal pins the approve rule explicitly instead.
/// Shared-identity cause capture: the cause sink (accept thread) and the
/// test thread both touch it. Mirrors the E1-E box pattern.
private final class RehearsalCauseBox: Sendable {
    let mutex = Mutex<[String]>([])
}

private struct RehearsalDispatch {
    let session: RuntimeAdmissionSession
    let capability = RuntimeCapability()
    let runtime: RuntimeSession
    let toolAddress: MCPToolAddress
    let causes: RehearsalCauseBox

    init(world: RehearsalWorld) throws {
        let workspace = try #require(WorkingDirectory(validating: world.root.path))
        let runtime = RuntimeSession(
            id: RuntimeSessionID(),
            workspaceSessionID: WorkspaceSessionID(),
            host: .opencode,
            workspace: workspace,
            backend: .seatbelt,
            startedAt: Date(),
            child: nil
        )
        let toolAddress = try MCPToolAddress(
            integration: "e2e", owner: "user", connection: "conn", tool: "read"
        )
        let mcpSession = MCPTransportSession(
            id: MCPSessionID(),
            resource: try #require(MCPResourceID(rawValue: "conn")),
            callerToken: .random(),
            kind: .streamableHTTP
        )
        let policies = MCPPolicyStore(
            policies: [
                ToolPolicy(
                    id: "rehearsal-approve",
                    owner: .user,
                    pattern: .any,
                    action: .approve,
                    position: FractionalIndex(value: 1)
                )
            ],
            pluginDefault: .approve
        )
        let registry = AgentInstanceRegistry(
            journal: .file(world.root.appendingPathComponent("dispatch-instances.jsonl"))
        )
        let granted = world.definition.authorityCeiling
        let instance = AgentInstance(
            id: AgentInstanceID(),
            owner: OwnerPrincipal(uid: 501),
            definitionID: world.definition.id,
            definitionRevision: AgentDefinitionRevision.resolve(world.definition),
            workspaceSessionID: runtime.workspaceSessionID,
            runtimeSessionID: runtime.id,
            executableEvidence: .none,
            assurance: .launchObserved,
            groupLeader: RuntimeChildIdentity(pid: 100),
            workloadProcess: nil,
            parent: nil,
            effectiveAuthority: granted,
            delegableAuthority: granted,
            mintedAt: Date()
        )
        guard registry.announce(instance) else { throw RehearsalError.announceFailed }
        let established = try #require(
            EstablishedRuntimeSession(session: runtime, instance: instance, establishedAt: Date())
        )
        guard registry.activate(established) != nil else { throw RehearsalError.activateFailed }
        let broker = SecretBroker(
            providers: world.providers,
            auditDirectory: world.brokerAuditDir,
            liveness: .registry(registry)
        )
        let connectionRef = try SecretRef(provider: "file", item: "e2e/connection", field: nil)
        let causes = RehearsalCauseBox()
        let mcp = RuntimeMCPConfiguration(
            registry: MCPRegistry(handlers: [
                MCPHandlerRecord(address: toolAddress, isStaticFqid: false, pluginDefault: .approve)
            ]),
            policies: policies,
            elicitation: InMemoryElicitationBackend(),
            credentials: .broker(broker) { _ in [connectionRef] },
            transport: MCPStreamableHTTPClient(
                baseURL: "http://127.0.0.1:\(world.stubPort)",
                send: rehearsalLiveSend
            ),
            audit: .file(directory: world.mcpAuditDir),
            causes: MCPServerCauseLog(sink: { line in causes.mutex.withLock { $0.append(line) } }),
            sessionFor: { _, dispatch in
                guard let parsed = try? MCPToolAddress.parse(dispatch.address),
                    parsed.connection == "conn"
                else {
                    return nil
                }
                return mcpSession
            },
            bridgeTimeoutSeconds: 30
        )
        let configuration = RuntimeAdmissionConfiguration(
            normalize: { _, _ in .failure(.failed) },
            executor: .refuse,
            approval: { _, _ in nil },
            policy: { _ in .empty },
            evidence: RuntimeAdmissionEvidence(),
            mcpPolicy: { _, address in policies.resolve(address).action },
            mcp: .invoke(mcp)
        )
        let admission = RuntimeAdmissionSession(
            binding: RuntimeChannelBinding(session: runtime, capability: capability),
            configuration: configuration,
            launch: AdmittedLaunchContext(
                plan: compileContainedPlan(workspace: workspace),
                profileSource: "(deny file-link)",
                workspacePath: workspace.rawValue
            ),
            requestRead: -1,
            responseWrite: -1
        )
        guard admission.bindAgentInstance(instance.id, registry: registry) else {
            throw RehearsalError.bindFailed
        }
        self.session = admission
        self.runtime = runtime
        self.toolAddress = toolAddress
        self.causes = causes
    }

    func bytes(address: String, arguments: String = #"{"q":1}"#) throws -> Data {
        let dispatch = MCPDispatchAction(
            address: address,
            argsDigest: MCPDispatchDigest.hex(of: arguments),
            idempotencyKey: UUID().uuidString,
            argumentsJSON: arguments
        )
        let frame = RuntimeActionFrame(
            version: 1,
            requestID: try #require(RuntimeActionRequestID(validating: UUID().uuidString)),
            capability: capability,
            claimedSession: try #require(
                RuntimeSessionClaim(validating: runtime.id.rawValue.uuidString)
            ),
            action: .mcp(dispatch: dispatch)
        )
        return try RuntimeAdmissionCodec.encodeRequest(frame).get()
    }
}

// MARK: - Leak check

/// Asserts a canary byte string appears in NONE of the given artifacts.
/// Every ledger, audit, log, and stub file the rehearsal produces goes
/// through here; `seen.txt` is the only allowed carrier and never does.
private func rehearsalAssertSealed(
    _ canary: String, artifacts: [URL], sourceLocation: SourceLocation = #_sourceLocation
) throws {
    for url in artifacts {
        guard FileManager.default.fileExists(atPath: url.path) else { continue }
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(
            text.contains(canary) == false,
            "canary leaked into \(url.lastPathComponent)",
            sourceLocation: sourceLocation
        )
    }
}

// MARK: - Rehearsal

@Suite("Secrets MCP rehearsal", .serialized)
struct SecretsMCPRehearsalTests {
    @Test func filesToChildEnvAndToolResult() async throws {
        let world = try RehearsalWorld()
        defer { world.cleanup() }

        // The v2 definition made the round trip: provider selection plus
        // the profile's secret entries survived file → store → value.
        #expect(world.definition.secretsProvider == "file")
        #expect(world.definition.resourceProfile.secrets.map(\.env)
            == ["E2E_BROKER_VALUE", "E2E_BROKER_DROPPED"])
        // The factory built the real offline set: file plus env plus the
        // platform keychain, and nothing else (no vault configured).
        var expectedIDs = ["env", "file"]
        if KeychainSecretsProvider.currentPlatform() != nil {
            expectedIDs.append("keychain")
        }
        #expect(world.providers.map(\.id).sorted() == expectedIDs.sorted())

        // Launch half: one broker secret lands in the child environment.
        let running = try world.supervisor.launch(
            host: .opencode,
            stagingAgent: nil,
            command: try #require(IsolatedCommand(
                executable: "/bin/sh",
                arguments: ["-c", #"printf '%s' "$E2E_BROKER_VALUE" > seen.txt; /bin/sleep 30"#]
            )),
            plan: compileContainedPlan(workspace: world.supervisor.snapshot.policyWorkspace),
            io: .discard,
            resourceProfile: world.definition.resourceProfile,
            admission: .failClosed,
            sessionStore: .file(world.runtimeLog),
            brokerCallerContext: try rehearsalActiveContext(world),
            brokerProviders: world.providers,
            secretsConfigDirectory: world.configDir
        ).get()
        defer { _ = world.supervisor.cancel(running.id) }
        #expect(try await rehearsalSeen(world) == rehearsalCanary)

        // The launch ledger holds the broker's resolved row for the good
        // ref and exactly one denied drop row for the oversized sibling.
        let launchLedger = world.configDir.appendingPathComponent("secrets-audit.jsonl")
        let launchRows = SecretsLedger.loadRecords(fileURL: launchLedger)
        let resolved = launchRows.filter {
            $0.kind == .secretResolve && $0.decision == .resolved
        }
        #expect(resolved.contains(where: {
            $0.addressOrRef == .secret(provider: "file", item: "e2e/api-token", field: nil)
        }))
        let drops = launchRows.filter {
            $0.kind == .secretResolve && $0.decision == .denied
        }
        #expect(drops.count == 1)
        let drop = try #require(drops.first)
        #expect(drop.cause?.redacted == "stagingDrop:oversized:E2E_BROKER_DROPPED")
        #expect(drop.addressOrRef == .secret(provider: "file", item: "e2e/huge", field: nil))

        // Dispatch half: one tool call crosses the real loopback socket.
        let dispatch = try RehearsalDispatch(world: world)
        let decisions = await rehearsalAcceptOffPool(
            session: dispatch.session,
            bytes: try dispatch.bytes(address: dispatch.toolAddress.literal)
        )
        let decision = try #require(decisions.first)
        guard case .mcp(let receipt) = decision.response else {
            Issue.record("expected .mcp, got \(decision.response)")
            return
        }
        #expect(receipt.address == dispatch.toolAddress.literal)
        #expect(receipt.body == Data(rehearsalToolResult.utf8))
        #expect(decision.event.authorization == .allowed)
        #expect(decision.event.executionAttempted == true)
        #expect(decision.event.result == "mcp:succeeded")

        // The stub served exactly one call for this address.
        let stubLog = try String(contentsOf: world.stubLog, encoding: .utf8)
        #expect(stubLog.contains("served address=\(dispatch.toolAddress.literal)"))

        // The MCP ledger joins dispatch → outcome on one execution id.
        let mcpRows = SecretsLedger.loadRecords(
            fileURL: world.mcpAuditDir.appendingPathComponent("secrets-audit.jsonl")
        )
        let dispatches = mcpRows.filter {
            $0.kind == .toolDispatch && $0.decision == .allowed
        }
        let outcomes = mcpRows.filter {
            $0.kind == .toolOutcome && $0.decision == .succeeded
        }
        #expect(dispatches.count == 1)
        #expect(outcomes.count == 1)
        let dispatchRow = try #require(dispatches.first)
        let outcomeRow = try #require(outcomes.first)
        #expect(dispatchRow.executionID == outcomeRow.executionID)
        #expect(dispatchRow.addressOrRef == .tool(dispatch.toolAddress))
        #expect(outcomeRow.addressOrRef == .tool(dispatch.toolAddress))

        // The credential broker resolved the connection secret through
        // the file provider and audited it to its own ledger.
        let brokerRows = SecretsLedger.loadRecords(
            fileURL: world.brokerAuditDir.appendingPathComponent("secrets-audit.jsonl")
        )
        let connectionResolved = brokerRows.contains(where: { row in
            row.kind == .secretResolve && row.decision == .resolved
                && row.addressOrRef == .secret(provider: "file", item: "e2e/connection", field: nil)
        })
        #expect(connectionResolved)

        // Leak seal: neither canary appears in any ledger, audit, log,
        // journal, or stub artifact. `seen.txt` is excluded by design —
        // it is the child-observed environment, the one place the value
        // is SUPPOSED to be — and so are the input operator files.
        let artifacts = [
            launchLedger,
            world.mcpAuditDir.appendingPathComponent("secrets-audit.jsonl"),
            world.brokerAuditDir.appendingPathComponent("secrets-audit.jsonl"),
            world.runtimeLog,
            world.root.appendingPathComponent("workspace.jsonl"),
            world.root.appendingPathComponent("instances.jsonl"),
            world.root.appendingPathComponent("dispatch-instances.jsonl"),
            world.stubLog,
        ]
        // The seal skips missing files (nothing to leak), so prove the
        // sealed set is real: every artifact must exist and be non-empty.
        // A path typo here must fail loudly, never seal vacuously.
        for url in artifacts {
            let text = try #require(
                try? String(contentsOf: url, encoding: .utf8),
                "sealed artifact missing: \(url.lastPathComponent)"
            )
            #expect(text.isEmpty == false, "sealed artifact empty: \(url.lastPathComponent)")
        }
        try rehearsalAssertSealed(rehearsalCanary, artifacts: artifacts)
        try rehearsalAssertSealed(rehearsalConnectionSecret, artifacts: artifacts)
    }
}
#endif
