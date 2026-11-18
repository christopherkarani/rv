#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Bounds on one `rv workspace upload` or `download`.
public struct WorkspaceTransferLimits: Sendable, Equatable {
    /// Files and directories, the transferred top included.
    public var maxEntries: Int
    /// Bytes of file content, planned and actually copied.
    public var maxBytes: UInt64
    /// Components below the transferred top.
    public var maxDepth: Int

    public init(maxEntries: Int, maxBytes: UInt64, maxDepth: Int) {
        self.maxEntries = maxEntries
        self.maxBytes = maxBytes
        self.maxDepth = maxDepth
    }

    public static let standard = WorkspaceTransferLimits(maxEntries: 20_000, maxBytes: 2 << 30, maxDepth: 64)
}

public struct WorkspaceTransferSummary: Sendable, Equatable {
    public let files: Int
    public let directories: Int
    public let bytes: UInt64
    /// Entries `.gitignore` (or the `.git` rule) left out.
    public let ignored: Int

    public init(files: Int, directories: Int, bytes: UInt64, ignored: Int) {
        self.files = files
        self.directories = directories
        self.bytes = bytes
        self.ignored = ignored
    }
}

/// Why a transfer did not happen, or stopped. Paths are the caller's
/// spelling (host paths) or workspace/tree-relative, with control
/// characters escaped (`\x0a`).
public enum WorkspaceTransferRefusal: Error, Sendable, Equatable, CustomStringConvertible {
    /// `..`, a relative host path, an absolute workspace path, empty, or control characters.
    case unsafePath(String)
    case missing(String)
    /// Transfers never read, write or copy through a symlink.
    case symlink(String)
    /// A FIFO, socket or device.
    case specialFile(String)
    /// A name that is not UTF-8, too long, or holds control characters.
    case unsafeName(String)
    /// Another file system inside the tree.
    case otherDevice(String)
    /// An upload source file with another name elsewhere on the host.
    case hardLinked(String)
    /// An upload source inside or containing rv's config dir or the workspace.
    case protectedSource(String)
    /// A workspace control or run-later path, or a host path under rv's
    /// config or install dirs or inside the workspace.
    case protectedDestination(String)
    case destinationExists(String)
    /// An upload would put a file where a directory is, or the reverse.
    case destinationConflict(String)
    case tooManyEntries(Int)
    case tooLarge(UInt64)
    case tooDeep(Int)
    case nothingSelected
    /// The tree changed between planning and copying.
    case changed(String)
    case io(String, Int32)

    public var description: String {
        switch self {
        case .unsafePath(let path): "\(path): unsafe path (no '..', host paths absolute, workspace paths relative)"
        case .missing(let path): "\(path): no such file or directory"
        case .symlink(let path): "\(path) is a symlink; transfers do not follow or copy symlinks"
        case .specialFile(let path): "\(path) is not a regular file or directory"
        case .unsafeName(let path): "\(path): unsafe file name"
        case .otherDevice(let path): "\(path) is on another file system"
        case .hardLinked(let path): "\(path) has other hard links; uploads refuse aliased files"
        case .protectedSource(let path): "\(path) is, holds, or is inside rv's config dir or the workspace"
        case .protectedDestination(let path): "\(path) is a protected path"
        case .destinationExists(let path): "\(path) already exists; choose a new destination"
        case .destinationConflict(let path): "\(path) exists with a different type"
        case .tooManyEntries(let limit): "more than \(limit) files and directories"
        case .tooLarge(let limit): "more than \(limit) bytes"
        case .tooDeep(let limit): "nested more than \(limit) directories deep"
        case .nothingSelected: "nothing to copy (everything is ignored)"
        case .changed(let path): "\(path) changed during the transfer; nothing more was copied"
        case .io(let path, let code): "\(path): \(String(cString: strerror(code)))"
        }
    }
}

/// Copy host files into the live workspace (`source` is owner-named).
public struct WorkspaceUploadRequest: Sendable {
    public let source: String
    public let workspace: String
    /// Workspace-relative. Nil is the source's name at the workspace root;
    /// `.` merges a directory into the workspace root.
    public let destination: String?
    /// Host directories no upload may read from (rv's config dir).
    public let protectedRoots: [String]
    public let gitignore: Bool
    public let limits: WorkspaceTransferLimits

