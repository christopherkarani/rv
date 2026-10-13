import ArgumentParser
import Foundation
import RVDomain
import RVHistory
import RVIsolation
import RVMCP
import RVPolicy

/// Seams for `rv mcp`: where rv and the hosts keep configuration.
struct MCPEnvironment: Sendable {
    var configDirectory: URL
    var home: URL
    var processEnvironment: [String: String]
    var keychain: SecretKeychainWriter
    var managed: ManagedPolicyState = .none
    var approvalKeys: MCPApprovalKeyStore = .unavailable
    var presence = UserPresence { _, _ in .refused("no user presence available") }
    var oauthTokens: MCPOAuthTokenStore = .none

    static func live(home: HomeDirectory) -> MCPEnvironment {
        let configDirectory = RVPolicyPaths.configDirectory(home: home)
        return MCPEnvironment(
            configDirectory: configDirectory,
            home: URL(fileURLWithPath: home.rawValue, isDirectory: true),
            processEnvironment: ProcessInfo.processInfo.environment,
            keychain: .live,
            managed: ManagedRun.installed(home: home),
            approvalKeys: .live(configDirectory: configDirectory, home: home.rawValue),
            presence: .live,
            oauthTokens: .live(configDirectory: configDirectory, home: home.rawValue)
        )
    }

    var approvals: MCPApprovalStore {
        MCPApprovalStore(configDirectory: configDirectory, keys: approvalKeys)
    }

    var integrity: MCPIntegrityStatus {
        MCPIntegrity.status(configDirectory: configDirectory, keys: approvalKeys)
    }
}

enum MCPRun {
    struct Row: Encodable, Equatable {
        var host: String
        var scope: String
        var configPath: String
        var name: String
        var status: String
        var command: String
        var environmentNames: [String]
        var headerNames: [String]
        var plaintextCredentials: [String]
        var governedServer: String?
    }

    struct Problem: Encodable, Equatable {
        var path: String
        var message: String
    }

    struct Report: Encodable, Equatable {
        var servers: Int
        var direct: Int
        var blocked: Int
        /// `none`, `trusted`, or `untrusted` (mcp.json changed outside rv).
        var integrity: String
        var integrityProblem: String?
        var rows: [Row]
        var problems: [Problem]

        var failing: [Row] {
            rows.filter { MCPEntryStatus(rawValue: $0.status)?.isAcceptable == false }
        }

        var passes: Bool { failing.isEmpty && problems.isEmpty && integrityProblem == nil }
    }

    /// mcp.json with organization policy applied. An invalid managed policy fails closed.
    static func configuration(_ environment: MCPEnvironment) -> Result<MCPConfiguration, CommandFailure> {
        if let reason = environment.managed.invalidReason {
            return .failure(CommandFailure("organization policy is invalid, so MCP is disabled: \(reason)"))
        }
        return MCPConfiguration.load(configDirectory: environment.configDirectory)
            .map { configuration in
                var configuration = configuration
                configuration.managed = environment.managed.policy
                configuration.untrusted = environment.integrity.isTrusted == false
                return configuration
            }
            .mapError { CommandFailure($0.message) }
    }

    /// rv signs mcp.json on every write; refusing over an outside edit keeps
    /// rv from laundering it into a trusted file.
    static func signerForWrite(_ environment: MCPEnvironment) -> Result<MCPSigner, CommandFailure> {
        if let problem = environment.integrity.problem { return .failure(CommandFailure(problem)) }
        guard let signer = environment.approvalKeys.loadOrCreate() else {
            return .failure("could not create rv's approvals key (\(MCPApprovalKeyStore.keychainService))")
        }
        return .success(signer)
    }

    static func report(
        _ environment: MCPEnvironment, project: URL?, configuration: MCPConfiguration, rvExecutable: String
    ) -> Report {
        let inventory = MCPInventory.discover(
            home: environment.home, project: project, environment: environment.processEnvironment)
        let rows = MCPInventoryRow.rows(inventory, configuration: configuration, rvExecutable: rvExecutable).map { row in
            Row(
                host: row.entry.host.rawValue,
                scope: row.entry.scope.label,
                configPath: row.entry.configPath,
                name: row.entry.name,
                status: row.status.rawValue,
                command: row.display,
                environmentNames: row.environmentNames,
                headerNames: row.headerNames,
                plaintextCredentials: row.plaintextCredentials,
                governedServer: row.entry.governedServer)
        }
        let integrity = environment.integrity
        return Report(
            servers: configuration.servers.count,
            direct: configuration.direct.count,
            blocked: configuration.blocked.count,
            integrity: integrity.label,
            integrityProblem: integrity.problem,
            rows: rows,
            problems: inventory.problems.map { Problem(path: $0.path, message: $0.message) })
    }

