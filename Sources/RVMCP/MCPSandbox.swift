#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Seatbelt cage for upstream MCP servers that set `sandbox` in mcp.json.
/// Allow-default (so npx/uvx/node work) with writes confined to a scratch
/// directory, temp and package caches, and reads of credential stores and
/// other hosts' MCP configs denied. Not a deny-default runtime cage.
public enum MCPSandbox {
    public static let sandboxExec = "/usr/bin/sandbox-exec"

    static let defaultWritable = ["~/.npm", "~/.cache", "~/Library/Caches"]
    /// Paths `profile` allows even when `policy.writable` is empty.
    static let seatbeltWriteRoots = ["/private/tmp", "/private/var/folders", "/dev"]

    /// Write paths a present sandbox still allows. Trust and import show this
    /// list. `~` is this home when `home` is set, so the review names the
    /// directory serve will expand. Temp is only `/private/tmp` and
    /// `/private/var/folders`, not whatever `TMPDIR` is at serve.
    public static func disclosedWritePaths(
        server name: String, policy: MCPSandboxPolicy, home: String? = nil
    ) -> [String] {
        func show(_ path: String) -> String {
            guard let home, path.hasPrefix("~/") else { return path }
            return home + String(path.dropFirst(1))
        }
        let scratch = show("~/Library/Caches/rv-mcp/\(name)")
        return [scratch] + seatbeltWriteRoots + defaultWritable.map(show) + policy.writable
    }

    static let deniedReads = [
        "~/.ssh", "~/.aws", "~/.gnupg", "~/.kube", "~/.docker", "~/.config/gh", "~/.config/gcloud", "~/.azure",
        "~/Library/Keychains", "~/Library/Cookies", "~/Library/Application Support/Google/Chrome",
        "~/Library/Application Support/Firefox", "~/Library/Application Support/BraveSoftware",
        "~/.claude.json", "~/.codex", "~/.cursor", "~/.codeium", "~/.gemini", "~/.config/opencode",
        "~/Library/Application Support/Claude", "~/.netrc", "~/.npmrc", "~/.pypirc",
    ]

    /// The planner hook `rv mcp serve` passes to `MCPLaunchPlanner.plan`.
    public static func apply(
        configDirectory: URL, home: URL
    ) -> (MCPServerDefinition, MCPUpstreamLaunch) -> Result<MCPUpstreamLaunch, MCPLaunchError> {
        { definition, launch in
            guard let policy = definition.sandbox else { return .success(launch) }
            #if os(macOS)
            let scratch = home.appendingPathComponent("Library/Caches/rv-mcp/\(definition.name)", isDirectory: true)
            let temporary = launch.environment["TMPDIR"] ?? NSTemporaryDirectory()
            guard let pinned = pinExistingAncestors(scratch.path) else {
                return .failure(.sandbox(scratchCreationFailure(scratch.path)))
            }
            if let widened = unreviewedWrite(
                policy: policy, scratch: scratch.path, home: home.path, temporaryDirectory: temporary)
            {
                return .failure(.sandbox(widened))
            }
            if let widened = unreviewedHome(home.path) {
                return .failure(.sandbox(widened))
            }
            guard createPinned(scratch.path, pinned: pinned) else {
                return .failure(.sandbox(scratchCreationFailure(scratch.path)))
            }
            switch profile(
                policy: policy, scratch: scratch.path, home: home.path, configDirectory: configDirectory.path,
                temporaryDirectory: temporary)
            {
            case .failure(let error): return .failure(error)
            case .success(let text):
                var caged = launch
                caged.executable = sandboxExec
                caged.arguments = ["-p", text, launch.executable] + launch.arguments
                caged.workingDirectory = scratch.path
                return .success(caged)
            }
            #else
            return .failure(.sandbox("\(definition.name) asks for a sandbox, which rv supports only on macOS"))
            #endif
        }
    }

