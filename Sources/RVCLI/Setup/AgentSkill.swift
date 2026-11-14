#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain

/// What installing the agent skill did.
enum AgentSkillInstall: Equatable, Sendable {
    case wrote
    case unchanged
    /// A file rv did not write (or one changed since) is there: left as is.
    case keptForeign
    /// The write itself failed (a non-folder in the way, permissions).
    /// Never fatal: the hook is already wired, the skill is guidance.
    case writeFailed(reason: String)
}

/// A skill setup did not install, named on stderr with a fix.
enum AgentSkillNote: Equatable, Sendable {
    case kept(path: String)
    case writeFailed(path: String, reason: String)
}

/// The rv agent skill: a SKILL.md teaching the agent to read an rv denial,
/// ask the human once for a narrow grant, and never work around rv.
/// `rv setup` installs it into a host's user skill directory
/// (`OwnedPaths.agentSkill(for:)`); detach removes it.
///
/// Ownership: the installed bytes end with a seal line naming the SHA-256
/// of everything before it. A file whose seal checks out is rv's (this or
/// an older version) and may be replaced or removed. Anything else (no
/// seal, edited text, a symlink anywhere from the host root down, a
/// non-regular or oversized file, an unreadable file) is kept: rv never
/// writes through a link, and never overwrites or deletes a skill someone
/// else wrote.
enum AgentSkill {
    static let directoryName = "rv"
    static let fileName = "SKILL.md"
    private static let sealPrefix = "<!-- rv-owned-skill sha256="
    private static let sealSuffix = " -->\n"
    /// Every skill path is `<host root>/skills/rv/SKILL.md`.
    static let hostRootSuffix = "/skills/rv/SKILL.md"
    /// Larger than any skill rv ships; a bigger file is not rv's.
    static let maximumBytes = 64 * 1024

    enum Ownership: Equatable, Sendable {
        case absent
        /// Byte-identical to what this rv writes.
        case current
        /// Sealed by rv, but not this version's text.
        case ownedStale
        case foreign
    }

    /// The embedded skill text, without the seal.
    static var text: String {
        String(decoding: PackageResources.rv_agent_skill_md, as: UTF8.self)
    }

    /// The bytes setup writes.
    static var rendered: Data { sealed(text) }

    /// `body` (newline-terminated) followed by its seal line.
    static func sealed(_ body: String) -> Data {
        let terminated = body.hasSuffix("\n") ? body : body + "\n"
        let bytes = Array(terminated.utf8)
        return Data(bytes + Array((sealPrefix + RVDigest.sha256Hex(bytes) + sealSuffix).utf8))
    }

    static func ownership(of data: Data?) -> Ownership {
        guard let data else { return .absent }
        if data == rendered { return .current }
        return isSealed(data) ? .ownedStale : .foreign
    }

    /// The last line is a seal over every byte before it.
    private static func isSealed(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.last == UInt8(ascii: "\n") else { return false }
        let start = bytes.dropLast().lastIndex(of: UInt8(ascii: "\n")).map { $0 + 1 } ?? 0
        let line = String(decoding: bytes[start...], as: UTF8.self)
        return line == sealPrefix + RVDigest.sha256Hex(Array(bytes[..<start])) + sealSuffix
    }

    /// The ownership of what is at `path`, never following a link. A
    /// symlink at the host root or any folder below it, a path not shaped
    /// `<root>/skills/rv/SKILL.md`, or a file that is not a readable
    /// regular file of at most `maximumBytes` is foreign.
    static func ownership(at path: String, files: FileOps) -> Ownership {
        guard let chain = componentChain(path) else { return .foreign }
        if chain.contains(where: files.isSymbolicLink) { return .foreign }
        switch readRegularFile(path) {
        case .absent: return .absent
        case .foreign: return .foreign
        case .bytes(let data): return ownership(of: data)
        }
    }

    /// The host root, `skills`, `rv`, then the file: every entry setup
    /// writes into or through. Nil for a path of any other shape.
    static func componentChain(_ path: String) -> [String]? {
        guard path.hasSuffix(hostRootSuffix), path.count > hostRootSuffix.count else { return nil }
        let root = String(path.dropLast(hostRootSuffix.count))
        return [root, root + "/skills", root + "/skills/rv", path]
    }

    private enum Read {
        case absent
        case bytes(Data)
        case foreign
    }

    /// Opens without following a link and without blocking (a FIFO in the
    /// file's place must not hang setup), then accepts only a regular file
    /// of at most `maximumBytes`.
    private static func readRegularFile(_ path: String) -> Read {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        // ENOTDIR: a non-folder sits where `skills` or `rv` goes. Nothing
        // there is a skill; setup's write fails on it and says so.
        guard fd >= 0 else { return errno == ENOENT || errno == ENOTDIR ? .absent : .foreign }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= maximumBytes else {
            return .foreign
        }
        var bytes: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while bytes.count <= maximumBytes {
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0 { return .foreign }
            if count == 0 { break }
            bytes.append(contentsOf: chunk[..<count])
        }
        return bytes.count <= maximumBytes ? .bytes(Data(bytes)) : .foreign
    }

    /// Whether `path` holds a skill rv wrote (so detach may remove it).
    static func isOwned(at path: String, files: FileOps) -> Bool {
        switch ownership(at: path, files: files) {
        case .current, .ownedStale: true
        case .absent, .foreign: false
        }
    }

    /// Writes the skill atomically when absent or rv's own older version.
    static func install(at path: String, files: FileOps) -> AgentSkillInstall {
        switch ownership(at: path, files: files) {
        case .current:
            return .unchanged
        case .foreign:
            return .keptForeign
        case .absent, .ownedStale:
            do {
                try files.write(String(decoding: rendered, as: UTF8.self), to: path)
            } catch {
                return .writeFailed(reason: (error as NSError).localizedDescription)
            }
            return .wrote
        }
    }

    /// Directories detach removes when empty after the skill goes: only
    /// rv's own `rv/` folder. `skills/` and the host root may be the
    /// user's (or a dotfiles link), so they stay even when empty.
    static func emptyDirectories(after path: String) -> [String] {
        [(path as NSString).deletingLastPathComponent]
    }
}
