#if os(macOS)
import Darwin
import Foundation

/// One notice the single PTY reader fans out. Bytes are unmodified master output.
enum TerminalNotice: Sendable, Equatable {
    case replay(sequence: Int64, bytes: Data)
    case output(sequence: Int64, bytes: Data)
    case inputOwner(Bool)
    case exited(Int32)
    case overflow
}

enum TerminalControlError: Error, Equatable, Sendable {
    case unavailable
    case busy
    case limit
    case invalid
}

/// Host-owned PTY for one runtime.
///
/// The master stays in this process. The child receives the slave as stdin,
/// stdout, and stderr through `posix_spawn` file actions after
/// `POSIX_SPAWN_SETSID`, so the child is the session leader and the slave is
/// its controlling terminal. Seatbelt still denies `setsid` and `setpgid`,
/// so the agent cannot leave the process group RV records.
///
/// This object is the only reader of the master. Client sockets never receive
/// the descriptor. Closing a client does not close the master. Closing the
/// workspace host does: the PTY dies with this process, and crash recovery
/// reclaims the process group without rebuilding the byte stream.
final class RuntimeTerminal: @unchecked Sendable {
    private let condition = NSCondition()
    private var master: Int32
    private var stopRead: Int32
    private var stopWrite: Int32
    private var rows: Int
    private var columns: Int
    private var replay = TerminalReplayBuffer()
    private var nextSequence: Int64 = 1
    private var subscribers: [UUID: Subscriber] = [:]
    private var inputOwner: UUID?
    private var exited = false
    private var exitStatus: Int32?
    private var exitQueued = false
    private var readerStarted = false
    private var readerStopped = false
    private var masterClosed = false
    let slavePath: String

    private init(master: Int32, stopRead: Int32, stopWrite: Int32, slavePath: String, rows: Int, columns: Int) {
        self.master = master
        self.stopRead = stopRead
        self.stopWrite = stopWrite
        self.slavePath = slavePath
        self.rows = rows
        self.columns = columns
    }

