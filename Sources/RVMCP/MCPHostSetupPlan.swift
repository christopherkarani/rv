import Foundation

/// What `rv mcp setup` / `--undo` saw on disk for one path, captured before deciding anything.
struct MCPFileState: Sendable, Equatable {
    var contents: MCPInventory.HostFile
    var isSymbolicLink: Bool
}

struct MCPHostSnapshot: Sendable {
    var file: MCPHostFile
    var state: MCPFileState
}

/// The pure result of deciding every host-config rewrite before any file is
/// written. One write per distinct path, however many entries share it.
struct MCPSetupPlan: Sendable, Equatable {
    struct Write: Sendable, Equatable {
        var path: URL
        var data: Data
        var records: [MCPSetupRecord]
        var changed: [String]
    }

    var prior: [MCPSetupRecord]
    var writes: [Write]
    /// `changed` / `skipped` / `manualSteps` for the whole plan; `backups` stay empty until apply.
    var report: MCPSetupResult

    /// Prior records plus the records of the paths in `written`.
    func manifest(written: Set<String>) -> [MCPSetupRecord] {
        prior + writes.filter { written.contains($0.path.path) }.flatMap(\.records)
    }

    var allPaths: Set<String> { Set(writes.map(\.path.path)) }
}

struct MCPUndoPlan: Sendable {
    struct Write: Sendable {
        var path: URL
        var data: Data
        var changed: [String]
    }

    var records: [MCPSetupRecord]
    /// Indices into `records` whose work is finished once the path they sit on is settled.
    var retired: Set<Int>
    var writes: [Write]
    var report: MCPSetupResult

    /// Records still needed after the paths in `written` were restored: those not retired,
    /// plus retired ones whose file still has to be rewritten.
    func manifest(written: Set<String>) -> [MCPSetupRecord] {
        let pending = Set(writes.map(\.path.path)).subtracting(written)
        return records.indices.filter { index in
            retired.contains(index) == false || pending.contains(records[index].configPath)
        }.map { records[$0] }
    }
}

extension MCPHostSetup {
    static func plan(
        snapshots: [MCPHostSnapshot],
        manifest: [MCPSetupRecord],
        configuration: MCPConfiguration,
        servers filter: Set<String>?,
        rvPath: String
    ) -> Result<MCPSetupPlan, MCPSetupError> {
        var report = MCPSetupResult()
        /// Evolving root per path: entries sharing a path (`~/.claude.json` user and
        /// project scope) see each other's rewrite and produce one write.
        var roots: [String: JSONValue] = [:]
        var order: [String] = []
        var pending: [String: MCPSetupPlan.Write] = [:]
        for snapshot in snapshots {
            let file = snapshot.file
            guard case .data(let data) = snapshot.state.contents else { continue }
            switch file.format {
            case .codexTOML:
                let entries = (try? MCPInventory.entries(in: data, file: file).get()) ?? []
                for entry in entries where wanted(entry.name, filter) && entry.governedServer == nil
                    && configuration.server(named: entry.name) != nil
                {
                    let name = shellQuote(entry.name)
                    let rv = shellQuote(MCPDisplayedText.field(rvPath))
                    report.manualSteps.append(
                        "codex mcp remove \(name) && codex mcp add \(name) -- \(rv) mcp serve --server \(name)")
                }
            case .json(let keyPath, _, let opencode):
                let path = file.path.path
                let root: JSONValue
                if let known = roots[path] {
                    root = known
                } else {
                    guard let parsed = try? JSONValue.parse(data, maximumDepth: 128, lenient: true) else {
                        return .failure(.unreadable(path))
                    }
                    root = parsed
                }
                roots[path] = root
                guard var servers = value(at: keyPath, in: root)?.objectValue else { continue }
                var records: [MCPSetupRecord] = []
                var changed: [String] = []
                for (name, entry) in servers.entries where wanted(name, filter) {
                    guard let object = entry.objectValue,
                        let hostEntry = opencode
                            ? MCPInventory.opencodeEntry(name: name, object: object, file: file)
                            : MCPInventory.standardEntry(name: name, object: object, file: file)
                    else { continue }
                    let shown = MCPDisplayedText.field(name)
                    guard hostEntry.governedServer == nil else {
                        report.skipped.append("\(shown) (\(file.host.rawValue)): already routed through rv")
                        continue
                    }
                    guard configuration.server(named: name) != nil else {
                        report.skipped.append("\(shown) (\(file.host.rawValue)): not in mcp.json; `rv mcp import` it first")
                        continue
                    }
                    let written = gatewayEntry(rvPath: rvPath, server: name, original: object, opencode: opencode)
                    servers[name] = written
                    records.append(MCPSetupRecord(
                        host: file.host.rawValue, configPath: path, keyPath: keyPath, name: name,
                        original: entry, written: written))
                    changed.append("\(shown) (\(file.host.rawValue), \(MCPDisplayedText.field(path)))")
                }
                guard changed.isEmpty == false else { continue }
                if pending[path] == nil {
                    // Replacing a link would drop it and copy its target's bytes here.
                    guard snapshot.state.isSymbolicLink == false else { return .failure(.symbolicLink(path)) }
                    guard (try? JSONValue.parse(data, maximumDepth: 128)) != nil else { return .failure(.hasComments(path)) }
                }
                guard let updated = replacing(keyPath, in: root, with: .object(servers)) else {
                    return .failure(.writeFailed(path))
                }
                roots[path] = updated
                report.changed += changed
                if var write = pending[path] {
                    write.records += records
                    write.changed += changed
                    write.data = Data(updated.prettyText.utf8)
                    pending[path] = write
                } else {
                    order.append(path)
                    pending[path] = MCPSetupPlan.Write(
                        path: file.path, data: Data(updated.prettyText.utf8), records: records, changed: changed)
                }
            }
        }
        return .success(MCPSetupPlan(prior: manifest, writes: order.compactMap { pending[$0] }, report: report))
    }

