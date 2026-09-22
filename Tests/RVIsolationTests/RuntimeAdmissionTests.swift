#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import Testing
@testable import RVIsolation

@Suite("RuntimeAdmission")
struct RuntimeAdmissionIsolationTests {
    @Test func allowedCommandRunsOnce() throws {
        let harness = try AdmissionHarness()
        defer { harness.cleanup() }
        let first = harness.session.submit(.success(harness.frame("touch marker")))
        #expect(harness.effect.runs == 1)
        #expect(harness.effect.exists)
        #expect(first.response == .executed(exitStatus: 0))
        #expect(first.event.executionAttempted)
        #expect(first.event.session == harness.runtime.id.rawValue.uuidString)

        let replay = harness.session.submit(.success(harness.frame("touch marker", id: harness.requestID)))
        #expect(harness.effect.runs == 1)
        #expect(replay.response == .rejected(.replay))
        #expect(replay.event.executionAttempted == false)

        let sameCommand = harness.session.submit(
            .success(harness.frame("touch marker", id: UUID()))
        )
        #expect(harness.effect.runs == 1)
        #expect(sameCommand.response == .rejected(.replay))
    }

    @Test func deniedCommandDoesNotRun() throws {
        let harness = try AdmissionHarness()
        defer { harness.cleanup() }
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-admission-outside-\(UUID().uuidString)")
        let decision = harness.session.submit(
            .success(harness.frame("touch \(outside.path)"))
        )
        #expect(harness.effect.runs == 0)
        #expect(harness.effect.exists == false)
        #expect(FileManager.default.fileExists(atPath: outside.path) == false)
        if case .denied = decision.response {
        } else {
            Issue.record("outside touch must be denied, got \(decision.response)")
        }
    }

    @Test func pendingCommandDoesNotRunUntilAllowOnce() throws {
        let harness = try AdmissionHarness()
        defer { harness.cleanup() }
        let pending = harness.session.submit(.success(harness.frame("echo hello")))
        #expect(harness.effect.runs == 0)
        #expect(pending.response == .pending(.reviewAsk))

        let approved = try AdmissionHarness(approval: { _ in .success(.allowOnce) })
        defer { approved.cleanup() }
        let decision = approved.session.submit(.success(approved.frame("echo hello")))
        #expect(approved.effect.runs == 1)
        #expect(approved.effect.exists)
        #expect(decision.response == .executed(exitStatus: 0))

        let unavailable = try AdmissionHarness(approval: { _ in .failure(.approvalUnavailable) })
        defer { unavailable.cleanup() }
        let refused = unavailable.session.submit(.success(unavailable.frame("echo hello")))
        #expect(unavailable.effect.runs == 0)
        #expect(unavailable.effect.exists == false)
        #expect(refused.response == .approvalUnavailable)

        let rule = try AdmissionHarness(approval: { _ in .success(.createRule) })
        defer { rule.cleanup() }
        let created = rule.session.submit(.success(rule.frame("echo hello")))
        #expect(rule.effect.runs == 0)
        #expect(created.response == .approvalUnavailable)
    }

