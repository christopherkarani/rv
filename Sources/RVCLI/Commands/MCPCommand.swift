import ArgumentParser
import Foundation
import RVDomain
import RVHistory
import RVIsolation
import RVMCP
import RVPolicy
import Synchronization

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

    /// A fresh read of mcp.json. Launching and re-signing must not treat a
    /// passing result as permission to use a configuration read at another time.
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

    /// mcp.json bytes and the configuration decoded from those exact bytes.
    /// Integrity is not checked here, so this does not prompt for the key.
    struct MCPStoredConfiguration: Sendable {
        var bytes: Data?
        var configuration: MCPConfiguration
    }

    /// One read of mcp.json, judged and decoded from those bytes. `keys.load`
    /// may prompt after the read; it cannot change which bytes were judged.
    struct MCPBoundConfiguration: Sendable {
        var stored: MCPStoredConfiguration
        var integrity: MCPIntegrityStatus

        var configuration: MCPConfiguration { stored.configuration }
    }

    /// mcp.json with organization policy applied. An invalid managed policy fails closed.
    /// One read: the signature check runs on the same bytes that are decoded,
    /// so a file swapped between two reads cannot verify as another file.
    /// The `untrusted` flag describes the same bytes as `configuration`.
    static func configuration(_ environment: MCPEnvironment) -> Result<MCPConfiguration, CommandFailure> {
        boundConfiguration(environment).map(\.configuration)
    }

    static func readSnapshot(_ environment: MCPEnvironment) -> Result<MCPStoredConfiguration, CommandFailure> {
        if let reason = environment.managed.invalidReason {
            return .failure(CommandFailure("organization policy is invalid, so MCP is disabled: \(reason)"))
        }
        let bytes: Data?
        switch OwnerOnlyFile.read(
            MCPConfiguration.fileURL(configDirectory: environment.configDirectory),
            maximumBytes: MCPConfiguration.maximumBytes)
        {
        case .success(let data): bytes = data
        case .failure(let error): return .failure(CommandFailure(configurationError(error).message))
        }
        let decoded: MCPConfiguration
        if let bytes {
            switch MCPConfiguration.decode(bytes) {
            case .failure(let error): return .failure(CommandFailure(error.message))
            case .success(let configuration): decoded = configuration
            }
        } else {
            decoded = MCPConfiguration()
        }
        var configuration = decoded
        configuration.managed = environment.managed.policy
        return .success(MCPStoredConfiguration(bytes: bytes, configuration: configuration))
    }

    static func boundConfiguration(_ environment: MCPEnvironment) -> Result<MCPBoundConfiguration, CommandFailure> {
        let stored: MCPStoredConfiguration
        switch readSnapshot(environment) {
        case .failure(let failure): return .failure(failure)
        case .success(let loaded): stored = loaded
        }
        let integrity = MCPIntegrity.status(
            of: stored.bytes, configDirectory: environment.configDirectory, keys: environment.approvalKeys)
        var configuration = stored.configuration
        configuration.untrusted = integrity.isTrusted == false
        return .success(MCPBoundConfiguration(
            stored: MCPStoredConfiguration(bytes: stored.bytes, configuration: configuration), integrity: integrity))
    }

    /// File contents, ignoring the managed overlay and the untrusted flag.
    static func sameStoredConfiguration(_ lhs: MCPConfiguration, _ rhs: MCPConfiguration) -> Bool {
        var left = lhs
        var right = rhs
        left.managed = nil
        right.managed = nil
        left.untrusted = false
        right.untrusted = false
        return left == right
    }

    static func configurationError(_ error: OwnerOnlyFileError) -> MCPConfigurationError {
        switch error {
        case .unsafe(let reason): .unsafeFile(reason)
        case .unreadable: .unreadable
        case .oversized: .oversized
        }
    }

    static func signer(_ environment: MCPEnvironment) -> Result<MCPSigner, CommandFailure> {
        guard let loaded = environment.approvalKeys.loadOrCreate() else {
            return .failure("could not create rv's approvals key (\(MCPApprovalKeyStore.keychainService))")
        }
        return .success(loaded)
    }

    /// True when mcp.json on disk is exactly `configuration.encoded()`.
    static func fileMatches(_ configuration: MCPConfiguration, configDirectory: URL) -> Bool {
        let expected = Data(configuration.encoded().prettyText.utf8)
        guard case .success(let actual?) = OwnerOnlyFile.read(
            MCPConfiguration.fileURL(configDirectory: configDirectory), maximumBytes: MCPConfiguration.maximumBytes)
        else { return false }
        return actual == expected
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
        var problems = inventory.problems.map { Problem(path: $0.path, message: $0.message) }
        problems += sandboxProblems(configuration, configDirectory: environment.configDirectory)
        return Report(
            servers: configuration.servers.count,
            direct: configuration.direct.count,
            blocked: configuration.blocked.count,
            integrity: integrity.label,
            integrityProblem: integrity.problem,
            rows: rows,
            problems: problems)
    }

    static func listText(_ report: Report, home: URL) -> String {
        var lines = [
            "rv mcp.json: \(report.servers) gateway servers, \(report.direct) direct, \(report.blocked) blocked"
        ]
        if report.rows.isEmpty { lines.append("no MCP servers found in any host configuration") }
        var currentFile: String?
        let shownNames = report.rows.map { reviewField($0.name) }
        let width = min(28, shownNames.map(\.count).max() ?? 0)
        for row in report.rows {
            let file = "\(reviewField(row.host)) (\(row.scope == "user" ? "user" : "project"), \(reviewField(abbreviate(row.configPath, home: home))))"
            if file != currentFile {
                lines.append("")
                lines.append(file)
                currentFile = file
            }
            let name = reviewField(row.name)
            let padded = name.padding(toLength: max(width, name.count), withPad: " ", startingAt: 0)
            let status = reviewField(row.status).padding(toLength: 10, withPad: " ", startingAt: 0)
            lines.append("  \(padded)  \(status)  \(reviewField(row.command))")
            var details: [String] = []
            if row.environmentNames.isEmpty == false { details.append("env " + capped(row.environmentNames.map(reviewField))) }
            if row.headerNames.isEmpty == false { details.append("headers " + row.headerNames.map(reviewField).joined(separator: ", ")) }
            if row.plaintextCredentials.isEmpty == false {
                details.append("plaintext credential: " + row.plaintextCredentials.map(reviewField).joined(separator: ", "))
            }
            if details.isEmpty == false {
                lines.append("  " + String(repeating: " ", count: max(width, row.name.count)) + "  " + details.joined(separator: " · "))
            }
        }
        lines.append("")
        lines.append(summary(report))
        lines += problemLines(report, home: home)
        if let problem = report.integrityProblem { lines.append("warning: " + reviewField(problem)) }
        return lines.joined(separator: "\n") + "\n"
    }

    static func checkText(_ report: Report, home: URL) -> String {
        var lines: [String] = []
        if report.passes {
            lines.append("ok: every MCP server is governed by rv, allowed direct, or disabled (\(report.rows.count) checked)")
        } else {
            if let problem = report.integrityProblem {
                lines.append("untrusted  " + reviewField(problem))
                lines.append("  Fix: review with `rv mcp list`, then `rv mcp trust`")
            }
            for row in report.failing {
                let status = MCPEntryStatus(rawValue: row.status)
                lines.append(
                    "\(reviewField(row.status))  \(reviewField(row.name))  \(reviewField(row.host)) \(reviewField(abbreviate(row.configPath, home: home)))")
                if let status { lines.append("  \(status.explanation)") }
                if let status, let fix = fixLine(status: status, row: row) { lines.append(fix) }
            }
            lines += problemLines(report, home: home)
            lines.append(summary(report))
        }
        let leaks = report.rows.filter { $0.plaintextCredentials.isEmpty == false }
        if leaks.isEmpty == false {
            lines.append(
                "warning: \(leaks.count) host entr\(leaks.count == 1 ? "y holds" : "ies hold") plaintext credentials ("
                    + leaks.map { reviewField($0.name) }.joined(separator: ", ") + "); `rv mcp import` moves them into rv secrets")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The exact next command for a failing row. Names and hosts go through
    /// the same review escaping as the rest of the output, so a hostile
    /// server name cannot redraw the terminal or forge the suggestion.
    static func fixLine(status: MCPEntryStatus, row: Row) -> String? {
        let host = reviewField(row.host)
        let name = shellQuotedReviewFields([row.name])
        switch status {
        case .bypass:
            return "  Fix: `rv mcp setup --host \(host) --server \(name)`"
        case .unreviewed:
            return "  Fix: `rv mcp onboard --host \(host) --server \(name)`"
        case .dangling:
            return "  Fix: `rv mcp setup --host \(host) --server \(name) --undo`, or define \(name) in mcp.json"
        case .blocked:
            return "  Fix: remove \(name) from \"blocked\" in mcp.json to review it"
        case .governed, .direct, .disabled:
            return nil
        }
    }

    static func capped(_ names: [String], limit: Int = 4) -> String {
        names.count <= limit
            ? names.joined(separator: ", ")
            : names.prefix(limit).joined(separator: ", ") + " +\(names.count - limit) more"
    }

    /// Terminal-safe spelling. CR, ESC, C1, line separators, and bidi marks stay
    /// visible as text so a password cannot be erased, concealed, or reordered.
    static func visible(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                output += "\\n"
            } else if concealsOnATerminal(scalar) {
                switch scalar.value {
                case 0x09: output += "\\t"
                case 0x0D: output += "\\r"
                case 0x1B: output += "\\u{001B}"
                default: output += String(format: "\\u{%04X}", scalar.value)
                }
            } else {
                output.unicodeScalars.append(scalar)
            }
        }
        return output
    }

    /// A review that still contains a raw control or bidi mark would hide text on a terminal.
    /// True when the rendered review still carries a raw scalar the display
    /// layer escapes (controls, separators, format/bidi) — such a scalar
    /// could redraw or reorder what the person approved. This is the
    /// renderer's own predicate: scalars it deliberately leaves raw
    /// (joiners, variation selectors) are shown, not concealing.
    static func reviewConceals(_ review: String) -> Bool {
        review.unicodeScalars.contains { scalar in
            scalar != "\n" && DisplayedText.needsEscape(scalar)
        }
    }

    /// Anything invisible or text-reordering on a terminal, classified by
    /// property: controls, format characters (zero-width spaces, bidi
    /// controls, tag characters), line/paragraph separators, unassigned
    /// scalars, and default-ignorable code points (variation selectors,
    /// the combining grapheme joiner). Ordinary combining accents print.
    static func concealsOnATerminal(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isDefaultIgnorableCodePoint { return true }
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .unassigned, .privateUse:
            return true
        default:
            return false
        }
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

    /// Governed local servers `rv mcp serve` will refuse: every local server
    /// needs an explicit sandbox, and a sandbox reaches the network only
    /// through `sandbox.hosts`. Blocked servers are refused either way.
    static func sandboxProblems(_ configuration: MCPConfiguration, configDirectory: URL) -> [Problem] {
        let path = MCPConfiguration.fileURL(configDirectory: configDirectory).path
        return configuration.servers.compactMap { server -> Problem? in
            guard server.remote == nil, configuration.isBlocked(server.name) == false else { return nil }
            if server.sandbox == nil {
                return Problem(
                    path: path,
                    message: "\(server.name) has no sandbox; add \"sandbox\" to its mcp.json entry")
            }
            if server.sandbox?.network == true {
                return Problem(
                    path: path,
                    message: "\(server.name) has sandbox network on; list the hosts it needs in sandbox.hosts")
            }
            return nil
        }
    }

    static func problemLines(_ report: Report, home: URL) -> [String] {
        report.problems.map {
            "problem: \(reviewField(abbreviate($0.path, home: home))): \(reviewField($0.message))"
        }
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
        /// False when the stored names are not the names inside the key MAC.
        var argumentKeysBound: Bool
        var requestedAt: Date
    }

    static func pendingRows(_ store: MCPApprovalStore) -> [PendingRow] {
        store.pending().map { request in
            let bound = store.argumentKeysAreBound(request)
            return PendingRow(
                id: request.id, server: request.server, tool: request.tool,
                argumentKeys: bound ? request.argumentKeys : [], argumentKeysBound: bound,
                requestedAt: request.requestedAt)
        }
    }

    static func pendingText(_ rows: [PendingRow]) -> String {
        guard rows.isEmpty == false else { return "no MCP tool calls are waiting for approval\n" }
        let formatter = ISO8601DateFormatter()
        let lines = rows.map { row in
            let keys: String
            if row.argumentKeysBound == false {
                keys = "arguments changed outside rv"
            } else if row.argumentKeys.isEmpty {
                keys = "no arguments"
            } else {
                keys = "arguments " + displayedArgumentKeys(row.argumentKeys)
            }
            return "\(reviewField(row.id))  \(reviewField(row.server)) \(reviewField(row.tool))  \(keys)  \(formatter.string(from: row.requestedAt))"
        }
        return (lines + [
            "approve in your own terminal with `rv mcp approve <id>` (once) or `--always`; refuse with `rv mcp deny <id>`",
            "approving needs you present: Touch ID or your password. A pseudo-terminal cannot approve",
        ])
            .joined(separator: "\n") + "\n"
    }

    /// Grants one pending call; `always` also adds the tool to the server's allow list.
    /// The person approving must prove presence first, so an agent's shell cannot approve.
    static func approve(id: String, always: Bool, environment: MCPEnvironment) async -> Result<String, CommandFailure> {
        let store = environment.approvals
        guard let request = store.pending().first(where: { $0.id == id }) else {
            return .failure("no pending MCP approval has id \(reviewField(id)) (see `rv mcp pending`)")
        }
        var allowed: (MCPConfiguration, MCPSigner)?
        if always {
            switch allowListed(request, environment: environment) {
            case .failure(let failure): return .failure(failure)
            case .success(let result): allowed = result
            }
        }
        guard store.argumentKeysAreBound(request) else {
            return .failure("the approval changed while you reviewed it; nothing was signed")
        }
        let shownKeys = request.argumentKeys.isEmpty
            ? "no arguments"
            : displayedArgumentKeys(request.argumentKeys)
        let reason = "rv: approve \(reviewField(request.server)) tool \(reviewField(request.tool)) "
            + "arguments \(request.argumentsHash) keys \(shownKeys) "
            + (always ? "always" : "once")
        let codeChecked = Mutex(false)
        let outcome = await environment.presence.confirm(reason, .printedCode { typed in
            let ok = store.verifyCode(id: id, typed: typed)
            if ok { codeChecked.withLock { $0 = true } }
            return ok
        })
        guard case .confirmed(let method) = outcome else {
            let refusal = if case .refused(let why) = outcome { why } else { "not confirmed" }
            audit(request, decision: .denied, reason: "user presence not confirmed: \(refusal)", method: nil,
                  always: always, configDirectory: environment.configDirectory)
            return .failure(CommandFailure("not approved: \(refusal)"))
        }
        guard codeChecked.withLock({ $0 }) else {
            audit(request, decision: .denied, reason: "confirmation code was not checked", method: method,
                  always: always, configDirectory: environment.configDirectory)
            return .failure("not approved: confirmation code was not checked")
        }
        guard store.grant(
            id: id, server: request.server, tool: request.tool, argumentsHash: request.argumentsHash,
            argumentKeys: request.argumentKeys
        ) != nil else {
            audit(request, decision: .denied, reason: "approval changed before it was signed", method: method,
                  always: always, configDirectory: environment.configDirectory)
            return .failure("the approval changed while you reviewed it; nothing was signed")
        }
        if case let (configuration, signer)? = allowed {
            if case .failure(let error) = configuration.write(configDirectory: environment.configDirectory, signer: signer) {
                _ = store.remove(id: id)
                return .failure(CommandFailure(error.message))
            }
            guard fileMatches(configuration, configDirectory: environment.configDirectory) else {
                _ = store.remove(id: id)
                return .failure("mcp.json changed while it was being signed")
            }
        }
        audit(request, decision: .allowed, reason: nil, method: method, always: always,
              configDirectory: environment.configDirectory)
        return .success(always
            ? "approved \(reviewField(request.server)) \(reviewField(request.tool)) always (added to its allow list in mcp.json)\n"
            : "approved \(reviewField(request.server)) \(reviewField(request.tool)) once; the agent can retry the same call\n")
    }

    /// mcp.json with the request's tool moved to the allow list, and the signer to write it with.
    /// The configuration is the bytes verified before the keychain prompt, not a later read.
    static func allowListed(
        _ request: MCPApprovalRequest, environment: MCPEnvironment
    ) -> Result<(MCPConfiguration, MCPSigner), CommandFailure> {
        let bound: MCPBoundConfiguration
        switch boundConfiguration(environment) {
        case .failure(let failure): return .failure(failure)
        case .success(let loaded): bound = loaded
        }
        if let problem = bound.integrity.problem { return .failure(CommandFailure(problem)) }
        let signer: MCPSigner
        switch self.signer(environment) {
        case .failure(let failure): return .failure(failure)
        case .success(let loaded): signer = loaded
        }
        var configuration = bound.configuration
        guard let index = configuration.servers.firstIndex(where: { $0.name == request.server }) else {
            return .failure("mcp.json no longer defines \(reviewField(request.server))")
        }
        if configuration.hasArgumentRules(server: configuration.servers[index], tool: request.tool) {
            return .failure(
                "\(reviewField(request.tool)) has argument rules, so allowing it always would not cover every call; approve it once or edit the rule")
        }
        var tools = configuration.servers[index].tools
        tools.ask.removeAll { $0 == request.tool }
        if tools.allow.contains(request.tool) == false { tools.allow.append(request.tool) }
        configuration.servers[index].tools = tools
        if let organization = configuration.organizationDecision(server: request.server, tool: request.tool),
            organization != .allow
        {
            return .failure(
                "organization policy says \(organization.rawValue) for \(reviewField(request.server))/\(reviewField(request.tool)); approve it once instead")
        }
        if configuration.decision(server: configuration.servers[index], tool: request.tool) != .allow {
            return .failure(
                "\(reviewField(request.tool)) still matches an ask or deny rule in mcp.json; edit that rule instead")
        }
        return .success((configuration, signer))
    }

    static func audit(
        _ request: MCPApprovalRequest, decision: AuditDecision, reason: String?, method: String?, always: Bool,
        configDirectory: URL
    ) {
        var detail = ["approval": request.id, "always": always ? "true" : "false"]
        if let method { detail["method"] = method }
        auditOrLog(
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
        case .failure(.invalid("repeats a JSON key")):
            return .failure("mcp.json repeats a JSON key; nothing signed")
        case .failure(let error): return .failure(CommandFailure(error.message))
        case .success(let decoded): configuration = decoded
        }
        if MCPIntegrity.status(of: data, configDirectory: environment.configDirectory, keys: environment.approvalKeys) == .trusted {
            return .success("mcp.json already matches rv's signature; nothing to trust\n")
        }
        let digest = RVDigest.sha256Hex([UInt8](data))
        let review = trustReview(configuration) + "\nsha256 \(digest)"
        guard review.contains("sha256 \(digest)"), trustReviewShowsEveryLiteral(configuration, review) else {
            return .failure("trust review omitted a literal value; nothing signed")
        }
        show(review + "\n")
        let outcome = await environment.presence.confirm("rv: trust mcp.json sha256 \(digest)\n\(review)", .deviceOwner)
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
        auditOrLog(
            AuditEvent(
                time: Date(), kind: .mcpApproval, decision: .allowed, subject: MCPConfiguration.fileName,
                reason: "mcp.json trusted", source: "rv mcp trust",
                detail: ["method": method, "sha256": RVDigest.sha256Hex([UInt8](data))]),
            configDirectory: environment.configDirectory)
        return .success("trusted mcp.json; rv signs it again on every change it makes\n")
    }

    static func trustReview(_ configuration: MCPConfiguration) -> String {
        var lines = [
            "mcp.json: default deny for tools without a rule",
            "  unlisted tools deny; local servers need a sandbox; network only through sandbox.hosts",
        ]
        if configuration.toolMode == .search {
            lines.append("  tool mode search: clients see only rv_search_tools and rv_call_tool")
        }
        for server in configuration.servers {
            var rules: [String] = []
            if let remote = server.remote {
                let transport = remote.transport == .sse ? "legacy SSE" : "streamable HTTP"
                let redacted = MCPRedaction.url(remote.url.absoluteString)
                let shown = redacted.leaked ? "\(redacted.display) (credential-like part hidden)" : remote.url.absoluteString
                lines.append("  \(reviewField(server.name)): \(visible(shown)) (remote, \(transport))")
                for name in remote.headers.keys.sorted() {
                    let value = remote.headers[name] ?? ""
                    lines.append("    \(name): \(visible(value))")
                    let secrets = MCPSecretReference.names(in: value) ?? []
                    if secrets.isEmpty == false {
                        lines.append("    \(name) → secret \(secrets.map(visible).joined(separator: ", "))")
                    }
                }
            } else {
                lines.append("  \(reviewField(server.name)): \(quotedReviewFields([server.command] + server.args))")
                lines.append("    command: \(visible(server.command))")
                for arg in server.args {
                    lines.append("    argument: \(visible(arg))")
                }
            }
            if let description = server.description {
                lines.append("    description: \(visible(description))")
            }
            for name in server.environment.keys.sorted() {
                lines.append("    \(name)=\(visible(server.environment[name] ?? ""))")
            }
            for variable in server.secrets.keys.sorted() {
                lines.append("    \(variable) → secret \(visible(server.secrets[variable] ?? ""))")
            }
            lines += bindingLines(server, indent: "    ")
            let tools = server.tools
            if tools.allow.isEmpty == false { rules.append("allow " + tools.allow.map(visible).joined(separator: ", ")) }
            if tools.ask.isEmpty == false { rules.append("ask " + tools.ask.map(visible).joined(separator: ", ")) }
            if tools.deny.isEmpty == false { rules.append("deny " + tools.deny.map(visible).joined(separator: ", ")) }
            for glob in tools.allow { lines.append("    allow \(visible(glob))") }
            for glob in tools.ask { lines.append("    ask \(visible(glob))") }
            for glob in tools.deny { lines.append("    deny \(visible(glob))") }
            for ruled in tools.rules { rules.append("\(ruled.decision.rawValue) \(visible(ruled.rule.summary))") }
            rules.append("other tools deny")
            if let sandbox = server.sandbox {
                for path in sandbox.writable {
                    lines.append("    writable: \(visible(path))")
                }
                if sandbox.hosts.isEmpty == false {
                    rules.append("network only to " + sandbox.hosts.map(visible).joined(separator: ", "))
                    for host in sandbox.hosts { lines.append("    host \(visible(host))") }
                } else if sandbox.network == false {
                    rules.append("no network")
                }
            } else if server.remote == nil {
                rules.append("no sandbox")
            }
            if server.remote == nil { lines += sandboxLines(server, indent: "    ") }
            if rules.isEmpty == false { lines.append("    " + rules.joined(separator: " · ")) }
        }
        if configuration.direct.isEmpty == false {
            lines.append("  direct: " + quotedReviewFields(configuration.direct))
        }
        if configuration.blocked.isEmpty == false {
            lines.append("  blocked: " + quotedReviewFields(configuration.blocked))
        }
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
            MCPRun.auditOrLog(
                AuditEvent(
                    time: Date(), kind: .mcpApproval, decision: .allowed, subject: name, reason: reason, source: "rv mcp connect",
                    detail: detail),
                configDirectory: environment.configDirectory)
        }
        if forget {
            // Under the same interprocess lock as refresh, or a concurrent
            // serve can re-save the tokens being deleted.
            let removed = Mutex<Bool?>(nil)
            _ = environment.oauthTokens.withExclusiveLock(name) {
                removed.withLock { $0 = environment.oauthTokens.remove(name) }
            }
            guard removed.withLock({ $0 }) == true else {
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
        let saved = Mutex(false)
        _ = environment.oauthTokens.withExclusiveLock(name) {
            saved.withLock { $0 = environment.oauthTokens.save(name, tokens) }
        }
        guard saved.withLock({ $0 }) else {
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

    /// Appends, or says so on stderr: silently losing audit on a full disk
    /// would let calls proceed unrecorded.
    static func auditOrLog(_ event: AuditEvent, configDirectory: URL) {
        if AuditLog.append(event, configDirectory: configDirectory) == false {
            FileHandle.standardError.write(Data("rv mcp: could not append the audit log\n".utf8))
        }
    }

    static func auditRecord(_ record: MCPCallRecord, configDirectory: URL) {
        auditOrLog(record.auditEvent(), configDirectory: configDirectory)
    }

    static func reviewField(_ text: String) -> String {
        MCPDisplayedText.field(text)
    }

    /// Robot JSON. `JSONEncoder` already writes ESC as `\u001b`. U+2028,
    /// U+2029, and U+202E stay raw unless they are replaced after encoding.
    /// The result is still valid JSON. `SecretsRun.json` itself is unchanged.
    static func robotJSON<T: Encodable>(_ value: T) -> String {
        var text = SecretsRun.json(value)
        let scalars: [(Character, String)] = [
            ("\u{2028}", "\\u2028"),
            ("\u{2029}", "\\u2029"),
            ("\u{202E}", "\\u202e"),
        ]
        for (scalar, escaped) in scalars {
            text = text.replacingOccurrences(of: String(scalar), with: escaped)
        }
        return text
    }

    static func denyMissingIDMessage(_ id: String) -> String {
        "no MCP approval has id \(reviewField(id))"
    }

    /// Quoted review values. `read_file` plus `shell` does not look like the
    /// single name `read_file, shell`.
    static func quotedReviewFields(_ values: [String]) -> String {
        values.map { value in
            let quoted = reviewField(value)
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(quoted)\""
        }.joined(separator: ", ")
    }

    /// Double-quoted values safe to paste into a shell command: inside
    /// double quotes `$` and backticks still expand, so escape them (and
    /// the quote/backslash `quotedReviewFields` already handles).
    static func shellQuotedReviewFields(_ values: [String]) -> String {
        values.map { value in
            let quoted = reviewField(value)
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "$", with: "\\$")
                .replacingOccurrences(of: "`", with: "\\`")
            return "\"\(quoted)\""
        }.joined(separator: ", ")
    }

    /// Quoted argument names. `path` plus `contents` does not look like the
    /// single name `path, contents`.
    static func displayedArgumentKeys(_ keys: [String]) -> String {
        quotedReviewFields(keys)
    }

    static func deniedLine(server: String, tool: String) -> String {
        "refused \(reviewField(server)) \(reviewField(tool))\n"
    }

    /// Sandbox network and writable paths, or `no sandbox` when serve will
    /// inherit the host environment.
    static func sandboxLines(_ server: MCPServerDefinition, indent: String = "") -> [String] {
        guard let sandbox = server.sandbox else { return ["\(indent)no sandbox"] }
        let writable = quotedReviewFields(
            MCPSandbox.disclosedWritePaths(server: server.name, policy: sandbox))
        return ["\(indent)sandbox network \(sandbox.network)", "\(indent)sandbox writable \(writable)"]
    }

    /// Every env binding, secret binding, and tool-list name, with no clip.
    static func bindingLines(_ server: MCPServerDefinition, indent: String = "") -> [String] {
        var lines: [String] = []
        for (name, value) in server.environment.sorted(by: { $0.key < $1.key }) {
            lines.append("\(indent)env \(reviewField(name))=\(reviewField(value))")
        }
        for (name, secret) in server.secrets.sorted(by: { $0.key < $1.key }) {
            lines.append("\(indent)secret \(reviewField(name))=\(reviewField(secret))")
        }
        if server.tools.allow.isEmpty == false {
            lines.append("\(indent)allow " + quotedReviewFields(server.tools.allow))
        }
        if server.tools.ask.isEmpty == false {
            lines.append("\(indent)ask " + quotedReviewFields(server.tools.ask))
        }
        if server.tools.deny.isEmpty == false {
            lines.append("\(indent)deny " + quotedReviewFields(server.tools.deny))
        }
        for ruled in server.tools.rules {
            lines.append("\(indent)\(ruled.decision.rawValue) \(reviewField(ruled.rule.summary))")
        }
        if let remote = server.remote {
            lines.append(
                "\(indent)remote \(reviewField(MCPRedaction.url(remote.url.absoluteString).display)) (\(remote.transport.rawValue))")
            for (name, value) in remote.headers.sorted(by: { $0.key < $1.key }) {
                lines.append("\(indent)header \(reviewField(name)): \(reviewField(value))")
            }
        }
        return lines
    }

    /// Plans upstream processes. An untrusted mcp.json is refused before any
    /// command, argument, sandbox, or secret is resolved into a launch.
    /// The plan uses the bytes this call verified. A configuration captured
    /// earlier is not launched when it differs.
    static func upstreamLaunches(
        names: [String], configuration: MCPConfiguration, environment: MCPEnvironment, secrets: SecretsConfiguration,
        resolver: SecretResolver,
        sandbox: @escaping (MCPServerDefinition, MCPUpstreamLaunch) -> Result<MCPUpstreamLaunch, MCPLaunchError> = { _, launch in
            .success(launch)
        }
    ) -> Result<[(MCPGatewayCore.Upstream, MCPUpstreamConnection)], CommandFailure> {
        let verified: MCPConfiguration
        switch boundConfiguration(environment) {
        case .failure(let failure): return .failure(failure)
        case .success(let bound):
            if let problem = bound.integrity.problem {
                auditOrLog(
                    AuditEvent(
                        time: Date(), kind: .mcpApproval, decision: .info, subject: MCPConfiguration.fileName,
                        reason: problem, source: "rv mcp serve", detail: ["integrity": "untrusted"]),
                    configDirectory: environment.configDirectory)
                return .failure(CommandFailure("\(problem); not launching MCP servers"))
            }
            guard sameStoredConfiguration(configuration, bound.configuration) else {
                let problem = "mcp.json changed while it was being checked"
                auditOrLog(
                    AuditEvent(
                        time: Date(), kind: .mcpApproval, decision: .info, subject: MCPConfiguration.fileName,
                        reason: problem, source: "rv mcp serve", detail: ["integrity": "changed"]),
                    configDirectory: environment.configDirectory)
                return .failure(CommandFailure("\(problem); not launching MCP servers"))
            }
            verified = bound.configuration
        }
        switch MCPLaunchPlanner.plan(
            servers: names, configuration: verified, secrets: secrets, resolver: resolver,
            baseEnvironment: environment.processEnvironment, oauthTokens: environment.oauthTokens.load, sandbox: sandbox)
        {
        case .failure(let error): return .failure(CommandFailure(error.message))
        case .success(let planned): return .success(planned)
        }
    }

    /// Every server that will be signed: command, arguments, tool policy, env
    /// bindings, secret bindings, and every allow, ask, and deny name.
    /// The digest is of that whole text. Nothing is clipped.
    static func importPresenceReview(servers: [MCPServerDefinition]) -> (shown: String, reason: String) {
        let policy = "ask before every tool"
        let lines = servers.flatMap { server -> [String] in
            let command = reviewField(server.name) + ": " + quotedReviewFields([server.command] + server.args)
            return ["\(command) (\(policy))"] + bindingLines(server) + sandboxLines(server)
                + reviewedServerLines(server)
        }
        let body = (["tools: \(policy)"] + lines).joined(separator: "\n")
        let digest = RVDigest.sha256Hex(Array(body.utf8))
        return (body + "\nsha256 \(digest)\n", "rv: import sha256 \(digest)\n\(body)")
    }

    static func importServers(
        host: MCPHost, names: [String], project: URL?, dryRun: Bool, environment: MCPEnvironment,
        toolModeForFreshConfig: MCPToolMode? = nil,
        show: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> Result<String, CommandFailure> {
        let base: MCPStoredConfiguration
        switch readSnapshot(environment) {
        case .failure(let failure): return .failure(failure)
        case .success(let loaded): base = loaded
        }
        let configuration = base.configuration
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
            let shown = missing.map(reviewField).joined(separator: ", ")
            return .failure(CommandFailure("\(host.rawValue) has no MCP server named \(shown)"))
        }
        let plan = MCPImport.plan(entries: entries, configuration: configuration, secrets: secrets)
        var lines: [String] = []
        for server in plan.servers {
            var detail = "import \(reviewField(server.name)): \(reviewField(server.command))"
            var names = Set(server.secrets.values).union(server.args.flatMap { MCPSecretReference.names(in: $0) ?? [] })
            if let remote = server.remote {
                detail = "import \(reviewField(server.name)): "
                    + "\(reviewField(MCPRedaction.url(remote.url.absoluteString).display)) (\(remote.transport.rawValue))"
                names.formUnion(remote.secretNames)
            }
            if names.isEmpty == false {
                detail += " (credentials → rv secrets " + names.sorted().map(reviewField).joined(separator: ", ") + ")"
            }
            lines.append(detail)
        }
        lines += plan.skipped.map { "skip \(reviewField($0.name)): \(reviewField($0.reason))" }
        lines += plan.notes.map { "note \(reviewField($0))" }
        guard plan.servers.isEmpty == false else {
            return .success((lines + ["nothing to import"]).joined(separator: "\n") + "\n")
        }
        if dryRun { return .success((lines + ["dry run: nothing written"]).joined(separator: "\n") + "\n") }
        let integrity = MCPIntegrity.status(
            of: base.bytes, configDirectory: environment.configDirectory, keys: environment.approvalKeys)
        if let problem = integrity.problem {
            return .failure(CommandFailure("\(problem); nothing imported"))
        }
        let signer: MCPSigner
        switch self.signer(environment) {
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
        let review = importPresenceReview(servers: plan.servers)
        guard reviewShowsEveryLiteral(plan, review.shown) else {
            return .failure(CommandFailure("import review omitted a literal value; nothing imported"))
        }
        show(review.shown)
        let outcome = await environment.presence.confirm(review.reason, .deviceOwner)
        guard case .confirmed = outcome else {
            let refusal = if case .refused(let why) = outcome { why } else { "not confirmed" }
            return .failure(CommandFailure("not imported: \(refusal); nothing imported"))
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
        // A first import chooses the compact tool listing: clients see only
        // rv_search_tools and rv_call_tool instead of every upstream schema.
        // Existing configs keep whatever mode the operator already chose.
        if let toolModeForFreshConfig, configuration.servers.isEmpty {
            updated.toolMode = toolModeForFreshConfig
        }
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
        guard fileMatches(updated, configDirectory: environment.configDirectory) else {
            return .failure(CommandFailure("mcp.json changed while it was being signed"))
        }
        lines.append("wrote mcp.json\(plan.secrets.isEmpty ? "" : " and secrets.json (values in the Keychain, service \(SecretKeychain.service))")")
        if toolModeForFreshConfig != nil, configuration.servers.isEmpty {
            lines.append("tool mode search: clients see only rv_search_tools and rv_call_tool")
        }
        lines.append("every tool asks for approval until you allow it (mcp.json \"tools\" or `rv mcp approve <id> --always`)")
        lines.append("next: `rv mcp setup --host \(host.rawValue)` routes the host through rv")
        return .success(lines.joined(separator: "\n") + "\n")
    }

    /// One-command onboarding: import the host's servers, then route the host
    /// through `rv mcp serve`. The import asks for presence once; setup asks
    /// nothing, so the whole flow needs a single confirmation.
    static func onboard(
        host: MCPHost, names: [String], project: URL?, dryRun: Bool,
        rvPath: String, environment: MCPEnvironment,
        show: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> Result<String, CommandFailure> {
        let imported: String
        switch await importServers(
            host: host, names: names, project: project, dryRun: dryRun,
            environment: environment, toolModeForFreshConfig: .search, show: show)
        {
        case .failure(let failure): return .failure(failure)
        case .success(let text): imported = text
        }
        if dryRun {
            return .success(imported + "dry run: setup not run\n")
        }
        switch setup(
            host: host, names: names, project: project, undo: false, rvPath: rvPath,
            environment: environment)
        {
        case .failure(let failure):
            return .failure(CommandFailure(imported + "setup failed: \(failure.message)"))
        case .success(let routed):
            return .success(imported + routed)
        }
    }

    /// What the device owner sees before secrets are stored or mcp.json is signed.
    /// Every literal env value, header, argument, description, writable path,
    /// tool glob, and secret binding is listed. Controls are escaped so a
    /// terminal cannot erase the password. Classified secrets stay in the
    /// Keychain and appear here only as names.
    /// Nothing in the plan is signed unless the review the device owner sees
    /// contains each value in the same spelling the terminal will show.
    static func reviewShowsEveryLiteral(_ plan: MCPImportPlan, _ review: String) -> Bool {
        guard reviewConceals(review) == false else { return false }
        let lines = Set(review.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
        for server in plan.servers where reviewLists(server, lines: lines, review: review) == false {
            return false
        }
        return true
    }

    /// Nothing is signed unless the trust review lists every value that the
    /// original bytes contain, in the spelling the terminal will show.
    static func trustReviewShowsEveryLiteral(_ configuration: MCPConfiguration, _ review: String) -> Bool {
        guard reviewConceals(review) == false else { return false }
        let lines = Set(review.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
        for server in configuration.servers where reviewLists(server, lines: lines, review: review) == false {
            return false
        }
        return true
    }

    private static func reviewedServerLines(_ server: MCPServerDefinition) -> [String] {
        var lines: [String] = []
        if let remote = server.remote {
            let transport = remote.transport == .sse ? "legacy SSE" : "streamable HTTP"
            let shown = MCPRedaction.url(remote.url.absoluteString)
            let address = shown.leaked ? shown.display : remote.url.absoluteString
            lines.append("  \(server.name): \(visible(address)) (remote, \(transport))")
            for name in remote.headers.keys.sorted() {
                let value = remote.headers[name] ?? ""
                lines.append("    \(name): \(visible(value))")
                let secrets = MCPSecretReference.names(in: value) ?? []
                if secrets.isEmpty == false {
                    lines.append("    \(name) → secret \(secrets.map(visible).joined(separator: ", "))")
                }
            }
        } else {
            lines.append("  \(server.name): \(visible(server.command))")
            lines.append("    command: \(visible(server.command))")
        }
        if let description = server.description {
            lines.append("    description: \(visible(description))")
        }
        for name in server.environment.keys.sorted() {
            lines.append("    \(name)=\(visible(server.environment[name] ?? ""))")
        }
        for variable in server.secrets.keys.sorted() {
            if let name = server.secrets[variable] {
                lines.append("    \(variable) → secret \(visible(name))")
            }
        }
        for arg in server.args {
            lines.append("    argument: \(visible(arg))")
            for name in MCPSecretReference.names(in: arg) ?? [] {
                lines.append("    argument → secret \(visible(name))")
            }
        }
        for glob in server.tools.allow { lines.append("    allow \(visible(glob))") }
        for glob in server.tools.ask { lines.append("    ask \(visible(glob))") }
        for glob in server.tools.deny { lines.append("    deny \(visible(glob))") }
        for path in server.sandbox?.writable ?? [] {
            lines.append("    writable: \(visible(path))")
        }
        for host in server.sandbox?.hosts ?? [] {
            lines.append("    host \(visible(host))")
        }
        return lines
    }

    private static func reviewLists(
        _ server: MCPServerDefinition, lines: Set<String>, review: String
    ) -> Bool {
        if let remote = server.remote {
            let shown = MCPRedaction.url(remote.url.absoluteString)
            if shown.leaked { return false }
            if review.contains(visible(remote.url.absoluteString)) == false { return false }
            for (name, value) in remote.headers where lines.contains("    \(name): \(visible(value))") == false {
                return false
            }
        } else if lines.contains("    command: \(visible(server.command))") == false {
            return false
        }
        if let description = server.description, lines.contains("    description: \(visible(description))") == false {
            return false
        }
        for (name, value) in server.environment where lines.contains("    \(name)=\(visible(value))") == false {
            return false
        }
        for (variable, name) in server.secrets where lines.contains("    \(variable) → secret \(visible(name))") == false {
            return false
        }
        for arg in server.args where lines.contains("    argument: \(visible(arg))") == false {
            return false
        }
        for glob in server.tools.allow where lines.contains("    allow \(visible(glob))") == false { return false }
        for glob in server.tools.ask where lines.contains("    ask \(visible(glob))") == false { return false }
        for glob in server.tools.deny where lines.contains("    deny \(visible(glob))") == false { return false }
        for path in server.sandbox?.writable ?? [] where lines.contains("    writable: \(visible(path))") == false {
            return false
        }
        for host in server.sandbox?.hosts ?? [] where lines.contains("    host \(visible(host))") == false {
            return false
        }
        return true
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
            MCPList.self, MCPCheck.self, MCPImportCommand.self, MCPSetupCommand.self, MCPOnboard.self, MCPServe.self,
            MCPPending.self, MCPApprove.self, MCPDeny.self, MCPTrust.self, MCPConnect.self,
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
            ctx.writeStdout(ctx.explicitRobot ? MCPRun.robotJSON(report) : MCPRun.listText(report, home: environment.home))
        }
    }
}

struct MCPCheck: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Exit 1 when any MCP server bypasses rv, is unreviewed, is blocked, or has no usable sandbox.")

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
            let text = ctx.explicitRobot ? MCPRun.robotJSON(report) : MCPRun.checkText(report, home: environment.home)
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
        var seen = Set<String>()
        let names = (servers.isEmpty ? configuration.servers.map(\.name) : servers).filter { seen.insert($0).inserted }
        guard names.isEmpty == false else { try fail("mcp.json defines no servers; see `rv mcp import`") }
        let secrets: SecretsConfiguration
        switch SecretsConfiguration.load(configDirectory: environment.configDirectory) {
        case .failure(let error): try fail(error.message)
        case .success(let loaded): secrets = loaded
        }
        let planned: [(MCPGatewayCore.Upstream, MCPUpstreamConnection)]
        switch MCPRun.upstreamLaunches(
            names: names, configuration: configuration, environment: environment, secrets: secrets,
            resolver: .live(home: home.rawValue),
            sandbox: MCPSandbox.apply(
                configDirectory: environment.configDirectory, home: environment.home,
                denied: DenialAudit.forwarder(configDirectory: environment.configDirectory)))
        {
        case .failure(let failure): try fail(failure.message)
        case .success(let result): planned = result
        }
        let configDirectory = environment.configDirectory
        let log: @Sendable (String) -> Void = { message in
            FileHandle.standardError.write(Data("rv mcp: \(message)\n".utf8))
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
            event: { MCPRun.auditOrLog($0, configDirectory: configDirectory) },
            log: log)
        runtime.run()
        MCPSandbox.stopProxies()
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
        ctx.writeStdout(ctx.explicitRobot ? MCPRun.robotJSON(rows) : MCPRun.pendingText(rows))
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
            try ctx.fail("rv mcp deny: \(MCPRun.denyMissingIDMessage(id))\n")
        }
        ctx.writeStdout(MCPRun.deniedLine(server: request.server, tool: request.tool))
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
    @Flag(help: "Show what would change; write nothing.") var dryRun = false

    func run() async throws {
        let ctx = CommandContext.current(command: "mcp import", json: false, robot: false, plain: true, noColor: true)
        let environment = MCPEnvironment.live(home: try ctx.requireHome())
        switch await MCPRun.importServers(
            host: host, names: servers, project: MCPRun.projectURL(project), dryRun: dryRun,
            environment: environment, show: { ctx.writeStdout($0) })
        {
        case .failure(let failure): try ctx.fail("rv mcp import: \(failure.message)\n")
        case .success(let text): ctx.writeStdout(text)
        }
    }
}

struct MCPOnboard: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "onboard",
        abstract: "Import a host's MCP servers and route the host through rv in one step.")

    @Option(help: "Host to onboard: \(MCPHost.allCases.map(\.rawValue).joined(separator: ", ")).") var host: MCPHost
    @Option(name: .customLong("server"), help: "Only this server (repeatable).") var servers: [String] = []
    @Option(help: "Project directory for project-scoped configs. Default: current directory.") var project: String?
    @Flag(help: "Show what would change; write nothing.") var dryRun = false
    @Option(help: "rv path the host should launch. Default: this rv.") var rvPath: String?

    func run() async throws {
        let ctx = CommandContext.current(command: "mcp onboard", json: false, robot: false, plain: true, noColor: true)
        let environment = MCPEnvironment.live(home: try ctx.requireHome())
        let path = rvPath ?? MCPRun.rvExecutablePath(environment: environment.processEnvironment)
        switch await MCPRun.onboard(
            host: host, names: servers, project: MCPRun.projectURL(project),
            dryRun: dryRun, rvPath: path, environment: environment, show: { ctx.writeStdout($0) })
        {
        case .failure(let failure): try ctx.fail("rv mcp onboard: \(failure.message)\n")
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

/// Coalesces egress-denial audit: every refused CONNECT used to be one
/// fsync'd audit append, so any local process that found the proxy port
/// could force unbounded audit growth. One denial per (server, host, port,
/// reason) is audited per minute; repeats are counted into the next entry.
enum DenialAudit {
    static func forwarder(configDirectory: URL) -> @Sendable (String, EgressProxyDenial) -> Void {
        let state = Mutex<[String: (last: Date, suppressed: Int)]>([:])
        return { server, denial in
            let key = "\(server)\u{0}\(denial.host)\u{0}\(denial.port)\u{0}\(denial.reason.rawValue)"
            let suppressed: Int? = state.withLock { table in
                if let entry = table[key], denial.recordedAt.timeIntervalSince(entry.last) < 60 {
                    table[key] = (entry.last, entry.suppressed + 1)
                    return nil
                }
                let count = table[key]?.suppressed ?? 0
                // Host is attacker-chosen: bound the table or it grows with
                // distinct names for the life of the serve process.
                if table[key] == nil, table.count >= 512 {
                    table = table.filter { denial.recordedAt.timeIntervalSince($0.value.last) < 60 }
                    if table.count >= 512 { return 0 }
                }
                table[key] = (denial.recordedAt, 0)
                return count
            }
            guard let suppressed else { return }
            var detail = ["server": server]
            if suppressed > 0 { detail["suppressed"] = "\(suppressed)" }
            MCPRun.auditOrLog(
                AuditEvent(
                    time: denial.recordedAt, kind: .egressDenied, decision: .denied,
                    subject: "\(denial.host):\(denial.port)",
                    reason: denial.reason.rawValue, source: "rv mcp serve", detail: detail),
                configDirectory: configDirectory)
        }
    }
}
