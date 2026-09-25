#if os(macOS)
import Foundation
import RVDomain
import Testing
@testable import RVIsolation
@testable import RVWorkspaceTUI

@Suite(.serialized)
struct WorkspaceTUIIntegrationTests {
@Test func emptyWorkspaceStartsAnInteractiveContainedShell() throws {
    let host = try OpenedHost()
    defer { host.close() }
    let client = try WorkspaceClient.connect(host.server.endpoint).get()
    let terminalClient = try WorkspaceClient.connect(host.server.endpoint).get()
    let live = LiveWorkspaceTUIClient(controlClient: client, terminalClient: terminalClient)
    let script = "stty icanon icrnl; printf 'RV-AUTO-SHELL-READY\\r\\n'; while IFS= read -r line; do if [ \"$line\" = quit ]; then break; else printf 'RV-AUTO-SHELL-REPLY:%s\\r\\n' \"$line\"; fi; done"
    let model = WorkspaceTUIModel(
        client: live,
        summary: try live.describe().get(),
        launcher: [RuntimeLaunchChoice(
            id: "shell", title: "shell", executable: "/bin/sh",
            arguments: ["-c", script], hook: nil
        )],
        rows: 12,
        columns: 40
    )
    try model.connect().get()
    let pump = TerminalEventPump(client: live, model: model)
    pump.start()
    defer {
        pump.stop()
        model.detachSession()
    }

    model.launchDefaultRuntimeIfEmpty()

    #expect(model.snapshot().terminal?.lease == .owned)
    let runtime = try #require(model.snapshot().terminal?.runtime)
    send("typed input", to: model)
    #expect(waitUntil { screen(model).contains("RV-AUTO-SHELL-READY") })
    #expect(waitUntil { screen(model).contains("RV-AUTO-SHELL-REPLY:typed input") })

    send("quit", to: model)
    #expect(waitUntil { model.snapshot().mode == .launcher })
    #expect(model.snapshot().terminal?.running == false)
    #expect(model.snapshot().terminal?.runtime == runtime)
    model.handle(.character("1"))
    #expect(waitUntil {
        model.snapshot().terminal?.runtime != runtime && model.snapshot().terminal?.lease == .owned
    })
    #expect(waitUntil { screen(model).contains("RV-AUTO-SHELL-READY") })
    send("again", to: model)
    #expect(waitUntil { screen(model).contains("RV-AUTO-SHELL-REPLY:again") })
    #expect(try client.listRuntimes().get().first { $0.runtime == runtime }?.running == false)
    #expect(try live.describe().get().phase == "active")
}

@Test func hostPTYBytesResizeDetachAndReattachUseTheSameRuntime() throws {
    let host = try OpenedHost()
    defer { host.close() }
    let client = try WorkspaceClient.connect(host.server.endpoint).get()
    let terminalClient = try WorkspaceClient.connect(host.server.endpoint).get()
    let live = LiveWorkspaceTUIClient(controlClient: client, terminalClient: terminalClient)
    let summary = try live.describe().get()
    let script = "stty icanon icrnl; printf 'RV-TUI-MARKER\\r\\n'; while IFS= read -r line; do if [ \"$line\" = size ]; then stty size; else printf 'REPLY:%s\\r\\n' \"$line\"; fi; done"
    let shell = WorkspaceTUIModel(
        client: live,
        summary: summary,
        launcher: [RuntimeLaunchChoice(
            id: "shell", title: "shell", executable: "/bin/sh",
            arguments: ["-c", script], hook: nil
        )],
        rows: 24,
        columns: 80
    )
    try shell.connect().get()
    var pump: TerminalEventPump? = TerminalEventPump(client: live, model: shell)
    defer {
        pump?.stop()
        shell.detachSession()
    }
    pump?.start()
    shell.handle(.character("1"))
    #expect(waitUntil { shell.snapshot().terminal?.lease == .owned })
    let runtime = try #require(shell.snapshot().terminal?.runtime)

    #expect(shell.snapshot().terminal?.lease == .owned)
    #expect(try client.listRuntimes().get().first?.inputOwner == true)
    #expect(waitUntil { screen(shell).contains("RV-TUI-MARKER") })
    send("Z", to: shell)
    #expect(waitUntil { screen(shell).contains("REPLY:Z") })

    let resizeAt = Date(timeIntervalSince1970: 1_000)
    shell.noteSize(rows: 17, columns: 53, now: resizeAt)
    shell.processPendingWork(now: resizeAt.addingTimeInterval(0.1))
    send("size", to: shell)
    #expect(waitUntil { screen(shell).contains("17 53") })
    #expect(shell.terminalSize()?.rows == 17)
    #expect(shell.terminalSize()?.columns == 53)

    pump?.stop()
    pump = nil
    shell.detachSession()
    let reattachClient = try WorkspaceClient.connect(host.server.endpoint).get()
    let remaining = try reattachClient.listRuntimes().get()
    #expect(remaining.contains { $0.runtime == runtime && $0.running })

    let reattachTerminalClient = try WorkspaceClient.connect(host.server.endpoint).get()
    let second = LiveWorkspaceTUIClient(
        controlClient: reattachClient,
        terminalClient: reattachTerminalClient
    )
    let reattached = WorkspaceTUIModel(client: second, summary: try second.describe().get(), launcher: [])
    try reattached.connect().get()
    #expect(reattached.snapshot().terminal?.runtime == runtime)
    let replay = TerminalEventPump(client: second, model: reattached)
    pump = replay
    replay.start()
    #expect(waitUntil { screen(reattached).contains("RV-TUI-MARKER") })
    #expect(reattached.snapshot().terminal?.running == true)
    #expect(try reattachClient.listRuntimes().get().filter(\.terminal).count == 1)
    _ = reattachClient.cancelRuntime(runtime)
}

