import Foundation
import RVDomain

/// What installing the agent skill did.
enum AgentSkillInstall: Equatable, Sendable {
    case wrote
    case unchanged
    /// A file rv did not write (or one changed since) is there: left as is.
    case keptForeign
}

/// The rv agent skill: a SKILL.md teaching the agent to read an rv denial,
/// ask the human once for a narrow grant, and never work around rv.
/// `rv setup` installs it into a host's user skill directory
/// (`OwnedPaths.agentSkill(for:)`); detach removes it.
///
/// Ownership: the installed bytes end with a seal line naming the SHA-256
/// of everything before it. A file whose seal checks out is rv's (this or
/// an older version) and may be replaced or removed. Anything else (no
/// seal, edited text, a symlink, a directory, an unreadable file) is kept:
/// rv never overwrites or deletes a skill someone else wrote.
enum AgentSkill {
    static let directoryName = "rv"
    static let fileName = "SKILL.md"
    private static let sealPrefix = "<!-- rv-owned-skill sha256="
    private static let sealSuffix = " -->\n"

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

    /// The ownership of what is at `path`, never following a link: a
    /// symlinked file or skill directory, a directory in the file's place,
    /// or a file that exists but cannot be read is foreign.
    static func ownership(at path: String, files: FileOps) -> Ownership {
        let directory = (path as NSString).deletingLastPathComponent
        if files.isSymbolicLink(directory) || files.isSymbolicLink(path) { return .foreign }
        guard files.fileExists(path) else { return .absent }
        if files.isDirectory(path) { return .foreign }
        guard let data = files.readData(path) else { return .foreign }
        return ownership(of: data)
    }

    /// Whether `path` holds a skill rv wrote (so detach may remove it).
    static func isOwned(at path: String, files: FileOps) -> Bool {
        switch ownership(at: path, files: files) {
        case .current, .ownedStale: true
        case .absent, .foreign: false
        }
    }

    /// Writes the skill atomically when absent or rv's own older version.
    /// Throws only when the write itself fails.
    static func install(at path: String, files: FileOps) throws -> AgentSkillInstall {
        switch ownership(at: path, files: files) {
        case .current:
            return .unchanged
        case .foreign:
            return .keptForeign
        case .absent, .ownedStale:
            try files.write(String(decoding: rendered, as: UTF8.self), to: path)
            return .wrote
        }
    }

    /// Directories detach removes when empty after the skill goes: the
    /// skill's own folder, then the host's skills folder.
    static func emptyDirectories(after path: String) -> [String] {
        let directory = (path as NSString).deletingLastPathComponent
        return [directory, (directory as NSString).deletingLastPathComponent]
    }
}
