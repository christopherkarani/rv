import Darwin
import Foundation

/// Non-identifying platform facts for product counters.
public struct PlatformSnapshot: Sendable, Equatable {
    public var macosVersion: String
    public var macosBuild: String

    public init(macosVersion: String, macosBuild: String) {
        self.macosVersion = macosVersion
        self.macosBuild = macosBuild
    }

    public static func live(
        processInfo: ProcessInfo = .processInfo
    ) -> PlatformSnapshot {
        let v = processInfo.operatingSystemVersion
        let version = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        return PlatformSnapshot(macosVersion: version, macosBuild: kernelOSVersion())
    }

    private static func kernelOSVersion() -> String {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else {
            return "unknown"
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else {
            return "unknown"
        }
        return String(decoding: buffer.map { UInt8(bitPattern: $0) }.prefix { $0 != 0 }, as: UTF8.self)
    }
}
