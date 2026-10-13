import Foundation

/// Highest organization-policy serial accepted per policy directory (D21).
/// Kept in the user's config, so it stops replay of an older signed bundle
/// by whoever can write the root-owned directory, not by the user.
public struct ManagedSerialRecord: Sendable, Equatable {
    public static let fileName = "managed-state.json"
    public static let maximumBytes = 64 * 1024

    public var highest: [String: Int]

    public init(highest: [String: Int] = [:]) {
        self.highest = highest
    }

    private struct File: Codable {
        var version: Int
        var highest: [String: Int]
    }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(File(version: 1, highest: highest))) ?? Data()
    }

    public static func decode(_ data: Data) -> Result<ManagedSerialRecord, ManagedPolicyError> {
        guard let file = try? JSONDecoder().decode(File.self, from: data), file.version == 1,
            file.highest.values.allSatisfy({ $0 >= 0 })
        else { return .failure(ManagedPolicyError("\(fileName) is not a valid rv serial record")) }
        return .success(ManagedSerialRecord(highest: file.highest))
    }
}

extension ManagedPolicyState {
    /// The state after the anti-rollback check, and the record to save when
    /// this policy raised the highest serial for its directory.
    public func checkedForRollback(
        against record: ManagedSerialRecord
    ) -> (state: ManagedPolicyState, raised: ManagedSerialRecord?) {
        guard case .active(var bundle) = self else { return (self, nil) }
        let file = ManagedPolicyLocation.policyFile
        let remembered = record.highest[bundle.directory]
        switch (bundle.policy.serial, remembered) {
        case (nil, nil):
            return (self, nil)
        case (nil, let highest?):
            return (.invalid(
                "rollback: \(file) has no serial but serial \(highest) was already accepted from \(bundle.directory)"), nil)
        case (let serial?, let highest?) where serial < highest:
            return (.invalid(
                "rollback: \(file) serial \(serial) is lower than serial \(highest) already accepted from \(bundle.directory)"),
                nil)
        case (let serial?, let highest):
            bundle.highestSerial = serial
            guard serial != highest else { return (.active(bundle), nil) }
            var raised = record
            raised.highest[bundle.directory] = serial
            return (.active(bundle), raised)
        }
    }
}
