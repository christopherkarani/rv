#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A resolved secret. Never prints its contents.
public struct SecretValue: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let maximumBytes = 16 * 1024

    let bytes: [UInt8]

    init?(_ bytes: [UInt8]) {
        guard bytes.isEmpty == false, bytes.count <= Self.maximumBytes, bytes.contains(0) == false else {
            return nil
        }
        self.bytes = bytes
    }

    init?(_ text: String) {
        self.init(Array(text.utf8))
    }

    var text: String? {
        String(bytes: bytes, encoding: .utf8)
    }

    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
}

public enum SecretResolutionError: Error, Sendable, Equatable {
    case notFound(String)
    case providerUnavailable(String)
    case failed(String)
    case timedOut(String)
    case invalidValue(String)

    public var message: String {
        switch self {
        case .notFound(let detail): "not found: \(detail)"
        case .providerUnavailable(let detail): "provider unavailable: \(detail)"
        case .failed(let detail): "provider failed: \(detail)"
        case .timedOut(let detail): "timed out: \(detail)"
        case .invalidValue(let detail): "unusable value: \(detail)"
        }
    }
}

/// Host-side reads. Tests inject fakes; production uses `.live`.
public struct SecretResolver: Sendable {
    public var resolve: @Sendable (SecretSource) -> Result<SecretValue, SecretResolutionError>

    public init(resolve: @escaping @Sendable (SecretSource) -> Result<SecretValue, SecretResolutionError>) {
        self.resolve = resolve
    }

    public static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String
    ) -> SecretResolver {
        SecretResolver { source in
            switch source {
            case .keychain(let service, let account):
                guard let data = KeychainReader.live.read(service, account) else {
                    return .failure(.notFound("keychain item \(service) / \(account)"))
                }
                return value(Array(data), from: "keychain item \(service) / \(account)")
            case .hostEnvironment(let variable):
                guard let text = environment[variable] else {
                    return .failure(.notFound("host variable \(variable) is not set"))
                }
                return value(Array(text.utf8), from: "host variable \(variable)")
            case .onePassword(let reference):
                return SecretCommandProviders.onePassword(reference, environment: environment)
            case .vault(let path, let field, let address):
                return SecretVaultProvider.read(
                    path: path, field: field, address: address, environment: environment, home: home)
            case .awsSecretsManager(let secretID, let field, let region):
                return SecretCommandProviders.aws(
                    secretID: secretID, field: field, region: region, environment: environment)
            }
        }
    }

    static func value(_ bytes: [UInt8], from origin: String) -> Result<SecretValue, SecretResolutionError> {
        var trimmed = bytes
        while let last = trimmed.last, last == 10 || last == 13 { trimmed.removeLast() }
        guard let value = SecretValue(trimmed) else {
            return .failure(.invalidValue("\(origin) is empty, larger than 16 KiB, or contains NUL"))
        }
        return .success(value)
    }
}

enum SecretCommandProviders {
    static func onePassword(
        _ reference: String,
        environment: [String: String]
    ) -> Result<SecretValue, SecretResolutionError> {
        guard let op = executable("op", environment: environment) else {
            return .failure(.providerUnavailable("1Password CLI `op` is not installed"))
        }
        guard let run = BoundedProcess.run(op, ["read", "--no-newline", reference], environment: environment) else {
            return .failure(.timedOut("1Password read of \(reference)"))
        }
        guard run.status == 0 else {
            return .failure(.failed("op read \(reference) exited \(run.status): \(run.stderrSummary)"))
        }
        return SecretResolver.value(run.stdout, from: reference)
    }

    static func aws(
        secretID: String,
        field: String?,
        region: String?,
        environment: [String: String]
    ) -> Result<SecretValue, SecretResolutionError> {
        guard let aws = executable("aws", environment: environment) else {
            return .failure(.providerUnavailable("AWS CLI `aws` is not installed"))
        }
        var arguments = [
            "secretsmanager", "get-secret-value", "--secret-id", secretID,
            "--query", "SecretString", "--output", "text",
        ]
        if let region { arguments += ["--region", region] }
        guard let run = BoundedProcess.run(aws, arguments, environment: environment) else {
            return .failure(.timedOut("AWS Secrets Manager read of \(secretID)"))
        }
        guard run.status == 0 else {
            return .failure(.failed("aws secretsmanager \(secretID) exited \(run.status): \(run.stderrSummary)"))
        }
        guard let field else { return SecretResolver.value(run.stdout, from: secretID) }
        guard let object = try? JSONSerialization.jsonObject(with: Data(run.stdout)) as? [String: Any],
            let picked = object[field] as? String
        else { return .failure(.notFound("field \(field) in \(secretID)")) }
        return SecretResolver.value(Array(picked.utf8), from: "\(secretID).\(field)")
    }

