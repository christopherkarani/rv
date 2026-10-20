import Foundation
import RVDomain
import Testing
@testable import RVIsolation

#if os(macOS)
/// L2: a real Seatbelt cage reaches the secret gateway over loopback. The
/// upstream sees the real value; nothing inside the cage ever does.
@Suite("SecretGatewayCage", .serialized)
struct SecretGatewayCageTests {
    private static let realKey = "sk-live-REAL-0123456789"

    private struct Opened {
        let tree: ContainmentTree
        let supervisor: WorkspaceSessionSupervisor
        let runtimeLog: URL
    }

    private func open(broker: SecretLaunchBroker) throws -> Opened {
        let tree = try ContainmentTree()
        let runtimeLog = tree.rootURL.appendingPathComponent("runtime-\(UUID().uuidString).jsonl")
        let lifeLog = tree.rootURL.appendingPathComponent("workspace-\(UUID().uuidString).jsonl")
        let directory = try #require(WorkingDirectory(validating: tree.workspaceURL.path))
        let supervisor = try WorkspaceSessionSupervisor.open(
            directory, lifecycleLog: .file(lifeLog), runtimeLog: runtimeLog, secretBroker: broker
        ).get()
        return Opened(tree: tree, supervisor: supervisor, runtimeLog: runtimeLog)
    }

    private func read(_ opened: Opened, _ name: String) -> String {
        (try? String(contentsOf: opened.tree.workspaceURL.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }

    @Test func cagedCurlReachesUpstreamWithTheRealKeyWhileTheCageSeesOnlyAPlaceholder() throws {
        let fixture = try SecretsFixture(SecretsFixture.standard)
        defer { fixture.tearDown() }
        let upstream = RecordingUpstream(
            status: 200, headers: [("Content-Type", "application/json")],
            chunks: [Data("{\"echo\":\"\(Self.realKey)\"}".utf8)])
        let broker = SecretLaunchBroker(
            configDirectory: fixture.directory, makeResolver: { fakeResolver },
            transport: upstream.transport, workspace: "cage-test")
        let opened = try open(broker: broker)
        defer {
            _ = opened.supervisor.close()
            opened.tree.tearDown()
        }
        let profile = RuntimeResourceProfile(
            id: "agents", projects: [opened.supervisor.snapshot.originalPath.rawValue],
            secrets: ["OPENAI_API_KEY", "GH_TOKEN"])
        let script = """
            printf '%s' "$OPENAI_API_KEY" > key.txt
            printf '%s' "$OPENAI_BASE_URL" > base.txt
            printf '%s' "$GH_TOKEN" > gh.txt
            /usr/bin/curl -sS -H "Authorization: Bearer $OPENAI_API_KEY" "$OPENAI_BASE_URL/models?x=1" \
              > reply.txt 2> curl-err.txt
            env > env.txt
            echo done > done.txt
            """
        let running = try opened.supervisor.launch(
            host: nil, stagingAgent: cageStagingTag("codex"),
            command: try #require(IsolatedCommand(executable: "/bin/sh", arguments: ["-c", script])),
            plan: compileContainedPlan(workspace: opened.supervisor.snapshot.policyWorkspace),
            io: .discard, resourceProfile: profile,
            admission: .failClosed, sessionStore: .file(opened.runtimeLog),
            keychainReader: KeychainReader(read: { _, _ in nil })
        ).get()
        #expect(cageWait { FileManager.default.fileExists(
            atPath: opened.tree.workspaceURL.appendingPathComponent("done.txt").path) })

        let placeholder = read(opened, "key.txt")
        let port = try #require(broker.gatewayPort)
        #expect(placeholder.hasPrefix("sk-rvph_"))
        #expect(read(opened, "base.txt") == "http://127.0.0.1:\(port)/s/OPENAI_API_KEY")
        #expect(read(opened, "gh.txt") == "ghp_realtoken")
        #expect(read(opened, "curl-err.txt") == "")
        #expect(read(opened, "reply.txt") == "{\"echo\":\"\(placeholder)\"}")
        #expect(read(opened, "env.txt").contains(Self.realKey) == false)
        #expect(read(opened, "reply.txt").contains(Self.realKey) == false)

