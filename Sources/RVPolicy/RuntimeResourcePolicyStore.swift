#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain

public enum RuntimeResourcePolicyError: Error, Sendable, Equatable {
    case unsafeLocation
    case unreadable
    case oversized
    case invalidDocument
    case unsupportedVersion
}

/// Reads only the operator's machine policy. Repository policy is never an
/// authority source because a contained runtime can write its workspace.
public enum RuntimeResourcePolicyStore {
    public static let maximumBytes = 65_536

    public static func load(from configDirectory: URL) -> Result<RuntimeResourcePolicy, RuntimeResourcePolicyError> {
        let directory = configDirectory.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        if directory < 0 {
            return errno == ENOENT ? .success(.empty) : .failure(.unsafeLocation)
        }
        defer { close(directory) }
        var directoryStatus = stat()
        guard fstat(directory, &directoryStatus) == 0,
            directoryStatus.st_uid == getuid(),
            (directoryStatus.st_mode & 0o022) == 0
        else {
            return .failure(.unsafeLocation)
        }
        let file = "runtime-resources.json".withCString {
            openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        if file < 0 {
            return errno == ENOENT ? .success(.empty) : .failure(.unsafeLocation)
        }
        defer { close(file) }
        var fileStatus = stat()
        guard fstat(file, &fileStatus) == 0,
            (fileStatus.st_mode & S_IFMT) == S_IFREG,
            fileStatus.st_uid == getuid(),
            (fileStatus.st_mode & 0o177) == 0
        else {
            return .failure(.unsafeLocation)
        }
        guard fileStatus.st_size >= 0, fileStatus.st_size <= Int64(maximumBytes) else {
            return .failure(.oversized)
        }
        var bytes = [UInt8](repeating: 0, count: maximumBytes + 1)
        var count = 0
        while count < bytes.count {
            let remaining = bytes.count - count
            let result = bytes.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return -1 }
                return read(file, base.advanced(by: count), remaining)
            }
            if result > 0 { count += result; continue }
            if result == 0 { break }
            if errno == EINTR { continue }
            return .failure(.unreadable)
        }
        guard count <= maximumBytes else { return .failure(.oversized) }
        return decode(Data(bytes.prefix(count)))
    }

    public static func decode(_ data: Data) -> Result<RuntimeResourcePolicy, RuntimeResourcePolicyError> {
        guard data.count <= maximumBytes else { return .failure(.oversized) }
        guard let document = try? JSONDecoder().decode(RuntimeResourcePolicy.self, from: data) else {
            return .failure(.invalidDocument)
        }
        guard document.version == 1 else { return .failure(.unsupportedVersion) }
        guard validate(document) else { return .failure(.invalidDocument) }
        return .success(document)
    }

    private static func validate(_ document: RuntimeResourcePolicy) -> Bool {
        guard document.profiles.count <= 32 else { return false }
        var ids = Set<String>()
        for profile in document.profiles {
            guard identifier(profile.id), ids.insert(profile.id).inserted,
                !profile.projects.isEmpty, profile.projects.count <= 32,
                profile.projects.allSatisfy(absolutePath),
                profile.executableLinks.count <= 32,
                profile.readFiles.count <= 64, profile.readTrees.count <= 32,
                profile.writeTrees.count <= 16, profile.credentials.count <= 32,
                profile.environment.count <= 32, profile.keychain.count <= 8,
                profile.readFiles.allSatisfy(absolutePath),
                profile.readTrees.allSatisfy(absolutePath),
                profile.writeTrees.allSatisfy(absolutePath)
            else { return false }
            // Marks accept any identifier: the launcher derives entries from
            // them, so a closed set here would reintroduce per-agent source
            // edits. Unknown names simply match nothing with a hook wire.
            guard profile.agents.count <= 8,
                profile.agents.allSatisfy(identifier),
                Set(profile.agents).count == profile.agents.count
            else { return false }
            var names = Set<String>()
            for link in profile.executableLinks {
                guard identifier(link.name), absolutePath(link.target),
                    names.insert(link.name).inserted else { return false }
            }
            var destinations = Set<String>()
            for credential in profile.credentials {
                guard absolutePath(credential.source), relativePath(credential.destination),
                    destinations.insert(credential.destination).inserted else { return false }
                // Credential agent filters use the same identifier rules
                // as profile marks; an absent filter stages everywhere.
                if let agents = credential.agents {
                    guard agents.count <= 8,
                        agents.allSatisfy(identifier),
                        Set(agents).count == agents.count
                    else { return false }
                }
            }
            var variables = Set<String>()
            for entry in profile.environment {
                let hostSource = entry.hostVariable.map(environmentName) ?? false
                let literalSource = entry.literalValue.map {
                    !$0.contains("\0") && !$0.contains("\n") && !$0.contains("\r")
                        && $0.utf8.count <= 1_024
                } ?? false
                guard environmentName(entry.name), hostSource != literalSource,
                    !reservedEnvironmentNames.contains(entry.name),
                    variables.insert(entry.name).inserted else { return false }
            }
            for entry in profile.keychain {
                guard keychainLabel(entry.service), keychainLabel(entry.account),
                    entry.field.map(keychainField) ?? true,
                    environmentName(entry.env),
                    !reservedEnvironmentNames.contains(entry.env),
                    variables.insert(entry.env).inserted
                else { return false }
                if let agents = entry.agents {
                    guard agents.count <= 8,
                        agents.allSatisfy(identifier),
                        Set(agents).count == agents.count
                    else { return false }
                }
            }
        }
        if let defaultID = document.defaultProfile {
            guard identifier(defaultID), ids.contains(defaultID) else { return false }
        }
        return true
    }

    private static func identifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 && value.utf8.allSatisfy {
            ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122)
                || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    /// Keychain service/account labels: opaque operator text, bounded,
    /// without control bytes. Any printable label is accepted; unknown
    /// items simply fail closed at read time.
    private static func keychainLabel(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256
            && !value.contains("\0") && !value.contains("\n") && !value.contains("\r")
    }

    private static func keychainField(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128
            && !value.contains("\0") && !value.contains("\n") && !value.contains("\r")
    }

    private static func environmentName(_ value: String) -> Bool {
        guard let first = value.utf8.first,
            (first >= 65 && first <= 90) || (first >= 97 && first <= 122) || first == 95,
            value.utf8.count <= 64 else { return false }
        return value.utf8.allSatisfy {
            ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122)
                || ($0 >= 48 && $0 <= 57) || $0 == 95
        }
    }

    private static func absolutePath(_ value: String) -> Bool {
        value.hasPrefix("/") && value != "/" && value.utf8.count <= 1_024 && pathPartsSafe(value)
    }

    private static func relativePath(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("/") && value.utf8.count <= 256 && pathPartsSafe(value)
    }

    private static func pathPartsSafe(_ value: String) -> Bool {
        !value.contains("\0") && !value.contains("\n") && !value.contains("\r")
            && value.split(separator: "/", omittingEmptySubsequences: false)
                .dropFirst(value.hasPrefix("/") ? 1 : 0)
                .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static let reservedEnvironmentNames: Set<String> = [
        "PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "TERM", "CLICOLOR",
        "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY",
        "http_proxy", "https_proxy", "no_proxy",
    ]
}