    @Test func evaluationFailureDoesNotRun() throws {
        let harness = try AdmissionHarness()
        defer { harness.cleanup() }
        let decision = harness.session.submit(.success(harness.frame(#"python3 -c "$CMD""#)))
        #expect(harness.effect.runs == 0)
        #expect(harness.effect.exists == false)
        #expect(decision.response == .evaluationFailed)
        #expect(decision.event.executionAttempted == false)
    }

    @Test func fakeCapabilityWrongSessionAndClosedChannelDoNotRun() throws {
        let harness = try AdmissionHarness()
        defer { harness.cleanup() }
        let other = try AdmissionHarness()
        defer { other.cleanup() }

        let fake = harness.session.submit(
            .success(harness.frame("touch marker", capability: RuntimeCapability()))
        )
        let impersonated = harness.session.submit(
            .success(harness.frame("touch marker", claim: other.runtime.id.rawValue))
        )
        let foreignToken = harness.session.submit(
            .success(other.frame("touch marker"))
        )
        #expect(fake.response == .rejected(.invalidCapability))
        #expect(impersonated.response == .rejected(.impersonation))
        #expect(foreignToken.response == .rejected(.invalidCapability))
        #expect(harness.effect.runs == 0)

        let encoded = try RuntimeAdmissionCodec.encodeRequest(harness.frame("touch marker")).get()
        harness.session.finish()
        let stale = harness.session.accept(encoded)
        #expect(harness.effect.runs == 0)
        #expect(harness.effect.exists == false)
        #expect(stale.first?.response == .rejected(.inactiveSession))
        #expect(stale.first?.event.executionAttempted == false)
    }

    @Test func malformedFrameDoesNotRun() throws {
        let harness = try AdmissionHarness()
        defer { harness.cleanup() }
        let decision = harness.session.submit(.failure(.malformed))
        #expect(harness.effect.runs == 0)
        #expect(decision.response == .rejected(.malformed))
        let extra = Data(
            """
            {"v":1,"id":"\(UUID().uuidString)","capability":"\(harness.capability.rawValue)","session":"\(harness.runtime.id.rawValue.uuidString)","command":"touch marker","cwd":"/tmp"}
            """.utf8
        )
        var framed = Data()
        var length = UInt32(extra.count).bigEndian
        framed.append(Data(bytes: &length, count: 4))
        framed.append(extra)
        let decoded = harness.session.accept(framed)
        #expect(harness.effect.runs == 0)
        #expect(decoded.first?.response == .rejected(.malformed))
    }

    @Test func evidenceFileRecordsTheSessionAndOutcome() throws {
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-admission-log-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: log) }
        let harness = try AdmissionHarness(evidenceFile: log)
        defer { harness.cleanup() }
        _ = harness.session.submit(.success(harness.frame("touch marker")))
        let text = try String(contentsOf: log, encoding: .utf8)
        #expect(text.contains(harness.runtime.id.rawValue.uuidString))
        #expect(text.contains("\"authorization\":\"allowed\""))
        #expect(text.contains("\"executionAttempted\":true"))
        #expect(text.contains("\"result\":\"exit:0\""))
    }

    @Test func seatbeltProfileGainsNoNetworkAllow() throws {
        let workspace = try #require(WorkingDirectory(validating: "/tmp/rv-admission-profile"))
        let plan = try compileIsolationPlan(
            IsolationCompileRequest(requested: .contained, workspace: workspace)
        ).get()
        let profile = try compileSeatbeltProfile(plan).get()
        #expect(profile.source.contains("(deny default)"))
        #expect(profile.source.contains("allow network") == false)
        #expect(profile.source.contains("system-socket") == false)
    }

    #if os(Linux)
    @Test func containedLaunchStaysUnsupported() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let marker = tree.workspaceURL.appendingPathComponent("must-not-run")
        let command = try #require(IsolatedCommand(executable: "/bin/touch", arguments: ["must-not-run"]))
        switch IsolationBackends.apply(tree.contained, command: command) {
        case .failure(.containedGuaranteesUnsupported):
            break
        case .failure(let error):
            Issue.record("Linux contained launch must be refused, got \(error)")
        case .success(let run):
            Issue.record("Linux contained launch must be refused, got exit \(run.exitStatus)")
        }
        #expect(FileManager.default.fileExists(atPath: marker.path) == false)
    }
    #endif

