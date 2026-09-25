import Foundation
import Testing
@testable import RVWorkspaceTUI

final class FakeWorkspaceSession: WorkspaceTUISession, @unchecked Sendable {
    private let lock = NSLock()
    private var storedSummary: WorkspaceTUISummary
    private var storedRuntimes: [ListedRuntime] = []
    private var storedFailLaunch = false
    private var storedFailSubscribe = false
    private var storedBusyInput = false
    private var storedBusyWrite = false
    private var storedFailDescribe = false
    private var storedFailPoll = false
    private var storedDisconnectOnAttach = false
    private var storedWrites: [(UUID, Data)] = []
    private var storedCancels: [UUID] = []
    private var storedSubscribes: [UUID] = []
    private var storedUnsubscribes: [UUID] = []
    private var storedAcquires: [UUID] = []
    private var storedReleases: [UUID] = []
    private var storedResizes: [(UUID, Int, Int)] = []
    private var storedDetached = false
    private var storedEvents: [WorkspaceTUIEvent] = []
    private var storedLaunchAttempts = 0
    private var launchesToBlock = 0
    private var writesToBlock = 0
    private var resizesToBlock = 0
    private var cancelsToBlock = 0
    let writeStarted = DispatchSemaphore(value: 0)
    let writeGate = DispatchSemaphore(value: 0)
    let resizeStarted = DispatchSemaphore(value: 0)
    let resizeGate = DispatchSemaphore(value: 0)
    let cancelStarted = DispatchSemaphore(value: 0)
    let cancelGate = DispatchSemaphore(value: 0)
    let launchStarted = DispatchSemaphore(value: 0)
    let launchGate = DispatchSemaphore(value: 0)

    var summary: WorkspaceTUISummary {
        get { withLock { storedSummary } }
        set { withLock { storedSummary = newValue } }
    }
    var runtimes: [ListedRuntime] {
        get { withLock { storedRuntimes } }
        set { withLock { storedRuntimes = newValue } }
    }
    var failLaunch: Bool {
        get { withLock { storedFailLaunch } }
        set { withLock { storedFailLaunch = newValue } }
    }
    var failSubscribe: Bool {
        get { withLock { storedFailSubscribe } }
        set { withLock { storedFailSubscribe = newValue } }
    }
    var busyInput: Bool {
        get { withLock { storedBusyInput } }
        set { withLock { storedBusyInput = newValue } }
    }
    var busyWrite: Bool {
        get { withLock { storedBusyWrite } }
        set { withLock { storedBusyWrite = newValue } }
    }
    var failDescribe: Bool {
        get { withLock { storedFailDescribe } }
        set { withLock { storedFailDescribe = newValue } }
    }
    var failPoll: Bool {
        get { withLock { storedFailPoll } }
        set { withLock { storedFailPoll = newValue } }
    }
    var disconnectOnAttach: Bool {
        get { withLock { storedDisconnectOnAttach } }
        set { withLock { storedDisconnectOnAttach = newValue } }
    }
    var writes: [(UUID, Data)] { withLock { storedWrites } }
    var cancels: [UUID] { withLock { storedCancels } }
    var subscribes: [UUID] { withLock { storedSubscribes } }
    var unsubscribes: [UUID] { withLock { storedUnsubscribes } }
    var acquires: [UUID] { withLock { storedAcquires } }
    var releases: [UUID] { withLock { storedReleases } }
    var resizes: [(UUID, Int, Int)] { withLock { storedResizes } }
    var detached: Bool { withLock { storedDetached } }
    var launchAttempts: Int { withLock { storedLaunchAttempts } }
    var events: [WorkspaceTUIEvent] {
        get { withLock { storedEvents } }
        set { withLock { storedEvents = newValue } }
    }

    init() {
        storedSummary = WorkspaceTUISummary(
            project: "/tmp/project",
            phase: "active",
            protected: true,
            workspace: UUID()
        )
    }

    func inventory() -> Result<SessionInventory, WorkspaceTUIError> {
        let (fails, summary, runtimes) = withLock { (storedFailDescribe, storedSummary, storedRuntimes) }
        if fails { return .failure(.disconnected) }
        let terminals = runtimes
            .filter(\.terminal)
            .sorted { $0.id.uuidString < $1.id.uuidString }
        return .success(SessionInventory(summary: summary, terminals: terminals))
    }