    public static func profile(
        policy: MCPSandboxPolicy, scratch: String, home: String, configDirectory: String, temporaryDirectory: String
    ) -> Result<String, MCPLaunchError> {
        func expand(_ path: String) -> String {
            path.hasPrefix("~/") ? home + path.dropFirst(1) : path
        }
        let writable = [scratch, temporaryDirectory] + seatbeltWriteRoots
            + (defaultWritable + policy.writable).map(expand)
        if let widened = unreviewedWrite(
            policy: policy, scratch: scratch, home: home, temporaryDirectory: temporaryDirectory)
        {
            return .failure(.sandbox(widened))
        }
        let unreadable = deniedReads.map(expand) + [configDirectory]
        let writeAllow = paths(writable, denyTargets: false)
        let linkDenies = symlinkDenies(unreadable)
        var lines = [
            "(version 1)",
            "(allow default)",
            "(deny file-write*)",
            "(allow file-write* " + writeAllow + ")",
            "(deny file-read* file-write* " + paths(unreadable, denyTargets: true) + linkDenies + ")",
        ]
        // A credential symlink can be retargeted at a path the profile did not
        // name. File reads no longer fall through to (allow default). Reviewed
        // write paths are allowed again, then the credential deny is repeated
        // so a target under /private/tmp or a cache is not re-opened.
        if linkDenies.isEmpty == false {
            let credentialDeny = "(deny file-read* file-write* " + paths(unreadable, denyTargets: true) + linkDenies + ")"
            lines.append("(deny file-read*)")
            lines.append("(allow file-read* file-write* " + writeAllow + ")")
            lines.append(credentialDeny)
        }
        if policy.network == false {
            lines.append("(deny network*)")
        }
        return .success(lines.joined(separator: "\n"))
    }

    /// Shown when the scratch path cannot be pinned or created. The path is
    /// fielded once here. Callers that already field a reason do not use this.
    static func scratchCreationFailure(_ path: String) -> String {
        "could not create \(MCPDisplayedText.field(path))"
    }

    /// The real path when it is not the path the review named. `/tmp` and
    /// `/private/tmp` are the same directory. Any other symlink target is refused.
    static func unreviewedWrite(
        policy: MCPSandboxPolicy, scratch: String, home: String, temporaryDirectory: String
    ) -> String? {
        func expand(_ path: String) -> String {
            path.hasPrefix("~/") ? home + path.dropFirst(1) : path
        }
        if let widened = unreviewedTemporary(temporaryDirectory) {
            return widened
        }
        let writable = [scratch, temporaryDirectory] + seatbeltWriteRoots
            + (defaultWritable + policy.writable).map(expand)
        return unreviewedWrite(paths: writable)
    }

    /// `TMPDIR` is a write root only when it is `/private/tmp`,
    /// `/private/var/folders`, or a directory inside one of those. A concrete
    /// path the review never named is refused. A path C `realpath` cannot
    /// resolve is refused too: a missing middle component must not be glued
    /// back on, `..` and all, and emitted as an allow.
    static func unreviewedTemporary(_ path: String) -> String? {
        guard let existing = resolveExisting(path) else {
            return "\(MCPDisplayedText.field(path)) resolves to \(MCPDisplayedText.field(path)), which was not the path reviewed"
        }
        let resolved = tmpAlias(existing)
        let roots = ["/private/tmp", "/private/var/folders"]
        if roots.contains(where: { resolved == $0 || resolved.hasPrefix($0 + "/") }) {
            return nil
        }
        return "\(MCPDisplayedText.field(path)) resolves to \(MCPDisplayedText.field(existing)), which was not the path reviewed"
    }

    /// `~` in the review is the account home. A serve-time `HOME` that points
    /// somewhere else is a write root the review did not name.
    static func unreviewedHome(_ home: String) -> String? {
        guard let passwd = passwdHome() else {
            return "\(MCPDisplayedText.field(home)) resolves to a directory that was not the path reviewed"
        }
        let resolved = realPath(home)
        if sameReviewedDirectory(resolved, realPath(passwd)) { return nil }
        return "\(MCPDisplayedText.field(home)) resolves to \(MCPDisplayedText.field(resolved)), which was not the path reviewed"
    }

