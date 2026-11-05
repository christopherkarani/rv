#if os(macOS)
import Darwin
import Foundation
import RVDomain
import Synchronization
import Testing
@testable import RVIsolation

/// Routing of legacy frames at the `LiveSeatbeltChild` seam: before the
/// watch finishes a submit parks in the pending slot for the watch
/// thread's drain; after it finishes the same interface runs the frame
/// on the caller's thread. The decision is atomic in the child module,
/// so a finish racing a parked submit still answers it.
@Suite("LiveSeatbeltChildLegacyRouting", .serialized)
struct LiveSeatbeltChildLegacyRoutingTests {
    @Test func beforeFinishSubmitIsAnsweredByWatchThreadDrain() throws {
        let fixture = try LegacyRoutingFixture()
        defer { fixture.cleanup() }
        let child = fixture.child

        let submitted = DecisionBox()
        let caller = startThread(named: "rv-test-caller") {
            submitted.store(child.submitLegacy(fixture.frame()))
        }
        // The watch thread drains until the parked frame is answered.
        let watch = startThread(named: "rv-test-watch") {
            let deadline = Date().addingTimeInterval(10)
            while submitted.isStored == false, Date() < deadline {
                child.drainPending()
                usleep(5_000)
            }
        }
        join(caller)
        join(watch)

        let decision = try #require(submitted.value)
        #expect(decision?.response == .evaluationFailed)
        #expect(fixture.recorder.snapshot == ["rv-test-watch"])
        #expect(child.isWatchFinished == false)
    }

    @Test func occupiedSlotRefusesSecondSubmitUntilDrained() throws {
        let fixture = try LegacyRoutingFixture()
        defer { fixture.cleanup() }
        let child = fixture.child

        let first = DecisionBox()
        let caller = startThread(named: "rv-test-caller") {
            first.store(child.submitLegacy(fixture.frame()))
        }
        // The first submit parks immediately on its thread; give it the
        // slot before probing with a second submit.
        usleep(100_000)
        let second = child.submitLegacy(fixture.frame(id: UUID()))
        #expect(second == nil)
        #expect(fixture.recorder.snapshot.isEmpty)

        child.drainPending()
        join(caller)
        let decision = try #require(first.value)
        #expect(decision?.response == .evaluationFailed)
        #expect(fixture.recorder.snapshot.count == 1)
    }

    @Test func afterFinishSubmitRunsDirectOnCallerThread() throws {
        let fixture = try LegacyRoutingFixture()
        defer { fixture.cleanup() }
        let child = fixture.child

        child.markWatchFinished()
        #expect(child.isWatchFinished)
        #expect(fixture.recorder.snapshot.isEmpty)

        let submitted = DecisionBox()
        let caller = startThread(named: "rv-test-caller") {
            submitted.store(child.submitLegacy(fixture.frame()))
        }
        join(caller)

        let decision = try #require(submitted.value)
        #expect(decision?.response == .evaluationFailed)
        #expect(fixture.recorder.snapshot == ["rv-test-caller"])
    }

    @Test func finishRacingParkedSubmitStillAnswersOnCallerThread() throws {
        let fixture = try LegacyRoutingFixture()
        defer { fixture.cleanup() }
        let child = fixture.child

        let submitted = DecisionBox()
        let caller = startThread(named: "rv-test-caller") {
            submitted.store(child.submitLegacy(fixture.frame()))
        }
        usleep(100_000)
        // No drain ever comes: the finish flips routing and the waiting
        // caller claims its parked frame back and runs it direct.
        let watch = startThread(named: "rv-test-watch") {
            child.markWatchFinished()
        }
        join(watch)
        join(caller)

        let decision = try #require(submitted.value)
        #expect(decision?.response == .evaluationFailed)
        #expect(fixture.recorder.snapshot == ["rv-test-caller"])
        #expect(child.isWatchFinished)
    }