    public init(
        source: String, workspace: String, destination: String?, protectedRoots: [String],
        gitignore: Bool, limits: WorkspaceTransferLimits = .standard
    ) {
        self.source = source
        self.workspace = workspace
        self.destination = destination
        self.protectedRoots = protectedRoots
        self.gitignore = gitignore
        self.limits = limits
    }
}

/// Copy workspace files to a new host path the owner names.
public struct WorkspaceDownloadRequest: Sendable {
    public let workspace: String
    /// Workspace-relative; `.` is the whole workspace.
    public let source: String
    /// Absolute host path that must not exist yet.
    public let destination: String
    /// Host directories no download may write into (rv's config and
    /// install dirs). The workspace is always protected too.
    public let protectedRoots: [String]
    public let gitignore: Bool
    public let limits: WorkspaceTransferLimits

    public init(
        workspace: String, source: String, destination: String, protectedRoots: [String],
        gitignore: Bool, limits: WorkspaceTransferLimits = .standard
    ) {
        self.workspace = workspace
        self.source = source
        self.destination = destination
        self.protectedRoots = protectedRoots
        self.gitignore = gitignore
        self.limits = limits
    }
}

/// File transfer between the host and a live workspace.
///
/// Every guest (Seatbelt, the Linux micro-VM and the macOS VM) works on
/// the workspace volume mounted at the project path, so the host side of a
/// transfer is a copy between that volume and a host path: no guest
/// channel, and the guest never names a host path. Each tree is planned
/// first (names, types, caps, protected paths) and then copied by
/// descriptor, one `openat(O_NOFOLLOW)` per component, so a symlink or a
/// swapped directory cannot redirect a read or write. A download writes
/// only below a destination it creates, and removes it on failure.
public enum WorkspaceTransfer {
    public static func upload(_ request: WorkspaceUploadRequest) -> Result<WorkspaceTransferSummary, WorkspaceTransferRefusal> {
        switch prepareUpload(request) {
        case .failure(let refusal):
            return .failure(refusal)
        case .success(let prepared):
            defer { prepared.release() }
            return copyUpload(prepared, limits: request.limits)
        }
    }

    public static func download(_ request: WorkspaceDownloadRequest) -> Result<WorkspaceTransferSummary, WorkspaceTransferRefusal> {
        switch prepareDownload(request) {
        case .failure(let refusal):
            return .failure(refusal)
        case .success(let prepared):
            defer { prepared.release() }
            return copyDownload(prepared, limits: request.limits)
        }
    }

    // MARK: - Paths (pure)