    static func passwdHome() -> String? {
        guard let entry = getpwuid(geteuid()), let dir = entry.pointee.pw_dir else { return nil }
        let home = String(cString: dir)
        return home.isEmpty ? nil : home
    }

    static func unreviewedWrite(paths writable: [String]) -> String? {
        for path in writable {
            let resolved = realPath(path)
            if sameReviewedDirectory(path, resolved) { continue }
            return "\(MCPDisplayedText.field(path)) resolves to \(MCPDisplayedText.field(resolved)), which was not the path reviewed"
        }
        return nil
    }

    /// Same directory, including the `/tmp` → `/private/tmp` alias. A symlink
    /// to a different tree is not the same directory.
    static func sameReviewedDirectory(_ reviewed: String, _ resolved: String) -> Bool {
        if reviewed == resolved { return true }
        return tmpAlias(reviewed) == tmpAlias(resolved)
    }

    static func tmpAlias(_ path: String) -> String {
        if path == "/tmp" { return "/private/tmp" }
        if path.hasPrefix("/tmp/") { return "/private/tmp/" + path.dropFirst("/tmp/".count) }
        return path
    }

    /// Allow filters add a resolved spelling only when it is the same
    /// directory. Deny filters also add a different real path, so a symlink
    /// at `~/.ssh` or the config directory does not leave the target readable.
    static func paths(_ raw: [String], denyTargets: Bool) -> String {
        // Scalar identity, not String equality. Swift treats NFC and NFD as
        // the same string, and a catalog name in the other form would be dropped.
        var seen = Set<[UInt32]>()
        func fresh(_ text: String) -> Bool {
            seen.insert(text.unicodeScalars.map(\.value)).inserted
        }
        var filters: [String] = []
        for path in raw {
            let resolved = denyTargets ? deniedRealPath(path) : realPath(path)
            var spellings = (denyTargets || sameReviewedDirectory(path, resolved)) ? [path, resolved] : [path]
            if denyTargets {
                var expanded: [String] = []
                for spelling in spellings + seatbeltSpellings(resolved) {
                    for form in unicodeForms(spelling) {
                        expanded.append(contentsOf: seatbeltSpellings(form))
                    }
                }
                spellings = expanded
            }
            for spelling in spellings where fresh(spelling) {
                filters.append("(subpath \"\(escape(spelling))\")")
                if denyTargets {
                    let pattern = "(regex #\"\(seatbeltPathPattern(spelling))\")"
                    if fresh(pattern) { filters.append(pattern) }
                }
            }
        }
        return filters.joined(separator: " ")
    }

    static func realPath(_ path: String) -> String {
        if let resolved = resolveExisting(path) { return resolved }
        return resolvingMissingSuffix(path)
    }

    /// The path Seatbelt will check. A dangling symlink uses `readlink` so the
    /// target is denied even when that directory does not exist yet.
    static func deniedRealPath(_ path: String) -> String {
        if let resolved = resolveExisting(path) { return resolved }
        if let target = absoluteLinkTarget(path) {
            if let resolved = resolveExisting(target) { return resolved }
            return resolvingMissingSuffix(target)
        }
        return resolvingMissingSuffix(path)
    }

    static func absoluteLinkTarget(_ path: String) -> String? {
        guard let raw = readLink(path) else { return nil }
        if raw.hasPrefix("/") { return raw }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return URL(fileURLWithPath: parent).appendingPathComponent(raw).path
    }

