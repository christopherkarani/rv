#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain

public struct DotenvEntry: Sendable, Equatable {
    public var name: String
    public var value: String
    public var line: Int

    public init(name: String, value: String, line: Int) {
        self.name = name
        self.value = value
        self.line = line
    }
}

/// A parsed `.env`. Duplicates and malformed lines are recorded, not thrown:
/// the resolver fails closed per-variable (duplicate) or per-file (malformed),
/// while import stays advisory and names what it skipped.
public struct DotenvParse: Sendable, Equatable {
    public var entries: [DotenvEntry] = []
    public var duplicates: Set<String> = []
    public var malformedLine: Int?
    public var lintNotes: [String] = []

    public func value(for name: String) -> String? {
        entries.first { $0.name == name }?.value
    }
}

public enum DotenvFileError: Error, Sendable, Equatable {
    case oversized
    case nul
    case notUTF8

    public var message: String {
        switch self {
        case .oversized: "dotenv file is larger than 256 KiB"
        case .nul: "dotenv file contains NUL"
        case .notUTF8: "dotenv file is not UTF-8"
        }
    }
}

/// Strict `.env` subset: `NAME=VALUE`, optional `export `, whitespace around
/// `=`, `#` comment only outside quotes and preceded by a space, single- and
/// double-quoted values read literally (no interpolation, no escapes). Values
/// stay in the file; rv reads them host-side at lease time.
public enum DotenvFile {
    public static let maximumBytes = 256 * 1024

    public static func parse(_ data: Data) -> Result<DotenvParse, DotenvFileError> {
        guard data.count <= maximumBytes else { return .failure(.oversized) }
        guard data.contains(0) == false else { return .failure(.nul) }
        guard var text = String(data: data, encoding: .utf8) else { return .failure(.notUTF8) }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        var parsed = DotenvParse()
        var seen = Set<String>()
        // Split on the LF scalar: "\r\n" is a single grapheme cluster, so a
        // Character-level split never sees the newline inside CRLF.
        let lines = text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String(String.UnicodeScalarView($0)) }
        for (offset, rawLine) in lines.enumerated() {
            var line = String(rawLine)
            if line.hasSuffix("\r") { line.removeLast() }
            let lineNumber = offset + 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            var body = trimmed
            if body.hasPrefix("export ") {
                body = String(body.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
            }
            guard let assignment = assignment(body) else {
                if parsed.malformedLine == nil { parsed.malformedLine = lineNumber }
                continue
            }
            if containsLint(assignment.value) {
                parsed.lintNotes.append(
                    "note \(assignment.name): value contains characters other tools expand; rv reads it literally (no interpolation or escapes)")
            }
            guard seen.insert(assignment.name).inserted else {
                parsed.duplicates.insert(assignment.name)
                continue
            }
            parsed.entries.append(DotenvEntry(name: assignment.name, value: assignment.value, line: lineNumber))
        }
        return .success(parsed)
    }

