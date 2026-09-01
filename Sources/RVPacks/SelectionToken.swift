import RVDomain

/// One classified operator selection: a pack ID, a category name, or a preset name.
public enum SelectionToken: Hashable, Sendable {
    case id(PackID)
    case category(String)
    case preset(String)

    public var rawValue: String {
        switch self {
        case .id(let id):
            return id.rawValue
        case .category(let name):
            return name
        case .preset(let name):
            return name
        }
    }

    /// The sanctioned boundary where raw operator strings become tokens. One string
    /// may match several families at once (a preset sharing a category's name); every
    /// match is returned so expansion stays additive. Unknown strings surface as
    /// `.id` so rejection carries the operator's own spelling.
    public static func parse(_ raw: String, index: PackIndex) -> [SelectionToken] {
        var tokens: [SelectionToken] = []
        if index.categories[raw] != nil {
            tokens.append(.category(raw))
        }
        if index.presets[raw] != nil {
            tokens.append(.preset(raw))
        }
        if tokens.isEmpty || index.packIDs.contains(PackID(rawValue: raw)) {
            tokens.append(.id(PackID(rawValue: raw)))
        }
        return tokens
    }
}