    func attach(_ id: UUID) -> SessionAttachOutcome {
        let (fails, busy, disconnected) = withLock {
            storedSubscribes.append(id)
            return (storedFailSubscribe, storedBusyInput, storedDisconnectOnAttach)
        }
        if disconnected { return .disconnected }
        if fails { return .unavailable }
        if busy { return .readOnly }
        withLock { storedAcquires.append(id) }
        return .owned
    }

    func reacquire(_ id: UUID) -> SessionAttachOutcome {
        let busy = withLock {
            if storedBusyInput { return true }
            storedAcquires.append(id)
            return false
        }
        return busy ? .readOnly : .owned
    }

    func launch(
        executable: String,
        arguments: [String],
        hook: String?,
        rows: Int,
        columns: Int
    ) -> Result<ListedRuntime, WorkspaceTUIError> {
        let (fails, block) = withLock {
            storedLaunchAttempts += 1
            let block = launchesToBlock > 0
            if block { launchesToBlock -= 1 }
            return (storedFailLaunch, block)
        }
        if block {
            launchStarted.signal()
            _ = launchGate.wait(timeout: .now() + 5)
        }
        if fails { return .failure(.rejected) }
        let runtime = ListedRuntime(id: UUID(), hook: hook, running: true, terminal: true, created: true)
        withLock { storedRuntimes.append(runtime) }
        return .success(runtime)
    }

    func ensureTerminal(
        executable: String,
        arguments: [String],
        hook: String?,
        rows: Int,
        columns: Int
    ) -> Result<ListedRuntime, WorkspaceTUIError> {
        if case .success(let inventoried) = inventory(),
            let existing = inventoried.terminals
                .filter(\.running)
                .first
        {
            return .success(existing)
        }
        return launch(
            executable: executable,
            arguments: arguments,
            hook: hook,
            rows: rows,
            columns: columns
        )
    }

    func cancel(_ id: UUID) {
        let block = withLock {
            storedCancels.append(id)
            guard cancelsToBlock > 0 else { return false }
            cancelsToBlock -= 1
            return true
        }
        if block {
            cancelStarted.signal()
            _ = cancelGate.wait(timeout: .now() + 5)
        }
    }

    func release(_ id: UUID) {
        withLock {
            storedReleases.append(id)
            storedUnsubscribes.append(id)
        }
    }

    func send(_ bytes: Data, to id: UUID) -> Result<Void, WorkspaceTUIError> {
        let (block, busy) = withLock {
            storedWrites.append((id, bytes))
            let block = writesToBlock > 0
            if block { writesToBlock -= 1 }
            return (block, storedBusyWrite)
        }
        if block {
            writeStarted.signal()
            _ = writeGate.wait(timeout: .now() + 5)
        }
        return busy ? .failure(.busy) : .success(())
    }

    func resize(_ id: UUID, rows: Int, columns: Int) -> Result<Void, WorkspaceTUIError> {
        let block = withLock {
            storedResizes.append((id, rows, columns))
            guard resizesToBlock > 0 else { return false }
            resizesToBlock -= 1
            return true
        }
        if block {
            resizeStarted.signal()
            _ = resizeGate.wait(timeout: .now() + 5)
        }
        return .success(())
    }

    func close() {
        withLock { storedDetached = true }
    }

    func poll(timeout: TimeInterval) -> SessionPoll {
        withLock {
            if storedEvents.isEmpty == false {
                return .event(storedEvents.removeFirst())
            }
            return storedFailPoll ? .disconnected : .none
        }
    }

    func blockNextWrite() {
        withLock { writesToBlock += 1 }
    }

    func blockNextResize() {
        withLock { resizesToBlock += 1 }
    }

    func blockNextCancel() {
        withLock { cancelsToBlock += 1 }
    }

