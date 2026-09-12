import Foundation

/// Closed file-tool kinds. Host aliases map onto these; Grep / Glob / MCP do not.
public enum FileToolKind: String, Sendable, Equatable, Codable {
    case read
    case edit
    case write

    /// Ledger / doctor name (`Read` / `Edit` / `Write`).
    public var ledgerName: String {
        switch self {
        case .read:
            "Read"
        case .edit:
            "Edit"
        case .write:
            "Write"
        }
    }

    /// `Read` / `read_file` → read; `Edit` / `edit_file` → edit; `Write` / `write_file` → write.
    public init?(toolName: String) {
        switch toolName {
        case "Read", "read_file":
            self = .read
        case "Edit", "edit_file":
            self = .edit
        case "Write", "write_file":
            self = .write
        default:
            return nil
        }
    }
}

/// Path extracted from a file-tool payload. Empty is representable (deny).
public struct FileToolPath: RawRepresentable, Hashable, Sendable, Equatable, Codable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var isEmpty: Bool {
        rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// First non-empty of `file_path`, `path`, `target_file`, `target`.
    public static func firstPresent(_ values: String?...) -> FileToolPath? {
        firstPresent(Array(values))
    }

    fileprivate static func firstPresent(_ values: [String?]) -> FileToolPath? {
        for value in values {
            if let value, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                return FileToolPath(rawValue: value)
            }
        }
        return nil
    }
}

/// One Read / Edit / Write event. Packs never see this.
public struct FileToolAction: Sendable, Equatable, Codable {
    public var kind: FileToolKind
    public var path: FileToolPath

    public init(kind: FileToolKind, path: FileToolPath) {
        self.kind = kind
        self.path = path
    }

    /// Host-adapter decode: closed kind plus first non-empty path key.
    /// Unknown tools are `nil` (foreign). Missing path keys yield an empty path.
    public static func decoded(toolName: String?, paths: String?...) -> FileToolAction? {
        guard let kind = FileToolKind(toolName: toolName ?? "") else {
            return nil
        }
        let path = FileToolPath.firstPresent(Array(paths)) ?? FileToolPath(rawValue: "")
        return FileToolAction(kind: kind, path: path)
    }
}
