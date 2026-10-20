#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import ArgumentParser
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RVDomain
import RVHistory
import RVIsolation
import RVMCP
import RVPolicy

/// HTTP seam for `rv audit forward`.
struct AuditForwardTransport: Sendable {
    /// Status code, or a transport error message.
    var post: @Sendable (_ url: URL, _ headers: [String: String], _ body: Data) -> Result<Int, CommandFailure>

    static let live = AuditForwardTransport { url, headers, body in
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("rv/\(ProductVersion.semver)", forHTTPHeaderField: "User-Agent")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        switch DirectHTTP.send(request) {
        case .status(let status): return .success(status)
        case .failed(let message): return .failure(CommandFailure(message))
        }
    }
}

enum AuditForwardRun {
    enum Format: String, CaseIterable, ExpressibleByArgument {
        case ocsf
        case rv
    }

    struct Options {
        var url: URL
        var headers: [String: String] = [:]
        var format: Format = .ocsf
        var batchSize = 500
    }

    /// https anywhere; plain http only to this machine. No userinfo, fragment,
    /// path secret, or query secret (including a query value that is a URL
    /// with userinfo). `--install` copies `--to` into a plist and a crontab
    /// line, so a refusal names the problem and not the secret.
    static func destination(_ text: String) -> Result<URL, CommandFailure> {
        guard let url = URL(string: text),
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(), let rawHost = components.host, rawHost.isEmpty == false
        else {
            return .failure("--to must be an absolute URL")
        }
        let host = rawHost.lowercased()
        if components.user != nil || components.password != nil {
            return .failure("--to must not include a username or password")
        }
        if components.fragment != nil {
            return .failure("--to must not have a fragment")
        }
        if MCPRedaction.hostCarriesSecret(rawHost) || MCPRedaction.hostCarriesSecret(components.percentEncodedHost ?? "")
            || MCPRedaction.authorityCarriesPassword(text)
        {
            return .failure("--to must not carry a secret in its host")
        }
        if MCPRedaction.pathCarriesSecret(components.percentEncodedPath) {
            return .failure("--to must not carry a secret in its path")
        }
        let rawQuery = components.percentEncodedQuery ?? MCPRedaction.rawQuery(text)
        if MCPRedaction.queryCarriesSecret(encoded: rawQuery, items: components.queryItems)
            || MCPRedaction.rawQuery(text).map({ MCPRedaction.queryCarriesSecret(encoded: $0, items: nil) }) == true
        {
            return .failure("--to must not carry a secret in its query")
        }
        // `user:/su?password@host` is split into a path and a query before those checks.
        if components.user == nil, components.password == nil, MCPRedaction.containsUserinfoSpelling(text) {
            return .failure("--to must not carry a secret in its path")
        }
        if scheme == "https" { return .success(url) }
        if scheme == "http", ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host) { return .success(url) }
        return .failure("audit forwarding needs https (plain http is allowed only to localhost)")
    }

    static func stateDirectory(_ configDirectory: URL) -> URL {
        configDirectory.appendingPathComponent("audit-forward", isDirectory: true)
    }

    static func cursorURL(_ configDirectory: URL, destination: URL) -> URL {
        let key = String(RVDigest.sha256Hex(Array(destination.absoluteString.utf8)).prefix(16))
        return stateDirectory(configDirectory).appendingPathComponent("\(key).json")
    }

    static func loadCursor(_ url: URL) -> Result<AuditCursor?, CommandFailure> {
        switch OwnerOnlyFile.read(url, maximumBytes: 1024 * 1024) {
        case .success(nil): return .success(nil)
        case .success(let data?):
            guard let cursor = try? JSONDecoder().decode(AuditCursor.self, from: data) else {
                return .failure(CommandFailure("\(DisplayedText.field(url.path)) is not a forward cursor; delete it to start over"))
            }
            return .success(cursor)
        case .failure(.unsafe(let reason)): return .failure(CommandFailure("\(DisplayedText.field(url.path)): \(reason)"))
        case .failure: return .failure(CommandFailure("cannot read \(DisplayedText.field(url.path))"))
        }
    }

    static func saveCursor(_ cursor: AuditCursor, to url: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(cursor) else { return false }
        return OwnerOnlyFile.write(data, to: url)
    }

    static func body(_ events: [AuditEvent], format: Format, hostName: String) -> Data? {
        switch format {
        case .ocsf:
            let objects = events.map { AuditOCSF.object($0, hostName: hostName) }
            return try? JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys, .withoutEscapingSlashes])
        case .rv:
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try? encoder.encode(events)
        }
    }

    /// Start forwarding at the current end of every ledger.
    static func startFromNow(options: Options, configDirectory: URL) -> Result<String, CommandFailure> {
        let url = cursorURL(configDirectory, destination: options.url)
        guard saveCursor(AuditLedger(configDirectory: configDirectory).endCursor(), to: url) else {
            return .failure("could not write \(DisplayedText.field(url.path))")
        }
        return .success("forward cursor for \(options.url.absoluteString) set to now; older events will not be sent\n")
    }

    /// One pass: send everything after the cursor in batches, committing the
    /// cursor after each 2xx. At-least-once: a crash between POST and commit resends.
    static func forward(
        options: Options, configDirectory: URL, hostName: String, transport: AuditForwardTransport
    ) -> Result<String, CommandFailure> {
        let cursorFile = cursorURL(configDirectory, destination: options.url)
        guard let lock = FileLock(stateDirectory(configDirectory).appendingPathComponent(cursorFile.lastPathComponent + ".lock")) else {
            return .failure("another `rv audit forward` to this URL is running")
        }
        defer { lock.release() }
        var cursor: AuditCursor
        switch loadCursor(cursorFile) {
        case .failure(let failure): return .failure(failure)
        case .success(let loaded): cursor = loaded ?? AuditCursor()
        }
        // Never forward past a break: the cursor would commit beyond it and
        // the gap would look intentional off-machine. Refuse loudly instead.
        switch AuditChain.verify(fileURL: AuditLog.fileURL(configDirectory: configDirectory)) {
        case .failure(let error):
            return .failure(CommandFailure("audit chain cannot be checked (\(error.message)); refusing to forward"))
        case .success(let report) where report.isIntact == false && report.firstBreak?.reason == "no prev on any line":
            // A wholly pre-chain (legacy) file has no head to protect and
            // no self-recovery: it anchors at its next append, but the
            // backlog must not deadlock until then.
            FileHandle.standardError.write(Data("rv audit forward: audit.jsonl predates the hash chain; forwarding without a chain head\n".utf8))
        case .success(let report) where report.isIntact == false:
            let broken = report.firstBreak
            return .failure(CommandFailure(
                "audit chain break at line \(broken?.line ?? 0) (\(broken?.reason ?? "unknown")); refusing to forward — run `rv audit verify`"))
        case .success:
            break
        }
        let ledger = AuditLedger(configDirectory: configDirectory)
        var sent = 0
        var batches = 0
        while true {
            let (events, next) = ledger.events(after: cursor, limit: options.batchSize)
            if events.isEmpty {
                if next != cursor, saveCursor(next, to: cursorFile) == false {
                    return .failure("could not write \(DisplayedText.field(cursorFile.path))")
                }
                break
            }
            guard let payload = body(events, format: options.format, hostName: hostName) else {
                return .failure("could not encode \(events.count) events")
            }
            switch transport.post(options.url, options.headers, payload) {
            case .failure(let failure):
                return .failure(CommandFailure(
                    "sent \(sent) events, then: \(failure.message); the cursor is kept, rerun to retry"))
            // 3xx is a failed batch. The live transport does not follow
            // redirects, so the cursor stays put instead of committing a hop.
            case .success(let status) where (200..<300).contains(status) == false:
                return .failure(CommandFailure(
                    "sent \(sent) events, then HTTP \(status); the cursor is kept, rerun to retry"))
            case .success:
                guard saveCursor(next, to: cursorFile) else {
                    return .failure("could not write \(DisplayedText.field(cursorFile.path))")
                }
                cursor = next
                sent += events.count
                batches += 1
            }
        }
        if sent == 0 { return .success("nothing new to forward to \(options.url.absoluteString)\n") }
        return .success("forwarded \(sent) events in \(batches) batch\(batches == 1 ? "" : "es") to \(options.url.absoluteString)\n")
    }

    /// `${secret:NAME}` in header values, resolved through secrets.json.
    static func resolveHeaders(
        _ headers: [String: String], secrets: () -> Result<SecretsConfiguration, SecretsConfigurationError>,
        resolver: SecretResolver, managed: ManagedPolicyState = .none
    ) -> Result<[String: String], CommandFailure> {
        let names = Set(headers.values.flatMap { MCPSecretReference.names(in: $0) ?? [] })
        guard names.isEmpty == false else { return .success(headers) }
        // This path sends values off-host: an invalid or forbidding policy
        // fails closed here regardless of how the destination was chosen.
        if let reason = managed.invalidReason {
            return .failure(CommandFailure("organization policy is invalid: \(reason)"))
        }
        let configuration: SecretsConfiguration
        switch secrets() {
        case .failure(let error): return .failure(CommandFailure(error.message))
        case .success(let loaded): configuration = loaded
        }
        var values: [String: String] = [:]
        for name in names.sorted() {
            guard let secret = configuration.secret(named: name) else {
                return .failure(CommandFailure("header secret \(DisplayedText.field(name)) is not defined in secrets.json"))
            }
            if managed.policy?.allowsSecretSource(secret.source.kind) == false {
                return .failure(CommandFailure(
                    "organization policy: \(name) uses a \(secret.source.kind) source, which is not allowed"))
            }
            switch resolver.resolve(secret.source) {
            case .failure(let error): return .failure(CommandFailure("header secret \(DisplayedText.field(name)): \(error.message)"))
            case .success(let value):
                guard let text = String(validating: value.revealed(), as: UTF8.self) else {
                    return .failure(CommandFailure("header secret \(DisplayedText.field(name)) is not text"))
                }
                guard text.contains("\r") == false, text.contains("\n") == false, text.contains("\0") == false else {
                    return .failure(CommandFailure("header secret \(DisplayedText.field(name)) contains a line break"))
                }
                values[name] = text
            }
        }
        return .success(headers.mapValues { MCPSecretReference.substitute($0, values: values) })
    }

    static func parseHeaders(_ raw: [String]) -> Result<[String: String], CommandFailure> {
        var headers: [String: String] = [:]
        for item in raw {
            guard let equals = item.firstIndex(of: "="), equals != item.startIndex else {
                return .failure(CommandFailure("--header takes NAME=VALUE, got \(DisplayedText.field(item))"))
            }
            headers[String(item[..<equals])] = String(item[item.index(after: equals)...])
        }
        return .success(headers)
    }
}