    func blockNextLaunch() {
        withLock { launchesToBlock += 1 }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

final class RecordingEmulator: TerminalEmulating {
    var columns: Int
    var rows: Int
    var generation = 0
    var fed = Data()
    private var responses: [Data]

    init(columns: Int, rows: Int, responses: [Data] = []) {
        self.columns = columns
        self.rows = rows
        self.responses = responses
    }

    func feed(_ bytes: Data) {
        fed.append(bytes)
        generation += 1
    }

    func resize(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }

    func frame() -> TerminalFrame {
        let cells = (0..<rows).map { _ in
            (0..<columns).map { _ in TerminalCell(text: " ") }
        }
        return TerminalFrame(columns: columns, rows: rows, cells: cells, cursor: nil, generation: generation)
    }

    func takeResponses() -> [Data] {
        defer { responses.removeAll() }
        return responses
    }
}

struct RecordingFactory: TerminalEmulatorFactory {
    var responses: [Data] = []

    func make(columns: Int, rows: Int) -> any TerminalEmulating {
        RecordingEmulator(columns: columns, rows: rows, responses: responses)
    }
}

private func model(_ session: FakeWorkspaceSession) -> WorkspaceTUIModel {
    WorkspaceTUIModel(
        session: session,
        emulators: RecordingFactory(),
        summary: session.summary,
        launcher: [
            RuntimeLaunchChoice(id: "shell", title: "shell", executable: "/bin/sh", arguments: [], hook: nil),
            RuntimeLaunchChoice(id: "opencode", title: "opencode", executable: "/bin/opencode", arguments: [], hook: "opencode"),
        ]
    )
}

@Test func connectAttachesTheFirstExistingRuntimeWithoutLaunching() throws {
    let session = FakeWorkspaceSession()
    let first = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let second = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    session.runtimes = [
        ListedRuntime(id: first, hook: "opencode", running: true, terminal: true),
        ListedRuntime(id: second, hook: nil, running: true, terminal: true),
    ]
    let shell = model(session)
    try shell.connect().get()
    #expect(shell.snapshot().terminal?.runtime == second)
    #expect(session.subscribes == [second])
    #expect(session.runtimes.count == 2)
    #expect(session.launchAttempts == 0)
}

@Test func eventsForUnattachedRuntimesAreIgnored() throws {
    let session = FakeWorkspaceSession()
    let attached = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let other = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    session.runtimes = [
        ListedRuntime(id: attached, hook: nil, running: true, terminal: true),
        ListedRuntime(id: other, hook: nil, running: true, terminal: true),
    ]
    let shell = model(session)
    try shell.connect().get()
    shell.apply([
        .bytes(runtime: other, data: Data("elsewhere".utf8)),
        .exited(runtime: other, status: 3),
        .inputOwner(runtime: other, owned: false),
    ])
    #expect(shell.snapshot().terminal?.runtime == attached)
    #expect(shell.snapshot().terminal?.running == true)
    #expect(shell.snapshot().terminal?.lease == .owned)
    #expect(shell.snapshot().mode == .terminal)
}

@Test func failedLaunchDoesNotCreateATerminal() throws {
    let session = FakeWorkspaceSession()
    let shell = model(session)
    try shell.connect().get()
    session.failLaunch = true
    shell.handle(.character("1"))
    #expect(waitForModel { shell.snapshot().mode == .launcher })
    #expect(session.launchAttempts == 1)
    #expect(shell.snapshot().terminal == nil)
}

@Test func blockingHostWritesDoNotBlockKeyHandling() throws {
    let session = FakeWorkspaceSession()
    session.runtimes = [ListedRuntime(id: UUID(), hook: nil, running: true, terminal: true)]
    let shell = model(session)
    try shell.connect().get()
    session.blockNextWrite()

    shell.handle(.character("A"))
    #expect(session.writeStarted.wait(timeout: .now() + 2) == .success)
    let start = Date()
    shell.handle(.character("B"))
    #expect(Date().timeIntervalSince(start) < 0.1)

    session.writeGate.signal()
    #expect(waitForModel { session.writes.count == 2 })
    #expect(session.writes.map(\.1) == [Data("A".utf8), Data("B".utf8)])
}

@Test func delayedLeaseReleaseDoesNotRevokeANewerLocalAcquire() throws {
    let session = FakeWorkspaceSession()
    let runtime = UUID()
    session.runtimes = [ListedRuntime(id: runtime, hook: nil, running: true, terminal: true)]
    let shell = model(session)
    try shell.connect().get()

    shell.apply([
        .inputOwner(runtime: runtime, owned: false),
        .inputOwner(runtime: runtime, owned: true),
    ])
    #expect(shell.snapshot().terminal?.lease == .owned)
    shell.handle(.character("Q"))
    #expect(waitForModel { session.writes.count == 1 })
}

@Test func renderResizeWorkDoesNotWaitForTheWorkspaceHost() throws {
    let session = FakeWorkspaceSession()
    session.runtimes = [ListedRuntime(id: UUID(), hook: nil, running: true, terminal: true)]
    let shell = model(session)
    try shell.connect().get()
    let now = Date(timeIntervalSince1970: 10_000)
    shell.noteSize(rows: 30, columns: 90, now: now)
    session.blockNextResize()

    let start = Date()
    shell.processPendingWork(now: now.addingTimeInterval(1))
    #expect(Date().timeIntervalSince(start) < 0.1)
    #expect(session.resizeStarted.wait(timeout: .now() + 2) == .success)
    session.resizeGate.signal()
}

@Test func blockedReplacementLaunchDoesNotBlockKeyHandling() throws {
    let session = FakeWorkspaceSession()
    let runtime = UUID()
    session.runtimes = [ListedRuntime(id: runtime, hook: nil, running: true, terminal: true)]
    let shell = model(session)
    try shell.connect().get()
    shell.apply([.exited(runtime: runtime, status: 0)])
    #expect(shell.snapshot().mode == .launcher)
    session.blockNextLaunch()

    let start = Date()
    shell.handle(.character("1"))
    #expect(Date().timeIntervalSince(start) < 0.1)
    #expect(session.launchStarted.wait(timeout: .now() + 2) == .success)
    // While the replacement is blocked the exited terminal stays put and
    // typed input has nowhere to go.
    shell.handle(.character("A"))
    #expect(session.writes.isEmpty)

    session.launchGate.signal()
    #expect(waitForModel { shell.snapshot().terminal?.running == true })
    #expect(shell.snapshot().terminal?.runtime != runtime)
    #expect(session.unsubscribes == [runtime])
    #expect(session.cancels.isEmpty)
}

@Test func emulatorRepliesDoNotBlockEventDelivery() throws {
    let session = FakeWorkspaceSession()
    let runtime = UUID()
    session.runtimes = [ListedRuntime(id: runtime, hook: nil, running: true, terminal: true)]
    let shell = WorkspaceTUIModel(
        session: session,
        emulators: RecordingFactory(responses: [Data("R".utf8)]),
        summary: session.summary,
        launcher: []
    )
    try shell.connect().get()
    session.blockNextWrite()

    let start = Date()
    shell.apply([.bytes(runtime: runtime, data: Data("query".utf8))])
    #expect(Date().timeIntervalSince(start) < 0.1)
    #expect(session.writeStarted.wait(timeout: .now() + 2) == .success)
    session.writeGate.signal()
    #expect(waitForModel { session.writes.count == 1 })
    #expect(session.writes.first?.1 == Data("R".utf8))
}

@Test func emptyWorkspaceDoesNotStartAnArbitraryRuntime() throws {
    let session = FakeWorkspaceSession()
    let shell = model(session)
    try shell.connect().get()
    #expect(shell.snapshot().terminal == nil)
    #expect(session.runtimes.isEmpty)
    #expect(session.subscribes.isEmpty)
}

@Test func emptyWorkspaceCanStartTheConfiguredShellOnce() throws {
    let session = FakeWorkspaceSession()
    let shell = model(session)
    try shell.connect().get()

    shell.launchDefaultRuntimeIfEmpty()

    #expect(session.launchAttempts == 1)
    #expect(shell.snapshot().terminal?.title == "shell")
    #expect(shell.snapshot().terminal?.lease == .owned)
    shell.launchDefaultRuntimeIfEmpty()
    Thread.sleep(forTimeInterval: 0.05)
    #expect(session.launchAttempts == 1)
}

@Test func defaultShellDoesNotLaunchWhenAnExistingRuntimeIsAttached() throws {
    let session = FakeWorkspaceSession()
    let runtime = UUID()
    session.runtimes = [ListedRuntime(id: runtime, hook: "codex", running: true, terminal: true)]
    let shell = model(session)
    try shell.connect().get()

    shell.launchDefaultRuntimeIfEmpty()

    #expect(shell.snapshot().terminal?.runtime == runtime)
    #expect(session.launchAttempts == 0)
}

@Test func failedDefaultShellLaunchFallsBackToTheRuntimeLauncher() throws {
    let session = FakeWorkspaceSession()
    session.failLaunch = true
    let shell = model(session)
    try shell.connect().get()

    shell.launchDefaultRuntimeIfEmpty()

    #expect(waitForModel { shell.snapshot().mode == .launcher })
    #expect(shell.snapshot().terminal == nil)
    #expect(session.launchAttempts == 1)
}

@Test func ensureUsesTheRuntimeThatAppearedAfterInventory() throws {
    let session = FakeWorkspaceSession()
    let shell = model(session)
    try shell.connect().get()
    let runtime = ListedRuntime(id: UUID(), hook: "opencode", running: true, terminal: true)
    session.runtimes = [runtime]

    shell.launchDefaultRuntimeIfEmpty()

    #expect(session.launchAttempts == 0)
    #expect(shell.snapshot().terminal?.runtime == runtime.id)
    #expect(shell.snapshot().terminal?.title == "opencode")
}

@Test func reusedUnhookedRuntimeUsesANeutralTitle() throws {
    let session = FakeWorkspaceSession()
    let shell = model(session)
    try shell.connect().get()
    let runtime = ListedRuntime(id: UUID(), hook: nil, running: true, terminal: true)
    session.runtimes = [runtime]

    shell.launchDefaultRuntimeIfEmpty()

    #expect(shell.snapshot().terminal?.runtime == runtime.id)
    #expect(shell.snapshot().terminal?.title == "runtime")
}

@Test func failedDefaultShellSubscriptionIsMarkedUnavailable() throws {
    let session = FakeWorkspaceSession()
    session.failSubscribe = true
    let shell = model(session)
    try shell.connect().get()

    shell.launchDefaultRuntimeIfEmpty()

    let terminal = try #require(shell.snapshot().terminal)
    #expect(terminal.title == "shell (unavailable)")
    #expect(terminal.subscribed == false)
    #expect(terminal.lease == .readOnly)
    #expect(session.acquires.isEmpty)
}

@Test func unavailableConnectAttachAcquiresNothing() throws {
    let session = FakeWorkspaceSession()
    let runtime = UUID()
    session.runtimes = [ListedRuntime(id: runtime, hook: nil, running: true, terminal: true)]
    session.failSubscribe = true
    let shell = model(session)
    try shell.connect().get()

    let terminal = try #require(shell.snapshot().terminal)
    #expect(terminal.runtime == runtime)
    #expect(terminal.subscribed == false)
    #expect(terminal.lease == .readOnly)
    #expect(session.subscribes == [runtime])
    #expect(session.acquires.isEmpty)
}

@Test func renderRevisionGateDoesNotInvalidateThroughAFullIdleStackDepth() {
    var gate = WorkspaceTUIRefreshGate(revision: 0)
    var invalidations = 0
    for _ in 0..<130_609 {
        if gate.consume(0) { invalidations += 1 }
    }
    #expect(invalidations == 0)
    let changed = gate.consume(1)
    let unchanged = gate.consume(1)
    #expect(changed)
    #expect(unchanged == false)
}

@Test func presentationRevisionChangesForTerminalOutputAndStaysStableWhileIdle() throws {
    let session = FakeWorkspaceSession()
    let runtime = UUID()
    session.runtimes = [ListedRuntime(id: runtime, hook: nil, running: true, terminal: true)]
    let shell = model(session)
    try shell.connect().get()

    let resizeDate = Date().addingTimeInterval(1)
    shell.processPendingWork(now: resizeDate)
    let idleRevision = shell.snapshot().presentationRevision
    for _ in 0..<130_609 {
        shell.processPendingWork(now: resizeDate.addingTimeInterval(1))
    }
    #expect(shell.snapshot().presentationRevision == idleRevision)

    shell.apply([.bytes(runtime: runtime, data: Data("visible output".utf8))])
    #expect(shell.snapshot().presentationRevision > idleRevision)
    #expect(shell.terminalFrame()?.generation == 1)
}

@Test func numberedChoiceLaunchesDirectlyFromAnEmptyWorkspace() throws {
    let session = FakeWorkspaceSession()
    let shell = model(session)
    try shell.connect().get()

    shell.handle(.character("1"))

    #expect(waitForModel { shell.snapshot().terminal != nil })
    #expect(session.launchAttempts == 1)
    #expect(shell.snapshot().terminal?.title == "shell")
    #expect(session.writes.isEmpty)
}

@Test func secondNumberLaunchesOpenCodeDirectlyFromAnEmptyWorkspace() throws {
    let session = FakeWorkspaceSession()
    let shell = model(session)
    try shell.connect().get()

    shell.handle(.character("2"))

    #expect(waitForModel { shell.snapshot().terminal != nil })
    #expect(session.launchAttempts == 1)
    #expect(shell.snapshot().terminal?.title == "opencode")
}

@Test func nIsTerminalInputAndNeverOpensALauncher() throws {
    let session = FakeWorkspaceSession()
    let shell = model(session)
    try shell.connect().get()

    shell.handle(.character("n"))

    #expect(shell.snapshot().mode == .terminal)
    #expect(session.launchAttempts == 0)
    shell.handle(.character("1"))
    #expect(waitForModel { shell.snapshot().terminal?.lease == .owned })

    shell.handle(.character("n"))
    #expect(waitForModel { session.writes.contains { $0.1 == Data("n".utf8) } })
}

@Test func exitedShellOffersTheLauncherAndNumberKeysReplaceIt() throws {
    let session = FakeWorkspaceSession()
    let runtime = UUID()
    session.runtimes = [ListedRuntime(id: runtime, hook: nil, running: true, terminal: true)]
    let shell = model(session)
    try shell.connect().get()

    shell.apply([.exited(runtime: runtime, status: 0)])

    #expect(shell.snapshot().terminal?.running == false)
    #expect(shell.snapshot().terminal?.exitStatus == 0)
    #expect(shell.snapshot().terminal?.lease == .released)
    #expect(shell.snapshot().mode == .launcher)
    #expect(shell.snapshot().terminal?.runtime == runtime)

    shell.handle(.character("1"))

    #expect(waitForModel { shell.snapshot().terminal?.running == true })
    #expect(shell.snapshot().terminal?.runtime != runtime)
    #expect(shell.snapshot().mode == .terminal)
    #expect(session.unsubscribes == [runtime])
    #expect(session.cancels.isEmpty)
    #expect(waitForModel { shell.snapshot().terminal?.lease == .owned })
}

@Test func failedReplacementLaunchKeepsTheExitedTerminal() throws {
    let session = FakeWorkspaceSession()
    let runtime = UUID()
    session.runtimes = [ListedRuntime(id: runtime, hook: nil, running: true, terminal: true)]
    let shell = model(session)
    try shell.connect().get()
    shell.apply([.exited(runtime: runtime, status: 1)])
    session.failLaunch = true

    shell.handle(.character("1"))

    #expect(waitForModel { session.launchAttempts == 1 })
    #expect(shell.snapshot().terminal?.runtime == runtime)
    #expect(shell.snapshot().terminal?.running == false)
    #expect(shell.snapshot().mode == .launcher)
}

@Test func disconnectedWorkspaceRejectsFurtherTerminalInput() throws {
    let session = FakeWorkspaceSession()
    let shell = model(session)
    try shell.connect().get()
    shell.handle(.character("1"))
    #expect(waitForModel { shell.snapshot().terminal?.lease == .owned })
    shell.handle(.character("A"))
    #expect(waitForModel { session.writes.count == 1 })
    shell.hostDisconnected()
    shell.handle(.character("B"))
    #expect(shell.snapshot().connection == .disconnected)
    #expect(shell.snapshot().terminal?.lease == .readOnly)
    #expect(session.writes.count == 1)
}

@Test func detachReleasesInputAndUnsubscribesWithoutClosingTheRuntime() throws {
    let session = FakeWorkspaceSession()
    let shell = model(session)
    try shell.connect().get()
    shell.handle(.character("1"))
    #expect(waitForModel { shell.snapshot().terminal?.lease == .owned })
    let runtime = try #require(shell.snapshot().terminal?.runtime)
    shell.handle(.character("A"))
    #expect(waitForModel { session.writes.count == 1 })
    #expect(session.writes.first?.0 == runtime)
    #expect(session.writes.first?.1 == Data("A".utf8))
    shell.handle(.control("g"))
    shell.handle(.character("d"))
    #expect(shell.snapshot().shouldExit)
    #expect(session.detached == false)
    shell.detachSession()
    #expect(session.detached)
    #expect(session.releases == [runtime])
    #expect(session.unsubscribes == [runtime])
    #expect(session.cancels.isEmpty)
}

@Test func busyInputKeepsTheTerminalReadOnly() throws {
    let session = FakeWorkspaceSession()
    session.busyInput = true
    session.runtimes = [ListedRuntime(id: UUID(), hook: nil, running: true, terminal: true)]
    let shell = model(session)
    try shell.connect().get()
    #expect(shell.snapshot().terminal?.lease == .readOnly)
    shell.handle(.character("B"))
    Thread.sleep(forTimeInterval: 0.05)
    #expect(session.writes.isEmpty)
}

@Test func busyWriteRendersTheTerminalAsReadOnly() throws {
    let session = FakeWorkspaceSession()
    let runtime = UUID()
    session.runtimes = [ListedRuntime(id: runtime, hook: nil, running: true, terminal: true)]
    let shell = model(session)
    try shell.connect().get()
    #expect(shell.snapshot().terminal?.lease == .owned)
    let previousRevision = shell.snapshot().presentationRevision

    session.busyWrite = true
    shell.handle(.character("A"))

    #expect(waitForModel { shell.snapshot().terminal?.lease == .readOnly })
    #expect(shell.snapshot().presentationRevision > previousRevision)
}

@Test func describeFailureMarksTheWorkspaceDisconnected() {
    let session = FakeWorkspaceSession()
    session.failDescribe = true
    let shell = model(session)
    if case .failure(.disconnected) = shell.connect() {
        #expect(Bool(true))
    } else {
        Issue.record("connect should report the unavailable host")
    }
    #expect(shell.snapshot().connection == .disconnected)
    shell.handle(.character("A"))
    #expect(session.writes.isEmpty)
}

@Test func disconnectedAttachFailsConnect() {
    let session = FakeWorkspaceSession()
    session.runtimes = [ListedRuntime(id: UUID(), hook: nil, running: true, terminal: true)]
    session.disconnectOnAttach = true
    let shell = model(session)
    if case .failure(.disconnected) = shell.connect() {
        #expect(Bool(true))
    } else {
        Issue.record("connect should report a disconnected attach instead of succeeding detached")
    }
    #expect(shell.snapshot().connection == .disconnected)
}

@Test func resizeCoalescerSendsOnlyAStableChange() {
    var gate = ResizeCoalescer()
    gate.recordLaunch(rows: 24, columns: 80)
    let now = Date(timeIntervalSince1970: 1_000)
    #expect(gate.propose(rows: 24, columns: 80, now: now) == nil)
    #expect(gate.propose(rows: 40, columns: 100, now: now) == nil)
    #expect(gate.propose(rows: 41, columns: 100, now: now.addingTimeInterval(0.01)) == nil)
    let sent = gate.propose(rows: 41, columns: 100, now: now.addingTimeInterval(0.08))
    #expect(sent?.rows == 41)
    #expect(sent?.columns == 100)
    #expect(gate.propose(rows: 41, columns: 100, now: now.addingTimeInterval(1)) == nil)
    #expect(gate.propose(rows: 900, columns: 1, now: now)?.rows == nil)
    let clamped = gate.propose(rows: 900, columns: 1, now: now.addingTimeInterval(1.05))
    #expect(clamped?.rows == 512)
    #expect(clamped?.columns == 1)
}

final class PumpRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedBatches: [[WorkspaceTUIEvent]] = []
    private var storedDisconnects = 0

    func record(_ batch: [WorkspaceTUIEvent]) {
        lock.lock()
        storedBatches.append(batch)
        lock.unlock()
    }

    func recordDisconnect() {
        lock.lock()
        storedDisconnects += 1
        lock.unlock()
    }

    var batches: [[WorkspaceTUIEvent]] {
        lock.lock()
        defer { lock.unlock() }
        return storedBatches
    }

    var disconnects: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedDisconnects
    }
}

