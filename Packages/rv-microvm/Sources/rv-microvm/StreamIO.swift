import Containerization
import Foundation
import Synchronization

/// Guest output to a host descriptor.
struct DescriptorWriter: Writer {
    let handle: FileHandle

    func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
    }

    func close() throws {}
}

/// Host stdin (not a terminal) to the guest process.
struct DescriptorReader: ReaderStream {
    let handle: FileHandle

    func stream() -> AsyncStream<Data> {
        AsyncStream { continuation in
            handle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
        }
    }
}

/// Collects the guest relay's stdout and reports when it printed `ready`.
final class ReadyLatch: Writer, Sendable {
    private struct State {
        var buffer = Data()
        var ready = false
        var waiters: [CheckedContinuation<Bool, Never>] = []
    }

    private let state = Mutex(State())
    private static let marker = Data("ready\n".utf8)

    func write(_ data: Data) throws {
        let resumed: [CheckedContinuation<Bool, Never>] = state.withLock { state in
            guard state.ready == false else { return [] }
            state.buffer.append(data)
            guard state.buffer.range(of: Self.marker) != nil else {
                if state.buffer.count > 4096 { state.buffer.removeFirst(state.buffer.count - 4096) }
                return []
            }
            state.ready = true
            let waiters = state.waiters
            state.waiters = []
            return waiters
        }
        resumed.forEach { $0.resume(returning: true) }
    }

    func close() throws {
        fail()
    }

    /// Wakes waiters with `false`: the relay exited or timed out.
    func fail() {
        let resumed: [CheckedContinuation<Bool, Never>] = state.withLock { state in
            let waiters = state.waiters
            state.waiters = []
            return waiters
        }
        resumed.forEach { $0.resume(returning: false) }
    }

    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            let readyNow: Bool? = state.withLock { state in
                if state.ready { return true }
                state.waiters.append(continuation)
                return nil
            }
            if let readyNow { continuation.resume(returning: readyNow) }
        }
    }
}

/// Bounded copy of guest stderr, shown only when setup fails.
final class CapturedOutput: Writer, Sendable {
    private let data = Mutex(Data())

    func write(_ chunk: Data) throws {
        data.withLock { buffer in
            buffer.append(chunk)
            if buffer.count > 16_384 { buffer.removeFirst(buffer.count - 16_384) }
        }
    }

    func close() throws {}

    var text: String {
        data.withLock { String(decoding: $0, as: UTF8.self) }
    }
}

/// One line to stderr, prefixed so it is distinguishable from guest output.
func report(_ message: String) {
    FileHandle.standardError.write(Data("rv-microvm: \(message)\n".utf8))
}
