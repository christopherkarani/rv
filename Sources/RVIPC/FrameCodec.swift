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

    /// Decodes a complete frame, enforcing the four-byte header, 1 MiB cap, and ordered framing errors.
    public static func decode(_ frame: Data) throws -> Data {
        let header = Data(frame.prefix(4))
        let length = try bodyCount(fromHeader: header)
        let expected = 4 + length
        guard frame.count >= expected else { throw FrameCodecError.truncated }
        guard frame.count == expected else { throw FrameCodecError.lengthMismatch }
        return frame.subdata(in: 4..<expected)
    }

    /// Validates a four-byte header and 1 MiB body cap, reporting framing errors in order before empty frames.
    public static func bodyCount(fromHeader: Data) throws -> Int {
        guard fromHeader.count >= 4 else { throw FrameCodecError.truncated }
        let declared = fromHeader.withUnsafeBytes { raw -> UInt32 in
            raw.loadUnaligned(as: UInt32.self).bigEndian
        }
        guard declared <= UInt32(maxBodyBytes) else { throw FrameCodecError.oversized }
        guard fromHeader.count == 4 else { throw FrameCodecError.lengthMismatch }
        guard declared != 0 else { throw FrameCodecError.empty }
        return Int(declared)
    }

    /// Decodes a split frame, enforcing the four-byte header, 1 MiB cap, and ordered framing errors.
    public static func decode(header: Data, body: Data) throws -> Data {
        let expected = try bodyCount(fromHeader: header)
        guard body.count >= expected else { throw FrameCodecError.truncated }
        guard body.count == expected else { throw FrameCodecError.lengthMismatch }
        return body
    }
}
