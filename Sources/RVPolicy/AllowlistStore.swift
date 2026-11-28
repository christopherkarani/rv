import Foundation
import RVDomain
import RVFileStore
import RVHistory

public enum AllowlistStoreError: Error, Sendable, Equatable {
    case lockFailed
}

public struct AllowlistStore: Sendable {
    public var baseDirectory: URL

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    public var fileURL: URL {
        RVPolicyPaths.allowlistFile(inConfigDir: baseDirectory)
    }

    /// Fail-open load for evaluate. Symlink into `workspacePath` → empty. Invalid TOML → empty.
    /// The denylist fails closed instead: see `DenylistStore.loadSnapshot`.
    public func loadUserSnapshot(workspacePath: String?, now: Date) -> AllowlistSnapshot {
        let blocked = DenylistStore(baseDirectory: baseDirectory).loadSnapshot()
        switch loadForValidate(workspacePath: workspacePath) {
        case .missing, .symlinkIntoWorkspace, .invalid:
            return AllowlistSnapshot(entries: [], blocked: blocked)
        case .ok(let entries):
            return AllowlistSnapshot(
                entries: entries.filter { $0.isActive(at: now) },
                blocked: blocked
            )
        }
    }

    public enum LoadResult: Equatable, Sendable {
        case missing
        case symlinkIntoWorkspace
        case invalid(AllowlistParseError)
        case ok([AllowlistEntry])
    }

    public func loadForValidate(workspacePath: String?) -> LoadResult {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .missing
        }
        if isSymlinkIntoWorkspace(url: url, workspacePath: workspacePath) {
            return .symlinkIntoWorkspace
        }
        guard let data = readRegularFile(url),
              let text = String(data: data, encoding: .utf8)
        else {
            return .invalid(.invalidTOML)
        }
        do {
            let entries = try AllowlistTOML.parse(text)
            return .ok(entries)
        } catch let error as AllowlistParseError {
            return .invalid(error)
        } catch {
            return .invalid(.invalidTOML)
        }
    }

    public func add(
        _ entry: AllowlistEntry,
        tty: TTYCapability
    ) throws {
        guard allowsInteractiveAllowOnce(tty) else { throw AllowOnceError.ttyRequired }
        try mutate { entries in
            entries.append(entry)
        }
    }

    /// Dashboard Always-allow. No TTY. The preview confirm is the human.
    package func pin(_ entry: AllowlistEntry) throws {
        try mutate { entries in
            if entries.contains(where: { $0.selector == entry.selector }) {
                return
            }
            entries.append(entry)
        }
    }

    /// The menu bar's Always allow (K2): leaves `entry`'s exact command
    /// allowed from now on, with `entry`'s bindings, and returns the entries
    /// as written. An entry with the same selector and bindings that never
    /// expires is kept as it is. One with the same selector that expires
    /// (or already has) or is legacy (unbound) is replaced, so an old row
    /// cannot stand in for the new answer. A permanent entry bound to
    /// another payload or wrapper is left beside it.
    package func pinExact(_ entry: AllowlistEntry) throws -> [AllowlistEntry] {
        var written: [AllowlistEntry] = []
        try mutate { entries in
            let current = entries.contains {
                $0.selector == entry.selector && $0.expiresAt == nil
                    && $0.maskedPayloadDigest == entry.maskedPayloadDigest
                    && $0.invocationDigest == entry.invocationDigest
            }
            if current == false {
                entries.removeAll {
                    $0.selector == entry.selector
                        && ($0.expiresAt != nil || ($0.maskedPayloadDigest == nil && $0.invocationDigest == nil))
                }
                entries.append(entry)
            }
            written = entries
        }
        return written
    }

    public func remove(
        matching ruleOrCommand: String,
        tty: TTYCapability,
        exactCommandAliases: [String] = []
    ) throws -> Int {
        guard allowsInteractiveAllowOnce(tty) else { throw AllowOnceError.ttyRequired }
        let needle = ruleOrCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let aliases = Set(
            ([needle] + exactCommandAliases)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.isEmpty == false }
        )
        var removed = 0
        try mutate { entries in
            let before = entries.count
            entries.removeAll { entry in
                switch entry.selector {
                case .rule(let ruleID):
                    return ruleID.rawValue == needle
                        || ruleID.slashDisplay == needle
                        || parseAllowlistRuleID(needle) == ruleID
                case .exactCommand(let command):
                    return aliases.contains(command.rawValue)
                }
            }
            removed = before - entries.count
        }
        return removed
    }

    /// Callers enforce the TTY. Through `OwnerConfigFile` under
    /// `.allowlist.lock`: an existing `allowlist.toml` that cannot be read
    /// or parsed throws `OwnerConfigWriteError.unreadable` and nothing is
    /// written. Records `config.changed` (`allowlist`) write-ahead.
    private func mutate(_ body: (inout [AllowlistEntry]) throws -> Void) throws {
        let file = OwnerConfigFile<[AllowlistEntry]>(
            url: fileURL, lockURL: RVPolicyPaths.allowlistLockFile(inConfigDir: baseDirectory), empty: [],
            parse: { data in String(data: data, encoding: .utf8).flatMap { try? AllowlistTOML.parse($0) } },
            render: { Data(AllowlistTOML.render($0).utf8) })
        do {
            try file.update(audit: Self.changeEvent, mutate: body)
        } catch ExclusiveFileLock.LockError.lockFailed {
            throw AllowlistStoreError.lockFailed
        }
    }

    /// `config.changed` (`allowlist`): entry counts before and after and the
    /// selectors added or removed. Rule ids by name; an exact command only as
    /// `exact-command`, since its text can hold anything. Nil when no entry
    /// changed. Only removing entries tightens; any added or edited entry
    /// is an exception and loosens.
    static func changeEvent(from prior: [AllowlistEntry], to new: [AllowlistEntry]) -> AuditEvent? {
        guard prior != new else { return nil }
        func label(_ entry: AllowlistEntry) -> String {
            switch entry.selector {
            case .rule(let rule): rule.rawValue
            case .exactCommand: "exact-command"
            }
        }
        let added = new.filter { entry in prior.contains(entry) == false }.map(label)
        let removed = prior.filter { entry in new.contains(entry) == false }.map(label)
        var detail: [String: String] = [:]
        if added.isEmpty == false { detail["added"] = ConfigChangeAudit.list(added) }
        if removed.isEmpty == false { detail["removed"] = ConfigChangeAudit.list(removed) }
        return ConfigChangeAudit.setting(
            "allowlist", from: "\(prior.count) entries", to: "\(new.count) entries",
            direction: added.isEmpty ? .tightening : .loosening, detail: detail)
    }

    private func isSymlinkIntoWorkspace(url: URL, workspacePath: String?) -> Bool {
        guard let workspacePath, workspacePath.isEmpty == false else { return false }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return false
        }
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        let parentValues = try? url.deletingLastPathComponent()
            .resourceValues(forKeys: [.isSymbolicLinkKey])
        let isLink = (values?.isSymbolicLink == true) || (parentValues?.isSymbolicLink == true)
        guard isLink else { return false }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        let workspace = URL(fileURLWithPath: workspacePath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        if resolved == workspace { return true }
        let prefix = workspace.hasSuffix("/") ? workspace : workspace + "/"
        return resolved.hasPrefix(prefix)
    }
}
