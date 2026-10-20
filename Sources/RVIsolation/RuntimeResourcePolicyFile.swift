import Foundation
import RVDomain
import RVPolicy

/// Encodes and atomically replaces the operator's machine policy.
///
/// Reads stay in `RuntimeResourcePolicyStore`. Every write round-trips
/// through the store's own decoder first, so `rv init` and
/// `rv secrets set --profile` can only persist documents the host would
/// accept. The file replace itself is owner-only 0600.
public enum RuntimeResourcePolicyFile {
    public static let fileName = "runtime-resources.json"

    public static func fileURL(configDirectory: URL) -> URL {
        configDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    /// Canonical JSON for this policy; round-trips through the store decoder.
    public static func encode(_ policy: RuntimeResourcePolicy) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(policy)) ?? Data()
        return data + Data("\n".utf8)
    }

    /// Validates, then atomically replaces runtime-resources.json (0600,
    /// owner-only directory). Fails closed on any validation or write error.
    public static func write(
        _ policy: RuntimeResourcePolicy, configDirectory: URL
    ) -> Result<Void, RuntimeResourcePolicyError> {
        let data = encode(policy)
        if case .failure(let error) = RuntimeResourcePolicyStore.decode(data) {
            return .failure(error)
        }
        guard OwnerOnlyFile.write(data, to: fileURL(configDirectory: configDirectory)) else {
            return .failure(.unreadable)
        }
        return .success(())
    }

    public static func message(_ error: RuntimeResourcePolicyError) -> String {
        switch error {
        case .unsafeLocation:
            "runtime-resources.json is not safe to use (owner-only file and directory required)"
        case .unreadable:
            "runtime-resources.json could not be read or written"
        case .oversized:
            "runtime-resources.json is larger than 64 KiB"
        case .invalidDocument:
            "runtime-resources.json is invalid"
        case .unsupportedVersion:
            "runtime-resources.json has an unsupported version"
        }
    }
}