    @Test func finishIsIdempotentAndDrainAfterFinishIsNoOp() throws {
        let fixture = try LegacyRoutingFixture()
        defer { fixture.cleanup() }
        let child = fixture.child

        child.markWatchFinished()
        child.markWatchFinished()
        child.drainPending()
        #expect(child.isWatchFinished)
        #expect(fixture.recorder.snapshot.isEmpty)
    }
}

/// Records which thread executed each admission submit. `submitCore`
/// reads the configured policy on its executing thread, once per submit.
private final class ExecutionRecorder: Sendable {
    private let threads = Mutex<[String]>([])

    func record() {
        threads.withLock { $0.append(Thread.current.name ?? "<unnamed>") }
    }

    var snapshot: [String] { threads.withLock { $0 } }
}

private final class DecisionBox: Sendable {
    private let stored = Mutex<RuntimeAdmissionDecision??>(nil)

    func store(_ decision: RuntimeAdmissionDecision?) {
        stored.withLock { $0 = .some(decision) }
    }

    var isStored: Bool { stored.withLock { $0 != nil } }

    var value: RuntimeAdmissionDecision?? { stored.withLock { $0 } }
}

private func startThread(named name: String, _ body: @escaping @Sendable () -> Void) -> Thread {
    let thread = Thread(block: body)
    thread.name = name
    thread.start()
    return thread
}

private func join(_ thread: Thread) {
    let deadline = Date().addingTimeInterval(15)
    while thread.isFinished == false, Date() < deadline {
        usleep(5_000)
    }
    #expect(thread.isFinished)
}

/// A child whose admission never executes: normalize fails, so every
/// routed frame answers `.evaluationFailed` on the executing thread.
private struct LegacyRoutingFixture {
    let root: URL
    let runtime: RuntimeSession
    let capability: RuntimeCapability
    let recorder: ExecutionRecorder
    let child: LiveSeatbeltChild

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-legacy-routing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = try #require(WorkingDirectory(validating: root.path))
        let runtime = RuntimeSession(
            id: RuntimeSessionID(),
            workspaceSessionID: WorkspaceSessionID(),
            host: .opencode,
            workspace: workspace,
            backend: .seatbelt,
            startedAt: Date(),
            child: nil
        )
        let capability = RuntimeCapability()
        let recorder = ExecutionRecorder()
        let admission = RuntimeAdmissionSession(
            binding: RuntimeChannelBinding(session: runtime, capability: capability),
            configuration: RuntimeAdmissionConfiguration(
                normalize: { _, _ in .failure(.failed) },
                executor: .refuse,
                approval: { _, _ in nil },
                policy: { _ in
                    recorder.record()
                    return .empty
                },
                evidence: RuntimeAdmissionEvidence()
            ),
            launch: AdmittedLaunchContext(
                plan: compileContainedPlan(workspace: workspace),
                profileSource: "(deny file-link)",
                profileIsContainedCompilerOutput: true,
                workspacePath: workspace.rawValue
            ),
            requestRead: -1,
            responseWrite: -1
        )
        let child = LiveSeatbeltChild(
            session: runtime,
            capability: capability,
            pid: getpid(),
            nonce: "legacy-routing-test",
            admission: admission,
            parentDescriptors: [],
            handshakeRead: -1,
            terminal: nil,
            resources: nil
        )
        // The tests play the watch thread themselves; without this,
        // deinit would reap the (fictional) unwatched session group.
        child.markWatchStarted()
        self.root = root
        self.runtime = runtime
        self.capability = capability
        self.recorder = recorder
        self.child = child
    }

    func frame(id: UUID = UUID()) -> RuntimeActionFrame {
        RuntimeActionFrame(
            version: 1,
            requestID: RuntimeActionRequestID(validating: id.uuidString)!,
            capability: capability,
            claimedSession: RuntimeSessionClaim(validating: runtime.id.rawValue.uuidString)!,
            action: .shell(ShellCommand(rawValue: "echo hello"))
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
#endif