@Test func eventPumpDeliversOneBatchThenDisconnects() {
    let session = FakeWorkspaceSession()
    let runtime = UUID()
    session.events = [
        .bytes(runtime: runtime, data: Data("a".utf8)),
        .overflow(runtime: runtime),
    ]
    session.failPoll = true
    let recorder = PumpRecorder()
    let pump = SessionEventPump()
    pump.start(
        session: session,
        onEvents: { recorder.record($0) },
        onDisconnect: { recorder.recordDisconnect() }
    )
    #expect(waitForModel { recorder.disconnects == 1 })
    pump.stop()
    #expect(recorder.batches.count == 1)
    #expect(recorder.batches.first == [
        .bytes(runtime: runtime, data: Data("a".utf8)),
        .overflow(runtime: runtime),
    ])
    #expect(recorder.disconnects == 1)
}

@Test func eventDeliveryDisconnectsTheModelAndDetachStopsIt() throws {
    let session = FakeWorkspaceSession()
    session.runtimes = [ListedRuntime(id: UUID(), hook: nil, running: true, terminal: true)]
    let shell = model(session)
    try shell.connect().get()
    session.failPoll = true
    shell.startEventDelivery()
    #expect(waitForModel { shell.snapshot().connection == .disconnected })
    shell.detachSession()
    #expect(session.detached)
}

