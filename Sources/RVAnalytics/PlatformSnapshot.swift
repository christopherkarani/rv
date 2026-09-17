#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Non-identifying platform facts for product counters.
public struct PlatformSnapshot: Sendable, Equatable {
    /// Posted as JSON `macos_version` (stable wire name on every platform).
    public var osVersion: String
    /// Posted as JSON `macos_build` (stable wire name on every platform).
    public var osBuild: String

    public init(osVersion: String, osBuild: String) {
        self.osVersion = osVersion
        self.osBuild = osBuild
    }

    /// Creates a snapshot from the current process's operating system version.
    public static func makeLive(
        processInfo: ProcessInfo = .processInfo
    ) -> PlatformSnapshot {
        let v = processInfo.operatingSystemVersion
        let version = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        return PlatformSnapshot(osVersion: version, osBuild: kernelOSVersion())
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
    /// Reads one `KEY=value` field from an os-release file. Live snapshot uses
    /// `/etc/os-release` when `uname` does not yield a release string.
    package static func osReleaseField(
        _ key: String,
        filePath: String = "/etc/os-release"
    ) -> String? {
        guard let text = try? String(contentsOfFile: filePath, encoding: .utf8) else {
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
