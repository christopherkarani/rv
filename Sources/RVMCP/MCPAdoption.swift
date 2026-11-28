import Foundation
import RVIsolation

/// `rv mcp add`: which of the MCP servers the agent hosts already have rv
/// can take, and what it would change. Everything here is a pure function
/// of what was read: host entries (from `MCPInventory`, which only reads
/// files and never starts a server), mcp.json, secrets.json and host file
/// bytes. Writing is the CLI's job, through the existing import (one owner
/// confirmation, keys by name) and `MCPHostSetup` (backups, manifest, undo).
public enum MCPAdoption {
    /// The survey of `entries` for `hosts` (nil: every host) and `servers`
    /// (nil: every name). `rvExecutable` is the rv that counts as rv's
    /// gateway when an entry already launches one.
    public static func survey(
        entries: [MCPHostEntry],
        configuration: MCPConfiguration,
        secrets: SecretsConfiguration,
        rvExecutable: String,
        hosts: Set<MCPHost>? = nil,
        servers: Set<String>? = nil
    ) -> MCPAdoptionSurvey {
        let selected = entries.filter { entry in
            (hosts?.contains(entry.host) ?? true) && (servers?.contains(entry.name) ?? true)
        }
        var verdicts: [MCPAdoptionVerdict?] = selected.map { entry in
            firstVerdict(entry, configuration: configuration, rvExecutable: rvExecutable)
        }
        // Each still-open entry is either rv's reviewed server (`bypass`) or
        // new to rv. Setup routes a host's entries by name, so every entry a
        // host has under one name must be the same server; a new server must
        // also be the same in every host that names it.
        let open = selected.indices.filter { verdicts[$0] == nil }
        for index in open {
            let entry = selected[index]
            let sameHost = selected.indices.filter { other in
                selected[other].host == entry.host && selected[other].name == entry.name && isWritable(selected[other])
                    && MCPInventoryRow.status(selected[other], configuration: configuration, rvExecutable: rvExecutable)
                        != .governed
            }
            if sameHost.contains(where: { signature(selected[$0]) != signature(entry) }) {
                let host = entry.host.displayName
                verdicts[index] = .leave("\(host) has two different servers named \(entry.name); rename one, then rv mcp add")
            }
        }
        let fresh = open.filter { verdicts[$0] == nil && configuration.server(named: selected[$0].name) == nil }
        for index in fresh {
            let entry = selected[index]
            let differing = fresh.filter { selected[$0].name == entry.name && signature(selected[$0]) != signature(entry) }
            if differing.isEmpty == false {
                let names = Set(fresh.filter { selected[$0].name == entry.name }.map { selected[$0].host })
                let shown = MCPHost.allCases.filter(names.contains).map(\.displayName).joined(separator: " and ")
                verdicts[index] = .leave("\(shown) run different servers named \(entry.name); rename one, then rv mcp add")
            }
        }
        var seen = Set<String>()
        let canonical = fresh.filter { verdicts[$0] == nil }.map { selected[$0] }.filter { seen.insert($0.name).inserted }
        let imports = MCPImport.plan(entries: canonical, configuration: configuration, secrets: secrets)
        let skipped = Dictionary(imports.skipped.map { ($0.name, $0.reason) }, uniquingKeysWith: { first, _ in first })
        let definitions = Dictionary(imports.servers.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        var rows: [MCPAdoptionRow] = []
        var routes: [MCPHost: Set<String>] = [:]
        for (index, entry) in selected.enumerated() {
            let verdict: MCPAdoptionVerdict
            var keys: [String] = []
            if let decided = verdicts[index] {
                verdict = decided
            } else if configuration.server(named: entry.name) != nil {
                verdict = .adopt(.reviewed)
            } else if let reason = skipped[entry.name] {
                verdict = .leave(reason)
            } else if let definition = definitions[entry.name] {
                keys = secretNames(definition)
                verdict = .adopt(definition.remote == nil ? .local(sandbox: definition.sandbox) : .remote)
            } else {
                verdict = .leave("rv could not read this server")
            }
            if case .adopt = verdict { routes[entry.host, default: []].insert(entry.name) }
            rows.append(MCPAdoptionRow(
                host: entry.host, scope: entry.scope, configPath: entry.configPath, name: entry.name,
                shown: MCPInventoryRow.row(entry, configuration: configuration, rvExecutable: rvExecutable).display,
                verdict: verdict, keys: keys))
        }
        return MCPAdoptionSurvey(rows: rows, imports: imports, routes: routes)
    }

    /// The verdict an entry gets on its own, or nil when it depends on the
    /// other entries (rv may take it).
    static func firstVerdict(
        _ entry: MCPHostEntry, configuration: MCPConfiguration, rvExecutable: String
    ) -> MCPAdoptionVerdict? {
        let status = MCPInventoryRow.status(entry, configuration: configuration, rvExecutable: rvExecutable)
        if status == .governed { return .governed }
        // A gateway launch of another rv binary: setup will not rewrite it.
        if entry.governedServer != nil, entry.launches(rvExecutable) == false {
            return .leave("already points at an rv gateway at another path")
        }
        switch entry.scope {
        case .managed: return .leave("your organization's managed config sets it; rv can't rewrite that file")
        case .plugin(let id): return .leave("plugin \(MCPDisplayedText.field(id)) brings it; rv can't rewrite a plugin")
        case .user, .project: break
        }
        switch status {
        case .governed, .bypass, .unreviewed, .off: return nil
        case .disabled: return .leave("turned off in \(entry.host.displayName); turn it on, then rv mcp add")
        case .blocked: return .leave("mcp.json blocks it; remove it from \(entry.host.displayName)")
        case .direct: return .leave("mcp.json lets it run outside rv (\"direct\")")
        case .dangling: return .leave("points at rv, but mcp.json has no \(entry.name)")
        }
    }

    static func isWritable(_ entry: MCPHostEntry) -> Bool {
        switch entry.scope {
        case .user, .project: true
        case .managed, .plugin: false
        }
    }

    /// What makes two host entries the same server.
    struct Signature: Equatable {
        var transport: MCPTransport
        var environment: [String: String]
        var headers: [String: String]
        var remoteTransport: MCPRemoteTransport?
        var isDisabled: Bool
    }

    static func signature(_ entry: MCPHostEntry) -> Signature {
        Signature(
            transport: entry.transport, environment: entry.environment, headers: entry.headers,
            remoteTransport: entry.remoteTransport, isDisabled: entry.isDisabled)
    }

    /// The rv key names a definition reads, never their values.
    static func secretNames(_ definition: MCPServerDefinition) -> [String] {
        var names = Set(definition.secrets.values)
        names.formUnion(definition.args.flatMap { MCPSecretReference.names(in: $0) ?? [] })
        if let remote = definition.remote { names.formUnion(remote.secretNames) }
        return names.sorted()
    }
}

/// What rv will do with one server a host has configured.
public enum MCPAdoptionVerdict: Sendable, Equatable {
    /// The host already runs it through rv.
    case governed
    /// rv takes it and points the host at its gateway.
    case adopt(MCPAdoptionTaking)
    /// rv leaves it as it is, for this one-line reason.
    case leave(String)
}

/// How rv takes a server.
public enum MCPAdoptionTaking: Sendable, Equatable {
    /// A local server rv reviews and adds to mcp.json, in this sandbox.
    case local(sandbox: MCPSandboxPolicy?)
    /// A remote server rv reviews and adds to mcp.json.
    case remote
    /// mcp.json already has a server by this name; the host is pointed at it.
    case reviewed
}

public struct MCPAdoptionRow: Sendable, Equatable {
    public var host: MCPHost
    public var scope: MCPEntryScope
    public var configPath: String
    public var name: String
    /// The command line or URL, credentials masked (`MCPInventoryRow.display`).
    public var shown: String
    public var verdict: MCPAdoptionVerdict
    /// rv key names this server's credentials move to.
    public var keys: [String]
}

public struct MCPAdoptionSurvey: Sendable {
    public var rows: [MCPAdoptionRow]
    /// The servers (and their keys) rv adds to mcp.json.
    public var imports: MCPImportPlan
    /// Per host, the server names whose entries rv points at its gateway.
    public var routes: [MCPHost: Set<String>]

    /// Every server the hosts have.
    public var found: Int { rows.count }
    /// Servers that do not run through rv today.
    public var notGoverned: Int { rows.filter { $0.verdict != .governed }.count }
    /// Servers rv takes.
    public var adopting: Int {
        rows.filter { if case .adopt = $0.verdict { true } else { false } }.count
    }
    /// The hosts that have servers, in `MCPHost` order.
    public var hosts: [MCPHost] {
        MCPHost.allCases.filter { host in rows.contains { $0.host == host } }
    }
    /// Distinct rv key names the import moves credentials into.
    public var keys: [String] { imports.secrets.map(\.definition.name) }
}