@Test func sustainedPTYOutputKeepsInputResponsiveAndReachesTheFinalScreen() throws {
    let host = try OpenedHost()
    defer { host.close() }
    let client = try WorkspaceClient.connect(host.server.endpoint).get()
    let terminalClient = try WorkspaceClient.connect(host.server.endpoint).get()
    let live = LiveWorkspaceTUIClient(controlClient: client, terminalClient: terminalClient)
    let script = "stty icanon icrnl;read g;(i=0;while ((i<1000));do printf 'OUT:%d:abcdefghijklmnopqrstuvwx\\r\\n' \"$i\";((i==400))&&echo READY;if ((i>400));then sleep .05;fi;((i++));done)&p=$!;read -r l;printf 'IN:%s\\r\\n' \"$l\";kill $p;wait $p;printf 'DONE\\r\\n'"
    // The kill/notice/DONE cascade lands within one screen poll, so the
    // screen must be tall enough to retain IN:stop past bash's multi-line
    // job-termination notice.
    let shell = WorkspaceTUIModel(
        client: live,
        summary: try live.describe().get(),
        launcher: [RuntimeLaunchChoice(
            id: "shell", title: "shell", executable: "/bin/bash",
            arguments: ["-c", script], hook: nil
        )],
        rows: 21,
        columns: 78
    )
    try shell.connect().get()
    let pump = TerminalEventPump(client: live, model: shell)
    pump.start()
    defer {
        pump.stop()
        shell.detachSession()
    }
    shell.handle(.character("1"))
    #expect(waitUntil { shell.snapshot().terminal?.lease == .owned })
    send("go", to: shell)
    #expect(waitUntil(seconds: 8) { screen(shell).contains("READY") })
    #expect(shell.snapshot().terminal?.overflowed == false)
    let sendBegan = Date()
    send("stop", to: shell)
    #expect(Date().timeIntervalSince(sendBegan) < 3)
    #expect(waitUntil(seconds: 8) { screen(shell).contains("IN:stop") })
    #expect(waitUntil(seconds: 8) { screen(shell).contains("DONE") })
    #expect(shell.snapshot().terminal?.overflowed == false)
    #expect(TerminalScrollback.lines == 1_000)
}

@Test func externalInputLeaseKeepsTheTUIReadOnlyUntilTheLeaseIsReleased() throws {
    let host = try OpenedHost()
    defer { host.close() }
    let owner = try WorkspaceClient.connect(host.server.endpoint).get()
    let runtime = try owner.launchRuntime(
        executable: "/bin/sh",
        arguments: ["-c", "stty icanon icrnl; while IFS= read -r line; do printf 'OWNER:%s\\r\\n' \"$line\"; done"],
        terminalRows: 12,
        terminalColumns: 40
    ).get()
    try owner.subscribeTerminal(runtime.runtime).get()
    try owner.acquireTerminalInput(runtime.runtime).get()

    let viewer = try WorkspaceClient.connect(host.server.endpoint).get()
    let viewerTerminal = try WorkspaceClient.connect(host.server.endpoint).get()
    let live = LiveWorkspaceTUIClient(controlClient: viewer, terminalClient: viewerTerminal)
    let model = WorkspaceTUIModel(client: live, summary: try live.describe().get(), launcher: [])
    try model.connect().get()
    #expect(model.snapshot().terminal?.runtime == runtime.runtime)
    #expect(model.snapshot().terminal?.lease == .readOnly)
    model.apply([.inputOwner(runtime: runtime.runtime, owned: true)])
    #expect(model.snapshot().terminal?.lease == .readOnly)

    model.handle(.character("X"))
    #expect(try viewer.listRuntimes().get().first?.inputOwner == true)
    try owner.releaseTerminalInput(runtime.runtime).get()
    model.apply([.inputOwner(runtime: runtime.runtime, owned: false)])
    model.processPendingWork()
    #expect(waitUntil { model.snapshot().terminal?.lease == .owned })
    #expect(try viewer.listRuntimes().get().first?.inputOwner == true)
    model.detachSession()
    _ = owner.cancelRuntime(runtime.runtime)
}

