import Foundation
import RVDomain

public struct PackRecord: Sendable, Equatable, Codable {
    public var id: PackID
    public var enabled: Bool
    public var bundled: Bool

    public init(id: PackID, enabled: Bool, bundled: Bool) {
        self.id = id
        self.enabled = enabled
        self.bundled = bundled
    }
}

public struct ListPacksReply: Sendable, Equatable, Codable {
    public var packs: [PackRecord]
    public var enabledCount: Int
    public var totalCount: Int

    public init(packs: [PackRecord], enabledCount: Int, totalCount: Int) {
        self.packs = packs
        self.enabledCount = enabledCount
        self.totalCount = totalCount
    }
}

public struct SetPackEnabledParams: Sendable, Equatable, Codable {
    public var id: PackID
    public var enabled: Bool

    public init(id: PackID, enabled: Bool) {
        self.id = id
        self.enabled = enabled
    }
}

public struct SetPackEnabledReply: Sendable, Equatable, Codable {
    public var pack: PackRecord

    public init(pack: PackRecord) {
        self.pack = pack
    }
}
