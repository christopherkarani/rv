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
        // createPinned records the leaf it created and that leaf's parent.
        // Moving the leaf inode into a planted rv-mcp/<server> keeps the
        // inode and changes the parent. A path that is simply gone is the
        // same swap with nothing planted there.
        if let recorded = createdLeafIdentity(scratch), leafIdentity(scratch) != recorded {
            let resolved = realPath(scratch)
            return "\(MCPDisplayedText.field(scratch)) resolves to \(MCPDisplayedText.field(resolved)), which was not the path reviewed"
        }
        if resolveExisting(scratch) == nil {
            let resolved = realPath(scratch)
            if sameReviewedDirectory(scratch, resolved) {
                return "\(MCPDisplayedText.field(scratch)) resolves to \(MCPDisplayedText.field(resolved)), which was not the path reviewed"
            }
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
                var roots = spellings + seatbeltSpellings(resolved)
                for opening in missingSymlinkOpenings(path) {
                    roots.append(opening)
                    roots.append(contentsOf: seatbeltSpellings(opening))
                }
                for spelling in roots {
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

    /// The leaf does not exist yet. Walk the path the kernel walks: follow a
    /// symlink, then let `..` mean that directory's parent. Popping `..` in
    /// the string first turns `jump/../private/tmp/...` into a home path and
    /// leaves the `/private/tmp` allow in front of the real target.
    /// A component that does not exist yet is collapsed only in the suffix,
    /// so `no-such/../future-keys` is still `future-keys`. `URL` is not used:
    /// a last component of `..` must not grow the path.
    static func resolvingMissingSuffix(_ path: String) -> String {
        guard path.hasPrefix("/") else { return lexicalAbsolute(path) }
        return resolvingWalk(path, followsLeft: 32)
    }

    private static func resolvingWalk(_ path: String, followsLeft: Int) -> String {
        var current = "/"
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var index = 0
        while index < parts.count {
            let part = parts[index]
            index += 1
            if part == "." { continue }
            if part == ".." {
                current = parentDirectory(current)
                continue
            }
            let next = current == "/" ? "/" + part : current + "/" + part
            if let link = readLink(next) {
                guard followsLeft > 0 else {
                    return lexicalJoin(current, [part] + Array(parts[index...]))
                }
                let absolute = link.hasPrefix("/") ? link : (current == "/" ? "/" + link : current + "/" + link)
                let rest = parts[index...].joined(separator: "/")
                let continued = rest.isEmpty ? absolute : absolute + "/" + rest
                return resolvingWalk(continued, followsLeft: followsLeft - 1)
            }
            if isRealDirectory(next) {
                current = next
                continue
            }
            return lexicalJoin(current, [part] + Array(parts[index...]))
        }
        return current
    }

    /// Paths `open` can read after the profile is built. A missing component
    /// under a write allow can be created as a symlink. `part` → `/part`
    /// makes `jump/../private/tmp/future-keys` and `jump/foo/../../...` read
    /// `/private/tmp/future-keys`, which the lexical doubled path does not
    /// name. The doubled path stays denied too: without that symlink, `open`
    /// still names it.
    static func missingSymlinkOpenings(_ path: String) -> [String] {
        guard path.hasPrefix("/") else { return [] }
        return symlinkOpenings(path, followsLeft: 32)
    }

    private static func symlinkOpenings(_ path: String, followsLeft: Int, afterSymlink: Bool = false) -> [String] {
        var current = "/"
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var index = 0
        while index < parts.count {
            let part = parts[index]
            index += 1
            if part == "." { continue }
            if part == ".." {
                current = parentDirectory(current)
                continue
            }
            let next = current == "/" ? "/" + part : current + "/" + part
            if let link = readLink(next) {
                guard followsLeft > 0 else { return [] }
                var absolute = link.hasPrefix("/") ? link : (current == "/" ? "/" + link : current + "/" + link)
                var rest = Array(parts[index...])
                while let first = rest.first, first == "." || first == ".." {
                    rest.removeFirst()
                    if first == ".." { absolute = parentDirectory(absolute) }
                }
                if let name = rest.first {
                    let child = absolute == "/" ? "/" + name : absolute + "/" + name
                    if readLink(child) == nil, isRealDirectory(child) == false {
                        return openingsFromMissing(parent: absolute, parts: rest, origin: path)
                    }
                }
                let continuedRest = rest.joined(separator: "/")
                let continued = continuedRest.isEmpty ? absolute : absolute + "/" + continuedRest
                return symlinkOpenings(continued, followsLeft: followsLeft - 1, afterSymlink: true)
            }
            if isRealDirectory(next) {
                current = next
                continue
            }
            // A directory that already exists is not the opening. A later
            // missing name under it can still be created as a symlink, and
            // that link can point at an ancestor, not only at `/<name>`.
            guard afterSymlink else { return [] }
            return openingsFromMissing(parent: current, parts: [part] + Array(parts[index...]), origin: path)
        }
        return []
    }

    /// The first missing name can be created as a directory, and a later
    /// name is then the symlink. Each missing name is an opening.
    /// When `/<name>` and the ancestors already collapse to one path
    /// (`../private/tmp/future-keys`), that path is the whole set.
    /// `link/../../../future-keys` collapses to `/future-keys`, and
    /// `link/../../../foo/future-keys` collapses to `/foo/future-keys`.
    /// Neither is the file `open` reads after a deep relative symlink.
    private static func openingsFromMissing(parent: String, parts: [String], origin: String) -> [String] {
        guard let name = parts.first else { return [] }
        let tail = Array(parts.dropFirst())
        let primary = syntheticOpenings(parent: parent, name: name, tail: tail, origin: origin, includeCreationDirectory: false)
        if tail.isEmpty || collapsedOpeningCoversTheParent(primary, parent: parent, tail: tail) {
            return primary
        }
        var results = syntheticOpenings(parent: parent, name: name, tail: tail, origin: origin, includeCreationDirectory: true)
        let nextParent = parent == "/" ? "/" + name : parent + "/" + name
        for opening in openingsFromMissing(parent: nextParent, parts: tail, origin: origin)
            where results.contains(opening) == false {
            results.append(opening)
        }
        return results
    }

    /// One collapsed opening is the whole set when the tail has no `..`, or
    /// when that `..` run cannot leave the directory the name is created in
    /// and the collapsed path still begins on that directory.
    /// `/foo/future-keys` is as deep as `/private/tmp` and is a different
    /// tree: `link/../../../foo/future-keys` then `ln -s .` reads
    /// `/private/tmp/future-keys`. `foo/../../private/tmp/future-keys` stays
    /// on `/private/tmp/future-keys` and is the whole set.
    private static func collapsedOpeningCoversTheParent(
        _ primary: [String], parent: String, tail: [String]
    ) -> Bool {
        guard primary.count <= 1 else { return false }
        guard tail.contains(".."), let opened = primary.first else { return true }
        let parentParts = parent.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let openedParts = opened.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if openedParts.count < parentParts.count { return false }
        var dots = 0
        for part in tail {
            if part == ".." {
                dots += 1
            } else {
                break
            }
        }
        // Enough `..` to leave the creation directory. Later names can be
        // `ln -s .` and still name a file under that directory.
        if dots >= parentParts.count { return false }
        var shared = 0
        for (parentPart, openedPart) in zip(parentParts, openedParts) {
            if parentPart != openedPart { break }
            shared += 1
        }
        return shared >= parentParts.count - dots
    }

    /// Openings for a component that does not exist yet. `name` → `/name`
    /// keeps `../private/tmp/...` and `foo/../../...` on `/private/tmp/...`.
    /// The same component can instead point at an ancestor of the directory
    /// it is created in (`x` → `/private`, `tmp` → `/private/tmp`). A final
    /// missing name can point at that directory itself.
    private static func syntheticOpenings(
        parent: String, name: String, tail: [String], origin: String, includeCreationDirectory: Bool = false
    ) -> [String] {
        var results: [String] = []
        func add(_ base: String) {
            let combined: String
            if tail.isEmpty {
                combined = base
            } else if base == "/" {
                combined = "/" + tail.joined(separator: "/")
            } else {
                combined = base + "/" + tail.joined(separator: "/")
            }
            let opened = resolvingMissingSuffix(combined)
            if opened != origin, results.contains(opened) == false {
                results.append(opened)
            }
        }
        add("/" + name)
        var ancestor = parentDirectory(parent)
        while ancestor != "/" {
            add(ancestor)
            ancestor = parentDirectory(ancestor)
        }
        // `.` is this directory even when the tail is not empty
        // (`ln -s .` then `future-keys`). A final name already includes it.
        if includeCreationDirectory || tail.isEmpty {
            add(parent)
        }
        return results
    }

    private static func parentDirectory(_ path: String) -> String {
        guard path != "/" else { return "/" }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count > 1 else { return "/" }
        return "/" + parts.dropLast().joined(separator: "/")
    }

    /// Collapse `.` and `..` in a suffix onto a directory the walk already
    /// reached. `URL` is not used, so a missing `..` does not grow the path.
    private static func lexicalJoin(_ base: String, _ suffix: [String]) -> String {
        let combined = (base == "/" ? "" : base) + "/" + suffix.joined(separator: "/")
        return lexicalAbsolute(combined)
    }

    /// Collapse `.` and `..` without asking `URL` to delete a component.
    /// Used for the not-yet-existing suffix. A symlink component is followed
    /// by the walk before this runs, so `..` is not popped past that link.
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

    private static func isRealDirectory(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR
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
        var body = parts.map { caseFold($0) }.joined(separator: "/+(\\./+)*")
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

    /// Case-fold a path component. One-scalar folds become a class (`s` is
    /// `[Ssſ]`, `σ` includes final sigma). A fold of more than one scalar
    /// (`ß`/`ẞ` → `ss`, `ﬁ` → `fi`, `ﬅ`/`ﬆ` → `st`, `ﬀ` → `ff`, `İ` → `i`
    /// plus U+0307) is an alternation, so either spelling matches. U+017F
    /// stays optional beside each scalar (`fuſture-keys`). A quote is still
    /// escaped inside the atom.
    static func caseFold(_ component: String) -> String {
        var folded: [Unicode.Scalar] = []
        for scalar in component.unicodeScalars {
            folded.append(contentsOf: fullFoldScalars(scalar))
        }
        return caseFoldPattern(folded)
    }

    /// Unicode full casefold where Swift's per-scalar upper+lower is not.
    /// `ẞ`.uppercased().lowercased() is `ß`, not `ss`.
    private static func fullFoldScalars(_ scalar: Unicode.Scalar) -> [Unicode.Scalar] {
        if let override = fullFoldOverrides[scalar.value] { return override }
        let folded = Array(String(scalar).uppercased().lowercased().unicodeScalars)
        return folded.isEmpty ? [scalar] : folded
    }

    private static let fullFoldOverrides: [UInt32: [Unicode.Scalar]] = [
        0x00DF: Array("ss".unicodeScalars),
        0x1E9E: Array("ss".unicodeScalars),
        0x0130: Array("i\u{0307}".unicodeScalars),
        0xFB00: Array("ff".unicodeScalars),
        0xFB01: Array("fi".unicodeScalars),
        0xFB02: Array("fl".unicodeScalars),
        0xFB03: Array("ffi".unicodeScalars),
        0xFB04: Array("ffl".unicodeScalars),
        0xFB05: Array("st".unicodeScalars),
        0xFB06: Array("st".unicodeScalars),
    ]

    private struct FoldTables {
        var single: [UInt32: [Unicode.Scalar]]
        var multi: [String: [Unicode.Scalar]]
    }

    /// Scalars grouped by full casefold, through U+10FFFF. A non-BMP small
    /// letter and its capital are one class (`𐐨` includes `𐐀`), not a
    /// single hard-coded pair. Uncased non-BMP scalars fold to themselves
    /// and stay out of the table. Multi-scalar folds are not members of
    /// the one-scalar class.
    private static let foldTables: FoldTables = {
        var single: [UInt32: [Unicode.Scalar]] = [:]
        var multi: [String: [Unicode.Scalar]] = [:]
        for value in 0...0x10FFFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            if value > 0xFFFF, scalar.properties.isCased == false { continue }
            let folded = fullFoldScalars(scalar)
            if folded.count == 1, let key = folded.first {
                single[key.value, default: []].append(scalar)
            } else {
                multi[scalarString(folded), default: []].append(scalar)
            }
        }
        return FoldTables(single: single, multi: multi)
    }()

    private static func caseFoldPattern(_ folded: [Unicode.Scalar]) -> String {
        var memo: [Int: String] = [:]
        func emit(_ index: Int) -> String {
            if let stored = memo[index] { return stored }
            guard index < folded.count else {
                memo[index] = ""
                return ""
            }
            if let run = homogeneousRun(folded, from: index),
               let compact = repeatedScalarPattern(folded[index], count: run) {
                // `st` is only two scalars, so `ﬅ`/`ﬆ` starts on the last `s`
                // of a run. The compact `ss` pattern would otherwise hand the
                // following `t` to its own atom and drop the ligature.
                let stayed = compact + emit(index + run)
                let pattern: String
                if let bridge = leavingPairPattern(folded, at: index + run - 1),
                   let shorter = repeatedScalarPattern(folded[index], count: run - 1) {
                    let crossed = shorter + bridge + emit(index + run + 1)
                    pattern = "(" + stayed + "|" + crossed + ")"
                } else {
                    pattern = stayed
                }
                memo[index] = pattern
                return pattern
            }
            let one = foldAtom(folded[index]) + "\u{017F}?"
            var spans: [(length: Int, pattern: String)] = []
            let longest = min(3, folded.count - index)
            if longest >= 2 {
                for length in 2...longest {
                    let key = scalarString(Array(folded[index..<(index + length)]))
                    guard let forms = foldTables.multi[key], forms.isEmpty == false else { continue }
                    let body = forms.map { regexEscape(String($0)) }.joined(separator: "|")
                    spans.append((length, "(\(body))\u{017F}?"))
                }
            }
            if spans.isEmpty {
                let pattern = one + emit(index + 1)
                memo[index] = pattern
                return pattern
            }
            let clean = spans.filter { span in
                (1..<span.length).allSatisfy { multiSpan(folded, at: index + $0) == nil }
            }
            if clean.count == spans.count, Set(clean.map(\.length)).count == 1, let length = clean.first?.length {
                var short = ""
                for offset in 0..<length {
                    short += foldAtom(folded[index + offset]) + "\u{017F}?"
                }
                let choices = [short] + clean.map(\.pattern)
                let pattern = "(" + choices.joined(separator: "|") + ")" + emit(index + length)
                memo[index] = pattern
                return pattern
            }
            // Overlapping folds (`ff` beside `ffi`) keep every alternation.
            // The continuation is shared through `memo`; it is not dropped
            // once the text gets long.
            var choices = [one + emit(index + 1)]
            for span in spans {
                choices.append(span.pattern + emit(index + span.length))
            }
            let pattern = "(" + choices.joined(separator: "|") + ")"
            memo[index] = pattern
            return pattern
        }
        return emit(0)
    }

    /// A run of one scalar whose only multi-scalar fold inside the run is
    /// that scalar repeated (`ss`, `ff`). A longer fold that leaves the run
    /// (`ffi`) stays on the mixed path so both spellings are still
    /// alternations. A length-2 fold that starts on the last copy (`st`)
    /// is bridged at the call site; it is not a reason to leave this path.
    private static func homogeneousRun(_ folded: [Unicode.Scalar], from index: Int) -> Int? {
        let scalar = folded[index]
        var end = index + 1
        while end < folded.count, folded[end] == scalar { end += 1 }
        let count = end - index
        guard count >= 2 else { return nil }
        let pair = scalarString([scalar, scalar])
        guard foldTables.multi[pair]?.isEmpty == false else { return nil }
        for start in index..<end {
            guard let span = multiSpan(folded, at: start), span.length > 2 else { continue }
            if folded[start + span.length - 1] != scalar { return nil }
        }
        return count
    }

    private static func multiSpan(_ folded: [Unicode.Scalar], at index: Int) -> (length: Int, pattern: String)? {
        let longest = min(3, folded.count - index)
        guard longest >= 2 else { return nil }
        for length in stride(from: longest, through: 2, by: -1) {
            let key = scalarString(Array(folded[index..<(index + length)]))
            guard let forms = foldTables.multi[key], forms.isEmpty == false else { continue }
            let body = forms.map { regexEscape(String($0)) }.joined(separator: "|")
            return (length, "(\(body))\u{017F}?")
        }
        return nil
    }

    /// A length-2 fold that consumes the last copy of a homogeneous run and
    /// the scalar after it (`s` + `t` → `ﬅ`/`ﬆ`). The run stays compact; this
    /// alternation keeps the ligature without copying the tail into every `ß`.
    private static func leavingPairPattern(_ folded: [Unicode.Scalar], at index: Int) -> String? {
        guard index + 1 < folded.count, folded[index] != folded[index + 1] else { return nil }
        let key = scalarString([folded[index], folded[index + 1]])
        guard let forms = foldTables.multi[key], forms.isEmpty == false else { return nil }
        let body = forms.map { regexEscape(String($0)) }.joined(separator: "|")
        return "(\(body))\u{017F}?"
    }

    /// Exactly `count` folded copies of `scalar`, including a weight-2
    /// spelling at any alignment. The tail is not copied into each
    /// alternative, so a long run keeps `(ß|ẞ)` instead of dropping it.
    private static func repeatedScalarPattern(_ scalar: Unicode.Scalar, count: Int) -> String? {
        let pair = scalarString([scalar, scalar])
        guard let forms = foldTables.multi[pair], forms.isEmpty == false else { return nil }
        let atom = "(" + foldAtom(scalar) + "\u{017F}?)"
        let wide = "(" + forms.map { regexEscape(String($0)) }.joined(separator: "|") + ")\u{017F}?"
        // The next scalar is not another copy of this run. A's may sit on
        // either side of a weight-2 spelling; the token count fixes the weight.
        let boundary = "(?!" + atom + "|" + wide + ")"
        var alts: [String] = []
        for copies in 0...(count / 2) {
            let singles = count - 2 * copies
            let tokens = singles + copies
            let look = "(?=(" + atom + "*" + wide + "){\(copies)}" + atom + "*" + boundary + ")"
            let body = "(" + atom + "|" + wide + "){\(tokens)}"
            alts.append("(" + look + body + ")")
        }
        return "(" + alts.joined(separator: "|") + ")"
    }

    private static func foldAtom(_ scalar: Unicode.Scalar) -> String {
        let equivalents = foldTables.single[scalar.value] ?? [scalar]
        if equivalents.count > 1 {
            return "[" + characterClassBody(equivalents) + "]"
        }
        return regexEscape(String(scalar))
    }

    private static func scalarString(_ scalars: [Unicode.Scalar]) -> String {
        var text = ""
        for scalar in scalars { text.unicodeScalars.append(scalar) }
        return text
    }

    private static func characterClassBody(_ scalars: [Unicode.Scalar]) -> String {
        var body = ""
        for scalar in scalars {
            switch scalar {
            case "\\", "]", "^", "-":
                body += "\\"
                body.unicodeScalars.append(scalar)
            default:
                body.unicodeScalars.append(scalar)
            }
        }
        return body
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
        let watched = watchedWritableRoots(path)
        let watchedBefore = watched.map(treeStamp)
        afterAncestorMatch?()
        guard pathStillNames(existingPath, held: last) else { return false }
        // A rename into an existing child does not change the watched
        // directory's own link count or timestamps. The child's stamp does.
        if zip(watched, watchedBefore).contains(where: { treeStamp($0.0) != $0.1 }) {
            return false
        }
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
        rememberLeafIdentity(path)
        return true
    }

    /// `Library/Caches`, `~/.npm`, and `~/.cache`. The profile allows all
    /// three. Moving a project into a directory that already exists does not
    /// change that directory's inode: `rename` into a non-empty directory
    /// keeps it. The link count and timestamps do change.
    private static func watchedWritableRoots(_ scratch: String) -> [String] {
        guard let marker = scratch.range(of: "/Library/Caches/") else { return [] }
        let home = String(scratch[..<marker.lowerBound])
        return [home + "/Library/Caches", home + "/.npm", home + "/.cache"]
    }

    private struct InodeStamp: Equatable {
        var present: Bool
        var device: UInt64
        var inode: UInt64
        var links: UInt64
        var modified: Int64
        var modifiedNsec: Int64
        var changed: Int64
        var changedNsec: Int64
        /// Set when `path` is a symlink. The target directory can be unlistable
        /// on both reads; a move into it still changes this link count.
        var targetPresent: Bool = false
        var targetDevice: UInt64 = 0
        var targetInode: UInt64 = 0
        var targetLinks: UInt64 = 0
        var targetModified: Int64 = 0
        var targetModifiedNsec: Int64 = 0
        var targetChanged: Int64 = 0
        var targetChangedNsec: Int64 = 0
    }

    private static func inodeStamp(_ path: String) -> InodeStamp {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            return InodeStamp(
                present: false, device: 0, inode: 0, links: 0,
                modified: 0, modifiedNsec: 0, changed: 0, changedNsec: 0)
        }
        let clock = directoryClock(info)
        return InodeStamp(
            present: true, device: UInt64(info.st_dev), inode: UInt64(info.st_ino), links: UInt64(info.st_nlink),
            modified: clock.modified, modifiedNsec: clock.modifiedNsec,
            changed: clock.changed, changedNsec: clock.changedNsec)
    }

    /// The watched directory and every directory under it, including the
    /// directory a symlink already names. Moving a project into a grandchild
    /// changes that directory's link count and timestamps. A direct child's
    /// own stamp does not. The symlink's inode stays in the stamp, so
    /// replacing a directory with a link still changes it. The target
    /// directory's own inode is on that same stamp: its link count is the
    /// change a move into it leaves behind. A child that already exists under
    /// an unlistable target is on the stamp too. Listing that target adds the
    /// owner's read bit and restores the mode; chmod changes ctime, so that
    /// ctime is not part of the stamp. The child's link count is.
    private struct TreeStamp: Equatable {
        var root: InodeStamp
        var children: [String: InodeStamp]
    }

    private struct DirectoryWalk {
        var stamps: [String: InodeStamp]
        var clearedChangeTime: Bool
    }

    private static func treeStamp(_ path: String) -> TreeStamp {
        var visited: Set<String> = []
        if let identity = directoryIdentity(path) {
            visited.insert(identity)
        }
        var root = inodeStamp(path)
        let walked = directoryStamps(under: path, relative: "", visited: &visited)
        if walked.clearedChangeTime {
            root.changed = 0
            root.changedNsec = 0
        }
        return TreeStamp(root: root, children: walked.stamps)
    }

    private static func directoryStamps(
        under path: String, relative: String, visited: inout Set<String>
    ) -> DirectoryWalk {
        var stamps: [String: InodeStamp] = [:]
        let listed = listDirectory(path)
        guard let names = listed.names else {
            return DirectoryWalk(stamps: stamps, clearedChangeTime: listed.clearedChangeTime)
        }
        for name in names where name != "." && name != ".." {
            let child = path == "/" ? "/" + name : path + "/" + name
            var info = stat()
            guard lstat(child, &info) == 0 else { continue }
            let kind = info.st_mode & S_IFMT
            guard kind == S_IFDIR || kind == S_IFLNK else { continue }
            let rel = relative.isEmpty ? name : relative + "/" + name
            let entered: String?
            if kind == S_IFDIR {
                stamps[rel] = inodeStamp(child)
                entered = child
            } else {
                entered = symlinkDirectory(child)
                if let entered {
                    stamps[rel] = stampNotingTarget(child, target: entered)
                } else {
                    stamps[rel] = inodeStamp(child)
                }
            }
            guard let entered, let identity = directoryIdentity(entered), visited.insert(identity).inserted else {
                continue
            }
            let nested = directoryStamps(under: entered, relative: rel, visited: &visited)
            if nested.clearedChangeTime, var stamp = stamps[rel] {
                if kind == S_IFDIR {
                    stamp.changed = 0
                    stamp.changedNsec = 0
                } else {
                    stamp.targetChanged = 0
                    stamp.targetChangedNsec = 0
                }
                stamps[rel] = stamp
            }
            for (deeper, stamp) in nested.stamps {
                stamps[deeper] = stamp
            }
        }
        return DirectoryWalk(stamps: stamps, clearedChangeTime: listed.clearedChangeTime)
    }

    /// Names in `path`. Mode `0111` cannot be listed. The owner read bit is
    /// added for this call and the mode is put back. `chmod` updates ctime
    /// and leaves mtime and the link count alone, so the caller drops ctime.
    private static func listDirectory(_ path: String) -> (names: [String]?, clearedChangeTime: Bool) {
        if let names = try? FileManager.default.contentsOfDirectory(atPath: path) {
            return (names, false)
        }
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            return (nil, false)
        }
        let mode = info.st_mode & 0o7777
        guard (mode & S_IRUSR) == 0, chmod(path, mode | S_IRUSR) == 0 else {
            return (nil, false)
        }
        defer { _ = chmod(path, mode) }
        return (try? FileManager.default.contentsOfDirectory(atPath: path), true)
    }

    /// The symlink's own inode, plus the directory it names. Listing that
    /// directory can fail (mode `0111`) while its link count still changes.
    private static func stampNotingTarget(_ path: String, target: String) -> InodeStamp {
        var stamp = inodeStamp(path)
        let noted = inodeStamp(target)
        stamp.targetPresent = noted.present
        stamp.targetDevice = noted.device
        stamp.targetInode = noted.inode
        stamp.targetLinks = noted.links
        stamp.targetModified = noted.modified
        stamp.targetModifiedNsec = noted.modifiedNsec
        stamp.targetChanged = noted.changed
        stamp.targetChangedNsec = noted.changedNsec
        return stamp
    }

    /// The real directory a symlink names, relative target included.
    /// A link that does not name a directory is only its own inode.
    private static func symlinkDirectory(_ path: String) -> String? {
        guard let raw = readLink(path) else { return nil }
        let absolute: String
        if raw.hasPrefix("/") {
            absolute = raw
        } else {
            let parent = parentDirectory(path)
            absolute = parent == "/" ? "/" + raw : parent + "/" + raw
        }
        guard let resolved = resolveExisting(absolute) else { return nil }
        guard directoryIdentity(resolved) != nil else { return nil }
        return resolved
    }

    private static func directoryIdentity(_ path: String) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return "\(UInt64(info.st_dev)):\(UInt64(info.st_ino))"
    }

    private static func directoryClock(_ info: stat) -> (modified: Int64, modifiedNsec: Int64, changed: Int64, changedNsec: Int64) {
        #if canImport(Darwin)
        return (
            Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec),
            Int64(info.st_ctimespec.tv_sec), Int64(info.st_ctimespec.tv_nsec))
        #else
        return (
            Int64(info.st_mtim.tv_sec), Int64(info.st_mtim.tv_nsec),
            Int64(info.st_ctim.tv_sec), Int64(info.st_ctim.tv_nsec))
        #endif
    }

    private struct AncestorPin: Equatable {
        var device: UInt64
        var inode: UInt64
    }

    private struct LeafIdentity: Equatable {
        var present: Bool
        var device: UInt64
        var inode: UInt64
        var parentDevice: UInt64
        var parentInode: UInt64
        /// Parent, then each directory above it. Moving `rv-mcp` together
        /// with the leaf keeps those two inodes and changes `Caches`.
        var ancestors: [AncestorPin]
        /// `~/Library/Caches`, `~/.npm`, and `~/.cache` at the moment the leaf
        /// was recorded. A later move into a grandchild does not change the
        /// ancestor inodes. `profile` re-reads these stamps.
        var watched: [String: TreeStamp]
    }

    private final class LeafRecords: @unchecked Sendable {
        let lock = NSLock()
        var values: [String: LeafIdentity] = [:]
    }

    private static let leafRecords = LeafRecords()

    private static func leafIdentity(_ path: String) -> LeafIdentity {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            return LeafIdentity(
                present: false, device: 0, inode: 0, parentDevice: 0, parentInode: 0,
                ancestors: [], watched: [:])
        }
        var parentInfo = stat()
        let parent = parentDirectory(path)
        let parentOK = lstat(parent, &parentInfo) == 0
        return LeafIdentity(
            present: true, device: UInt64(info.st_dev), inode: UInt64(info.st_ino),
            parentDevice: parentOK ? UInt64(parentInfo.st_dev) : 0,
            parentInode: parentOK ? UInt64(parentInfo.st_ino) : 0,
            ancestors: ancestorPins(parent),
            watched: watchedStamps(path))
    }

    private static func watchedStamps(_ path: String) -> [String: TreeStamp] {
        var stamps: [String: TreeStamp] = [:]
        for root in watchedWritableRoots(path) {
            stamps[root] = treeStamp(root)
        }
        return stamps
    }

    private static func ancestorPins(_ path: String) -> [AncestorPin] {
        var pins: [AncestorPin] = []
        var current = path
        while true {
            var info = stat()
            if lstat(current, &info) == 0 {
                pins.append(AncestorPin(device: UInt64(info.st_dev), inode: UInt64(info.st_ino)))
            } else {
                pins.append(AncestorPin(device: 0, inode: 0))
            }
            if current == "/" { break }
            current = parentDirectory(current)
        }
        return pins
    }

    private static func rememberLeafIdentity(_ path: String) {
        let identity = leafIdentity(path)
        leafRecords.lock.lock()
        leafRecords.values[path] = identity
        leafRecords.lock.unlock()
    }

    private static func createdLeafIdentity(_ path: String) -> LeafIdentity? {
        leafRecords.lock.lock()
        defer { leafRecords.lock.unlock() }
        return leafRecords.values[path]
    }

    /// The path string still names the directory the walk opened. Each
    /// component is opened with `O_NOFOLLOW`, so a symlink planted on an
    /// ancestor (`~/Library` → project) is not the pinned Caches inode.
    /// `lstat` of the final path would follow that ancestor. A project moved
    /// onto `~/Library/Caches` has a different inode.
    static func pathStillNames(_ path: String, held: HeldDirectory) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let root = open("/", flags)
        guard root >= 0 else { return false }
        var current = root
        var opened = [root]
        defer { opened.forEach { close($0) } }
        for part in parts {
            let next = part.withCString { openat(current, $0, flags) }
            guard next >= 0 else { return false }
            opened.append(next)
            current = next
        }
        var info = stat()
        guard fstat(current, &info) == 0 else { return false }
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
