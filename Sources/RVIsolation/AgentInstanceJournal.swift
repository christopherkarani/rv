#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain

/// One line in the Agent Instance journal: a description of what happened.
///
/// History never recreates live authority. Loading these records informs
/// operators and audit; only the live registry holds usable validity, and a
/// fresh registry starts empty no matter what the journal contains.
struct AgentInstanceJournalRecord: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        /// A launch attempt was announced. The instance is not usable yet.
        case attempted
        /// The runtime established and the instance became active.
        case established
        /// Revocation began. New privileged use is already refused.
        case revoking
        /// The instance is inactive. `detail` carries the terminal outcome.
        case finished
    }

    var kind: Kind
    var instance: UUID
    var workspace: UUID
    var runtime: UUID
    var definition: String
    var revision: String
    var ownerUID: UInt32
    var assurance: String
    var recordedAt: Date
    /// Parent instance for a delegated child. Absent otherwise.
    var parent: UUID?
    /// Bounded terminal vocabulary (`revoked:<reason>`, `refused:<stage>`).
    /// Absent on lines that carry no outcome.
    var detail: String?

    init(
        kind: Kind,
        instance: UUID,
        workspace: UUID,
        runtime: UUID,
        definition: String,
        revision: String,
        ownerUID: UInt32,
        assurance: String,
        recordedAt: Date,
        parent: UUID? = nil,
        detail: String? = nil
    ) {
        self.kind = kind
        self.instance = instance
        self.workspace = workspace
        self.runtime = runtime
        self.definition = definition
        self.revision = revision
        self.ownerUID = ownerUID
        self.assurance = assurance
        self.recordedAt = recordedAt
        self.parent = parent
        self.detail = detail
    }
}

/// Append-only Agent Instance history. Not the denial ledger.
struct AgentInstanceJournalStore: Sendable {
    var append: @Sendable (AgentInstanceJournalRecord) -> Result<Void, IsolationApplyError>
    /// File recovery reads. Nil when the home directory cannot be named.
    var file: URL?

    static let production: AgentInstanceJournalStore = {
        let url = AgentInstanceJournal.productionURL()
        return AgentInstanceJournalStore(
            append: { record in
                guard let url = AgentInstanceJournal.productionURL() else {
                    return .failure(.sessionRecordFailed)
                }
                return AgentInstanceJournal.append(record, to: url)
            },
            file: url
        )
    }()

    static func file(_ url: URL) -> AgentInstanceJournalStore {
        AgentInstanceJournalStore(
            append: { record in
                AgentInstanceJournal.append(record, to: url)
            },
            file: url
        )
    }
}

struct AgentInstanceJournalRead: Equatable, Sendable {
    var records: [AgentInstanceJournalRecord]
    /// The last line is not a complete record. Earlier records are kept.
    var tornTrailing: Bool
    /// A non-trailing line could not be decoded. The sequence is not trustworthy.
    var interiorCorruption: Bool
}

enum AgentInstanceJournalLoad: Equatable, Sendable {
    case missing
    case unreadable
    case decoded(AgentInstanceJournalRead)
}

enum AgentInstanceJournal {
    private struct Encoded: Codable {
        var kind: String
        var instance: UUID
        var workspace: UUID
        var runtime: UUID
        var definition: String
        var revision: String
        var ownerUID: UInt32
        var assurance: String
        var recordedAt: Double
        var parent: UUID?
        var detail: String?
    }

    /// `$HOME/.config/rv/agent-instances.jsonl`. Ignores `XDG_CONFIG_HOME`.
    static func productionURL() -> URL? {
        guard let home = ProcessInfo.processInfo.environment["HOME"],
            home.hasPrefix("/"), home.contains("\0") == false
        else {
            return nil
        }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("rv", isDirectory: true)
            .appendingPathComponent("agent-instances.jsonl", isDirectory: false)
    }

    static func append(
        _ record: AgentInstanceJournalRecord,
        to url: URL
    ) -> Result<Void, IsolationApplyError> {
        let encoded = Encoded(
            kind: record.kind.rawValue,
            instance: record.instance,
            workspace: record.workspace,
            runtime: record.runtime,
            definition: record.definition,
            revision: record.revision,
            ownerUID: record.ownerUID,
            assurance: record.assurance,
            recordedAt: record.recordedAt.timeIntervalSince1970,
            parent: record.parent,
            detail: record.detail
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(encoded) else {
            return .failure(.sessionRecordFailed)
        }
        data.append(UInt8(ascii: "\n"))
        return RuntimeSessionLog.appendExclusiveLine(data, to: url)
    }

    static func records(at url: URL) -> [AgentInstanceJournalRecord] {
        guard case .decoded(let read) = load(at: url) else { return [] }
        return read.records
    }

    /// Missing file is an empty history. A file that cannot be read is not.
    static func load(at url: URL) -> AgentInstanceJournalLoad {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if exists == false {
            return .missing
        }
        if isDirectory.boolValue {
            return .unreadable
        }
        guard let data = try? Data(contentsOf: url) else {
            return .unreadable
        }
        if data.isEmpty {
            return .decoded(
                AgentInstanceJournalRead(records: [], tornTrailing: false, interiorCorruption: false)
            )
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return .decoded(
                AgentInstanceJournalRead(records: [], tornTrailing: true, interiorCorruption: false)
            )
        }
        return .decoded(decode(text))
    }

    private static func decode(_ text: String) -> AgentInstanceJournalRead {
        let endsWithNewline = text.hasSuffix("\n")
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if endsWithNewline, lines.last?.isEmpty == true {
            lines.removeLast()
        }
        let decoder = JSONDecoder()
        var records: [AgentInstanceJournalRecord] = []
        var tornTrailing = false
        var interiorCorruption = false
        for (index, line) in lines.enumerated() {
            if line.isEmpty { continue }
            let isLast = index == lines.index(before: lines.endIndex)
            if let record = decodeLine(line, decoder: decoder) {
                records.append(record)
                continue
            }
            if isLast {
                tornTrailing = true
            } else {
                interiorCorruption = true
            }
        }
        return AgentInstanceJournalRead(
            records: records,
            tornTrailing: tornTrailing,
            interiorCorruption: interiorCorruption
        )
    }

    private static func decodeLine(_ line: String, decoder: JSONDecoder) -> AgentInstanceJournalRecord? {
        guard let data = line.data(using: .utf8),
            let record = try? decoder.decode(Encoded.self, from: data),
            let kind = AgentInstanceJournalRecord.Kind(rawValue: record.kind)
        else {
            return nil
        }
        return AgentInstanceJournalRecord(
            kind: kind,
            instance: record.instance,
            workspace: record.workspace,
            runtime: record.runtime,
            definition: record.definition,
            revision: record.revision,
            ownerUID: record.ownerUID,
            assurance: record.assurance,
            recordedAt: Date(timeIntervalSince1970: record.recordedAt),
            parent: record.parent,
            detail: record.detail
        )
    }
}
