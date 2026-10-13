#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation
import RVHistory
import RVIsolation

/// How to start one upstream server process.
public struct MCPUpstreamLaunch: Sendable, Equatable {
    public var server: String
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String?

    public init(server: String, executable: String, arguments: [String], environment: [String: String], workingDirectory: String? = nil) {
        self.server = server
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }
}

public enum MCPLaunchError: Error, Sendable, Equatable {
    case unknownServer(String)
    case blocked(String)
    case secretUndefined(server: String, secret: String)
    case secretUnavailable(server: String, secret: String, reason: String)
    case sandbox(String)

    public var message: String {
        switch self {
        case .unknownServer(let name): "mcp.json has no server named \(name)"
        case .blocked(let name): "\(name) is blocked by mcp.json or organization policy"
        case .secretUndefined(let server, let secret): "\(server) uses secret \(secret), which secrets.json does not define"
        case .secretUnavailable(let server, let secret, let reason): "\(server) could not read secret \(secret): \(reason)"
        case .sandbox(let reason): "sandbox: \(reason)"
        }
    }
}

/// Turns `mcp.json` definitions into processes the runtime can start.
public enum MCPLaunchPlanner {
    /// `PATH` lookup happens in `/usr/bin/env` against the upstream's own environment.
    public static let envPath = "/usr/bin/env"

    public static func plan(
        servers names: [String],
        configuration: MCPConfiguration,
        secrets: SecretsConfiguration,
        resolver: SecretResolver,
        baseEnvironment: [String: String],
        sandbox: (MCPServerDefinition, MCPUpstreamLaunch) -> Result<MCPUpstreamLaunch, MCPLaunchError> = { .success($1) }
    ) -> Result<[(MCPGatewayCore.Upstream, MCPUpstreamLaunch)], MCPLaunchError> {
        var planned: [(MCPGatewayCore.Upstream, MCPUpstreamLaunch)] = []
        for name in names {
            if configuration.isBlocked(name) { return .failure(.blocked(name)) }
            guard let definition = configuration.server(named: name) else { return .failure(.unknownServer(name)) }
            if configuration.managed?.mcp.requireSandbox == true, definition.sandbox == nil {
                return .failure(.sandbox("organization policy requires a sandbox for \(name); add \"sandbox\" to its mcp.json entry"))
            }
            var environment = definition.sandbox == nil ? baseEnvironment : sandboxEnvironment(baseEnvironment)
            for (key, value) in definition.environment { environment[key] = value }
            var resolved: [String: String] = [:]
            let referenced = Set(definition.secrets.values).union(definition.args.flatMap { MCPSecretReference.names(in: $0) ?? [] })
            for secretName in referenced.sorted() {
                guard let secret = secrets.secret(named: secretName) else {
                    return .failure(.secretUndefined(server: name, secret: secretName))
                }
                if configuration.managed?.allowsSecretSource(secret.source.kind) == false {
                    return .failure(.secretUnavailable(
                        server: name, secret: secretName,
                        reason: "organization policy does not allow \(secret.source.kind) secrets"))
                }
                switch resolver.resolve(secret.source) {
                case .failure(let error):
                    return .failure(.secretUnavailable(server: name, secret: secretName, reason: error.message))
                case .success(let value):
                    guard let text = String(validating: value.revealed(), as: UTF8.self), text.contains("\0") == false else {
                        return .failure(.secretUnavailable(server: name, secret: secretName, reason: "not usable as text"))
                    }
                    resolved[secretName] = text
                }
            }
            for (variable, secretName) in definition.secrets { environment[variable] = resolved[secretName] }
            let args = definition.args.map { MCPSecretReference.substitute($0, values: resolved) }
            let values = resolved.keys.sorted().compactMap { key in resolved[key].map { (name: key, value: $0) } }
            let launch = MCPUpstreamLaunch(
                server: name, executable: envPath, arguments: [definition.command] + args, environment: environment)
            switch sandbox(definition, launch) {
            case .failure(let error): return .failure(error)
            case .success(let caged): planned.append((MCPGatewayCore.Upstream(definition: definition, secretValues: values), caged))
            }
        }
        return .success(planned)
    }

    /// Host environment a sandboxed upstream may see. Credentials the host
    /// already exported (`AWS_*`, `GITHUB_TOKEN`, …) are not copied.
    static func sandboxEnvironment(_ base: [String: String]) -> [String: String] {
        var kept: [String: String] = [:]
        for (key, value) in base where key == "PATH" || key == "HOME" || key == "TMPDIR" || key == "LANG" || key.hasPrefix("LC_") {
            kept[key] = value
        }
        return kept
    }
}

/// Runs a gateway core over real pipes: the client on `input`/`output`
/// (normally stdin/stdout), upstreams as child processes. One serial queue
/// owns the core; reader threads only parse lines and enqueue them.
public final class MCPGatewayRuntime: @unchecked Sendable {
    public static let maximumLineBytes = 64 * 1024 * 1024

