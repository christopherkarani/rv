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

public struct PackCatalog: Sendable, Equatable {
    public private(set) var records: [PackEnablement]

    public init(bundled: [PackID] = [.coreFilesystem, .coreGit]) {
        records = bundled
            .sorted { $0.rawValue < $1.rawValue }
            .map { PackEnablement(id: $0, enabled: true, bundled: true) }
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
