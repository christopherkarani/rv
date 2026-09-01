import RVDomain

public struct PackEnablement: Sendable, Equatable {
    public var id: PackID
    public var enabled: Bool
    public var bundled: Bool

    public init(id: PackID, enabled: Bool, bundled: Bool) {
        self.id = id
        self.enabled = enabled
        self.bundled = bundled
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
            .map { PackEnablement(id: $0, enabled: true, bundled: true) }
    }

    public static func bundlingAll(enabled: Set<PackID>, index: PackIndex) throws -> PackCatalog {
        var records: [PackEnablement] = []
        records.reserveCapacity(index.packIDs.count)
        for id in index.packIDs {
            records.append(PackEnablement(id: id, enabled: enabled.contains(id), bundled: true))
        }
        return PackCatalog(records: records)
    }

    public var enabledIDs: [PackID] {
        records.filter(\.enabled).map(\.id)
    }

    public mutating func setEnabled(id: PackID, enabled: Bool) throws -> PackEnablement {
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            throw PackEnableError.packNotFound(id)
        }
        records[index].enabled = enabled
        return records[index]
    }
}