    /// Workspace-relative components: `.` and empty segments dropped, `..`,
    /// a leading `/`, control characters and unsafe names refused.
    static func workspaceComponents(_ path: String) -> Result<[String], WorkspaceTransferRefusal> {
        guard path.isEmpty == false, path.hasPrefix("/") == false, hasControlCharacter(path) == false else {
            return .failure(.unsafePath(escaped(path)))
        }
        var components: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) where part != "." {
            guard part != "..", isSafeName(Array(part.utf8)) else { return .failure(.unsafePath(escaped(path))) }
            components.append(String(part))
        }
        return .success(components)
    }

    /// An absolute host path split into its parent and final name.
    static func hostParentAndName(_ path: String) -> Result<(parent: String, name: String), WorkspaceTransferRefusal> {
        guard path.hasPrefix("/"), hasControlCharacter(path) == false else { return .failure(.unsafePath(escaped(path))) }
        var components: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) where part != "." {
            guard part != "..", isSafeName(Array(part.utf8)) else { return .failure(.unsafePath(escaped(path))) }
            components.append(String(part))
        }
        guard let name = components.last else { return .failure(.unsafePath(escaped(path))) }
        return .success(("/" + components.dropLast().joined(separator: "/"), name))
    }

    /// Workspace paths an upload never writes: rv and git control paths
    /// (all of `.git`, stricter than the cage) and the run-later files and
    /// trees host tools execute or trust. Compared case-folded, as on a
    /// case-insensitive volume.
    static func isProtectedWorkspacePath(_ components: [String]) -> Bool {
        guard components.isEmpty == false else { return false }
        let path = components.map(caseFolded).joined(separator: "/")
        return protectedWorkspacePrefixes.contains { protected in
            path == protected || path.hasPrefix(protected + "/")
        }
    }

    private static let protectedWorkspacePrefixes: [String] =
        ([".git"] + MicroVMControlLayout.controlTrees + MicroVMControlLayout.controlFiles
            + WorkspaceRunLaterPaths.files + WorkspaceRunLaterPaths.trees).map(caseFolded)

    private static func caseFolded(_ text: String) -> String {
        var folded = ""
        for character in text.lowercased() {
            switch character {
            case "\u{017F}": folded.append("s")
            case "\u{212A}": folded.append("k")
            default: folded.append(character)
            }
        }
        return folded
    }

    static func isSafeName(_ bytes: [UInt8]) -> Bool {
        guard bytes.isEmpty == false, bytes.count <= 255, bytes != [0x2E], bytes != [0x2E, 0x2E] else { return false }
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 != 0x7F && $0 != 0x2F }) else { return false }
        return String(validating: bytes, as: UTF8.self) != nil
    }

    private static func hasControlCharacter(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    /// Display form: control characters as `\xNN`, invalid UTF-8 replaced.
    public static func escaped(_ text: String) -> String {
        escaped(Array(text.utf8))
    }

    static func escaped(_ bytes: [UInt8]) -> String {
        var out = ""
        for scalar in String(decoding: bytes, as: UTF8.self).unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F {
                out += "\\x" + String(scalar.value, radix: 16).leftPadded(to: 2)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}

private extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: "0", count: width - count) + self
    }
}

// MARK: - File system plumbing

struct NodeIdentity: Hashable {
    let device: UInt64
    let inode: UInt64

    init(_ info: stat) {
        device = UInt64(truncatingIfNeeded: info.st_dev)
        inode = UInt64(truncatingIfNeeded: info.st_ino)
    }
}

enum NodeKind {
    case directory, file, symlink, special

    init(_ info: stat) {
        switch info.st_mode & S_IFMT {
        case S_IFDIR: self = .directory
        case S_IFREG: self = .file
        case S_IFLNK: self = .symlink
        default: self = .special
        }
    }
}

func lstatAt(_ directory: Int32, _ name: String) -> (stat?, Int32) {
    var info = stat()
    let result = name.withCString { fstatat(directory, $0, &info, AT_SYMLINK_NOFOLLOW) }
    return result == 0 ? (info, 0) : (nil, errno)
}

func fstatOf(_ fd: Int32) -> stat? {
    var info = stat()
    return fstat(fd, &info) == 0 ? info : nil
}