/// Non-blocking exclusive flock; nil when another holder has it.
struct FileLock {
    let fd: Int32

    init?(_ url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        self.fd = fd
    }

    func release() {
        flock(fd, LOCK_UN)
        close(fd)
    }
}

struct AuditForward: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "forward",
        abstract: "Send new audit events to a SIEM endpoint (one pass; run it from cron or launchd).")

    @Option(help: "Endpoint URL. Default: audit.forward in the organization policy.") var to: String?
    @Option(name: .customLong("header"), help: "NAME=VALUE request header (repeatable); VALUE may use ${secret:NAME}.")
    var headers: [String] = []
    @Option(help: "Payload: ocsf or rv.") var format: AuditForwardRun.Format = .ocsf
    @Option(help: "Events per POST (1-5000).") var batchSize = 500
    @Flag(help: "Start from the current end of the audit trail instead of sending history.") var fromNow = false
    @Flag(help: "Write a user LaunchAgent that runs this forward every 5 minutes, and print a LaunchDaemon template.")
    var install = false

    /// These options again, for the scheduled run.
    var scheduledArguments: [String] {
        var arguments: [String] = []
        if let to { arguments += ["--to", to] }
        for header in headers { arguments += ["--header", header] }
        if format != .ocsf { arguments += ["--format", format.rawValue] }
        if batchSize != 500 { arguments += ["--batch-size", String(batchSize)] }
        return arguments
    }

    func run() throws {
        let ctx = CommandContext.current(command: "audit forward", json: false, robot: false, plain: true, noColor: true)
        let home = try ctx.requireHome()
        let configDirectory = RVPolicyPaths.configDirectory(home: home)
        guard (1...5_000).contains(batchSize) else { try ctx.fail("rv audit forward: --batch-size must be 1-5000\n") }
        let managed = ManagedRun.installed(home: home)
        if let reason = managed.invalidReason, to == nil {
            try ctx.fail("rv audit forward: organization policy is invalid: \(reason)\n")
        }
        guard let target = to ?? managed.policy?.auditForward?.url else {
            try ctx.fail("rv audit forward: pass --to URL (no audit.forward in the organization policy)\n")
        }
        var headerMap = to == nil ? managed.policy?.auditForward?.headers ?? [:] : [:]
        switch AuditForwardRun.parseHeaders(headers) {
        case .failure(let failure): try ctx.fail("rv audit forward: \(failure.message)\n")
        case .success(let parsed): headerMap.merge(parsed) { _, new in new }
        }
        let url: URL
        switch AuditForwardRun.destination(target) {
        case .failure(let failure): try ctx.fail("rv audit forward: \(failure.message)\n")
        case .success(let parsed): url = parsed
        }
        var options = AuditForwardRun.Options(url: url, format: format, batchSize: batchSize)
        if install {
            if fromNow { try ctx.fail("rv audit forward: --install and --from-now cannot be combined; run --from-now once first\n") }
            guard let userName = AuditForwardInstall.accountName() else {
                try ctx.fail("rv audit forward: could not read the account name from the passwd entry\n")
            }
            let plan = AuditForwardInstall.Plan(
                home: URL(fileURLWithPath: home.rawValue, isDirectory: true), rvExecutable: MCPExecutable.currentPath(),
                userID: getuid(), userName: userName, forwardArguments: scheduledArguments)
            #if os(macOS)
            switch AuditForwardInstall.install(plan) {
            case .failure(let failure): try ctx.fail("rv audit forward: \(failure.message)\n")
            case .success(let text): ctx.writeStdout(text)
            }
            return
            #else
            if let header = AuditForwardInstall.plaintextHeader(plan.forwardArguments) {
                try ctx.fail("rv audit forward: header \(header) must use ${secret:NAME} in a scheduled command\n")
            }
            try ctx.fail("rv audit forward: " + AuditForwardInstall.cronHint(plan))
            #endif
        }
        if fromNow {
            switch AuditForwardRun.startFromNow(options: options, configDirectory: configDirectory) {
            case .failure(let failure): try ctx.fail("rv audit forward: \(failure.message)\n")
            case .success(let text): ctx.writeStdout(text)
            }
            return
        }
        switch AuditForwardRun.resolveHeaders(
            headerMap, secrets: { SecretsConfiguration.load(configDirectory: configDirectory) },
            resolver: .live(home: home.rawValue), managed: managed)
        {
        case .failure(let failure): try ctx.fail("rv audit forward: \(failure.message)\n")
        case .success(let resolved): options.headers = resolved
        }
        switch AuditForwardRun.forward(
            options: options, configDirectory: configDirectory, hostName: ProcessInfo.processInfo.hostName,
            transport: .live)
        {
        case .failure(let failure): try ctx.fail("rv audit forward: \(failure.message)\n")
        case .success(let text): ctx.writeStdout(text)
        }
    }
}