    private static func assignment(_ body: String) -> (name: String, value: String)? {
        guard let equals = body.firstIndex(of: "=") else { return nil }
        let name = String(body[..<equals]).trimmingCharacters(in: .whitespaces)
        guard SecretsConfiguration.isVariableName(name) else { return nil }
        let rawValue = String(body[body.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
        guard let first = rawValue.first, first == "\"" || first == "'" else {
            return (name, stripTrailingComment(rawValue).trimmingCharacters(in: .whitespaces))
        }
        guard rawValue.count >= 2, let close = rawValue.dropFirst().firstIndex(of: first) else { return nil }
        let quoted = String(rawValue[rawValue.index(after: rawValue.startIndex)..<close])
        let rest = String(rawValue[rawValue.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        guard rest.isEmpty || rest.hasPrefix("#") else { return nil }
        return (name, quoted)
    }

    private static func stripTrailingComment(_ value: String) -> String {
        var quote: Character?
        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#", index > value.startIndex, value[value.index(before: index)] == " " {
                return String(value[..<index])
            }
            index = value.index(after: index)
        }
        return value
    }

    private static func containsLint(_ value: String) -> Bool {
        value.contains("\\") || value.contains("$") || value.contains("`")
    }
}

/// One trust-checked read of a bound `.env`, with the `fstat` identity the
/// per-lease snapshot compares against.
public struct DotenvFileSnapshot: Sendable, Equatable {
    public var canonicalPath: String
    public var data: Data
    public var identity: String

    public init(canonicalPath: String, data: Data, identity: String) {
        self.canonicalPath = canonicalPath
        self.data = data
        self.identity = identity
    }
}

public enum DotenvReadError: Error, Sendable, Equatable {
    case missingFile(String)
    case untrustedFile(path: String, reason: String)
    case oversized(String)
    case unreadable(String)

    public var message: String {
        switch self {
        case .missingFile(let path): "dotenv file \(DisplayedText.field(path)) does not exist"
        case .untrustedFile(let path, let reason):
            "dotenv file \(DisplayedText.field(path)) is not safe to use: \(reason)"
        case .oversized(let path): "dotenv file \(DisplayedText.field(path)) is larger than 256 KiB"
        case .unreadable(let path): "dotenv file \(DisplayedText.field(path)) could not be read"
        }
    }

    var resolutionError: SecretResolutionError {
        switch self {
        case .missingFile: .notFound(message)
        case .untrustedFile, .unreadable: .failed(message)
        case .oversized: .invalidValue(message)
        }
    }
}

public typealias DotenvReaderFunction = @Sendable (String) -> Result<DotenvFileSnapshot, DotenvReadError>

/// Host-side reader for bound `.env` files. Canonicalizes the stored path
/// (symlinks, including parent components, are followed deliberately), then
/// applies OwnerOnlyFile-style checks to the canonical target: regular file,
/// owner-owned, not group/world-writable. Group/world-readable (0644) is
/// allowed; strict orgs forbid dotenv sources entirely via managed policy.
public enum DotenvLiveReader {
    public static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    public static func read(path: String) -> Result<DotenvFileSnapshot, DotenvReadError> {
        guard let canonical = canonicalPath(path) else {
            return .failure(errno == ENOENT ? .missingFile(path) : .unreadable(path))
        }
        let fd = open(canonical, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT { return .failure(.missingFile(path)) }
            if errno == ELOOP { return .failure(.untrustedFile(path: canonical, reason: "symlink")) }
            return .failure(.unreadable(path))
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return .failure(.unreadable(path)) }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            return .failure(.untrustedFile(path: canonical, reason: "not a regular file"))
        }
        guard info.st_uid == getuid() else {
            return .failure(.untrustedFile(path: canonical, reason: "owned by another user"))
        }
        guard (info.st_mode & 0o022) == 0 else {
            return .failure(.untrustedFile(path: canonical, reason: "group or world writable"))
        }
        guard info.st_size <= DotenvFile.maximumBytes else { return .failure(.oversized(canonical)) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size) + 1)
        var count = 0
        while count < bytes.count {
            let n = bytes.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                #if canImport(Darwin)
                return Darwin.read(fd, base + count, raw.count - count)
                #else
                return Glibc.read(fd, base + count, raw.count - count)
                #endif
            }
            if n < 0, errno == EINTR { continue }
            guard n >= 0 else { return .failure(.unreadable(path)) }
            if n == 0 { break }
            count += n
        }
        guard count <= DotenvFile.maximumBytes else { return .failure(.oversized(canonical)) }
        #if canImport(Darwin)
        let mtime = info.st_mtimespec
        #else
        let mtime = info.st_mtim
        #endif
        let identity = "\(info.st_dev):\(info.st_ino):\(mtime.tv_sec).\(mtime.tv_nsec):\(info.st_size)"
        return .success(DotenvFileSnapshot(
            canonicalPath: canonical, data: Data(bytes.prefix(count)), identity: identity))
    }
}

/// Resolves one variable from one snapshot. Errors name path+variable, never values.
enum DotenvResolver {
    static func value(
        path: String, variable: String, snapshot: DotenvFileSnapshot
    ) -> Result<SecretValue, SecretResolutionError> {
        value(path: path, variable: variable, parsed: DotenvFile.parse(snapshot.data))
    }

    static func value(
        path: String, variable: String, parsed: Result<DotenvParse, DotenvFileError>
    ) -> Result<SecretValue, SecretResolutionError> {
        let parse: DotenvParse
        switch parsed {
        case .failure(let error):
            return .failure(.invalidValue("dotenv \(DisplayedText.field(path))#\(variable): \(error.message)"))
        case .success(let loaded): parse = loaded
        }
        if let malformedLine = parse.malformedLine {
            return .failure(.failed(
                "dotenv file \(DisplayedText.field(path)) line \(malformedLine) is not a NAME=VALUE assignment"))
        }
        if parse.duplicates.contains(variable) {
            return .failure(.failed(
                "dotenv \(DisplayedText.field(path))#\(variable): duplicate variable in file; refusing to guess"))
        }
        guard let raw = parse.value(for: variable) else {
            return .failure(.notFound(
                "dotenv \(DisplayedText.field(path))#\(variable): variable is not set in the file"))
        }
        return SecretResolver.value(Array(raw.utf8), from: "dotenv \(path)#\(variable)")
    }
}

/// Per-resolver-instance snapshot: within one lease, every secret sourced
/// from the same file comes from one file generation. An identity change
/// mid-lease fails that file's remaining secrets instead of mixing values.
final class DotenvSnapshotCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: [String: (identity: String, parsed: Result<DotenvParse, DotenvFileError>)] = [:]

    func resolve(
        path: String, variable: String, reader: DotenvReaderFunction
    ) -> Result<SecretValue, SecretResolutionError> {
        let snapshot: DotenvFileSnapshot
        switch reader(path) {
        case .failure(let error): return .failure(error.resolutionError)
        case .success(let loaded): snapshot = loaded
        }
        lock.lock()
        if let prior = cached[snapshot.canonicalPath] {
            guard prior.identity == snapshot.identity else {
                lock.unlock()
                return .failure(.failed(
                    "dotenv file \(DisplayedText.field(snapshot.canonicalPath)) changed during this lease"))
            }
            let parsed = prior.parsed
            lock.unlock()
            return DotenvResolver.value(path: snapshot.canonicalPath, variable: variable, parsed: parsed)
        }
        let parsed = DotenvFile.parse(snapshot.data)
        cached[snapshot.canonicalPath] = (snapshot.identity, parsed)
        lock.unlock()
        return DotenvResolver.value(path: snapshot.canonicalPath, variable: variable, parsed: parsed)
    }
}
