import RVDomain

public struct PackEnablement: Sendable, Equatable {
    public var id: PackID
    public var isEnabled: Bool
    public var isBundled: Bool

    public init(id: PackID, isEnabled: Bool, isBundled: Bool) {
        self.id = id
        self.isEnabled = isEnabled
        self.isBundled = isBundled
    }
}

public enum PackEnableError: Error, Sendable, Equatable {
    case packNotFound(PackID)
}

/// Mutable enable flags over the bundled catalog (IPC / doctor rows).
public struct PackCatalog: Sendable, Equatable {
    public private(set) var records: [PackEnablement]

    public init(records: [PackEnablement]) {
        self.records = records.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public init(bundled: [PackID] = PackSet.defaultIDs) {
        records = bundled
            .sorted { $0.rawValue < $1.rawValue }
            .map { PackEnablement(id: $0, isEnabled: true, isBundled: true) }
    }

    /// Creates a catalog that marks every indexed pack as bundled, with `enabled` as the on set.
    public static func make(enabled: Set<PackID>, index: PackIndex) -> PackCatalog {
        var records: [PackEnablement] = []
        records.reserveCapacity(index.packIDs.count)
        for id in index.packIDs {
            records.append(PackEnablement(id: id, isEnabled: enabled.contains(id), isBundled: true))
        }
        return PackCatalog(records: records)
    }

    public var enabledIDs: [PackID] {
        records.filter(\.isEnabled).map(\.id)
    }

    public mutating func enable(_ id: PackID) throws -> PackEnablement {
        try setEnabled(id, isEnabled: true)
    }

    public mutating func disable(_ id: PackID) throws -> PackEnablement {
        try setEnabled(id, isEnabled: false)
    }

    private mutating func setEnabled(_ id: PackID, isEnabled: Bool) throws -> PackEnablement {
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            throw PackEnableError.packNotFound(id)
        }
        records[index].isEnabled = isEnabled
        return records[index]
    }
}