    private var core: MCPGatewayCore
    private let launches: [MCPUpstreamLaunch]
    private let input: Int32
    private let output: Int32
    private let audit: @Sendable (MCPCallRecord) -> Void
    private let event: @Sendable (AuditEvent) -> Void
    private let log: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "rv.mcp.gateway")
    private var processes: [String: Process] = [:]
    private var upstreamInputs: [String: FileHandle] = [:]
    private let finished = DispatchSemaphore(value: 0)
    private var stopping = false

    public init(
        core: MCPGatewayCore,
        launches: [MCPUpstreamLaunch],
        input: Int32 = STDIN_FILENO,
        output: Int32 = STDOUT_FILENO,
        audit: @escaping @Sendable (MCPCallRecord) -> Void,
        event: @escaping @Sendable (AuditEvent) -> Void = { _ in },
        log: @escaping @Sendable (String) -> Void
    ) {
        self.core = core
        self.launches = launches
        self.input = input
        self.output = output
        self.audit = audit
        self.event = event
        self.log = log
    }

    /// Blocks until the client closes its input, then stops every upstream.
    public func run() {
        signal(SIGPIPE, SIG_IGN)
        queue.sync {
            var failed: [String] = []
            for launch in launches where spawn(launch) == false { failed.append(launch.server) }
            perform(core.start())
            for server in failed { perform(core.handle(.upstreamExited(server: server))) }
        }
        let clientInput = input
        Thread.detachNewThread { [self] in
            Self.readLines(clientInput) { line in
                let message: MCPGatewayInput = (try? JSONValue.parse(line)).map { .client($0) } ?? .clientUnparseable
                queue.async { self.perform(self.core.handle(message)) }
            }
            queue.async { self.finished.signal() }
        }
        finished.wait()
        queue.sync {
            stopping = true
            stopUpstreams()
        }
    }

    private func spawn(_ launch: MCPUpstreamLaunch) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        process.environment = launch.environment
        if let directory = launch.workingDirectory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.standardError
        do {
            try process.run()
        } catch {
            log("could not start MCP server \(launch.server): \(error.localizedDescription)")
            return false
        }
        processes[launch.server] = process
        upstreamInputs[launch.server] = stdin.fileHandleForWriting
        let server = launch.server
        let reader = stdout.fileHandleForReading
        Thread.detachNewThread { [self] in
            Self.readLines(reader.fileDescriptor) { line in
                guard let message = try? JSONValue.parse(line) else {
                    self.log("MCP server \(server) wrote a line that is not JSON; ignored")
                    return
                }
                queue.async { self.perform(self.core.handle(.upstream(server: server, message: message))) }
            }
            queue.async {
                guard self.stopping == false else { return }
                self.perform(self.core.handle(.upstreamExited(server: server)))
            }
        }
        return true
    }

    private func perform(_ outputs: [MCPGatewayOutput]) {
        for item in outputs {
            switch item {
            case .toClient(let message):
                Self.writeLine(output, message)
            case .toUpstream(let server, let message):
                if let handle = upstreamInputs[server] { Self.writeLine(handle.fileDescriptor, message) }
            case .audit(let record):
                audit(record)
            case .event(let item):
                event(item)
            case .log(let text):
                log(text)
            }
        }
    }

    private func stopUpstreams() {
        for handle in upstreamInputs.values { try? handle.close() }
        upstreamInputs = [:]
        let deadline = Date().addingTimeInterval(2)
        for process in processes.values {
            while process.isRunning, Date() < deadline { usleep(20_000) }
            if process.isRunning { process.terminate() }
        }
        let killDeadline = Date().addingTimeInterval(1)
        for process in processes.values {
            while process.isRunning, Date() < killDeadline { usleep(20_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        processes = [:]
    }

    static func writeLine(_ fd: Int32, _ message: JSONValue) {
        let bytes = Array((message.compactText + "\n").utf8)
        var written = 0
        while written < bytes.count {
            let n = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return write(fd, base + written, raw.count - written)
            }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return }
            written += n
        }
    }

    /// Calls `body` for each newline-terminated line (CR stripped). Lines
    /// over the cap are dropped whole. Returns at EOF or on a read error.
    static func readLines(_ fd: Int32, _ body: (Data) -> Void) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var line: [UInt8] = []
        var overflowing = false
        while true {
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return read(fd, base, raw.count)
            }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { break }
            var start = 0
            for index in 0..<n where buffer[index] == 0x0A {
                if overflowing == false {
                    line += buffer[start..<index]
                    if line.last == 0x0D { line.removeLast() }
                    if line.isEmpty == false { body(Data(line)) }
                }
                line.removeAll(keepingCapacity: true)
                overflowing = false
                start = index + 1
            }
            if overflowing == false {
                line += buffer[start..<n]
                if line.count > maximumLineBytes {
                    overflowing = true
                    line.removeAll()
                }
            }
        }
        if overflowing == false, line.isEmpty == false { body(Data(line)) }
    }
}