    /// Allocates a PTY, configures termios and the initial window, and keeps
    /// only the master. The slave path is opened again by the child.
    static func open(rows: Int, columns: Int) -> RuntimeTerminal? {
        guard TerminalStreamLimits.accepts(rows: rows, columns: columns) else { return nil }
        var master = posix_openpt(O_RDWR | O_NOCTTY | O_CLOEXEC)
        guard master >= 0 else { return nil }
        guard relocate(&master, floor: 16) else {
            Darwin.close(master)
            return nil
        }
        guard grantpt(master) == 0, unlockpt(master) == 0 else {
            Darwin.close(master)
            return nil
        }
        var name = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard ptsname_r(master, &name, name.count) == 0 else {
            Darwin.close(master)
            return nil
        }
        let slavePath = String(cString: name)
        var slave = slavePath.withCString { Darwin.open($0, O_RDWR | O_NOCTTY | O_CLOEXEC) }
        guard slave >= 0 else {
            Darwin.close(master)
            return nil
        }
        guard relocate(&slave, floor: 16) else {
            Darwin.close(slave)
            Darwin.close(master)
            return nil
        }
        guard configureSlave(slave), applyWindow(rows: rows, columns: columns, fd: slave),
            applyWindow(rows: rows, columns: columns, fd: master)
        else {
            Darwin.close(slave)
            Darwin.close(master)
            return nil
        }
        Darwin.close(slave)
        var ends: [Int32] = [-1, -1]
        let piped = ends.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return pipe(base)
        }
        guard piped == 0 else {
            Darwin.close(master)
            return nil
        }
        var stopRead = ends[0]
        var stopWrite = ends[1]
        guard fcntl(stopRead, F_SETFD, FD_CLOEXEC) >= 0,
            fcntl(stopWrite, F_SETFD, FD_CLOEXEC) >= 0,
            relocate(&stopRead, floor: 16),
            relocate(&stopWrite, floor: 16),
            setNonblocking(master)
        else {
            Darwin.close(stopRead)
            Darwin.close(stopWrite)
            Darwin.close(master)
            return nil
        }
        return RuntimeTerminal(
            master: master,
            stopRead: stopRead,
            stopWrite: stopWrite,
            slavePath: slavePath,
            rows: rows,
            columns: columns
        )
    }

    var masterFD: Int32 {
        condition.lock()
        let fd = masterClosed ? -1 : master
        condition.unlock()
        return fd
    }

    var hasSubscribers: Bool {
        condition.lock()
        let value = subscribers.isEmpty == false
        condition.unlock()
        return value
    }

    var hasInputOwner: Bool {
        condition.lock()
        let value = inputOwner != nil
        condition.unlock()
        return value
    }

    func window() -> (rows: Int, columns: Int) {
        condition.lock()
        let value = (rows, columns)
        condition.unlock()
        return value
    }

    func startReader() {
        condition.lock()
        if masterClosed || readerStarted {
            condition.unlock()
            return
        }
        readerStarted = true
        condition.unlock()
        let thread = Thread { [self] in
            self.readLoop()
            self.condition.lock()
            self.readerStopped = true
            self.condition.broadcast()
            self.condition.unlock()
        }
        thread.name = "rv-pty-reader"
        thread.start()
    }

    /// Records process exit, tells current subscribers, and closes the master
    /// after the reader has stopped. Further attaches still see replay.
    func finish(status: Int32?) {
        condition.lock()
        if exitQueued {
            condition.unlock()
            return
        }
        exitQueued = true
        exited = true
        exitStatus = status
        let notice = TerminalNotice.exited(status ?? -1)
        for subscriber in subscribers.values where subscriber.dropped == false && subscriber.stopped == false {
            subscriber.chunks.append(notice)
        }
        condition.broadcast()
        condition.unlock()
        shutdownMaster()
    }

    func shutdownMaster() {
        condition.lock()
        if masterClosed {
            condition.unlock()
            return
        }
        masterClosed = true
        let wake = stopWrite
        let started = readerStarted
        condition.unlock()
        if wake >= 0 {
            var byte: UInt8 = 1
            _ = Darwin.write(wake, &byte, 1)
        }
        if started {
            condition.lock()
            while readerStopped == false {
                condition.wait()
            }
            condition.unlock()
        }
        condition.lock()
        let fd = master
        let stopR = stopRead
        let stopW = stopWrite
        master = -1
        stopRead = -1
        stopWrite = -1
        condition.broadcast()
        condition.unlock()
        if fd >= 0 { Darwin.close(fd) }
        if stopR >= 0 { Darwin.close(stopR) }
        if stopW >= 0 { Darwin.close(stopW) }
    }

    func subscribe(
        client: UUID,
        emit: @escaping @Sendable (TerminalNotice) -> Void
    ) -> Result<Void, TerminalControlError> {
        condition.lock()
        if subscribers[client] != nil {
            condition.unlock()
            return .failure(.invalid)
        }
        if subscribers.count >= TerminalStreamLimits.maximumSubscribers {
            condition.unlock()
            return .failure(.limit)
        }
        let subscriber = Subscriber(id: client, emit: emit)
        for chunk in replay.chunks {
            subscriber.chunks.append(.replay(sequence: chunk.sequence, bytes: chunk.bytes))
            subscriber.queuedBytes += chunk.bytes.count
        }
        if exitQueued {
            subscriber.chunks.append(.exited(exitStatus ?? -1))
        }
        subscribers[client] = subscriber
        condition.unlock()
        let terminal = self
        let thread = Thread {
            terminal.flushLoop(subscriber)
        }
        thread.name = "rv-pty-subscriber"
        thread.start()
        return .success(())
    }

    /// Replay and live bytes stay queued until the subscribe reply is written.
    func activate(client: UUID) {
        condition.lock()
        subscribers[client]?.deliver = true
        condition.broadcast()
        condition.unlock()
    }

    func detach(client: UUID) {
        condition.lock()
        if let subscriber = subscribers.removeValue(forKey: client) {
            subscriber.stopped = true
        }
        if inputOwner == client {
            inputOwner = nil
            enqueueOwnerLocked(false)
        }
        condition.broadcast()
        condition.unlock()
    }

    func acquireInput(client: UUID) -> Result<Void, TerminalControlError> {
        condition.lock()
        guard subscribers[client] != nil else {
            condition.unlock()
            return .failure(.unavailable)
        }
        if exited && exitQueued {
            condition.unlock()
            return .failure(.unavailable)
        }
        if let inputOwner, inputOwner != client {
            condition.unlock()
            return .failure(.busy)
        }
        let changed = inputOwner != client
        inputOwner = client
        if changed { enqueueOwnerLocked(true) }
        condition.broadcast()
        condition.unlock()
        return .success(())
    }

    func releaseInput(client: UUID) -> Result<Void, TerminalControlError> {
        condition.lock()
        guard inputOwner == client else {
            condition.unlock()
            return .success(())
        }
        inputOwner = nil
        enqueueOwnerLocked(false)
        condition.broadcast()
        condition.unlock()
        return .success(())
    }

    func writeInput(client: UUID, bytes: Data) -> Result<Void, TerminalControlError> {
        guard bytes.isEmpty == false, bytes.count <= TerminalStreamLimits.maximumInputBytes else {
            return .failure(.invalid)
        }
        condition.lock()
        guard inputOwner == client, masterClosed == false, exited == false, master >= 0 else {
            let error: TerminalControlError = inputOwner == client ? .unavailable : .busy
            condition.unlock()
            return .failure(error)
        }
        let fd = master
        condition.unlock()
        guard writeAll(fd: fd, bytes: bytes) else { return .failure(.unavailable) }
        return .success(())
    }

    func resize(rows: Int, columns: Int) -> Result<Void, TerminalControlError> {
        guard TerminalStreamLimits.accepts(rows: rows, columns: columns) else {
            return .failure(.invalid)
        }
        condition.lock()
        guard masterClosed == false, master >= 0 else {
            condition.unlock()
            return .failure(.unavailable)
        }
        let fd = master
        condition.unlock()
        guard Self.applyWindow(rows: rows, columns: columns, fd: fd) else {
            return .failure(.unavailable)
        }
        condition.lock()
        self.rows = rows
        self.columns = columns
        condition.unlock()
        return .success(())
    }

    private func enqueueOwnerLocked(_ owned: Bool) {
        let notice = TerminalNotice.inputOwner(owned)
        for subscriber in subscribers.values where subscriber.dropped == false && subscriber.stopped == false {
            subscriber.chunks.append(notice)
        }
    }

    private func readLoop() {
        while true {
            condition.lock()
            if masterClosed {
                condition.unlock()
                return
            }
            let masterFD = master
            let wakeFD = stopRead
            condition.unlock()
            guard masterFD >= 0, wakeFD >= 0 else { return }
            var polls = [
                pollfd(fd: wakeFD, events: Int16(POLLIN), revents: 0),
                pollfd(fd: masterFD, events: Int16(POLLIN), revents: 0),
            ]
            let waited = poll(&polls, nfds_t(polls.count), -1)
            if waited < 0 {
                if errno == EINTR { continue }
                return
            }
            if polls[0].revents != 0 { return }
            guard polls[1].revents != 0 else { continue }
            var buffer = [UInt8](repeating: 0, count: TerminalStreamLimits.readChunkBytes)
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(masterFD, base, raw.count)
            }
            if count > 0 {
                publish(Data(buffer.prefix(count)))
                continue
            }
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            return
        }
    }

    private func publish(_ data: Data) {
        guard data.isEmpty == false else { return }
        condition.lock()
        if masterClosed || exited {
            condition.unlock()
            return
        }
        guard nextSequence < Int64.max else {
            condition.unlock()
            return
        }
        let sequence = nextSequence
        nextSequence += 1
        replay.append(sequence: sequence, bytes: data, limit: TerminalStreamLimits.replayBytes)
        let notice = TerminalNotice.output(sequence: sequence, bytes: data)
        for subscriber in subscribers.values where subscriber.stopped == false && subscriber.dropped == false {
            switch TerminalQueue.decide(
                queued: subscriber.queuedBytes,
                incoming: data.count,
                limit: TerminalStreamLimits.subscriberQueueBytes
            ) {
            case .queued(let bytes):
                subscriber.chunks.append(notice)
                subscriber.queuedBytes = bytes
            case .overflow:
                subscriber.dropped = true
                subscriber.chunks.removeAll()
                subscriber.queuedBytes = 0
                subscriber.chunks.append(.overflow)
            }
        }
        condition.broadcast()
        condition.unlock()
    }

    private func flushLoop(_ subscriber: Subscriber) {
        while true {
            condition.lock()
            while subscriber.deliver == false && subscriber.stopped == false {
                condition.wait()
            }
            if subscriber.stopped {
                condition.unlock()
                return
            }
            while subscriber.chunks.isEmpty && subscriber.dropped == false && subscriber.stopped == false {
                condition.wait()
            }
            if subscriber.stopped {
                condition.unlock()
                return
            }
            let batch = subscriber.chunks
            subscriber.chunks.removeAll()
            subscriber.queuedBytes = 0
            let dropped = subscriber.dropped
            condition.unlock()
            var ended = false
            for notice in batch {
                subscriber.emit(notice)
                if case .exited = notice { ended = true }
            }
            if dropped || ended {
                condition.lock()
                subscribers[subscriber.id] = nil
                subscriber.stopped = true
                condition.unlock()
                return
            }
        }
    }

    private func writeAll(fd: Int32, bytes: Data) -> Bool {
        let raw = [UInt8](bytes)
        var offset = 0
        let deadline = Date().addingTimeInterval(1)
        while offset < raw.count {
            let count = raw.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
            }
            if count > 0 {
                offset += count
                continue
            }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                if Date() >= deadline { return false }
                var state = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&state, 1, 50)
                continue
            }
            return false
        }
        return true
    }

    private static func configureSlave(_ fd: Int32) -> Bool {
        var term = termios()
        guard tcgetattr(fd, &term) == 0 else { return false }
        term.c_iflag |= tcflag_t(ICRNL | IXON)
        term.c_iflag &= ~tcflag_t(ISTRIP | INLCR | IGNCR)
        term.c_oflag |= tcflag_t(OPOST | ONLCR)
        term.c_lflag |= tcflag_t(ISIG | ICANON | ECHO | ECHOE | ECHOK)
        term.c_cflag |= tcflag_t(CS8)
        setControlCharacter(&term, VINTR, 3)
        setControlCharacter(&term, VQUIT, 28)
        setControlCharacter(&term, VERASE, 127)
        setControlCharacter(&term, VKILL, 21)
        setControlCharacter(&term, VEOF, 4)
        setControlCharacter(&term, VSUSP, 26)
        return tcsetattr(fd, TCSANOW, &term) == 0
    }

    private static func setControlCharacter(_ term: inout termios, _ index: Int32, _ value: UInt8) {
        withUnsafeMutableBytes(of: &term.c_cc) { raw in
            let offset = Int(index)
            guard offset >= 0, offset < raw.count else { return }
            raw[offset] = value
        }
    }

    private static func applyWindow(rows: Int, columns: Int, fd: Int32) -> Bool {
        var size = winsize()
        size.ws_row = UInt16(rows)
        size.ws_col = UInt16(columns)
        size.ws_xpixel = 0
        size.ws_ypixel = 0
        return ioctl(fd, TIOCSWINSZ, &size) == 0
    }

    private static func setNonblocking(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else { return false }
        return fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0
    }

    private static func relocate(_ fd: inout Int32, floor: Int32) -> Bool {
        guard fd >= 0 else { return false }
        if fd >= floor { return true }
        let moved = fcntl(fd, F_DUPFD_CLOEXEC, floor)
        guard moved >= 0 else { return false }
        Darwin.close(fd)
        fd = moved
        return true
    }
}

private final class Subscriber: @unchecked Sendable {
    let id: UUID
    let emit: @Sendable (TerminalNotice) -> Void
    var chunks: [TerminalNotice] = []
    var queuedBytes = 0
    var deliver = false
    var dropped = false
    var stopped = false

    init(id: UUID, emit: @escaping @Sendable (TerminalNotice) -> Void) {
        self.id = id
        self.emit = emit
    }
}
#endif
