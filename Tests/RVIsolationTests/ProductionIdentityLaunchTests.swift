#if os(macOS)
import Darwin
import Foundation
import RVDomain
import RVPolicy
import Synchronization
import Testing
@testable import RVIsolation

/// Real supervisor and contained children. This does not exercise the installed
/// three-process service topology or certify its authenticated XPC bridge.
@Suite(.serialized)
struct ProductionIdentityLaunchTests {
    @Test func selectedDefinitionMintsAnActivePrincipalAndCancellationInvalidatesIt() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let supervisor = try openIdentityWorkspace(tree)
        defer { _ = supervisor.close() }
        let selection = try operatorSelection(tree, executable: "/bin/sleep")
        let runtime = try supervisor.launchAgent(
            selection: selection, arguments: ["30"],
            io: .discard, admission: .failClosed,
            sessionStore: .file(tree.rootURL.appendingPathComponent("runtime.jsonl")),
            host: WorkspaceHostID(), generation: WorkspaceHostGeneration()
        ).get()
        let instance = try #require(supervisor.agentInstances.instance(forRuntime: runtime.id))
        let context = try #require(supervisor.agentInstances.context(for: instance.id))
        #expect(context.validity == .active)
        #expect(instance.definitionID == selection.resolved.definition.id)
        #expect(instance.definitionRevision == selection.resolved.revision)
        #expect(instance.owner == OwnerPrincipal.current())
        #expect(instance.workspaceSessionID == supervisor.id)
        #expect(instance.runtimeSessionID == runtime.id)
        #expect(instance.assurance == .launchObserved)
        #expect(instance.executableEvidence.contentDigestSHA256 == nil)
        #expect(instance.workloadProcess == nil)

        let authority = WorkspacePrincipalAuthority(
            registry: supervisor.agentInstances, workspace: supervisor.id, host: WorkspaceHostID()
        )
        let reference = try #require(authority.reference(forRuntime: runtime.id))
        #expect(authority.resolve(reference)?.validity == .active)
        let restarted = WorkspacePrincipalAuthority(
            registry: supervisor.agentInstances, workspace: supervisor.id, host: authority.host
        )
        #expect(restarted.generation != authority.generation)
        #expect(restarted.resolve(reference) == nil)
        let newReference = try #require(restarted.reference(forRuntime: runtime.id))
        #expect(newReference.workspaceHostGeneration == restarted.generation)
        try supervisor.cancel(runtime.id).get()
        #expect(authority.resolve(reference) == nil)
        #expect(restarted.resolve(newReference) == nil)
        #expect(authority.reference(forRuntime: runtime.id) == nil)
    }

    @Test func legacyHookLabelDoesNotMintAPrincipal() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let supervisor = try openIdentityWorkspace(tree)
        defer { _ = supervisor.close() }
        let command = try #require(IsolatedCommand(executable: "/bin/sleep", arguments: ["30"]))
        let runtime = try supervisor.launchLegacy(
            host: .claude, command: command, plan: tree.containedPlan(),
            io: .discard, admission: .failClosed,
            sessionStore: .file(tree.rootURL.appendingPathComponent("legacy-runtime.jsonl"))
        ).get()
        #expect(runtime.session.host == .claude)
        #expect(supervisor.agentInstances.instance(forRuntime: runtime.id) == nil)
        let authority = WorkspacePrincipalAuthority(
            registry: supervisor.agentInstances, workspace: supervisor.id, host: WorkspaceHostID()
        )
        #expect(authority.reference(forRuntime: runtime.id) == nil)
        try supervisor.cancel(runtime.id).get()
    }

    @Test func realAdmissionPipesResolveTheSelectedChildPrincipal() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        // Compile before opening the protected workspace so this is an ordinary
        // real executable, not a substitute implementation of the launch path.
        let executable = try compileIdentityClient(in: tree.workspaceURL)
        let selection = try operatorSelection(tree, executable: executable.path)
        let supervisor = try openIdentityWorkspace(tree)
        defer { _ = supervisor.close() }
        let observed = Mutex<[RuntimeAdmissionSubject]>([])
        let evidence = RuntimeAdmissionEvidence()
        let configuration = RuntimeAdmissionConfiguration(
            normalize: { subject, _ in
                observed.withLock { $0.append(subject) }
                return .failure(.failed)
            },
            executor: .effect { _ in .failure(.spawnFailed) },
            approval: { _ in nil }, policy: { _ in .empty }, evidence: evidence
        )
        let trigger = tree.workspaceURL.appendingPathComponent("submit-request")
        let reply = tree.workspaceURL.appendingPathComponent("identity-reply")
        let runtime = try supervisor.launchAgent(
            selection: selection, arguments: [trigger.path, reply.path],
            io: .discard, admission: configuration,
            sessionStore: .file(tree.rootURL.appendingPathComponent("pipe-runtime.jsonl")),
            host: WorkspaceHostID(), generation: WorkspaceHostGeneration()
        ).get()
        let instance = try #require(supervisor.agentInstances.instance(forRuntime: runtime.id))
        // The child submits only after the production launch returns established.
        // This avoids guessing the duration of the establishment handshake.
        try Data().write(to: trigger)
        let deadline = Date().addingTimeInterval(10)
        while (try? String(contentsOf: reply, encoding: .utf8))?.contains("evaluationFailed") != true,
            Date() < deadline {
            usleep(10_000)
        }
        let response = try String(contentsOf: reply, encoding: .utf8)
        #expect(response.contains("evaluationFailed"))
        let subjects = observed.withLock { $0 }
        #expect(subjects.count == 1)
        let subject = try #require(subjects.first)
        let agent = try #require(subject.agent)
        #expect(agent.validity == .active)
        #expect(agent.instance.id == instance.id)
        #expect(agent.instance.definitionRevision == selection.resolved.revision)
        #expect(agent.instance.owner == OwnerPrincipal.current())
        #expect(subject.session.id == runtime.id)
        #expect(agent.instance.runtimeSessionID == runtime.id)
        #expect(agent.instance.workspaceSessionID == supervisor.id)
        #expect(URL(fileURLWithPath: subject.policyWorkspace.rawValue).resolvingSymlinksInPath().path
            == URL(fileURLWithPath: supervisor.snapshot.policyWorkspace.rawValue).resolvingSymlinksInPath().path)
        #expect(evidence.snapshot().allSatisfy { !$0.executionAttempted })
        try supervisor.cancel(runtime.id).get()
    }
}

