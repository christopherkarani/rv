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
            configDirectory: fixture.directory, resolver: fakeResolver,
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

    @Test func aHostProcessHoldingTheCagesPlaceholderIsRefusedWhileTheCageIsServed() throws {
        let fixture = try SecretsFixture(SecretsFixture.standard)
        defer { fixture.tearDown() }
        let upstream = RecordingUpstream(status: 200, chunks: [Data("ok".utf8)])
        let broker = SecretLaunchBroker(
            configDirectory: fixture.directory, resolver: fakeResolver,
            transport: upstream.transport, workspace: "cage-test")
        let opened = try open(broker: broker)
        defer {
            _ = opened.supervisor.close()
            opened.tree.tearDown()
        }
        let profile = RuntimeResourceProfile(
            id: "agents", projects: [opened.supervisor.snapshot.originalPath.rawValue], secrets: ["OPENAI_API_KEY"])
        // The runtime stays alive, so its placeholder stays live, until the host has tried it.
        let script = """
            printf '%s' "$OPENAI_API_KEY" > key.txt
            while [ ! -f go.txt ]; do /bin/sleep 0.1; done
            /usr/bin/curl -sS -H "Authorization: Bearer $OPENAI_API_KEY" "$OPENAI_BASE_URL/models" \
              > reply.txt 2> curl-err.txt
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
        #expect(cageWait { read(opened, "key.txt").hasPrefix("sk-rvph_") })

        // This test process is outside the runtime's process group.
        let placeholder = read(opened, "key.txt")
        let port = try #require(broker.gatewayPort)
        let stolen = try gatewayExchange(port: port,
            "GET /s/OPENAI_API_KEY/models HTTP/1.1\r\nAuthorization: Bearer \(placeholder)\r\n\r\n")
        #expect(stolen.status == 403)
        #expect(upstream.requests.isEmpty)

        try Data().write(to: opened.tree.workspaceURL.appendingPathComponent("go.txt"))
        #expect(cageWait { FileManager.default.fileExists(
            atPath: opened.tree.workspaceURL.appendingPathComponent("done.txt").path) })
        #expect(read(opened, "curl-err.txt") == "")
        #expect(read(opened, "reply.txt") == "ok")
        #expect(upstream.requests.count == 1)

        let runtime = running.session.id.rawValue.uuidString
        let misuse = fixture.auditLines.filter { $0["kind"] as? String == "secret.misuse" }
        #expect(misuse.count == 1)
        #expect(misuse.first?["runtime"] as? String == runtime)
        #expect((misuse.first?["detail"] as? [String: String])?["refusal"] == "runtimeMismatch")
        #expect(fixture.auditText.contains(placeholder) == false)
    }

    /// The cage denies `setsid` and `setpgid` but not `posix_spawn`'s
    /// `SETSID` and `SETPGROUP` flags (Node's `detached: true`). A child
    /// that leaves the leader's group that way is still the runtime's.
    @Test func childrenSpawnedIntoANewSessionOrGroupAreServed() throws {
        let fixture = try SecretsFixture(SecretsFixture.standard)
        defer { fixture.tearDown() }
        let upstream = RecordingUpstream(status: 200, chunks: [Data("ok".utf8)])
        let broker = SecretLaunchBroker(
            configDirectory: fixture.directory, resolver: fakeResolver,
            transport: upstream.transport, workspace: "cage-test")
        let opened = try open(broker: broker)
        defer {
            _ = opened.supervisor.close()
            opened.tree.tearDown()
        }
        let probe = try compileSpawnProbe(in: opened.tree.workspaceURL)
        let profile = RuntimeResourceProfile(
            id: "agents", projects: [opened.supervisor.snapshot.originalPath.rawValue], secrets: ["OPENAI_API_KEY"])
        func curl(_ name: String) -> String {
            "/usr/bin/curl -sS -H \"Authorization: Bearer $OPENAI_API_KEY\" \"$OPENAI_BASE_URL/models\" "
                + "> \(name).txt 2> \(name)-err.txt"
        }
        _ = try opened.supervisor.launch(
            host: nil, stagingAgent: cageStagingTag("codex"),
            command: try #require(IsolatedCommand(executable: probe.path, arguments: [
                "report.txt", "setsid", curl("setsid"), "setpgroup", curl("setpgroup"),
            ])),
            plan: compileContainedPlan(workspace: opened.supervisor.snapshot.policyWorkspace),
            io: .discard, resourceProfile: profile,
            admission: .failClosed, sessionStore: .file(opened.runtimeLog),
            keychainReader: KeychainReader(read: { _, _ in nil })
        ).get()
        #expect(cageWait { read(opened, "report.txt").split(separator: "\n").count == 2 })

        let report = read(opened, "report.txt")
        #expect(report.contains("setsid spawn=0 leftGroup=1 exit=0"))
        #expect(report.contains("setpgroup spawn=0 leftGroup=1 exit=0"))
        #expect(read(opened, "setsid-err.txt") == "")
        #expect(read(opened, "setsid.txt") == "ok")
        #expect(read(opened, "setpgroup.txt") == "ok")
        #expect(upstream.requests.count == 2)
        #expect(fixture.auditLines.contains { $0["kind"] as? String == "secret.misuse" } == false)
    }

    @Test func undefinedSecretFailsTheLaunchBeforeSpawn() throws {
        let fixture = try SecretsFixture(SecretsFixture.standard)
        defer { fixture.tearDown() }
        let broker = SecretLaunchBroker(
            configDirectory: fixture.directory, resolver: fakeResolver,
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
            configDirectory: fixture.directory, resolver: fakeResolver,
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

/// Runs each `(mode, script)` pair under `/bin/sh` in a child spawned with
/// `POSIX_SPAWN_SETSID` or `POSIX_SPAWN_SETPGROUP`, and reports whether the
/// child left the caller's process group.
private let spawnProbeSource = """
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
extern char **environ;
int main(int argc, char **argv) {
    if (argc < 4) return 2;
    FILE *report = fopen(argv[1], "w");
    if (report == NULL) return 3;
    for (int i = 2; i + 1 < argc; i += 2) {
        posix_spawnattr_t attr;
        posix_spawnattr_init(&attr);
        if (strcmp(argv[i], "setsid") == 0) {
            posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID);
        } else {
            posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
            posix_spawnattr_setpgroup(&attr, 0);
        }
        char *av[] = {"/bin/sh", "-c", argv[i + 1], NULL};
        pid_t child = 0;
        int rc = posix_spawn(&child, "/bin/sh", NULL, &attr, av, environ);
        int left = rc == 0 && getpgid(child) != getpgrp();
        int status = 0;
        if (rc == 0) waitpid(child, &status, 0);
        fprintf(report, "%s spawn=%d leftGroup=%d exit=%d\\n", argv[i], rc, left,
            WIFEXITED(status) ? WEXITSTATUS(status) : -1);
        fflush(report);
    }
    fclose(report);
    return 0;
}
"""

private func compileSpawnProbe(in workspace: URL) throws -> URL {
    let file = workspace.appendingPathComponent("spawn-probe.c")
    let binary = workspace.appendingPathComponent("spawn-probe")
    try Data(spawnProbeSource.utf8).write(to: file)
    let compile = Process()
    compile.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
    compile.arguments = ["-O2", "-o", binary.path, file.path]
    compile.standardOutput = FileHandle.nullDevice
    compile.standardError = FileHandle.nullDevice
    try compile.run()
    compile.waitUntilExit()
    try #require(compile.terminationStatus == 0)
    return binary
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
