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
}