func openDirectoryAt(_ parent: Int32, _ name: String) -> Int32 {
    name.withCString { openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
}

/// Entry names of an open directory as raw bytes, `.`/`..` dropped.
func directoryNames(_ fd: Int32) -> [[UInt8]]? {
    let copy = dup(fd)
    guard copy >= 0 else { return nil }
    guard let stream = fdopendir(copy) else {
        close(copy)
        return nil
    }
    defer { closedir(stream) }
    var names: [[UInt8]] = []
    while true {
        errno = 0
        guard let entry = readdir(stream) else { return errno == 0 ? names : nil }
        let bytes = withUnsafeBytes(of: &entry.pointee.d_name) { raw in Array(raw.prefix(while: { $0 != 0 })) }
        if bytes == [0x2E] || bytes == [0x2E, 0x2E] { continue }
        names.append(bytes)
    }
}

/// `realpath` of the longest existing prefix plus the rest, so a protected
/// root that does not exist yet still compares by its eventual path.
private func resolvedPath(_ path: String) -> String {
    var head = path
    var tail: [String] = []
    while true {
        if let real = realpath(head, nil) {
            defer { free(real) }
            let base = String(cString: real)
            return tail.isEmpty ? base : (base == "/" ? "" : base) + "/" + tail.reversed().joined(separator: "/")
        }
        let url = URL(fileURLWithPath: head)
        let parent = url.deletingLastPathComponent().path
        guard parent != head, parent.isEmpty == false else { return path }
        tail.append(url.lastPathComponent)
        head = parent
    }
}

/// Identities of `/` and every directory on the way to the resolved
/// path, and of the path itself when it exists (not followed).
private func identityChain(_ resolved: String) -> Set<NodeIdentity> {
    var chain = Set<NodeIdentity>()
    var prefix = ""
    var info = stat()
    if lstat("/", &info) == 0 { chain.insert(NodeIdentity(info)) }
    for part in resolved.split(separator: "/") {
        prefix += "/" + part
        guard lstat(prefix, &info) == 0 else { break }
        chain.insert(NodeIdentity(info))
    }
    return chain
}

/// Lexical (case-folded) and inode comparison of two resolved paths.
private struct ResolvedNode {
    let path: String
    let folded: String
    let identity: NodeIdentity?
    let chain: Set<NodeIdentity>

    init(_ path: String) {
        let resolved = resolvedPath(path)
        self.path = resolved
        folded = resolved.lowercased()
        var info = stat()
        identity = lstat(resolved, &info) == 0 ? NodeIdentity(info) : nil
        chain = identityChain(resolved)
    }

    func isInsideOrEqual(_ other: ResolvedNode) -> Bool {
        if folded == other.folded || folded.hasPrefix(other.folded == "/" ? "/" : other.folded + "/") { return true }
        return other.identity.map(chain.contains) ?? false
    }
}

// MARK: - Planning

struct PlannedEntry {
    /// Components below the transferred top; empty for the top itself.
    let path: [String]
    let isDirectory: Bool
    let identity: NodeIdentity
    let size: UInt64
    let executable: Bool
}

struct TransferPlan {
    var entries: [PlannedEntry] = []
    var ignored = 0
    var bytes: UInt64 = 0

    var summary: WorkspaceTransferSummary {
        WorkspaceTransferSummary(
            files: entries.filter { $0.isDirectory == false }.count,
            directories: entries.filter(\.isDirectory).count,
            bytes: bytes, ignored: ignored
        )
    }
}

private struct TreePlanner {
    let limits: WorkspaceTransferLimits
    let gitignore: Bool
    /// Prepended to tree paths in refusals.
    let label: [String]
    let device: UInt64
    let refuseHardLinks: Bool
    var plan = TransferPlan()

    private static let maxGitignoreBytes = 256 * 1024

    func display(_ path: [String]) -> String {
        WorkspaceTransfer.escaped((label + path).joined(separator: "/"))
    }

    /// Plans the top `name` inside `parent`, then everything below it.
    mutating func planTop(parent: Int32, name: String) -> WorkspaceTransferRefusal? {
        let (found, code) = lstatAt(parent, name)
        guard let info = found else {
            return code == ENOENT ? .missing(display([])) : .io(display([]), code)
        }
        if let refusal = admit(info, path: []) { return refusal }
        guard NodeKind(info) == .directory else { return checkSelection() }
        let fd = openDirectoryAt(parent, name)
        guard fd >= 0 else { return .io(display([]), errno) }
        defer { close(fd) }
        guard let opened = fstatOf(fd), NodeIdentity(opened) == NodeIdentity(info) else { return .changed(display([])) }
        if let refusal = planDirectory(fd, path: [], rules: GitignoreRules()) { return refusal }
        return checkSelection()
    }

    private func checkSelection() -> WorkspaceTransferRefusal? {
        plan.entries.contains { $0.isDirectory == false } ? nil : .nothingSelected
    }

    /// Kind, device, alias and cap checks for one selected entry.
    private mutating func admit(_ info: stat, path: [String]) -> WorkspaceTransferRefusal? {
        if path.count > limits.maxDepth { return .tooDeep(limits.maxDepth) }
        let kind = NodeKind(info)
        switch kind {
        case .symlink: return .symlink(display(path))
        case .special: return .specialFile(display(path))
        case .directory, .file: break
        }
        if UInt64(truncatingIfNeeded: info.st_dev) != device { return .otherDevice(display(path)) }
        let size = kind == .file ? UInt64(max(0, Int64(info.st_size))) : 0
        if kind == .file, refuseHardLinks, info.st_nlink > 1 { return .hardLinked(display(path)) }
        plan.entries.append(PlannedEntry(
            path: path, isDirectory: kind == .directory, identity: NodeIdentity(info),
            size: size, executable: info.st_mode & 0o100 != 0
        ))
        plan.bytes += size
        if plan.entries.count > limits.maxEntries { return .tooManyEntries(limits.maxEntries) }
        if plan.bytes > limits.maxBytes { return .tooLarge(limits.maxBytes) }
        return nil
    }

    private mutating func planDirectory(_ fd: Int32, path: [String], rules inherited: GitignoreRules) -> WorkspaceTransferRefusal? {
        guard let raw = directoryNames(fd) else { return .io(display(path), errno) }
        var names: [String] = []
        for bytes in raw {
            guard WorkspaceTransfer.isSafeName(bytes), let name = String(validating: bytes, as: UTF8.self) else {
                return .unsafeName(display(path) + (path.isEmpty && label.isEmpty ? "" : "/") + WorkspaceTransfer.escaped(bytes))
            }
            names.append(name)
        }
        names.sort()
        var rules = inherited
        if gitignore, names.contains(".gitignore"), let text = readGitignore(fd) {
            rules = rules.adding(text, base: path)
        }
        for name in names {
            let childPath = path + [name]
            if gitignore, name == ".git" {
                plan.ignored += 1
                continue
            }
            let (found, code) = lstatAt(fd, name)
            guard let info = found else { return code == ENOENT ? .changed(display(childPath)) : .io(display(childPath), code) }
            if gitignore, rules.isIgnored(childPath, isDirectory: NodeKind(info) == .directory) {
                plan.ignored += 1
                continue
            }
            if let refusal = admit(info, path: childPath) { return refusal }
            guard NodeKind(info) == .directory else { continue }
            let child = openDirectoryAt(fd, name)
            guard child >= 0 else { return .io(display(childPath), errno) }
            defer { close(child) }
            guard let opened = fstatOf(child), NodeIdentity(opened) == NodeIdentity(info) else {
                return .changed(display(childPath))
            }
            if let refusal = planDirectory(child, path: childPath, rules: rules) { return refusal }
        }
        return nil
    }

    /// A regular `.gitignore` of bounded size; anything else contributes no rules.
    private func readGitignore(_ directory: Int32) -> String? {
        let fd = ".gitignore".withCString { openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard let info = fstatOf(fd), NodeKind(info) == .file, info.st_size <= Self.maxGitignoreBytes else { return nil }
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while bytes.count <= Self.maxGitignoreBytes {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            bytes += buffer.prefix(count)
        }
        return String(decoding: bytes.prefix(Self.maxGitignoreBytes), as: UTF8.self)
    }
}

// MARK: - Prepared transfers

struct PreparedTransfer {
    let sourceParent: Int32
    let sourceName: String
    let destinationParent: Int32
    /// Nil: the top is merged into `destinationParent` itself (upload to `.`).
    let destinationName: String?
    let destinationDevice: UInt64
    /// Displayed in refusals about destination entries.
    let destinationLabel: [String]
    let plan: TransferPlan

    func release() {
        close(sourceParent)
        close(destinationParent)
    }
}

private func openResolvedDirectory(_ path: String, display: String) -> Result<(fd: Int32, info: stat), WorkspaceTransferRefusal> {
    let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard fd >= 0 else {
        return .failure(errno == ENOENT ? .missing(display) : .io(display, errno))
    }
    guard let info = fstatOf(fd) else {
        let code = errno
        close(fd)
        return .failure(.io(display, code))
    }
    return .success((fd, info))
}

extension WorkspaceTransfer {
    private static func prepareUpload(_ request: WorkspaceUploadRequest) -> Result<PreparedTransfer, WorkspaceTransferRefusal> {
        let source: (parent: String, name: String)
        switch hostParentAndName(request.source) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let value): source = value
        }
        let destination: [String]
        switch workspaceComponents(request.destination ?? source.name) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let value): destination = value
        }
        guard let realParent = realpathString(source.parent) else {
            return .failure(errno == ENOENT ? .missing(escaped(request.source)) : .io(escaped(request.source), errno))
        }
        let sourceNode = ResolvedNode(joined(realParent, source.name))
        let workspaceNode = ResolvedNode(request.workspace)
        let sourceDisplay = escaped(request.source)
        for root in request.protectedRoots.map(ResolvedNode.init) + [workspaceNode] {
            if sourceNode.isInsideOrEqual(root) || root.isInsideOrEqual(sourceNode) {
                return .failure(.protectedSource(sourceDisplay))
            }
        }

        let parent: (fd: Int32, info: stat)
        switch openResolvedDirectory(realParent, display: sourceDisplay) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let value): parent = value
        }
        let (topInfo, code) = lstatAt(parent.fd, source.name)
        guard let top = topInfo else {
            close(parent.fd)
            return .failure(code == ENOENT ? .missing(sourceDisplay) : .io(sourceDisplay, code))
        }
        if NodeKind(top) == .symlink {
            close(parent.fd)
            return .failure(.symlink(sourceDisplay))
        }
        if NodeKind(top) == .file, destination.isEmpty {
            close(parent.fd)
            return .failure(.unsafePath("."))
        }
        var planner = TreePlanner(
            limits: request.limits, gitignore: request.gitignore, label: [source.name],
            device: UInt64(truncatingIfNeeded: top.st_dev), refuseHardLinks: true
        )
        if let refusal = planner.planTop(parent: parent.fd, name: source.name) {
            close(parent.fd)
            return .failure(refusal)
        }
        for entry in planner.plan.entries where isProtectedWorkspacePath(destination + entry.path) {
            close(parent.fd)
            return .failure(.protectedDestination(escaped((destination + entry.path).joined(separator: "/"))))
        }

        let workspace: (fd: Int32, info: stat)
        switch openResolvedDirectory(workspaceNode.path, display: escaped(request.workspace)) {
        case .failure(let refusal):
            close(parent.fd)
            return .failure(refusal)
        case .success(let value): workspace = value
        }
        let device = UInt64(truncatingIfNeeded: workspace.info.st_dev)
        // Walk (and create) the directories above the destination now, so
        // a symlink or file on the way refuses before anything is copied.
        switch descend(workspace.fd, through: destination.dropLast(), device: device) {
        case .failure(let refusal):
            close(parent.fd)
            close(workspace.fd)
            return .failure(refusal)
        case .success(let fd):
            close(workspace.fd)
            return .success(PreparedTransfer(
                sourceParent: parent.fd, sourceName: source.name,
                destinationParent: fd, destinationName: destination.last,
                destinationDevice: device, destinationLabel: Array(destination.dropLast()),
                plan: planner.plan
            ))
        }
    }

    private static func prepareDownload(_ request: WorkspaceDownloadRequest) -> Result<PreparedTransfer, WorkspaceTransferRefusal> {
        let source: [String]
        switch workspaceComponents(request.source) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let value): source = value
        }
        let destination: (parent: String, name: String)
        switch hostParentAndName(request.destination) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let value): destination = value
        }
        let destinationDisplay = escaped(request.destination)
        guard let realParent = realpathString(destination.parent) else {
            return .failure(errno == ENOENT ? .missing(escaped(destination.parent)) : .io(escaped(destination.parent), errno))
        }
        let workspaceNode = ResolvedNode(request.workspace)
        let destinationNode = ResolvedNode(joined(realParent, destination.name))
        for root in request.protectedRoots.map(ResolvedNode.init) + [workspaceNode] where destinationNode.isInsideOrEqual(root) {
            return .failure(.protectedDestination(destinationDisplay))
        }

        let workspace: (fd: Int32, info: stat)
        switch openResolvedDirectory(workspaceNode.path, display: escaped(request.workspace)) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let value): workspace = value
        }
        let device = UInt64(truncatingIfNeeded: workspace.info.st_dev)
        // The source's parent, reached by descriptor without following links.
        let sourceParent: Int32
        let sourceName: String
        if let last = source.last {
            switch descend(workspace.fd, through: source.dropLast(), device: device, create: false) {
            case .failure(let refusal):
                close(workspace.fd)
                return .failure(refusal)
            case .success(let fd):
                sourceParent = fd
                sourceName = last
            }
            close(workspace.fd)
        } else {
            // `.`: the workspace root, opened again through its parent.
            let url = URL(fileURLWithPath: workspaceNode.path)
            close(workspace.fd)
            switch openResolvedDirectory(url.deletingLastPathComponent().path, display: escaped(request.workspace)) {
            case .failure(let refusal): return .failure(refusal)
            case .success(let value): sourceParent = value.fd
            }
            sourceName = url.lastPathComponent
        }
        var planner = TreePlanner(
            limits: request.limits, gitignore: request.gitignore, label: source, device: device, refuseHardLinks: false
        )
        if let refusal = planner.planTop(parent: sourceParent, name: sourceName) {
            close(sourceParent)
            return .failure(refusal)
        }

        let parent: (fd: Int32, info: stat)
        switch openResolvedDirectory(realParent, display: escaped(destination.parent)) {
        case .failure(let refusal):
            close(sourceParent)
            return .failure(refusal)
        case .success(let value): parent = value
        }
        let (existing, code) = lstatAt(parent.fd, destination.name)
        guard existing == nil, code == ENOENT else {
            close(sourceParent)
            close(parent.fd)
            return .failure(existing != nil ? .destinationExists(destinationDisplay) : .io(destinationDisplay, code))
        }
        return .success(PreparedTransfer(
            sourceParent: sourceParent, sourceName: sourceName,
            destinationParent: parent.fd, destinationName: destination.name,
            destinationDevice: UInt64(truncatingIfNeeded: parent.info.st_dev),
            destinationLabel: [destinationDisplay], plan: planner.plan
        ))
    }

    /// Opens `components` below `root` one directory at a time, never
    /// following a link, staying on `device`; `create` makes missing ones.
    private static func descend(
        _ root: Int32, through components: ArraySlice<String>, device: UInt64, create: Bool = true
    ) -> Result<Int32, WorkspaceTransferRefusal> {
        var current = dup(root)
        guard current >= 0 else { return .failure(.io(".", errno)) }
        var walked: [String] = []
        for name in components {
            walked.append(name)
            let display = escaped(walked.joined(separator: "/"))
            var (found, code) = lstatAt(current, name)
            if found == nil, code == ENOENT, create {
                if name.withCString({ mkdirat(current, $0, 0o755) }) != 0, errno != EEXIST {
                    let failure = errno
                    close(current)
                    return .failure(.io(display, failure))
                }
                (found, code) = lstatAt(current, name)
            }
            guard let info = found else {
                close(current)
                return .failure(code == ENOENT ? .missing(display) : .io(display, code))
            }
            switch NodeKind(info) {
            case .symlink:
                close(current)
                return .failure(.symlink(display))
            case .file, .special:
                close(current)
                return .failure(.destinationConflict(display))
            case .directory:
                break
            }
            let next = openDirectoryAt(current, name)
            close(current)
            guard next >= 0 else { return .failure(.io(display, errno)) }
            guard let opened = fstatOf(next), NodeIdentity(opened) == NodeIdentity(info),
                UInt64(truncatingIfNeeded: opened.st_dev) == device
            else {
                close(next)
                return .failure(.otherDevice(display))
            }
            current = next
        }
        return .success(current)
    }

    private static func realpathString(_ path: String) -> String? {
        guard let real = realpath(path, nil) else { return nil }
        defer { free(real) }
        return String(cString: real)
    }

    private static func joined(_ parent: String, _ name: String) -> String {
        parent == "/" ? "/" + name : parent + "/" + name
    }
}