@Test func invalidHookStringIsRejectedWithoutLaunching() throws {
    let host = try OpenedHost()
    defer { host.close() }
    let client = try WorkspaceClient.connect(host.server.endpoint).get()
    let terminalClient = try WorkspaceClient.connect(host.server.endpoint).get()
    let live = LiveWorkspaceTUIClient(controlClient: client, terminalClient: terminalClient)
    defer { _ = live.detach() }
    guard case .failure(.rejected) = live.launchRuntime(
        executable: "/bin/sh", arguments: [], hook: "bogus-hook", rows: 12, columns: 40
    ) else {
        Issue.record("an unknown hook must fail instead of launching unhooked")
        return
    }
    guard case .failure(.rejected) = live.ensureTerminalRuntime(
        executable: "/bin/sh", arguments: [], hook: "bogus-hook", rows: 12, columns: 40
    ) else {
        Issue.record("an unknown hook must fail instead of ensuring unhooked")
        return
    }
    #expect(try client.listRuntimes().get().isEmpty)
}

@Test func overflowedTerminalResubscribesFromReplay() throws {
    let host = try OpenedHost()
    defer { host.close() }
    let client = try WorkspaceClient.connect(host.server.endpoint).get()
    let terminalClient = try WorkspaceClient.connect(host.server.endpoint).get()
    let live = LiveWorkspaceTUIClient(controlClient: client, terminalClient: terminalClient)
    defer { _ = live.detach() }
    let runtime = try live.ensureTerminalRuntime(
        executable: "/bin/sh",
        arguments: ["-c", "printf 'RV-TUI-RESUB'; /bin/sleep 30"],
        hook: nil,
        rows: 12,
        columns: 40
    ).get()
    try live.subscribe(runtime.id).get()
    #expect(waitUntil { drainContains(live, needle: "RV-TUI-RESUB") })
    try live.resubscribe(runtime.id).get()
    #expect(waitUntil { drainContains(live, needle: "RV-TUI-RESUB") })
    _ = client.cancelRuntime(runtime.id)
}

private func screen(_ model: WorkspaceTUIModel) -> String {
    guard let frame = model.terminalFrame() else { return "" }
    return (0..<frame.rows).map(frame.line).joined(separator: "\n")
}

private func send(_ string: String, to model: WorkspaceTUIModel) {
    for character in string { model.handle(.character(character)) }
    model.handle(.enter)
}

private func drainContains(_ live: LiveWorkspaceTUIClient, needle: String) -> Bool {
    var seen = Data()
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
        switch live.nextEvent(timeout: 0.2) {
        case .failure:
            return false
        case .success(nil):
            continue
        case .success(.bytes(_, let data)):
            seen.append(data)
            if String(data: seen, encoding: .utf8)?.contains(needle) == true { return true }
        case .success:
            continue
        }
    }
    return false
}

private struct OpenedHost {
    var supervisor: WorkspaceSessionSupervisor
    var server: WorkspaceHostServer
    var root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "rv-tui-\(UUID().uuidString)",
            isDirectory: true
        )
        let workspace = root.appendingPathComponent("ws", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let config = root.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let directory = try #require(WorkingDirectory(validating: workspace.path))
        supervisor = try WorkspaceSessionSupervisor.open(
            directory,
            lifecycleLog: .file(config.appendingPathComponent("workspace-sessions.jsonl"))
        ).get()
        server = try WorkspaceHostServer.start(
            supervisor: supervisor,
            configurationDirectory: config,
            sessionStore: .file(config.appendingPathComponent("runtime-sessions.jsonl"))
        ).get()
    }

    func close() {
        server.stop()
        _ = supervisor.close()
        try? FileManager.default.removeItem(at: root)
    }
}

private func waitUntil(seconds: TimeInterval = 8, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return false
}
}
#endif