    /// Spellings Seatbelt may check for one path: `/tmp` and `/private/tmp`,
    /// `/var` and `/private/var`, and the Data-volume firmlink of an absolute
    /// path (`/opt`, `/private`, `/Users`, and the rest).
    static func seatbeltSpellings(_ path: String) -> [String] {
        var spellings: [String] = []
        func add(_ value: String) {
            if spellings.contains(value) == false { spellings.append(value) }
        }
        add(path)
        if path == "/tmp" || path.hasPrefix("/tmp/") {
            add("/private" + path)
        } else if path == "/private/tmp" || path.hasPrefix("/private/tmp/") {
            add("/tmp" + path.dropFirst("/private/tmp".count))
        }
        if path == "/var" || path.hasPrefix("/var/") {
            add("/private" + path)
        } else if path == "/private/var" || path.hasPrefix("/private/var/") {
            add(String(path.dropFirst("/private".count)))
        }
        let firm = "/System/Volumes/Data"
        for spelling in Array(spellings) {
            if spelling == firm || spelling.hasPrefix(firm + "/") {
                add(String(spelling.dropFirst(firm.count)))
            } else if spelling.hasPrefix("/") {
                add(firm + spelling)
            }
        }
        return spellings
    }

    /// The leaf does not exist yet. Resolve the nearest existing ancestor so
    /// a parent symlink cannot hide the directory `createDirectory` would make.
    /// `.` and `..` are collapsed in the string first. `URL` treats a last
    /// component of `..` as another component to append, so a missing `..`
    /// never reaches an existing parent and the deny is never built.
    static func resolvingMissingSuffix(_ path: String) -> String {
        let normalized = lexicalAbsolute(path)
        var parts = normalized.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var suffix: [String] = []
        while parts.isEmpty == false {
            let current = "/" + parts.joined(separator: "/")
            if let resolved = resolveExisting(current) {
                return suffix.reduce(resolved) { base, part in
                    base == "/" ? "/" + part : base + "/" + part
                }
            }
            suffix.insert(parts.removeLast(), at: 0)
        }
        return normalized
    }

