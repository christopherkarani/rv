#if os(macOS)
import Darwin
import Foundation
import RVDomain
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
        var terminateSucceeds = true
        var reports: [String] = []
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
                terminate: {
                    self.terminated.append($0)
                    return self.terminateSucceeds
                },
                report: { self.reports.append($0) },
                recordLaunch: { pid, _ in self.recorded.append(pid) },
                canonicalize: { $0 },
                now: { self.now },
                pause: { self.now = self.now.addingTimeInterval(0.05) }
            )
        }
    }

    static let endpoint = WorkspaceEndpoint(
        host: WorkspaceHostID(rawValue: UUID()),
        workspace: UUID(),
        canonicalPath: "/p",
        socketPath: "/p.sock",
        socketDevice: 1,
        socketInode: 2,
        ownerToken: UUID(),
        uid: getuid()
    )

    /// The endpoint the spawned child (pid 4242) published.
    private static let ownEndpoint: WorkspaceEndpoint = {
        var own = endpoint
        own.hostPID = 4242
        return own
    }()

    /// Another host's endpoint for the same project (a new socket).
    private static let otherEndpoint: WorkspaceEndpoint = {
        var other = endpoint
        other.host = WorkspaceHostID(rawValue: UUID())
        other.socketInode = 3
        other.hostPID = 999
        return other
    }()

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
        let script = Script(attachments: [.absent, .starting(nil), .live(Self.ownEndpoint)], probes: [.failure(.unauthorizedClient)])
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

    /// Mount and recovery run before the endpoint is published. A host
    /// still starting or recovering at the deadline keeps going in the
    /// background; killing it would interrupt recovery on every attempt.
    /// It is recorded then, so `rv workspace close` can stop it later.
    @Test(arguments: [WorkspaceAttachment.starting(nil), .recovering(UUID())])
    func hostStillStartingOrRecoveringOutlivesTheTimeout(_ state: WorkspaceAttachment) {
        let script = Script(attachments: [.absent, state])
        #expect(Self.ensure(script, timeout: 2) == .failure(.stillStarting))
        #expect(script.spawned == [4242])
        #expect(script.terminated.isEmpty)
        #expect(script.recorded == [4242])
    }

    /// Every other state at the deadline leaves a host nobody can use or
    /// stop later (no endpoint of its own, so no launch record): stop it.
    @Test(arguments: [
        WorkspaceAttachment.absent, .orphaned(UUID()), .staleEndpoint, .live(WorkspaceHostEnsureTests.endpoint),
    ])
    func timeoutStopsOurHostInEveryOtherState(_ last: WorkspaceAttachment) {
        // `.live` answers "closing" (describe says not active): never ready.
        let script = Script(attachments: [.absent, .starting(nil), last], probes: [.success(false)])
        #expect(Self.ensure(script, timeout: 2) == .failure(.timedOut))
        #expect(script.spawned == [4242])
        #expect(script.terminated == [4242])
        #expect(script.recorded.isEmpty)
    }

    /// A host that published its endpoint always gets the full readiness
    /// window, even past a shorter overall timeout (the TUI uses 15 s), and
    /// is then stopped as not answering.
    @Test func publishedHostAlwaysGetsItsFullReadinessWindow() {
        let script = Script(attachments: [.absent, .live(Self.ownEndpoint)], probes: [.failure(.disconnected)])
        let started = script.now
        #expect(Self.ensure(script, timeout: 2) == .failure(.notAnswering))
        #expect(script.now.timeIntervalSince(started) >= WorkspaceHosts.readinessTimeout)
        #expect(script.terminated == [4242])
        #expect(script.recorded == [4242])
    }

    /// A describe answer (the workspace is closing) restarts the clock.
    @Test func describeAnswerRestartsTheClock() {
        let tenSeconds = Array(repeating: Result<Bool, WorkspaceClientFailure>.failure(.disconnected), count: 200)
        let script = Script(
            attachments: [.live(Self.endpoint)], probes: tenSeconds + [.success(false), .failure(.disconnected)]
        )
        let started = script.now
        #expect(Self.ensure(script) == .failure(.notAnswering))
        #expect(script.now.timeIntervalSince(started) >= 10 + WorkspaceHosts.readinessTimeout - 0.1)
    }

    /// A child that outlives SIGKILL is reported through the seam (the TUI
    /// must not get a stray stderr line in raw mode).
    @Test func stuckChildIsReportedThroughTheSeam() {
        let script = Script(attachments: [.absent, .live(Self.ownEndpoint)], probes: [.failure(.unauthorizedClient)])
        script.terminateSucceeds = false
        #expect(Self.ensure(script) == .failure(.control(.unauthorizedClient)))
        #expect(script.reports.count == 1)
        #expect(script.reports.first?.contains("4242") == true)
        let quiet = Script(attachments: [.absent, .live(Self.ownEndpoint)], probes: [.failure(.unauthorizedClient)])
        _ = Self.ensure(quiet)
        #expect(quiet.reports.isEmpty)
    }

    /// A refused race winner: our child is stopped, and the winner's
    /// endpoint is never recorded as ours.
    @Test func refusedRaceWinnerStopsOurChildWithoutRecordingIt() {
        let script = Script(attachments: [.absent, .live(Self.otherEndpoint)], probes: [.failure(.unauthorizedClient)])
        #expect(Self.ensure(script) == .failure(.control(.unauthorizedClient)))
        #expect(script.terminated == [4242])
        #expect(script.recorded.isEmpty)
    }

    /// The readiness clock belongs to one endpoint: a new host (new socket,
    /// new pid) gets its own 15 s.
    @Test func readinessClockRestartsForANewEndpoint() {
        let tenSeconds = Array(repeating: WorkspaceAttachment.live(Self.endpoint), count: 200)
        let script = Script(attachments: tenSeconds + [.live(Self.otherEndpoint)], probes: [.failure(.disconnected)])
        let started = script.now
        #expect(Self.ensure(script) == .failure(.notAnswering))
        #expect(script.now.timeIntervalSince(started) >= 10 + WorkspaceHosts.readinessTimeout - 0.1)
    }

    /// Leaving `.live` (the host went back to starting) restarts the clock.
    @Test func readinessClockRestartsAfterLeavingLive() {
        let tenSeconds = Array(repeating: WorkspaceAttachment.live(Self.endpoint), count: 200)
        let script = Script(
            attachments: tenSeconds + [.starting(nil), .live(Self.endpoint)], probes: [.failure(.disconnected)]
        )
        let started = script.now
        #expect(Self.ensure(script) == .failure(.notAnswering))
        #expect(script.now.timeIntervalSince(started) >= 10 + WorkspaceHosts.readinessTimeout - 0.1)
    }

    /// The launch record names our child only once it owns the endpoint: a
    /// spawn that loses the race must not overwrite the winner's record.
    @Test func launchIsRecordedOnlyForOurOwnEndpoint() {
        let lost = Script(attachments: [.absent, .live(Self.otherEndpoint)], probes: [.success(true)])
        #expect(Self.ensure(lost) == .success(Self.otherEndpoint))
        #expect(lost.recorded.isEmpty)
        let won = Script(attachments: [.absent, .live(Self.ownEndpoint)], probes: [.success(true)])
        #expect(Self.ensure(won) == .success(Self.ownEndpoint))
        #expect(won.recorded == [4242])
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

    /// A recovery block ends with the host exiting by itself; it is not
    /// interrupted mid-recovery.
    @Test func recoveryBlockDoesNotSignalTheSpawnedHost() {
        let block = WorkspaceRecoveryBlock(workspace: nil, reason: .corrupt)
        let script = Script(attachments: [.absent, .blocked(block)])
        #expect(Self.ensure(script) == .failure(.recoveryBlocked(block)))
        #expect(script.spawned == [4242])
        #expect(script.terminated.isEmpty)
    }

    /// A workspace that is closing stays a poll, not a readiness failure.
    @Test func closingWorkspaceIsNotCountedAsUnanswered() {
        let script = Script(attachments: [.live(Self.endpoint)], probes: [.success(false)])
        #expect(Self.ensure(script, timeout: 30) == .failure(.timedOut))
    }
}

