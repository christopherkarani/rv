import Foundation
import RVDomain
import RVPacks
import RVPolicy

/// A pack `rv protect <tool>` names, with the words it shows.
public struct ProtectTarget: Equatable, Sendable {
    public var packID: PackID
    /// The pack's display name (`Redis`, `Terraform`, `kubectl`).
    public var name: String
    /// The name a person types for it (`redis`), for the next command.
    public var tool: String
    /// Rules a command can reach (placeholders the analyzers emit are left out).
    public var ruleCount: Int

    public init(packID: PackID, name: String, tool: String, ruleCount: Int) {
        self.packID = packID
        self.name = name
        self.tool = tool
        self.ruleCount = ruleCount
    }
}

/// What a typed tool name resolves to.
public enum ProtectResolution: Equatable, Sendable {
    case found(ProtectTarget)
    /// Not a name rv knows; `target` is the nearest one (`reddis` → Redis).
    case nearest(ProtectTarget)
    case unknown
}

/// Plain tool names to bundled packs (`PackToolNames`), and the nearest
/// name for a typo. A pack id (`database.redis`) also names its pack.
public struct ProtectTools: Sendable {
    private let documents: [PackID: PackDocument]
    private let table: [String: PackID]
    /// The name each pack is shown with in the next command: its shortest
    /// tool name.
    private let toolName: [PackID: String]

    public init(documents: [PackDocument]) {
        self.documents = Dictionary(documents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        table = PackToolNames.table(documents: documents)
        var names: [PackID: String] = [:]
        for (name, id) in table.sorted(by: { ($0.key.count, $0.key) < ($1.key.count, $1.key) }) where names[id] == nil {
            if name.contains(" ") == false { names[id] = name }
        }
        toolName = names
    }

    public static func bundled() throws -> ProtectTools {
        try ProtectTools(documents: PackRegistry.loadAllDocuments())
    }

    public func resolve(_ typed: String) -> ProtectResolution {
        let word = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let id = table[word] ?? documents[PackID(rawValue: word)]?.id, let target = target(id) {
            return .found(target)
        }
        guard word.isEmpty == false,
              let near = PacksConfigStore.nearestSelection(to: word, in: Array(table.keys).sorted()),
              let id = table[near], let target = target(id)
        else { return .unknown }
        return .nearest(target)
    }

    public func target(_ id: PackID) -> ProtectTarget? {
        guard let document = documents[id] else { return nil }
        return ProtectTarget(
            packID: id,
            name: document.name,
            tool: toolName[id] ?? id.rawValue,
            ruleCount: document.destructive.filter { $0.pattern != "(?!)" }.count
        )
    }
}
