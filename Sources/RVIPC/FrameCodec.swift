import Foundation

public enum FrameCodecError: Error, Sendable, Equatable {
    case empty
    case truncated
    case oversized
    case lengthMismatch
}

public enum FrameCodec: Sendable {
    public static let maxBodyBytes = 1_048_576

    public static func encode(body: Data) throws -> Data {
        guard body.count <= maxBodyBytes else { throw FrameCodecError.oversized }
        var header = UInt32(body.count).bigEndian
        var frame = Data(bytes: &header, count: 4)
        frame.append(body)
        return frame
    }

    public static func decode(_ frame: Data) throws -> Data {
        guard frame.count >= 4 else { throw FrameCodecError.truncated }
        let declared = frame.prefix(4).withUnsafeBytes { raw -> UInt32 in
            raw.loadUnaligned(as: UInt32.self).bigEndian
        }
        guard declared <= UInt32(maxBodyBytes) else { throw FrameCodecError.oversized }
        let expected = 4 + Int(declared)
        guard frame.count >= expected else { throw FrameCodecError.truncated }
        guard frame.count == expected else { throw FrameCodecError.lengthMismatch }
        if declared == 0 { throw FrameCodecError.empty }
        return frame.subdata(in: 4..<expected)
    }
}