    static func listText(_ report: Report, home: URL) -> String {
        var lines = [
            "rv mcp.json: \(report.servers) gateway servers, \(report.direct) direct, \(report.blocked) blocked"
        ]
        if report.rows.isEmpty { lines.append("no MCP servers found in any host configuration") }
        var currentFile: String?
        let width = min(28, report.rows.map(\.name.count).max() ?? 0)
        for row in report.rows {
            let file = "\(row.host) (\(row.scope == "user" ? "user" : "project"), \(abbreviate(row.configPath, home: home)))"
            if file != currentFile {
                lines.append("")
                lines.append(file)
                currentFile = file
            }
            let name = row.name.padding(toLength: max(width, row.name.count), withPad: " ", startingAt: 0)
            let status = row.status.padding(toLength: 10, withPad: " ", startingAt: 0)
            lines.append("  \(name)  \(status)  \(row.command)")
            var details: [String] = []
            if row.environmentNames.isEmpty == false { details.append("env " + capped(row.environmentNames)) }
            if row.headerNames.isEmpty == false { details.append("headers " + row.headerNames.joined(separator: ", ")) }
            if row.plaintextCredentials.isEmpty == false {
                details.append("plaintext credential: " + row.plaintextCredentials.joined(separator: ", "))
            }
            if details.isEmpty == false {
                lines.append("  " + String(repeating: " ", count: max(width, row.name.count)) + "  " + details.joined(separator: " · "))
            }
        }
        lines.append("")
        lines.append(summary(report))
        lines += problemLines(report, home: home)
        if let problem = report.integrityProblem { lines.append("warning: " + problem) }
        return lines.joined(separator: "\n") + "\n"
    }

