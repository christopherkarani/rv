#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import RVIsolation

/// `WorkspaceHosts.ensure` with every process and socket effect injected:
/// no host binary, no manifest, no real clock.
@Suite struct WorkspaceHostEnsureTests {
    /// A clock that advances only when the loop pauses.
    private final class Script {
        var now = Date(timeIntervalSince1970: 1_000)
        var attachments: [WorkspaceAttachment]
        var probes: [Result<Bool, WorkspaceClientFailure>]
        var spawned: [pid_t] = []
        var recorded: [pid_t] = []
        var terminated: [pid_t] = []
        var exits: [pid_t: Int32] = [:]

        init(attachments: [WorkspaceAttachment], probes: [Result<Bool, WorkspaceClientFailure>] = []) {
            self.attachments = attachments
            self.probes = probes
        }

        func seams() -> WorkspaceHosts.EnsureSeams {
            WorkspaceHosts.EnsureSeams(
                inspect: { _ in self.attachments.count > 1 ? self.attachments.removeFirst() : self.attachments[0] },
                probe: { _ in self.probes.count > 1 ? self.probes.removeFirst() : self.probes[0] },
                spawn: { _, _ in
                    self.spawned.append(4242)
                    return .success(4242)
                },
                reap: { self.exits[$0] },
                terminate: { self.terminated.append($0) },
                recordLaunch: { pid, _ in self.recorded.append(pid) },
                now: { self.now },
                pause: { self.now = self.now.addingTimeInterval(0.05) }
            )
        }
    }

    private static let endpoint = WorkspaceEndpoint(
        host: WorkspaceHostID(rawValue: UUID()),
        workspace: UUID(),
        canonicalPath: "/p",
        socketPath: "/p.sock",
        socketDevice: 1,
        socketInode: 2,
        ownerToken: UUID(),
        uid: getuid()
    )

    private static func ensure(_ script: Script, timeout: TimeInterval = 90) -> Result<WorkspaceEndpoint, WorkspaceHostFailure> {
        WorkspaceHosts.ensure(
            project: "/p",
            executable: URL(fileURLWithPath: "/bin/rv-workspace-host"),
            timeout: timeout,
            homeDirectory: "/home",
            seams: script.seams()
        )
    }

    /// The live failure: the host this start spawned is not the build the
    /// manifest pins, so every connect is refused. Fail at once (not at the
    /// 90 s deadline) and stop the host instead of orphaning it.
    @Test func refusedHostFailsFastAndIsStopped() {
        let script = Script(attachments: [.absent, .starting(nil), .live(Self.endpoint)], probes: [.failure(.unauthorizedClient)])
        #expect(Self.ensure(script) == .failure(.control(.unauthorizedClient)))
        #expect(script.spawned == [4242])
        #expect(script.recorded == [4242])
        #expect(script.terminated == [4242])
        #expect(script.now.timeIntervalSince1970 < 1_001)
    }

    /// A live endpoint nobody answers on: bounded by the readiness timeout,
    /// not the overall startup timeout.
    @Test func unansweredEndpointGivesUpAfterReadinessTimeout() {
        let script = Script(attachments: [.absent, .live(Self.endpoint)], probes: [.failure(.disconnected)])
        let started = script.now
        #expect(Self.ensure(script) == .failure(.notAnswering))
        let waited = script.now.timeIntervalSince(started)
        #expect(waited >= WorkspaceHosts.readinessTimeout)
        #expect(waited < WorkspaceHosts.readinessTimeout + 1)
        #expect(script.terminated == [4242])
    }

    @Test func readinessTimeoutIsFifteenSeconds() {
        #expect(WorkspaceHosts.readinessTimeout == 15)
    }

    @Test func overallTimeoutStopsTheSpawnedHost() {
        let script = Script(attachments: [.absent, .starting(nil)])
        #expect(Self.ensure(script, timeout: 2) == .failure(.timedOut))
        #expect(script.terminated == [4242])
    }

    @Test func answeringHostIsKeptRunning() {
        let script = Script(attachments: [.absent, .live(Self.endpoint)], probes: [.failure(.disconnected), .success(true)])
        #expect(Self.ensure(script) == .success(Self.endpoint))
        #expect(script.terminated.isEmpty)
    }

    /// A refused host this call did not spawn belongs to an earlier start;
    /// `ensure` reports it and leaves it to `rv workspace close`.
    @Test func refusedHostFromAnEarlierStartIsNotSignalled() {
        let script = Script(attachments: [.live(Self.endpoint)], probes: [.failure(.unauthorizedClient)])
        #expect(Self.ensure(script) == .failure(.control(.unauthorizedClient)))
        #expect(script.spawned.isEmpty)
        #expect(script.terminated.isEmpty)
    }

