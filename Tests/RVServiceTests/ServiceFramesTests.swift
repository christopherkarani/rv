import Foundation
import Testing
import RVIPC
import RVService

struct ServiceFramesTests {
    @Test func encodeDecode_roundTripsBody() throws {
        let body = Data("{\"protocol\":\"rv.ipc.v1\"}".utf8)
        let frame = try ServiceFrames.encode(body: body)
        #expect(frame.count == 4 + body.count)
        #expect(try ServiceFrames.decode(frame) == body)
    }

    @Test func decode_emptyHeader_isEmpty() throws {
        var header = UInt32(0).bigEndian
        let frame = Data(bytes: &header, count: 4)
        #expect(throws: FrameCodecError.empty) {
            _ = try ServiceFrames.decode(frame)
        }
    }

    @Test func decode_truncatedAndLengthMismatch() throws {
        let body = Data("hello".utf8)
        var frame = try ServiceFrames.encode(body: body)
        frame.removeLast()
        #expect(throws: FrameCodecError.truncated) {
            _ = try ServiceFrames.decode(frame)
        }

        var long = try ServiceFrames.encode(body: body)
        long.append(0x00)
        #expect(throws: FrameCodecError.lengthMismatch) {
            _ = try ServiceFrames.decode(long)
        }
    }

    @Test func encode_oversized_throws() {
        let body = Data(count: FrameCodec.maxBodyBytes + 1)
        #expect(throws: FrameCodecError.oversized) {
            _ = try ServiceFrames.encode(body: body)
        }
    }
}