    static func checkText(_ report: Report, home: URL) -> String {
        var lines: [String] = []
        if report.passes {
            lines.append("ok: every MCP server is governed by rv, allowed direct, or disabled (\(report.rows.count) checked)")
        } else {
            if let problem = report.integrityProblem { lines.append("untrusted  " + problem) }
            for row in report.failing {
                let status = MCPEntryStatus(rawValue: row.status)
                lines.append("\(row.status)  \(row.name)  \(row.host) \(abbreviate(row.configPath, home: home))")
                if let status { lines.append("  \(status.explanation)") }
            }
            lines += problemLines(report, home: home)
            lines.append(summary(report))
        }
        let leaks = report.rows.filter { $0.plaintextCredentials.isEmpty == false }
        if leaks.isEmpty == false {
            lines.append(
                "warning: \(leaks.count) host entr\(leaks.count == 1 ? "y holds" : "ies hold") plaintext credentials ("
                    + leaks.map(\.name).joined(separator: ", ") + "); `rv mcp import` moves them into rv secrets")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func capped(_ names: [String], limit: Int = 4) -> String {
        names.count <= limit
            ? names.joined(separator: ", ")
            : names.prefix(limit).joined(separator: ", ") + " +\(names.count - limit) more"
    }

    static func summary(_ report: Report) -> String {
        let order: [MCPEntryStatus] = [.governed, .direct, .bypass, .unreviewed, .blocked, .dangling, .disabled]
        let counts = order.compactMap { status -> String? in
            let count = report.rows.filter { $0.status == status.rawValue }.count
            return count == 0 ? nil : "\(count) \(status.rawValue)"
        }
        let files = Set(report.rows.map(\.configPath)).count
        return "\(report.rows.count) host entries in \(files) files" + (counts.isEmpty ? "" : ": " + counts.joined(separator: ", "))
    }

    static func problemLines(_ report: Report, home: URL) -> [String] {
        report.problems.map { "unreadable: \(abbreviate($0.path, home: home)): \($0.message)" }
    }

    static func abbreviate(_ path: String, home: URL) -> String {
        let prefix = home.standardizedFileURL.path
        guard path.hasPrefix(prefix + "/") else { return path }
        return "~" + path.dropFirst(prefix.count)
    }

    struct PendingRow: Encodable, Equatable {
        var id: String
        var server: String
        var tool: String
        var argumentKeys: [String]
        var requestedAt: Date
    }

    static func pendingRows(_ store: MCPApprovalStore) -> [PendingRow] {
        store.pending().map {
            PendingRow(id: $0.id, server: $0.server, tool: $0.tool, argumentKeys: $0.argumentKeys, requestedAt: $0.requestedAt)
        }
    }

    static func pendingText(_ rows: [PendingRow]) -> String {
        guard rows.isEmpty == false else { return "no MCP tool calls are waiting for approval\n" }
        let formatter = ISO8601DateFormatter()
        let lines = rows.map { row in
            let keys = row.argumentKeys.isEmpty ? "no arguments" : "arguments " + row.argumentKeys.joined(separator: ", ")
            return "\(row.id)  \(row.server) \(row.tool)  \(keys)  \(formatter.string(from: row.requestedAt))"
        }
        return (lines + [
            "approve in your own terminal with `rv mcp approve <id>` (once) or `--always`; refuse with `rv mcp deny <id>`",
            "approving needs you present: Touch ID or your password on macOS, otherwise the code `rv mcp serve` printed",
        ])
            .joined(separator: "\n") + "\n"
    }

    /// Grants one pending call; `always` also adds the tool to the server's allow list.
    /// The person approving must prove presence first, so an agent's shell cannot approve.
    static func approve(id: String, always: Bool, environment: MCPEnvironment) async -> Result<String, CommandFailure> {
        let store = environment.approvals
        guard let request = store.pending().first(where: { $0.id == id }) else {
            return .failure("no pending MCP approval has id \(id) (see `rv mcp pending`)")
        }
        var allowed: (MCPConfiguration, MCPSigner)?
        if always {
            switch allowListed(request, environment: environment) {
            case .failure(let failure): return .failure(failure)
            case .success(let result): allowed = result
            }
        }
        let reason = "rv: approve \(request.server) tool \(request.tool) \(always ? "always" : "once")"
        let outcome = await environment.presence.confirm(reason, .printedCode { store.verifyCode(id: id, typed: $0) })
        guard case .confirmed(let method) = outcome else {
            let refusal = if case .refused(let why) = outcome { why } else { "not confirmed" }
            audit(request, decision: .denied, reason: "user presence not confirmed: \(refusal)", method: nil,
                  always: always, configDirectory: environment.configDirectory)
            return .failure(CommandFailure("not approved: \(refusal)"))
        }
        if case let (configuration, signer)? = allowed,
            case .failure(let error) = configuration.write(configDirectory: environment.configDirectory, signer: signer)
        {
            return .failure(CommandFailure(error.message))
        }
        guard store.grant(id: id) != nil else { return .failure("could not record the approval") }
        audit(request, decision: .allowed, reason: nil, method: method, always: always,
              configDirectory: environment.configDirectory)
        return .success(always
            ? "approved \(request.server) \(request.tool) always (added to its allow list in mcp.json)\n"
            : "approved \(request.server) \(request.tool) once; the agent can retry the same call\n")
    }

    /// mcp.json with the request's tool moved to the allow list, and the signer to write it with.
    static func allowListed(
        _ request: MCPApprovalRequest, environment: MCPEnvironment
    ) -> Result<(MCPConfiguration, MCPSigner), CommandFailure> {
        let signer: MCPSigner
        switch signerForWrite(environment) {
        case .failure(let failure): return .failure(failure)
        case .success(let loaded): signer = loaded
        }
        var configuration: MCPConfiguration
        switch self.configuration(environment) {
        case .failure(let failure): return .failure(failure)
        case .success(let loaded): configuration = loaded
        }
        guard let index = configuration.servers.firstIndex(where: { $0.name == request.server }) else {
            return .failure("mcp.json no longer defines \(request.server)")
        }
        if configuration.hasArgumentRules(server: configuration.servers[index], tool: request.tool) {
            return .failure("\(request.tool) has argument rules, so allowing it always would not cover every call; approve it once or edit the rule")
        }
        var tools = configuration.servers[index].tools
        tools.ask.removeAll { $0 == request.tool }
        if tools.allow.contains(request.tool) == false { tools.allow.append(request.tool) }
        configuration.servers[index].tools = tools
        if let organization = configuration.organizationDecision(server: request.server, tool: request.tool),
            organization != .allow
        {
            return .failure("organization policy says \(organization.rawValue) for \(request.server)/\(request.tool); approve it once instead")
        }
        if configuration.decision(server: configuration.servers[index], tool: request.tool) != .allow {
            return .failure("\(request.tool) still matches an ask or deny rule in mcp.json; edit that rule instead")
        }
        return .success((configuration, signer))
    }

    static func audit(
        _ request: MCPApprovalRequest, decision: AuditDecision, reason: String?, method: String?, always: Bool,
        configDirectory: URL
    ) {
        var detail = ["approval": request.id, "always": always ? "true" : "false"]
        if let method { detail["method"] = method }
        _ = AuditLog.append(
            AuditEvent(
                time: Date(), kind: .mcpApproval, decision: decision, subject: "\(request.server)/\(request.tool)",
                reason: reason, source: "rv mcp approve", detail: detail),
            configDirectory: configDirectory)
    }

    /// Signs mcp.json as it is now, after showing what it allows and confirming presence.
    static func trust(
        environment: MCPEnvironment, show: @Sendable (String) -> Void
    ) async -> Result<String, CommandFailure> {
        let url = MCPConfiguration.fileURL(configDirectory: environment.configDirectory)
        let data: Data
        switch OwnerOnlyFile.read(url, maximumBytes: MCPConfiguration.maximumBytes) {
        case .success(nil): return .failure("there is no mcp.json to trust")
        case .success(let bytes?): data = bytes
        case .failure: return .failure("mcp.json is unreadable or unsafe")
        }
        let configuration: MCPConfiguration
        switch MCPConfiguration.decode(data) {
        case .failure(let error): return .failure(CommandFailure(error.message))
        case .success(let decoded): configuration = decoded
        }
        if environment.integrity == .trusted {
            return .success("mcp.json already matches rv's signature; nothing to trust\n")
        }
        show(trustReview(configuration) + "\n")
        let outcome = await environment.presence.confirm("rv: trust mcp.json as shown", .echoCode)
        guard case .confirmed(let method) = outcome else {
            let refusal = if case .refused(let why) = outcome { why } else { "not confirmed" }
            return .failure(CommandFailure("not trusted: \(refusal)"))
        }
        guard let signer = environment.approvalKeys.loadOrCreate() else {
            return .failure("could not create rv's approvals key (\(MCPApprovalKeyStore.keychainService))")
        }
        guard MCPIntegrity.sign(data, configDirectory: environment.configDirectory, signer: signer) else {
            return .failure("could not write \(MCPIntegrity.fileName)")
        }
        guard environment.integrity == .trusted else {
            return .failure("mcp.json changed while you reviewed it; run `rv mcp trust` again")
        }
        _ = AuditLog.append(
            AuditEvent(
                time: Date(), kind: .mcpApproval, decision: .allowed, subject: MCPConfiguration.fileName,
                reason: "mcp.json trusted", source: "rv mcp trust",
                detail: ["method": method, "sha256": RVDigest.sha256Hex([UInt8](data))]),
            configDirectory: environment.configDirectory)
        return .success("trusted mcp.json; rv signs it again on every change it makes\n")
    }

    static func trustReview(_ configuration: MCPConfiguration) -> String {
        var lines = ["mcp.json: default \(configuration.defaultDecision.rawValue) for tools without a rule"]
        if configuration.toolMode == .search {
            lines.append("  tool mode search: clients see only rv_search_tools and rv_call_tool")
        }
        for server in configuration.servers {
            var rules: [String] = []
            if let remote = server.remote {
                let transport = remote.transport == .sse ? "legacy SSE" : "streamable HTTP"
                lines.append("  \(server.name): \(remote.url.absoluteString) (remote, \(transport))")
                if remote.headers.isEmpty == false {
                    rules.append("headers " + remote.headers.keys.sorted().map { name in
                        let secrets = MCPSecretReference.names(in: remote.headers[name] ?? "") ?? []
                        return secrets.isEmpty ? "\(name) (literal)" : "\(name) (secret \(secrets.joined(separator: ", ")))"
                    }.joined(separator: ", "))
                }
            } else {
                lines.append("  \(server.name): \(([server.command] + server.args).joined(separator: " "))")
            }
            let tools = server.tools
            if tools.allow.isEmpty == false { rules.append("allow " + capped(tools.allow)) }
            if tools.ask.isEmpty == false { rules.append("ask " + capped(tools.ask)) }
            if tools.deny.isEmpty == false { rules.append("deny " + capped(tools.deny)) }
            for ruled in tools.rules { rules.append("\(ruled.decision.rawValue) \(ruled.rule.summary)") }
            if let fallback = tools.defaultDecision { rules.append("other tools \(fallback.rawValue)") }
            if server.sandbox == nil, server.remote == nil { rules.append("no sandbox") }
            if rules.isEmpty == false { lines.append("    " + rules.joined(separator: " · ")) }
        }
        if configuration.direct.isEmpty == false { lines.append("  direct: " + configuration.direct.joined(separator: ", ")) }
        if configuration.blocked.isEmpty == false { lines.append("  blocked: " + configuration.blocked.joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }

    static func connect(
        server name: String, clientID: String?, scope: String?, forget: Bool, resolver: SecretResolver, flow: MCPOAuthFlow,
        environment: MCPEnvironment
    ) -> Result<String, CommandFailure> {
        let configuration: MCPConfiguration
        switch self.configuration(environment) {
        case .failure(let failure): return .failure(failure)
        case .success(let loaded): configuration = loaded
        }
        guard let definition = configuration.server(named: name) else {
            return .failure(CommandFailure("mcp.json has no server named \(name)"))
        }
        guard let remote = definition.remote else {
            return .failure(CommandFailure("\(name) runs a local command; only remote (url) servers sign in with OAuth"))
        }
        func audit(_ reason: String, _ detail: [String: String]) {
            _ = AuditLog.append(
                AuditEvent(
                    time: Date(), kind: .mcpApproval, decision: .allowed, subject: name, reason: reason, source: "rv mcp connect",
                    detail: detail),
                configDirectory: environment.configDirectory)
        }
        if forget {
            guard environment.oauthTokens.remove(name) else {
                return .failure(CommandFailure("could not delete the stored OAuth tokens for \(name)"))
            }
            audit("OAuth tokens deleted", [:])
            return .success("deleted the OAuth tokens rv stored for \(name)\n")
        }
        if let problem = environment.integrity.problem { return .failure(CommandFailure(problem)) }
        guard configuration.isBlocked(name) == false else {
            return .failure(CommandFailure("\(name) is blocked by mcp.json or organization policy"))
        }
        guard remote.headers.keys.contains(where: { $0.lowercased() == "authorization" }) == false else {
            return .failure(CommandFailure("\(name) already sends an Authorization header from mcp.json; remove it to sign in with OAuth"))
        }
        let secrets: SecretsConfiguration
        switch SecretsConfiguration.load(configDirectory: environment.configDirectory) {
        case .failure(let error): return .failure(CommandFailure(error.message))
        case .success(let loaded): secrets = loaded
        }
        let launch: MCPRemoteLaunch
        switch MCPLaunchPlanner.plan(
            servers: [name], configuration: configuration, secrets: secrets, resolver: resolver, baseEnvironment: [:])
        {
        case .failure(let error): return .failure(CommandFailure(error.message))
        case .success(let planned):
            guard let found = planned.first?.1.remote else { return .failure(CommandFailure("\(name) is not a remote server")) }
            launch = found
        }
        let tokens: MCPOAuthTokens
        switch flow.connect(server: name, launch: launch, clientID: clientID, scope: scope) {
        case .failure(let error): return .failure(CommandFailure("\(name): \(error.message)"))
        case .success(let issued): tokens = issued
        }
        guard environment.oauthTokens.save(name, tokens) else {
            return .failure(CommandFailure("could not store the OAuth tokens for \(name) (\(oauthStoreLabel(name, environment)))"))
        }
        audit("OAuth connected", ["resource": tokens.resource, "scope": tokens.scope ?? "", "client": tokens.clientID])
        var lines = ["connected \(name); tokens stored in \(oauthStoreLabel(name, environment))"]
        if let granted = tokens.scope { lines.append("scope: \(granted)") }
        lines.append("`rv mcp serve` sends the token and refreshes it; `rv mcp connect \(name) --forget` deletes it")
        return .success(lines.joined(separator: "\n") + "\n")
    }

    static func oauthStoreLabel(_ server: String, _ environment: MCPEnvironment) -> String {
        #if os(macOS)
        "the Keychain (service \(MCPOAuthTokenStore.keychainService), account \(server))"
        #else
        environment.configDirectory.appendingPathComponent("\(MCPOAuthTokenStore.directoryName)/\(server).json").path + " (0600)"
        #endif
    }

    static func auditRecord(_ record: MCPCallRecord, configDirectory: URL) {
        _ = AuditLog.append(record.auditEvent(), configDirectory: configDirectory)
    }

    static func importServers(
        host: MCPHost, names: [String], project: URL?, allowTools: Bool, dryRun: Bool, environment: MCPEnvironment
    ) -> Result<String, CommandFailure> {
        let configuration: MCPConfiguration
        switch self.configuration(environment) {
        case .failure(let failure): return .failure(failure)
        case .success(let loaded): configuration = loaded
        }
        let secrets: SecretsConfiguration
        switch SecretsConfiguration.load(configDirectory: environment.configDirectory) {
        case .failure(let error): return .failure(CommandFailure(error.message))
        case .success(let loaded): secrets = loaded
        }
        let inventory = MCPInventory.discover(home: environment.home, project: project, environment: environment.processEnvironment)
        var seen = Set<String>()
        let entries = inventory.entries.filter { entry in
            entry.host == host && (names.isEmpty || names.contains(entry.name)) && seen.insert(entry.name).inserted
        }
        let missing = names.filter { name in entries.contains { $0.name == name } == false }
        guard missing.isEmpty else {
            return .failure(CommandFailure("\(host.rawValue) has no MCP server named \(missing.joined(separator: ", "))"))
        }
        let plan = MCPImport.plan(entries: entries, configuration: configuration, secrets: secrets, allowTools: allowTools)
        var lines: [String] = []
        for server in plan.servers {
            var detail = "import \(server.name): \(server.command)"
            var names = Set(server.secrets.values).union(server.args.flatMap { MCPSecretReference.names(in: $0) ?? [] })
            if let remote = server.remote {
                detail = "import \(server.name): \(MCPRedaction.url(remote.url.absoluteString).display) (\(remote.transport.rawValue))"
                names.formUnion(remote.secretNames)
            }
            if names.isEmpty == false {
                detail += " (credentials → rv secrets " + names.sorted().joined(separator: ", ") + ")"
            }
            lines.append(detail)
        }
        lines += plan.skipped.map { "skip \($0.name): \($0.reason)" }
        lines += plan.notes.map { "note \($0)" }
        guard plan.servers.isEmpty == false else {
            return .success((lines + ["nothing to import"]).joined(separator: "\n") + "\n")
        }
        if dryRun { return .success((lines + ["dry run: nothing written"]).joined(separator: "\n") + "\n") }
        let signer: MCPSigner
        switch signerForWrite(environment) {
        case .failure(let failure): return .failure(CommandFailure("\(failure.message); nothing imported"))
        case .success(let loaded): signer = loaded
        }
        if let definition = plan.secrets.first?.definition,
            let reason = SecretOrganizationRules.violation(definition, policy: environment.managed.policy)
        {
            return .failure(CommandFailure("organization policy: \(reason); nothing imported"))
        }

        for secret in plan.secrets where SecretValue(secret.value) == nil {
            return .failure(CommandFailure(
                "\(secret.definition.name) is empty, contains NUL, or is over \(SecretValue.maximumBytes) bytes; nothing imported"))
        }
        var stored: [String] = []
        func rollback() -> Bool {
            stored.allSatisfy { environment.keychain.delete(SecretKeychain.service, $0) }
        }
        func keychainFailure(_ name: String) -> CommandFailure {
            let cleared = rollback()
            let tail = cleared
                ? "nothing imported"
                : "could not remove secrets this import already stored in the Keychain"
            return CommandFailure("could not store \(name) in the Keychain; \(tail)")
        }
        for secret in plan.secrets {
            guard environment.keychain.store(SecretKeychain.service, secret.definition.name, Data(secret.value.utf8)) else {
                return .failure(keychainFailure(secret.definition.name))
            }
            stored.append(secret.definition.name)
        }
        if plan.secrets.isEmpty == false {
            var updatedSecrets = secrets
            updatedSecrets.secrets += plan.secrets.map(\.definition)
            if case .failure(let error) = updatedSecrets.write(configDirectory: environment.configDirectory) {
                let cleared = rollback()
                let message = cleared ? error.message : "\(error.message); could not remove secrets this import already stored in the Keychain"
                return .failure(CommandFailure(message))
            }
        }
        var updated = configuration
        updated.servers += plan.servers
        if case .failure(let error) = updated.write(configDirectory: environment.configDirectory, signer: signer) {
            let restoredSecrets: Bool
            if plan.secrets.isEmpty {
                restoredSecrets = true
            } else if case .success = secrets.write(configDirectory: environment.configDirectory) {
                restoredSecrets = true
            } else {
                restoredSecrets = false
            }
            let cleared = rollback()
            let message = restoredSecrets && cleared
                ? error.message
                : "\(error.message); could not remove secrets this import already stored"
            return .failure(CommandFailure(message))
        }
        lines.append("wrote mcp.json\(plan.secrets.isEmpty ? "" : " and secrets.json (values in the Keychain, service \(SecretKeychain.service))")")
        if allowTools == false {
            lines.append("every tool asks for approval until you allow it (mcp.json \"tools\" or `rv mcp approve <id> --always`)")
        }
        lines.append("next: `rv mcp setup --host \(host.rawValue)` routes the host through rv")
        return .success(lines.joined(separator: "\n") + "\n")
    }

    static func setup(
        host: MCPHost, names: [String], project: URL?, undo: Bool, rvPath: String, environment: MCPEnvironment
    ) -> Result<String, CommandFailure> {
        let filter = names.isEmpty ? nil : Set(names)
        let outcome: Result<MCPSetupResult, MCPSetupError>
        if undo {
            outcome = MCPHostSetup.undo(host: host, servers: filter, configDirectory: environment.configDirectory)
        } else {
            let configuration: MCPConfiguration
            switch self.configuration(environment) {
            case .failure(let failure): return .failure(failure)
            case .success(let loaded): configuration = loaded
            }
            let files = MCPHostFile.all(home: environment.home, project: project, environment: environment.processEnvironment)
                .filter { $0.host == host }
            outcome = MCPHostSetup.setup(
                files: files, configuration: configuration, servers: filter, rvPath: rvPath,
                configDirectory: environment.configDirectory)
        }
        switch outcome {
        case .failure(let error):
            return .failure(CommandFailure(error.message))
        case .success(let result):
            var lines = result.changed.map { (undo ? "restored " : "routed through rv: ") + $0 }
            lines += result.skipped.map { "skipped " + $0 }
            if result.manualSteps.isEmpty == false {
                lines.append("\(host.rawValue) keeps MCP servers in TOML; run:")
                lines += result.manualSteps.map { "  " + $0 }
            }
            if lines.isEmpty { lines.append(undo ? "nothing to undo for \(host.rawValue)" : "nothing to change for \(host.rawValue)") }
            if undo == false, result.changed.isEmpty == false {
                lines.append("restart \(host.rawValue) to pick this up; `rv mcp setup --host \(host.rawValue) --undo` reverts it")
            }
            return .success(lines.joined(separator: "\n") + "\n")
        }
    }

    /// The path hosts should launch: argv[0] made absolute (symlinks kept, so upgrades keep working).
    static func rvExecutablePath(arguments: [String] = CommandLine.arguments, environment: [String: String]) -> String {
        let invoked = arguments.first ?? "rv"
        if invoked.contains("/") {
            return URL(fileURLWithPath: invoked).standardizedFileURL.path
        }
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(invoked).path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return invoked
    }

    static func projectURL(_ raw: String?) -> URL {
        URL(fileURLWithPath: raw ?? FileManager.default.currentDirectoryPath, isDirectory: true).standardizedFileURL
    }
}

struct MCP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Find, review, and govern the MCP servers your agents use.",
        subcommands: [
            MCPList.self, MCPCheck.self, MCPImportCommand.self, MCPSetupCommand.self, MCPServe.self, MCPPending.self,
            MCPApprove.self, MCPDeny.self, MCPTrust.self, MCPConnect.self,
        ],
        defaultSubcommand: MCPList.self
    )
}

struct MCPList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list", abstract: "List MCP servers from every host config, with rv's review status.")

    @Option(help: "Project directory for project-scoped configs. Default: current directory.") var project: String?
    @OptionGroup var format: FormatFlags

    func run() throws {
        let ctx = CommandContext.current(command: "mcp list", format: format)
        let environment = MCPEnvironment.live(home: try ctx.requireHome())
        switch MCPRun.configuration(environment) {
        case .failure(let failure):
            try ctx.fail("rv mcp list: \(failure.message)\n")
        case .success(let configuration):
            let report = MCPRun.report(
                environment, project: MCPRun.projectURL(project), configuration: configuration,
                rvExecutable: MCPExecutable.currentPath())
            ctx.writeStdout(ctx.explicitRobot ? SecretsRun.json(report) : MCPRun.listText(report, home: environment.home))
        }
    }
}

struct MCPCheck: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Exit 1 when any MCP server bypasses rv, is unreviewed, or is blocked.")

