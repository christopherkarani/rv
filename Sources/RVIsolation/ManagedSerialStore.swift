import Foundation
import RVPolicy

/// The user's `managed-state.json`: applies the anti-rollback check to a
/// loaded organization policy and remembers a raised serial.
public struct ManagedSerialStore: Sendable {
    public var url: URL

    public init(configDirectory: URL) {
        url = configDirectory.appendingPathComponent(ManagedSerialRecord.fileName)
    }

    public func check(_ state: ManagedPolicyState) -> ManagedPolicyState {
        guard case .active = state else { return state }
        let unusable = ManagedPolicyState.invalid(
            "\(url.path) is unreadable or unsafe, so the policy serial cannot be checked for rollback")
        var record = ManagedSerialRecord()
        switch OwnerOnlyFile.read(url, maximumBytes: ManagedSerialRecord.maximumBytes) {
        case .failure:
            return unusable
        case .success(nil):
            break
        case .success(let data?):
            guard case .success(let decoded) = ManagedSerialRecord.decode(data) else { return unusable }
            record = decoded
        }
        let checked = state.checkedForRollback(against: record)
        if let raised = checked.raised { _ = OwnerOnlyFile.write(raised.encoded(), to: url) }
        return checked.state
    }
}

extension ManagedPolicyLocation {
    /// `load()` followed by the anti-rollback check against the user's serial record.
    public func load(serialsIn configDirectory: URL) -> ManagedPolicyState {
        ManagedSerialStore(configDirectory: configDirectory).check(load())
    }
}