        let seen = try #require(upstream.requests.first)
        #expect(seen.url == "https://api.example.com/v1/models?x=1")
        #expect(seen.headers["authorization"] == "Bearer \(Self.realKey)")

        let runtime = running.session.id.rawValue.uuidString
        #expect(cageWait { broker.liveCount == 0 })
        let request = fixture.auditLines.first {
            ($0["detail"] as? [String: String])?["event"] == "request"
        }
        #expect(request?["runtime"] as? String == runtime)
        #expect(request?["decision"] as? String == "allowed")
        #expect(fixture.auditText.contains(Self.realKey) == false)
    }

    @Test func undefinedSecretFailsTheLaunchBeforeSpawn() throws {
        let fixture = try SecretsFixture(SecretsFixture.standard)
        defer { fixture.tearDown() }
        let broker = SecretLaunchBroker(
            configDirectory: fixture.directory, makeResolver: { fakeResolver },
            transport: RecordingUpstream().transport, workspace: nil)
        let opened = try open(broker: broker)
        defer {
            _ = opened.supervisor.close()
            opened.tree.tearDown()
        }
        let refused = opened.supervisor.launch(
            host: nil,
            command: try #require(IsolatedCommand(executable: "/bin/sh", arguments: ["-c", "echo x > spawned.txt"])),
            plan: compileContainedPlan(workspace: opened.supervisor.snapshot.policyWorkspace),
            io: .discard,
            resourceProfile: RuntimeResourceProfile(
                id: "agents", projects: [opened.supervisor.snapshot.originalPath.rawValue],
                secrets: ["NOT_DEFINED"]),
            admission: .failClosed, sessionStore: .file(opened.runtimeLog)
        )
        guard case .failure(.apply(.resourceStagingFailed(let detail))) = refused else {
            Issue.record("an undefined secret must fail staging, got \(refused)")
            return
        }
        #expect(detail == "secret NOT_DEFINED is not defined in secrets.json")
        #expect(read(opened, "spawned.txt") == "")
    }

    @Test func deniedReaderPathRefusesProfilesThatListSecrets() throws {
        let fixture = try SecretsFixture(SecretsFixture.standard)
        defer { fixture.tearDown() }
        let broker = SecretLaunchBroker(
            configDirectory: fixture.directory, makeResolver: { fakeResolver },
            transport: RecordingUpstream().transport, workspace: nil)
        let opened = try open(broker: broker)
        defer {
            _ = opened.supervisor.close()
            opened.tree.tearDown()
        }
        let refused = opened.supervisor.launch(
            host: nil,
            command: try #require(IsolatedCommand(executable: "/bin/sh", arguments: ["-c", "echo x > spawned.txt"])),
            plan: compileContainedPlan(workspace: opened.supervisor.snapshot.policyWorkspace),
            io: .discard,
            resourceProfile: RuntimeResourceProfile(
                id: "agents", projects: [opened.supervisor.snapshot.originalPath.rawValue],
                secrets: ["GH_TOKEN"]),
            admission: .failClosed, sessionStore: .file(opened.runtimeLog),
            keychainReader: .denied
        )
        guard case .failure(.apply(.resourceStagingFailed(let detail))) = refused else {
            Issue.record("the denied path must refuse secrets, got \(refused)")
            return
        }
        #expect(detail == "secrets are not available on this launch path")
        #expect(broker.liveCount == 0)
    }
}

private func cageStagingTag(_ tag: String) -> DefinitionStagingTag {
    DefinitionStagingTag(AgentDefinition(
        id: AgentDefinitionID(rawValue: "test"),
        displayName: "Test",
        blurb: "",
        executableRequirement: ExecutableRequirement(allowsUnsigned: true),
        hookHost: nil,
        agentTag: tag,
        resourceProfile: RuntimeResourceProfile(id: "test", projects: []),
        credentialBindings: [],
        requiredAssurance: .launchObserved,
        authorityCeiling: AgentAuthority(scopes: [])
    ))!
}

private func cageWait(seconds: TimeInterval = 30, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return condition()
}
#endif