    @Option(help: "Project directory for project-scoped configs. Default: current directory.") var project: String?
    @OptionGroup var format: FormatFlags

    func run() throws {
        let ctx = CommandContext.current(command: "mcp check", format: format)
        let environment = MCPEnvironment.live(home: try ctx.requireHome())
        switch MCPRun.configuration(environment) {
        case .failure(let failure):
            try ctx.fail("rv mcp check: \(failure.message)\n")
        case .success(let configuration):
            let report = MCPRun.report(
                environment, project: MCPRun.projectURL(project), configuration: configuration,
                rvExecutable: MCPExecutable.currentPath())
            let text = ctx.explicitRobot ? SecretsRun.json(report) : MCPRun.checkText(report, home: environment.home)
            if report.passes {
                ctx.writeStdout(text)
            } else {
                try ctx.emit(stdout: text, exitCode: 1)
            }
        }
    }
}

struct MCPServe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Run approved MCP servers behind rv's policy gateway (stdio; hosts launch this).")

    @Option(name: .customLong("server"), help: "Server from mcp.json to serve (repeatable). Default: all.")
    var servers: [String] = []

    func run() throws {
        let ctx = CommandContext.current(command: "mcp serve", json: false, robot: false, plain: true, noColor: true)
        let home = try ctx.requireHome()
        let environment = MCPEnvironment.live(home: home)
        func fail(_ message: String) throws -> Never {
            try ctx.emit(stdout: "", stderr: "rv mcp serve: \(message)\n", exitCode: 1)
        }
        let configuration: MCPConfiguration
        switch MCPRun.configuration(environment) {
        case .failure(let failure): try fail(failure.message)
        case .success(let loaded): configuration = loaded
        }
        let names = servers.isEmpty ? configuration.servers.map(\.name) : servers
        guard names.isEmpty == false else { try fail("mcp.json defines no servers; see `rv mcp import`") }
        let secrets: SecretsConfiguration
        switch SecretsConfiguration.load(configDirectory: environment.configDirectory) {
        case .failure(let error): try fail(error.message)
        case .success(let loaded): secrets = loaded
        }
        let planned: [(MCPGatewayCore.Upstream, MCPUpstreamConnection)]
        switch MCPLaunchPlanner.plan(
            servers: names, configuration: configuration, secrets: secrets,
            resolver: .live(home: home.rawValue), baseEnvironment: environment.processEnvironment,
            oauthTokens: environment.oauthTokens.load,
            sandbox: MCPSandbox.apply(configDirectory: environment.configDirectory, home: environment.home))
        {
        case .failure(let error): try fail(error.message)
        case .success(let result): planned = result
        }
        let configDirectory = environment.configDirectory
        let log: @Sendable (String) -> Void = { message in
            FileHandle.standardError.write(Data("rv mcp: \(message)\n".utf8))
        }
        if let problem = environment.integrity.problem {
            log("\(problem); every allowed tool asks until then")
            _ = AuditLog.append(
                AuditEvent(
                    time: Date(), kind: .mcpApproval, decision: .info, subject: MCPConfiguration.fileName,
                    reason: problem, source: "rv mcp serve", detail: ["integrity": "untrusted"]),
                configDirectory: configDirectory)
        }
        let core = MCPGatewayCore(
            configuration: configuration,
            upstreams: planned.map { $0.0 },
            approvals: .store(environment.approvals))
        let runtime = MCPGatewayRuntime(
            core: core,
            connections: planned.map { $0.1 },
            oauthStore: environment.oauthTokens,
            audit: { MCPRun.auditRecord($0, configDirectory: configDirectory) },
            event: { _ = AuditLog.append($0, configDirectory: configDirectory) },
            log: log)
        runtime.run()
    }
}

