import Foundation
import RVIPC

public enum ServiceFrames {
    public static func encode(body: Data) throws -> Data {
        try FrameCodec.encode(body: body)
    }

    public static func decode(_ frame: Data) throws -> Data {
        try FrameCodec.decode(frame)
    }
}
