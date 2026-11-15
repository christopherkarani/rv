import Foundation
import Testing
@testable import RVIsolation

@Suite("Gateway response writer")
struct GatewayResponseWriterTests {
    /// The scrubber holds a body's last byte back while it could begin the
    /// secret, and `finish` writes it as the last chunk. When that write
    /// fails, nothing may follow it: a terminator would let the client read
    /// a well-formed body missing its last byte.
    @Test
    func aTailThatCannotBeWrittenIsNotFollowedByTheTerminator() {
        let tail = Array("1\r\ns\r\n".utf8)
        let (writer, sent) = Self.writer { $0 != tail }
        writer.head(status: 200, headers: [(name: "Content-Type", value: "text/plain")])
        // "s" could begin the secret, so it is held back for `finish`.
        #expect(writer.body(Data("hello s".utf8)))
        writer.finish()
        let writes = sent.all
        #expect(writes.last == tail, "something was written after the tail's write failed")
        #expect(writes.contains(Array("0\r\n\r\n".utf8)) == false)
        #expect(writer.failure == GatewayResponseWriter.cutShort)
    }

    /// The same body, its tail written, ends with the terminator.
    @Test
    func aTailThatIsWrittenIsFollowedByTheTerminator() {
        let (writer, sent) = Self.writer { _ in true }
        writer.head(status: 200, headers: [(name: "Content-Type", value: "text/plain")])
        #expect(writer.body(Data("hello s".utf8)))
        writer.finish()
        let writes = sent.all
        #expect(Array(writes.suffix(2)) == [Array("1\r\ns\r\n".utf8), Array("0\r\n\r\n".utf8)])
        #expect(writer.failure == nil)
    }

    /// A writer whose every write is recorded, and succeeds when `succeeds` says so.
    private static func writer(
        _ succeeds: @escaping @Sendable ([UInt8]) -> Bool
    ) -> (GatewayResponseWriter, Writes) {
        let secret = Array("sk-live-REAL-0123456789".utf8)
        let writer = GatewayResponseWriter(fd: -1, method: "GET", scrub: [(secret, Array("sk-placeholder".utf8))])
        let sent = Writes()
        writer.transmit = { _, bytes in
            sent.append(bytes)
            return succeeds(bytes)
        }
        return (writer, sent)
    }
}

private final class Writes: @unchecked Sendable {
    private let lock = NSLock()
    private var writes: [[UInt8]] = []

    func append(_ bytes: [UInt8]) {
        lock.lock()
        writes.append(bytes)
        lock.unlock()
    }

    var all: [[UInt8]] {
        lock.lock()
        defer { lock.unlock() }
        return writes
    }
}