struct MCPPending: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pending", abstract: "List MCP tool calls waiting for your approval.")

    @OptionGroup var format: FormatFlags

    func run() throws {
        let ctx = CommandContext.current(command: "mcp pending", format: format)
        let environment = MCPEnvironment.live(home: try ctx.requireHome())
        let rows = MCPRun.pendingRows(environment.approvals)
        ctx.writeStdout(ctx.explicitRobot ? SecretsRun.json(rows) : MCPRun.pendingText(rows))
    }
}

struct MCPApprove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "approve", abstract: "Let one paused MCP tool call through, or always allow that tool.")

    @Argument(help: "Approval id from the tool error or `rv mcp pending`.") var id: String
    @Flag(help: "Add the tool to the server's allow list in mcp.json.") var always = false

    func run() async throws {
        let ctx = CommandContext.current(command: "mcp approve", json: false, robot: false, plain: true, noColor: true)
        let environment = MCPEnvironment.live(home: try ctx.requireHome())
        switch await MCPRun.approve(id: id, always: always, environment: environment) {
        case .failure(let failure): try ctx.fail("rv mcp approve: \(failure.message)\n")
        case .success(let text): ctx.writeStdout(text)
        }
    }
}

struct MCPDeny: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "deny", abstract: "Refuse a paused MCP tool call.")

    @Argument(help: "Approval id from `rv mcp pending`.") var id: String

    func run() throws {
        let ctx = CommandContext.current(command: "mcp deny", json: false, robot: false, plain: true, noColor: true)
        let environment = MCPEnvironment.live(home: try ctx.requireHome())
        guard let request = environment.approvals.remove(id: id) else {
            try ctx.fail("rv mcp deny: no MCP approval has id \(id)\n")
        }
        ctx.writeStdout("refused \(request.server) \(request.tool)\n")
    }
}

