import Foundation
import RVIPC
import Testing
@testable import RVJudgePool

@Suite("Judge pool frames")
struct FrameStreamTests {
    @Test("frames split at any byte boundary decode to the same bodies, in order")
    func splitsAnywhere() throws {
        let one = try #require(FrameStream.frame(json: WorkerEvent.ready(checkpoint: "c")))
        let two = try #require(FrameStream.frame(json: WorkerEvent.failed(id: "r1")))
        let stream = one + two
        for cut in 0...stream.count {
            var decoder = FrameStreamDecoder()
            let bodies = decoder.feed(Data(stream.prefix(cut))) + decoder.feed(Data(stream.dropFirst(cut)))
            let events = bodies.compactMap { JudgePoolJSON.decode(WorkerEvent.self, from: $0) }
            #expect(events == [.ready(checkpoint: "c"), .failed(id: "r1")])
            #expect(decoder.pendingBytes == 0)
        }
    }

    @Test("an oversized length poisons the decoder")
    func oversized() {
        var decoder = FrameStreamDecoder()
        var header = UInt32(FrameCodec.maxBodyBytes + 1).bigEndian
        let bytes = Data(bytes: &header, count: 4) + Data("x".utf8)
        #expect(decoder.feed(bytes).isEmpty)
        #expect(decoder.failed == .oversized)
        #expect(decoder.feed(FrameStream.frame(Data("{}".utf8))!).isEmpty, "never resynchronizes")
    }

    @Test("an empty frame poisons the decoder")
    func empty() {
        var decoder = FrameStreamDecoder()
        #expect(decoder.feed(Data([0, 0, 0, 0])).isEmpty)
        #expect(decoder.failed == .empty)
    }

    @Test("an empty body is never framed")
    func noEmptyFrames() {
        #expect(FrameStream.frame(Data()) == nil)
    }

    @Test("the worker request carries exactly the judge inputs")
    func requestRoundTrip() throws {
        let request = WorkerRequest(id: "r1", input: JudgeInput(command: "git push --force", contextLines: ["cwd-inside-repo: yes"]))
        let frame = try #require(FrameStream.frame(json: request))
        var decoder = FrameStreamDecoder()
        let body = try #require(decoder.feed(frame).first)
        #expect(JudgePoolJSON.decode(WorkerRequest.self, from: body) == request)
    }

    @Test("client replies round-trip, including verdict bytes and the answering worker")
    func replyRoundTrip() throws {
        let replies: [JudgePoolReply] = [
            .outcome(.verdict(Data(#"{"risk":0.1}"#.utf8), slot: .fallback)),
            .outcome(.loadFailed(LoadFailure(kind: .badBundle, message: "m"))),
            .outcome(.late), .outcome(.busy), .outcome(.warming), .outcome(.failed("x")),
            .helloAck(protocolVersion: JudgePoolWire.protocolVersion), .ack, .refused,
        ]
        for reply in replies {
            let data = try #require(JudgePoolJSON.encode(reply))
            #expect(JudgePoolJSON.decode(JudgePoolReply.self, from: data) == reply)
        }
    }

    @Test("model keys outside the shipped engines or not absolute are malformed")
    func modelKeyValidation() {
        #expect(ModelKey(engine: "ft", bundle: "/a/b").isWellFormed)
        #expect(ModelKey(engine: "laya", bundle: "/a/b").isWellFormed)
        #expect(!ModelKey(engine: "onnx", bundle: "/a/b").isWellFormed)
        #expect(!ModelKey(engine: "ft", bundle: "a/b").isWellFormed)
        #expect(!ModelKey(engine: "ft", bundle: "/a\0b").isWellFormed)
    }
}
