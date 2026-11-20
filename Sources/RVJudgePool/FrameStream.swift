import Foundation
import RVIPC

/// Length-prefixed frames over a byte stream (the worker pipes): RVIPC's
/// `FrameCodec` format, a four-byte big-endian length then the body, with
/// its 1 MiB cap and its empty-frame refusal.
public enum FrameStream {
    /// One frame for `body`; nil when the body is empty or over the cap.
    public static func frame(_ body: Data) -> Data? {
        guard !body.isEmpty else { return nil }
        return try? FrameCodec.encode(body: body)
    }

    /// One frame carrying `value` as JSON.
    public static func frame<T: Encodable>(json value: T) -> Data? {
        JudgePoolJSON.encode(value).flatMap(frame)
    }
}

/// Accumulates stream bytes and yields whole frame bodies. A framing error
/// (oversized or empty length) poisons the decoder: a peer that broke
/// framing once cannot be resynchronized, so the caller drops it.
public struct FrameStreamDecoder: Sendable {
    private var buffer = Data()
    public private(set) var failed: FrameCodecError?

    public init() {}

    /// Appends `bytes` and returns every body now complete, in order.
    public mutating func feed(_ bytes: Data) -> [Data] {
        guard failed == nil else { return [] }
        buffer.append(bytes)
        var bodies: [Data] = []
        while buffer.count >= 4 {
            let length: Int
            do {
                length = try FrameCodec.bodyCount(fromHeader: Data(buffer.prefix(4)))
            } catch let error as FrameCodecError {
                failed = error
                buffer.removeAll()
                return bodies
            } catch {
                failed = .truncated
                buffer.removeAll()
                return bodies
            }
            guard buffer.count >= 4 + length else { break }
            let start = buffer.startIndex
            bodies.append(Data(buffer[(start + 4)..<(start + 4 + length)]))
            buffer = Data(buffer[(start + 4 + length)...])
        }
        return bodies
    }

    /// Bytes held for an incomplete frame.
    public var pendingBytes: Int { buffer.count }
}