    #if os(macOS)
    @Test func containedClientUsesTheGrantedPipes() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let client = try compileAdmissionClient(in: tree.workspaceURL)
        let reply = tree.workspaceURL.appendingPathComponent("admission-reply")
        let marker = tree.workspaceURL.appendingPathComponent("admitted-marker")
        let evidence = RuntimeAdmissionEvidence()
        let configuration = RuntimeAdmissionConfiguration(
            normalize: isolationAdmissionNormalize,
            executor: .containedCommand,
            approval: { _ in nil },
            policy: { _ in .empty },
            evidence: evidence
        )
        let command = try #require(
            IsolatedCommand(executable: client.path, arguments: [reply.path])
        )
        let log = tree.rootURL.appendingPathComponent("sessions.jsonl")
        let result = IsolationBackends.applyLaunch(
            tree.contained,
            command: command,
            io: .discard,
            host: .opencode,
            sessionStore: .file(log),
            admission: configuration
        )
        let run = try result.get()
        #expect(run.exitStatus == 0)
        let text = try String(contentsOf: reply, encoding: .utf8)
        #expect(text.contains("\"status\":\"executed\""))
        #expect(text.contains("\"reason\":\"replay\""))
        #expect(text.contains("\"reason\":\"impersonation\""))
        #expect(text.contains("\"reason\":\"invalidCapability\""))
        #expect(FileManager.default.fileExists(atPath: marker.path))
        let attempted = evidence.snapshot().filter(\.executionAttempted)
        #expect(attempted.count == 1)
        #expect(attempted.first?.authorization == .allowed)
        let rejected = evidence.snapshot().filter { $0.eventExecutionWasRejected }
        #expect(rejected.allSatisfy { $0.executionAttempted == false })
    }

    @Test func admittedCommandStopsWhenContainedProcessExits() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let sleeper = try compileC(
            admissionSleeperSource,
            named: "admission-sleeper",
            in: tree.workspaceURL
        )
        let client = try compileC(
            admissionLifetimeClientSource,
            named: "admission-lifetime",
            in: tree.workspaceURL
        )
        let escaped = tree.workspaceURL.appendingPathComponent("escaped")
        let started = tree.workspaceURL.appendingPathComponent("command-started")
        let command = try #require(
            IsolatedCommand(executable: client.path, arguments: [sleeper.path])
        )
        let configuration = RuntimeAdmissionConfiguration(
            normalize: allowAdmittedCommand,
            executor: .containedCommand,
            approval: { _ in nil },
            policy: { _ in .empty },
            evidence: RuntimeAdmissionEvidence()
        )
        let result = IsolationBackends.applyLaunch(
            tree.contained,
            command: command,
            io: .discard,
            host: .opencode,
            sessionStore: .file(tree.rootURL.appendingPathComponent("sessions.jsonl")),
            admission: configuration
        )
        let run = try result.get()
        #expect(run.exitStatus == 0)
        #expect(FileManager.default.fileExists(atPath: started.path))
        #expect(FileManager.default.fileExists(atPath: escaped.path) == false)
    }
    #endif
}

private final class AdmissionEffect: @unchecked Sendable {
    let url: URL
    var runs = 0

    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-admission-effect-\(UUID().uuidString)")
    }

    var exists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func run(_: AllowedAction) -> Result<Int32, RuntimeAdmissionExecutorError> {
        runs += 1
        guard FileManager.default.createFile(atPath: url.path, contents: Data("once".utf8)) else {
            return .failure(.spawnFailed)
        }
        return .success(0)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: url)
    }
}

private struct AdmissionHarness {
    let root: URL
    let runtime: RuntimeSession
    let capability: RuntimeCapability
    let requestID: UUID
    let effect: AdmissionEffect
    let session: RuntimeAdmissionSession

    init(
        approval: @escaping @Sendable (PendingAuthorization) -> Result<ApprovalDecision, AgentApprovalError>? = { _ in nil },
        evidenceFile: URL? = nil
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-admission-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = try #require(WorkingDirectory(validating: root.path))
        let plan = compileContainedPlan(workspace: workspace)
        let runtime = RuntimeSession(
            id: RuntimeSessionID(),
            host: .opencode,
            workspace: workspace,
            backend: .seatbelt,
            startedAt: Date(),
            child: nil
        )
        let capability = RuntimeCapability()
        let effect = AdmissionEffect()
        let evidence = RuntimeAdmissionEvidence(appendingTo: evidenceFile)
        let configuration = RuntimeAdmissionConfiguration(
            normalize: isolationAdmissionNormalize,
            executor: .effect(effect.run),
            approval: approval,
            policy: { _ in .empty },
            evidence: evidence
        )
        self.root = root
        self.runtime = runtime
        self.capability = capability
        self.requestID = UUID()
        self.effect = effect
        session = RuntimeAdmissionSession(
            binding: RuntimeChannelBinding(session: runtime, capability: capability),
            configuration: configuration,
            launch: AdmittedLaunchContext(
                plan: plan,
                profileSource: "(deny file-link)",
                workspacePath: workspace.rawValue
            ),
            requestRead: -1,
            responseWrite: -1
        )
    }