struct MCPTrust: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "trust", abstract: "Accept mcp.json after an edit made outside rv (needs you present).")

    func run() async throws {
        let ctx = CommandContext.current(command: "mcp trust", json: false, robot: false, plain: true, noColor: true)
        let environment = MCPEnvironment.live(home: try ctx.requireHome())
        switch await MCPRun.trust(environment: environment, show: { ctx.writeStdout($0) }) {
        case .failure(let failure): try ctx.fail("rv mcp trust: \(failure.message)\n")
        case .success(let text): ctx.writeStdout(text)
        }
    }
}

struct MCPConnect: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "connect", abstract: "Sign in to a remote MCP server with OAuth; rv keeps and refreshes the tokens.")

    @Argument(help: "Remote (url) server from mcp.json.") var server: String
    @Option(help: "OAuth client id, for servers without client registration.") var clientID: String?
    @Option(help: "Scopes to request (space-separated). Default: what the server asks for.") var scope: String?
    @Flag(help: "Print the sign-in URL without opening a browser.") var noBrowser = false
    @Flag(help: "Delete the tokens rv stored for this server.") var forget = false

    func run() throws {
        let ctx = CommandContext.current(command: "mcp connect", json: false, robot: false, plain: true, noColor: true)
        let home = try ctx.requireHome()
        let environment = MCPEnvironment.live(home: home)
        let name = server
        let openBrowser = noBrowser == false
        let flow = MCPOAuthFlow(present: { url in
            FileHandle.standardError.write(Data("rv: open this URL to sign in to \(name):\n  \(url.absoluteString)\n".utf8))
            if openBrowser { MCPConnect.open(url) }
        })
        switch MCPRun.connect(
            server: server, clientID: clientID, scope: scope, forget: forget, resolver: .live(home: home.rawValue), flow: flow,
            environment: environment)
        {
        case .failure(let failure): try ctx.fail("rv mcp connect: \(failure.message)\n")
        case .success(let text): ctx.writeStdout(text)
        }
    }

    static func open(_ url: URL) {
        #if os(macOS)
        let opener = "/usr/bin/open"
        #else
        let opener = "/usr/bin/xdg-open"
        #endif
        guard FileManager.default.isExecutableFile(atPath: opener) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: opener)
        process.arguments = [url.absoluteString]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}