    /// Collapse `.` and `..` without asking `URL` to delete a component.
    /// A missing middle component still yields the path Seatbelt checks once
    /// that component exists. `realpath` staying NULL is not a reason to drop
    /// the path.
    static func lexicalAbsolute(_ path: String) -> String {
        var parts: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if parts.isEmpty == false { parts.removeLast() }
                continue
            }
            parts.append(String(part))
        }
        return "/" + parts.joined(separator: "/")
    }

    /// NFC and NFD of one path. A catalog name in the other form misses a
    /// byte-for-byte subpath. ASCII paths are one entry.
    static func unicodeForms(_ path: String) -> [String] {
        var forms: [String] = []
        var seen = Set<[UInt32]>()
        for form in [path, path.precomposedStringWithCanonicalMapping, path.decomposedStringWithCanonicalMapping] {
            let scalars = form.unicodeScalars.map(\.value)
            if seen.insert(scalars).inserted { forms.append(form) }
        }
        return forms
    }

    static func resolveExisting(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func escape(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Each symlink in a credential chain is denied by a regex built from the
    /// path Seatbelt checks, and by its parent. A static regex cannot see a
    /// retarget, so the parent is not left to `(allow default)`. Reviewed
    /// write paths are allowed again after that deny.
    static func symlinkDenies(_ raw: [String]) -> String {
        var seen = Set<String>()
        var filters: [String] = []
        for path in raw {
            for link in symlinkChain(path) {
                var candidates = [link]
                candidates += seatbeltSpellings(link)
                for candidate in candidates {
                    let exact = "(regex #\"^\(regexEscape(candidate))(/.*)?$\")"
                    let normalized = "(regex #\"\(seatbeltPathPattern(candidate))\")"
                    for filter in [exact, normalized] where seen.insert(filter).inserted {
                        filters.append(filter)
                    }
                }
                let parent = URL(fileURLWithPath: link).deletingLastPathComponent().path
                guard parent != "/" else { continue }
                for spelling in seatbeltSpellings(parent) {
                    let filter = "(subpath \"\(escape(spelling))\")"
                    if seen.insert(filter).inserted { filters.append(filter) }
                }
            }
        }
        return filters.isEmpty ? "" : " " + filters.joined(separator: " ")
    }

    /// The path and every symlink it points through, without the final real
    /// directory. A second symlink at an intermediate path is its own deny.
    static func symlinkChain(_ path: String) -> [String] {
        var links: [String] = []
        var current = path
        var seen = Set<String>()
        while seen.insert(current).inserted, links.count < 32 {
            var info = stat()
            guard lstat(current, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK else { break }
            links.append(current)
            guard let target = readLink(current) else { break }
            if target.hasPrefix("/") {
                current = target
            } else {
                let parent = URL(fileURLWithPath: current).deletingLastPathComponent().path
                current = URL(fileURLWithPath: parent).appendingPathComponent(target).path
            }
        }
        return links
    }

    static func readLink(_ path: String) -> String? {
        let capacity = 4096
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        let count = readlink(path, buffer, capacity - 1)
        guard count > 0 else { return nil }
        buffer[count] = 0
        return String(cString: buffer)
    }

    /// `^/+(\./+)*` between components, letters as classes, so `/a/./b`,
    /// `/a//b`, and `/A/b` are the same path. `/tmp` and `/var` also match
    /// `/private/...` and the Data-volume spelling of that private path.
    /// `/opt`, `/private`, `/usr/local`, `/Volumes`, and `/Users` match the
    /// Data-volume firmlink. A quote in the path stays escaped and still
    /// fails the profile closed.
    static func seatbeltPathPattern(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.isEmpty == false else { return "^$" }
        var body = parts.map { caseFold(regexEscape($0)) }.joined(separator: "/+(\\./+)*")
        let firm = "[Ss][Yy][Ss][Tt][Ee][Mm]/+(\\./+)*[Vv][Oo][Ll][Uu][Mm][Ee][Ss]/+(\\./+)*[Dd][Aa][Tt][Aa]/+(\\./+)*"
        let priv = "[Pp][Rr][Ii][Vv][Aa][Tt][Ee]/+(\\./+)*"
        switch parts[0].lowercased() {
        case "tmp", "var":
            body = "(\(firm))?(\(priv))?" + body
        case "private", "opt", "volumes", "users":
            body = "(\(firm))?" + body
        case "usr":
            if parts.count > 1, parts[1].lowercased() == "local" {
                body = "(\(firm))?" + body
            }
        default:
            break
        }
        return "^/+(\\./+)*" + body + "(/+.*)?$"
    }

    static func caseFold(_ escaped: String) -> String {
        var folded = ""
        var escapedNext = false
        for scalar in escaped.unicodeScalars {
            if escapedNext {
                folded.unicodeScalars.append(scalar)
                escapedNext = false
                continue
            }
            if scalar == "\\" {
                folded.unicodeScalars.append(scalar)
                escapedNext = true
                continue
            }
            let upper = String(scalar).uppercased()
            let lower = String(scalar).lowercased()
            if upper != lower {
                folded += "[\(upper)\(lower)]"
            } else {
                folded.unicodeScalars.append(scalar)
            }
        }
        return folded
    }

    static func regexEscape(_ path: String) -> String {
        var escaped = ""
        for scalar in path.unicodeScalars {
            switch scalar {
            case "\\", ".", "^", "$", "*", "+", "?", "(", ")", "[", "]", "{", "}", "|", "\"":
                escaped += "\\"
                escaped.unicodeScalars.append(scalar)
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }

    /// Opens `path` without following a symlink. The caller creates children
    /// with `mkdirat` on this descriptor, so a later rename of the path does
    /// not redirect the leaf.
    final class HeldDirectory {
        let fd: Int32
        let device: UInt64
        let inode: UInt64

        init?(path: String) {
            let opened = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard opened >= 0 else { return nil }
            var info = stat()
            guard fstat(opened, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
                close(opened)
                return nil
            }
            fd = opened
            device = UInt64(info.st_dev)
            inode = UInt64(info.st_ino)
        }

        deinit { close(fd) }

        func stillChecked() -> Bool {
            var info = stat()
            guard fstat(fd, &info) == 0 else { return false }
            return UInt64(info.st_dev) == device && UInt64(info.st_ino) == inode
        }
    }

    /// Ancestors held before a scratch leaf is created. A later rename of one
    /// of those directories does not redirect `mkdirat`.
    struct PinnedScratch {
        var directories: [HeldDirectory]
        var missing: [String]
    }

    /// Open every existing ancestor of `path` with `O_NOFOLLOW`. A symlink in
    /// the chain is not a directory this can hold.
    static func pinExistingAncestors(_ path: String) -> PinnedScratch? {
        guard path.hasPrefix("/") else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let root = HeldDirectory(path: "/") else { return nil }
        var directories = [root]
        var built = ""
        for (index, part) in parts.enumerated() {
            built += "/" + part
            var info = stat()
            if lstat(built, &info) != 0 {
                guard errno == ENOENT else { return nil }
                return PinnedScratch(directories: directories, missing: Array(parts[index...]))
            }
            let kind = info.st_mode & S_IFMT
            if kind == S_IFLNK { return nil }
            guard kind == S_IFDIR, let held = HeldDirectory(path: built) else { return nil }
            directories.append(held)
        }
        return PinnedScratch(directories: directories, missing: [])
    }

    /// Creates `path` by holding a descriptor for every ancestor. `O_NOFOLLOW`
    /// applies to each component, so swapping `~/Library` (the parent of the
    /// checked Caches directory) cannot `mkdirat` the leaf into the project.
    static func createCheckedDirectory(_ path: String) -> Bool {
        guard let pinned = pinExistingAncestors(path) else { return false }
        return createPinned(path, pinned: pinned)
    }

    /// `mkdirat` on the held ancestors. If a component's inode is no longer
    /// the one that was pinned, the path points at another directory: do not
    /// create the leaf. `afterAncestorMatch` runs once the openat walk has
    /// matched those inodes and before the leaf is created. A rename of the
    /// path string after that match must not mkdirat onto the old inode or
    /// return true: the profile allows the path string only when this returns
    /// true.
    static func createPinned(
        _ path: String, pinned: PinnedScratch, afterAncestorMatch: (() -> Void)? = nil
    ) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let existingCount = parts.count - pinned.missing.count
        guard existingCount == pinned.directories.count - 1, let last = pinned.directories.last, last.stillChecked()
        else { return false }
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let root = open("/", flags)
        guard root >= 0 else { return false }
        var opened = [root]
        defer { opened.forEach { close($0) } }
        var rootInfo = stat()
        guard fstat(root, &rootInfo) == 0,
            UInt64(rootInfo.st_dev) == pinned.directories[0].device,
            UInt64(rootInfo.st_ino) == pinned.directories[0].inode
        else { return false }
        var current = root
        if existingCount > 0 {
            for index in 0..<existingCount {
                let next = parts[index].withCString { openat(current, $0, flags) }
                guard next >= 0 else { return false }
                opened.append(next)
                var info = stat()
                guard fstat(next, &info) == 0 else { return false }
                let held = pinned.directories[index + 1]
                if UInt64(info.st_dev) != held.device || UInt64(info.st_ino) != held.inode {
                    return false
                }
                current = next
            }
        }
        var parent = stat()
        guard fstat(current, &parent) == 0,
            UInt64(parent.st_dev) == last.device,
            UInt64(parent.st_ino) == last.inode,
            last.stillChecked()
        else { return false }
        let existingPath = existingCount == 0 ? "/" : "/" + parts.prefix(existingCount).joined(separator: "/")
        afterAncestorMatch?()
        guard pathStillNames(existingPath, held: last) else { return false }
        guard createMissing(pinned.missing, parent: current) else { return false }
        guard pathStillNames(existingPath, held: last) else {
            removeCreated(pinned.missing, parent: current)
            return false
        }
        guard confirmLeafParent(pinned.missing, parent: current, held: last), last.stillChecked(),
            pathStillNames(existingPath, held: last)
        else {
            removeCreated(pinned.missing, parent: current)
            return false
        }
        return true
    }

    /// The path string still names the directory the walk opened. `lstat`
    /// does not follow a symlink planted on that path. A project moved onto
    /// `~/Library/Caches` after the openat match has a different inode.
    static func pathStillNames(_ path: String, held: HeldDirectory) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return false }
        return UInt64(info.st_dev) == held.device && UInt64(info.st_ino) == held.inode
    }

    /// Remove a suffix this call created on `parent` after the path string
    /// stopped naming that directory. The leaf must not stay in the directory
    /// that was renamed away.
    static func removeCreated(_ parts: [String], parent: Int32) {
        guard parts.isEmpty == false else { return }
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var current = parent
        var opened: [Int32] = []
        defer { opened.forEach { close($0) } }
        for part in parts {
            let next = part.withCString { openat(current, $0, flags) }
            guard next >= 0 else { return }
            opened.append(next)
            current = next
        }
        for index in parts.indices.reversed() {
            let directory = index == 0 ? parent : opened[index - 1]
            _ = parts[index].withCString { unlinkat(directory, $0, AT_REMOVEDIR) }
        }
    }

    /// The new leaf's parent is the pinned directory, or a directory this call
    /// created from that descriptor. A longer missing suffix is walked. It is
    /// not treated as already checked. A name that existed before `mkdirat`
    /// is not the leaf.
    static func confirmLeafParent(_ missing: [String], parent: Int32, held: HeldDirectory) -> Bool {
        guard missing.isEmpty == false else { return true }
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var current = parent
        var opened: [Int32] = []
        defer { opened.forEach { close($0) } }
        var info = stat()
        guard fstat(current, &info) == 0,
            UInt64(info.st_dev) == held.device,
            UInt64(info.st_ino) == held.inode
        else { return false }
        for part in missing {
            let next = part.withCString { openat(current, $0, flags) }
            guard next >= 0 else { return false }
            opened.append(next)
            var child = stat()
            guard fstat(next, &child) == 0, (child.st_mode & S_IFMT) == S_IFDIR else { return false }
            if UInt64(child.st_dev) == held.device && UInt64(child.st_ino) == held.inode {
                return false
            }
            current = next
        }
        return held.stillChecked()
    }

    /// `mkdirat` the missing suffix on a descriptor already opened with
    /// `O_NOFOLLOW`. A name that already exists was planted after the pin,
    /// including the project moved onto that component. A symlink swapped in
    /// for a missing name is not followed.
    static func createMissing(_ parts: [String], parent: Int32) -> Bool {
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var current = parent
        var opened: [Int32] = []
        defer { opened.forEach { close($0) } }
        for part in parts {
            var existing = stat()
            let present = part.withCString { fstatat(current, $0, &existing, AT_SYMLINK_NOFOLLOW) }
            if present == 0 { return false }
            let created = part.withCString { mkdirat(current, $0, mode_t(0o700)) }
            if created != 0 { return false }
            let next = part.withCString { openat(current, $0, flags) }
            guard next >= 0 else { return false }
            opened.append(next)
            current = next
        }
        return true
    }

    /// `mkdirat` each component on `held`. The leaf's parent is that
    /// descriptor (or a directory created from it), and the checked inode
    /// must be unchanged when the leaf is created.
    static func createRelative(_ parts: [String], holding held: HeldDirectory) -> Bool {
        guard held.stillChecked() else { return false }
        var current = held.fd
        var opened: [Int32] = []
        defer { opened.forEach { close($0) } }
        for (index, part) in parts.enumerated() {
            let created = part.withCString { mkdirat(current, $0, mode_t(0o700)) }
            if created != 0 && errno != EEXIST { return false }
            guard held.stillChecked() else { return false }
            let next = part.withCString { openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard next >= 0 else { return false }
            if index + 1 == parts.count {
                var parent = stat()
                guard fstat(current, &parent) == 0 else {
                    close(next)
                    return false
                }
                if current == held.fd {
                    guard UInt64(parent.st_dev) == held.device, UInt64(parent.st_ino) == held.inode else {
                        close(next)
                        return false
                    }
                }
            }
            opened.append(next)
            current = next
        }
        return held.stillChecked()
    }

}