    func frame(
        _ command: String,
        capability: RuntimeCapability? = nil,
        claim: UUID? = nil,
        id: UUID? = nil
    ) -> RuntimeActionFrame {
        RuntimeActionFrame(
            version: 1,
            requestID: RuntimeActionRequestID(validating: (id ?? requestID).uuidString)!,
            capability: capability ?? self.capability,
            claimedSession: RuntimeSessionClaim(validating: (claim ?? runtime.id.rawValue).uuidString)!,
            command: ShellCommand(rawValue: command)
        )
    }

    func cleanup() {
        effect.cleanup()
        try? FileManager.default.removeItem(at: root)
    }
}

private extension RuntimeAdmissionEvent {
    var eventExecutionWasRejected: Bool {
        authorization == .rejected
    }
}

/// Classifies the fixture commands without linking RVEngine.
/// Inside `touch` is allowed, an absolute `touch` is an outside write, and
/// shell substitutions produce no proposal. Anything else stays pending.
private func isolationAdmissionNormalize(
    subject: RuntimeAdmissionSubject,
    command: ShellCommand
) -> Result<ProposedAction, RuntimeAdmissionEvaluationError> {
    let raw = command.rawValue
    if raw.contains("$") || raw.contains("`") || raw.contains("\"") || raw.contains("'") {
        return .failure(.failed)
    }
    let fingerprint = ActionFingerprint(
        rawValue: "runtime:\(subject.session.id.rawValue.uuidString):\(subject.policyWorkspace.rawValue):\(raw)"
    )
    let tokens = raw.split(whereSeparator: \.isWhitespace).map(String.init)
    if tokens.count == 2, tokens[0] == "touch" {
        let inside = tokens[1].hasPrefix("/") == false
        let scope: FilesystemScope = inside ? .insideRepository : .outsideRepository
        let kinds: [ActionEffectKind] = inside
            ? [.filesystemCreate]
            : [.filesystemOverwrite, .outsideRepositoryMutation]
        return .success(
            .shell(
                ShellAction(
                    fingerprint: fingerprint,
                    effects: ActionEffects(kinds: kinds),
                    resources: ActionResources(
                        path: tokens[1],
                        filesystemScope: scope,
                        resourceKind: .unknown
                    ),
                    scope: ActionScope(workingDirectory: subject.policyWorkspace),
                    supportingCommand: command
                )
            )
        )
    }
    return .success(
        .shell(
            ShellAction(
                fingerprint: fingerprint,
                effects: ActionEffects(),
                resources: ActionResources(),
                scope: ActionScope(workingDirectory: subject.policyWorkspace),
                supportingCommand: command
            )
        )
    )
}

#if os(macOS)
/// Test double that authorizes the requested argv. Production normalization
/// stays in RVEngine; this only lets a lifetime probe reach the spawner.
private func allowAdmittedCommand(
    subject: RuntimeAdmissionSubject,
    command: ShellCommand
) -> Result<ProposedAction, RuntimeAdmissionEvaluationError> {
    .success(
        .shell(
            ShellAction(
                fingerprint: ActionFingerprint(rawValue: "runtime:lifetime:\(command.rawValue)"),
                effects: ActionEffects(kinds: [.filesystemCreate]),
                resources: ActionResources(
                    path: "command-started",
                    filesystemScope: .insideRepository,
                    resourceKind: .unknown
                ),
                scope: ActionScope(workingDirectory: subject.policyWorkspace),
                supportingCommand: command
            )
        )
    )
}
#endif