    static func executable(_ name: String, environment: [String: String]) -> String? {
        let searched = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        for directory in searched where directory.hasPrefix("/") {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if access(candidate, X_OK) == 0 { return candidate }
        }
        return nil
    }
}

enum SecretVaultProvider {
    static func read(
        path: String,
        field: String,
        address: URL?,
        environment: [String: String],
        home: String,
        timeout: TimeInterval = 15
    ) -> Result<SecretValue, SecretResolutionError> {
        guard let base = address ?? environment["VAULT_ADDR"].flatMap(vaultAddress) else {
            return .failure(.providerUnavailable("VAULT_ADDR is not set to an https (or loopback http) URL"))
        }
        let token = environment["VAULT_TOKEN"]
            ?? (try? String(contentsOfFile: (home as NSString).appendingPathComponent(".vault-token"), encoding: .utf8))
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), token.isEmpty == false else {
            return .failure(.providerUnavailable("no Vault token in VAULT_TOKEN or ~/.vault-token"))
        }
        guard let url = URL(string: base.absoluteString + "/v1/" + path) else {
            return .failure(.failed("Vault URL for \(path)"))
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(token, forHTTPHeaderField: "X-Vault-Token")
        if let namespace = environment["VAULT_NAMESPACE"], namespace.isEmpty == false {
            request.setValue(namespace, forHTTPHeaderField: "X-Vault-Namespace")
        }
        guard let (status, body) = BlockingHTTP.send(request, timeout: timeout + 1) else {
            return .failure(.timedOut("Vault read of \(path)"))
        }
        if status == 404 { return .failure(.notFound("Vault path \(path)")) }
        guard status == 200 else { return .failure(.failed("Vault returned HTTP \(status) for \(path)")) }
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let data = object["data"] as? [String: Any]
        else { return .failure(.failed("Vault response for \(path) is not JSON")) }
        let fields = (data["data"] as? [String: Any]) ?? data
        guard let picked = fields[field] as? String else {
            return .failure(.notFound("field \(field) at Vault path \(path)"))
        }
        return SecretResolver.value(Array(picked.utf8), from: "\(path)#\(field)")
    }

    static func vaultAddress(_ text: String) -> URL? {
        if let https = SecretsDecoding.httpsOrigin(text) { return https }
        guard let components = URLComponents(string: text), components.scheme == "http",
            let host = components.host, ["127.0.0.1", "localhost", "::1"].contains(host),
            components.path.isEmpty || components.path == "/"
        else { return nil }
        var normalized = components
        normalized.path = ""
        return normalized.url
    }
}

/// Synchronous HTTPS for host-side provider reads. No cookies, cache, or redirects.
enum BlockingHTTP {
    static func send(_ request: URLRequest, timeout: TimeInterval) -> (Int, Data)? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        let delegate = NoRedirects()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let done = DispatchSemaphore(value: 0)
        let box = ResultBox()
        session.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse {
                box.set((http.statusCode, data ?? Data()))
            }
            done.signal()
        }.resume()
        guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        return box.value
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: (Int, Data)?
        func set(_ value: (Int, Data)) { lock.lock(); stored = value; lock.unlock() }
        var value: (Int, Data)? { lock.lock(); defer { lock.unlock() }; return stored }
    }
}

/// Runs a provider CLI with a deadline and bounded output.
enum BoundedProcess {
    struct Outcome {
        var status: Int32
        var stdout: [UInt8]
        var stderr: [UInt8]

        var stderrSummary: String {
            let text = String(decoding: stderr.prefix(200), as: UTF8.self)
            return text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        }
    }

    static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String],
        timeout: TimeInterval = 30
    ) -> Outcome? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let stdout = Collector()
        let stderr = Collector()
        out.fileHandleForReading.readabilityHandler = { stdout.append($0.availableData) }
        err.fileHandleForReading.readabilityHandler = { stderr.append($0.availableData) }
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(10_000) }
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
            return nil
        }
        stdout.append(out.fileHandleForReading.readDataToEndOfFile())
        stderr.append(err.fileHandleForReading.readDataToEndOfFile())
        return Outcome(status: process.terminationStatus, stdout: stdout.bytes, stderr: stderr.bytes)
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var data: [UInt8] = []
        func append(_ chunk: Data) {
            lock.lock()
            if data.count < 1_048_576 { data.append(contentsOf: chunk.prefix(1_048_576 - data.count)) }
            lock.unlock()
        }
        var bytes: [UInt8] { lock.lock(); defer { lock.unlock() }; return data }
    }
}