@Test func recordNeverPromotesASettledResize() {
    var gate = ResizeCoalescer()
    gate.recordLaunch(rows: 24, columns: 80)
    let start = Date(timeIntervalSince1970: 2_000)
    gate.record(rows: 30, columns: 90, now: start)
    // A render after the settle window must not mark the size sent; only the
    // coalescing tick promotes via `flush`.
    gate.record(rows: 30, columns: 90, now: start.addingTimeInterval(0.1))
    let flushed = gate.flush(now: start.addingTimeInterval(0.1))
    #expect(flushed?.rows == 30)
    #expect(flushed?.columns == 90)
    #expect(gate.flush(now: start.addingTimeInterval(1)) == nil)
}

private func waitForModel(
    timeout: TimeInterval = 3,
    _ condition: () -> Bool
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return condition()
}

@Test func domainAndIsolationDoNotImportTheTUIFrameworks() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let package = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
    let isolation = package.split(separator: ".target(").first { $0.contains("name: \"RVIsolation\"") }
    let domain = package.split(separator: ".target(").first { $0.contains("name: \"RVDomain\"") }
    let isolationText = String(isolation ?? "")
    let domainText = String(domain ?? "")
    #expect(isolationText.contains("SwiftTUI") == false)
    #expect(isolationText.contains("SwiftTerm") == false)
    #expect(domainText.contains("SwiftTUI") == false)
    #expect(domainText.contains("SwiftTerm") == false)
    #expect(package.components(separatedBy: ".product(name: \"SwiftTUICLI\"").count == 2)
    #expect(package.components(separatedBy: ".product(name: \"SwiftTerm\"").count == 2)
    let sources = root.appendingPathComponent("Sources")
    let files = try FileManager.default.subpathsOfDirectory(atPath: sources.path)
    for file in files where file.hasSuffix(".swift") && file.hasPrefix("RVWorkspaceTUI/") == false {
        let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
        #expect(text.contains("import SwiftTUI") == false)
        #expect(text.contains("import SwiftTUICLI") == false)
        #expect(text.contains("import SwiftTerm") == false)
    }
}

