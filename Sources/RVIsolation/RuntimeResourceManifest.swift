#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain

/// A credential-selection tag derived from a trusted agent definition.
///
/// Step 8 (F2 re-review): the launch layers accept ONLY this type for
/// filtered staging. The sole constructor takes the definition itself,
/// so wire tags, HookHost values, and CLI/caller-provided strings are
/// unrepresentable as selection input — they cannot become this type.
struct DefinitionStagingTag: Hashable, Sendable, Equatable {
    let rawValue: String

    /// Maps a trusted definition's tag. Nil when the definition names
    /// none (unfiltered entries only).
    init?(_ definition: AgentDefinition) {
        guard let tag = definition.agentTag else { return nil }
        rawValue = tag
    }
}

/// The one host-resolved resource description consumed by profile compilation,
/// private staging, and environment construction. A client sends only its ID.
struct RuntimeResourceManifest: Sendable, Equatable {
    let profile: RuntimeResourceProfile
    let privateHome: String

    init(_ profile: RuntimeResourceProfile) {
        self.profile = profile
        // Linux has no /private/tmp; stage under the platform temporary
        // directory instead. macOS keeps /private/tmp for the sandbox.
        #if os(macOS)
        privateHome = "/private/tmp/rv-runtime-\(UUID().uuidString.lowercased())"
        #else
        privateHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-runtime-\(UUID().uuidString.lowercased())").path
        #endif
    }

    var bin: String { "\(privateHome)/bin" }
    var tmp: String { "\(privateHome)/tmp" }

    /// Stage only the selected profile. Credential contents are copied into a
    /// private home; the sandbox never receives a read grant for the originals.
    /// A credential naming agents stages only when `agent` matches; unfiltered
    /// credentials stage for every launch.
    ///
    /// Step 8 (F2): `agent` must be a definition-derived tag (identity path)
    /// or nil (legacy path: filtered entries never stage). Wire tags,
    /// HookHost values, and CLI/caller-provided names must never be passed.
    func stage(forAgent agent: String? = nil) -> Result<Void, ResourceStagingError> {
        guard privateHome.withCString({ mkdir($0, 0o700) }) == 0 else {
            return .failure(.privateHome)
        }
        var complete = false
        defer { if !complete { remove() } }
        guard makeDirectory(bin), makeDirectory(tmp) else { return .failure(.privateHome) }
        for link in profile.executableLinks {
            guard let target = posixRealpath(link.target),
                FileManager.default.isExecutableFile(atPath: target),
                "\(bin)/\(link.name)".withCString({ path in
                    target.withCString { symlink($0, path) }
                }) == 0
            else { return .failure(.executableLink(name: link.name)) }
        }
        for credential in profile.credentials {
            if let filter = credential.agents, filter.isEmpty == false {
                guard let agent, filter.contains(agent) else { continue }
            }
            let destination = "\(privateHome)/\(credential.destination)"
            let parent = (destination as NSString).deletingLastPathComponent
            guard makeDirectory(parent), copyCredential(credential.source, to: destination) else {
                return .failure(.credential(destination: credential.destination))
            }
        }
        for tree in profile.writeTrees {
            guard makeDirectory(tree), privateDirectory(tree) else {
                return .failure(.writeTree(path: tree))
            }
        }
        complete = true
        return .success(())
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: privateHome)
    }

    /// Read the profile's keychain entries for this launch's agent tag.
    /// Selection mirrors credential filtering: a filtered entry injects
    /// only on a tag match; unfiltered entries inject everywhere. A JSON
    /// secret yields the named string field; otherwise the whole secret
    /// must decode as UTF-8 text. Every failure names the operator's env
    /// var and stages nothing.
    ///
    /// Step 8 (F2): the tag must be definition-derived (identity path) or
    /// nil (legacy path: filtered entries never match). Wire tags,
    /// HookHost values, and CLI/caller-provided names must never be passed.
    func keychainEnvironment(
        forAgent agent: String? = nil,
        reader: KeychainReader = .live
    ) -> Result<[(name: String, value: String)], ResourceStagingError> {
        var entries: [(name: String, value: String)] = []
        for item in profile.keychain {
            if let filter = item.agents, filter.isEmpty == false {
                guard let agent, filter.contains(agent) else { continue }
            }
            guard let secret = reader.read(item.service, item.account),
                secret.isEmpty == false,
                secret.count <= 8_192
            else {
                return .failure(.keychain(env: item.env))
            }
            let value: String
            if let field = item.field {
                guard let json = try? JSONDecoder().decode(JSONValue.self, from: secret),
                    let raw = json[field]?.string
                else {
                    return .failure(.keychain(env: item.env))
                }
                value = raw
            } else {
                guard let raw = String(data: secret, encoding: .utf8) else {
                    return .failure(.keychain(env: item.env))
                }
                value = raw
            }
            guard value.utf8.count <= 8_192, value.contains("\0") == false else {
                return .failure(.keychain(env: item.env))
            }
            entries.append((item.env, value))
        }
        return .success(entries)
    }

    private func makeDirectory(_ path: String) -> Bool {
        if FileManager.default.fileExists(atPath: path) == false {
            do {
                try FileManager.default.createDirectory(
                    atPath: path, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch { return false }
        }
        return true
    }

    private func privateDirectory(_ path: String) -> Bool {
        var status = stat()
        return path.withCString { lstat($0, &status) } == 0
            && (status.st_mode & S_IFMT) == S_IFDIR
            && status.st_uid == getuid()
            && (status.st_mode & 0o077) == 0
    }

    private func copyCredential(_ source: String, to destination: String) -> Bool {
        let input = source.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard input >= 0 else { return false }
        defer { close(input) }
        var status = stat()
        guard fstat(input, &status) == 0,
            (status.st_mode & S_IFMT) == S_IFREG,
            status.st_uid == getuid(),
            (status.st_mode & 0o022) == 0,
            status.st_size >= 0,
            status.st_size <= 1_048_576
        else { return false }
        let output = destination.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard output >= 0 else { return false }
        defer { close(output) }
        var buffer = [UInt8](repeating: 0, count: 16_384)
        var copied = 0
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in read(input, raw.baseAddress, raw.count) }
            if count == 0 { return true }
            if count < 0 {
                if errno == EINTR { continue }
                return false
            }
            copied += count
            if copied > 1_048_576 { return false }
            var written = 0
            while written < count {
                let result = buffer.withUnsafeBytes { raw in
                    write(output, raw.baseAddress?.advanced(by: written), count - written)
                }
                if result < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if result == 0 { return false }
                written += result
            }
        }
    }
}

/// Which policy grant broke staging. The detail names the
/// operator-authored item only, never host paths or errno text.
enum ResourceStagingError: Error, Sendable, Equatable {
    case privateHome
    case executableLink(name: String)
    case credential(destination: String)
    case writeTree(path: String)
    case keychain(env: String)

    /// Operator-legible descriptor for the denial path. Link names,
    /// credential destinations, and keychain env vars come from the
    /// operator's own policy file; tree paths surface only their final
    /// component. Keychain service/account labels never surface: the env
    /// var names the broken grant without hinting at other vault items.
    var detail: String {
        switch self {
        case .privateHome:
            "private staging directory"
        case .executableLink(let name):
            "executable link '\(name)'"
        case .credential(let destination):
            "credential '\(destination)'"
        case .writeTree(let path):
            "workspace directory '\((path as NSString).lastPathComponent)'"
        case .keychain(let env):
            "keychain '\(env)'"
        }
    }
}
