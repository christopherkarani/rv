#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
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
#if canImport(Darwin)
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else {
            return "unknown"
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else {
            return "unknown"
        }
        return String(decoding: buffer.map { UInt8(bitPattern: $0) }.prefix { $0 != 0 }, as: UTF8.self)
#else
        var systemInfo = utsname()
        if uname(&systemInfo) == 0 {
            let release = withUnsafeBytes(of: systemInfo.release) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            if release.isEmpty == false {
                return release
            }
        }
        return osReleaseField("BUILD_ID") ?? osReleaseField("VERSION_ID") ?? "unknown"
#endif
    }

#if !canImport(Darwin)
    private static func osReleaseField(_ key: String) -> String? {
        guard let text = try? String(contentsOfFile: "/etc/os-release", encoding: .utf8) else {
            return nil
        }
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\(key)=") else { continue }
            var value = String(trimmed.dropFirst(key.count + 1))
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value.removeFirst()
                value.removeLast()
            }
            return value
        }
        return nil
    }
#endif
}
