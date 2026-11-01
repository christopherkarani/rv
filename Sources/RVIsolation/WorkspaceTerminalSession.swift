#if os(macOS)
import Darwin
import Foundation

/// How a workspace terminal session ended without a failure.
public enum WorkspaceTerminalOutcome: Sendable, Equatable {
    /// The runtime exited with this status.
    case exited(Int32)
    /// The local input ended on purpose (Ctrl-D). The runtime keeps running.
    case inputEnded
}

public enum WorkspaceTerminalSessionFailure: Error, Sendable, Equatable {
    /// The launch closure failed.
    case launch(WorkspaceClientFailure)
    /// The launched runtime has no host-owned terminal.
    case noTerminal
    /// Subscribe, acquire, or the event stream failed.
    case client(WorkspaceClientFailure)
    /// The host dropped this subscriber's backlog.
    case fellBehind
}

/// The local end of `rv workspace run`: launch, attach to the runtime's
/// terminal, copy its output, and forward input while this client owns it.
public enum WorkspaceTerminalSession {
    /// Always detaches `client` exactly once, after stopping the stdin bridge
    /// and restoring the local terminal. Restore comes first because detach
    /// can block for the describe timeout.
    ///
    /// - Parameters:
    ///   - rows: The row count the runtime was launched with. With
    ///     `columns` it seeds resize tracking, which sends only changes of
    ///     `output`'s window.
    ///   - columns: The column count the runtime was launched with.
    ///   - abandonOnInputEnd: Whether an EOF on owned `input` ends the
    ///     session. Pass true only for an interactive terminal; a pipe or
    ///     /dev/null EOFs at once and must not cut a slow command short.
    ///   - rawMode: Engages raw mode on `input` when this client owns it.
    public static func run(
        client: WorkspaceClient,
        launch: (WorkspaceClient) -> Result<WorkspaceRuntimeReport, WorkspaceClientFailure>,
        rows: Int,
        columns: Int,
        abandonOnInputEnd: Bool,
        input: Int32 = STDIN_FILENO,
        output: Int32 = STDOUT_FILENO,
        rawMode: (Int32) -> LocalTerminalRestorer? = { LocalTerminalRestorer.engage($0) }
    ) throws(WorkspaceTerminalSessionFailure) -> WorkspaceTerminalOutcome {
        var restorer: LocalTerminalRestorer?
        var bridge: TerminalStdinBridge?
        defer {
            // Stopping an unstarted bridge waits out its full timeout, so
            // only a started one is set here. The reader leaves `input`
            // before restore, or a pending read makes restore set PENDIN.
            bridge?.stop()
            restorer?.restore()
            _ = client.detach()
        }
        let runtime: UUID
        switch launch(client) {
        case .failure(let error):
            throw .launch(error)
        case .success(let report):
            guard report.terminal else { throw .noTerminal }
            runtime = report.runtime
        }
        if case .failure(let error) = client.subscribeTerminal(runtime) {
            throw .client(error)
        }
        let ownsInput: Bool
        switch client.acquireTerminalInput(runtime) {
        case .success:
            ownsInput = true
        case .failure(.terminalUnavailable):
            // The runtime can exit before this client takes input. The exit
            // status is still on the stream.
            ownsInput = false
        case .failure(let error):
            throw .client(error)
        }
        if ownsInput {
            restorer = rawMode(input)
            let reader = TerminalStdinBridge(client: client, runtime: runtime, input: input)
            reader.start()
            bridge = reader
        }
        let out = FileHandle(fileDescriptor: output, closeOnDealloc: false)
        var window = LocalTerminalWindow(rows: rows, columns: columns)
        while true {
            let inputEnded = bridge?.inputEnded ?? false
            if endsOnInput(ownsInput: ownsInput, abandonOnInputEnd: abandonOnInputEnd, inputEnded: inputEnded) {
                return .inputEnded
            }
            if let size = LocalTerminalWindow.current(fd: output), size != window {
                window = size
                _ = client.resizeTerminal(runtime, rows: size.rows, columns: size.columns)
            }
            switch step(client.nextTerminalEvent(timeout: 0.2), runtime: runtime) {
            case .idle:
                continue
            case .write(let bytes):
                out.write(bytes)
            case .exited(let status):
                return .exited(status)
            case .failed(let failure):
                throw failure
            }
        }
    }

    /// What one terminal read asks the session loop to do.
    enum Step: Sendable, Equatable {
        case idle
        case write(Data)
        case exited(Int32)
        case failed(WorkspaceTerminalSessionFailure)
    }

    static func step(
        _ read: Result<WorkspaceTerminalRead, WorkspaceClientFailure>,
        runtime: UUID
    ) -> Step {
        switch read {
        case .failure(let error):
            return .failed(.client(error))
        case .success(.waiting):
            return .idle
        case .success(.event(let event)):
            guard event.runtime == runtime else { return .idle }
            switch event.body {
            case .replay(_, let bytes), .output(_, let bytes):
                return .write(bytes)
            case .exited(let status):
                return .exited(status)
            case .overflow:
                return .failed(.fellBehind)
            case .replayBegin, .replayEnd, .inputOwner, .window:
                // Output goes out as a fresh byte stream; there is no retained
                // screen to reconcile with replay bounds or window notices.
                return .idle
            }
        }
    }

    static func endsOnInput(ownsInput: Bool, abandonOnInputEnd: Bool, inputEnded: Bool) -> Bool {
        ownsInput && abandonOnInputEnd && inputEnded
    }
}
#endif