#if os(macOS)
private func compileAdmissionClient(in workspace: URL) throws -> URL {
    try compileC(admissionClientSource, named: "admission-client", in: workspace)
}

private func compileC(_ source: String, named name: String, in workspace: URL) throws -> URL {
    let file = workspace.appendingPathComponent("\(name).c")
    let binary = workspace.appendingPathComponent(name)
    try Data(source.utf8).write(to: file)
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

private let admissionClientSource = #"""
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int read_full(int fd, void *buffer, size_t count) {
    unsigned char *bytes = buffer;
    size_t got = 0;
    while (got < count) {
        ssize_t n = read(fd, bytes + got, count - got);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        got += (size_t)n;
    }
    return 0;
}

static int write_full(int fd, const void *buffer, size_t count) {
    const unsigned char *bytes = buffer;
    size_t sent = 0;
    while (sent < count) {
        ssize_t n = write(fd, bytes + sent, count - sent);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        sent += (size_t)n;
    }
    return 0;
}

static int read_frame(int fd, char *body, size_t cap) {
    unsigned char header[4];
    if (read_full(fd, header, 4) != 0) return -1;
    size_t length = ((size_t)header[0] << 24) | ((size_t)header[1] << 16)
        | ((size_t)header[2] << 8) | (size_t)header[3];
    if (length == 0 || length + 1 > cap) return -1;
    if (read_full(fd, body, length) != 0) return -1;
    body[length] = 0;
    return (int)length;
}

static int write_frame(int fd, const char *body) {
    size_t length = strlen(body);
    unsigned char header[4] = {
        (unsigned char)((length >> 24) & 0xff),
        (unsigned char)((length >> 16) & 0xff),
        (unsigned char)((length >> 8) & 0xff),
        (unsigned char)(length & 0xff),
    };
    if (write_full(fd, header, 4) != 0) return -1;
    return write_full(fd, body, length);
}

static int extract(const char *json, const char *key, char *out, size_t cap) {
    char pattern[64];
    snprintf(pattern, sizeof pattern, "\"%s\":\"", key);
    const char *found = strstr(json, pattern);
    if (found == NULL) return -1;
    found += strlen(pattern);
    size_t used = 0;
    while (found[used] != 0 && found[used] != '"' && used + 1 < cap) {
        out[used] = found[used];
        used++;
    }
    if (found[used] != '"') return -1;
    out[used] = 0;
    return 0;
}

static int exchange(int request, int response, const char *body, FILE *reply) {
    if (write_frame(request, body) != 0) return -1;
    char incoming[8192];
    if (read_frame(response, incoming, sizeof incoming) < 0) return -1;
    if (fprintf(reply, "%s\n", incoming) < 0) return -1;
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    char grant[8192];
    if (read_frame(5, grant, sizeof grant) < 0) return 3;
    char capability[80];
    char session[80];
    if (extract(grant, "capability", capability, sizeof capability) != 0) return 4;
    if (extract(grant, "session", session, sizeof session) != 0) return 4;
    FILE *reply = fopen(argv[1], "w");
    if (reply == NULL) return 5;
    char body[1024];
    snprintf(body, sizeof body,
        "{\"v\":1,\"id\":\"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa\",\"capability\":\"%s\",\"session\":\"%s\",\"command\":\"touch admitted-marker\"}",
        capability, session);
    if (exchange(4, 5, body, reply) != 0) return 6;
    if (exchange(4, 5, body, reply) != 0) return 7;
    snprintf(body, sizeof body,
        "{\"v\":1,\"id\":\"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb\",\"capability\":\"%s\",\"session\":\"00000000-0000-0000-0000-000000000001\",\"command\":\"touch admitted-marker\"}",
        capability);
    if (exchange(4, 5, body, reply) != 0) return 8;
    char fake[65];
    memset(fake, 'a', 64);
    fake[64] = 0;
    snprintf(body, sizeof body,
        "{\"v\":1,\"id\":\"cccccccc-cccc-cccc-cccc-cccccccccccc\",\"capability\":\"%s\",\"session\":\"%s\",\"command\":\"touch admitted-marker\"}",
        fake, session);
    if (exchange(4, 5, body, reply) != 0) return 9;
    fclose(reply);
    return 0;
}
"""#

private let admissionSleeperSource = #"""
#include <fcntl.h>
#include <unistd.h>

int main(void) {
    int started = open("command-started", O_WRONLY | O_CREAT | O_EXCL, 0644);
    if (started < 0) return 2;
    close(started);
    sleep(20);
    return 0;
}
"""#

private let admissionLifetimeClientSource = #"""
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int read_full(int fd, void *buffer, size_t count) {
    unsigned char *bytes = buffer;
    size_t got = 0;
    while (got < count) {
        ssize_t n = read(fd, bytes + got, count - got);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        got += (size_t)n;
    }
    return 0;
}

static int write_full(int fd, const void *buffer, size_t count) {
    const unsigned char *bytes = buffer;
    size_t sent = 0;
    while (sent < count) {
        ssize_t n = write(fd, bytes + sent, count - sent);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        sent += (size_t)n;
    }
    return 0;
}

static int read_frame(int fd, char *body, size_t cap) {
    unsigned char header[4];
    if (read_full(fd, header, 4) != 0) return -1;
    size_t length = ((size_t)header[0] << 24) | ((size_t)header[1] << 16)
        | ((size_t)header[2] << 8) | (size_t)header[3];
    if (length == 0 || length + 1 > cap) return -1;
    if (read_full(fd, body, length) != 0) return -1;
    body[length] = 0;
    return (int)length;
}

static int write_frame(int fd, const char *body) {
    size_t length = strlen(body);
    unsigned char header[4] = {
        (unsigned char)((length >> 24) & 0xff),
        (unsigned char)((length >> 16) & 0xff),
        (unsigned char)((length >> 8) & 0xff),
        (unsigned char)(length & 0xff),
    };
    if (write_full(fd, header, 4) != 0) return -1;
    return write_full(fd, body, length);
}

static int extract(const char *json, const char *key, char *out, size_t cap) {
    char pattern[64];
    snprintf(pattern, sizeof pattern, "\"%s\":\"", key);
    const char *found = strstr(json, pattern);
    if (found == NULL) return -1;
    found += strlen(pattern);
    size_t used = 0;
    while (found[used] != 0 && found[used] != '"' && used + 1 < cap) {
        out[used] = found[used];
        used++;
    }
    if (found[used] != '"') return -1;
    out[used] = 0;
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    pid_t child = fork();
    if (child < 0) return 3;
    if (child == 0) {
        for (int attempt = 0; attempt < 400; attempt++) {
            if (access("command-started", F_OK) == 0) break;
            usleep(50000);
        }
        sleep(8);
        int escaped = open("escaped", O_WRONLY | O_CREAT | O_EXCL, 0644);
        if (escaped >= 0) close(escaped);
        _exit(0);
    }
    char grant[8192];
    if (read_frame(5, grant, sizeof grant) < 0) return 4;
    char capability[80];
    char session[80];
    if (extract(grant, "capability", capability, sizeof capability) != 0) return 5;
    if (extract(grant, "session", session, sizeof session) != 0) return 5;
    char body[2048];
    int wrote = snprintf(body, sizeof body,
        "{\"v\":1,\"id\":\"dddddddd-dddd-dddd-dddd-dddddddddddd\",\"capability\":\"%s\",\"session\":\"%s\",\"command\":\"%s\"}",
        capability, session, argv[1]);
    if (wrote < 0 || (size_t)wrote >= sizeof body) return 6;
    if (write_frame(4, body) != 0) return 7;
    for (int attempt = 0; attempt < 200; attempt++) {
        if (access("command-started", F_OK) == 0) _exit(0);
        usleep(50000);
    }
    return 8;
}
"""#
#endif
