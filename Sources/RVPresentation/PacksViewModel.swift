import RVDomain

public struct PackRow: Equatable, Sendable {
    public var id: PackID
    public var enabled: Bool
    public var summary: String

    public init(id: PackID, enabled: Bool, summary: String) {
        self.id = id
        self.enabled = enabled
        self.summary = summary
    }
}

public struct PacksViewModel: Equatable, Sendable {
    public var rows: [PackRow]

    public init(rows: [PackRow]) {
        self.rows = rows
    }
}

public func packsViewModel(enabled: [PackID], catalog: [(PackID, String)]) -> PacksViewModel {
    let on = Set(enabled)
    let rows = catalog.map { item in
        PackRow(id: item.0, enabled: on.contains(item.0), summary: item.1)
    }
    return PacksViewModel(rows: rows)
}