private func openIdentityWorkspace(_ tree: ContainmentTree) throws -> WorkspaceSessionSupervisor {
    try WorkspaceSessionSupervisor.open(
        try #require(WorkingDirectory(validating: tree.workspaceURL.path)),
        lifecycleLog: .file(tree.rootURL.appendingPathComponent("workspace.jsonl")),
        runtimeLog: tree.rootURL.appendingPathComponent("runtime.jsonl"),
        instanceJournal: .file(tree.rootURL.appendingPathComponent("instances.jsonl"))
    ).get()
}

private func operatorSelection(_ tree: ContainmentTree, executable: String) throws -> ResolvedAgentLaunch {
    let policy = RuntimeResourcePolicy(profiles: [RuntimeResourceProfile(
        id: "identity-fixture", projects: [tree.workspaceURL.path],
        executableLinks: [.init(name: "identity-fixture", target: executable)]
    )])
    let definition: [String: Any] = [
        "id": "identity-fixture", "displayName": "Identity fixture", "blurb": "Test operator fixture",
        "executable": ["allowsUnsigned": true], "resourceProfile": "identity-fixture",
        "credentialBindings": [], "requiredAssurance": "launchObserved", "authorityCeiling": []
    ]
    let document = try JSONSerialization.data(withJSONObject: [
        "version": 1,
        "definitions": [definition]
    ])
    let definitions = try AgentDefinitionStore.decode(document, resourcePolicy: policy).get()
    return try AgentLaunchSelection.resolveNamed(
        id: AgentDefinitionID(rawValue: "identity-fixture"), definitions: definitions,
        project: tree.workspaceURL.path
    ).get()
}

private func compileIdentityClient(in workspace: URL) throws -> URL {
    let source = workspace.appendingPathComponent("identity-client.c")
    let binary = workspace.appendingPathComponent("identity-client")
    try Data(identityClientSource.utf8).write(to: source)
    let compiler = Process()
    compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
    compiler.arguments = ["-O2", "-o", binary.path, source.path]
    compiler.standardOutput = FileHandle.nullDevice
    compiler.standardError = FileHandle.nullDevice
    try compiler.run()
    compiler.waitUntilExit()
    try #require(compiler.terminationStatus == 0)
    return binary
}

private let identityClientSource = #"""
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int read_full(int fd, void *buffer, size_t count) {
    size_t done = 0;
    while (done < count) {
        ssize_t n = read(fd, (char *)buffer + done, count - done);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        done += (size_t)n;
    }
    return 0;
}
static int write_full(int fd, const void *buffer, size_t count) {
    size_t done = 0;
    while (done < count) {
        ssize_t n = write(fd, (const char *)buffer + done, count - done);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        done += (size_t)n;
    }
    return 0;
}
static int read_frame(int fd, char *body, size_t capacity) {
    unsigned char header[4];
    if (read_full(fd, header, 4)) return -1;
    size_t n = ((size_t)header[0] << 24) | ((size_t)header[1] << 16)
        | ((size_t)header[2] << 8) | header[3];
    if (n == 0 || n >= capacity || read_full(fd, body, n)) return -1;
    body[n] = 0;
    return 0;
}
static int extract(const char *json, const char *key, char *out, size_t capacity) {
    char pattern[64];
    snprintf(pattern, sizeof pattern, "\"%s\":\"", key);
    const char *start = strstr(json, pattern);
    if (!start) return -1;
    start += strlen(pattern);
    const char *end = strchr(start, '"');
    if (!end || (size_t)(end - start) >= capacity) return -1;
    memcpy(out, start, (size_t)(end - start));
    out[end - start] = 0;
    return 0;
}
int main(int argc, char **argv) {
    if (argc != 3) return 2;
    char grant[8192], capability[80], session[80], body[1024], reply[8192];
    if (read_frame(5, grant, sizeof grant)) return 3;
    if (extract(grant, "capability", capability, sizeof capability)
        || extract(grant, "session", session, sizeof session)) return 4;
    for (int attempt = 0; access(argv[1], F_OK) != 0; attempt++) {
        if (attempt >= 1000) return 5;
        usleep(10000);
    }
    int n = snprintf(body, sizeof body,
        "{\"v\":1,\"id\":\"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa\",\"capability\":\"%s\",\"session\":\"%s\",\"command\":\"echo identity-probe\"}",
        capability, session);
    if (n <= 0 || (size_t)n >= sizeof body) return 6;
    unsigned char header[4] = {
        (unsigned char)((unsigned)n >> 24), (unsigned char)((unsigned)n >> 16),
        (unsigned char)((unsigned)n >> 8), (unsigned char)n
    };
    if (write_full(4, header, 4) || write_full(4, body, (size_t)n)) return 7;
    if (read_frame(5, reply, sizeof reply)) return 8;
    FILE *out = fopen(argv[2], "w");
    if (!out) return 9;
    if (fprintf(out, "%s\n", reply) < 0 || fclose(out)) return 10;
    for (;;) pause();
}
"""#
#endif