    /// A spawned host that already exited needs no signal.
    @Test func exitedChildIsNotSignalled() {
        let script = Script(attachments: [.absent, .starting(nil)])
        script.exits[4242] = 1 << 8
        #expect(Self.ensure(script) == .failure(.hostExited(1)))
        #expect(script.terminated.isEmpty)
    }

    /// A workspace that is closing stays a poll, not a readiness failure.
    @Test func closingWorkspaceIsNotCountedAsUnanswered() {
        let script = Script(attachments: [.live(Self.endpoint)], probes: [.success(false)])
        #expect(Self.ensure(script, timeout: 30) == .failure(.timedOut))
    }
}

/// `rv workspace close` stopping a host that never answered.
@Suite struct WorkspaceHostLaunchStopTests {
    private static let launch = WorkspaceHostLaunch(v: 1, pid: 777, startSeconds: 50, startMicroseconds: 7)
    private static let host = "/Users/u/.local/bin/rv-workspace-host"

    private final class Kernel {
        var alive = true
        var startSeconds: UInt64 = 50
        var executable: String? = WorkspaceHostLaunchStopTests.host
        var signals: [Int32] = []
        var diesOn: Int32? = SIGTERM
        var now = Date(timeIntervalSince1970: 0)

        func seams() -> WorkspaceHostLaunchRecord.StopSeams {
            WorkspaceHostLaunchRecord.StopSeams(
                lookup: { pid in
                    self.alive
                        ? .found(ProcessIdentity(pid: UInt32(pid), parent: 1, group: UInt32(pid), startSeconds: self.startSeconds, startMicroseconds: 7))
                        : .absent
                },
                executable: { _ in self.executable },
                resolve: { $0 },
                signal: { _, signal in
                    self.signals.append(signal)
                    if signal == self.diesOn { self.alive = false }
                },
                now: { self.now },
                pause: { self.now = self.now.addingTimeInterval(0.05) },
                grace: 2
            )
        }
    }

    private static func stop(_ kernel: Kernel, _ launch: WorkspaceHostLaunch? = launch) -> WorkspaceHostStop {
        WorkspaceHostLaunchRecord.stop(launch, installedHost: host, seams: kernel.seams())
    }

    @Test func stopsTheRecordedInstalledHost() {
        let kernel = Kernel()
        #expect(Self.stop(kernel) == .stopped(777))
        #expect(kernel.signals == [SIGTERM])
    }

    @Test func escalatesToSigkillAfterGrace() {
        let kernel = Kernel()
        kernel.diesOn = SIGKILL
        #expect(Self.stop(kernel) == .stopped(777))
        #expect(kernel.signals == [SIGTERM, SIGKILL])
    }

    /// Pid reuse: same pid, different start time. Never signalled.
    @Test func reusedPidIsNotSignalled() {
        let kernel = Kernel()
        kernel.startSeconds = 99
        #expect(Self.stop(kernel) == .notRunning)
        #expect(kernel.signals.isEmpty)
    }

    /// The recorded process runs something other than rv's installed host.
    @Test func foreignExecutableIsLeftAlone() {
        let kernel = Kernel()
        kernel.executable = "/usr/bin/vim"
        guard case .leftAlone(let why) = Self.stop(kernel) else {
            Issue.record("a non-rv process must be left alone")
            return
        }
        #expect(why.contains("/usr/bin/vim"))
        #expect(kernel.signals.isEmpty)
    }

    @Test func unreadableExecutableIsLeftAlone() {
        let kernel = Kernel()
        kernel.executable = nil
        guard case .leftAlone = Self.stop(kernel) else {
            Issue.record("an unproven process must be left alone")
            return
        }
        #expect(kernel.signals.isEmpty)
    }

    @Test func noRecordAndExitedHost() {
        #expect(Self.stop(Kernel(), nil) == .noRecord)
        let gone = Kernel()
        gone.alive = false
        #expect(Self.stop(gone) == .notRunning)
        #expect(gone.signals.isEmpty)
    }

    @Test func survivorIsReported() {
        let kernel = Kernel()
        kernel.diesOn = nil
        #expect(Self.stop(kernel) == .stillRunning(777))
        #expect(kernel.signals == [SIGTERM, SIGKILL])
    }

    @Test func launchRecordRoundTripsAndRejectsJunk() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-launch-record-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = WorkspaceHostLaunchRecord.file(in: dir, canonicalPath: "/p")
        #expect(url.lastPathComponent.hasSuffix(".launch.json"))
        #expect(WorkspaceEndpointStore.writeOwnerFile(try JSONEncoder().encode(Self.launch), to: url))
        #expect(WorkspaceHostLaunchRecord.load(from: url) == Self.launch)
        try Data(#"{"v":1,"pid":1,"startSeconds":0,"startMicroseconds":0}"#.utf8).write(to: url)
        #expect(WorkspaceHostLaunchRecord.load(from: url) == nil)
    }
}
#endif