extension MCPHost: ExpressibleByArgument {}

struct MCPImportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Copy a host's MCP servers into mcp.json; literal credentials move into the Keychain.")

    @Option(help: "Host to import from: \(MCPHost.allCases.map(\.rawValue).joined(separator: ", ")).") var host: MCPHost
    @Option(name: .customLong("server"), help: "Only this server (repeatable).") var servers: [String] = []
    @Option(help: "Project directory for project-scoped configs. Default: current directory.") var project: String?
    @Flag(help: "Allow every tool of the imported servers instead of asking.") var allowTools = false
    @Flag(help: "Show what would change; write nothing.") var dryRun = false

    func run() throws {
        let ctx = CommandContext.current(command: "mcp import", json: false, robot: false, plain: true, noColor: true)
        let environment = MCPEnvironment.live(home: try ctx.requireHome())
        switch MCPRun.importServers(
            host: host, names: servers, project: MCPRun.projectURL(project), allowTools: allowTools, dryRun: dryRun,
            environment: environment)
        {
        case .failure(let failure): try ctx.fail("rv mcp import: \(failure.message)\n")
        case .success(let text): ctx.writeStdout(text)
        }
    }
}

struct MCPSetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Point a host's MCP servers at `rv mcp serve`; --undo restores them.")

    @Option(help: "Host to configure: \(MCPHost.allCases.map(\.rawValue).joined(separator: ", ")).") var host: MCPHost
    @Option(name: .customLong("server"), help: "Only this server (repeatable).") var servers: [String] = []
    @Option(help: "Project directory for project-scoped configs. Default: current directory.") var project: String?
    @Option(help: "rv path the host should launch. Default: this rv.") var rvPath: String?
    @Flag(help: "Restore the entries rv rewrote, when they are unchanged.") var undo = false

    func run() throws {
        let ctx = CommandContext.current(command: "mcp setup", json: false, robot: false, plain: true, noColor: true)
        let environment = MCPEnvironment.live(home: try ctx.requireHome())
        let path = rvPath ?? MCPRun.rvExecutablePath(environment: environment.processEnvironment)
        switch MCPRun.setup(
            host: host, names: servers, project: MCPRun.projectURL(project), undo: undo, rvPath: path,
            environment: environment)
        {
        case .failure(let failure): try ctx.fail("rv mcp setup: \(failure.message)\n")
        case .success(let text): ctx.writeStdout(text)
        }
    }
}