/// Stopping a spawned child never blocks: SIGKILL is followed by a bounded
/// poll, not an unbounded `waitpid`.
@Suite struct WorkspaceHostTerminateTests {
    private final class Child {
        var signals: [Int32] = []
        var diesOn: Int32?
        var dead = false
        var now = Date(timeIntervalSince1970: 0)

        func seams() -> WorkspaceHosts.TerminateSeams {
            WorkspaceHosts.TerminateSeams(
                signal: { _, signal in
                    self.signals.append(signal)
                    if signal == self.diesOn { self.dead = true }
                },
                reap: { _ in self.dead ? 0 : nil },
                now: { self.now },
                pause: { self.now = self.now.addingTimeInterval(0.05) }
            )
        }
    }

    @Test func termIsEnough() {
        let child = Child()
        child.diesOn = SIGTERM
        #expect(WorkspaceHosts.terminateChild(4242, seams: child.seams()))
        #expect(child.signals == [SIGTERM])
    }

    @Test func killAfterGrace() {
        let child = Child()
        child.diesOn = SIGKILL
        #expect(WorkspaceHosts.terminateChild(4242, seams: child.seams()))
        #expect(child.signals == [SIGTERM, SIGKILL])
    }

    @Test func unkillableChildIsReportedWithoutBlocking() {
        let child = Child()
        #expect(WorkspaceHosts.terminateChild(4242, seams: child.seams()) == false)
        #expect(child.signals == [SIGTERM, SIGKILL])
        #expect(child.now.timeIntervalSince1970 <= 2 * WorkspaceHosts.terminateGraceSeconds + 0.2)
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
        var sessionLeader = true
        var ownUser = true
        var now = Date(timeIntervalSince1970: 0)

        func seams() -> WorkspaceHostLaunchRecord.StopSeams {
            WorkspaceHostLaunchRecord.StopSeams(
                lookup: { pid in
                    self.alive
                        ? .found(ProcessIdentity(pid: UInt32(pid), parent: 1, group: UInt32(pid), startSeconds: self.startSeconds, startMicroseconds: 7))
                        : .absent
                },
                executable: { _ in self.executable },
                isSessionLeader: { _ in self.sessionLeader },
                isOwnUser: { _ in self.ownUser },
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

    private static func stop(
        _ kernel: Kernel, _ launch: WorkspaceHostLaunch? = launch, endpointPID: Int32? = 777
    ) -> WorkspaceHostStop {
        WorkspaceHostLaunchRecord.stop(launch, endpointPID: endpointPID, installedHost: host, seams: kernel.seams())
    }

    /// An older launch record must not stop a newer host: the endpoint
    /// close failed to reach has to name the recorded pid.
    @Test func endpointOfAnotherHostIsLeftAlone() {
        let newer = Kernel()
        guard case .leftAlone(let why) = Self.stop(newer, endpointPID: 888) else {
            Issue.record("a record for another pid must not stop the endpoint's host")
            return
        }
        #expect(why.contains("888"))
        #expect(newer.signals.isEmpty)
    }

    /// An older host does not name its pid in the endpoint: nothing proves
    /// the record is its own, so close leaves it alone.
    @Test func endpointWithoutAPidIsLeftAlone() {
        let older = Kernel()
        guard case .leftAlone = Self.stop(older, endpointPID: nil) else {
            Issue.record("an endpoint without a pid must be left alone")
            return
        }
        #expect(older.signals.isEmpty)
    }

    /// The real kernel checks: this test process is ours; launchd (pid 1)
    /// is root's. A child spawned with SETSID leads its session; one
    /// spawned without it does not.
    @Test func liveIdentityChecksReadTheKernel() throws {
        let seams = WorkspaceHostLaunchRecord.StopSeams()
        #expect(seams.isOwnUser(getpid()))
        #expect(seams.isOwnUser(1) == false)
        let leader = try Self.spawnSleeper(setsid: true)
        defer { Self.reap(leader) }
        #expect(seams.isSessionLeader(leader))
        let follower = try Self.spawnSleeper(setsid: false)
        defer { Self.reap(follower) }
        #expect(seams.isSessionLeader(follower) == false)
    }

    private static func spawnSleeper(setsid: Bool) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        if setsid {
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        }
        var pid: pid_t = 0
        let arguments: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("30"), nil]
        defer { arguments.forEach { free($0) } }
        let spawned = posix_spawn(&pid, "/bin/sleep", nil, &attributes, arguments, environ)
        try #require(spawned == 0 && pid > 0)
        return pid
    }

    private static func reap(_ pid: pid_t) {
        kill(pid, SIGKILL)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
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

    /// The host calls setsid and runs as this user; a pid that does not is
    /// not the host rv launched.
    @Test func nonLeaderOrForeignUserIsLeftAlone() {
        let follower = Kernel()
        follower.sessionLeader = false
        guard case .leftAlone = Self.stop(follower) else {
            Issue.record("a process that is not its session leader must be left alone")
            return
        }
        #expect(follower.signals.isEmpty)
        let foreign = Kernel()
        foreign.ownUser = false
        guard case .leftAlone = Self.stop(foreign) else {
            Issue.record("another user's process must be left alone")
            return
        }
        #expect(foreign.signals.isEmpty)
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

/// The endpoint file carries the publishing host's pid; a file from an
/// older host without it still loads, with no pid.
@Suite struct WorkspaceEndpointPIDTests {
    private static func record(pid: Int32?) -> WorkspaceEndpointRecord {
        WorkspaceEndpointRecord(
            v: WorkspaceControlLimits.version, host: UUID(), workspace: UUID(), canonicalPath: "/p",
            socketPath: "/p.sock", socketDevice: 1, socketInode: 2, ownerToken: UUID(),
            lockPath: "/p.lock", lockDevice: 1, lockInode: 3, uid: getuid(), pid: pid
        )
    }

    private static func roundTrip(_ record: WorkspaceEndpointRecord) throws -> (WorkspaceEndpointRecord?, String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-endpoint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("endpoint.json")
        try #require(WorkspaceEndpointStore.write(record, to: url))
        let text = try String(contentsOf: url, encoding: .utf8)
        return (WorkspaceEndpointStore.load(from: url), text)
    }

    @Test func pidRoundTrips() throws {
        let written = Self.record(pid: 4242)
        let (loaded, text) = try Self.roundTrip(written)
        #expect(text.contains(#""pid":4242"#))
        #expect(loaded == written)
        #expect(loaded?.endpoint().hostPID == 4242)
    }

    @Test func olderHostWithoutPidStillLoads() throws {
        let written = Self.record(pid: nil)
        let (loaded, text) = try Self.roundTrip(written)
        #expect(text.contains("pid") == false)
        #expect(loaded == written)
        #expect(loaded?.endpoint().hostPID == nil)
    }
}
#endif
