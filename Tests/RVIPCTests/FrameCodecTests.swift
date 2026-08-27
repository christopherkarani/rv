import Foundation
import Testing
@testable import RVIPC

struct FrameCodecTests {
    @Test func lengthPrefixRoundTrip() throws {
        let body = Data("{\"ok\":true}".utf8)
        let frame = try FrameCodec.encode(body: body)
        #expect(frame.count == 4 + body.count)
        #expect(try FrameCodec.decode(frame) == body)
    }

    @Test func emptyBodyIsRejected() throws {
        var header = UInt32(0).bigEndian
        let frame = Data(bytes: &header, count: 4)
        #expect(throws: FrameCodecError.empty) {
            try FrameCodec.decode(frame)
        }
    }

    @Test func truncatedHeaderFails() {
        #expect(throws: FrameCodecError.truncated) {
            try FrameCodec.decode(Data([0x00, 0x00]))
        }
    }

    @Test func oversizedDeclaredLengthFails() {
        var header = UInt32(FrameCodec.maxBodyBytes + 1).bigEndian
        let frame = Data(bytes: &header, count: 4)
        #expect(throws: FrameCodecError.oversized) {
            try FrameCodec.decode(frame)
        }
    }

    @Test func splitFrameRoundTripReturnsReceivedBody() throws {
        let body = Data("{\"ok\":true}".utf8)
        let frame = try FrameCodec.encode(body: body)

        #expect(
            try FrameCodec.decode(
                header: Data(frame.prefix(4)),
                body: Data(frame.dropFirst(4))
            ) == body
        )
    }

    @Test func splitFramePreservesValidationErrors() {
        #expect(throws: FrameCodecError.truncated) {
            try FrameCodec.decode(header: Data([0x00, 0x00]), body: Data())
        }

        var oversized = UInt32(FrameCodec.maxBodyBytes + 1).bigEndian
        #expect(throws: FrameCodecError.oversized) {
            try FrameCodec.decode(
                header: Data(bytes: &oversized, count: 4),
                body: Data()
            )
        }

        var declared = UInt32(2).bigEndian
        let header = Data(bytes: &declared, count: 4)
        #expect(throws: FrameCodecError.truncated) {
            try FrameCodec.decode(header: header, body: Data([0x01]))
        }
        #expect(throws: FrameCodecError.lengthMismatch) {
            try FrameCodec.decode(header: header, body: Data([0x01, 0x02, 0x03]))
        }

        var empty = UInt32(0).bigEndian
        #expect(throws: FrameCodecError.empty) {
            try FrameCodec.decode(
                header: Data(bytes: &empty, count: 4),
                body: Data()
            )
        }
    }

    @Test func bodyCountRejectsOversizedHeaderWithoutBody() {
        var header = UInt32(FrameCodec.maxBodyBytes + 1).bigEndian
        #expect(throws: FrameCodecError.oversized) {
            try FrameCodec.bodyCount(fromHeader: Data(bytes: &header, count: 4))
        }
    }

    @Test func bodyCountRejectsEmptyHeader() {
        var header = UInt32(0).bigEndian
        #expect(throws: FrameCodecError.empty) {
            try FrameCodec.bodyCount(fromHeader: Data(bytes: &header, count: 4))
        }
    }
}
