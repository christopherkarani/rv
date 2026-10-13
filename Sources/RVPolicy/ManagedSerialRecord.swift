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

    /// Serials are decimal strings. A JSON number would round above 2^53, and
    /// the rounded value can replace a higher exact serial.
    public func encoded() -> Data {
        let pairs = highest.keys.sorted().compactMap { key -> String? in
            guard let serial = highest[key] else { return nil }
            return "\(JSONLiteral.quoted(key)): \(JSONLiteral.quoted(String(serial)))"
        }
        return Data("{\"version\": 1, \"highest\": {\(pairs.joined(separator: ", "))}}\n".utf8)
    }

    public static func decode(_ data: Data) -> Result<ManagedSerialRecord, ManagedPolicyError> {
        guard let root = JSONLiteral.parse(data)?.object, case .number(let version) = root["version"], version == "1",
            let highest = root["highest"]?.object
        else { return .failure(ManagedPolicyError("\(fileName) is not a valid rv serial record")) }
        var map: [String: Int] = [:]
        for (key, value) in highest {
            let token: String?
            switch value {
            case .number(let spelling), .string(let spelling): token = spelling
            default: token = nil
            }
            guard let token, let exact = JSONLiteral.nonNegativeInteger(token) else {
                return .failure(ManagedPolicyError("\(fileName) is not a valid rv serial record"))
            }
            map[key] = exact
        }
        return .success(ManagedSerialRecord(highest: map))
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
