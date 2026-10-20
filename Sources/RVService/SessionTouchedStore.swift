import Foundation
import RVDomain

/// Session file-tracking for the fine-tuned judge (`JudgeContext.agentTouched`).
///
/// When a hook reports a file-tool mutation (Edit/Write) or an allowed shell
/// command creates/writes files, the paths land here keyed by (session,
/// workspace root). When the judge later scores a shell command in that
/// session, the lookup supplies `agent-touched` context so
/// context-appropriate allows work in production (e.g. deleting a directory
/// the agent itself created).
///
/// Keying: one bucket per (sessionID, workspace root). A host event with no
/// session id keys on the workspace root alone — a deliberate limitation:
/// concurrent session-less agents sharing one workspace also share one
/// bucket. Entries expire 30 minutes after recording (TTL enforced on read);
/// each bucket caps at 200 paths, LRU-ish (oldest evicted first).
///
/// Memory only: no disk persistence in v1, so a daemon restart forgets
/// everything. CLI in-process paths construct their own store per process
/// (starts empty); one-shot CLI invocations never accrue daemon history.
///
/// Normalization: absolute paths relativize against the workspace into
/// training form (`./rel/path`; directories carry a trailing `/`), plus
/// every ancestor directory of a recorded file (target matching is
/// parent-aware). Paths outside the workspace cannot relativize, so only
/// their basename is kept (`./basename`) — the model still sees that
/// something was touched, never the outside absolute path.
public final class SessionTouchedStore: @unchecked Sendable {
    /// Entries older than this are dropped on read.
    public static let ttl: TimeInterval = 30 * 60
    /// Per (session, workspace) cap; oldest evicted first.
    public static let maxEntriesPerKey = 200
    /// Training format caps the agent-touched line at 8 entries.
    public static let maxLookupEntries = 8

    private struct Key: Hashable {
        var session: String?
        var workspace: String
    }

    private struct Entry {
        var path: String
        var touchedAt: Date
    }

    private let lock = NSLock()
    private var tables: [Key: [Entry]] = [:]

    public init() {}

    /// Records known-mutated paths. Call only for actual writes (Edit/Write
    /// file tools, allowed shell writers) — never for read-only views.
    public func record(
        paths: [String],
        session: SessionID?,
        workspace: WorkingDirectory?,
        now: Date = Date()
    ) {
        let items = Self.normalize(paths: paths, workspace: workspace)
        guard items.isEmpty == false else { return }
        let key = Self.key(session: session, workspace: workspace)
        lock.lock()
        defer { lock.unlock() }
        var list = tables[key] ?? []
        list.removeAll { now.timeIntervalSince($0.touchedAt) > Self.ttl }
        for item in items {
            list.removeAll { $0.path == item }
            list.append(Entry(path: item, touchedAt: now))
        }
        if list.count > Self.maxEntriesPerKey {
            list.removeFirst(list.count - Self.maxEntriesPerKey)
        }
        tables[key] = list
    }

    /// Live entry count for one bucket after TTL pruning. Test seam for
    /// the per-key cap (lookup only ever surfaces 8).
    func entryCount(
        session: SessionID?,
        workspace: WorkingDirectory?,
        now: Date = Date()
    ) -> Int {
        let key = Self.key(session: session, workspace: workspace)
        lock.lock()
        defer { lock.unlock() }
        var list = tables[key] ?? []
        list.removeAll { now.timeIntervalSince($0.touchedAt) > Self.ttl }
        tables[key] = list
        return list.count
    }

    /// Workspace-relative training-form paths, sorted, directories with a
    /// trailing `/`, at most 8. A crowded bucket prefers the
    /// most-recently-touched directories, then the most-recently-touched
    /// files; the survivors sort codepoint-wise like training. A looked-up
    /// empty list is a true negative (nothing touched yet), not unknown.
    public func lookup(
        session: SessionID?,
        workspace: WorkingDirectory?,
        now: Date = Date()
    ) -> [String] {
        let key = Self.key(session: session, workspace: workspace)
        lock.lock()
        defer { lock.unlock() }
        var list = tables[key] ?? []
        list.removeAll { now.timeIntervalSince($0.touchedAt) > Self.ttl }
        tables[key] = list
        let freshFirst = list.reversed()
        let dirs = freshFirst.filter { $0.path.hasSuffix("/") }
        let files = freshFirst.filter { !$0.path.hasSuffix("/") }
        let picked = (dirs + files).prefix(Self.maxLookupEntries).map(\.path)
        return picked.sorted {
            $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars)
        }
    }

    private static func key(session: SessionID?, workspace: WorkingDirectory?) -> Key {
        let root = workspace.map { standardize($0.rawValue) } ?? ""
        return Key(session: session?.rawValue, workspace: root)
    }

    private static func standardize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardized.path
    }

    private static func normalize(paths: [String], workspace: WorkingDirectory?) -> [String] {
        let root = workspace.map { standardize($0.rawValue) }
        var out: [String] = []
        for raw in paths {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { continue }
            if let root {
                let dirHint = trimmed.hasSuffix("/")
                let abs: String?
                if trimmed.hasPrefix("/") {
                    abs = standardize(trimmed)
                } else if trimmed.hasPrefix("~") {
                    abs = nil
                } else {
                    abs = standardize(root + "/" + trimmed)
                }
                if let abs, abs != root, abs.hasPrefix(root + "/") {
                    appendInside(String(abs.dropFirst(root.count + 1)), dirHint: dirHint, to: &out)
                } else if let abs {
                    if abs == root { continue }
                    appendBasename(abs, to: &out)
                } else {
                    appendBasename(trimmed, to: &out)
                }
            } else if trimmed.hasPrefix("/") {
                appendBasename(trimmed, to: &out)
            } else {
                let rel = trimmed.hasPrefix("./") ? String(trimmed.dropFirst(2)) : trimmed
                appendInside(rel, dirHint: rel.hasSuffix("/"), to: &out)
            }
        }
        return out
    }

    /// A workspace-inside relative path: the file entry plus every ancestor
    /// directory (trailing `/`). Directory inputs (`dirHint`) record as the
    /// directory itself.
    private static func appendInside(_ rel: String, dirHint: Bool, to out: inout [String]) {
        var rel = rel
        while rel.hasSuffix("/") { rel.removeLast() }
        guard rel.isEmpty == false else { return }
        if dirHint {
            out.append("./" + rel + "/")
        } else {
            out.append("./" + rel)
        }
        var prefix = ""
        for component in rel.split(separator: "/").dropLast() {
            prefix = prefix.isEmpty ? String(component) : prefix + "/" + String(component)
            out.append("./" + prefix + "/")
        }
    }

    private static func appendBasename(_ path: String, to out: inout [String]) {
        var path = path
        while path.hasSuffix("/"), path.count > 1 { path.removeLast() }
        let base = URL(fileURLWithPath: path).lastPathComponent
        guard base.isEmpty == false, base != "/" else { return }
        out.append("./" + base)
    }
}