    static func planUndo(
        manifest records: [MCPSetupRecord],
        snapshots: [String: MCPFileState],
        host: MCPHost?,
        servers filter: Set<String>?
    ) -> Result<MCPUndoPlan, MCPSetupError> {
        var report = MCPSetupResult()
        let selected = records.indices.filter { index in
            (host == nil || records[index].host == host?.rawValue) && wanted(records[index].name, filter)
        }
        let paths = Set(selected.map { records[$0].configPath }).sorted()
        // Refuse up front so a later linked file cannot strand earlier restores outside the manifest.
        if let linked = paths.first(where: { snapshots[$0]?.isSymbolicLink == true }) {
            return .failure(.symbolicLink(linked))
        }
        var retired = Set<Int>()
        var writes: [MCPUndoPlan.Write] = []
        for path in paths {
            let mine = selected.filter { records[$0].configPath == path }
            guard case .data(let data)? = snapshots[path]?.contents, var root = try? JSONValue.parse(data, maximumDepth: 128) else {
                let shownPath = MCPDisplayedText.field(path)
                report.skipped += mine.map { "\(MCPDisplayedText.field(records[$0].name)): \(shownPath) is missing or unreadable" }
                retired.formUnion(mine)
                continue
            }
            var changedLines: [String] = []
            for index in mine.reversed() {
                let record = records[index]
                retired.insert(index)
                guard var servers = value(at: record.keyPath, in: root)?.objectValue,
                    servers[record.name] == record.written
                else {
                    report.skipped.append("\(MCPDisplayedText.field(record.name)) (\(record.host)): changed since setup; left as is")
                    continue
                }
                servers[record.name] = record.original
                guard let updated = replacing(record.keyPath, in: root, with: .object(servers)) else { continue }
                root = updated
                changedLines.append("\(MCPDisplayedText.field(record.name)) (\(record.host), \(MCPDisplayedText.field(path)))")
            }
            if changedLines.isEmpty == false {
                report.changed += changedLines
                writes.append(.init(path: URL(fileURLWithPath: path), data: Data(root.prettyText.utf8), changed: changedLines))
            }
        }
        return .success(MCPUndoPlan(records: records, retired: retired, writes: writes, report: report))
    }

    /// Writes one file; returns the backups it kept, or nil when it could not write.
    typealias HostWriter = (URL, Data) -> [String]?

    static func apply(
        _ plan: MCPSetupPlan, write: HostWriter, saveManifest: ([MCPSetupRecord]) -> Bool
    ) -> Result<MCPSetupResult, MCPSetupError> {
        guard plan.writes.isEmpty == false else { return .success(plan.report) }
        // Intent first: an extra record is harmless (undo compares the current
        // value to `written`), a missing one strands a rewrite.
        guard saveManifest(plan.manifest(written: plan.allPaths)) else { return .failure(.manifest("could not save")) }
        var applied = MCPSetupResult()
        var written = Set<String>()
        for item in plan.writes {
            guard let backups = write(item.path, item.data) else {
                _ = saveManifest(plan.manifest(written: written))
                let cause = MCPSetupError.writeFailed(item.path.path)
                return .failure(written.isEmpty ? cause : .partial(applied: applied, cause: cause))
            }
            written.insert(item.path.path)
            applied.changed += item.changed
            applied.backups += backups
        }
        var result = plan.report
        result.backups = applied.backups
        return .success(result)
    }

    static func apply(
        _ plan: MCPUndoPlan, write: HostWriter, saveManifest: ([MCPSetupRecord]) -> Bool
    ) -> Result<MCPSetupResult, MCPSetupError> {
        var applied = MCPSetupResult()
        var written = Set<String>()
        for item in plan.writes {
            guard let backups = write(item.path, item.data) else {
                _ = saveManifest(plan.manifest(written: written))
                let cause = MCPSetupError.writeFailed(item.path.path)
                return .failure(written.isEmpty ? cause : .partial(applied: applied, cause: cause))
            }
            written.insert(item.path.path)
            applied.changed += item.changed
            applied.backups += backups
        }
        guard saveManifest(plan.manifest(written: written)) else {
            let cause = MCPSetupError.manifest("could not save")
            return .failure(written.isEmpty ? cause : .partial(applied: applied, cause: cause))
        }
        var result = plan.report
        result.backups = applied.backups
        return .success(result)
    }
}
