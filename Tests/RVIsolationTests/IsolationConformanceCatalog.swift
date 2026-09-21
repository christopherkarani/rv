/// Named first-slice conformance rows. Completeness is asserted against the
/// §8 ID list in `IsolationConformanceTests` — a missing deny ID must fail.
enum IsolationConformanceVerdict: String, Sendable, Equatable {
    case deny
    case allowIn = "allow-in"
    case hole
    case failClosed
}

enum IsolationConformanceID: String, Sendable, Equatable, CaseIterable {
    case fsWriteIn = "FS-WRITE-IN"
    case fsWriteOut = "FS-WRITE-OUT"
    case fsWriteRepo = "FS-WRITE-REPO"
    case fsMkdirOut = "FS-MKDIR-OUT"
    case fsAppendOut = "FS-APPEND-OUT"
    case fsUnlinkOut = "FS-UNLINK-OUT"
    case fsRenameOut = "FS-RENAME-OUT"
    case descSh = "DESC-SH"
    case descNested = "DESC-NESTED"
    case holeNet = "HOLE-NET"
    case holeRead = "HOLE-READ"
    case holeSymlink = "HOLE-SYMLINK"
    case fcUnavailable = "FC-UNAVAILABLE"
    case fcLandlockDarwin = "FC-LANDLOCK-DARWIN"
    case fcRootWs = "FC-ROOT-WS"
    case fcHelperInWs = "FC-HELPER-IN-WS"
}

struct IsolationConformanceEntry: Sendable, Equatable {
    let id: IsolationConformanceID
    let verdict: IsolationConformanceVerdict
}

enum IsolationConformanceCatalog {
    static let entries: [IsolationConformanceEntry] = [
        IsolationConformanceEntry(id: .fsWriteIn, verdict: .allowIn),
        IsolationConformanceEntry(id: .fsWriteOut, verdict: .deny),
        IsolationConformanceEntry(id: .fsWriteRepo, verdict: .deny),
        IsolationConformanceEntry(id: .fsMkdirOut, verdict: .deny),
        IsolationConformanceEntry(id: .fsAppendOut, verdict: .deny),
        IsolationConformanceEntry(id: .fsUnlinkOut, verdict: .deny),
        IsolationConformanceEntry(id: .fsRenameOut, verdict: .deny),
        IsolationConformanceEntry(id: .descSh, verdict: .deny),
        IsolationConformanceEntry(id: .descNested, verdict: .deny),
        IsolationConformanceEntry(id: .holeNet, verdict: .hole),
        IsolationConformanceEntry(id: .holeRead, verdict: .hole),
        IsolationConformanceEntry(id: .holeSymlink, verdict: .hole),
        IsolationConformanceEntry(id: .fcUnavailable, verdict: .failClosed),
        IsolationConformanceEntry(id: .fcLandlockDarwin, verdict: .failClosed),
        IsolationConformanceEntry(id: .fcRootWs, verdict: .failClosed),
        IsolationConformanceEntry(id: .fcHelperInWs, verdict: .failClosed),
    ]

    static var ids: [String] {
        entries.map(\.id.rawValue)
    }

    static var denyAndAllowIn: [IsolationConformanceEntry] {
        entries.filter { entry in
            switch entry.verdict {
            case .deny, .allowIn:
                return true
            case .hole, .failClosed:
                return false
            }
        }
    }

    static var holes: [IsolationConformanceEntry] {
        entries.filter { entry in
            switch entry.verdict {
            case .hole:
                return true
            case .deny, .allowIn, .failClosed:
                return false
            }
        }
    }

    static var failClosed: [IsolationConformanceEntry] {
        entries.filter { entry in
            switch entry.verdict {
            case .failClosed:
                return true
            case .deny, .allowIn, .hole:
                return false
            }
        }
    }
}
