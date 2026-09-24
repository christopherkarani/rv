import Foundation
import Testing
@testable import RVWorkspaceTUI

final class FakeWorkspaceClient: WorkspaceTUIClient, @unchecked Sendable {
    private let lock = NSLock()
    private var storedSummary: WorkspaceTUISummary
    private var storedRuntimes: [ListedRuntime] = []
    private var storedFailLaunch = false
    private var storedFailCancel = false
    private var storedBusyInput = false
    private var storedBusyWrite = false
    private var storedFailDescribe = false
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
    var failCancel: Bool {
        get { withLock { storedFailCancel } }
        set { withLock { storedFailCancel = newValue } }
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

    func describe() -> Result<WorkspaceTUISummary, WorkspaceTUIClientError> {
        let (fails, value) = withLock { (storedFailDescribe, storedSummary) }
        return fails ? .failure(.disconnected) : .success(value)
    }

    func listRuntimes() -> Result<[ListedRuntime], WorkspaceTUIClientError> {
        .success(withLock { storedRuntimes })
    }

    func launchRuntime(
        executable: String,
        arguments: [String],
        hook: String?,
        rows: Int,
        columns: Int
    ) -> Result<ListedRuntime, WorkspaceTUIClientError> {
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
        let runtime = ListedRuntime(id: UUID(), hook: hook, running: true, terminal: true)
        withLock { storedRuntimes.append(runtime) }
        return .success(runtime)
    }

    func cancelRuntime(_ id: UUID) -> Result<Void, WorkspaceTUIClientError> {
        let (fails, block) = withLock {
            storedCancels.append(id)
            let block = cancelsToBlock > 0
            if block { cancelsToBlock -= 1 }
            return (storedFailCancel, block)
        }
        if block {
            cancelStarted.signal()
            _ = cancelGate.wait(timeout: .now() + 5)
        }
        return fails ? .failure(.rejected) : .success(())
    }

    func subscribe(_ id: UUID) -> Result<Void, WorkspaceTUIClientError> {
        withLock { storedSubscribes.append(id) }
        return .success(())
    }

    func unsubscribe(_ id: UUID) -> Result<Void, WorkspaceTUIClientError> {
        withLock { storedUnsubscribes.append(id) }
        return .success(())
    }

    func acquireInput(_ id: UUID) -> Result<Void, WorkspaceTUIClientError> {
        let busy = withLock {
            if storedBusyInput { return true }
            storedAcquires.append(id)
            return false
        }
        if busy { return .failure(.busy) }
        return .success(())
    }

    func releaseInput(_ id: UUID) -> Result<Void, WorkspaceTUIClientError> {
        withLock { storedReleases.append(id) }
        return .success(())
    }

    func write(_ id: UUID, bytes: Data) -> Result<Void, WorkspaceTUIClientError> {
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

    func resize(_ id: UUID, rows: Int, columns: Int) -> Result<Void, WorkspaceTUIClientError> {
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

    func detach() -> Result<Void, WorkspaceTUIClientError> {
        withLock { storedDetached = true }
        return .success(())
    }

    func nextEvent(timeout: TimeInterval) -> Result<WorkspaceTUIEvent?, WorkspaceTUIClientError> {
        .success(withLock { storedEvents.isEmpty ? nil : storedEvents.removeFirst() })
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

private func model(_ client: FakeWorkspaceClient) -> WorkspaceTUIModel {
    WorkspaceTUIModel(
        client: client,
        emulators: RecordingFactory(),
        summary: client.summary,
        launcher: [
            RuntimeLaunchChoice(id: "shell", title: "shell", executable: "/bin/sh", arguments: [], hook: nil),
            RuntimeLaunchChoice(id: "opencode", title: "opencode", executable: "/bin/opencode", arguments: [], hook: "opencode"),
        ]
    )
}

@Test func connectBuildsPanesForExistingRuntimesWithoutLaunching() throws {
    let client = FakeWorkspaceClient()
    let first = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let second = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    client.runtimes = [
        ListedRuntime(id: first, hook: "opencode", running: true, terminal: true),
        ListedRuntime(id: second, hook: nil, running: true, terminal: true),
    ]
    let shell = model(client)
    try shell.connect().get()
    let snapshot = shell.snapshot()
    #expect(snapshot.tree.paneIDs.count == 2)
    #expect(client.subscribes == [second, first])
    #expect(snapshot.panes.values.contains { $0.runtime == second })
    #expect(client.runtimes.count == 2)
}

@Test func failedLaunchDoesNotMutateTheTree() throws {
    let client = FakeWorkspaceClient()
    let shell = model(client)
    try shell.connect().get()
    client.failLaunch = true
    shell.handle(.control("g"))
    shell.handle(.character("v"))
    #expect(waitForModel { client.launchAttempts == 1 })
    #expect(shell.snapshot().tree == .empty)
}

@Test func blockingHostWritesDoNotBlockKeyHandling() throws {
    let client = FakeWorkspaceClient()
    client.runtimes = [ListedRuntime(id: UUID(), hook: nil, running: true, terminal: true)]
    let shell = model(client)
    try shell.connect().get()
    client.blockNextWrite()

    shell.handle(.character("A"))
    #expect(client.writeStarted.wait(timeout: .now() + 2) == .success)
    let start = Date()
    shell.handle(.character("B"))
    #expect(Date().timeIntervalSince(start) < 0.1)

    client.writeGate.signal()
    #expect(waitForModel { client.writes.count == 2 })
    #expect(client.writes.map(\.1) == [Data("A".utf8), Data("B".utf8)])
}

@Test func delayedLeaseReleaseDoesNotRevokeANewerLocalAcquire() throws {
    let client = FakeWorkspaceClient()
    let runtime = UUID()
    client.runtimes = [ListedRuntime(id: runtime, hook: nil, running: true, terminal: true)]
    let shell = model(client)
    try shell.connect().get()
    let pane = try #require(shell.snapshot().focused)

    shell.apply([
        .inputOwner(runtime: runtime, owned: false),
        .inputOwner(runtime: runtime, owned: true),
    ])
    #expect(shell.snapshot().panes[pane]?.lease == .owned)
    shell.handle(.character("Q"))
    #expect(waitForModel { client.writes.count == 1 })
}

@Test func renderResizeWorkDoesNotWaitForTheWorkspaceHost() throws {
    let client = FakeWorkspaceClient()
    client.runtimes = [ListedRuntime(id: UUID(), hook: nil, running: true, terminal: true)]
    let shell = model(client)
    try shell.connect().get()
    let pane = try #require(shell.snapshot().focused)
    let now = Date(timeIntervalSince1970: 10_000)
    shell.noteSize(of: pane, rows: 30, columns: 90, now: now)
    client.blockNextResize()

    let start = Date()
    shell.processPendingWork(now: now.addingTimeInterval(1))
    #expect(Date().timeIntervalSince(start) < 0.1)
    #expect(client.resizeStarted.wait(timeout: .now() + 2) == .success)
    client.resizeGate.signal()
}

@Test func blockingRuntimeCancellationDoesNotBlockTheKeyHandler() throws {
    let client = FakeWorkspaceClient()
    client.runtimes = [ListedRuntime(id: UUID(), hook: nil, running: true, terminal: true)]
    let shell = model(client)
    try shell.connect().get()
    client.blockNextCancel()

    shell.handle(.control("g"))
    let start = Date()
    shell.handle(.character("x"))
    #expect(Date().timeIntervalSince(start) < 0.1)
    #expect(client.cancelStarted.wait(timeout: .now() + 2) == .success)
    shell.handle(.character("A"))
    #expect(waitForModel { client.writes.count == 1 })
    client.cancelGate.signal()
    #expect(waitForModel { shell.snapshot().tree == .empty })
}

@Test func slowPaneCloseDoesNotOverwriteANewerFocusChange() throws {
    let client = FakeWorkspaceClient()
    let firstRuntime = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    client.runtimes = [ListedRuntime(id: firstRuntime, hook: nil, running: true, terminal: true)]
    let shell = model(client)
    try shell.connect().get()
    let firstPane = try #require(shell.snapshot().focused)

    shell.handle(.control("g"))
    shell.handle(.character("s"))
    #expect(waitForModel { shell.snapshot().panes.count == 2 })
    shell.handle(.control("g"))
    shell.handle(.character("v"))
    #expect(waitForModel { shell.snapshot().panes.count == 3 })
    let closingPane = try #require(shell.snapshot().focused)
    client.blockNextCancel()

    shell.handle(.control("g"))
    shell.handle(.character("x"))
    #expect(client.cancelStarted.wait(timeout: .now() + 2) == .success)
    shell.handle(.control("g"))
    shell.handle(.character("k"))
    #expect(shell.snapshot().focused == firstPane)

    client.cancelGate.signal()
    #expect(waitForModel { shell.snapshot().panes[closingPane] == nil })
    #expect(shell.snapshot().focused == firstPane)
    #expect(waitForModel { shell.snapshot().panes[firstPane]?.lease == .owned })
}

@Test func blockedRuntimeLaunchDoesNotDelayInputToTheExistingPane() throws {
    let client = FakeWorkspaceClient()
    client.runtimes = [ListedRuntime(id: UUID(), hook: nil, running: true, terminal: true)]
    let shell = model(client)
    try shell.connect().get()
    client.blockNextLaunch()

    shell.handle(.control("g"))
    shell.handle(.character("v"))
    #expect(client.launchStarted.wait(timeout: .now() + 2) == .success)
    let start = Date()
    shell.handle(.character("A"))
    #expect(Date().timeIntervalSince(start) < 0.1)
    #expect(waitForModel { client.writes.count == 1 })
    client.launchGate.signal()
    #expect(waitForModel { shell.snapshot().panes.count == 2 })
}

@Test func slowSplitLaunchPreservesFocusMovedWhileLaunching() throws {
    let client = FakeWorkspaceClient()
    let shell = model(client)
    try shell.connect().get()
    shell.handle(.control("g"))
    shell.handle(.character("n"))
    shell.handle(.character("1"))
    #expect(waitForModel { shell.snapshot().panes.count == 1 })

    shell.handle(.control("g"))
    shell.handle(.character("v"))
    #expect(waitForModel { shell.snapshot().panes.count == 2 })
    let secondPane = try #require(shell.snapshot().focused)
    shell.handle(.control("g"))
    shell.handle(.character("h"))
    let firstPane = try #require(shell.snapshot().focused)
    #expect(firstPane != secondPane)

    client.blockNextLaunch()
    shell.handle(.control("g"))
    shell.handle(.character("v"))
    #expect(client.launchStarted.wait(timeout: .now() + 2) == .success)

    shell.handle(.control("g"))
    shell.handle(.character("l"))
    #expect(shell.snapshot().focused == secondPane)

    client.launchGate.signal()
    #expect(waitForModel { shell.snapshot().panes.count == 3 })
    #expect(shell.snapshot().focused == secondPane)
}

@Test func emulatorRepliesDoNotBlockTheTerminalEventPump() throws {
    let client = FakeWorkspaceClient()
    let runtime = UUID()
    client.runtimes = [ListedRuntime(id: runtime, hook: nil, running: true, terminal: true)]
    let shell = WorkspaceTUIModel(
        client: client,
        emulators: RecordingFactory(responses: [Data("R".utf8)]),
        summary: client.summary,
        launcher: []
    )
    try shell.connect().get()
    client.blockNextWrite()

    let start = Date()
    shell.apply([.bytes(runtime: runtime, data: Data("query".utf8))])
    #expect(Date().timeIntervalSince(start) < 0.1)
    #expect(client.writeStarted.wait(timeout: .now() + 2) == .success)
    client.writeGate.signal()
    #expect(waitForModel { client.writes.count == 1 })
    #expect(client.writes.first?.1 == Data("R".utf8))
}

@Test func emptyWorkspaceDoesNotStartAnArbitraryRuntime() throws {
    let client = FakeWorkspaceClient()
    let shell = model(client)
    try shell.connect().get()
    #expect(shell.snapshot().tree == .empty)
    #expect(shell.snapshot().focused == nil)
    #expect(client.runtimes.isEmpty)
    #expect(client.subscribes.isEmpty)
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
    let client = FakeWorkspaceClient()
    let runtime = UUID()
    client.runtimes = [ListedRuntime(id: runtime, hook: nil, running: true, terminal: true)]
    let shell = model(client)
    try shell.connect().get()
    let pane = try #require(shell.snapshot().focused)

    let resizeDate = Date().addingTimeInterval(1)
    shell.processPendingWork(now: resizeDate)
    let idleRevision = shell.snapshot().presentationRevision
    for _ in 0..<130_609 {
        shell.processPendingWork(now: resizeDate.addingTimeInterval(1))
    }
    #expect(shell.snapshot().presentationRevision == idleRevision)

    shell.apply([.bytes(runtime: runtime, data: Data("visible output".utf8))])
    #expect(shell.snapshot().presentationRevision > idleRevision)
    #expect(shell.terminalFrame(for: pane)?.generation == 1)
}

@Test func numberedChoiceLaunchesDirectlyFromAnEmptyWorkspace() throws {
    let client = FakeWorkspaceClient()
    let shell = model(client)
    try shell.connect().get()

    shell.handle(.character("1"))

    #expect(waitForModel { shell.snapshot().panes.count == 1 })
    #expect(client.launchAttempts == 1)
    #expect(shell.snapshot().panes.values.first?.title == "shell")
    #expect(client.writes.isEmpty)
}

@Test func secondNumberLaunchesOpenCodeDirectlyFromAnEmptyWorkspace() throws {
    let client = FakeWorkspaceClient()
    let shell = model(client)
    try shell.connect().get()

    shell.handle(.character("2"))

    #expect(waitForModel { shell.snapshot().panes.count == 1 })
    #expect(client.launchAttempts == 1)
    #expect(shell.snapshot().panes.values.first?.title == "opencode")
}

@Test func failedRuntimeCancellationKeepsItsPaneAndTree() throws {
    let client = FakeWorkspaceClient()
    let shell = model(client)
    try shell.connect().get()
    shell.handle(.control("g"))
    shell.handle(.character("n"))
    shell.handle(.character("1"))
    #expect(waitForModel { shell.snapshot().panes.count == 1 })
    let pane = try #require(shell.snapshot().focused)
    let before = shell.snapshot().tree
    client.failCancel = true
    shell.handle(.control("g"))
    shell.handle(.character("x"))
    #expect(waitForModel { client.cancels.count == 1 })
    #expect(shell.snapshot().tree == before)
    #expect(shell.snapshot().panes[pane]?.running == true)
    #expect(client.cancels == [try #require(shell.snapshot().panes[pane]?.runtime)])
}

@Test func disconnectedWorkspaceRejectsFurtherTerminalInput() throws {
    let client = FakeWorkspaceClient()
    let shell = model(client)
    try shell.connect().get()
    shell.handle(.control("g"))
    shell.handle(.character("n"))
    shell.handle(.character("1"))
    #expect(waitForModel { shell.snapshot().panes.count == 1 })
    shell.handle(.character("A"))
    #expect(waitForModel { client.writes.count == 1 })
    shell.hostDisconnected()
    shell.handle(.character("B"))
    #expect(shell.snapshot().connection == .disconnected)
    #expect(shell.snapshot().panes.values.first?.lease == .readOnly)
    #expect(client.writes.count == 1)
}

@Test func splitCloseExitDetachAndBusyInput() throws {
    let client = FakeWorkspaceClient()
    let shell = model(client)
    try shell.connect().get()
    shell.handle(.control("g"))
    shell.handle(.character("n"))
    shell.handle(.character("1"))
    #expect(waitForModel { shell.snapshot().panes.count == 1 })
    let launched = try #require(shell.snapshot().focused)
    let runtime = try #require(shell.snapshot().panes[launched]?.runtime)
    #expect(shell.snapshot().panes[launched]?.lease == .owned)
    shell.handle(.character("A"))
    #expect(waitForModel { client.writes.count == 1 })
    #expect(client.writes.first?.0 == runtime)
    #expect(client.writes.first?.1 == Data("A".utf8))
    shell.apply([.exited(runtime: runtime, status: 0)])
    #expect(shell.snapshot().panes[launched]?.running == false)
    #expect(shell.snapshot().tree != .empty)
    shell.handle(.control("g"))
    shell.handle(.character("x"))
    #expect(waitForModel { shell.snapshot().tree == .empty })
    #expect(shell.snapshot().tree == .empty)
    #expect(client.cancels.isEmpty)
    client.busyInput = true
    shell.handle(.control("g"))
    shell.handle(.character("v"))
    #expect(waitForModel { shell.snapshot().panes.values.first?.lease == .readOnly })
    let busy = try #require(shell.snapshot().focused)
    #expect(shell.snapshot().panes[busy]?.lease == .readOnly)
    shell.handle(.character("B"))
    #expect(client.writes.count == 1)
    shell.handle(.control("g"))
    shell.handle(.character("d"))
    #expect(shell.snapshot().shouldExit)
    #expect(client.detached == false)
    shell.detachSession()
    #expect(client.detached)
}

@Test func busyWriteRendersTheFocusedPaneAsReadOnly() throws {
    let client = FakeWorkspaceClient()
    let runtime = UUID()
    client.runtimes = [ListedRuntime(id: runtime, hook: nil, running: true, terminal: true)]
    let shell = model(client)
    try shell.connect().get()
    let pane = try #require(shell.snapshot().focused)
    #expect(shell.snapshot().panes[pane]?.lease == .owned)
    let previousRevision = shell.snapshot().presentationRevision

    client.busyWrite = true
    shell.handle(.character("A"))

    #expect(waitForModel { shell.snapshot().panes[pane]?.lease == .readOnly })
    #expect(shell.snapshot().presentationRevision > previousRevision)
}

@Test func inputReachesOnlyTheFocusedRuntime() throws {
    let client = FakeWorkspaceClient()
    let shell = model(client)
    try shell.connect().get()
    shell.handle(.control("g"))
    shell.handle(.character("n"))
    shell.handle(.character("1"))
    #expect(waitForModel { shell.snapshot().panes.values.first?.lease == .owned })
    let left = try #require(shell.snapshot().focused)
    let leftRuntime = try #require(shell.snapshot().panes[left]?.runtime)
    shell.handle(.control("g"))
    shell.handle(.character("v"))
    #expect(waitForModel { shell.snapshot().panes.count == 2 })
    let right = try #require(shell.snapshot().focused)
    let rightRuntime = try #require(shell.snapshot().panes[right]?.runtime)
    shell.noteCanvas(width: 80, height: 24)
    shell.handle(.control("g"))
    shell.handle(.character("h"))
    #expect(waitForModel { shell.snapshot().focused == left })
    #expect(left != right)
    shell.handle(.character("A"))
    #expect(waitForModel { client.writes.count == 1 })
    shell.handle(.control("g"))
    shell.handle(.character("l"))
    #expect(waitForModel { shell.snapshot().focused == right })
    shell.handle(.character("B"))
    #expect(waitForModel { client.writes.count == 2 })
    #expect(client.writes.map(\.0) == [leftRuntime, rightRuntime])
    #expect(client.writes.map(\.1) == [Data("A".utf8), Data("B".utf8)])
    let before = shell.snapshot().workspace
    shell.handle(.control("g"))
    shell.handle(.character("h"))
    shell.handle(.control("g"))
    shell.handle(.character("x"))
    #expect(waitForModel { shell.snapshot().panes[left] == nil })
    #expect(shell.snapshot().panes[left] == nil)
    #expect(shell.snapshot().panes[right]?.running == true)
    #expect(shell.snapshot().workspace == before)
    #expect(client.detached == false)
}

@Test func describeFailureMarksTheWorkspaceDisconnected() {
    let client = FakeWorkspaceClient()
    client.failDescribe = true
    let shell = model(client)
    if case .failure(.disconnected) = shell.connect() {
        #expect(Bool(true))
    } else {
        Issue.record("connect should report the unavailable host")
    }
    #expect(shell.snapshot().connection == .disconnected)
    shell.handle(.character("A"))
    #expect(client.writes.isEmpty)
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
